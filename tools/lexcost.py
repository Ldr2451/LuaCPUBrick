"""What does a faster lexer cost in gates?

The chip lexes four characters per tick because lexChunk() is four unrolled
lexStep() calls, and the library is prepended *source*, so every program that
names a library function pays that rate on the library's characters.  Raising
the unroll is the only global speed knob for it, and it costs gates linearly, so
measure it rather than guess: patch the unroll, compile, report nodes and wires.

  python -u tools/lexcost.py 4 8 12 16
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, 'lua.ws')
PAT = re.compile(r'(mod lexChunk\(\) \{\n)((?:  lexStep\(\)\n)+)(\})')


def with_steps(n):
    ws = open(SRC, encoding='utf-8', newline='').read()
    m = PAT.search(ws)
    if not m:
        sys.exit('lexChunk not found in %s' % SRC)
    body = '  lexStep()\n' * n
    return ws[:m.start()] + m.group(1) + body + m.group(3) + ws[m.end():]


def count(path):
    p = subprocess.run([sys.executable, '-u', os.path.join(ROOT, 'tools', 'audit.py'), path],
                       capture_output=True, text=True, cwd=ROOT)
    for line in p.stdout.splitlines():
        if line.startswith('nodes:'):
            parts = line.replace(':', '').split()
            return int(parts[1]), int(parts[3])
    sys.exit('audit failed: %s' % p.stdout[-400:])


base_n, base_w = count(SRC)
print('lexChunk 4 steps: %d nodes, %d wires (baseline)' % (base_n, base_w))
tmp = tempfile.mkdtemp(prefix='lexcost')
for n in [int(a) for a in sys.argv[1:]] + [8, 12, 16]:
    path = os.path.join(tmp, 'lua%d.ws' % n)
    with open(path, 'w', encoding='utf-8', newline='') as f:
        f.write(with_steps(n))
    nodes, wires = count(path)
    print('lexChunk %2d steps: %d nodes (%+d), %d wires (%+d)  -> %.2fx lexing'
          % (n, nodes, nodes - base_n, wires, wires - base_w, 4.0 / n))
shutil.rmtree(tmp, ignore_errors=True)
