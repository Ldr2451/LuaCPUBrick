"""Locate the source line of a compiled node, by its _bindname or label.

  python -u tools/unsup_where.py lua.ws 27400 43375

tools/audit.py says *that* an expression failed to lower, and prints the node
ids; this says which line of lua.ws it came from, by searching for the binding
name the compiler recorded.
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'irrun'))
from irdump import dump_source
from irsims import _extract

src = sys.argv[1] if len(sys.argv) > 1 else 'lua.ws'
want = set(int(a) for a in sys.argv[2:])
nodes, wires, _ = dump_source(os.path.abspath(src))
lines = open(src, encoding='utf-8').read().splitlines()

for nid in sorted(want):
    nd = nodes.get(nid)
    if not nd:
        print(nid, 'not a node')
        continue
    props = {k: _extract(v) for k, v in nd.props.items()}
    name = props.get('_bindname') or props.get('_label') or ''
    print('nid=%d %s bind=%r' % (nid, nd.cls, name))
    # a binding name appears as `let <name>` / `var <name>` / `mod <name>(`
    for i, l in enumerate(lines, 1):
        if name and (('let %s ' % name) in l or ('var %s ' % name) in l
                     or ('mod %s(' % name) in l or ('%s =' % name) in l):
            print('   %s:%d: %s' % (src, i, l.strip()[:96]))
