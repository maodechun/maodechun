"""生成并编译 io.flutter.plugins.GeneratedPluginRegistrant。

背景：Flutter 官方工具链在 Gradle 构建时自动生成该类，手工流水线此前没有，
导致引擎反射找不到它、所有插件（path_provider/camera/secure_storage/...）
都不注册，Dart 侧调用一律 MissingPluginException。

做法：
1. 扫描 build/classes 里所有顶层 .class（compile_plugins 的产物）；
2. 用 javap 找出「public + 非抽象 + 实现 FlutterPlugin + 有公共无参构造」的类；
3. 按官方模板生成 GeneratedPluginRegistrant.java（逐插件 try/catch）；
4. javac 编译进 build/classes，随 build_dex 进入 dex。
幂等：重跑会覆盖生成文件。
"""
import os
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
PROJ = os.path.join(ROOT, 'bodhi_token')
BUILD = os.path.join(PROJ, 'build')
CLASSES = os.path.join(BUILD, 'classes')
EMBEDDING = os.path.join(BUILD, 'deps', 'libs', '__flutter__flutter_embedding.jar')
ANDROID_JAR = os.path.join(ROOT, 'toolchain', 'sdk', 'platforms', 'android-34', 'android.jar')
JAVAC = os.path.join(ROOT, 'toolchain', 'jdk', 'jdk-17.0.2', 'bin', 'javac.exe')
JAVAP = os.path.join(ROOT, 'toolchain', 'jdk', 'jdk-17.0.2', 'bin', 'javap.exe')

OUT_JAVA_DIR = os.path.join(BUILD, 'gen_plugin_registrant', 'io', 'flutter', 'plugins')

FLUTTER_PLUGIN = 'io.flutter.embedding.engine.plugins.FlutterPlugin'


def list_top_level_classes():
    out = []
    for dp, _, fns in os.walk(CLASSES):
        for fn in fns:
            if not fn.endswith('.class') or '$' in fn:
                continue
            fqn = os.path.relpath(os.path.join(dp, fn), CLASSES)
            out.append(fqn[:-len('.class')].replace(os.sep, '.'))
    return sorted(out)


def javap_probe(fqns):
    """批量 javap，返回 {fqn: javap输出文本}"""
    result = {}
    cp = CLASSES + os.pathsep + EMBEDDING + os.pathsep + ANDROID_JAR
    B = 60
    for i in range(0, len(fqns), B):
        batch = fqns[i:i + B]
        r = subprocess.run([JAVAP, '-classpath', cp, '-p'] + batch,
                           capture_output=True)
        # javap 对多个类输出时以空行分隔，但难以精确切分；
        # 改为逐个调用太慢，这里用「逐段识别」：输出形如
        #   public class a.b.C { ... }
        cur = None
        for line in (r.stdout or b'').decode('utf-8', 'replace').splitlines():
            s = line.strip()
            if s.startswith('public class ') or s.startswith('public final class ') \
               or s.startswith('public abstract class ') or s.startswith('public interface '):
                tok = s.split()[2] if s.split()[1] == 'class' or s.split()[1] in ('final', 'abstract') else None
                # 取最后一个以 . 分隔的词作为类名（可能有泛型）
                words = s.replace('{', '').split()
                name = words[2] if words[1] == 'class' else words[-1]
                name = name.split('<')[0]
                cur = name if name in batchset_global else None
                if cur:
                    result[cur] = [s]
            elif cur:
                result[cur].append(s)
        # stderr 中的 missing class 直接忽略
    return result


# javap_probe 里用于校验批次成员的全局集合（逐批填充）
batchset_global = set()


def find_registrable():
    cands = [c for c in list_top_level_classes()
             if not c.startswith('com.daotuo') and not c.endswith('.R')
             and not c.startswith('io.flutter.plugins.GeneratedPluginRegistrant')]
    info = {}
    cp = CLASSES + os.pathsep + EMBEDDING + os.pathsep + ANDROID_JAR
    B = 60
    for i in range(0, len(cands), B):
        batch = set(cands[i:i + B])
        r = subprocess.run([JAVAP, '-classpath', cp, '-p'] + sorted(batch),
                           capture_output=True)
        cur = None
        buf = []
        for line in (r.stdout or b'').decode('utf-8', 'replace').splitlines():
            s = line.rstrip()
            if s and not s.startswith(' ') and s.endswith('{'):
                # 新的类声明开始；先落盘上一个类
                if cur is not None:
                    info[cur] = '\n'.join(buf)
                cur = None
                buf = []
                words = s.replace('{', '').split()
                if 'class' in words:
                    name = words[words.index('class') + 1].split('<')[0]
                    if name in batch:
                        cur = name
                        buf = [s]
            elif cur is not None:
                buf.append(s)
        if cur is not None:
            info[cur] = '\n'.join(buf)
    regs = []
    for fqn, text in info.items():
        header = text.split('\n')[0]
        if 'interface' in header or 'abstract' in header:
            continue
        if FLUTTER_PLUGIN not in header:
            continue
        # 公共无参构造（javap 输出的是全限定名）
        if ('public %s();' % fqn) not in text:
            continue
        regs.append(fqn)
    return sorted(regs)


TEMPLATE = '''package io.flutter.plugins;

import androidx.annotation.Keep;
import androidx.annotation.NonNull;
import io.flutter.Log;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.embedding.engine.plugins.FlutterPlugin;

/**
 * Generated file. Do not edit.
 * Rebuilt by ci/gen_plugin_registrant.py — registers %d plugins.
 */
@Keep
public final class GeneratedPluginRegistrant {
  private static final String TAG = "GeneratedPluginRegistrant";

  public static void registerWith(@NonNull FlutterEngine engine) {
%s
  }
}
'''


def main():
    regs = find_registrable()
    print('registrable plugins:', len(regs))
    for r in regs:
        print('  ', r)
    if not regs:
        print('!! no registrable plugin found, abort')
        return 1
    body = []
    for r in regs:
        body.append('    try {')
        body.append('      engine.getPlugins().add(new %s());' % r)
        body.append('    } catch (Throwable t) {')
        body.append('      // Throwable：个别插件静态初始化抛 Error（如缺 libdartjni.so 的 jni），')
        body.append('      // 不能让它中断其余插件的注册')
        body.append('      Log.e(TAG, "Error registering plugin %s", t);' % r)
        body.append('    }')
    src = TEMPLATE % (len(regs), '\n'.join(body))
    os.makedirs(OUT_JAVA_DIR, exist_ok=True)
    out_java = os.path.join(OUT_JAVA_DIR, 'GeneratedPluginRegistrant.java')
    with open(out_java, 'w', encoding='utf-8') as f:
        f.write(src)
    print('written:', out_java)
    rc = subprocess.run([JAVAC, '--release', '8', '-encoding', 'UTF-8',
                         '-classpath', CLASSES + os.pathsep + EMBEDDING + os.pathsep
                         + ANDROID_JAR + os.pathsep + os.path.join(BUILD, 'deps', 'libs', '*'),
                         '-d', CLASSES, out_java],
                        capture_output=True)
    if rc.returncode != 0:
        print('javac failed:\n', rc.stdout, rc.stderr)
        return 1
    cls = os.path.join(CLASSES, 'io', 'flutter', 'plugins', 'GeneratedPluginRegistrant.class')
    print('compiled:', cls, os.path.getsize(cls), 'bytes')
    return 0


if __name__ == '__main__':
    sys.exit(main())
