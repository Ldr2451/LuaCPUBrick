"""List gate classes the compiled chip uses that irsims.py has no handler for.

The sim dispatches on class-name fragments (`"Expr_Ceil" in cls`), so this reads
those fragments straight out of irsims.py: any gate the graph contains whose name
matches none of them would only fail in whichever program happens to touch it.

  python -u tools/unhandled.py lua.ws
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'irrun'))
from irdump import dump_source

src = sys.argv[1] if len(sys.argv) > 1 else 'lua.ws'
sim_src = open(os.path.join(ROOT, 'irrun', 'irsims.py'), encoding='utf-8').read()
# the fragments the dispatch actually tests: `"X" in cls`, `cls == "X"`, and
# the pseudo classes gates.py knows about
frags = set(re.findall(r'"([A-Za-z_][A-Za-z0-9_]*)"\s+in\s+cls', sim_src))
frags |= set(re.findall(r'cls\s*==\s*"([A-Za-z_][A-Za-z0-9_]*)"', sim_src))
frags |= set(re.findall(r'cls\.startswith\("([A-Za-z_][A-Za-z0-9_]*)"', sim_src))
import gates
frags |= {c.replace('BrickComponentType_', '') for c in gates.all_gate_classes()}

nodes, wires, _ = dump_source(os.path.abspath(src))
used = {}
for nid, nd in nodes.items():
    cls = nd.cls
    if cls.startswith('BrickComponentType_'):
        used[cls] = used.get(cls, 0) + 1


def handled(cls):
    return any(f in cls for f in frags)


missing = sorted((c, n) for c, n in used.items() if not handled(c))
print('%d gate classes used, %d fragments known, %d unhandled'
      % (len(used), len(frags), len(missing)))
for c, n in missing:
    print('   %-72s x%d' % (c.replace('BrickComponentType_', ''), n))
sys.exit(1 if missing else 0)
