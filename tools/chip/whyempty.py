"""Why did this program print nothing?  Ask the chip, instead of guessing.

`check.py` reporting `chip='' err=''` is the worst shape a failure has: no output and
no error.  Two limits produce it -- MAX_TOKENS in the lexer and MAX_INSTR in bEmit --
and both set a flag that the parse then reports, so the flags are the answer.

  python -u whyempty.py 'local k = "by".."te" print(string[k]("A",1))'
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "irrun"))
from irsims import ChipRunner  # noqa: E402

FIELDS = ("lerr", "lerrLine", "lerrMsg", "perr", "perrMsg", "progOkV",
          "lsrc", "llen", "mainFid")


def main(argv):
    src = argv[0] if argv else 'print(1)'
    runner = ChipRunner(os.path.join(ROOT, "lua.ws"))
    runner.sim.reset()
    runner.sim.inputs = {"program": src, "run": True}
    runner.sim.run(20000)
    print("program: %r" % src)
    print("log:     %r" % runner.sim.log)
    for f in FIELDS:
        v = runner.sim.chip_var(f, "<absent>")
        if f == "lsrc":
            v = len(v) if isinstance(v, str) else v
        print("  %-9s %r" % (f, v))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
