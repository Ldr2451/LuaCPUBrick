"""Compare IR node-kind histograms between two --dump-ir outputs."""
import collections
import re
import subprocess
import sys

WS = (r"C:\Users\Alessandro\AppData\Local\Temp\opencode\wirescript"
      r"\target\release\wirescript.exe")


def dump(src):
    p = subprocess.run([WS, "compile", src, "-o",
                        src + ".tmp.brz", "--dump-ir"],
                       capture_output=True, text=True, cwd=
                       r"C:\Users\Alessandro\AppData\Local\Temp\opencode"
                       r"\wirescript")
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
