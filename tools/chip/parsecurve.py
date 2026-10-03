"""Is parse cost linear in program length?  A super-linear term is free to fix.

lexrate.py prices a piece with `chars * rate`, which ASSUMES linearity.  Every
rate in the repo rests on that, and nothing has ever checked it past 120
statements.  If any stage rescans -- the shunting yard, a patch list, a local
lookup that walks a table -- the cost grows faster than the text and the model
understates a big program by more than its own factors.

Prints ticks per statement at four sizes, so the trend is visible rather than
fitted away: a flat column is linear, a rising one is the bug.

  python -u tools/chip/parsecurve.py
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "irrun"))
from irsims import ChipRunner  # noqa: E402

CAP = 60000
SHAPES = {
    # assign: the lexrate `assign` shape, 17.5 ticks a statement
    "assign": ("local acc = 0\n", "acc = acc + %d\n", "print(acc)\n"),
    # nested locals: more live locals, so a resolver that walks them shows up
    "locals": ("", "local v%d = 7\n", "print(v0)\n"),
    # a growing table: a hash insert per statement
    "table": ("local t = {}\n", "t[%d] = 7\n", "print(#t)\n"),
}


def main():
    runner = ChipRunner(os.path.join(ROOT, "lua.ws"))
    for name, (head, body, tail) in SHAPES.items():
        print("== %s" % name)
        prev = None
        for n in (50, 100, 200, 400):
            src = head + "".join(body % i for i in range(n)) + tail
            seen = {}

            def watch(sim, tick, seen=seen):
                if "first" not in seen and sim.log:
                    seen["first"] = tick

            runner.sim.reset()
            runner.sim.inputs = {"program": src, "run": True}
            runner.sim.run(CAP, on_tick=watch)
            t = seen.get("first")
            if t is None:
                print("   n=%-4d NEVER PRINTED (%d chars)" % (n, len(src)))
                break
            per = t / float(n)
            ratio = "" if prev is None else "  x%.2f for 2x the text" % (
                t / float(prev)) if prev else ""
            print("   n=%-4d chars=%-5d first_output=%-6d %.2f ticks/stmt%s"
                  % (n, len(src), t, per, ratio))
            prev = t
    return 0


if __name__ == "__main__":
    sys.exit(main())