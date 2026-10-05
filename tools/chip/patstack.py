"""Trace the matcher AND its backtrack stack: one row per tick.

pattrace.py reads the named state but not patSl, and the `+` floor is a
comparison between two slots of the top entry, so the slots are the thing to
read.

  python -u tools/chip/patstack.py 'print(string.match("abc", "%a+%c"))' 60
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "irrun"))
from irsims import ChipRunner  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(HERE))
FIELDS = ("patSt", "patP", "patI", "patSp", "patHit", "patQEnd", "patItemP")
CAP = 60000


def main(argv):
    src = None
    if argv and argv[0].endswith(".lua"):
        src = open(argv[0], encoding="utf-8").read()
        argv = argv[1:]
    elif argv:
        src = argv[0]
        argv = argv[1:]
    else:
        src = 'print(string.match("abc", "%a+%c"))'
    want = int(argv[0]) if argv else 60
    skip = int(argv[1]) if len(argv) > 1 else 0
    runner = ChipRunner(os.path.join(ROOT, "lua.ws"))
    runner.sim.reset()
    runner.sim.inputs = {"program": src, "run": True}
    rows = []
    state = {"on": False}

    def watch(sim, tick):
        r = [sim.chip_var(f, -1) for f in FIELDS]
        sp = r[3]
        if r[0] != 0 or r[2] != 0 or sp != 0:
            state["on"] = True
        if state["on"]:
            sl = sim.chip_array("patSl") or []
            entries = []
            for e in range(0, int(sp), 4):
                if e + 3 >= len(sl):
                    entries.append("k?(truncated)")
                    break
                extra = "" if sl[e] == 1 else ",%s" % sl[e + 1]
                entries.append("k%d(%s..%s%s)" % (sl[e], sl[e + 2],
                                                 sl[e + 1], extra))
            rows.append((tick, r, entries))

    runner.sim.run(CAP, on_tick=watch)
    print("%-6s %s  %s" % ("tick", "  ".join("%-7s" % f for f in FIELDS),
                           "stack (kind, lastStart..itemOrBegin)"))
    for tick, r, entries in rows[skip:skip + want]:
        print("%-6d %s  %s" % (tick, "  ".join("%-7s" % v for v in r),
                               " ".join(entries) or "-"))
    print("... %d matcher ticks total, chip log=%r"
          % (len(rows), "".join(runner.sim.log)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))