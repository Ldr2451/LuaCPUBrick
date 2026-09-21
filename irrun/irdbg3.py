"""Trace exec_queue at each tick."""
import sys, os
sys.path.insert(0, 'tinylua')
sys.path.insert(0, 'tinylua/irrun')
from irdump import dump_source
from irgraph import Graph, Wire
from irsims import Sim, MAX_TICKS

WS_PATH = 'C:\\Users\\Alessandro\\Documents\\New OpenCode Project\\tinylua\\lua.ws'
nodes, wires, nchips = dump_source(WS_PATH)
sim = Sim(nodes, [Wire(*w) for w in wires])

for tick in range(20):
    sim.tick = tick
    sim.tick_done = set()
    if tick > 0:
        for nid in sim.input_ids:
            sim.exec_queue.add((nid, "RER_Output"))
    for nid in sorted(sim.nodes):
        if "WireGraphPseudo_Var" in sim.nodes[nid].cls:
            sim._do_literal(nid)
    if not sim.exec_queue:
        print("HALT at tick " + str(tick))
        break
    if tick < 15:
        q_sorted = sorted(sim.exec_queue, key=lambda x: x[0])
        q_str = str([(nid, port) for nid, port in q_sorted[:30]])
        def_str = str(list(sim._deferred.keys()))
        print("TICK " + str(tick) + " qsz=" + str(len(sim.exec_queue)) + " fired=" + str(len(sim.fired)) + " def=" + def_str)
    next_q = set()
    for (nid, port) in sorted(sim.exec_queue, key=lambda x: x[0]):
        if (nid, port) in sim.tick_done:
            continue
        sim.tick_done.add((nid, port))
        sim.fired.add((nid, port))
        node = sim.nodes[nid]
        sim._exec_node(nid, node, next_q)
    for tgt in sim._deferred.get(tick, []):
        next_q.add(tgt)
    sim._deferred = {k: v for k, v in sim._deferred.items() if k > tick}
    sim.exec_queue = next_q

print("\nKey nodes in fired:")
for nid in [1184, 46052, 46055, 2799, 8770, 8771, 1182, 46054]:
    key = (nid, "Output") if nid in [1184, 46052, 46055, 2799, 8770, 8771, 1182, 46054] else (nid, "Exec")
    print("  " + str(nid) + ": " + str((nid, "Output" if nid in [1184, 46052, 46054, 1182] else "Exec") in sim.fired))

print("\nFired nodes around 1184-46052 chain:")
for nid in [1182, 1184, 46052, 46054, 1188, 1189, 1191, 1192, 1194, 1197, 1198, 1199, 1200, 1245, 2799]:
    found = False
    for (nid2, port) in sim.fired:
        if nid2 == nid:
            print("  " + str(nid) + ":" + port + " FIRED")
            found = True
    if not found:
        print("  " + str(nid) + ": NOT FIRED")
