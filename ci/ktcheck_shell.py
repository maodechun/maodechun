"""快速 Kotlin 类型检查：只编译 app 壳的 3 个 Kotlin 源文件。

用途：在跑完整 APK 构建（数分钟）之前，先秒级确认 ScanEngine.kt 语法/类型正确。
classpath 复用上一次构建的 build/classes（含生成的 R.class）。
"""
import os
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
PROJ = os.path.join(ROOT, 'bodhi_token')
JAVA = os.path.join(ROOT, 'toolchain', 'jdk', 'jdk-17.0.2', 'bin', 'java.exe')
KHOME = os.path.join(ROOT, 'toolchain', 'kotlin', 'home')
KLIB = os.path.join(KHOME, 'lib')
LIBS = os.path.join(PROJ, 'build', 'deps', 'libs')
ANDROID_JAR = os.path.join(ROOT, 'toolchain', 'sdk', 'platforms', 'android-34', 'android.jar')
OUT = os.path.join(PROJ, 'build', 'ktcheck')
SRC = os.path.join(PROJ, 'android', 'app', 'src', 'main', 'kotlin')

sources = []
for base, _dirs, files in os.walk(SRC):
    for f in files:
        if f.endswith('.kt'):
            sources.append(os.path.join(base, f))

dep_jars = sorted(os.path.join(LIBS, f) for f in os.listdir(LIBS) if f.endswith('.jar'))
cp = [ANDROID_JAR, os.path.join(PROJ, 'build', 'classes')] + dep_jars

os.makedirs(OUT, exist_ok=True)
argfile = os.path.join(PROJ, 'build', 'ktcheck_args.txt')
with open(argfile, 'w', encoding='utf-8') as f:
    f.write('-kotlin-home\n' + KHOME + '\n')
    f.write('-no-reflect\n')
    f.write('-nowarn\n')
    f.write('-jvm-target\n17\n')
    f.write('-d\n' + OUT + '\n')
    f.write('-classpath\n' + ';'.join(cp) + '\n')
    for s in sources:
        f.write(s + '\n')

cmd = [JAVA, '-Xmx4g',
       '-cp', ';'.join(os.path.join(KLIB, f) for f in os.listdir(KLIB)),
       'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler', '@' + argfile]
env = dict(os.environ)
env['JAVA_HOME'] = os.path.dirname(os.path.dirname(JAVA))
print('checking', len(sources), 'Kotlin sources ...')
r = subprocess.run(cmd, capture_output=True, text=True, encoding='utf-8',
                   errors='replace', env=env, timeout=1800)
print('rc =', r.returncode)
for line in (r.stdout or '').splitlines()[-40:]:
    print(line)
for line in (r.stderr or '').splitlines()[-20:]:
    print('[err]', line)
sys.exit(r.returncode)
