"""为每个依赖 aar 生成对应包名的 R 类（库 R）。

背景：published aar 的 classes.jar 本身不含 R 类（由 AGP 在编译期生成），
deps/libs 的 jar 又是从 aar 剥离资源而来，因此 dex 里完全没有
androidx.xxx.R / R$id / R$styleable 等库 R 类，库代码运行时一访问就是
NoClassDefFoundError（如 PreviewView 读 R.styleable.PreviewView）。

做法（两路并集，保证不漏）：
 A. 资源路：以 aapt2 link 生成的 app R.java（合并资源后的最终 ID）为准，
    按 aar 的 AndroidManifest package 属性，把该 aar res/ 中出现过的符号
    （values 类型 + layout/xml 中的 @+id）生成同名同值的库 R 类。
 B. 字节码路：解 aar 的 classes.jar，抽取 class 常量池中的可打印字符串，
    凡是「库自己的字节码里出现过、且 app R 中存在」的字段名一律生成；
    同时按字节码中出现的 `pkg/R$type` 引用确定目标包名。
    —— 这是关键补强：styleable 的数组字段（如 `int[] PreviewView={...}`）
    在 app R.java 里是跨行书写的，逐行解析必然漏，而字节码路直接以
    「代码真正引用了什么」为准，从机制上杜绝此类 NoClassDefFoundError。

输出：build/gen_lib_r/<pkg 路径>/R.java（供 build_dex 一并 javac 进 CLASSES）
"""
import io
import json
import os
import re
import sys
import zipfile
import xml.etree.ElementTree as ET

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
PROJ = os.path.join(ROOT, 'bodhi_token')
CLASSPATH_JSON = os.path.join(PROJ, 'build', 'deps', 'classpath.json')
APP_R = os.path.join(PROJ, 'build', 'gen', 'com', 'daotuo', 'bodhitoken', 'R.java')
OUT_DIR = os.path.join(PROJ, 'build', 'gen_lib_r')

# 逻辑版本：改动生成本身时 +1，用于让 .done.json 缓存失效
LOGIC_VERSION = 3

# 目录名 -> 资源类型
FILE_DIR_TYPES = ('drawable', 'color', 'mipmap', 'raw', 'xml', 'menu',
                  'anim', 'animator', 'interpolator', 'navigation', 'transition', 'layout')

PAT_SECTION = re.compile(r'public static final class (\w+) \{')
PAT_INT = re.compile(r'public static final int\s+(\w+)\s*=\s*([0-9a-fA-Fx]+)\s*;')
PAT_ARR = re.compile(r'public static final int\[\]\s*(\w+)\s*=\s*\{(.*?)\}\s*;', re.S)
PAT_BLOCK_COMMENT = re.compile(r'/\*.*?\*/', re.S)
PAT_LINE_COMMENT = re.compile(r'//[^\n]*')
PAT_PLUS_ID = re.compile(r'@\+id/([\w.]+)')
# 字节码里的可打印字符串（常量池 Utf8 是连续存放的，直接抓可打印串即可）
PAT_ASCII = re.compile(rb'[\x20-\x7e]{3,}')
# 字节码里引用的 R 类：内部形式 'androidx/camera/view/R$styleable'。
# 必须整体锚定，否则描述符里的 .../utils/RetryPolicy 会被误判成包 .../utils。
PAT_R_TOKEN = re.compile(r'^([a-z][a-z0-9_]*(?:/[a-z0-9_]+)*)/R(?:\$[A-Za-z0-9_]+)?$')


def parse_app_r(path):
    """解析 aapt2 生成的 app R.java -> {type: {name: value_str}}

    注意：styleable 的数组字段形如
        public static final int[] PreviewView={
          0x7f04009d, 0x7f0400d5
        };
    是跨行的，必须整文件解析，逐行正则一定漏。
    """
    text = open(path, encoding='utf-8').read()
    text = PAT_BLOCK_COMMENT.sub('', text)
    text = PAT_LINE_COMMENT.sub('', text)

    types = {}
    parts = PAT_SECTION.split(text)
    # parts = [前缀, 类名1, 类体1, 类名2, 类体2, ...]
    for i in range(1, len(parts) - 1, 2):
        cur = parts[i]
        body = parts[i + 1]
        bucket = types.setdefault(cur, {})
        for m in PAT_ARR.finditer(body):
            elems = ','.join(x.strip() for x in m.group(2).split(',') if x.strip())
            bucket[m.group(1)] = '{' + elems + '}'
        for m in PAT_INT.finditer(body):
            bucket.setdefault(m.group(1), m.group(2))
    return types


def aar_package(zf):
    try:
        root = ET.fromstring(zf.read('AndroidManifest.xml'))
        p = root.get('package')
        if p:
            return p
    except Exception:
        pass
    return None


def collect_symbols(zf):
    """从 aar 的 res/ 收集符号: {type: set(name)}"""
    syms = {}
    for name in zf.namelist():
        if not name.startswith('res/'):
            continue
        rel = name[len('res/'):]
        parts = rel.split('/')
        if len(parts) < 2:
            continue
        dirname = parts[0].split('-')[0]  # 去掉限定符
        fname = parts[-1]
        if dirname == 'values':
            if not fname.endswith('.xml'):
                continue
            try:
                root = ET.fromstring(zf.read(name))
            except Exception:
                continue
            for el in root:
                tag = el.tag.split('}')[-1]
                nm = el.get('name')
                if not nm:
                    continue
                nm = nm.split(':')[-1]
                if tag in ('declare-styleable',):
                    syms.setdefault('styleable', set()).add(nm)
                elif tag == 'item':
                    t = el.get('type', 'string')
                    if t == 'id':
                        syms.setdefault('id', set()).add(nm)
                    else:
                        syms.setdefault(t, set()).add(nm)
                else:
                    if tag in ('style', 'string', 'color', 'dimen', 'integer',
                               'bool', 'array', 'plurals', 'attr', 'id'):
                        syms.setdefault(tag, set()).add(nm)
        else:
            base = fname[:-4] if fname.endswith('.xml') else fname
            if '.' in base and dirname in ('raw',):
                base = base.rsplit('.', 1)[0]
            if dirname in FILE_DIR_TYPES:
                syms.setdefault(dirname, set()).add(base)
            if fname.endswith('.xml'):
                try:
                    content = zf.read(name).decode('utf-8', 'ignore')
                except Exception:
                    continue
                for m in PAT_PLUS_ID.finditer(content):
                    syms.setdefault('id', set()).add(m.group(1))
    return syms


def scan_classes_jar(zf):
    """解 aar 里的 classes.jar：
    返回 (tokens, r_pkgs)
      tokens  —— 字节码中出现的可打印字符串（含 R 字段名）
      r_pkgs  —— 字节码引用的 R 类所在包（点分形式，如 androidx.camera.view）
    """
    tokens = set()
    r_pkgs = set()
    try:
        raw = zf.read('classes.jar')
    except KeyError:
        return tokens, r_pkgs
    except Exception:
        return tokens, r_pkgs
    try:
        with zipfile.ZipFile(io.BytesIO(raw)) as jz:
            for n in jz.namelist():
                if not n.endswith('.class'):
                    continue
                try:
                    data = jz.read(n)
                except Exception:
                    continue
                for m in PAT_ASCII.finditer(data):
                    tokens.add(m.group().decode('ascii', 'ignore'))
    except Exception:
        return tokens, r_pkgs

    for tk in tokens:
        m = PAT_R_TOKEN.match(tk)
        if m:
            r_pkgs.add(m.group(1).replace('/', '.'))
    return tokens, r_pkgs


def generate():
    """生成全部库 R.java，返回生成的 .java 路径列表。"""
    if not os.path.isfile(APP_R):
        print('!! app R.java not found:', APP_R)
        sys.exit(1)
    data = json.load(open(CLASSPATH_JSON, encoding='utf-8'))
    sources = [s['path'] for s in data.get('aarSources', []) if os.path.isfile(s.get('path', ''))]

    marker = os.path.join(OUT_DIR, '.done.json')
    if os.path.isfile(marker):
        try:
            prev = json.load(open(marker, encoding='utf-8'))
            if (prev.get('aarCount') == len(sources)
                    and prev.get('logic') == LOGIC_VERSION):
                files = [os.path.join(dp, fn) for dp, _, fns in os.walk(OUT_DIR)
                         for fn in fns if fn == 'R.java']
                print('reusing existing library R sources:', len(files))
                return sorted(files)
        except Exception:
            pass

    app = parse_app_r(APP_R)
    n_types_total = sum(len(v) for v in app.values())
    print('app R symbols:', n_types_total, 'types:', sorted(app.keys()))

    if os.path.isdir(OUT_DIR):
        for dp, _, fns in os.walk(OUT_DIR):
            for fn in fns:
                if fn.endswith('.java') or fn.endswith('.json'):
                    try:
                        os.remove(os.path.join(dp, fn))
                    except OSError:
                        pass

    # needed[pkg][type] = set(names)
    needed = {}
    n_from_res = 0
    n_from_bytecode = 0
    skipped = []

    def add(pkg, rtype, name):
        needed.setdefault(pkg, {}).setdefault(rtype, set()).add(name)

    # 先取全部 aar 的 manifest 包名，作为「合法 R 包」白名单。
    # 库代码正常只引用自己模块的 R，白名单可挡掉描述符误判产生的幽灵包。
    mf_pkgs = {}
    for aar in sources:
        try:
            with zipfile.ZipFile(aar) as zf:
                mf_pkgs[aar] = aar_package(zf)
        except Exception:
            mf_pkgs[aar] = None
    known = set(p for p in mf_pkgs.values() if p)
    print('known library R packages:', len(known))

    for aar in sources:
        try:
            with zipfile.ZipFile(aar) as zf:
                mf_pkg = mf_pkgs.get(aar)
                res_syms = collect_symbols(zf) if mf_pkg else {}
                tokens, r_pkgs = scan_classes_jar(zf)

                if not mf_pkg and not r_pkgs:
                    skipped.append(os.path.basename(aar))
                    continue

                # A. 资源路（归属 aar 的 manifest 包名）
                if mf_pkg:
                    for t, names in res_syms.items():
                        for nm in names:
                            if nm in app.get(t, {}):
                                add(mf_pkg, t, nm)
                                n_from_res += 1

                # B. 字节码路：凡是字节码里出现过的 R 字段名都补上
                targets = set(p for p in r_pkgs if p in known)
                if mf_pkg:
                    targets.add(mf_pkg)
                if tokens and targets:
                    for t, names in app.items():
                        for nm in names:
                            if nm in tokens:
                                for p in targets:
                                    add(p, t, nm)
                                n_from_bytecode += 1
        except Exception as e:
            print('  [skip]', os.path.basename(aar), e)

    out_files = []
    n_pkgs = 0
    n_fields = 0
    for pkg, type_map in sorted(needed.items()):
        pkg_path = pkg.replace('.', os.sep)
        pkg_dir = os.path.join(OUT_DIR, pkg_path)
        os.makedirs(pkg_dir, exist_ok=True)
        lines = ['package %s;' % pkg, '', 'public final class R {']
        for t in sorted(type_map.keys()):
            fields = []
            for nm in sorted(type_map[t]):
                v = app.get(t, {}).get(nm)
                if v is None:
                    continue
                if v.startswith('{'):
                    fields.append('    public static final int[] %s=%s;' % (nm, v))
                else:
                    fields.append('    public static final int %s=%s;' % (nm, v))
            if not fields:
                continue
            lines.append('  public static final class %s {' % t)
            lines.extend(fields)
            lines.append('  }')
            n_fields += len(fields)
        lines.append('}')
        if len(lines) <= 5:
            continue
        out_path = os.path.join(pkg_dir, 'R.java')
        with open(out_path, 'w', encoding='utf-8') as f:
            f.write('\n'.join(lines) + '\n')
        out_files.append(out_path)
        n_pkgs += 1

    with open(marker, 'w', encoding='utf-8') as f:
        json.dump({'aarCount': len(sources), 'logic': LOGIC_VERSION}, f)
    print('library R generated: pkgs =', n_pkgs, '| fields =', n_fields)
    print('  from res =', n_from_res, '| from bytecode =', n_from_bytecode,
          '| no-package aars =', len(skipped))
    return sorted(out_files)


if __name__ == '__main__':
    generate()
