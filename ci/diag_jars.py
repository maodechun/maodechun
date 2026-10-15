"""诊断：列出 build_dex 实际会喂给 d8 的所有输入，并校验每个 jar/aar 是否可用。"""
import json
import os
import zipfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
PROJ = os.path.join(ROOT, 'bodhi_token')
BUILD = os.path.join(PROJ, 'build')
LIBS = os.path.join(BUILD, 'deps', 'libs')
CLOSURE = os.path.join(BUILD, 'runtime_closure.json')

MANUAL = {
    'androidx.webkit:webkit': 'androidx.webkit__webkit.jar',
    'androidx.preference:preference': 'androidx.preference__preference.jar',
    'androidx.browser:browser': 'androidx.browser__browser.jar',
    'androidx.camera:camera-extensions': 'androidx.camera__camera-extensions.jar',
    'net.zetetic:sqlcipher-android': 'net.zetetic__sqlcipher-android.jar',
    'androidx.sqlite:sqlite': 'androidx.sqlite__sqlite.jar',
    'androidx.datastore:datastore-preferences-core-jvm':
        'androidx.datastore__datastore-preferences-core-jvm.jar',
    'androidx.datastore:datastore-core-android':
        'androidx.datastore__datastore-core-android.jar',
    'androidx.datastore:datastore-preferences-android':
        'androidx.datastore__datastore-preferences-android.jar',
}


def pick_in_dir(d):
    if not d or not os.path.isdir(d):
        return None
    cands = [f for f in os.listdir(d)
             if (f.endswith('.jar') or f.endswith('.aar'))
             and 'sources' not in f and 'javadoc' not in f]
    if not cands:
        return None
    cands.sort(key=lambda f: (0 if f.endswith('.aar') else 1, f))
    return os.path.join(d, cands[0])


def classify(path):
    """返回 (有无 class, 有无 dex, 有无 knm, 条目数)"""
    try:
        with zipfile.ZipFile(path) as z:
            names = z.namelist()
    except Exception as e:
        return ('ERR', str(e), '', 0)
    has_class = any(n.endswith('.class') for n in names)
    has_dex = any(n.endswith('.dex') for n in names)
    has_knm = any(n.endswith('.knm') for n in names)
    return (has_class, has_dex, has_knm, len(names))


data = json.load(open(CLOSURE, encoding='utf-8'))
rows = []
used = set()

for item in data['resolved']:
    g, a, d = item['group'], item['artifact'], item['dir']
    p = pick_in_dir(d)
    if p:
        rows.append((g + ':' + a, p))
        used.add(g + ':' + a)

for key, fn in MANUAL.items():
    if key in used:
        continue
    p = os.path.join(LIBS, fn)
    if os.path.isfile(p):
        rows.append((key, p))
        used.add(key)

fj = os.path.join(LIBS, '__flutter__flutter_embedding.jar')
if os.path.isfile(fj):
    rows.append(('flutter:embedding', fj))

print('total inputs:', len(rows))
print()
print('%-58s %-6s %-5s %-5s %6s' % ('artifact', 'class', 'dex', 'knm', 'entries'))
print('-' * 90)
problems = []
for key, p in rows:
    c, d, k, n = classify(p)
    ext = os.path.splitext(p)[1]
    flag = ''
    if c == 'ERR':
        flag = '  <<< BROKEN'
        problems.append((key, p, d))
    elif d is True:
        flag = '  <<< HAS DEX'
        problems.append((key, p, 'contains .dex'))
    elif c is False and k is False:
        flag = '  <<< EMPTY/NODATA'
        problems.append((key, p, 'no class & no knm'))
    print('%-58s %-6s %-5s %-5s %6d%s' % (
        (key[:56] + '..' if len(key) > 58 else key),
        str(c), str(d), str(k), n, flag))
    print('    ' + os.path.basename(p) + '  [' + ext + ']')

print()
print('=== problems ===')
for key, p, why in problems:
    print('  ', key, '->', why)
    print('     ', p)
