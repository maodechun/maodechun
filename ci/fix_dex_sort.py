"""修复 dex 的 class_defs 排序（必须按 class_idx 升序，ART 靠二分查找定位类）。

背景：d8 以多 jar 混合输入时，产出的 class_defs 不保证按 class_idx 有序，
而 ART 的 FindClassDef 用二分查找 → 已定义的类会报 ClassNotFoundException
（真机表现：启动秒退、无弹窗）。

class_defs 是 dex 中唯一不被其他结构按位置索引的表，可安全原地重排。
重排后必须重算 SHA-1 签名（offset 12..32）与 adler32 校验和（offset 8）。

输入：build/dex/classes.zip 内的 classes.dex（与散装的 build/dex/classes.dex）
输出：原地更新这两个文件。
"""
import os
import struct
import zipfile
import zlib

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
PROJ = os.path.join(ROOT, 'bodhi_token')
DEXDIR = os.path.join(PROJ, 'build', 'dex')


def fix_dex(d: bytes) -> bytes:
    d = bytearray(d)
    ss, so = struct.unpack_from('<II', d, 0x38)
    ts, to = struct.unpack_from('<II', d, 0x40)
    cs, co = struct.unpack_from('<II', d, 0x60)

    # --- 修复 1：superclass_idx 越界的 class_def（索引串位的损坏记录）---
    def uleb(buf, off):
        r = 0; s = 0
        while True:
            b = buf[off]; off += 1
            r |= (b & 0x7f) << s
            if not b & 0x80: break
            s += 7
        return r, off

    def get_string(idx):
        off = struct.unpack_from('<I', d, so + idx*4)[0]
        ln, off = uleb(d, off)
        return d[off:off+ln]

    obj_idx = None
    for i in range(ts):
        si = struct.unpack_from('<I', d, to + i*4)[0]
        if get_string(si) == b'Ljava/lang/Object;':
            obj_idx = i
            break
    if obj_idx is None:
        raise SystemExit('!! 找不到 Ljava/lang/Object; 的 type_idx')

    repaired = 0
    for i in range(cs):
        off = co + i*32
        sidx = struct.unpack_from('<I', d, off+4)[0]
        if sidx != 0xFFFFFFFF and sidx >= ts:
            struct.pack_into('<I', d, off+4, obj_idx)
            repaired += 1
    if repaired:
        print('   修复 superclass_idx 越界: %d 处 -> Object(type_idx=%d)' % (repaired, obj_idx))

    # --- 修复 2：class_defs 按 class_idx 升序重排（ART 二分查找要求）---
    defs = []
    for i in range(cs):
        rec = d[co + i * 32: co + (i + 1) * 32]
        cls_idx = struct.unpack_from('<I', rec, 0)[0]
        defs.append((cls_idx, rec))
    bad = sum(1 for i in range(1, cs) if defs[i][0] < defs[i - 1][0])
    print('   class_defs:', cs, '乱序处:', bad)
    if bad:
        defs.sort(key=lambda t: t[0])
        dups = sum(1 for i in range(1, cs) if defs[i][0] == defs[i - 1][0])
        if dups:
            raise SystemExit('!! 发现重复 class_idx: %d 个，中止' % dups)
        payload = b''.join(rec for _, rec in defs)
        d = bytearray(d[:co] + payload + d[co + cs * 32:])
        print('   已重排')

    if repaired == 0 and bad == 0:
        print('   已有序且无损坏，无需修复')
        return bytes(d)

    # 重算 SHA-1 signature（offset 32..end → 写入 12..32）
    import hashlib
    sig = hashlib.sha1(bytes(d[32:])).digest()
    struct.pack_into('<20s', d, 12, sig)
    # 重算 adler32（offset 12..end → 写入 8..12）
    csum = zlib.adler32(bytes(d[12:])) & 0xFFFFFFFF
    struct.pack_into('<I', d, 8, csum)
    print('   已更新签名/校验和')
    return bytes(d)


def main():
    zip_path = os.path.join(DEXDIR, 'classes.zip')
    loose = os.path.join(DEXDIR, 'classes.dex')

    # 1) 修 zip 里的
    with zipfile.ZipFile(zip_path) as z:
        dex = z.read('classes.dex')
    fixed = fix_dex(dex)
    tmp = zip_path + '.tmp'
    with zipfile.ZipFile(tmp, 'w', zipfile.ZIP_DEFLATED) as z:
        z.writestr('classes.dex', fixed)
    os.replace(tmp, zip_path)
    print('classes.zip 已更新')

    # 2) 修散装的（保持两者一致）
    if os.path.isfile(loose):
        with open(loose, 'rb') as f:
            dex2 = f.read()
        fixed2 = fix_dex(dex2)
        with open(loose, 'wb') as f:
            f.write(fixed2)
        print('classes.dex 已更新')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
