# -*- coding: utf-8 -*-
"""探针：用两个候选 flutter_patched_sdk 目录分别编译最小 dart 文件，定位 DillLoader 崩溃根因。"""
import os
import subprocess
import sys

ROOT = r'C:\Users\Administrator\WorkBuddy\2026-10-13-20-18-48'
FLUTTER = os.path.join(ROOT, 'toolchain', 'flutter')
AOT = os.path.join(FLUTTER, 'bin', 'cache', 'dart-sdk', 'bin', 'dartaotruntime.exe')
FS = os.path.join(FLUTTER, 'bin', 'cache', 'dart-sdk', 'bin', 'snapshots',
                  'frontend_server_aot.dart.snapshot')
COMMON = os.path.join(FLUTTER, 'bin', 'cache', 'artifacts', 'engine', 'common')

MINI = os.path.join(os.environ.get('TEMP', r'C:\Windows\Temp'), 'minitest')
MINI = sys.argv[1] if len(sys.argv) > 1 else MINI


def uri(p):
    return 'file:///' + p.replace('\\', '/')


def probe(name, extra_aot=True):
    ENGINE = os.path.join(COMMON, name)
    platform = os.path.join(ENGINE, 'platform_strong.dill')
    if not os.path.exists(platform):
        print('  [skip] no platform_strong.dill in', name)
        return None
    OUT = os.path.join(MINI, 'out_%s.dill' % name)
    if os.path.exists(OUT):
        try:
            os.remove(OUT)
        except OSError:
            pass
    cmd = [AOT, FS,
           '--sdk-root', ENGINE + '\\',
           '--platform', uri(platform)]
    if extra_aot:
        cmd += ['--aot', '--tfa', '--target-os', 'android']
    cmd += ['--packages', uri(os.path.join(MINI, 'package_config.json')),
            '--output-dill', OUT,
            uri(os.path.join(MINI, 'main.dart'))]
    r = subprocess.run(cmd, capture_output=True, text=True)
    ok = r.returncode == 0 and os.path.exists(OUT)
    print('  [%s] rc=%d exists=%s size=%s' % (
        name, r.returncode, os.path.exists(OUT),
        os.path.getsize(OUT) if os.path.exists(OUT) else '-'))
    if not ok:
        for line in (r.stderr or '').splitlines()[:6]:
            print('     !', line)
        for line in (r.stdout or '').splitlines()[:6]:
            print('     o', line)
    return ok


if __name__ == '__main__':
    print('MINI =', MINI)
    print('AOT  =', AOT, os.path.exists(AOT))
    print('FS   =', FS, os.path.exists(FS))
    print()
    print('--- with --aot --tfa --target-os android ---')
    a = probe('flutter_patched_sdk_product', True)
    b = probe('flutter_patched_sdk', True)
    print()
    print('--- without --aot (JIT-ish kernel) ---')
    c = probe('flutter_patched_sdk_product', False)
    d = probe('flutter_patched_sdk', False)
    print()
    print('RESULT product/aot=%s  normal/aot=%s  product/jit=%s  normal/jit=%s' % (a, b, c, d))
