# -*- coding: utf-8 -*-
"""编译菩提护令：gen_kernel_aot + --target flutter -> app.dill（release / AOT kernel）。"""
import os
import subprocess
import sys
import time

ROOT = r'C:\Users\Administrator\WorkBuddy\2026-10-13-20-18-48'
PROJ = os.path.join(ROOT, 'bodhi_token')
FLUTTER = os.path.join(ROOT, 'toolchain', 'flutter')
AOT = os.path.join(FLUTTER, 'bin', 'cache', 'dart-sdk', 'bin', 'dartaotruntime.exe')
GK = os.path.join(FLUTTER, 'bin', 'cache', 'dart-sdk', 'bin', 'snapshots',
                  'gen_kernel_aot.dart.snapshot')
ENGINE = os.path.join(FLUTTER, 'bin', 'cache', 'artifacts', 'engine', 'common',
                      'flutter_patched_sdk_product')
OUT = os.path.join(PROJ, 'build', 'app.dill')


def main():
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    if os.path.exists(OUT):
        try:
            os.remove(OUT)
        except OSError:
            pass
    cmd = [AOT, GK,
           '--platform', os.path.join(ENGINE, 'platform_strong.dill'),
           '--packages', os.path.join(PROJ, '.dart_tool', 'package_config.json'),
           '--target', 'flutter',
           '--aot',
           '--target-os', 'android',
           '--no-embed-sources',
           '-o', OUT,
           os.path.join(PROJ, 'lib', 'main.dart')]
    print('编译中 ...')
    print(' '.join(cmd))
    print('-' * 60)
    t0 = time.time()
    r = subprocess.run(cmd, capture_output=True, text=True)
    dt = time.time() - t0
    print('耗时 %.1fs  rc=%d' % (dt, r.returncode))
    if r.stdout:
        out = r.stdout
        print('--- stdout (%d chars, tail 4000) ---' % len(out))
        print(out[-4000:])
    if r.stderr:
        print('--- stderr ---')
        print(r.stderr[-8000:])
    ok = r.returncode == 0 and os.path.exists(OUT)
    print('=' * 60)
    if ok:
        print('SUCCESS  app.dill = %s  (%.1f MB)' % (OUT, os.path.getsize(OUT) / 1048576.0))
    else:
        print('FAILED')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
