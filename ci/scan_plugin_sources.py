"""盘点插件 android 目录里的源文件构成。"""
import json
import os

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
PROJ = os.path.join(ROOT, 'bodhi_token')
CFG = os.path.join(PROJ, '.dart_tool', 'package_config.json')

cfg = json.load(open(CFG, encoding='utf-8'))
DART_TOOL = os.path.join(PROJ, '.dart_tool')


def to_path(uri):
    """package_config.json 里的 rootUri 多为相对 .dart_tool 的相对路径。"""
    u = uri
    if u.startswith('file:///'):
        u = u[8:]
        if not (len(u) > 1 and u[1] == ':'):
            u = '/' + u
        return os.path.abspath(u)
    if u.startswith('file://'):
        return os.path.abspath(u[7:])
    # 相对路径：以 .dart_tool 为基准
    return os.path.abspath(os.path.join(DART_TOOL, u.replace('/', os.sep)))


rows = []
for p in cfg['packages']:
    d = to_path(p['rootUri'])
    ad = os.path.join(d, 'android')
    if not os.path.isdir(ad):
        continue
    java = []
    kt = []
    aidl = []
    for dp, _, fns in os.walk(ad):
        for fn in fns:
            f = os.path.join(dp, fn)
            if fn.endswith('.java'):
                java.append(f)
            elif fn.endswith('.kt'):
                kt.append(f)
            elif fn.endswith('.aidl'):
                aidl.append(f)
    if java or kt or aidl:
        rows.append((p['name'], len(java), len(kt), len(aidl), java, kt, aidl))

rows.sort(key=lambda r: -(r[1] + r[2]))
print('%-34s %5s %5s %5s' % ('plugin', 'java', 'kt', 'aidl'))
print('-' * 56)
tj = tk = ta = 0
for n, j, k, a, _, _, _ in rows:
    print('%-34s %5d %5d %5d' % (n, j, k, a))
    tj += j
    tk += k
    ta += a
print('-' * 56)
print('%-34s %5d %5d %5d   TOTAL %d' % ('TOTAL', tj, tk, ta, tj + tk + ta))
print('plugins with sources:', len(rows))

# 落盘清单，供后续编译脚本消费
out = os.path.join(PROJ, 'build', 'plugin_sources.json')
os.makedirs(os.path.dirname(out), exist_ok=True)
data = [{'name': n, 'java': j, 'kt': k, 'aidl': a} for n, j, k, a, _, _, _ in rows]
with open(out, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
print('wrote', out)
