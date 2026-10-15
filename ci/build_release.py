"""菩提护令 Android APK 一键打包。

绕开 Gradle 与 flutter_tools（在本沙箱内它们的子进程调用受限），
手工驱动编译器与打包工具完成全流程。

链路：
  1. pub_fetch            解析并下载 pub 依赖        -> .dart_tool/package_config.json
  2. gen_plugins_deps     生成插件依赖描述            -> .flutter-plugins-dependencies
  3. gen_android_shell    生成 android 工程壳         -> android/
  4. build_kernel         Dart -> app.dill
  5. build_aot            dill -> libapp.so (三 ABI)
  6. scan_plugin_sources  盘点插件源文件
  7. collect_deps         展开 Maven 依赖为 classpath jar
  8. resolve_runtime_deps 解析插件声明的直接依赖
  9. resolve_closure      算传递依赖闭包
 10. fetch_extra_deps     补齐缓存缺失的 aar
 11. compile_plugins      Java/Kotlin 混编            -> build/classes
 12. build_resources      aapt2 compile + link        -> base.apk / R.java
 13. build_dex            d8 合并                     -> classes.dex
 14. assemble_apk         组装 + zipalign + 签名      -> 菩提护令-v1.0.0-release.apk

用法：
  python ci/build_release.py            # 全流程
  python ci/build_release.py --from 11  # 从第 11 步开始（复用前序产物）
"""
import os
import subprocess
import sys
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
CI = os.path.join(ROOT, 'bodhi_token', 'ci')
PY = sys.executable
FLUTTER_SHIM = os.path.join(ROOT, 'toolchain', 'flutter', 'bin', 'flutter_shim.py')

PIPELINE = [
    ('pub_fetch.py', '解析 pub 依赖'),
    ('gen_plugins_deps.py', '生成插件依赖描述'),
    ('gen_android_shell.py', '生成 android 工程壳'),
    ('build_kernel.py', 'Dart -> app.dill'),
    ('build_aot.py', 'app.dill -> libapp.so x3'),
    ('scan_plugin_sources.py', '盘点插件源文件'),
    ('collect_deps.py', '展开 Maven 依赖'),
    ('resolve_runtime_deps.py', '解析直接依赖'),
    ('resolve_closure.py', '计算依赖闭包'),
    ('fetch_extra_deps.py', '补齐缺失依赖'),
    ('compile_plugins.py', 'Java/Kotlin 混编'),
    ('build_resources.py', 'aapt2 资源编译链接'),
    ('build_dex.py', 'd8 合并 dex'),
    ('assemble_apk.py', '组装 + 对齐 + 签名'),
]


def run_script(name, label):
    path = os.path.join(CI, name)
    if not os.path.isfile(path):
        print('[SKIP] %s not found' % name)
        return 0
    print('\n' + '=' * 70)
    print('  %s  --  %s' % (name, label))
    print('=' * 70)
    t0 = time.time()
    r = subprocess.run([PY, path], capture_output=True, timeout=7200)

    def dec(b):
        if not b:
            return ''
        for enc in ('utf-8', 'gbk', 'latin-1'):
            try:
                return b.decode(enc)
            except UnicodeDecodeError:
                continue
        return repr(b[:400])

    out = dec(r.stdout)
    err = dec(r.stderr)
    # 过滤掉 d8 的 Info 噪音，只保留关键行
    keep = []
    for line in out.splitlines():
        if line.startswith('Info in ') or line.startswith('  Type `'):
            continue
        if 'was not found, it is required for default' in line:
            continue
        if line.startswith('Classes with missing EnclosingMethod'):
            continue
        keep.append(line)
    if keep:
        print('\n'.join(keep[-60:]))
    if err.strip():
        print('--- stderr ---')
        print('\n'.join(err.splitlines()[-30:]))
    dt = time.time() - t0
    print('\n[%s] rc=%d  %.1fs' % (name, r.returncode, dt))
    return r.returncode


def main():
    start = 1
    if '--from' in sys.argv:
        try:
            start = int(sys.argv[sys.argv.index('--from') + 1])
        except Exception:
            pass

    print('菩提护令 Android 打包流水线')
    print('工作目录:', ROOT)
    print('起始步骤:', start)

    for i, (name, label) in enumerate(PIPELINE, 1):
        if i < start:
            print('[SKIP] %2d. %-26s %s' % (i, name, label))
            continue
        rc = run_script(name, label)
        if rc != 0:
            print('\n!! 步骤 %d (%s) 失败，流水线中止' % (i, name))
            return rc

    # 最终 APK 名由 assemble_apk.py 按 pubspec 版本生成
    import glob as _glob
    candidates = _glob.glob(
        os.path.join(ROOT, 'bodhi_token', 'build', '菩提护令-v*-release.apk'))
    apk = max(candidates, key=os.path.getmtime) if candidates else ''
    print('\n' + '=' * 70)
    if apk and os.path.isfile(apk):
        print('打包完成')
        print('  %s' % apk)
        print('  %.1f MB' % (os.path.getsize(apk) / 1048576))
    else:
        print('!! 未找到最终 APK')
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
