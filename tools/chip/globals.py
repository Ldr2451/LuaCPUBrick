"""Dump the chip's global slot table after a run, to check global resolution.

  python -u tools/chip/globals.py ["local s = 'hi' print(s:upper())"]
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__)))), 'irrun'))
from irdump import dump_source
from irsims import Sim, Wire, _extract

nodes, wires, _ = dump_source(os.path.abspath('lua.ws'))
sim = Sim(nodes, [Wire(*w) for w in wires])
sim.inputs = {'program': sys.argv[1] if len(sys.argv) > 1 else 'print(1)', 'run': True}
r = sim.run(max_ticks=8000)

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
print('gmap', sorted((gm or {}).items(), key=lambda kv: kv[1]))
gt = sim.arrays.get(labels.get('gtag')) or []
gn = sim.arrays.get(labels.get('gnum')) or []
gs = sim.arrays.get(labels.get('gstr')) or []
for name, slot in sorted((gm or {}).items(), key=lambda kv: kv[1]):
    i = int(slot)
    if i < len(gt) and gt[i] != 0:
        print('  %-8s slot=%-3d tag=%d num=%.6g str=%r' % (name, i, gt[i], gn[i], gs[i]))
print('log', repr(r.get('log')), 'err', repr(r.get('outGlobals', {}).get('err')))
