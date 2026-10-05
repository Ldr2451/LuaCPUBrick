"""Read arena values after a run: vaTop, frame stacks, cell cursor.

For the sequential-call leak: 100 calls complete, 500 die with "too many
captured locals live at once".  Something grows per call; this says what.

  python -u tools/chip/arenaprobe.py 'prog' [ticks]
"""
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "irrun"))
from irsims import ChipRunner, share_dump, sim_from_dump  # noqa: E402

WS = os.path.join(ROOT, "lua.ws")
VARS = ("vaTop", "frameSeq", "cloTop", "uTop")
ARRS = ("fVaB", "fFunc", "fBase")


def main(argv):
    src = argv[0] if argv else 'print(1)'
    ticks = int(argv[1]) if len(argv) > 1 else 20000
    tag = int(os.path.getmtime(WS))
    path = os.path.join(tempfile.gettempdir(),
                        "tinylua-ultprobe-%d.pkl" % tag)
    if not os.path.exists(path):
        share_dump(WS, path)
    runner = ChipRunner(sim=sim_from_dump(path))
    r = runner.run(src, ticks, None)
    print("program: %r" % src[:60])
    print("log: %r err: %r finished: %r" % (
        r.get('log', ''), r.get('outGlobals', {}).get('err', ''),
        runner.sim.finished))
    for v in VARS:
        print("  var %-10s %r" % (v, runner.sim.chip_var(v, "<absent>")))
    for a in ARRS:
        arr = runner.sim.chip_array(a)
        print("  arr %-10s len=%s tail=%s" % (
            a, None if arr is None else len(arr),
            None if not arr else arr[-3:]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
