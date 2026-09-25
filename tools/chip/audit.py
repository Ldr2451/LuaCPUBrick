"""Static audit of the compiled chip, from one build.

Three questions that all need the compiled graph, and each used to cost its own
six-second compile:

  placeholders   the WireScript compiler silently gives up on an expression it
                 cannot lower.  The node it leaves behind reads 0, so the chip
                 builds and the program misbehaves far from the cause.
  unhandled      the simulator dispatches on class-name fragments, so a gate the
                 graph uses that matches none of them only fails in whichever
                 program happens to touch it.
  size           node and wire counts, the gate-size proxy to watch when adding
                 compiler or library code.

  python -u tools/chip/audit.py [chip.ws]      (exit 1 if a placeholder or gap is found)
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, 'irrun'))
from irdump import dump_source
from irsims import _extract
import gates

path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'lua.ws')
nodes, wires, _ = dump_source(os.path.abspath(path))


def label(nid):
    nd = nodes.get(nid)
    if not nd:
        return '?'
    v = _extract(nd.props.get('_label', ('raw', '')))
    return v if isinstance(v, str) else ''


# --- placeholders ---------------------------------------------------------
bad = [nid for nid, nd in nodes.items() if 'Unsupported' in nd.cls]
print('%d placeholder(s)' % len(bad))
for nid in bad:
    print('nid=%d label=%r bind=%r' % (
        nid, label(nid), _extract(nodes[nid].props.get('_bindname', ('raw', '')))))
    for w in wires:
        s, sp, d, dp = (w[0], w[1], w[2], w[3]) if not hasattr(w, 'dst_id') \
            else (w.src_id, w.src_port, w.dst_id, w.dst_port)
        if s == nid:
            print('   -> %d %s (%s %r)' % (d, dp, nodes[d].cls.split('_')[-1],
                                           label(d)))

# --- gate classes the simulator has no handler for ------------------------
sim_src = open(os.path.join(ROOT, 'irrun', 'irsims.py'), encoding='utf-8').read()
frags = set(re.findall(r'"([A-Za-z_][A-Za-z0-9_]*)"\s+in\s+cls', sim_src))
frags |= set(re.findall(r'cls\s*==\s*"([A-Za-z_][A-Za-z0-9_]*)"', sim_src))
frags |= set(re.findall(r'cls\.startswith\("([A-Za-z_][A-Za-z0-9_]*)"', sim_src))
frags |= {c.replace('BrickComponentType_', '') for c in gates.all_gate_classes()}

used = {}
for nid, nd in nodes.items():
    if nd.cls.startswith('BrickComponentType_'):
        used[nd.cls] = used.get(nd.cls, 0) + 1
missing = sorted((c, n) for c, n in used.items()
                 if not any(f in c for f in frags))
print('%d gate classes used, %d fragments known, %d unhandled'
      % (len(used), len(frags), len(missing)))
for c, n in missing:
    print('   %-72s x%d' % (c.replace('BrickComponentType_', ''), n))

# --- size ----------------------------------------------------------------
print('nodes: %d  wires: %d' % (len(nodes), len(wires)))

sys.exit(1 if (bad or missing) else 0)
