"""What does a compiled node actually record about its source?

`tools/nodbysize.py` can only attribute 4% of nodes, because 96% carry no
`_bindname`.  A gate sweep needs to know which mod the rest belong to, so this
enumerates the property names that appear across a build and how many nodes have
each -- that says whether a source line is recorded under a name I guessed
wrong, or not recorded at all.

    python -u tools/nodeprops.py [chip.ws]
"""
import os
import sys
from collections import Counter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'irrun'))
from irdump import dump_source
from irsims import _extract

path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'lua.ws')
nodes, wires, _ = dump_source(os.path.abspath(path))

seen = Counter()
sample = {}
for nid, nd in nodes.items():
    for k, v in nd.props.items():
        seen[k] += 1
        if k not in sample:
            sample[k] = (nid, _extract(v))

print('%d nodes' % len(nodes))
for k, n in seen.most_common():
    nid, v = sample[k]
    print('  %-24s %7d nodes   sample nid=%d %r' % (k, n, nid, v))
