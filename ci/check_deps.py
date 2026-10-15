# -*- coding: utf-8 -*-
"""校验 bodhi_token 的 pubspec 与 Dart import 是否完全对齐"""
import io, os, re, sys
import yaml

os.chdir(r'C:\Users\Administrator\WorkBuddy\2026-10-13-20-18-48\bodhi_token')

pub = yaml.safe_load(io.open('pubspec.yaml', encoding='utf-8'))
pkgs = set(pub.get('dependencies', {}).keys())
pkgs |= set(pub.get('dev_dependencies', {}).keys())
pkgs |= {'flutter', 'flutter_test'}

root = 'lib'
local = set()
for dp, dn, fn in os.walk(root):
    for f in fn:
        if f.endswith('.dart'):
            local.add(os.path.relpath(os.path.join(dp, f), root).replace(os.sep, '/'))

missing_local, undeclared, used = [], [], set()
for dp, dn, fn in os.walk(root):
    for f in fn:
        if not f.endswith('.dart'):
            continue
        p = os.path.join(dp, f)
        base = os.path.relpath(dp, root).replace(os.sep, '/')
        src = io.open(p, encoding='utf-8').read()
        for m in re.finditer(r"^import\s+'([^']+)'", src, re.M):
            imp = m.group(1)
            if imp.startswith('dart:'):
                continue
            if imp.startswith('package:'):
                name = imp.split('/')[0].replace('package:', '')
                used.add(name)
                if name not in pkgs:
                    undeclared.append((p.replace(os.sep, '/'), imp))
            else:
                t = os.path.normpath(os.path.join(base, imp)).replace(os.sep, '/')
                if t not in local:
                    missing_local.append((p.replace(os.sep, '/'), imp, t))

print('=' * 58)
print('  依赖对齐检查')
print('=' * 58)
print('  pubspec 声明依赖数 :', len([k for k in pub.get('dependencies', {}) if k != 'flutter']))
print('  代码实际使用的包   :', len(used))
print()
print('  本地相对 import 缺失 :', '无 ✅' if not missing_local else missing_local)
print('  未声明的 package     :', '无 ✅' if not undeclared else '')
for x in undeclared:
    print('      ❌', x[0], '->', x[1])
print()
unused = sorted(k for k in pkgs - used
                if k not in ('flutter', 'flutter_test', 'flutter_lints'))
print('  声明但未直接 import 的依赖（可能通过传递依赖或暂未启用）:')
for u in unused:
    print('      -', u)
print()
ok = not missing_local and not undeclared
print('  结论:', '✅ 通过，可以构建' if ok else '❌ 存在阻塞问题')
sys.exit(0 if ok else 1)
