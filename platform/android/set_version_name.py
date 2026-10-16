# -*- coding: utf-8 -*-
"""把 android/app/build.gradle.kts 的 versionName 覆写为指定正式版号。

CI 用 flutter create 重建安卓壳后，versionName 默认取自 pubspec 的三段版本号
（如 6.0.0）；本脚本用于改成四段正式版号（如 6.0.0.0）。

用法：python3 platform/android/set_version_name.py 6.0.0.0
"""
import io
import re
import sys

def main() -> int:
    if len(sys.argv) < 2 or not sys.argv[1].strip():
        print('usage: set_version_name.py <versionName>')
        return 2
    vn = sys.argv[1].strip()
    path = 'android/app/build.gradle.kts'
    with io.open(path, encoding='utf-8') as f:
        s = f.read()
    new_s, n = re.subn(
        r'versionName\s*=\s*(?:flutter\.versionName|"[^"]*")',
        'versionName = "%s"' % vn,
        s,
        count=1,
    )
    if n == 0:
        # 没有现成声明则补一行
        new_s = s.replace(
            'versionCode = flutter.versionCode',
            'versionName = "%s"\n        versionCode = flutter.versionCode' % vn,
            1,
        )
    with io.open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(new_s)
    print('versionName ->', vn)
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
