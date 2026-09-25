"""Show the var nodes behind a name: is a state variable one node or several?

A WireScript `var` is a graph node; every read is an Exec_Var_Get hanging off it
and every write an Exec_Var_Set.  Two things make a state machine mispredict
with no error at all, and both are questions about the graph:

  - the name resolves to more than one var node, so a write in one mod never
    reaches the read in another (`let c` in three mods is three locals, and a
    file-level `var` plus a mod-local of the same name is a silent split);
  - a read whose Exec input is unwired, so the gate takes its default instead of
    the value -- an int default of 0 is a state machine that is always in state
    0.

  python -u tools/chip/vargraph.py fmtState
  python -u tools/chip/vargraph.py c --readers

  --readers also lists, per read, the classes it feeds, which is how a state's
  comparison gates get counted (more than one means the chain evaluates more than
  once per tick).
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, 'irrun'))
from irdump import dump_source

ARGS = [a for a in sys.argv[1:] if not a.startswith('--')]
WANT = ARGS[0] if ARGS else 'vmPc'
FILT = ARGS[1] if len(ARGS) > 1 else WANT
READERS = '--readers' in sys.argv

nodes, wires, _ = dump_source(os.path.join(ROOT, 'lua.ws'))
by_id = {nid: nd for nid, nd in nodes.items()}


def label(nid):
    lbl = by_id[nid].props.get('_label')
    if isinstance(lbl, tuple) and len(lbl) == 2 and isinstance(lbl[1], str):
        return lbl[1]
    return lbl if isinstance(lbl, str) else ''


drives, feds = {}, {}
WIRE = []
for w in wires:
    s, sp, d, dp = (w.src_id, w.src_port, w.dst_id, w.dst_port) \
        if hasattr(w, 'src_id') else tuple(w)
    WIRE.append((s, sp, d, dp))
    drives.setdefault((d, dp), []).append((s, sp))
    feds.setdefault((s, sp), []).append((d, dp))


def short(nid):
    cls = by_id[nid].cls.split('_')
    return '%s.%s(%d)' % (cls[-2] if len(cls) > 1 else cls[0], cls[-1], nid)


exact = [nid for nid in sorted(nodes) if 'Pseudo_Var' in by_id[nid].cls
         and label(nid) == FILT]
vars_ = exact or [nid for nid in sorted(nodes) if 'Pseudo_Var' in by_id[nid].cls
                  and FILT in label(nid)]
if not exact and vars_:
    print('(no var named %r exactly; matching inside the name)' % FILT)
print('%d var node(s) labelled %r' % (len(vars_), FILT))
for vn in vars_:
    print('nid=%d %s pout=%s' % (vn, by_id[vn].cls, by_id[vn].pout))
    # a Var has no input pins: it hands out a VarRef, and every read or write is
    # a Get/Set node with that ref wired into its own VarRef port
    ins = sorted({d for s, sp, d, dp in WIRE if s == vn and sp == 'VarRef'})
    sets = [s for s in ins if 'Set' in by_id[s].cls or 'Assign' in by_id[s].cls]
    gets = [s for s in ins if 'Get' in by_id[s].cls or 'Read' in by_id[s].cls]
    incs = [s for s in ins if 'Increment' in by_id[s].cls]
    kinds = {}
    for s in ins:
        kinds[by_id[s].cls.split('_')[-1]] = kinds.get(by_id[s].cls.split('_')[-1], 0) + 1
    print('  %s' % ' '.join('%s=%d' % kv for kv in sorted(kinds.items())))
    print('  %d write(s): %s' % (len(sets), ' '.join(short(s) for s in sets)))
    if incs:
        print('  %d increment(s): %s' % (len(incs), ' '.join(short(s) for s in incs)))
    print('  %d read(s):  %s' % (len(gets), ' '.join(short(g) for g in gets)))
    for s in sets + incs:
        ins2 = [(x, dp) for x, sp, d, dp in WIRE if d == s]
        print('    %s pin=%s in=%s' % (short(s), by_id[s].pin,
              ' '.join('%s<-%s' % (dp, short(x)) for x, dp in ins2)))
    for g in gets:
        ex = [s for s, _ in drives.get((g, 'Exec'), [])]
        note = '' if ex else '   Exec UNWIRED -- this read never fires'
        outs = sorted({d for p in by_id[g].pin for d, _ in drives.get((g, p[0]), [])})
        fed = ' '.join(sorted({by_id[o].cls.split('_')[-1] for o in outs}))
        if not ex:
            print('    %s%s feeds %s' % (short(g), note, fed))
        elif READERS:
            print('    %s exec<-%s feeds %s'
                  % (short(g), ','.join(sorted({short(s) for s in ex})), fed))
