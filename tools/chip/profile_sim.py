"""Where a program's simulated time goes.

  python -u tools/chip/profile_sim.py "print(1)" "print(string.len('hi'))"
      -> build time, then per program: wall clock, ticks, node executions
  python -u tools/chip/profile_sim.py --prof "print(string.len('hi'))"
      -> cProfile the first program, hottest functions first

Ticks and node executions say whether a cost is in the program (a big library
prepend, a long loop) or in the simulator (work per node execution).
"""
import cProfile
import io
import os
import pstats
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, 'irrun'))
from irsims import ChipRunner

prof = '--prof' in sys.argv
progs = [a for a in sys.argv[1:] if a != '--prof'] or ["print(1)"]
ticks = int(os.environ.get("PROBE_TICKS", "6000"))
rows = int(os.environ.get("PROFILE_ROWS", "18"))

t0 = time.time()
runner = ChipRunner(os.path.join(ROOT, 'lua.ws'))
print("build %.1fs  nodes=%d wires=%d"
      % (time.time() - t0, len(runner.sim.nodes), len(runner.sim.wires)),
      flush=True)

for i, src in enumerate(progs):
    sim = runner.sim
    sim.reset()
    sim.inputs = {'program': src, 'run': True}
    n_exec = [0]
    orig = sim._exec_node

    def counted(nid, node, nq, _orig=orig, _n=n_exec):
        _n[0] += 1
        return _orig(nid, node, nq)

    sim._exec_node = counted
    t0 = time.time()
    if prof and i == 0:
        pr = cProfile.Profile()
        pr.enable()
        r = sim.run(ticks)
        pr.disable()
    else:
        r = sim.run(ticks)
    dt = time.time() - t0
    sim._exec_node = orig
    print("%6.2fs  ticks=%5d  execs=%8d  log=%r  err=%r :: %s"
          % (dt, sim.tick + 1, n_exec[0], r.get('log', '')[:24],
             r.get('outGlobals', {}).get('runErrors', ''), src), flush=True)
    if prof and i == 0:
        s = io.StringIO()
        pstats.Stats(pr, stream=s).sort_stats('tottime').print_stats(rows)
        print(s.getvalue())
