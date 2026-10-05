"""Library run speed survey: wall time and ticks for a loop of calls.

Boot dominates small probes, so this runs REPS calls in a loop on one chip
build and reports wall seconds plus tick count.  Programs come as arguments
with REPS as `___` (three underscores) to keep shells from mangling quotes;
use @file with %% separators for several at once, like check.py.

  python -u tools/chip/libbench.py 200 'local s=0 for i=1,___ do s=s+string.len("ab") end print(s)'

Answers print, so correctness shows next to speed: a fast wrong answer fails
visibly.  Ticks come from the sim boundary the same way bootprobe reads them.
"""
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "irrun"))
from irsims import ChipRunner  # noqa: E402

CAP = 400000


def main(argv):
    reps = int(argv[0]) if argv and argv[0].isdigit() else 200
    progs = [a for a in argv[1:] if a]
    if not progs:
        progs = ['local s = 0 for i = 1,___ do s = s + string.len("ab") end '
                 'print(s)']
    runner = ChipRunner(os.path.join(ROOT, "lua.ws"))
    for p in progs:
        if p.startswith("@"):
            with open(p[1:], encoding="utf-8") as f:
                parts = [q for q in f.read().split("\n%%\n") if q.strip()]
        else:
            parts = [p]
        for src in parts:
            src = src.replace("___", str(reps))
            t0 = time.time()
            runner.sim.reset()
            runner.sim.inputs = {"program": src, "run": True}
            seen = {}

            def watch(sim, tick, seen=seen):
                if "first" not in seen and sim.log:
                    seen["first"] = tick

            runner.sim.run(CAP, on_tick=watch)
            dt = time.time() - t0
            print("%.2fs first=%s log=%r :: %s"
                  % (dt, seen.get("first"), runner.sim.log.strip()[:40],
                     " ".join(src.split())[:80]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
