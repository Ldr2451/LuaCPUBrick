"""What port types will the WireScript compiler accept?

The chip's IO is typed, so adding a port means knowing what the host calls the
type.  Rather than guess -- `object`, `reference`, `item`, `gameobject` are all
plausible spellings and only one of them may compile -- ask the compiler: write
a one-port net per candidate and report which are accepted.

  python -u tools/lib/porttypes.py object reference item gameobject any
"""
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, 'irrun'))
from irdump import WS_EXE, WS_DIR

CANDIDATES = sys.argv[1:] or ['object', 'reference', 'item', 'gameobject',
                             'any', 'entity', 'player']

TEMPLATE = '''@layout("cube")

@left in probe: %s
@right out echo: string = "ok"

var hold: %s = %s
'''

# what a variable of each type can be initialised with
INIT = {
    'float': '0.0', 'int': '0', 'bool': 'false', 'string': '"x"',
    'vector': 'Vec(0.0, 0.0, 0.0)', 'color': 'Color(0.0, 0.0, 0.0, 0.0)',
    'entity': 'null', 'entity[]': '[]', 'string[]': '[]', 'any': '0.0',
}


def try_type(t):
    init = INIT.get(t, '[]' if t.endswith('[]') else '0.0')
    src = TEMPLATE % (t, t, init)
    path = os.path.join(tempfile.gettempdir(), 'ptype_%s.ws'
                        % t.replace('[]', '_arr'))
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(src)
    p = subprocess.run([WS_EXE, 'compile', path, '--dump-ir'],
                       capture_output=True, text=True, cwd=WS_DIR)
    errs = [l.strip() for l in p.stderr.splitlines()
            if 'ERROR' in l or 'error' in l.lower() or 'unknown' in l.lower()]
    os.unlink(path)
    return p.returncode, errs


for t in CANDIDATES:
    rc, errs = try_type(t)
    verdict = 'ACCEPTED' if rc == 0 and not errs else 'rejected'
    print('%-12s %-9s rc=%d' % (t, verdict, rc))
    for e in errs[:2]:
        print('    ' + e[:150])
