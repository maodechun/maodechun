# -*- coding: utf-8 -*-
"""探针2：固定 --platform，变化 --sdk-root 形式 / --packages 形式，定位 DillLoader 崩溃。"""
import os
import subprocess
import sys

ROOT = r'C:\Users\Administrator\WorkBuddy\2026-10-13-20-18-48'
FLUTTER = os.path.join(ROOT, 'toolchain', 'flutter')
AOT = os.path.join(FLUTTER, 'bin', 'cache', 'dart-sdk', 'bin', 'dartaotruntime.exe')
FS = os.path.join(FLUTTER, 'bin', 'cache', 'dart-sdk', 'bin', 'snapshots',
                  'frontend_server_aot.dart.snapshot')
ENGINE = os.path.join(FLUTTER, 'bin', 'cache', 'artifacts', 'engine', 'common',
                      'flutter_patched_sdk_product')
MINI = r'C:\Users\Administrator\AppData\Local\Temp\minitest'


def uri(p):
    return 'file:///' + p.replace('\\', '/')


CASES = [
    ('sdkroot=plain-tail\\      plat=uri  pkg=uri', ENGINE + '\\', uri(ENGINE) + '/platform_strong.dill', uri(MINI) + '/package_config.json'),
    ('sdkroot=plain-no-tail     plat=uri  pkg=uri', ENGINE, uri(ENGINE) + '/platform_strong.dill', uri(MINI) + '/package_config.json'),
    ('sdkroot=uri-with-tail     plat=uri  pkg=uri', uri(ENGINE) + '/', uri(ENGINE) + '/platform_strong.dill', uri(MINI) + '/package_config.json'),
    ('sdkroot=uri-no-tail       plat=uri  pkg=uri', uri(ENGINE), uri(ENGINE) + '/platform_strong.dill', uri(MINI) + '/package_config.json'),
    ('sdkroot=plain-tail\\      plat=plain pkg=uri', ENGINE + '\\', os.path.join(ENGINE, 'platform_strong.dill'), uri(MINI) + '/package_config.json'),
    ('sdkroot=uri-with-tail     plat=plain pkg=uri', uri(ENGINE) + '/', os.path.join(ENGINE, 'platform_strong.dill'), uri(MINI) + '/package_config.json'),
]

for idx, (label, sdkroot, plat, pkg) in enumerate(CASES):
    OUT = os.path.join(MINI, 'probe2_%d.dill' % idx)
    if os.path.exists(OUT):
        try:
            os.remove(OUT)
        except OSError:
            pass
    cmd = [AOT, FS,
           '--sdk-root', sdkroot,
           '--platform', plat,
           '--aot', '--tfa', '--target-os', 'android',
           '--packages', pkg,
           '--output-dill', OUT,
           uri(MINI) + '/main.dart']
    r = subprocess.run(cmd, capture_output=True, text=True)
    ok = r.returncode == 0 and os.path.exists(OUT)
    print('[%d] %-46s rc=%d ok=%s' % (idx, label, r.returncode, ok))
    if not ok:
        msg = (r.stderr or '') or (r.stdout or '')
        for line in msg.splitlines()[:4]:
            print('       |', line)
    print()
