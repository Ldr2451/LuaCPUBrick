"""Total gate fires for one program across chips: the game-wall proxy.

Ticks are identical-or-better and the game is slower; gates are the other
currency. Deterministic per chip+program: one run each, no repeats to argue.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "irrun"))
sys.path.insert(0, HERE)
from irsims import ChipRunner  # noqa: E402
from perfbench import measure  # noqa: E402


def main(argv):
    chips = []
    files = []
    i = 0
    while i < len(argv):
        if argv[i] == "--chip":
            chips.append(argv[i + 1])
            i += 2
            continue
        files.append(argv[i])
        i += 1
    chips = chips or [os.path.join(ROOT, "lua.ws")]
    runners = [(c, ChipRunner(os.path.abspath(c))) for c in chips]
    for f in files:
        src = open(f, encoding="utf-8").read()
        for c, runner in runners:
            # alternate once to share warmup, keep the best wall (perfbench rule)
            r1 = measure(runner, src, 30000)
            r2 = measure(runner, src, 30000)
            r = r1 if r1["wall"] < r2["wall"] else r2
            print("%-28s ticks=%d compile=%d bytecode=%d gates=%d "
                  "(%.1f/tick) wall=%.1fs log=%.40r" % (
                      os.path.basename(c), r["ticks"], r["compile_ticks"],
                      r["bytecode"], r["gates"],
                      r["gates"] / r["ticks"], r["wall"], r["log"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
