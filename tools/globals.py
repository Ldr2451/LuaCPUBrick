"""Dump the chip's global slot table after a reset, to check the builtin ids.

  python -u tools/globals.py
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))), 'irrun'))
from irdump import dump_source
from irsims import Sim, Wire, _extract

nodes, wires, _ = dump_source(os.path.abspath('lua.ws'))
sim = Sim(nodes, [Wire(*w) for w in wires])
sim.inputs = {'program': 'print(1)', 'run': True}
sim.run(max_ticks=3000)

labels = {}
for nid, nd in nodes.items():
    v = _extract(nd.props.get('_label', ('raw', '')))
    if isinstance(v, str):
        labels.setdefault(v, nid)
for nm in ('gtag', 'gnum', 'gstr', 'GTAG_INIT', 'GNUM_INIT'):
    arr = sim.arrays.get(labels.get(nm))
    print(nm, 'len', len(arr) if arr is not None else None)
    if nm != 'gstr' and arr is not None:
        print('   ', ' '.join('%d:%s' % (i, arr[i]) for i in range(17, len(arr))))
gm = sim.maps.get(labels.get('gmap'))
print('gmap', gm if gm is None else list(gm.items())[-6:])
print('gmap', gm if gm is None else list(gm.items())[-6:])
