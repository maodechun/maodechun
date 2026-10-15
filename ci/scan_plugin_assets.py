"""盘点各插件模块的 android/res 资源与 AndroidManifest。"""
import json
import os

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
PROJ = os.path.join(ROOT, 'bodhi_token')
DART_TOOL = os.path.join(PROJ, '.dart_tool')
cfg = json.load(open(os.path.join(DART_TOOL, 'package_config.json'), encoding='utf-8'))


def to_path(uri):
    u = uri
    if u.startswith('file:///'):
        u = u[8:]
        if not (len(u) > 1 and u[1] == ':'):
            u = '/' + u
        return os.path.abspath(u)
    if u.startswith('file://'):
        return os.path.abspath(u[7:])
    return os.path.abspath(os.path.join(DART_TOOL, uri.replace('/', os.sep)))


res_total = 0
res_mods = 0
manifest_mods = []
for p in cfg['packages']:
    d = to_path(p['rootUri'])
    ad = os.path.join(d, 'android')
    if not os.path.isdir(ad):
        continue
    res = os.path.join(ad, 'res')
    if os.path.isdir(res):
        n = sum(len(f) for _, _, f in os.walk(res))
        if n:
            print('  res  %-36s %4d files' % (p['name'], n))
            res_total += n
            res_mods += 1
    mf = os.path.join(ad, 'src', 'main', 'AndroidManifest.xml')
    if os.path.isfile(mf):
        manifest_mods.append((p['name'], mf))

print('--- modules with res:', res_mods, 'total res files:', res_total)
print('--- modules with AndroidManifest:', len(manifest_mods))
for n, m in manifest_mods:
    print('    %-36s %s' % (n, os.path.relpath(m, ROOT)))

out = os.path.join(PROJ, 'build', 'plugin_android_assets.json')
os.makedirs(os.path.dirname(out), exist_ok=True)
with open(out, 'w', encoding='utf-8') as f:
    json.dump({
        'resModules': res_mods,
        'resFiles': res_total,
        'manifests': [{'name': n, 'path': m} for n, m in manifest_mods],
    }, f, indent=2, ensure_ascii=False)
print('wrote', out)
