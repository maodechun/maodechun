"""组装最终 APK：把 dex / libs / flutter_assets 合并进 aapt2 link 产出的 base.apk，
再 zipalign + apksigner 签名。

组装顺序（对齐要求在写入 raw 文件后、签名前完成）：
  1. 以 base.apk（含 resources.arsc + 二进制 Manifest + res/）为骨架
  2. 加入 classes.dex
  3. 加入 lib/<abi>/*.so
  4. 加入 assets/flutter_assets/**
  5. 加入插件的 native 库（若有）
  6. zipalign -p 4
  7. apksigner sign
"""
import json
import os
import shutil
import subprocess
import sys
import zipfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
PROJ = os.path.join(ROOT, 'bodhi_token')
BUILD = os.path.join(PROJ, 'build')
BT34 = os.path.join(ROOT, 'toolchain', 'sdk', 'build-tools', '34.0.0')
BT36 = os.path.join(ROOT, 'toolchain', 'sdk', 'build-tools', '36.0.0')
JAVA_HOME = os.path.join(ROOT, 'toolchain', 'jdk', 'jdk-17.0.2')
JAVA = os.path.join(JAVA_HOME, 'bin', 'java.exe')
ZIPALIGN = os.path.join(BT34, 'zipalign.exe')
APKSIGNER_JAR = os.path.join(BT34, 'lib', 'apksigner.jar')
APKSIGNER_BAT = os.path.join(BT34, 'apksigner.bat')

BASE_APK = os.path.join(BUILD, 'res_linked', 'base.apk')
DEX_ZIP = os.path.join(BUILD, 'dex', 'classes.zip')
JNILIBS = os.path.join(BUILD, 'jniLibs')
SHIM_ASSETS = os.path.join(BUILD, 'shimtest', 'flutter_assets')
OUT_APK = os.path.join(BUILD, 'app-unsigned.apk')
ALIGNED_APK = os.path.join(BUILD, 'app-aligned.apk')


def read_pubspec_version():
    """从 pubspec.yaml 读取版本（与 build_resources.py 同源）。"""
    spec = os.path.join(PROJ, 'pubspec.yaml')
    with open(spec, encoding='utf-8') as f:
        for line in f:
            if line.strip().startswith('version:'):
                return line.split(':', 1)[1].strip().partition('+')[0] or '1.0.0'
    return '1.0.0'


FINAL_APK = os.path.join(BUILD, '菩提护令-v%s-release.apk' % read_pubspec_version())

def _read_key_properties():
    """读取 android/key.properties（本地开发凭据，已在 .gitignore 中，不入库）。"""
    path = os.path.join(PROJ, 'android', 'key.properties')
    props = {}
    if not os.path.isfile(path):
        return props
    with open(path, encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#') or '=' not in line:
                continue
            k, v = line.split('=', 1)
            props[k.strip()] = v.strip()
    return props


# 签名凭据一律不写入源码：解析顺序为
#   1) 环境变量 BODHI_KS_PATH / BODHI_KS_PASS / BODHI_KEY_PASS / BODHI_KEY_ALIAS
#   2) android/key.properties（本机私存，打包时排除）
#   3) 默认 keystore 路径 android_keys/bodhi-release.jks（口令仍须由 1/2 提供）
_PROPS = _read_key_properties()


def _resolve_keystore():
    env_path = os.environ.get('BODHI_KS_PATH')
    if env_path:
        return os.path.abspath(env_path)
    store_file = _PROPS.get('storeFile')
    if store_file:
        # key.properties 中的相对路径基于 android/ 目录
        return os.path.abspath(os.path.join(PROJ, 'android', store_file))
    return os.path.join(ROOT, 'android_keys', 'bodhi-release.jks')


KEYSTORE = _resolve_keystore()
KS_PASS = os.environ.get('BODHI_KS_PASS') or _PROPS.get('storePassword') or ''
KEY_PASS = os.environ.get('BODHI_KEY_PASS') or _PROPS.get('keyPassword') or KS_PASS
KEY_ALIAS = (os.environ.get('BODHI_KEY_ALIAS')
             or _PROPS.get('keyAlias') or 'bodhi')

# 打包 ABI 列表，可用环境变量 BODHI_ABIS 裁剪（逗号分隔）。
# 例：BODHI_ABIS=arm64-v8a 只出 64 位真机包（包体再省约 1/4）。
# 默认双 ARM 架构：覆盖全部真实手机；x86_64 仅模拟器需要，
# 体积约 25MB，默认剔除。模拟器验证时设 BODHI_ABIS=arm64-v8a,x86_64。
ABIS = os.environ.get(
    'BODHI_ABIS', 'arm64-v8a,armeabi-v7a',
).split(',')


def run(cmd, label, timeout=1800, env=None):
    print('\n>>>', label)
    r = subprocess.run(cmd, capture_output=True, timeout=timeout, env=env)

    def dec(b):
        if not b:
            return ''
        for enc in ('utf-8', 'gbk', 'latin-1'):
            try:
                return b.decode(enc)
            except UnicodeDecodeError:
                continue
        return repr(b[:500])

    so, se = dec(r.stdout), dec(r.stderr)
    print('   rc =', r.returncode)
    for tag, s in (('stdout', so), ('stderr', se)):
        if s:
            print('--- %s ---' % tag)
            print('\n'.join(s.splitlines()[-30:]))
    return r.returncode


def assemble():
    """把 base.apk 作为骨架，写入 dex/libs/assets。"""
    # 先准备一个工作副本，避免污染 base.apk
    if os.path.isfile(OUT_APK):
        os.remove(OUT_APK)
    shutil.copy2(BASE_APK, OUT_APK)
    print('skeleton:', os.path.basename(OUT_APK),
          os.path.getsize(OUT_APK), 'bytes')

    # 用 append 模式写入（APK 允许追加条目）
    with zipfile.ZipFile(OUT_APK, 'a', zipfile.ZIP_DEFLATED) as z:
        # 1. dex
        with zipfile.ZipFile(DEX_ZIP) as dz:
            for n in dz.namelist():
                if n.endswith('.dex'):
                    with dz.open(n) as s:
                        z.writestr(n, s.read())
                    print('   + ', n)

        # 2. native libs
        for abi in ABIS:
            d = os.path.join(JNILIBS, abi)
            if not os.path.isdir(d):
                continue
            for fn in sorted(os.listdir(d)):
                if not fn.endswith('.so'):
                    continue
                p = os.path.join(d, fn)
                arc = 'lib/%s/%s' % (abi, fn)
                # .so 必须 STORED（不压缩），否则 zipalign 与加载会出问题
                z.writestr(arc, open(p, 'rb').read(),
                           compress_type=zipfile.ZIP_STORED)
                print('   + ', arc, os.path.getsize(p))

        # 3. flutter assets
        if os.path.isdir(SHIM_ASSETS):
            for dp, _, fns in os.walk(SHIM_ASSETS):
                for fn in fns:
                    p = os.path.join(dp, fn)
                    rel = os.path.relpath(p, SHIM_ASSETS).replace(os.sep, '/')
                    arc = 'assets/flutter_assets/' + rel
                    z.writestr(arc, open(p, 'rb').read())
                    print('   + ', arc)

        # 3.5 框架着色器（Material 的 ink_sparkle / stretch_effect 等）。
        #     正常 flutter assemble 会自动用 impellerc 编译成 IPLR 运行时
        #     字节码再打包；直接塞 GLSL 源码引擎会报
        #     "Payload does not have valid identifier"（缺 IPLR 头）。
        #     参数完全对齐 flutter_tools shader_compiler.dart 的 Android 分支。
        FW_SHADERS = os.path.join(ROOT, 'toolchain', 'flutter', 'packages',
                                  'flutter', 'lib', 'src', 'material', 'shaders')
        IMPELLERC = os.path.join(ROOT, 'toolchain', 'flutter', 'bin', 'cache',
                                 'artifacts', 'engine', 'windows-x64', 'impellerc.exe')
        SHADER_LIB = os.path.join(os.path.dirname(IMPELLERC), 'shader_lib')
        SHADER_OUT = os.path.join(BUILD, 'shaders_compiled')
        os.makedirs(SHADER_OUT, exist_ok=True)
        if os.path.isdir(FW_SHADERS):
            for fn in sorted(os.listdir(FW_SHADERS)):
                if not fn.endswith('.frag'):
                    continue
                src = os.path.join(FW_SHADERS, fn)
                out = os.path.join(SHADER_OUT, fn)
                if not os.path.isfile(out) or os.path.getmtime(out) < os.path.getmtime(src):
                    cmd = [IMPELLERC,
                           '--sksl', '--runtime-stage-gles',
                           '--runtime-stage-gles3', '--runtime-stage-vulkan',
                           '--iplr', '--sl=' + out, '--spirv=' + out + '.spirv',
                           '--input=' + src, '--input-type=frag',
                           '--include=' + FW_SHADERS, '--include=' + SHADER_LIB]
                    r = run(cmd, 'impellerc ' + fn, timeout=120)
                    if r != 0:
                        print('   [warn] impellerc failed for', fn, '- bundling raw GLSL')
                        out = src
                arc = 'assets/flutter_assets/shaders/' + fn
                z.writestr(arc, open(out, 'rb').read())
                print('   + ', arc, os.path.getsize(out), 'bytes')

    print('\nassembled:', os.path.getsize(OUT_APK), 'bytes')


def align():
    if os.path.isfile(ALIGNED_APK):
        os.remove(ALIGNED_APK)
    # zipalign 必须用 build-tools 36：34.0.0 的 zipalign 不支持 -P 页对齐参数
    ZIPALIGN = os.path.join(BT36, 'zipalign.exe')
    # -P 16：.so 按 16KB 页对齐存储（Android 15+ 16KB 页设备必需；
    #        注意 -P 不能与 -p 同用，-P 16 本身已包含 .so 页对齐）
    rc = run([ZIPALIGN, '-f', '-P', '16', '4', OUT_APK, ALIGNED_APK],
             'zipalign')
    if os.path.isfile(ALIGNED_APK):
        print('   aligned:', os.path.getsize(ALIGNED_APK), 'bytes')
    return rc


def sign():
    if not KS_PASS:
        print('\n!! 缺少签名口令：请设置环境变量 BODHI_KS_PASS（及可选的 '
              'BODHI_KEY_PASS），或提供 android/key.properties。')
        return 1
    if not os.path.isfile(KEYSTORE):
        print('\n!! 找不到签名密钥库: %s' % KEYSTORE)
        return 1
    env = dict(os.environ)
    env['JAVA_HOME'] = JAVA_HOME
    if os.path.isfile(FINAL_APK):
        os.remove(FINAL_APK)
    cmd = [
        JAVA, '-jar', APKSIGNER_JAR, 'sign',
        '--ks', KEYSTORE,
        '--ks-pass', 'pass:' + KS_PASS,
        '--key-pass', 'pass:' + (KEY_PASS or KS_PASS),
        '--ks-key-alias', KEY_ALIAS,
        '--v1-signing-enabled', 'true',
        '--v2-signing-enabled', 'true',
        '--v3-signing-enabled', 'true',
        '--out', FINAL_APK,
        ALIGNED_APK,
    ]
    rc = run(cmd, 'apksigner sign', env=env)
    if os.path.isfile(FINAL_APK):
        print('   signed:', os.path.getsize(FINAL_APK), 'bytes')
    return rc


def verify():
    env = dict(os.environ)
    env['JAVA_HOME'] = JAVA_HOME
    cmd = [JAVA, '-jar', APKSIGNER_JAR, 'verify', '--verbose', FINAL_APK]
    return run(cmd, 'apksigner verify', env=env)


def main():
    assemble()
    align()
    sign()
    verify()
    print('\n=== FINAL ===')
    if os.path.isfile(FINAL_APK):
        print(FINAL_APK, os.path.getsize(FINAL_APK), 'bytes')
    return 0


if __name__ == '__main__':
    sys.exit(main())
