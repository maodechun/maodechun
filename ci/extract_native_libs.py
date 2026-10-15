# -*- coding: utf-8 -*-
"""抽取依赖 aar 中的 native 库（.so）到 build/jniLibs。

此前的手工打包只抽取了 aar 的 classes.jar（Java 字节码），
漏掉了 aar 内 jni/ 目录下的 native 库，导致运行时
System.loadLibrary("sqlcipher") 失败而闪退。

本脚本补齐：sqlcipher / datastore / camera-core 三个含 native 库的依赖，
按 ABI 抽取到 build/jniLibs。

⚠️ 不再抽取 ML Kit 的 libbarhopper_v3.so：
条码识别已改为原生 CameraX + zxing 实现，ML Kit 相关 jar 也已从 dex 中
排除，barhopper 本地模型（三 ABI 共约 14MB）是无用负载，一律剔除。
"""
import os
import zipfile

ROOT = r'C:\Users\Administrator\WorkBuddy\2026-10-13-20-18-48'
JNILIBS = os.path.join(ROOT, 'bodhi_token', 'build', 'jniLibs')
DEPS = os.path.join(ROOT, 'bodhi_token', 'build', 'deps')
GRADLE = r'C:\Users\Administrator\.gradle\caches\modules-2\files-2.1'

# 只打这三个 ABI（与 build_aot 一致）
ABIS = ['arm64-v8a', 'armeabi-v7a', 'x86_64']

# 明确废弃的 native 库（历史版本遗留，可能残留在 jniLibs 中）
OBSOLETE_SO = ('libbarhopper_v3.so',)

# (aar 绝对路径, 描述)
AARS = [
    (os.path.join(DEPS, 'sqlcipher.aar'), 'sqlcipher'),
    (os.path.join(DEPS, 'androidx.datastore__datastore-core-android.aar'),
     'datastore'),
    (os.path.join(
        GRADLE, 'androidx.camera', 'camera-core', '1.3.4',
        '34dde052e4fc236dee0f66312838040979545dd0',
        'camera-core-1.3.4.aar'), 'camera-core'),
]


def main():
    total = 0
    for aar, name in AARS:
        if not os.path.isfile(aar):
            print('[SKIP] %-14s %s' % (name, aar))
            continue
        with zipfile.ZipFile(aar) as z:
            for info in z.infolist():
                if not info.filename.endswith('.so'):
                    continue
                parts = info.filename.split('/')
                # 形如 jni/<abi>/<name>.so
                if len(parts) < 3 or parts[0] != 'jni':
                    continue
                abi = parts[1]
                if abi not in ABIS:
                    continue
                so_name = parts[-1]
                if so_name in OBSOLETE_SO:
                    continue
                out_dir = os.path.join(JNILIBS, abi)
                os.makedirs(out_dir, exist_ok=True)
                out = os.path.join(out_dir, so_name)
                with z.open(info) as src, open(out, 'wb') as fo:
                    fo.write(src.read())
                total += 1
                print('  [%s] %-24s -> lib/%s/%s  (%d)' % (
                    name, so_name, abi, so_name, os.path.getsize(out)))

    # 清理历史遗留的无用 so（抽取只会新增，不会删除）
    removed = 0
    for abi in ABIS:
        d = os.path.join(JNILIBS, abi)
        if not os.path.isdir(d):
            continue
        for f in sorted(os.listdir(d)):
            if f in OBSOLETE_SO:
                p = os.path.join(d, f)
                try:
                    sz = os.path.getsize(p)
                    os.remove(p)
                    removed += 1
                    print('  [clean] 移除无用 native 库 lib/%s/%s (%d)' % (abi, f, sz))
                except OSError as e:
                    print('  [clean] 失败 lib/%s/%s: %s' % (abi, f, e))

    print('-' * 60)
    print('共抽取 %d 个 native 库，清理 %d 个无用库' % (total, removed))
    for abi in ABIS:
        d = os.path.join(JNILIBS, abi)
        if os.path.isdir(d):
            for f in sorted(os.listdir(d)):
                print('  %-12s %-40s %d' % (abi, f, os.path.getsize(
                    os.path.join(d, f))))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
