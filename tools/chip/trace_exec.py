"""Trace which chip nodes execute for a program, in order.

  python -u tools/chip/trace_exec.py "print(1)"
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, 'irrun'))
from irdump import dump_source
from irsims import Sim, Wire, _extract

def trace(ws, src, tail=160):
    nodes, wires, _ = dump_source(os.path.abspath(ws))
    sim = Sim(nodes, [Wire(*w) for w in wires])
    sim.inputs = {'program': src, 'run': True}
    labels = {}
    for nid, nd in nodes.items():
        lbl = _extract(nd.props.get('_label', ('raw', '')))
        if isinstance(lbl, str):
            labels[nid] = lbl

    fire_log = []

    orig = sim._exec_node

    def arr_label(nid):
        nid = sim._arr_id(nid)
        return labels.get(nid, f"arr{nid}")

    def map_label(nid):
        nid = sim._map_id(nid)
        return labels.get(nid, f"map{nid}")

    def wrapped(nid, node, nq):
        cls = node.cls
        try:
            if "ArrayVar_Set" in cls:
                v = sim._in_val(nid, "Value", None)
                idx = sim._in_val(nid, "Index", None)
                fire_log.append((sim.tick, f"SET {arr_label(nid)}[{idx}] = {v}"))
            elif "ArrayVar_Push" in cls:
                v = sim._in_val(nid, "Value", None)
                fire_log.append((sim.tick, f"PUSH {arr_label(nid)} {v}"))
            elif "Var_Set" in cls and "ArrayVar" not in cls:
                v = sim._find_value_input(nid)
                vid = sim._var_id(nid)
                fire_log.append((sim.tick, f"VARSET {labels.get(vid, f'var{vid}')} = {v}"))
            elif "MapVar_Set" in cls:
                v = sim._in_val(nid, "Value", None)
                k = sim._in_val(nid, "Key", None)
                fire_log.append((sim.tick, f"MAPSET {map_label(nid)}[{k!r}] = {v}"))
        except Exception as e:
            fire_log.append((sim.tick, f"ERR {cls} {e}"))
        orig(nid, node, nq)

    sim._exec_node = wrapped
    sim.run(max_ticks=600)
    print(f"=== {ws} :: {src}  log={sim.log!r}")
    import re as _re
    pat = _re.compile(r'(cfNext|bop\b|bpa|bpb|bpc|fnDepth|gslotNext|gmap|locLen|ctlLoop|tmpS|tmpSStk)')
    shown = 0
    for tick, msg in fire_log:
        if pat.search(msg):
            print(f"  t{tick:3} {msg}")
            shown += 1
    print(f"  ({shown} relevant events)")


if __name__ == '__main__':
    ws = os.path.join(ROOT, 'lua.ws')
    progs = sys.argv[1:] or [
        "function f() return 1, 2 end print(f())",
        "function f() return 1 end print(f())",
    ]
    for i, p in enumerate(progs):
        if i:
            print()
        trace(ws, p)
