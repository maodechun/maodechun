# -*- coding: utf-8 -*-
"""一键打包菩提护令 APK（release）。

流程：
  1) pub_fetch.py        解析 pub 依赖 -> .dart_tool/package_config.json
  2) gen_plugins_deps.py 生成 .flutter-plugins-dependencies
  3) gen_android_shell.py 生成 android/ 工程壳（幂等）
  4) build_kernel.py     Dart -> build/app.dill
  5) build_aot.py        app.dill -> build/jniLibs/<abi>/libapp.so
  6) gradle assembleRelease  -> app-release.apk
       （Gradle 侧由 flutter.bat 垫片完成 assemble 阶段）

产物：bodhi_token/build/app/outputs/flutter-apk/app-release.apk
"""
import io
import os
import re
import shutil
import subprocess
import sys
import time

ROOT = r'C:\Users\Administrator\WorkBuddy\2026-10-13-20-18-48'
PROJ = os.path.join(ROOT, 'bodhi_token')
CI = os.path.join(PROJ, 'ci')
TOOLCHAIN = os.path.join(ROOT, 'toolchain')
PY = sys.executable or 'python'

JAVA_HOME = os.path.join(TOOLCHAIN, 'jdk', 'jdk-17.0.2')
ANDROID_HOME = os.path.join(TOOLCHAIN, 'sdk')
GRADLE = os.path.join(TOOLCHAIN, 'gradle-8.4', 'bin', 'gradle.bat')
GRADLE_USER_HOME = os.path.join(TOOLCHAIN, 'gradle-home')

AND = os.path.join(PROJ, 'android')
OUT_APK = os.path.join(PROJ, 'build', 'app', 'outputs', 'flutter-apk', 'app-release.apk')


def banner(s):
    print()
    print('=' * 68)
    print('  ' + s)
    print('=' * 68)


def run(step, args, env=None, cwd=None, timeout=None):
    print('\n>>> %s' % step)
    print('    ' + ' '.join(args))
    e = os.environ.copy()
    if env:
        e.update(env)
    r = subprocess.run(args, env=e, cwd=cwd, capture_output=True, text=True,
                       timeout=timeout)
    if r.stdout:
        lines = r.stdout.rstrip().splitlines()
        for ln in lines[-40:]:
            print('    | ' + ln)
    if r.stderr:
        lines = r.stderr.rstrip().splitlines()
        for ln in lines[-40:]:
            print('    ! ' + ln)
    return r.returncode


def main():
    t0 = time.time()
    steps = []

    # 1) pub 依赖
    banner('1/6  解析 pub 依赖')
    env = {'FLUTTER_ROOT': os.path.join(TOOLCHAIN, 'flutter')}
    rc = run('pub_fetch', [PY, os.path.join(CI, 'pub_fetch.py'), PROJ], env=env)
    steps.append(('pub_fetch', rc))
    if rc != 0:
        return finish(steps, t0)

    # 2) 插件依赖清单
    banner('2/6  生成 .flutter-plugins-dependencies')
    rc = run('gen_plugins_deps', [PY, os.path.join(CI, 'gen_plugins_deps.py')])
    steps.append(('gen_plugins_deps', rc))
    if rc != 0:
        return finish(steps, t0)

    # 3) android 工程壳
    banner('3/6  生成 android 工程壳')
    rc = run('gen_android_shell', [PY, os.path.join(CI, 'gen_android_shell.py')])
    steps.append(('gen_android_shell', rc))
    if rc != 0:
        return finish(steps, t0)

    # 4) kernel
    banner('4/6  编译 Dart kernel (app.dill)')
    rc = run('build_kernel', [PY, os.path.join(CI, 'build_kernel.py')])
    steps.append(('build_kernel', rc))
    if rc != 0:
        return finish(steps, t0)

    # 5) AOT
    banner('5/6  AOT 编译 (libapp.so x 3 ABI)')
    rc = run('build_aot', [PY, os.path.join(CI, 'build_aot.py')])
    steps.append(('build_aot', rc))
    if rc != 0:
        return finish(steps, t0)

    # 6) Gradle 打包
    banner('6/6  Gradle assembleRelease -> APK')
    gradle_env = {
        'JAVA_HOME': JAVA_HOME,
        'ANDROID_HOME': ANDROID_HOME,
        'ANDROID_SDK_ROOT': ANDROID_HOME,
        'GRADLE_USER_HOME': GRADLE_USER_HOME,
        'PATH': os.path.join(JAVA_HOME, 'bin') + os.pathsep + os.environ.get('PATH', ''),
    }
    rc = run('gradle assembleRelease',
             [GRADLE, 'assembleRelease', '--console=plain', '--no-daemon',
              '--stacktrace'],
             env=gradle_env, cwd=AND)
    steps.append(('gradle', rc))

    return finish(steps, t0)


def finish(steps, t0):
    banner('汇总')
    for name, rc in steps:
        print('  %-22s %s' % (name, 'OK' if rc == 0 else 'FAILED(rc=%d)' % rc))
    print('  总用时 %.1fs' % (time.time() - t0))

    if os.path.exists(OUT_APK):
        print()
        print('  ★ APK: %s' % OUT_APK)
        print('    %.1f MB' % (os.path.getsize(OUT_APK) / 1048576.0))
        return 0
    print()
    print('  未找到 APK 产物:', OUT_APK)
    return 1


if __name__ == '__main__':
    sys.exit(main())
