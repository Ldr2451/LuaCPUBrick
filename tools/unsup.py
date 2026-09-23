"""Show the compiler's _Unsupported placeholders and what they were wired into.

A placeholder means the WireScript compiler silently gave up on an expression:
the chip builds, but the expression reads 0.  The node's label and the nodes it
feeds usually say which statement it was.

  python -u tools/unsup.py lua.ws
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))), 'irrun'))
from irdump import dump_source
from irsims import _extract

path = sys.argv[1] if len(sys.argv) > 1 else 'lua.ws'
nodes, wires, _ = dump_source(os.path.abspath(path))


def lab(nid):
    nd = nodes.get(nid)
    if not nd:
        return '?'
    v = _extract(nd.props.get('_label', ('raw', '')))
    return v if isinstance(v, str) else ''


bad = [nid for nid, nd in nodes.items() if 'Unsupported' in nd.cls]
print('%d placeholder(s)' % len(bad))
for nid in bad:
    print('nid=%d label=%r bind=%r' % (
        nid, lab(nid), _extract(nodes[nid].props.get('_bindname', ('raw', '')))))
    for w in wires:
        s, sp, d, dp = (w[0], w[1], w[2], w[3]) if not hasattr(w, 'dst_id') \
            else (w.src_id, w.src_port, w.dst_id, w.dst_port)
        if s == nid:
            print('   -> %d %s (%s %r)' % (d, dp, nodes[d].cls.split('_')[-1],
                                           lab(d)))
