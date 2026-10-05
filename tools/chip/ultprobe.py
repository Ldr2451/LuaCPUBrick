"""Run one program like the suite does: log + runtime err + finished.

tools/chip/whyempty.py reads the PARSE flags, so a program that raises at run
time looks identical to one that stalls (empty log, progOkV true).  The suite
reads outGlobals['err'] instead.  This prints all three, so empty-log failures
can be told apart.

  python -u ultprobe.py 'print(math.ult(9223372036854775807, 0))'
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "irrun"))
from irsims import ChipRunner  # noqa: E402


def main(argv):
    src = argv[0] if argv else 'print(1)'
    ticks = int(argv[1]) if len(argv) > 1 else 20000
    runner = ChipRunner(os.path.join(ROOT, "lua.ws"))
    r = runner.run(src, ticks, None)
    print("program: %r" % src)
    print("log:     %r" % r.get('log', ''))
    print("err:     %r" % r.get('outGlobals', {}).get('err', ''))
    print("finished: %r" % runner.sim.finished)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
