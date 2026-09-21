"""Trace exec chain around loop trigger nodes 46052 and 46055."""
import sys, os
sys.path.insert(0, 'tinylua/irrun')
from irdump import dump_source

WS_PATH = 'C:\\Users\\Alessandro\\Documents\\New OpenCode Project\\tinylua\\lua.ws'
nodes, wires, nchips = dump_source(WS_PATH)

def trace_node(nid):
    n = nodes[nid]
    print(f"\n=== Node {nid}: {n.cls} ===")
    print(f"  props: {n.props}")
    print(f"  pin: {n.pin}")
    print(f"  pout: {n.pout}")
    # In wires
    in_ws = [w for w in wires if w[2] == nid]
    print(f"  in-wires ({len(in_ws)}):")
    for w in in_ws:
        src = nodes.get(w[0])
        print(f"    {w[0]}:{w[1]} ({src.cls if src else '?'}) -> {w[3]}")
    # Out wires
    out_ws = [w for w in wires if w[0] == nid]
    print(f"  out-wires ({len(out_ws)}):")
    for w in out_ws:
        dst = nodes.get(w[2])
        print(f"    {w[1]} -> {w[2]}:{w[3]} ({dst.cls if dst else '?'})")

for nid in [46052, 46055, 1184, 8771, 8790]:
    trace_node(nid)
