"""从种子依赖出发，解析 Gradle 缓存里的 .pom，算出运行时依赖闭包。

Gradle 缓存结构：
  <group>/<artifact>/<version>/<hash>/<artifact>-<version>.pom
pom 里的 <dependencies> 声明了传递依赖。递归即可得到闭包。
"""
import json
import os
import re
import xml.etree.ElementTree as ET

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
PROJ = os.path.join(ROOT, 'bodhi_token')
GC = os.path.join(os.path.expanduser('~'), '.gradle', 'caches', 'modules-2', 'files-2.1')
SEED_FILE = os.path.join(PROJ, 'build', 'runtime_deps.json')
OUT = os.path.join(PROJ, 'build', 'runtime_closure.json')

NS = '{http://maven.apache.org/POM/4.0.0}'


def iter_artifacts():
    """遍历缓存，产出 (group, artifact, version, dir)。"""
    if not os.path.isdir(GC):
        return
    for group in os.listdir(GC):
        gdir = os.path.join(GC, group)
        if not os.path.isdir(gdir):
            continue
        for art in os.listdir(gdir):
            adir = os.path.join(gdir, art)
            if not os.path.isdir(adir):
                continue
            for ver in os.listdir(adir):
                vdir = os.path.join(adir, ver)
                if not os.path.isdir(vdir):
                    continue
                for h in os.listdir(vdir):
                    hdir = os.path.join(vdir, h)
                    if os.path.isdir(hdir):
                        yield group, art, ver, hdir


print('scanning gradle cache ...')
index = {}
for g, a, v, h in iter_artifacts():
    index.setdefault((g, a), []).append((v, h))
print('cache artifacts:', len(index))


def pick_dir(group, artifact):
    items = index.get((group, artifact))
    if not items:
        return None, None
    # 优先取版本号最高的
    def key(t):
        parts = []
        for seg in t[0].replace('-', '.').split('.'):
            parts.append((0, int(seg), '') if seg.isdigit() else (1, 0, seg))
        return parts
    items = sorted(items, key=key)
    return items[-1]


def load_pom(group, artifact):
    ver, hdir = pick_dir(group, artifact)
    if not hdir:
        return None, None
    for fn in os.listdir(hdir):
        if fn.endswith('.pom'):
            try:
                return ET.parse(os.path.join(hdir, fn)).getroot(), ver
            except Exception:
                return None, ver
    return None, ver


def deps_of(root):
    out = []
    if root is None:
        return out
    for deps in root.iter(NS + 'dependencies'):
        for d in deps.findall(NS + 'dependency'):
            g = d.findtext(NS + 'groupId')
            a = d.findtext(NS + 'artifactId')
            scope = (d.findtext(NS + 'scope') or 'compile').strip()
            optional = (d.findtext(NS + 'optional') or 'false').strip()
            if not g or not a:
                continue
            if scope in ('test', 'provided', 'system'):
                continue
            if optional == 'true':
                continue
            out.append((g, a))
    return out


seeds = json.load(open(SEED_FILE, encoding='utf-8'))['coordinates']
seeds = [tuple(s.split(':')) for s in seeds]

seen = {}
queue = list(seeds)
while queue:
    g, a = queue.pop(0)
    key = (g, a)
    if key in seen:
        continue
    seen[key] = True
    root, ver = load_pom(g, a)
    if root is None:
        print('  [no pom]', g + ':' + a)
        continue
    for dg, da in deps_of(root):
        if (dg, da) not in seen:
            queue.append((dg, da))

print('\nclosure size:', len(seen))
resolved = []
missing = []
for g, a in sorted(seen):
    ver, hdir = pick_dir(g, a)
    if hdir:
        resolved.append({'group': g, 'artifact': a, 'version': ver, 'dir': hdir})
    else:
        missing.append(g + ':' + a)

print('resolved:', len(resolved), '| missing:', len(missing))
for m in missing:
    print('  [MISS]', m)

with open(OUT, 'w', encoding='utf-8') as f:
    json.dump({'resolved': resolved, 'missing': missing}, f,
              indent=2, ensure_ascii=False)
print('wrote', OUT)
