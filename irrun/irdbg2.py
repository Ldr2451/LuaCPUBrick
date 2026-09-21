"""Debug: trace tick-by-tick what fires."""
import sys, os
sys.path.insert(0, 'tinylua/irrun')
from irdump import dump_source
from irgraph import Graph, Wire
from irsims import Sim

WS_PATH = 'C:\\Users\\Alessandro\\Documents\\New OpenCode Project\\tinylua\\lua.ws'
nodes, wires, nchips = dump_source(WS_PATH)
sim = Sim(nodes, [Wire(*w) for w in wires])

# Monkey-patch to trace
orig_exec = sim._exec_node
def traced_exec(nid, node, nq):
    if sim.tick < 5:
        print('tick=' + str(sim.tick) + ' exec: ' + str(nid) + ':' + str(node.cls))
    return orig_exec(nid, node, nq)
sim._exec_node = traced_exec

# Also trace deferred additions
orig_buffer = sim._do_buffer
def traced_buffer(nid, nq):
    props = nodes[nid].props
    ticks = 1
    zero = -1
    delay = 0 if (zero >= 0 and sim.tick >= zero) else (ticks if ticks > 0 else 1)
    target = sim.tick + delay
    if sim.tick < 5 or target < 100:
        print('tick=' + str(sim.tick) + ' buffer ' + str(nid) + ': delay=' + str(delay) + ' target=' + str(target))
    return orig_buffer(nid, nq)
sim._do_buffer = traced_buffer

result = sim.run(max_ticks=10)
print('Halted: ' + str(result['halted']))
print('Tick: ' + str(sim.tick))
print('Log: ' + repr(result['log'][:200]))
