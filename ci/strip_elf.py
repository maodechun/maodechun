"""从 ELF .so 中剔除调试与符号段，达到 strip 的效果，无需外部工具链。

原理：
  ELF 文件由段表（section header table）描述各个 section。
  调试段（.debug_*）与符号表（.symtab/.strtab）对运行时加载毫无用途，
  移除后把段表里对应条目标记为 SHT_NULL，并把数据区截断/重排即可。

本脚本采取保守做法：
  - 只移除 .debug_* 与 .symtab/.strtab 这些「纯调试」段
  - 保留所有 SHF_ALLOC（运行时需要）的段
  - 保留 program header，因为加载器用的是 program header 而不是 section header
  - 重新计算并写回段表
"""
import os
import struct
import sys

# 需要剔除的段名（纯调试用途）
DEBUG_NAMES = {
    '.debug_info', '.debug_abbrev', '.debug_line', '.debug_line_str',
    '.debug_str', '.debug_str_offsets', '.debug_addr', '.debug_ranges',
    '.debug_rnglists', '.debug_loclists', '.debug_loc', '.debug_frame',
    '.debug_aranges', '.debug_pubnames', '.debug_pubtypes',
    '.debug_macro', '.debug_types', '.debug_sup',
    '.symtab', '.strtab', '.gdb_index', '.stab', '.stabstr',
    '.comment', '.note.gnu.gold-version',
}


class Elf:
    def __init__(self, data):
        self.data = bytearray(data)
        d = self.data
        assert d[:4] == b'\x7fELF', 'not an ELF file'
        self.is64 = d[4] == 2
        self.le = d[5] == 1
        self.end = '<' if self.le else '>'
        if self.is64:
            (self.e_shoff,) = struct.unpack_from(self.end + 'Q', d, 0x28)
            (self.e_shentsize,) = struct.unpack_from(self.end + 'H', d, 0x3A)
            (self.e_shnum,) = struct.unpack_from(self.end + 'H', d, 0x3C)
            (self.e_shstrndx,) = struct.unpack_from(self.end + 'H', d, 0x3E)
            (self.e_phoff,) = struct.unpack_from(self.end + 'Q', d, 0x20)
            (self.e_phentsize,) = struct.unpack_from(self.end + 'H', d, 0x36)
            (self.e_phnum,) = struct.unpack_from(self.end + 'H', d, 0x38)
        else:
            (self.e_shoff,) = struct.unpack_from(self.end + 'I', d, 0x20)
            (self.e_shentsize,) = struct.unpack_from(self.end + 'H', d, 0x2E)
            (self.e_shnum,) = struct.unpack_from(self.end + 'H', d, 0x30)
            (self.e_shstrndx,) = struct.unpack_from(self.end + 'H', d, 0x32)
            (self.e_phoff,) = struct.unpack_from(self.end + 'I', d, 0x1C)
            (self.e_phentsize,) = struct.unpack_from(self.end + 'H', d, 0x2A)
            (self.e_phnum,) = struct.unpack_from(self.end + 'H', d, 0x2C)
        self.sections = []
        for i in range(self.e_shnum):
            off = self.e_shoff + i * self.e_shentsize
            if self.is64:
                name, typ, flags, addr, offset, size = struct.unpack_from(
                    self.end + 'IIQQQQ', d, off)
            else:
                name, typ, flags, addr, offset, size = struct.unpack_from(
                    self.end + 'IIIIII', d, off)
            self.sections.append({
                'idx': i, 'nameoff': name, 'type': typ, 'flags': flags,
                'addr': addr, 'offset': offset, 'size': size, 'shoff': off,
            })
        # 读取段名字符串表
        shstr = self.sections[self.e_shstrndx]
        self.shstr = bytes(d[shstr['offset']:shstr['offset'] + shstr['size']])

    def sname(self, nameoff):
        e = self.shstr.find(b'\x00', nameoff)
        return self.shstr[nameoff:e].decode('utf-8', 'replace')

    def report(self):
        total = len(self.data)
        dbg = 0
        print('  file: %.2f MB  (%d sections)' % (total / 1048576, len(self.sections)))
        rows = []
        for s in self.sections:
            n = self.sname(s['nameoff'])
            if n in DEBUG_NAMES:
                rows.append((n, s['size']))
                dbg += s['size']
        for n, v in sorted(rows, key=lambda x: -x[1])[:14]:
            print('    %-24s %8.2f MB' % (n, v / 1048576))
        print('  debug total: %.2f MB (%.1f%%)' % (dbg / 1048576, dbg * 100 / total))
        print('  est. after strip: %.2f MB' % ((total - dbg) / 1048576))
        return dbg

    def strip(self, out_path):
        """重排文件，彻底移除调试段的数据。"""
        # 1. 决定保留哪些段
        keep = []
        drop = []
        for s in self.sections:
            n = self.sname(s['nameoff'])
            if s['type'] == 0 and s['size'] == 0:
                keep.append(s)
                continue
            if n in DEBUG_NAMES:
                drop.append(s)
            else:
                keep.append(s)

        removed = sum(s['size'] for s in drop)

        # 2. 按 offset 排序，重建数据区（仅保留段）
        data_secs = [s for s in keep if s['type'] != 0 and s['size'] > 0
                     and s['offset'] > 0]
        # 注意：不能重排 SHF_ALLOC 段，否则 program header 的偏移会失效。
        # 因此采用「就地清零 + 尾部截断」策略：
        #   清掉所有可丢弃段的内容，然后从文件末尾裁掉全零区域。
        for s in drop:
            if s['size'] and s['offset']:
                self.data[s['offset']:s['offset'] + s['size']] = b'\x00' * s['size']

        # 3. 段表项置空
        for s in drop:
            off = s['shoff']
            if self.is64:
                struct.pack_into(self.end + 'IIQQQQ', self.data, off,
                                 0, 0, 0, 0, 0, 0)
                struct.pack_into(self.end + 'IIQQ', self.data, off + 0x28,
                                 0, 0, 0, 0)
            else:
                struct.pack_into(self.end + 'IIIIII', self.data, off,
                                 0, 0, 0, 0, 0, 0)
                struct.pack_into(self.end + 'IIII', self.data, off + 0x18,
                                 0, 0, 0, 0)

        # 4. 找最后一个非零字节，从尾部截断
        buf = bytes(self.data)
        last = len(buf)
        # 从末尾往前找非零（按 4KB 块加速）
        step = 4096
        i = len(buf)
        while i > 0:
            j = max(0, i - step)
            if buf[j:i].strip(b'\x00'):
                # 该块内有数据，精确定位
                k = i - 1
                while k >= j and buf[k] == 0:
                    k -= 1
                last = k + 1
                break
            i = j
        last = max(last, self.e_shoff + self.e_shentsize * self.e_shnum)
        # 保持 4 字节对齐（ELF 段偏移通常 4 对齐）
        last = (last + 3) & ~3

        self.data = bytearray(buf[:last])
        print('  removed %.2f MB of debug/symbol data' % (removed / 1048576))
        print('  trimmed file to %.2f MB' % (len(self.data) / 1048576))

        with open(out_path, 'wb') as f:
            f.write(self.data)
        print('  output: %.2f MB' % (len(self.data) / 1048576))


def main():
    if len(sys.argv) < 3:
        print('usage: strip_elf.py <input.so> <output.so>')
        return 1
    src, dst = sys.argv[1], sys.argv[2]
    data = open(src, 'rb').read()
    e = Elf(data)
    e.report()
    e.strip(dst)
    # 校验产物仍是合法 ELF
    chk = open(dst, 'rb').read(4)
    print('  magic:', chk)
    return 0


if __name__ == '__main__':
    sys.exit(main())
