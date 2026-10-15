"""用 d8 把插件 class 与运行时依赖闭包合并成 dex。

关键点：
- 只喂「运行时依赖闭包」里的 jar，不喂 Gradle 构建工具链的 jar
  （bundletool、AGP、lint 等混含 DEX 与 Java 字节码，d8 会拒绝）。
- d8 只接受 jar/zip/class 文件，不接受目录，所以 class 目录先打包。

输入：
  build/classes/**               插件编译产物
  build/r_classes/**             资源的 R 类
  build/runtime_closure.json     运行时依赖闭包
输出：
  build/dex/classes.zip          内含 classes.dex
"""
import json
import os
import subprocess
import sys
import zipfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
PROJ = os.path.join(ROOT, 'bodhi_token')
JAVA = os.path.join(ROOT, 'toolchain', 'jdk', 'jdk-17.0.2', 'bin', 'java.exe')
# 必须用官方 R8 发行版：build-tools 36 自带的 d8 是 8.10.9-dev 开发版，
# 会静默产出损坏 dex（superclass_idx 越界 178 处，运行时 ClassNotFoundException 秒退）；
# build-tools 34 的 d8 (8.2) 则在解析 appcompat 1.7.0 匿名类时直接崩溃。
R8_JAR = os.path.join(ROOT, 'toolchain', 'r8-official.jar')
BT = os.path.join(ROOT, 'toolchain', 'sdk', 'build-tools', '36.0.0')
BT34 = os.path.join(ROOT, 'toolchain', 'sdk', 'build-tools', '34.0.0')
D8_JAR = R8_JAR
AAPT2 = os.path.join(BT34, 'aapt2.exe')
ANDROID_JAR = os.path.join(ROOT, 'toolchain', 'sdk', 'platforms', 'android-34', 'android.jar')

BUILD = os.path.join(PROJ, 'build')
CLASSES = os.path.join(BUILD, 'classes')
GEN = os.path.join(BUILD, 'gen')
LIBS = os.path.join(BUILD, 'deps', 'libs')
DEXOUT = os.path.join(BUILD, 'dex')
CLOSURE = os.path.join(BUILD, 'runtime_closure.json')
MIN_API = '23'

# 闭包里缺 aar 时，用 libs 下同名 jar 兜底
MANUAL = {
    'androidx.webkit:webkit': 'androidx.webkit__webkit.jar',
    'androidx.preference:preference': 'androidx.preference__preference.jar',
    'androidx.browser:browser': 'androidx.browser__browser.jar',
    'androidx.camera:camera-extensions': 'androidx.camera__camera-extensions.jar',
    'net.zetetic:sqlcipher-android': 'net.zetetic__sqlcipher-android.jar',
    'androidx.sqlite:sqlite': 'androidx.sqlite__sqlite.jar',
    'androidx.datastore:datastore-preferences-core-jvm':
        'androidx.datastore__datastore-preferences-core-jvm.jar',
    'androidx.datastore:datastore-core-android':
        'androidx.datastore__datastore-core-android.jar',
    'androidx.datastore:datastore-preferences-android':
        'androidx.datastore__datastore-preferences-android.jar',
}

# ═══════════════════════════════════════════════════════
# APK 瘦身：按制品名排除「绝非运行时依赖」的 jar。
#
# 背景：deps/libs 是 Maven 传递闭包的全量下载（264 个），其中约七成体积
# 是构建工具链（AGP / Kotlin 编译器 / IntelliJ / Groovy / Lint /
# bundletool / JNA / 测试平台…）与运行时用不到的库（Jetpack Compose /
# BouncyCastle / Netty / gRPC…）。此前全部喂给 d8，产出 21 个 dex
# 共 13.2 万个类（180MB 未压缩 / 65MB 压缩），是 145MB 包体的主因。
#
# 排除原则（按 jar 文件名前缀匹配）：
#   1. org.android.tools* / groovy / intellij / kotlin 编译器族：
#      构建期工具，运行时类加载器永远不会碰到（零风险）
#   2. androidx.compose*：Flutter 应用不使用 Compose（零风险）
#   3. 仅 JVM 侧的库（kotlin-reflect / tink-jvm / protobuf-java /
#      BouncyCastle / Netty / gRPC / glassfish / apache commons / http…）：
#      由工具链传递依赖引入，插件代码不引用（模拟器回归验证覆盖）
#   4. com.google.mlkit* / com.google.android.gms*：ML Kit 扫码全家桶。
#      扫码已改用原生 CameraX + zxing（纯 Java，无 GMS 依赖，见
#      ScanEngine.kt 与 pubspec 注释），mobile_scanner 已从依赖移除。
#      血泪史：曾试过「排除 thin 留 thick」「thin+thick 全保留」两条路，
#      在无 Google 服务的设备上均以 ML Kit Internal error / 动态下发失败告终，
#      唯一可靠解就是不依赖 ML Kit。
# 保留清单（易误伤，务必保留）：kotlin-stdlib、kotlinx-coroutines、
#   guava、tink-android（flutter_secure_storage 加密用）、androidx.*、
#   play-services-base/basement/tasks、mlkit bundled 全家、zxing、camera*
# ═══════════════════════════════════════════════════════
EXCLUDE_ARTIFACTS = (
    # ── Android Gradle Plugin 与构建工具链 ──
    'com.android.tools',
    'com.android.databinding',
    'com.google.testing.platform',
    'com.google.prefab', 
    # ── Kotlin 编译器族（保留 kotlin-stdlib / kotlinx-coroutines）──
    'kotlin-compiler',
    'kotlin-gradle-plugin',
    'kotlin-daemon',
    'kotlin-native-utils',
    'kotlin-reflect',
    'kotlin-serialization-compiler',
    'kotlin-annotation-processing',
    'kotlin-scripting',
    'kotlin-build-commons',
    # ── IDE / 通用构建工具 ──
    'org.jetbrains.intellij',
    'org.codehaus.groovy',
    'net.java.dev.jna',
    'com.github.ben-manes.caffeine',
    'caffeine',
    'trove4j',
    'org.jetbrains.annotations',  # 编译期注解，运行时无引用
    # ── 仅 JVM 侧 / 工具链传递依赖（Android 侧不用）──
    'com.google.crypto.tink__tink.jar',       # 保留 tink-android（FSS 用）
    'org.bouncycastle',
    'io.netty',
    'io.grpc',
    'io.opentelemetry',
    'org.apache.httpcomponents',
    'org.apache.commons',
    'commons-io',
    'commons-codec',
    'commons-logging',
    'org.glassfish',
    'com.google.api',
    'com.google.protobuf__protobuf-java.jar', # 保留 protobuf-lite 若存在
    'com.google.errorprone',
    'com.google.j2objc',
    'com.google.jimfs',
    'com.google.code.findbugs',
    'com.google.flatbuffers',
    'org.ow2.asm',
    'org.jacoco',
    'com.squareup.okhttp',
    'com.squareup.okio',
    'com.squareup.retrofit',
    # ── 未使用的 UI / 条码方案 ──
    'androidx.compose',
    # ⚠️ ML Kit 全家桶（扫码已改用 zxing 纯 Java 方案，见 pubspec 注释）。
    # mobile_scanner 移除后，全 app 无任何代码引用 GMS/ML Kit：
    #   com.google.mlkit.*          — bundled barhopper 实现（含 libbarhopper.so 不再打包）
    #   com.google.android.gms.*    — thin 公共 API + dynamite（需 Google 服务）
    # camera-extensions 仅 mobile_scanner 使用
    'com.google.mlkit',
    'com.google.android.gms',
    'androidx.camera__camera-extensions',
)


def run(cmd, label, timeout=3600):
    print('\n>>>', label)
    r = subprocess.run(cmd, capture_output=True, timeout=timeout)

    def dec(b):
        if not b:
            return ''
        for enc in ('utf-8', 'gbk', 'latin-1'):
            try:
                return b.decode(enc)
            except UnicodeDecodeError:
                continue
        return repr(b[:500])

    so, se = dec(r.stdout), dec(r.stderr)
    print('   rc =', r.returncode)
    if so:
        print('--- stdout ---')
        print('\n'.join(so.splitlines()[-40:]))
    if se:
        print('--- stderr ---')
        print('\n'.join(se.splitlines()[-60:]))
    return r.returncode


def zip_dir(src_dir, out_jar):
    n = 0
    with zipfile.ZipFile(out_jar, 'w', zipfile.ZIP_DEFLATED) as z:
        for dp, _, fns in os.walk(src_dir):
            for fn in fns:
                p = os.path.join(dp, fn)
                arc = os.path.relpath(p, src_dir).replace(os.sep, '/')
                z.write(p, arc)
                n += 1
    print('   zipped', n, 'files ->', os.path.basename(out_jar))
    return n


def compile_r_class():
    src = os.path.join(GEN, 'com', 'daotuo', 'bodhitoken', 'R.java')
    if not os.path.isfile(src):
        print('!! R.java not found:', src)
        return False
    out = os.path.join(BUILD, 'r_classes')
    os.makedirs(out, exist_ok=True)
    javac = os.path.join(ROOT, 'toolchain', 'jdk', 'jdk-17.0.2', 'bin', 'javac.exe')
    rc = run([javac, '--release', '8', '-encoding', 'UTF-8',
              '-classpath', ANDROID_JAR, '-d', out, src], 'javac R.java', 600)
    return rc == 0


def collect_runtime_jars():
    """使用 deps/libs 全量依赖（264 个 jar/aar），
    并按 EXCLUDE_ARTIFACTS 排除构建工具链等非运行时制品。

    历史 bug：曾按 runtime_closure.json 的「闭包」（仅 28 项）筛选输入，
    但该闭包漏了大量传递依赖（androidx.core / lifecycle / kotlin-stdlib /
    camera-core / play-services-base 等），导致 146 个运行时父类/接口缺失，
    FlutterFragmentActivity 链解析失败 → 启动即 ClassNotFoundException 秒退。
    「全量 - 排除表」是折中方案：比闭包安全（不漏），比全量小得多（去废）。
    每次调整排除表后必须整包回归验证（模拟器全流程）。
    """
    jars = []
    skipped_tooling = 0
    for fn in sorted(os.listdir(LIBS)):
        if not (fn.endswith('.jar') or fn.endswith('.aar')):
            continue
        if any(pat in fn for pat in EXCLUDE_ARTIFACTS):
            skipped_tooling += 1
            continue
        p = os.path.join(LIBS, fn)
        # 跳过同时含 dex 与 class 的构建工具 jar（bundletool/AGP 等）
        try:
            with zipfile.ZipFile(p) as z:
                if any(n.endswith('.dex') for n in z.namelist()):
                    skipped_tooling += 1
                    continue
        except Exception:
            pass
        jars.append(p)
    if skipped_tooling:
        print('skipped tooling/excluded jars:', skipped_tooling)

    # flutter 嵌入层必需，但它不在 Maven 依赖里
    fj = os.path.join(LIBS, '__flutter__flutter_embedding.jar')
    if os.path.isfile(fj) and fj not in jars:
        jars.append(fj)

    return jars


def main():
    os.makedirs(DEXOUT, exist_ok=True)
    # R.java 由 build_resources(aapt2 link) 生成，包含全部合并资源的符号。
    # 必须在此重编译进 build/classes，保证 R.id 等与最终资源 ID 一致。
    # 另外为每个依赖 aar 生成对应包名的库 R 类（aar 自带 classes.jar 不含 R），
    # 否则库代码运行时访问 R$id / R$styleable 会 NoClassDefFoundError。
    # 生成 GeneratedPluginRegistrant（Flutter 官方工具链自动生成，手工流水线
    # 必须补上，否则所有插件不注册，Dart 侧一律 MissingPluginException）。
    # 必须在 gen_library_r 之前、zip CLASSES 之前执行。
    import gen_plugin_registrant
    if gen_plugin_registrant.main() != 0:
        return 1

    import gen_library_r
    app_r = os.path.join(GEN, 'com', 'daotuo', 'bodhitoken', 'R.java')
    srcs = []
    if os.path.isfile(app_r):
        srcs.append(app_r)
    srcs.extend(gen_library_r.generate())
    if srcs:
        javac = os.path.join(ROOT, 'toolchain', 'jdk', 'jdk-17.0.2', 'bin', 'javac.exe')
        rc = run([javac, '--release', '8', '-encoding', 'UTF-8',
                  '-classpath', ANDROID_JAR, '-d', CLASSES] + srcs,
                 'javac R.java (app + libraries)', 900)
        if rc != 0:
            return 1

    inputs = []
    pj = os.path.join(DEXOUT, 'plugins.jar')
    zip_dir(CLASSES, pj)
    inputs.append(pj)

    jars = collect_runtime_jars()
    print('\nruntime jars:', len(jars))

    # 统一归一化：aar -> 抽 classes.jar；空 jar（如 listenablefuture 占位包）跳过
    norm = []
    skipped = []
    tmpdir = os.path.join(DEXOUT, 'aar_jar')
    os.makedirs(tmpdir, exist_ok=True)
    for j in jars:
        if j.endswith('.aar'):
            dst = os.path.join(tmpdir, os.path.basename(j) + '.classes.jar')
            ok = False
            if os.path.isfile(dst):
                ok = True
            else:
                try:
                    with zipfile.ZipFile(j) as z:
                        if 'classes.jar' in z.namelist():
                            with z.open('classes.jar') as s, open(dst, 'wb') as fo:
                                fo.write(s.read())
                            ok = True
                except Exception as e:
                    print('  [aar skip]', os.path.basename(j), e)
            if ok:
                norm.append(dst)
            else:
                skipped.append((os.path.basename(j), 'no classes.jar'))
        else:
            # jar 直接校验是否有 class
            try:
                with zipfile.ZipFile(j) as z:
                    if any(n.endswith('.class') for n in z.namelist()):
                        norm.append(j)
                    else:
                        skipped.append((os.path.basename(j), 'no .class inside'))
            except Exception as e:
                skipped.append((os.path.basename(j), 'unreadable: %s' % e))

    print('normalized jar inputs:', len(norm))
    if skipped:
        print('skipped:', len(skipped))
        for n, why in skipped:
            print('   -', n, '(', why, ')')

    # 去重优先级：真正的运行时库在前，AGP/编译器工具 jar 在后
    norm.sort(key=lambda p: (1 if ('com.android.tools' in p or 'com.google.testing' in p) else 0, p))

    # ---- 合并去重：全部运行时 class 合成一个 jar（跨 jar 重复类只保留首份）----
    merged = os.path.join(DEXOUT, 'all_runtime_merged.jar')
    seen = set()
    n_cls = 0
    with zipfile.ZipFile(merged, 'w', zipfile.ZIP_DEFLATED) as out:
        for j in norm:
            try:
                with zipfile.ZipFile(j) as z:
                    for name in z.namelist():
                        if not name.endswith('.class') or name in seen:
                            continue
                        seen.add(name)
                        out.writestr(name, z.read(name))
                        n_cls += 1
            except Exception as e:
                print('  [merge skip]', os.path.basename(j), e)
    print('merged classes:', n_cls)

    out_zip = os.path.join(DEXOUT, 'classes.zip')
    cmd = [
        JAVA, '-Xmx6g', '-cp', D8_JAR, 'com.android.tools.r8.D8',
        '--release',
        '--min-api', MIN_API,
        '--lib', ANDROID_JAR,
        '--output', out_zip,
    ]
    cmd.append(merged)
    cmd.extend(inputs)

    rc = run(cmd, 'd8', 5400)

    if os.path.isfile(out_zip):
        print('output:', out_zip, os.path.getsize(out_zip), 'bytes')
    return rc


if __name__ == '__main__':
    sys.exit(main())
