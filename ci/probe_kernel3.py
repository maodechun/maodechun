# -*- coding: utf-8 -*-
"""探针3：使用 gen_kernel_aot.dart.snapshot + --target flutter 编译最小 dart。"""
import os
import subprocess
import sys

ROOT = r'C:\Users\Administrator\WorkBuddy\2026-10-13-20-18-48'
FLUTTER = os.path.join(ROOT, 'toolchain', 'flutter')
AOT = os.path.join(FLUTTER, 'bin', 'cache', 'dart-sdk', 'bin', 'dartaotruntime.exe')
GK = os.path.join(FLUTTER, 'bin', 'cache', 'dart-sdk', 'bin', 'snapshots',
                  'gen_kernel_aot.dart.snapshot')
MINI = sys.argv[1] if len(sys.argv) > 1 else r'C:\Users\Administrator\AppData\Local\Temp\minitest'
COMMON = os.path.join(FLUTTER, 'bin', 'cache', 'artifacts', 'engine', 'common')


def run_case(label, sdk_name, target, out_name):
    ENGINE = os.path.join(COMMON, sdk_name)
    plat = os.path.join(ENGINE, 'platform_strong.dill')
    OUT = os.path.join(MINI, out_name)
    if os.path.exists(OUT):
        try:
            os.remove(OUT)
        except OSError:
            pass
    cmd = [AOT, GK,
           '--platform', plat,
           '--packages', os.path.join(MINI, 'package_config.json'),
           '--target', target,
           '--aot',
           '--target-os', 'android',
           '-o', OUT,
           os.path.join(MINI, 'main.dart')]
    r = subprocess.run(cmd, capture_output=True, text=True)
    ok = r.returncode == 0 and os.path.exists(OUT)
    print('[%s] rc=%d ok=%s size=%s' % (label, r.returncode, ok,
          os.path.getsize(OUT) if ok else '-'))
    if not ok:
        msg = (r.stderr or '') or (r.stdout or '')
        for line in msg.splitlines()[:8]:
            print('     |', line)
    print()
    return ok


if __name__ == '__main__':
    print('MINI =', MINI)
    a = run_case('flutter/target=flutter', 'flutter_patched_sdk', 'flutter', 'gk_flutter.dill')
    b = run_case('product/target=flutter', 'flutter_patched_sdk_product', 'flutter', 'gk_product.dill')
    c = run_case('flutter/target=vm     ', 'flutter_patched_sdk', 'vm', 'gk_vm.dill')
    print('RESULT flutter=%s product=%s vm=%s' % (a, b, c))
