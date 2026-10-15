"""用 aapt2 编译并链接 App 资源，产出 resources.arsc + 合并后的 AndroidManifest。

流程：
  aapt2 compile  : res/**/*.xml|png -> 扁平化 .flat 中间产物
  aapt2 link     : .flat + android.jar -> resources.arsc + AndroidManifest.xml(二进制)

插件 res 目录经盘点为空，因此只需处理 App 自身资源。
"""
import os
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
PROJ = os.path.join(ROOT, 'bodhi_token')
BT = os.path.join(ROOT, 'toolchain', 'sdk', 'build-tools', '34.0.0')
AAPT2 = os.path.join(BT, 'aapt2.exe')
ANDROID_JAR = os.path.join(ROOT, 'toolchain', 'sdk', 'platforms', 'android-34', 'android.jar')

APP_MAIN = os.path.join(PROJ, 'android', 'app', 'src', 'main')
RES = os.path.join(APP_MAIN, 'res')
MANIFEST = os.path.join(APP_MAIN, 'AndroidManifest.xml')

BUILD = os.path.join(PROJ, 'build')
FLAT = os.path.join(BUILD, 'res_flat')
LINKED = os.path.join(BUILD, 'res_linked')

PKG = 'com.daotuo.bodhitoken'
MIN_SDK = '23'
TARGET_SDK = '34'


def run(cmd, label):
    print('\n>>>', label)
    print('   ', ' '.join(os.path.basename(c) if i == 0 else c
                          for i, c in enumerate(cmd[:4])), '...')
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=1800)
    if r.returncode != 0:
        print('   rc =', r.returncode)
        if r.stdout:
            print('--- stdout ---')
            print('\n'.join(r.stdout.splitlines()[-40:]))
        if r.stderr:
            print('--- stderr ---')
            print('\n'.join(r.stderr.splitlines()[-40:]))
    else:
        print('   rc = 0 OK')
    return r


def read_pubspec_version():
    """从 pubspec.yaml 读取版本（如 5.0.1+501），唯一版本来源。"""
    spec = os.path.join(PROJ, 'pubspec.yaml')
    with open(spec, encoding='utf-8') as f:
        for line in f:
            if line.strip().startswith('version:'):
                v = line.split(':', 1)[1].strip()
                name, _, code = v.partition('+')
                return (name or '1.0.0', code or '1')
    return '1.0.0', '1'


def main():
    os.makedirs(FLAT, exist_ok=True)
    os.makedirs(LINKED, exist_ok=True)

    # ---- 0. 合并依赖 aar 的 res（lifecycle/fragment/core/appcompat 等）----
    import merge_res
    aar_sources = merge_res.main()
    res_dir = merge_res.OUT if os.path.isdir(merge_res.OUT) else RES

    # 新版本 flat 目录，避免删除旧 flat（600+ 文件）触发批量删除拦截
    flat_dir = FLAT
    _v = 2
    while os.path.isdir(flat_dir):
        flat_dir = FLAT + '_v' + str(_v)
        _v += 1
    os.makedirs(flat_dir, exist_ok=True)

    # ---- 1. compile ----
    r = run([AAPT2, 'compile', '--dir', res_dir, '-o', flat_dir],
            'aapt2 compile')
    flats = [os.path.join(flat_dir, f) for f in os.listdir(flat_dir) if f.endswith('.flat')]
    print('   flat files:', len(flats))
    if not flats:
        print('!! no flat output, abort')
        return 1

    # ---- 2. link ----
    # 处理 ${applicationName} 占位符，并补上 aapt2 要求的 package 属性
    # （Gradle 路线由 AGP 注入，手工路线必须自己写）
    mf_text = open(MANIFEST, encoding='utf-8').read()
    mf_fixed = mf_text.replace(
        '${applicationName}',
        'com.daotuo.bodhitoken.CrashGuardApp')
    # 临时调试：debuggable 以便 jdb 附加排查
    if '--debug' in sys.argv:
        mf_fixed = mf_fixed.replace('<application', '<application android:debuggable="true"')
    mf_fixed = mf_fixed.replace(
        '<manifest xmlns:android="http://schemas.android.com/apk/res/android">',
        '<manifest xmlns:android="http://schemas.android.com/apk/res/android"\n'
        '    package="%s">' % PKG,
    )
    # 合并库 AAR manifest + 插件源码包 manifest 的组件/权限/queries
    # （MlKitInitProvider、androidx.startup、FileProvider、相机/指纹权限等，
    #  缺失会导致功能静默失效）
    manifest_sources = list(aar_sources or []) + merge_res.plugin_manifest_sources()
    mf_fixed = merge_res.merge_manifest_text(mf_fixed, manifest_sources)
    mf_tmp = os.path.join(BUILD, 'AndroidManifest.merged.xml')
    with open(mf_tmp, 'w', encoding='utf-8') as f:
        f.write(mf_fixed)
    print('   manifest placeholder resolved ->', mf_tmp)

    VER_NAME, VER_CODE = read_pubspec_version()
    print('   version: %s (%s)' % (VER_NAME, VER_CODE))
    cmd = [
        AAPT2, 'link',
        '-o', os.path.join(LINKED, 'base.apk'),
        '-I', ANDROID_JAR,
        '--manifest', mf_tmp,
        '--java', os.path.join(BUILD, 'gen'),
        '--min-sdk-version', MIN_SDK,
        '--target-sdk-version', TARGET_SDK,
        '--version-code', VER_CODE,
        '--version-name', VER_NAME,
        '--no-version-vectors',
        '--auto-add-overlay',
        '--allow-reserved-package-id',
        '--package-id', '0x7f',
    ]
    # Windows 命令行长度限制 ~32K，642 个 flat 文件会触发 WinError 206。
    # aapt2 link 支持直接接收 zip 格式的 flat 档案，打包后只传一个参数。
    import zipfile as _zip
    flat_zip = os.path.join(BUILD, 'flat_all.zip')
    with _zip.ZipFile(flat_zip, 'w', _zip.ZIP_STORED) as zf:
        for fl in flats:
            zf.write(fl, arcname=os.path.basename(fl))
    print('   flat zip:', flat_zip, os.path.getsize(flat_zip), 'bytes,', len(flats), 'flats')
    cmd.append(flat_zip)

    r = run(cmd, 'aapt2 link')
    out_apk = os.path.join(LINKED, 'base.apk')
    if os.path.isfile(out_apk):
        print('   base.apk size:', os.path.getsize(out_apk))
    gen = os.path.join(BUILD, 'gen')
    if os.path.isdir(gen):
        n = sum(len(f) for _, _, f in os.walk(gen))
        print('   R.java generated files:', n)
    return r.returncode


if __name__ == '__main__':
    sys.exit(main())
