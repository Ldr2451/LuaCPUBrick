"""Boot cost per named function: which feature's piece costs the parse.

Usage: python -u tools/chip/libprobe.py [--chip <path>] [name ...]
One ChipRunner, one boot per feature, ticks to first output.
Names: floor sqrt sub rep upper char insert unpack select ipairs clock base
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "irrun"))
from irsims import ChipRunner  # noqa: E402

CAP = 30000

FEATURES = [
    ("base", "print(1)"),
    ("floor", "print(math.floor(1.5))"),
    ("sqrt", "print(math.sqrt(4))"),
    ("sub", "print(string.sub('ab', 1))"),
    ("rep", "print(string.rep('a', 2))"),
    ("upper", "print(string.upper('a'))"),
    ("char", "print(string.char(97))"),
    ("insert", "local t = {} table.insert(t, 1) print(1)"),
    ("unpack", "print(table.unpack({1}))"),
    ("select", "print(select('#', 1))"),
    ("ipairs", "for k in ipairs({1}) do end print(1)"),
    ("clock", "print(clock())"),
    ("pack", "print(table.pack(1).n)"),
    ("move", "print(table.move({1}, 1, 1, 1) ~= nil)"),
    ("fmod", "print(math.fmod(7, 3))"),
    ("modf", "print(math.modf(1.5))"),
    ("max", "print(math.max(1, 5))"),
    ("min", "print(math.min(1, 5))"),
    ("deg", "print(math.deg(1))"),
    ("sin", "print(math.sin(0))"),
    ("randomseed", "math.randomseed(1) print(1)"),
    ("random", "print(math.random(1))"),
    ("ostime", "print(os.time({year=2024, month=1, day=1}) ~= nil)"),
    ("osdate", "print(os.date('%Y-%m-%d', 0))"),
]


def main(argv):
    chip = os.path.join(ROOT, "lua.ws")
    want = []
    i = 0
    while i < len(argv):
        if argv[i] == "--chip":
            chip = argv[i + 1]
            i += 2
            continue
        want.append(argv[i])
        i += 1
    runner = ChipRunner(os.path.abspath(chip))
    rows = []
    features = FEATURES
    if want and "base" not in want:
        features = [FEATURES[0]] + [f for f in FEATURES[1:] if f[0] in want]
    else:
        features = [f for f in FEATURES if not want or f[0] in want]
    for name, src in features:
        runner.sim.reset()
        runner.sim.inputs = {"program": src, "run": True}
        seen = {}

        def watch(sim, tick, seen=seen):
            if "first" not in seen and sim.log:
                seen["first"] = tick

        runner.sim.run(CAP, on_tick=watch)
        rows.append((name, seen.get("first")))
    base = dict(rows).get("base")
    print("%-8s %7s %9s" % ("feature", "boot", "marginal"))
    for name, first in rows:
        if first is None:
            print("%-8s %7s %9s   NO OUTPUT" % (name, "-", "-"))
        else:
            print("%-8s %7d %+9d" % (name, first, first - base))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
