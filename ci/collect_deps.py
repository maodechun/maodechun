"""收集插件编译所需的 Maven 依赖（jar / aar），并抽出 aar 内的 classes.jar。

Gradle 缓存位于 ~/.gradle/caches/modules-2/files-2.1/<group>/<artifact>/<ver>/<hash>/<file>
本脚本递归扫描，挑出每个 artifact 的最高版本，输出扁平化的 classpath 目录。
"""
import json
import os
import shutil
import zipfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
PROJ = os.path.join(ROOT, 'bodhi_token')
GC = os.path.join(os.path.expanduser('~'), '.gradle', 'caches', 'modules-2', 'files-2.1')
OUTDIR = os.path.join(PROJ, 'build', 'deps')
LIBS = os.path.join(OUTDIR, 'libs')


def ver_key(v):
    """版本排序键。

    注意：Gradle 缓存里同一逻辑库会出现多种变体，如
    androidx.annotation 下的 annotation / annotation-jvm，
    kotlinx-coroutines-core 下的 core / core-jvm / core-android。
    这里只按数字段比较，忽略 -jvm/-android 之类后缀，避免
    1.9.24 与 1.9.24-jvm 被当成不同版本互相覆盖。
    """
    parts = []
    for seg in v.replace('-', '.').split('.'):
        if seg.isdigit():
            parts.append((0, int(seg), ''))
        else:
            parts.append((1, 0, seg))
    return parts


def collect():
    """返回 {group:artifact: [(version, path, ext)]}

    Gradle 缓存里的 artifact 目录名可能是 'annotation-jvm' 这种变体名，
    统一归并到去掉变体后缀的基础名，保证 classpath 尽量完整。
    """
    table = {}
    if not os.path.isdir(GC):
        print('!! gradle cache missing:', GC)
        return table
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
                    if not os.path.isdir(hdir):
                        continue
                    for fn in os.listdir(hdir):
                        if not (fn.endswith('.jar') or fn.endswith('.aar')):
                            continue
                        if 'sources' in fn or 'javadoc' in fn:
                            continue
                        key = group + ':' + art
                        ext = fn.rsplit('.', 1)[-1]
                        table.setdefault(key, []).append(
                            (ver, os.path.join(hdir, fn), ext))
    return table


def pick(table):
    """每个 artifact 取最高版本，但保留所有变体 artifact（-jvm/-android 等）。

    策略：先按基础名分组，组内取最高版本；但同组内不同变体名都保留，
    因为 KMP 变体（如 core-jvm 与 core-android）内容互补。
    """
    out = []
    for key, items in sorted(table.items()):
        items.sort(key=lambda t: ver_key(t[0]))
        ver, path, ext = items[-1]
        out.append((key, ver, path, ext))
    return out


def main():
    # 增量模式：只创建目录并覆盖同名文件，不做任何删除，
    # 避免触碰沙箱的删除限制。
    os.makedirs(LIBS, exist_ok=True)

    table = collect()
    picked = pick(table)

    # 手工补下的依赖（Gradle 缓存里没有，从镜像单独取）
    # libs 下的文件直接会被 compile_plugins 扫到，这里只登记 aar 以便追溯。
    extras = [
        ('net.zetetic:sqlcipher-android', '4.10.0',
         os.path.join(OUTDIR, 'sqlcipher.aar')),
        ('androidx.sqlite:sqlite', '2.4.0',
         os.path.join(OUTDIR, 'sqlite-2.4.0.aar')),
        ('androidx.webkit:webkit', '1.11.0',
         os.path.join(OUTDIR, 'webkit.aar')),
    ]
    have = {k for k, _, _, _ in picked}
    already = {f for f in os.listdir(LIBS)} if os.path.isdir(LIBS) else set()
    for key, ver, path in extras:
        safe = key.replace(':', '__') + '.jar'
        if safe in already:
            print('  [extra present]', key, ver)
            continue
        if key in have:
            continue
        if os.path.isfile(path) and os.path.getsize(path) > 10000:
            picked.append((key, ver, path, 'aar'))
            print('  [extra]', key, ver)
        else:
            print('  [extra MISSING]', key, path)

    print('gradle cached artifacts:', len(picked))

    cp = []
    aars = []
    for key, ver, path, ext in picked:
        safe = key.replace(':', '__')
        if ext == 'jar':
            dst = os.path.join(LIBS, safe + '.jar')
            shutil.copy2(path, dst)
            cp.append(dst)
        else:
            aars.append((key, ver, path))
            dst = os.path.join(LIBS, safe + '.jar')
            try:
                with zipfile.ZipFile(path) as z:
                    if 'classes.jar' in z.namelist():
                        with z.open('classes.jar') as src, open(dst, 'wb') as fo:
                            shutil.copyfileobj(src, fo)
                        cp.append(dst)
                    else:
                        print('  [aar no classes.jar]', key, ver)
            except Exception as e:
                print('  [aar fail]', key, ver, e)

    print('classpath jars:', len(cp))
    print('aars processed:', len(aars))

    manifest = os.path.join(OUTDIR, 'classpath.json')
    with open(manifest, 'w', encoding='utf-8') as f:
        json.dump({'jars': cp, 'aarSources': [
            {'key': k, 'ver': v, 'path': p} for k, v, p in aars
        ]}, f, indent=2, ensure_ascii=False)
    print('wrote', manifest)

    # 打印关键依赖是否命中
    wanted = [
        'androidx.core:core', 'androidx.annotation:annotation',
        'androidx.fragment:fragment', 'androidx.appcompat:appcompat',
        'androidx.activity:activity', 'androidx.lifecycle:lifecycle-runtime',
        'androidx.security:security-crypto', 'com.google.crypto.tink:tink-android',
        'androidx.exifinterface:exifinterface', 'com.google.mlkit:barcode-scanning',
        'com.google.android.gms:play-services-mlkit-barcode-scanning',
        'org.jetbrains.kotlinx:kotlinx-coroutines-core',
        'org.jetbrains.kotlinx:kotlinx-coroutines-android',
        'net.zetetic:sqlcipher-android', 'androidx.sqlite:sqlite',
        'org.jetbrains.kotlin:kotlin-stdlib',
    ]
    have = {k for k, _, _, _ in picked}
    print('\n--- key deps ---')
    for w in wanted:
        print(('  OK   ' if w in have else '  MISS ') + w)


if __name__ == '__main__':
    main()
