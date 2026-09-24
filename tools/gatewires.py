"""Show how the chip wires the string gates a micro-step depends on.

A direct `s.Substring(pos, len)` in WireScript should reach the
Expr_String_Substring gate with Start and Length driven by the two expressions
written.  When the formatter's character fetch returned the wrong thing, the
question was whether the gate was wired wrong or fed the wrong values -- and
that is a question about the graph, so answer it from the graph: every
Expr_String_Substring / CharacterToCodepoint node, what drives each input, and
which of our variables that driver is.

  python -u tools/gatewires.py [substring|codepoint|fromcode] [filter] [--ask]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, 'irrun'))
from irdump import dump_source
from irsims import _extract

WANT = {
    'substring': 'Expr_String_Substring',
    'codepoint': 'CharacterToCodepoint',
    'fromcode': 'CodepointToCharacter',
}[sys.argv[1] if len(sys.argv) > 1 else 'substring']
filt = sys.argv[2] if len(sys.argv) > 2 else ''
ASK = None
if '--ask' in sys.argv:
    from irsims import Sim, Wire as _W

nodes, wires, _ = dump_source(os.path.join(ROOT, 'lua.ws'))
by_id = {nid: nd for nid, nd in nodes.items()}
labels = {}
for nid, nd in nodes.items():
    v = _extract(nd.props.get('_label', ('raw', '')))
    if isinstance(v, str):
        labels[nid] = v

drives = {}
for w in wires:
    if hasattr(w, 'src_id'):
        s, sp, d, dp = w.src_id, w.src_port, w.dst_id, w.dst_port
    else:
        s, sp, d, dp = w
    drives.setdefault((d, dp), []).append((s, sp))
feds = {}
for (d, dp), srcs in drives.items():
    for s, sp in srcs:
        feds.setdefault(s, []).append((d, dp))

# A name filter resolves the variable to its Var node, then to every Get that
# reads it, then to whatever those Get outputs feed -- otherwise a filter can
# only match a gate's own label, and the string gates have none.
reads_var = set()
if filt:
    vnode = [nid for nid, nd in nodes.items()
             if labels.get(nid) == filt and 'Pseudo_Var' in nd.cls]
    print('var %r -> %d var node(s)' % (filt, len(vnode)))
    for vn in vnode:
        for (d, dp) in feds.get(vn, []):
            for (d2, dp2) in feds.get(d, []):
                reads_var.add((d2, dp2))
                for (d3, dp3) in feds.get(d2, []):
                    reads_var.add((d3, dp3))
    print('  %d gate input(s) reachable from it' % len(reads_var))

if '--ask' in sys.argv:
    from irsims import Sim, Wire as _Wire
    ASK = Sim(nodes, [_Wire(*w) for w in wires])
    ASK.inputs = {'program': 'print(string.format("%d", 42))', 'run': True}

hits = [nid for nid, nd in nodes.items() if WANT in nd.cls]
print('%d %s node(s)' % (len(hits), WANT))
shown = 0
for nid in sorted(hits):
    nd = by_id[nid]
    lbl = labels.get(nid, '')
    # the gate itself is usually unnamed, so a name filter has to match the
    # variables that feed it too -- that is how you find "the call on fmtSrc"
    feeds = [labels.get(s, '') for s, _ in drives.get((nid, 'Input'), [])]
    feeds += [labels.get(s, '') for s, _ in drives.get((nid, 'Start'), [])]
    if filt and filt not in lbl and not any(filt in f for f in feeds) \
            and (nid, 'Input') not in reads_var:
        continue
    shown += 1
    if shown > 12:
        print('  ...')
        break
    print('nid=%d %s  ports_in=%s' % (nid, nd.cls.split('_')[-1],
                                      [p[0] for p in nd.pin]))
    props = {k: _extract(v) for k, v in nd.props.items()
             if k in ('Start', 'Length', 'Value', 'PortLabel', 'Label')}
    if props:
        print('   props %s' % props)
    if ASK:
        from irsims import Sim, Wire
        sim = ASK
        vals = []
        for p in ('Input', 'Start', 'Length'):
            if any(p[0] == p[0] for p in nd.pin):
                try:
                    v = sim._in_val(nid, p, '<default>')
                except Exception as e:
                    v = '<err %s>' % e
                vals.append('%s=%r' % (p, v if not isinstance(v, str) or len(v) < 30
                                       else v[:30] + '...'))
        print('   sim would see: %s' % '  '.join(vals))
    for p in nd.pin:
        srcs = drives.get((nid, p[0]), [])
        if not srcs:
            print('   %-12s (unwired -> gate default)' % p[0])
        for s, sp in srcs:
            sl = labels.get(s, '')
            scls = by_id[s].cls.split('_')[-1] if s in by_id else '?'
            extra = ''
            props = by_id[s].props
            for key in ('Value', 'PortLabel', 'Label'):
                if key in props:
                    v = _extract(props[key])
                    if isinstance(v, str) and v:
                        extra = ' %s=%r' % (key, v[:28])
                        break
            print('   %-12s <- %s %s%s [%s.%s]' % (p[0], scls, sl, extra, s, sp))
