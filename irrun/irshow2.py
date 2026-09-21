"""Check what the body loop looks like and what should produce output."""
import sys, os
sys.path.insert(0, 'tinylua/irrun')
from irdump import dump_source

WS_PATH = 'C:\\Users\\Alessandro\\Documents\\New OpenCode Project\\tinylua\\lua.ws'
nodes, wires, nchips = dump_source(WS_PATH)

# Find Var_Set nodes that set log-related vars
for nid in sorted(nodes):
    n = nodes[nid]
    if "Var_Set" in n.cls and nid > 1000:
        props = n.props
        for k, v in props.items():
            vstr = str(v)
            if "log" in vstr.lower() or "print" in vstr.lower() or "result" in vstr.lower() or "outNum" in vstr or "outStr" in vstr:
                print(f"  Var_Set {nid}: {k}={v}")

# Check what nodes connect to Output nodes
print("\n=== Output nodes ===")
for nid in sorted(nodes):
    n = nodes[nid]
    if n.kind == "Output":
        label = n.props.get("PortLabel", ("raw", ""))
        label = label[1] if isinstance(label, tuple) else label
        print(f"  Output {nid}: label={label}")
        outws = [w for w in wires if w.dst_id == nid]
        for w in outws:
            src = nodes.get(w.src_id)
            print(f"    <- {w.src_id}:{w.src_port} ({src.cls if src else '?'})")
