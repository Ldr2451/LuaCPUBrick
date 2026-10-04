"""Trace the pattern matcher's own state, one row per tick.

`tools/chip/trace_pc.py` cannot see this: it samples at VM instruction boundaries
and a `_pat` gate is one whole call, so a micro-step machine shows up as a single
row no matter how many states it passes through.  The matcher's state IS named in
the graph, though -- patSt, patP, patI, patSp, patQ, patHit, patQEnd, patItemP,
patItemE -- so sampling those per tick reads the machine's actual path.

This exists because `("abc"):match(".*c")` hangs, the hand-trace reaches the right
answer in fifteen states, and therefore some write is being dropped.  Reading the
state is the only way to see which.

  python -u tools/chip/pattrace.lua_probe.py 'print(("abc"):match(".*c"))' 120
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "irrun"))
from irsims import ChipRunner  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(HERE))
FIELDS = ("patSt", "patP", "patPEnd", "patI", "patSp", "patQ", "patHit",
          "patQEnd", "patItemP", "patItemE", "patPlain")
CAP = 60000


def main(argv):
    src = argv[0] if argv else 'print(("abc"):match(".*c"))'
    want = int(argv[1]) if len(argv) > 1 else 60
    runner = ChipRunner(os.path.join(ROOT, "lua.ws"))
    runner.sim.reset()
    runner.sim.inputs = {"program": src, "run": True}
    rows = []
    state = {"on": False}

    def watch(sim, tick):
        r = tuple(sim.chip_var(f, -1) for f in FIELDS)
        # only rows where the matcher is actually running; the boot is thousands
        # of ticks of parse with patSt parked at 0
        if r[0] != 0 or r[5] != 0 or r[3] != 0 or r[4] != 0:
            state["on"] = True
        if state["on"]:
            rows.append((tick,) + r)

    runner.sim.run(CAP, on_tick=watch)
    print("%-6s %s" % ("tick", "  ".join("%-7s" % f for f in FIELDS)))
    for row in rows[:want]:
        print("%-6d %s" % (row[0], "  ".join(
            ("%-7s" % ("" if v == "" else v)) for v in row[1:])))
    print("... %d matcher ticks total, chip log=%r" % (len(rows), runner.sim.log))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
