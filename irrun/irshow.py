"""Trace exec chain from a node."""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from irdump import dump_source
from irgraph import Graph, Wire

nodes, wires, nchips = dump_source(
    "C:\\Users\\Alessandro\\Documents\\New OpenCode Project\\tinylua\\lua.ws")

def trace_from(nid, port, depth=0, visited=None):
    if visited is None:
        visited = set()
    key = (nid, port)
    if key in visited:
        print("  " * depth + f"^ CYCLE: {nid}:{port}")
        return
    visited.add(key)
    inws = [w for w in wires if w.dst_id == nid and w.dst_port == port]
    if not inws:
        print("  " * depth + f"  [no exec inputs]")
        return
    print("  " * depth + f"<- exec inputs to {nid}:{port}:")
    for w in inws:
        src = nodes.get(w.src_id)
        src_out_ports = [wo.dst_port for wo in wires if wo.src_id == w.src_id and wo.src_port == w.src_port]
        print("  " * depth + f"  {w.src_id}:{w.src_port} ({src.cls if src else '?'})")
        # Find what triggers the source node's exec port
        src_in_exec = [wi for wi in wires if wi.dst_id == w.src_id and wi.dst_port == "ExecOut"]
        if src_in_exec:
            trace_from(w.src_id, "ExecOut", depth + 2, visited.copy())

# Trace what triggers each BufferTicks
for nid in [1184, 8771, 8790, 28588]:
    print(f"\n=== What triggers BufferTicks {nid}? ===")
    trace_from(nid, "ExecOut")
