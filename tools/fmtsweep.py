"""Sweep the float conversions against the oracle, in batches.

%f %e %g are the conversions where being nearly right is being wrong: the last
digit of 0.15 at one place is decided by a difference of 5.5e-18, and a probe
that only tries tidy values never reaches it.  So this generates the awkward
ones -- decimals whose exact double expansion sits just above or below a tie,
random values across the magnitudes, the precision limits -- and compares every
one with PUC, sixteen to a program so the log's 32-append cap is not in the way.

    python -u tools/fmtsweep.py            # 96 values x precisions 0..15
    python -u tools/fmtsweep.py 400        # more values

A mismatch prints the value, the precision and both answers, so the failing case
is a program you can paste into tools/check.py.
"""
import os
import random
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "tests"))
from timing import Elapsed
from chipdiff import diff

BATCH = 32          # prints per program, the log's 32-append cap exactly
LIMIT = 9.007199254740992e15   # 2^53: above this the chip says so rather than guess


def tie_values():
    """Values whose exact expansion lands on or beside a decimal half, which is
    the whole difficulty: 0.15 * 10 is 1.5 in floating point and
    1.4999999999999999944... exactly, and the two round differently."""
    out = []
    for d in range(0, 400):
        for k in (1, 2, 5):
            out.append(d / k)
    for i in range(0, 60):
        out.append(i + 0.05)
        out.append(i + 0.15)
        out.append(i + 0.25)
        out.append(i + 0.35)
        out.append(i + 0.45)
        out.append(i + 0.55)
        out.append(i + 0.95)
        out.append(-(i + 0.05))
        out.append(-(i + 0.15))
        out.append(-(i + 0.45))
    return out


def random_values(n, seed=4242):
    rng = random.Random(seed)
    out = []
    for _ in range(n):
        kind = rng.randint(0, 3)
        if kind == 0:
            out.append(round(rng.uniform(-100000, 100000), rng.randint(0, 6)))
        elif kind == 1:
            out.append(rng.uniform(-1, 1) * 10.0 ** rng.randint(-12, 12))
        elif kind == 2:
            bits = rng.getrandbits(52)
            v = struct.unpack("<d", struct.pack("<Q", bits | (rng.randint(1, 2046) << 52)))[0]
            out.append(v)
        else:
            out.append(float(rng.randint(-10 ** 12, 10 ** 12)))
    return out


def lit(v):
    """A Lua literal that reads back as this double: %.17g round-trips, and a
    trailing .0 keeps the integer ones floats the way the chip tags them."""
    s = "%.17g" % v
    if "." not in s and "e" not in s and "E" not in s:
        s += ".0"
    return s


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 96
    conv = sys.argv[2] if len(sys.argv) > 2 else "f"
    with Elapsed("fmtsweep(%d values, %%%s)" % (n, conv)):
        # Values above 2^53 raise an error rather than print, and one error
        # takes the rest of the program with it, so they are left out here and
        # the error itself is a suite case.  What is measured here is whether
        # the digits are right, not where the range stops.
        vals = tie_values()[:240] + random_values(n)
        seen = set()
        uniq = []
        for v in vals:
            if v not in seen and v == v and abs(v) < LIMIT:
                seen.add(v)
                uniq.append(v)
        bad = 0
        ran = 0
        badprecs = []
        precs = [int(x) for x in os.environ.get("FMTSWEEP_P", "0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15").split(",")]
        for p in precs:
            for i in range(0, len(uniq), BATCH):
                chunk = uniq[i:i + BATCH]
                if conv == "f":
                    body = "".join("print(string.format('%%.%df', %s))\n" % (p, lit(v))
                                   for v in chunk)
                else:
                    body = "".join("print(string.format('%%.%d%s', %s))\n" % (p, conv, lit(v))
                                   for v in chunk)
                ok, got, want, err = diff(body, ticks=40000)
                ran += len(chunk)
                if not ok:
                    bad += 1
                    if p not in badprecs:
                        badprecs.append(p)
                    gl = got.split("\n")
                    wl = want.split("\n")
                    for k, v in enumerate(chunk):
                        g = gl[k] if k < len(gl) else "?"
                        w = wl[k] if k < len(wl) else "?"
                        if g != w:
                            print("  %%.%d%s of %-24s chip %-28s puc %s"
                                  % (p, conv, lit(v), repr(g), repr(w)))
                    if err:
                        print("  err: %s" % err)
                    if bad > 12:
                        print("  ... stopping after 12 failing batches")
                        print("compared %d values, %d batches differ, at precisions %s"
                              % (ran, bad, badprecs))
                        return
        print("%%.%s: %d values compared, %d mismatching batches, at precisions %s"
              % (conv, ran, bad, badprecs or "none"))


if __name__ == "__main__":
    main()
