"""Diagnostic: run sim, check visited nodes, trace critical chain."""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from irdump import dump_source
from irgraph import Graph, Wire
from irsims import Sim

HERE = os.path.dirname(os.path.abspath(__file__))
WS_PATH = "C:\\Users\\Alessandro\\Documents\\New OpenCode Project\\tinylua\\lua.ws"

nodes, wires, nchips = dump_source(WS_PATH)
print(f"IR: {len(nodes)} nodes, {len(wires)} wires")

sim = Sim(nodes, [Wire(*w) for w in wires])
result = sim.run(max_ticks=5000)
print(f"Halted: {result['halted']}")
print(f"Tick: {sim.tick}")
print(f"Log length: {len(result['log'])}")
print(f"Out globals: {list(result['outGlobals'].keys())}")

# Count how many nodes were visited via exec_done
exec_done_count = len(sim.exec_done)
print(f"Exec done count: {exec_done_count}")

# Check what nodes were visited
visited_nodes = set(nid for nid, port in sim.exec_done)
print(f"Unique visited node IDs: {len(visited_nodes)}")

# Check nodes in range 4000-7000 (body gates)
body_visited = [nid for nid in visited_nodes if 4000 <= nid <= 7000]
print(f"Body nodes visited (4000-7000): {len(body_visited)}")
if body_visited:
    print(f"  range: {min(body_visited)}-{max(body_visited)}")

# Check nodes in range 8000-10000
mid_visited = [nid for nid in visited_nodes if 8000 <= nid <= 10000]
print(f"Mid nodes visited (8000-10000): {len(mid_visited)}")

# Check Var_Set lstage nodes
for nid in visited_nodes:
    n = nodes[nid]
    if "Var_Set" in n.cls and nid > 1000:
        props = n.props
        for k, v in props.items():
            if "lstage" in str(k).lower() or "stage" in str(k).lower():
                print(f"  Var_Set {nid}: {k}={v}")
