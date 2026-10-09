"""Run one program like the suite does: log + runtime err + finished.

tools/chip/whyempty.py reads the PARSE flags, so a program that raises at run
time looks identical to one that stalls (empty log, progOkV true).  The suite
reads outGlobals['runErrors'] instead.  This prints all three, so empty-log failures
can be told apart.

The dump is cached by lua.ws mtime: compiling and indexing costs ~6s, loading
the pickle ~1s, so repeated probes on an unchanged chip stay fast.  Touching
lua.ws invalidates it, so a stale dump cannot lie.

  python -u ultprobe.py 'print(math.ult(9223372036854775807, 0))' [ticks]
"""
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "irrun"))
from irsims import ChipRunner, share_dump, sim_from_dump  # noqa: E402

WS = os.path.join(ROOT, "lua.ws")


def runner_cached():
    tag = int(os.path.getmtime(WS))
    path = os.path.join(tempfile.gettempdir(),
                        "tinylua-ultprobe-%d.pkl" % tag)
    if not os.path.exists(path):
        print("dump (lua.ws changed)...", flush=True)
        share_dump(WS, path)
    return ChipRunner(sim=sim_from_dump(path))


def main(argv):
    src = argv[0] if argv else 'print(1)'
    ticks = int(argv[1]) if len(argv) > 1 else 20000
    runner = runner_cached()
    r = runner.run(src, ticks, None)
    print("program: %r" % src)
    print("log:     %r" % r.get('log', ''))
    print("err:     %r" % r.get('outGlobals', {}).get('runErrors', ''))
    print("finished: %r" % runner.sim.finished)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
