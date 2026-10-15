# -*- coding: utf-8 -*-
"""
pub_fetch.py —— 轻量 pub 依赖解析与下载器

用途：在 flutter pub get 无法运行的环境中，手动完成依赖解析与下载，
     产出 .dart_tool/package_config.json。

工作方式：
  1. 读取项目 pubspec.yaml 的 dependencies
  2. 递归解析每个依赖（含传递依赖），按版本约束选版本
  3. 从 pub.flutter-io.cn 下载 tar.gz 并解开到 PUB_CACHE
  4. 生成 package_config.json（含 flutter SDK 包）

注意：这是简化实现，覆盖语义化版本约束的常见形式（^x.y.z、>=x <y、any）。
"""
import io
import json
import os
import re
import shutil
import sys
import tarfile
import time
import urllib.request
import urllib.parse

PUB_HOST = os.environ.get('PUB_HOSTED_URL', 'https://pub.flutter-io.cn').rstrip('/')
PUB_CACHE = os.environ.get(
    'PUB_CACHE',
    os.path.join(os.path.expanduser('~'), 'AppData', 'Local', 'Pub', 'Cache'),
)
CACHE_HOST_DIR = os.path.join(PUB_CACHE, 'hosted', 'pub.flutter-io.cn')
FLUTTER_ROOT = os.environ.get('FLUTTER_ROOT', '')


# ────────────────────────────── 版本处理 ──────────────────────────────

def parse_version(v):
    """'1.2.3-beta.1+5' -> (1,2,3) 用于比较（忽略预发布后缀，简化处理）"""
    core = re.split(r'[-+]', str(v))[0]
    parts = []
    for p in core.split('.'):
        try:
            parts.append(int(p))
        except ValueError:
            parts.append(0)
    while len(parts) < 3:
        parts.append(0)
    return tuple(parts[:3])


def ver_str(t):
    return '.'.join(str(x) for x in t)


class Constraint:
    """简化版版本约束"""

    def __init__(self, raw):
        self.raw = str(raw).strip()
        self.any = False
        self.mins = []      # (version_tuple, inclusive)
        self.maxs = []      # (version_tuple, inclusive)
        self.exact = None
        self._parse()

    def _parse(self):
        s = self.raw
        if s in ('any', '', 'null'):
            self.any = True
            return
        # 去掉引号
        s = s.strip('\'"')
        # ^x.y.z
        for m in re.finditer(r'\^([\w.+-]+)', s):
            base = parse_version(m.group(1))
            self.mins.append((base, True))
            # caret: 上限 = 首个非零位进位
            major, minor = base[0], base[1]
            if major > 0:
                self.maxs.append(((major + 1, 0, 0), False))
            else:
                self.maxs.append(((0, minor + 1, 0), False))
            return
        # >=x.y.z / >x.y.z / <=x.y.z / <x.y.z
        found = False
        for m in re.finditer(r'(>=|<=|>|<)\s*([\w.+-]+)', s):
            op, ver = m.group(1), parse_version(m.group(2))
            if op == '>=':
                self.mins.append((ver, True))
            elif op == '>':
                self.mins.append((ver, False))
            elif op == '<=':
                self.maxs.append((ver, True))
            elif op == '<':
                self.maxs.append((ver, False))
            found = True
        if found:
            return
        # 纯版本 = 精确匹配
        if re.fullmatch(r'[\d.]+', s):
            self.exact = parse_version(s)
            return
        self.any = True

    def allows(self, v):
        vt = parse_version(v)
        if self.exact is not None:
            return vt == self.exact
        if self.any:
            return True
        for ver, inc in self.mins:
            if vt < ver or (vt == ver and not inc):
                return False
        for ver, inc in self.maxs:
            if vt > ver or (vt == ver and not inc):
                return False
        return True

    def __repr__(self):
        return f'Constraint({self.raw!r})'


# ────────────────────────────── pubspec 解析 ──────────────────────────────

def load_pubspec(path):
    """读取 pubspec.yaml，优先用 PyYAML，退化到轻量解析"""
    txt = io.open(path, encoding='utf-8').read()
    try:
        import yaml
        data = yaml.safe_load(txt)
        if isinstance(data, dict):
            return data
    except Exception:
        pass
    return parse_yaml_lite(txt)


def parse_yaml_lite(txt):
    """支持 2 空格缩进的 map / list，够用即可"""
    lines = []
    for raw in txt.splitlines():
        if not raw.strip() or raw.lstrip().startswith('#'):
            continue
        indent = len(raw) - len(raw.lstrip(' '))
        lines.append((indent, raw.strip()))

    def parse_block(idx, indent):
        """返回 (value, next_idx)"""
        if idx >= len(lines):
            return {}, idx
        if lines[idx][1].startswith('- '):
            items = []
            while idx < len(lines) and lines[idx][0] == indent and lines[idx][1].startswith('- '):
                items.append(lines[idx][1][2:].strip().strip('\'"'))
                idx += 1
            return items, idx
        obj = {}
        while idx < len(lines) and lines[idx][0] == indent and not lines[idx][1].startswith('- '):
            content = lines[idx][1]
            if ':' in content:
                key, _, val = content.partition(':')
                key = key.strip().strip('\'"')
                val = val.strip()
                idx += 1
                if val == '':
                    if idx < len(lines) and lines[idx][0] > indent:
                        sub, idx = parse_block(idx, lines[idx][0])
                        obj[key] = sub
                    else:
                        obj[key] = None
                else:
                    obj[key] = val.strip('\'"')
            else:
                idx += 1
        return obj, idx

    if not lines:
        return {}
    return parse_block(0, lines[0][0])[0]


def extract_deps(pubspec, section='dependencies'):
    """从 pubspec dict 提取 {name: constraint_or_sdk}"""
    out = {}
    deps = pubspec.get(section) or {}
    if isinstance(deps, dict):
        for k, v in deps.items():
            if isinstance(v, dict):
                if 'sdk' in v:
                    out[k] = ('sdk', v['sdk'])
                elif 'path' in v:
                    out[k] = ('path', v['path'])
                elif 'git' in v:
                    out[k] = ('git', v['git'])
                else:
                    out[k] = ('hosted', 'any')
            else:
                out[k] = ('hosted', v if v else 'any')
    return out


# ────────────────────────────── 网络 ──────────────────────────────

def http_json(url, timeout=40):
    req = urllib.request.Request(url, headers={'User-Agent': 'Dart pub 3.0'})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return json.load(r)
        except Exception as e:
            if attempt == 2:
                raise
            time.sleep(2)


def download_file(url, dest, timeout=180):
    req = urllib.request.Request(url, headers={'User-Agent': 'Dart pub 3.0'})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r, open(dest, 'wb') as f:
                shutil.copyfileobj(r, f)
            return True
        except Exception:
            if attempt == 2:
                raise
            time.sleep(2)


# ────────────────────────────── 包获取 ──────────────────────────────

_pkg_meta_cache = {}


def get_package_meta(name):
    if name in _pkg_meta_cache:
        return _pkg_meta_cache[name]
    url = f'{PUB_HOST}/api/packages/{urllib.parse.quote(name)}'
    data = http_json(url)
    _pkg_meta_cache[name] = data
    return data


def pick_version(name, constraint):
    """按约束选择最合适的版本，返回 (version, archive_url, pubspec)"""
    meta = get_package_meta(name)
    versions = meta.get('versions') or []
    if not versions:
        return None
    if isinstance(constraint, str):
        cons = Constraint(constraint)
    else:
        cons = constraint
    # 从高到低找第一个满足约束的，且非预发布
    candidates = []
    for v in versions:
        ver = v.get('version', '')
        if '-' in ver.split('+')[0]:
            continue  # 跳过预发布
        if cons.allows(ver):
            candidates.append(v)
    if not candidates:
        # 放宽：允许预发布
        for v in versions:
            if cons.allows(v.get('version', '')):
                candidates.append(v)
    if not candidates:
        return None
    best = max(candidates, key=lambda x: parse_version(x['version']))
    return best


def ensure_package(name, version, archive_url):
    """确保包已解压到缓存，返回包目录。

    设计原则：只新增、不删除。任何已存在的目录/文件都优先复用，
    避免触发宿主环境的安全删除拦截。
    """
    target = os.path.join(CACHE_HOST_DIR, f'{name}-{version}')
    if os.path.isdir(target) and os.listdir(target):
        return target

    os.makedirs(CACHE_HOST_DIR, exist_ok=True)
    tmp_tar = os.path.join(CACHE_HOST_DIR, f'.{name}-{version}.tar.gz')
    extract_dir = os.path.join(CACHE_HOST_DIR, f'.{name}-{version}.unpack')

    # 若已有完整解包目录但未改名，直接改名复用
    if os.path.isdir(extract_dir) and os.listdir(extract_dir):
        try:
            os.rename(extract_dir, target)
            return target
        except OSError:
            pass

    # 若已有下载好的压缩包则复用，否则下载
    need_download = not (os.path.isfile(tmp_tar) and os.path.getsize(tmp_tar) > 512)
    if need_download:
        download_file(archive_url, tmp_tar)

    os.makedirs(extract_dir, exist_ok=True)
    with tarfile.open(tmp_tar, 'r:gz') as tf:
        for m in tf.getmembers():
            nm = m.name.replace('\\', '/')
            if nm.startswith('/') or '..' in nm.split('/'):
                raise RuntimeError(f'不安全的包路径: {nm}')
        tf.extractall(extract_dir)

    # 解包完成后改名为正式目录（不删除任何东西）
    try:
        os.rename(extract_dir, target)
    except OSError:
        if os.path.isdir(target):
            return target
        raise
    return target


# ────────────────────────────── 主解析 ──────────────────────────────

def resolve(project_dir, verbose=True):
    pubspec_path = os.path.join(project_dir, 'pubspec.yaml')
    root = load_pubspec(pubspec_path)
    root_name = root.get('name', 'app')
    deps = extract_deps(root)

    # dependency_overrides：强制指定版本（与标准 pub 语义一致），
    # 例如把 path_provider_android 钉死在 2.2.10（2.3.x 纯 Dart 实现不可用）
    overrides = extract_deps(root, 'dependency_overrides')

    resolved = {}        # name -> {'version','dir','constraint'}
    queue = list(deps.items()) + list(overrides.items())
    seen = {}

    while queue:
        name, (kind, cons) = queue.pop(0)
        if name in seen:
            continue
        # 覆盖项优先生效：任何来源的依赖约束都被 override 替换
        if name in overrides and name not in (
                'flutter', 'flutter_test', 'sky_engine'):
            kind, cons = overrides[name]
        seen[name] = True

        # sky_engine 是 flutter SDK 内的特殊包，真实位置在 bin/cache/pkg/sky_engine，
        # 而不是 packages/sky_engine。必须最先拦截，否则会被当成 hosted 包解析。
        if name == 'sky_engine':
            sky = os.path.join(FLUTTER_ROOT, 'bin', 'cache', 'pkg', 'sky_engine')
            resolved[name] = {'version': '0.0.0', 'dir': sky, 'sdk': True}
            continue

        if kind == 'sdk':
            # flutter / flutter_test —— 来自 SDK，不下载
            sdk_path = os.path.join(FLUTTER_ROOT, 'packages', name)
            resolved[name] = {
                'version': '0.0.0',
                'dir': sdk_path,
                'sdk': True,
            }
            # 读它的 pubspec 传递依赖
            sub = os.path.join(sdk_path, 'pubspec.yaml')
            if os.path.isfile(sub):
                subdeps = extract_deps(load_pubspec(sub))
                for k, v in subdeps.items():
                    if k not in seen and k not in ('flutter', 'flutter_test'):
                        queue.append((k, v))
            continue

        if kind == 'path':
            p = os.path.join(project_dir, cons)
            resolved[name] = {'version': '0.0.0', 'dir': p, 'path': True}
            sub = os.path.join(p, 'pubspec.yaml')
            if os.path.isfile(sub):
                subdeps = extract_deps(load_pubspec(sub))
                for k, v in subdeps.items():
                    if k not in seen:
                        queue.append((k, v))
            continue

        # hosted
        try:
            info = pick_version(name, cons)
        except Exception as e:
            if verbose:
                print(f'   ! {name}: 元数据获取失败 {e}')
            continue
        if not info:
            if verbose:
                print(f'   ! {name}: 无满足 {cons} 的版本')
            continue
        ver = info['version']
        url = info.get('archive_url')
        if not url:
            continue
        d = ensure_package(name, ver, url)
        resolved[name] = {'version': ver, 'dir': d}
        if verbose:
            print(f'   + {name} {ver}')

        # 传递依赖
        sub_pubspec = os.path.join(d, 'pubspec.yaml')
        if os.path.isfile(sub_pubspec):
            subdeps = extract_deps(load_pubspec(sub_pubspec))
            for k, v in subdeps.items():
                if k not in seen:
                    queue.append((k, v))

    # 生成 package_config.json
    pkgs = []
    # 根项目自身
    pkgs.append({
        'name': root_name,
        'rootUri': '../',
        'packageUri': 'lib/',
        'languageVersion': '3.2',
    })
    for name, info in sorted(resolved.items()):
        if name == root_name:
            continue
        d = info['dir']
        rel = os.path.relpath(d, os.path.join(project_dir, '.dart_tool')).replace('\\', '/')
        version = info['version']
        lang = version
        # 读包 pubspec 的 sdk 约束取语言版本
        try:
            pp = os.path.join(d, 'pubspec.yaml')
            if os.path.isfile(pp):
                ps = load_pubspec(pp)
                env = ps.get('environment') or {}
                sdk = env.get('sdk', '')
                m = re.search(r'(\d+)\.(\d+)', str(sdk))
                if m:
                    lang = f'{m.group(1)}.{m.group(2)}'
        except Exception:
            pass
        ver_final = '$VER$'
        if not info.get('sdk') and not info.get('path'):
            ver_final = version
        pkgs.append({
            'name': name,
            'rootUri': rel,
            'packageUri': 'lib/',
            'languageVersion': lang,
            'version': ver_final,
        })

    out_dir = os.path.join(project_dir, '.dart_tool')
    os.makedirs(out_dir, exist_ok=True)
    out_path = os.path.join(out_dir, 'package_config.json')
    # 注意：必须用 LF 换行、无 BOM、无尾随字符。
    # Dart 的 package_config 解析器遇到 CRLF 会报 "Unexpected trailing character"。
    payload = json.dumps({
        'configVersion': 2,
        'packages': pkgs,
    }, indent=2, ensure_ascii=False)
    with open(out_path, 'wb') as f:
        f.write(payload.encode('utf-8'))

    return resolved, out_path


if __name__ == '__main__':
    proj = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
    print(f'解析项目: {proj}')
    print(f'PUB_HOST: {PUB_HOST}')
    print(f'PUB_CACHE: {PUB_CACHE}')
    print(f'FLUTTER_ROOT: {FLUTTER_ROOT}')
    print('-' * 50)
    resolved, out = resolve(proj)
    print('-' * 50)
    print(f'共解析 {len(resolved)} 个包')
    print(f'package_config.json -> {out}')
