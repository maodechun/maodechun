"""从阿里云 Google Maven 镜像补齐 Gradle 缓存里缺失的 aar 依赖。

只做「下载 + 抽 classes.jar 到 libs/」，不做删除，可反复执行（幂等）。
"""
import os
import shutil
import zipfile

import urllib.request

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
PROJ = os.path.join(ROOT, 'bodhi_token')
DEPS = os.path.join(PROJ, 'build', 'deps')
LIBS = os.path.join(DEPS, 'libs')

BASES = [
    'https://maven.aliyun.com/repository/google',
    'https://maven.aliyun.com/repository/public',
]

# (group, artifact, version, ext)
WANTED = [
    ('androidx.datastore', 'datastore-preferences-android', '1.1.1', 'aar'),
    ('androidx.datastore', 'datastore-core-android', '1.1.1', 'aar'),
    # KMP 库：必须用 -jvm 变体，无后缀的只含 .knm metadata，kotlinc 读不到。
    ('androidx.datastore', 'datastore-preferences-core-jvm', '1.1.1', 'jar'),
    ('androidx.webkit', 'webkit', '1.11.0', 'aar'),
    ('androidx.preference', 'preference', '1.2.1', 'aar'),
    ('androidx.browser', 'browser', '1.8.0', 'aar'),
    ('androidx.camera', 'camera-extensions', '1.3.1', 'aar'),
    ('net.zetetic', 'sqlcipher-android', '4.10.0', 'aar'),
    ('androidx.sqlite', 'sqlite', '2.4.0', 'aar'),
    # Flutter embedding 的 POM 依赖，闭包解析曾遗漏，缺失时
    # FlutterLoader 初始化报 NoClassDefFoundError: ReLinker$Logger
    ('com.getkeepsafe.relinker', 'relinker', '1.4.5', 'aar'),
]


def fetch(group, artifact, version, ext):
    rel = '%s/%s/%s/%s-%s.%s' % (
        group.replace('.', '/'), artifact, version, artifact, version, ext)
    for base in BASES:
        url = base + '/' + rel
        try:
            req = urllib.request.Request(url, headers={'User-Agent': 'curl/8'})
            with urllib.request.urlopen(req, timeout=120) as r:
                data = r.read()
            if len(data) < 10000:
                continue
            return data
        except Exception:
            continue
    return None


def main():
    os.makedirs(LIBS, exist_ok=True)
    # 注意：datastore 的 -android 变体含真实 classes，
    # 其无后缀变体往往是空壳（仅重定向），两者都取一份能最大化命中。
    for group, artifact, version, ext in WANTED:
        safe = (group + '__' + artifact).replace(':', '__')
        dst = os.path.join(LIBS, safe + '.jar')
        if os.path.isfile(dst) and os.path.getsize(dst) > 1000:
            print('  [skip]', group + ':' + artifact, version, 'already present')
            continue
        data = fetch(group, artifact, version, ext)
        if data is None:
            print('  [FAIL]', group + ':' + artifact, version, '(download)')
            continue
        raw = os.path.join(DEPS, safe + '.' + ext)
        with open(raw, 'wb') as f:
            f.write(data)
        print('  [dl  ]', group + ':' + artifact, version,
              len(data), 'bytes ->', os.path.basename(raw))
        if ext == 'jar':
            shutil.copy2(raw, dst)
            print('        -> libs', os.path.basename(dst))
        else:
            try:
                with zipfile.ZipFile(raw) as z:
                    names = z.namelist()
                    if 'classes.jar' in names:
                        with z.open('classes.jar') as s, open(dst, 'wb') as fo:
                            shutil.copyfileobj(s, fo)
                        print('        -> libs', os.path.basename(dst),
                              os.path.getsize(dst), 'bytes')
                    else:
                        print('        !! no classes.jar in', artifact)
            except Exception as e:
                print('        !! unzip fail:', e)


if __name__ == '__main__':
    main()
