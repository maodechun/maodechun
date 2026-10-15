# -*- coding: utf-8 -*-
"""AOT 编译：app.dill -> libapp.so（按 ABI 逐个生成）。

Android release 使用 --snapshot_kind=app-aot-elf，
产物即 lib/<abi>/libapp.so。
"""
import os
import subprocess
import sys
import time

ROOT = r'C:\Users\Administrator\WorkBuddy\2026-10-13-20-18-48'
PROJ = os.path.join(ROOT, 'bodhi_token')
FLUTTER = os.path.join(ROOT, 'toolchain', 'flutter')
ENGINE_ART = os.path.join(FLUTTER, 'bin', 'cache', 'artifacts', 'engine')

DILL = os.path.join(PROJ, 'build', 'app.dill')

# Flutter ABI 名 -> android 平台目录名（与 java 侧 jniLibs 目录一致）
ABIS = [
    ('android-arm64-release', 'arm64-v8a'),
    ('android-arm-release', 'armeabi-v7a'),
    ('android-x64-release', 'x86_64'),
]


def build_one(artifact_dir, abi, out_root):
    gs = os.path.join(ENGINE_ART, artifact_dir, 'windows-x64', 'gen_snapshot.exe')
    if not os.path.exists(gs):
        print('  [skip] gen_snapshot 缺失:', gs)
        return False
    out_dir = os.path.join(out_root, abi)
    os.makedirs(out_dir, exist_ok=True)
    out_so = os.path.join(out_dir, 'libapp.so')
    if os.path.exists(out_so):
        try:
            os.remove(out_so)
        except OSError:
            pass
    cmd = [gs,
           '--snapshot_kind=app-aot-elf',
           '--elf=' + out_so,
           '--strip',
           DILL]
    t0 = time.time()
    r = subprocess.run(cmd, capture_output=True, text=True)
    dt = time.time() - t0
    ok = r.returncode == 0 and os.path.exists(out_so)
    print('  [%s] rc=%d %.1fs size=%s' % (
        abi, r.returncode, dt,
        ('%.1f MB' % (os.path.getsize(out_so) / 1048576.0)) if ok else '-'))
    if not ok:
        msg = (r.stderr or '') or (r.stdout or '')
        for line in msg.splitlines()[:12]:
            print('       |', line)
    return ok


def main():
    out_root = os.path.join(PROJ, 'build', 'jniLibs')
    print('DILL      =', DILL, os.path.exists(DILL))
    print('OUT_ROOT  =', out_root)
    print('-' * 60)
    results = {}
    for art, abi in ABIS:
        results[abi] = build_one(art, abi, out_root)
    print('-' * 60)
    for k, v in results.items():
        print('  %-14s %s' % (k, 'OK' if v else 'FAILED'))
    return 0 if all(results.values()) else 1


if __name__ == '__main__':
    sys.exit(main())
