"""How much of the boot is PREPENDED library text rather than the program?

The loader builds `lsrc = lib .. program`, where `lib` is the concatenation of
whichever LIB_* pieces the program's text names.  That text is lexed AND parsed
-- functions get defined -- and never run.  It is charged at the piece rate
(1.30-1.75 ticks/char), so if it is a large share of the boot then the cheapest
parse win in the repo is not in the lexer at all: it is in making that text
shorter.

Reads the chip's own `lsrc` after a parse, so it measures what was actually
lexed rather than re-deriving the loader's conditions.

  python -u bootprobe2.py demo.lua lib/gmatch.lua
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "irrun"))
sys.path.insert(0, HERE)
from irsims import ChipRunner  # noqa: E402

ROOT = r"C:\Users\Alessandro\Documents\New OpenCode Project\tinylua"
CAP = 20000


def main(argv):
    files = argv or ["demo.lua"]
    runner = ChipRunner(os.path.join(ROOT, "lua.ws"))
    for f in files:
        path = f if os.path.isabs(f) else os.path.join(ROOT, f)
        src = open(path, encoding="utf-8").read()
        seen = {}

        def watch(sim, tick, seen=seen):
            if "first" not in seen and sim.log:
                seen["first"] = tick

        runner.sim.reset()
        runner.sim.inputs = {"program": src, "run": True}
        runner.sim.run(CAP, on_tick=watch)
        lsrc = runner.sim.chip_var("lsrc", "")
        lexed = len(lsrc) if isinstance(lsrc, str) else -1
        first = seen.get("first")
        prepended = lexed - len(src) if lexed > 0 else -1
        print("%-16s program=%-6d lexed=%-6s prepended=%-6s (%s%%) "
              "first_output=%s ticks"
              % (os.path.basename(f), len(src), lexed, prepended,
                 ("%.0f" % (100.0 * prepended / lexed)) if lexed > 0 else "?",
                 first))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))