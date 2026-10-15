"""合并全部依赖 aar 的 res/ 到统一资源目录。

数据源：build/deps/classpath.json 的 aarSources（.gradle 缓存里的原始 aar，
含 res/）。deps/libs 下的 jar 是被剥掉资源的转换产物，不能用于资源合并。

规则：
- values/*.xml：按 (tag, name) 合并去重，app 自身资源优先；
- 其他文件（drawable/layout/xml/...）：路径相同者保留先出现的。
输出：build/res_merged/
"""
import json
import os
import shutil
import sys
import zipfile
import xml.etree.ElementTree as ET

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
PROJ = os.path.join(ROOT, 'bodhi_token')
CLASSPATH_JSON = os.path.join(PROJ, 'build', 'deps', 'classpath.json')
APP_RES = os.path.join(PROJ, 'android', 'app', 'src', 'main', 'res')
OUT = os.path.join(PROJ, 'build', 'res_merged_v2')


def value_key(elem):
    tag = elem.tag.split('}')[-1]
    if tag in ('style', 'declare-styleable', 'attr'):
        return (tag, elem.get('name', ''))
    if tag == 'item':
        return ('item:' + elem.get('type', ''), elem.get('name', ''))
    if tag == 'plurals':
        return ('plurals', elem.get('name', ''))
    return (tag, elem.get('name', ''))


def merge_value_bytes(dst_path, src_bytes):
    """把 src_bytes（values xml 内容）合并进 dst_path，全程内存操作不落临时文件。"""
    try:
        dt = ET.parse(dst_path).getroot()
        st = ET.fromstring(src_bytes)
    except Exception:
        with open(dst_path, 'wb') as f:
            f.write(src_bytes)
        return 0
    seen = set()
    for ch in list(dt):
        seen.add(value_key(ch))
    added = 0
    for ch in list(st):
        k = value_key(ch)
        if k in seen:
            continue
        seen.add(k)
        dt.append(ch)
        added += 1
    ET.ElementTree(dt).write(dst_path, encoding='utf-8', xml_declaration=True)
    return added


ANDROID_NS = 'http://schemas.android.com/apk/res/android'
TOOLS_NS = 'http://schemas.android.com/apk/tools'
A_NAME = '{%s}name' % ANDROID_NS

MERGE_TAGS = ('uses-permission', 'uses-permission-sdk-23', 'uses-feature',
              'permission', 'queries')


def _aname(el):
    return el.get(A_NAME, '')


def _pub_plugin_roots():
    """从 .dart_tool/package_config.json 解析全部 pub 包根目录。"""
    pc = os.path.join(PROJ, '.dart_tool', 'package_config.json')
    roots = []
    try:
        d = json.load(open(pc, encoding='utf-8'))
        for p in d.get('packages', []):
            roots.append(os.path.normpath(os.path.join(PROJ, '.dart_tool', p.get('rootUri', ''))))
    except Exception as e:
        print('package_config scan failed:', e)
    return roots


def plugin_manifest_sources():
    """收集 pub 插件包的 android/src/main/AndroidManifest.xml 路径。

    插件从源码编译（非 aar），其 manifest 不在 classpath.json 的 aarSources
    里，但同样声明了 Provider（secure_storage/image_picker 的 FileProvider 等）。
    """
    out = []
    for root in _pub_plugin_roots():
        mf = os.path.join(root, 'android', 'src', 'main', 'AndroidManifest.xml')
        if os.path.isfile(mf):
            out.append(mf)
    return out


def merge_manifest_text(app_text, aar_paths):
    """把库 AAR manifest 的组件/权限/queries 合并进 app manifest 文本。

    AGP 的 manifest merger 在 Gradle 构建里完成；手工流水线必须自己合并，
    否则 MlKitInitProvider / androidx.startup 等 ContentProvider 缺失
    （MlKitContext has not been initialized），库声明的权限也全部丢失。
    规则：app 自身条目优先；同名组件跳过（其缺失的子 meta-data 补齐）。

    ⚠️ ML Kit / GMS 的 aar manifest 一律跳过：扫码已改用 zxing，
    ML Kit 类不在 dex 里，若合并进 MlKitInitProvider 会导致
    ClassNotFoundException → 启动秒崩（v5.2.0 实测）。
    """
    def _is_gms_manifest(path):
        low = str(path).lower()
        return ('mlkit' in low or 'play-services' in low
                or 'com.google.android.gms' in low)

    aar_paths = [p for p in aar_paths if not _is_gms_manifest(p)]

    ET.register_namespace('android', ANDROID_NS)
    ET.register_namespace('tools', TOOLS_NS)
    root = ET.fromstring(app_text)
    app_el = root.find('application')

    seen_perm = set()
    idx_app = None
    for i, ch in enumerate(root):
        if ch.tag == 'application':
            idx_app = i
        elif ch.tag in MERGE_TAGS and _aname(ch):
            seen_perm.add((ch.tag, _aname(ch)))

    seen_comp = {}
    if app_el is not None:
        for ch in list(app_el):
            if _aname(ch):
                seen_comp[(ch.tag, _aname(ch))] = ch

    def insert_before_app(el):
        root.insert(idx_app if idx_app is not None else len(root), el)

    n_perm = n_comp = 0
    for aar in aar_paths:
        try:
            if aar.lower().endswith('.aar'):
                with zipfile.ZipFile(aar) as z:
                    if 'AndroidManifest.xml' not in z.namelist():
                        continue
                    mtext = z.read('AndroidManifest.xml')
            else:  # 插件源码包的 manifest xml 文件
                with open(aar, 'rb') as f:
                    mtext = f.read()
        except Exception:
            continue
        try:
            m = ET.fromstring(mtext)
        except Exception:
            continue

        for up in m.findall('uses-permission') + m.findall('uses-permission-sdk-23'):
            k = (up.tag, _aname(up))
            if _aname(up) and k not in seen_perm:
                seen_perm.add(k)
                insert_before_app(up)
                n_perm += 1
        for uf in m.findall('uses-feature'):
            k = (uf.tag, _aname(uf))
            if _aname(uf) and k not in seen_perm:
                seen_perm.add(k)
                insert_before_app(uf)

        lib_app = m.find('application')
        if lib_app is not None and app_el is not None:
            for ch in lib_app:
                nm = _aname(ch)
                if not nm:
                    continue
                k = (ch.tag, nm)
                if k in seen_comp:
                    existing = seen_comp[k]
                    child_names = set(_aname(c) for c in existing)
                    for c in ch:
                        if _aname(c) and _aname(c) not in child_names:
                            existing.append(c)
                    continue
                seen_comp[k] = ch
                app_el.append(ch)
                n_comp += 1

        # <queries> 按「序列化内容」去重合并
        for q in m.findall('queries'):
            for intent in q:
                sig = ET.tostring(intent)
                if not any(ET.tostring(e) == sig
                           for e in root.findall('queries/' + intent.tag)):
                    for eq in root.findall('queries'):
                        eq.append(intent)
                        break
                    else:
                        nq = ET.Element('queries')
                        nq.append(intent)
                        root.insert(idx_app if idx_app is not None else len(root), nq)

    print('manifest merge: +perms =', n_perm, '| +components =', n_comp)
    return ET.tostring(root, encoding='unicode')


def _app_res_signature():
    """app 资源目录内容签名（相对路径+大小+修改时间），用于复用校验。"""
    import hashlib
    h = hashlib.md5()
    for dp, _, fns in os.walk(APP_RES):
        for fn in sorted(fns):
            p = os.path.join(dp, fn)
            st = os.stat(p)
            h.update(('%s|%d|%d|' % (os.path.relpath(p, APP_RES),
                                     st.st_size, int(st.st_mtime))).encode())
    return h.hexdigest()


def main():
    data = json.load(open(CLASSPATH_JSON, encoding='utf-8'))
    sources = [s['path'] for s in data.get('aarSources', []) if os.path.isfile(s.get('path', ''))]
    app_sig = _app_res_signature()

    # 已有合并产物且记录的 aar 集合未变时直接复用（避免整目录删除触发批量删除拦截）
    marker = os.path.join(OUT, '.merge_marker.json')
    if os.path.isfile(marker):
        try:
            prev = json.load(open(marker, encoding='utf-8'))
            if (prev.get('aarCount') == len(sources) and prev.get('withPluginRes')
                    and prev.get('appSig') == app_sig):
                print('reusing existing merged res:', OUT)
                return sources
        except Exception:
            pass

    os.makedirs(OUT, exist_ok=True)

    # 1) app 自身资源优先复制
    n_app = 0
    for dp, _, fns in os.walk(APP_RES):
        rel = os.path.relpath(dp, APP_RES)
        tgt = os.path.join(OUT, rel)
        os.makedirs(tgt, exist_ok=True)
        for fn in fns:
            shutil.copy2(os.path.join(dp, fn), os.path.join(tgt, fn))
            n_app += 1
    print('app res files:', n_app)

    # 2) 逐个原始 aar 合并 res
    n_lib = 0
    n_vals = 0
    for aar in sources:
        try:
            with zipfile.ZipFile(aar) as z:
                for name in z.namelist():
                    if not name.startswith('res/') or name.endswith('/'):
                        continue
                    rel = name[len('res/'):]
                    tgt = os.path.join(OUT, rel)
                    os.makedirs(os.path.dirname(tgt), exist_ok=True)
                    is_values = rel.startswith('values')
                    src_data = z.read(name)
                    if is_values and os.path.isfile(tgt):
                        n_vals += merge_value_bytes(tgt, src_data)
                    elif not os.path.isfile(tgt):
                        with open(tgt, 'wb') as f:
                            f.write(src_data)
                        n_lib += 1
        except Exception as e:
            print('  [skip]', os.path.basename(aar), e)

    # 3) pub 插件源码包的 res（image_picker/share 的 xml/filepaths 等，
    #    合并后的 manifest 会引用它们，缺失会导致 aapt2 link 失败）
    n_plugin = 0
    for root_dir in _pub_plugin_roots():
        pres = os.path.join(root_dir, 'android', 'src', 'main', 'res')
        if not os.path.isdir(pres):
            continue
        for dp, _, fns in os.walk(pres):
            rel = os.path.relpath(dp, pres)
            for fn in fns:
                tgt = os.path.join(OUT, rel, fn)
                if os.path.isfile(tgt):
                    continue  # app / aar 已有者优先
                os.makedirs(os.path.dirname(tgt), exist_ok=True)
                shutil.copy2(os.path.join(dp, fn), tgt)
                n_plugin += 1
    print('plugin res files added:', n_plugin)

    print('aars merged:', len(sources), '| new res files:', n_lib, '| merged value entries:', n_vals)
    print('output:', OUT)
    try:
        with open(marker, 'w', encoding='utf-8') as f:
            json.dump({'aarCount': len(sources), 'withPluginRes': True,
                       'appSig': app_sig}, f)
    except Exception:
        pass
    return sources


if __name__ == '__main__':
    sys.exit(main())
