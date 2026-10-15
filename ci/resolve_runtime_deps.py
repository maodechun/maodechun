"""从插件的 build.gradle 里解析 dependencies 声明，生成精确的运行时依赖白名单。

这比「排除构建工具链」的黑名单方式可靠：
黑名单只能挡住已知的，白名单能确保只带真正被插件引用的库。
"""
import json
import os
import re

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
PROJ = os.path.join(ROOT, 'bodhi_token')
DART_TOOL = os.path.join(PROJ, '.dart_tool')
OUT = os.path.join(PROJ, 'build', 'runtime_deps.json')

cfg = json.load(open(os.path.join(DART_TOOL, 'package_config.json'), encoding='utf-8'))

# 匹配 implementation/api/compileOnly 'group:artifact:version'
DEP_RE = re.compile(
    r"""^\s*(implementation|api|compileOnly|runtimeOnly|debugImplementation|releaseImplementation)\s*[\(\s]\s*['"]([^'"]+)['"]""",
    re.MULTILINE,
)


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


coords = set()
plugin_files = []
for p in cfg['packages']:
    d = to_path(p['rootUri'])
    ad = os.path.join(d, 'android')
    if not os.path.isdir(ad):
        continue
    for name in ('build.gradle', 'build.gradle.kts'):
        g = os.path.join(ad, name)
        if not os.path.isfile(g):
            continue
        plugin_files.append((p['name'], g))
        txt = open(g, encoding='utf-8', errors='replace').read()
        for m in DEP_RE.finditer(txt):
            coord = m.group(2)
            if coord.startswith('group:'):
                continue
            parts = coord.split(':')
            if len(parts) >= 2:
                coords.add(parts[0] + ':' + parts[1])

print('plugin gradle files:', len(plugin_files))
print('unique coordinates:', len(coords))
for c in sorted(coords):
    print('  ', c)

with open(OUT, 'w', encoding='utf-8') as f:
    json.dump({'coordinates': sorted(coords)}, f, indent=2, ensure_ascii=False)
print('wrote', OUT)
