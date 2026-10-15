# -*- coding: utf-8 -*-
"""生成 .flutter-plugins-dependencies。

Flutter 的 Gradle 插件通过读这个文件，把每个带 Android 原生实现的插件
`include` 进 Gradle 工程。flutter_tools 正常会写它，但本沙箱跑不了
flutter_tools，因此这里按官方 schema 手工生成。

schema（见 native_plugin_loader.gradle.kts）：
{
  "plugins": {
    "android": [
      {"name":..., "path":..., "dependencies":[...],
       "native_build": bool, "dev_dependency": bool}
    ]
  },
  "dependencyGraph": [{"name":..., "dependencies":[...]}]
}
"""
import io
import json
import os
import sys

ROOT = r'C:\Users\Administrator\WorkBuddy\2026-10-13-20-18-48'
PROJ = os.path.join(ROOT, 'bodhi_token')
PKG_CONFIG = os.path.join(PROJ, '.dart_tool', 'package_config.json')
OUT = os.path.join(PROJ, '.flutter-plugins-dependencies')

# 这些包是 SDK 内置 / 纯 Dart，不作为 Android 插件
SKIP = {'flutter', 'flutter_test', 'sky_engine', 'flutter_web_plugins', 'bodhi_token'}


def load_yaml_safe(path):
    try:
        import yaml
        with io.open(path, encoding='utf-8') as f:
            return yaml.safe_load(f)
    except Exception:
        return None


def pkg_dir_of(entry):
    u = entry['rootUri']
    base = os.path.dirname(PKG_CONFIG)
    if u.startswith('file:///'):
        p = u[8:]
    else:
        p = os.path.normpath(os.path.join(base, u))
    return p


def has_android_plugin(d, pubspec):
    """判断该包是否提供 Android 原生实现。

    条件：pubspec 声明 flutter.plugin.platforms.android，
    且包内存在 android/ 目录。
    """
    android_dir = os.path.join(d, 'android')
    if not os.path.isdir(android_dir):
        return False
    fl = (pubspec or {}).get('flutter') or {}
    if not isinstance(fl, dict):
        return False
    plugin = fl.get('plugin')
    if not isinstance(plugin, dict):
        # 有些插件直接用 androidPackage 顶层键
        return False
    platforms = plugin.get('platforms') or {}
    if not isinstance(platforms, dict):
        return False
    return 'android' in platforms


def main():
    with io.open(PKG_CONFIG, encoding='utf-8') as f:
        cfg = json.load(f)

    by_name = {}
    for e in cfg['packages']:
        by_name[e['name']] = e

    plugins = []
    for e in cfg['packages']:
        name = e['name']
        if name in SKIP:
            continue
        d = pkg_dir_of(e)
        pubspec_path = os.path.join(d, 'pubspec.yaml')
        if not os.path.isfile(pubspec_path):
            continue
        ps = load_yaml_safe(pubspec_path)
        if not has_android_plugin(d, ps):
            continue

        # 依赖里只保留同样是插件的（且排除 SDK 包）
        deps_raw = ((ps or {}).get('dependencies') or {})
        dep_names = []
        if isinstance(deps_raw, dict):
            for dn in deps_raw.keys():
                if dn in SKIP:
                    continue
                dep_names.append(dn)

        plugins.append({
            'name': name,
            'path': d.replace('\\', '/'),
            'dependencies': dep_names,
            'native_build': True,
            'dev_dependency': False,
        })

    plugins.sort(key=lambda x: x['name'])

    data = {
        'plugins': {
            'android': plugins,
            # 其他平台留空数组，保持结构完整
            'ios': [],
            'linux': [],
            'macos': [],
            'web': [],
            'windows': [],
        },
        'dependencyGraph': [
            {'name': p['name'], 'dependencies': p['dependencies']}
            for p in plugins
        ],
    }

    with io.open(OUT, 'w', encoding='utf-8', newline='\n') as f:
        f.write(json.dumps(data, ensure_ascii=False, indent=2))

    print('生成 %s' % OUT)
    print('Android 插件 %d 个：' % len(plugins))
    for p in plugins:
        print('  - %-32s %s' % (p['name'], os.path.basename(p['path'])))
    return 0


if __name__ == '__main__':
    sys.exit(main())
