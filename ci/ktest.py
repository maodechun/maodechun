"""Kotlin 编译器最小验证：用标准 kotlin-home 布局驱动 K2JVMCompiler。"""
import os
import subprocess

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
JAVA = os.path.join(ROOT, 'toolchain', 'jdk', 'jdk-17.0.2', 'bin', 'java.exe')
KHOME = os.path.join(ROOT, 'toolchain', 'kotlin', 'home')
LIB = os.path.join(KHOME, 'lib')

cp_parts = [os.path.join(LIB, n) for n in sorted(os.listdir(LIB))]
cp = ';'.join(cp_parts)
print('kotlin-home:', KHOME)
print('classpath entries:', len(cp_parts))

SRC = os.path.join(ROOT, 'build_temp', 'ktest', 'Hello.kt')
OUT = os.path.join(ROOT, 'build_temp', 'ktest', 'out')
os.makedirs(OUT, exist_ok=True)

cmd = [
    JAVA,
    '-cp', cp,
    'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler',
    '-kotlin-home', KHOME,
    '-nowarn',
    '-jvm-target', '17',
    '-d', OUT,
    SRC,
]
env = dict(os.environ)
env['JAVA_HOME'] = os.path.dirname(os.path.dirname(JAVA))
print('running kotlinc ...')
r = subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=900)
print('rc =', r.returncode)
if r.stdout:
    print('--- stdout ---')
    print(r.stdout[:4000])
if r.stderr:
    print('--- stderr ---')
    print(r.stderr[:4000])

found = []
for dp, _, fns in os.walk(OUT):
    for fn in fns:
        found.append(os.path.relpath(os.path.join(dp, fn), OUT))
print('outputs:', found)
