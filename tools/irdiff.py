"""Compare IR node-kind histograms between two .ws files.

  python -u tools/irdiff.py lua_full.ws lua.ws

Use it to see what a change costs in gates, and to find what to simplify when
the total moves the wrong way.
"""
import collections
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, 'irrun'))
from irdump import WS_EXE, WS_DIR


def dump(src):
    p = subprocess.run([WS_EXE, "compile", src, "-o", src + ".tmp.brz",
                        "--dump-ir"],
                       capture_output=True, text=True, cwd=WS_DIR)
    return p.stderr


def hist(err):
    c = collections.Counter()
    for line in err.splitlines():
        m = re.match(r"\s*\[(\w+)\] \S+ \((BrickComponentType_\S+?)\)", line)
        if m:
            c[m.group(2)] += 1
    return c


a = hist(dump(sys.argv[1]))
b = hist(dump(sys.argv[2]))
keys = sorted(set(a) | set(b))
print(f"{'kind':60s} {'old':>7s} {'new':>7s} {'delta':>7s}")
tot_a = tot_b = 0
for k in keys:
    d = b.get(k, 0) - a.get(k, 0)
    tot_a += a.get(k, 0)
    tot_b += b.get(k, 0)
    if d != 0:
        print(f"{k:60s} {a.get(k, 0):7d} {b.get(k, 0):7d} {d:+7d}")
print(f"{'TOTAL':60s} {tot_a:7d} {tot_b:7d} {tot_b - tot_a:+7d}")
