"""Ticks for pattern-heavy programs, two chips in one process.

Ticks, not wall clock: AGENTS.md is explicit that two processes read drift as a
30% difference, and the matcher change is a correctness fix whose runtime cost
is the thing worth knowing.

  python -u tools/chip/patcost.py [file.lua ...]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "irrun"))
from irsims import ChipRunner  # noqa: E402

CAP = 60000


def ticks(chip, src):
    runner = ChipRunner(os.path.abspath(chip))
    runner.sim.reset()
    runner.sim.inputs = {"program": src, "run": True}
    seen = {"n": 0}

    def watch(sim, tick):
        seen["n"] = tick

    runner.sim.run(CAP, on_tick=watch)
    return seen["n"], "".join(runner.sim.log).strip()


def main(argv):
    chips = [c for c in argv if c.endswith(".ws")]
    files = [a for a in argv if not a.endswith(".ws")]
    if not chips:
        chips = [os.path.join(ROOT, "lua.ws")]
    if not files:
        files = [os.path.join(HERE, "..", "..", "..",
                              "perfbench", "patterns.lua")]
        files = [f for f in files if os.path.exists(f)]
    names = [os.path.basename(c) for c in chips]
    print("%-22s %s" % ("program", "  ".join("%-14s" % n for n in names)))
    for f in files:
        src = open(f, encoding="utf-8").read()
        row = []
        for c in chips:
            t, log = ticks(c, src)
            row.append("%-14s" % ("%d%s" % (t, "" if len(log) < 40
                                            else " log=%d" % len(log))))
        print("%-22s %s" % (os.path.basename(f), "  ".join(row)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))