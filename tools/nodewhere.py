"""Where the unattributed nodes are, by port name and node class.

96% of nodes carry no `_bindname` and nothing in the graph records a source
line, so the breakdown has to come from what the nodes *are*: a class (an add, a
compare, a literal) and a port name (`outNum0`, `self`, `program`).  Port names
are declared in mods, so counting by port attributes the bulk of the chip
without needing the compiler to change.

    python -u tools/nodeprops.py     ->  the property census (what exists)
    python -u tools/nodewhere.py     ->  the census that matters for a sweep
"""
import os
import sys
from collections import Counter, defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'irrun'))
from irdump import dump_source
from irsims import _extract

path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'lua.ws')
nodes, wires, _ = dump_source(os.path.abspath(path))

PORT_PROPS = ('InputA', 'InputB', 'Input', 'Key', 'Prefix', 'Search', 'Separator')

by_class = Counter()
by_port = Counter()
by_bind = Counter()
unattributed = 0

for nid, nd in nodes.items():
    by_class[nd.cls.replace('BrickComponentType_WireGraph_', '')] += 1
    bind = _extract(nd.props.get('_bindname', ('raw', '')))
    if isinstance(bind, str) and bind:
        by_bind[bind] += 1
        continue
    unattributed += 1
    port = ''
    for p in PORT_PROPS:
        v = _extract(nd.props.get(p, ('raw', '')))
        if isinstance(v, str) and v:
            port = '%s=%s' % (p, v)
            break
    if not port:
        v = _extract(nd.props.get('InputA', ('raw', 0)))
        if isinstance(v, (int, float)) and v:
            port = 'InputA=%d' % v
    by_port[port or '(no port name)'] += 1

total = len(nodes)
print('%d nodes, %d attributed by bind name, %d not' % (total, total - unattributed, unattributed))

print('\ntop classes among the unattributed:')
for c, n in by_class.most_common(20):
    print('  %-34s %7d' % (c, n))

print('\ntop port names among the unattributed:')
for p, n in by_port.most_common(25):
    print('  %-34s %7d' % (p, n))
