# -*- coding: utf-8 -*-
"""
向 Flutter 生成的 android/app/build.gradle[.kts] 注入 release 签名配置。

要点：
  1. Groovy DSL 里 'release {' 出现多次（signingConfigs.release / buildTypes.release），
     必须做块级定位而非简单正则替换 → 用花括号配对扫描。
  2. Flutter 3.29+ 生成的是 Kotlin DSL(.kts)，语法不同
     （signingConfigs.create("release") / signingConfig = signingConfigs.getByName("release")），
     需按文件类型分流出两种写法。
"""
import sys, io, re

GROOVY_KEYSTORE_BLOCK = """
// ── 由 CI 自动注入：读取 android/key.properties ──────────
def keystoreProperties = new Properties()
def keystorePropertiesFile = rootProject.file('key.properties')
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(new FileInputStream(keystorePropertiesFile))
}
// ─────────────────────────────────────────────────────────
"""

GROOVY_SIGNING = """
    signingConfigs {
        release {
            if (keystoreProperties['storeFile']) {
                storeFile file(keystoreProperties['storeFile'])
                storePassword keystoreProperties['storePassword']
                keyAlias keystoreProperties['keyAlias']
                keyPassword keystoreProperties['keyPassword']
            }
        }
    }
"""

KTS_KEYSTORE_BLOCK = """
// ── 由 CI 自动注入：读取 android/key.properties ──────────
import java.util.Properties
import java.io.FileInputStream

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}
// ─────────────────────────────────────────────────────────
"""

KTS_SIGNING = """
    signingConfigs {
        create("release") {
            if (keystoreProperties.getProperty("storeFile") != null) {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }
"""


def find_block(src, header_regex, search_from=0):
    """定位形如 'xxx {' 的块，返回 (open_brace_idx, close_brace_idx)。"""
    m = re.search(header_regex, src[search_from:], re.S)
    if not m:
        return None
    start = search_from + m.end() - 1
    depth = 0
    i = start
    while i < len(src):
        c = src[i]
        if c == '/' and i + 1 < len(src) and src[i + 1] == '/':
            nl = src.find('\n', i)
            if nl == -1:
                return None
            i = nl
            continue
        if c == "'" or c == '"':
            quote = c
            i += 1
            while i < len(src) and src[i] != quote:
                if src[i] == '\\':
                    i += 1
                i += 1
        elif c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                return (start, i)
        i += 1
    return None


def main(path):
    src = io.open(path, encoding='utf-8').read()
    orig = src

    is_kts = path.endswith('.kts')
    keystore_block = KTS_KEYSTORE_BLOCK if is_kts else GROOVY_KEYSTORE_BLOCK
    signing = KTS_SIGNING if is_kts else GROOVY_SIGNING
    ref = 'signingConfig = signingConfigs.getByName("release")' if is_kts \
        else 'signingConfig signingConfigs.release'

    print('   构建脚本类型: %s' % ('Kotlin DSL (.kts)' if is_kts else 'Groovy DSL'))

    # ── 1) 顶部注入 keystore 读取 ────────────────────────────
    if 'keystoreProperties' not in src:
        blk = find_block(src, r'^plugins\s*\{', 0)
        if blk:
            src = src[:blk[1] + 1] + '\n' + keystore_block + src[blk[1] + 1:]
        else:
            src = keystore_block + src

    # ── 2) 定位 android {} ──────────────────────────────────
    android_blk = find_block(src, r'\bandroid\s*\{')
    if not android_blk:
        print('❌ 未找到 android {} 块', file=sys.stderr)
        return 1

    # ── 3) 注入 signingConfigs ─────────────────────────────
    if 'signingConfigs' not in src:
        src = src[:android_blk[0] + 1] + '\n' + signing + src[android_blk[0] + 1:]

    # ── 4) 精确定位 buildTypes > release ────────────────────
    bt = find_block(src, r'\bbuildTypes\s*\{')
    if bt:
        rel = find_block(src, r'\brelease\s*(?:=\s*)?\{', bt[0])
        if rel and rel[0] < bt[1]:
            body = src[rel[0] + 1:rel[1]]
            if ref not in body:
                indent = '\n            '
                src = src[:rel[0] + 1] + indent + ref + src[rel[0] + 1:]
        else:
            print('⚠️ buildTypes 内未找到 release 块', file=sys.stderr)
    else:
        android_blk = find_block(src, r'\bandroid\s*\{')
        if is_kts:
            bt_block = """
    buildTypes {
        release {
            %s
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
""" % ref
        else:
            bt_block = """
    buildTypes {
        release {
            %s
            minifyEnabled false
            shrinkResources false
        }
    }
""" % ref
        src = src[:android_blk[0] + 1] + bt_block + src[android_blk[0] + 1:]

    # ── 5) 关闭混淆（TOTP / 反射 / 序列化易被破坏）──────────
    src = re.sub(r'\bminifyEnabled\s+true\b', 'minifyEnabled false', src)
    src = re.sub(r'\bisMinifyEnabled\s*=\s*true\b', 'isMinifyEnabled = false', src)
    src = re.sub(r'\bshrinkResources\s+true\b', 'shrinkResources false', src)
    src = re.sub(r'\bisShrinkResources\s*=\s*true\b', 'isShrinkResources = false', src)

    if src == orig:
        print('   ℹ️ 无需修改（已注入过）')
    else:
        io.open(path, 'w', encoding='utf-8').write(src)
        print('   ✅ 签名配置注入完成')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1]))
