"""Trace the VM one instruction at a time, with chosen registers or chip vars.

  python -u tools/trace_pc.py "for k,v in pairs(t) do end" "0,1,2,3"
  python -u tools/trace_pc.py "print(string.format('%d', 1))" "fmtState,fmtPos"

The second argument is a comma-separated watch list: a number is a VM register,
anything else is the label of a chip variable (fmtState, nxPc, retCountV ...).
Watching the chip's own variables is how a micro-step gets debugged -- the _fmt
state machine does its work between VM instructions, so the register trace shows
nothing happening.  Only the last TRACE_ROWS (default 40) changes are printed.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, 'irrun'))
from irdump import dump_source
from irsims import Sim, Wire, _extract

src = sys.argv[1] if len(sys.argv) > 1 else "function f() return 1,2 end local a, b = f() print(a, b)"
watch = sys.argv[2].split(',') if len(sys.argv) > 2 else []
nodes, wires, _ = dump_source(os.path.join(ROOT, 'lua.ws'))
sim = Sim(nodes, [Wire(*w) for w in wires])
sim.inputs = {'program': src, 'run': True}

labels = {}
for nid, nd in nodes.items():
    lbl = _extract(nd.props.get('_label', ('raw', '')))
    if isinstance(lbl, str):
        labels[nid] = lbl
by_label = {l: nid for nid, l in labels.items()}

# a watch entry is a register index, or the label of a chip variable
var_watch = {}
for w in watch:
    if w.lstrip('-').isdigit():
        continue
    if w in by_label:
        var_watch[w] = by_label[w]
regs = [int(x) for x in watch if x.lstrip('-').isdigit()]
WATCH = ['vmPc', 'vmBase', 'retCountV', 'vmHalted', 'fnDepth']
ids = {w: by_label.get(w) for w in WATCH}
vt, vn, vs = (by_label.get('vtag'), by_label.get('vnum'), by_label.get('vstr'))
nv = vn
rows = []
last = None

def fmt(tag, n, s):
    if tag == 0:
        return 'nil'
    if tag == 1:
        return 'n%.4g' % n
    if tag == 6:
        return 'i%d' % n
    if tag == 2:
        return repr(s)
    if tag == 4:
        return 'fn%.0f' % n
    if tag == 5:
        return 'tbl%.0f' % n
    return 't%d:%.4g' % (tag, n)

def hook(s, tick):
    global last
    pc = s.vars.get(ids['vmPc']) if ids.get('vmPc') is not None else None
    state = (pc, tuple(s.vars.get(r) for r in regs),
             tuple(s.vars.get(n) for n in var_watch.values()))
    if state == last:
        return
    last = state
    tag = s.arrays.get(vt) or []
    num = s.arrays.get(nv) or []
    st = s.arrays.get(vs) or []
    vals = []
    for r in regs:
        if r < len(tag):
            vals.append('r%d=%s' % (r, fmt(tag[r], num[r], st[r])))
    for name, nid in var_watch.items():
        vals.append('%s=%s' % (name, s.vars.get(nid)))
    head = " ".join("%s=%s" % (w, s.vars.get(ids[w])) for w in WATCH)
    rows.append("pc=%s %s %s" % (pc, head, " ".join(vals)))

r = sim.run(max_ticks=int(os.environ.get('TRACE_TICKS', '6000')), on_tick=hook)
print("log:", repr(r.get('log')), "err:", repr(r.get('outGlobals', {}).get('err')))
for line in rows[-int(os.environ.get('TRACE_ROWS', '40')):]:
    print(line)
