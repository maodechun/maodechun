"""编译全部 Android 插件源码（Java + Kotlin 混编）为 class 文件。

要点：
- kotlinc 能同时吃 .java 和 .kt，内部会调 javac 处理 Java 部分，
  因此不需要做两阶段编译，天然解决 Java<->Kotlin 循环引用。
- classpath = android.jar + 253 个依赖 jar
- 插件自己的 res/ 暂不参与编译（R 类由 aapt2 生成后再补编）
"""
import json
import os
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
PROJ = os.path.join(ROOT, 'bodhi_token')
JAVA = os.path.join(ROOT, 'toolchain', 'jdk', 'jdk-17.0.2', 'bin', 'java.exe')
KHOME = os.path.join(ROOT, 'toolchain', 'kotlin', 'home')
KLIB = os.path.join(KHOME, 'lib')
DEPS = os.path.join(PROJ, 'build', 'deps')
LIBS = os.path.join(DEPS, 'libs')
ANDROID_JAR = os.path.join(ROOT, 'toolchain', 'sdk', 'platforms', 'android-34', 'android.jar')
OUT = os.path.join(PROJ, 'build', 'classes')
DART_TOOL = os.path.join(PROJ, '.dart_tool')
PATCHED = os.path.join(PROJ, 'build', 'patched_src')
BUILDCONFIG_GEN = os.path.join(PROJ, 'build', 'gen_buildconfig')

# 需要替换为本地修正版的插件源码。
# image_gallery_saver 2.0.3 残留了 Flutter v1 embedding 的
# `io.flutter.plugin.common.PluginRegistry.Registrar` import，
# 该 API 在 Flutter 3.x 已删除，导致编译失败。实际代码并未使用它，
# 因此用去掉该 import 的本地副本替代。
PATCH_MAP = {
    'image_gallery_saver': os.path.join(PATCHED, 'image_gallery_saver'),
    # vibration 1.9.0 残留 Flutter v1 embedding 的 registerWith(Registrar)，
    # 该 API 在 Flutter 3.x 已删除，方法实际未被使用，用去掉该方法的副本替代。
    'vibration': os.path.join(PATCHED, 'vibration'),
    # sqflite 2.3.3 同样残留 v1 的 registerWith(Registrar)，去掉该方法。
    'sqflite': os.path.join(PATCHED, 'sqflite'),
    # sqflite_sqlcipher 3.0.0 的 onCorruption 是单参数旧签名，
    # sqlcipher-android 4.10.0 接口为双参数，改成双参数。
    'sqflite_sqlcipher': os.path.join(PATCHED, 'sqflite_sqlcipher'),
    # local_auth 引用了自身 res 的 R 类；其资源已合并进主 res，
    # 此处把 R 引用改为主包 com.daotuo.bodhitoken.R。
    'local_auth_android': os.path.join(PATCHED, 'local_auth'),
}


def to_path(uri):
    u = uri
    if u.startswith('file:///'):
        u = u[8:]
        if not (len(u) > 1 and u[1] == ':'):
            u = '/' + u
        return os.path.abspath(u)
    if u.startswith('file://'):
        return os.path.abspath(u[7:])
    return os.path.abspath(os.path.join(DART_TOOL, u.replace('/', os.sep)))


def generate_buildconfig():
    """为引用了 BuildConfig 的插件生成缺失的 BuildConfig 类。

    AGP 会在构建时自动为每个模块生成 BuildConfig（含 DEBUG 标志），
    手工 javac 不会生成，导致 url_launcher 等插件报「找不到符号 BuildConfig」。
    这里补一个 DEBUG=false 的占位类。
    """
    pkg_dir = os.path.join(BUILDCONFIG_GEN, 'io', 'flutter', 'plugins',
                           'urllauncher')
    os.makedirs(pkg_dir, exist_ok=True)
    p = os.path.join(pkg_dir, 'BuildConfig.java')
    content = (
        'package io.flutter.plugins.urllauncher;\n'
        'public final class BuildConfig {\n'
        '  public static final boolean DEBUG = false;\n'
        '  private BuildConfig() {}\n'
        '}\n'
    )
    with open(p, 'w', encoding='utf-8', newline='\n') as f:
        f.write(content)
    return p


def gather_sources():
    cfg = json.load(open(os.path.join(DART_TOOL, 'package_config.json'), encoding='utf-8'))
    java, kt, aidl = [], [], []
    mods = []

    # 只编主源码，排除测试目录（测试依赖 JUnit、androidTest 等，与运行无关）
    SKIP_DIRS = {
        'test', 'androidtest', 'androidTest',
    }
    # 匹配 src/<variant>/<lang> 结构下的 variant 段
    EXCLUDE_SEG = {'test', 'androidTest', 'androidtest'}

    for p in cfg['packages']:
        d = to_path(p['rootUri'])
        ad = os.path.join(d, 'android')
        # 若该插件在补丁表里，改用本地修正版目录
        if p['name'] in PATCH_MAP:
            ad = PATCH_MAP[p['name']]
            print('  [patch]', p['name'], '->', ad)
        if not os.path.isdir(ad):
            continue
        n_j = n_k = n_a = 0
        for dp, dirs, fns in os.walk(ad):
            rel = os.path.relpath(dp, ad).replace('\\', '/').lower()
            parts = [x for x in rel.split('/') if x and x != '.']
            # src/test/... 或 src/androidTest/... 一律跳过
            if 'src' in parts:
                i = parts.index('src')
                if i + 1 < len(parts) and parts[i + 1].lower() in EXCLUDE_SEG:
                    dirs[:] = []
                    continue
            # 兜底：任何名为 test 的目录都跳过
            parts_any = {x.lower() for x in parts}
            if parts_any & EXCLUDE_SEG:
                dirs[:] = []
                continue
            for fn in fns:
                f = os.path.join(dp, fn)
                if fn.endswith('.java'):
                    java.append(f)
                    n_j += 1
                elif fn.endswith('.kt'):
                    kt.append(f)
                    n_k += 1
                elif fn.endswith('.aidl'):
                    aidl.append(f)
                    n_a += 1
        if n_j or n_k or n_a:
            mods.append((p['name'], n_j, n_k, n_a))
    return java, kt, aidl, mods


def main():
    java, kt, aidl, mods = gather_sources()
    print('modules:', len(mods), '| java:', len(java), '| kt:', len(kt), '| aidl:', len(aidl))
    if aidl:
        print('  [warn] aidl 存在但本脚本不处理:', len(aidl))

    dep_jars = sorted(
        os.path.join(LIBS, f) for f in os.listdir(LIBS) if f.endswith('.jar')
    )
    cp = [ANDROID_JAR] + dep_jars
    cp_k = cp + [os.path.join(KLIB, f) for f in os.listdir(KLIB)]
    print('classpath: android.jar + %d dep jars' % len(dep_jars))

    os.makedirs(OUT, exist_ok=True)

    # ══════════════════════════════════════════════════════
    # 阶段一：kotlinc 编译 Kotlin
    #   ⚠️ kotlinc 只编译 Kotlin，不编译 Java —— 之前误以为能混编，
    #      导致 115 个 Java 插件被静默丢弃（闪退根因之一）。
    #      因此这里 sources 只传 .kt，Java 在阶段二用 javac 处理。
    # ══════════════════════════════════════════════════════
    if kt:
        argfile = os.path.join(PROJ, 'build', 'kotlinc_args.txt')
        with open(argfile, 'w', encoding='utf-8') as f:
            f.write('-kotlin-home\n')
            f.write(KHOME + '\n')
            f.write('-no-reflect\n')
            f.write('-nowarn\n')
            f.write('-jvm-target\n17\n')
            f.write('-d\n')
            f.write(OUT + '\n')
            f.write('-classpath\n')
            f.write(';'.join(cp_k) + '\n')
            for s in kt:
                f.write(s + '\n')

        cmd = [
            JAVA,
            '-Xmx4g',
            '-cp', ';'.join(os.path.join(KLIB, f) for f in os.listdir(KLIB)),
            'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler',
            '@' + argfile,
        ]
        env = dict(os.environ)
        env['JAVA_HOME'] = os.path.dirname(os.path.dirname(JAVA))
        print('kotlinc compiling', len(kt), 'Kotlin sources ...')
        r = subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=3600)
        print('kotlinc rc =', r.returncode)
        if r.returncode != 0:
            if r.stdout:
                print('\n'.join(r.stdout.splitlines()[-40:]))
            if r.stderr:
                print('\n'.join(r.stderr.splitlines()[-40:]))
            return r.returncode

    # ══════════════════════════════════════════════════════
    # 阶段二：javac 编译 Java
    #   classpath 含 OUT（阶段一的 Kotlin class），解决 Java 引用
    #   Kotlin 生成类（如 Pigeon 的 UrlLauncherApi）的跨语言依赖。
    #   --release 11：webview_flutter 4.14.x 用了 Java 9+ 私有接口方法。
    #   -encoding UTF-8：部分插件源码含中文注释，Windows 默认 GBK 会乱码。
    # ══════════════════════════════════════════════════════
    if java:
        # 补生成缺失的 BuildConfig 类（url_launcher 等引用）
        java = java + [generate_buildconfig()]
        # 主 R.java 由 build_resources.py 的 aapt2 link 生成，
        # local_auth 等插件引用了主包 R，需一并编译。
        rjava = os.path.join(PROJ, 'build', 'gen', 'com', 'daotuo',
                             'bodhitoken', 'R.java')
        if os.path.isfile(rjava):
            java = java + [rjava]
        javac = os.path.join(os.path.dirname(JAVA), 'javac.exe')
        argfile = os.path.join(PROJ, 'build', 'javac_args.txt')
        javac_cp = [OUT] + cp
        with open(argfile, 'w', encoding='utf-8') as f:
            # classpath 也放进 argfile：264 个 jar 会超出 Windows 命令行长度上限
            f.write('-classpath\n')
            f.write(';'.join(javac_cp) + '\n')
            for s in java:
                f.write(s + '\n')
        cmd = [
            javac,
            '--release', '11',
            '-encoding', 'UTF-8',
            '-nowarn',
            '-d', OUT,
            '@' + argfile,
        ]
        print('javac compiling', len(java), 'Java sources ...')
        r = subprocess.run(cmd, capture_output=True, timeout=3600)

        def dec(b):
            if not b:
                return ''
            for enc in ('utf-8', 'gbk', 'latin-1'):
                try:
                    return b.decode(enc)
                except UnicodeDecodeError:
                    continue
            return repr(b[:400])

        err = dec(r.stderr)
        print('javac rc =', r.returncode)
        if r.returncode != 0:
            print('\n'.join(err.splitlines()[-40:]))
            return r.returncode

    n = sum(len(fns) for _, _, fns in os.walk(OUT))
    print('class files produced:', n)
    return 0


if __name__ == '__main__':
    sys.exit(main())
