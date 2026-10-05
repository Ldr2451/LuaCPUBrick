"""Library run speed: wall time and ticks for string.rep at scale.

Boot dominates small probes, so a fast loop and a slow loop read the same --
which is how a real O(n^2)->O(n) win measures as nothing at all.  This runs
rep at sizes 4x apart on ONE chip build and prints both clocks, so the scaling
is the verdict: linear sizes with quadratic time was the old shape, linear
with linear is the new one.

  python -u tools/chip/repbench.py [n]

n is the largest repetition count (default 8000); three sizes n/16, n/4, n are
timed.  Answers are checked by length, because a fast wrong answer is not a
win.
"""
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "irrun"))
from irsims import ChipRunner  # noqa: E402

CAP = 400000


def one(runner, n):
    src = 'print(#string.rep("ab", %d, "-"))' % n
    want = 3 * n - 1
    t0 = time.time()
    runner.sim.reset()
    runner.sim.inputs = {"program": src, "run": True}
    ticks = 0

    def watch(sim, tick):
        pass

    runner.sim.run(CAP, on_tick=None)
    dt = time.time() - t0
    got = runner.sim.log.strip()
    ok = got == str(want)
    return dt, ok, got


def main(argv):
    chip = os.path.join(ROOT, "lua.ws")
    rest = []
    i = 0
    while i < len(argv):
        if argv[i] == "--chip":
            chip = argv[i + 1]
            i += 2
            continue
        rest.append(argv[i])
        i += 1
    top = int(rest[0]) if rest else 8000
    runner = ChipRunner(os.path.abspath(chip))
    print("rep bench (wall s, length ok?):")
    prev = None
    for n in (top // 16, top // 4, top):
        dt, ok, got = one(runner, n)
        ratio = ("x%.1f" % (dt / prev)) if prev else "--"
        print("  n=%-6d %.2fs  %s  ok=%s (got %s)" % (n, dt, ratio, ok, got))
        prev = dt
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
