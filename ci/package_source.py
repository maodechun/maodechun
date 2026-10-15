#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
安全源码打包器 —— 菩提护令

用途：生成可对外分享的源码包（.tar.gz），并**强制**保证包内不含密钥样本。

为什么需要它：
    测试期用过的真实/样例迁移 URI、二维码截图如果被误打进源码包，
    等于把用户的 TOTP 密钥公开出去。手工敲 tar 容易漏 --exclude，
    因此把「排除 + 扫描 + 校验」固化成脚本。

行为：
    1. 打包前扫描工程（排除 .git / build / .dart_tool），
       查找 TOTP 密钥载体：
         · 含 `otpauth-migration://offline?data=<>=40 字符> ` 的文本
         · `otpauth://totp/...?secret=<Base32>` 形式的明文
         · 常见密钥/签名文件（*.jks / key.properties / *.bodhi / *.bodhibak）
       发现即中止，不做打包。
    2. 以固定排除清单打包（build/、.dart_tool/、android/ 生成物等）。
    3. 打包后复查包内清单，确认黑名单路径一个都不在，否则删除产物并报错。

用法：
    python ci/package_source.py <输出路径.tar.gz> [--keep-git]
"""

import io
import os
import re
import sys
import tarfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 永不入库的路径前缀（相对工程根）
EXCLUDE_PREFIXES = (
    'build/', '.dart_tool/', '.git/', 'android/', '__pycache__/',
    'ios/', 'linux/', 'macos/', 'windows/', 'web/',
    '.idea/', '.vscode/',
)

# 密钥样本：文件名命中即视为危险
DANGEROUS_NAMES = (
    'real_uri.txt', 'migration_uri.txt', 'migration_batches.txt',
    'real_qr_crop.png', 'real_crop_a.png', 'real_crop_b.png',
    'key.properties', 'keystore.properties', 'secrets.properties',
)

DANGEROUS_EXTS = ('.jks', '.keystore', '.bodhi', '.bodhibak', '.b64')

# 内容指纹：
#  1) 含完整迁移数据的迁移 URI
#  2) otpauth 明文 secret
#  3) 签名凭据（storePassword / keyPassword 被赋了真实值）
#     只匹配「看起来像真口令」的值：ASCII、≥6 位、不以 $ 或 < 开头，
#     因此文档里的占位符（你的密码）与 CI 变量（$KEYSTORE_PASSWORD）不会误报。
SECRET_PATTERNS = (
    re.compile(rb'otpauth-migration://offline\?data=[A-Za-z0-9+/=_%-]{40,}'),
    re.compile(rb'otpauth://[a-z]+/[^\s"?]*\?[^\s"?]*secret=[A-Z2-7]{16,}'),
    re.compile(rb'(?:store|key)Password\s*=\s*'
               rb'(?!keystoreProperties|props\b|getProperty)'
               rb'[A-Za-z0-9_@#!.\-]{6,}'),
    re.compile(rb'ks-pass\s*[:=]\s*pass:[^\s\'"]{6,}'),
    re.compile(rb'BodhiToken20\d\d'),
)

SCAN_SKIP_EXTS = (
    '.png', '.jpg', '.jpeg', '.gif', '.webp', '.ico', '.apk', '.aab',
    '.so', '.dex', '.jar', '.zip', '.gz', '.ttf', '.otf', '.woff', '.woff2',
    '.class', '.pdf',
)

MAX_SCAN_BYTES = 8 * 1024 * 1024

# 不入包的本地噪音（构建日志等；非源码，体积与路径信息都无必要）
EXCLUDE_FILES = ('build_asm_c.log',)
EXCLUDE_SUFFIXES = ('.log', '.tmp', '.bak', '.orig')


def _iter_files():
    """遍历工程内可扫描的文本文件（跳过排除目录与二进制扩展名）。"""
    for dirpath, dirnames, filenames in os.walk(ROOT):
        rel_dir = os.path.relpath(dirpath, ROOT).replace('\\', '/')
        if rel_dir == '.':
            rel_dir = ''
        # 剪枝：整体排除的目录
        dirnames[:] = [
            d for d in dirnames
            if (rel_dir + '/' + d).lstrip('/') + '/' not in EXCLUDE_PREFIXES
            and d not in ('.git', 'build', '.dart_tool', '__pycache__')
        ]
        for fn in filenames:
            rel = (rel_dir + '/' + fn).lstrip('/')
            if any(rel.startswith(p) for p in EXCLUDE_PREFIXES):
                continue
            if fn.lower().endswith(SCAN_SKIP_EXTS):
                continue
            yield rel, os.path.join(dirpath, fn)


def scan_for_secrets():
    """返回 (危险文件列表, 内容命中列表)。"""
    name_hits, content_hits = [], []
    for rel, abspath in _iter_files():
        base = os.path.basename(rel)
        if base in DANGEROUS_NAMES or base.lower().endswith(DANGEROUS_EXTS):
            name_hits.append(rel)
            continue
        try:
            if os.path.getsize(abspath) > MAX_SCAN_BYTES:
                continue
            with open(abspath, 'rb') as f:
                blob = f.read()
        except OSError:
            continue
        for pat in SECRET_PATTERNS:
            m = pat.search(blob)
            if m:
                content_hits.append((rel, len(m.group(0))))
                break
    return name_hits, content_hits


def build_tar(out_path, keep_git=False):
    prefixes = EXCLUDE_PREFIXES if keep_git else EXCLUDE_PREFIXES + ('.git/',)

    def _filter(tarinfo):
        name = tarinfo.name.replace('\\', '/').lstrip('./')
        if not name:
            return None
        if any(name.startswith(p) or name == p.rstrip('/') for p in prefixes):
            return None
        # 任意层级的 __pycache__ / 字节码缓存不入包（可能含旧口令副本）
        if '__pycache__' in name.split('/') or name.endswith('.pyc'):
            return None
        # 本地噪音（构建日志等）
        if name.lower().endswith(EXCLUDE_SUFFIXES):
            return None
        if os.path.basename(name) in DANGEROUS_NAMES:
            return None
        if not keep_git and '/.git' in ('/' + name):
            return None
        return tarinfo

    with tarfile.open(out_path, 'w:gz') as tf:
        for entry in sorted(os.listdir(ROOT)):
            full = os.path.join(ROOT, entry)
            rel = entry + ('/' if os.path.isdir(full) else '')
            if any(rel.startswith(p) for p in prefixes):
                continue
            tf.add(full, arcname=entry, filter=_filter)


def verify_tar(out_path):
    """复查包内清单：黑名单路径与密钥文件一个都不能有。"""
    bad = []
    with tarfile.open(out_path, 'r:gz') as tf:
        names = tf.getnames()
        for n in names:
            clean = n.replace('\\', '/').lstrip('./')
            if any(clean.startswith(p) for p in ('build/', '.git/', 'android/')):
                bad.append(n)
            if '__pycache__' in clean.split('/') or clean.endswith('.pyc'):
                bad.append(n)
            if clean.lower().endswith(EXCLUDE_SUFFIXES):
                bad.append(n)
            if os.path.basename(clean) in DANGEROUS_NAMES:
                bad.append(n)
        # 内容复查
        for m in tf.getmembers():
            if not m.isfile() or m.size > MAX_SCAN_BYTES:
                continue
            if m.name.lower().endswith(SCAN_SKIP_EXTS):
                continue
            try:
                blob = tf.extractfile(m).read()
            except Exception:
                continue
            for i, pat in enumerate(SECRET_PATTERNS):
                if pat.search(blob):
                    tag = '完整迁移 URI' if i == 0 else (
                        '明文 secret' if i == 1 else '签名凭据')
                    bad.append(m.name + '  <含%s>' % tag)
                    break
    return len(names), bad


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    if not args:
        print('用法: python ci/package_source.py <输出.tar.gz> [--keep-git]')
        return 1
    out_path = os.path.abspath(args[0])
    keep_git = '--keep-git' in sys.argv

    print('· 扫描工程内密钥载体 …')
    name_hits, content_hits = scan_for_secrets()
    if name_hits or content_hits:
        print('')
        print('!! 中止打包：发现密钥载体，请先移除后再打包')
        for p in name_hits:
            print('   [文件名] %s' % p)
        for p, ln in content_hits:
            print('   [内容]   %s  (匹配 %d 字节)' % (p, ln))
        print('')
        print('提示：真实/样例迁移 URI、二维码截图请放在工程目录之外的临时路径。')
        return 2
    print('  未发现密钥载体（文件名 / 内容双检）')

    print('· 打包（强制排除 build/ .dart_tool/ android/ …）…')
    build_tar(out_path, keep_git=keep_git)

    total, bad = verify_tar(out_path)
    size = os.path.getsize(out_path)
    print('· 产物 %s  (%d 条目, %.1f KB)' % (out_path, total, size / 1024.0))
    if bad:
        os.remove(out_path)
        print('')
        print('!! 已删除产物：包内发现不允许的内容')
        for b in bad[:20]:
            print('   %s' % b)
        return 3
    print('  包内校验通过：无 build/、无 .git（除非 --keep-git）、无密钥样本')
    return 0


if __name__ == '__main__':
    sys.exit(main())
