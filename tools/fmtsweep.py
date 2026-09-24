"""Sweep the float conversions against the oracle, in batches.

%f %e %g are the conversions where being nearly right is being wrong: the last
digit of 0.15 at one place is decided by a difference of 5.5e-18, and a probe
that only tries tidy values never reaches it.  So this generates the awkward
ones -- decimals whose exact double expansion sits just above or below a tie,
random values across the magnitudes, the precision limits -- and compares every
one with PUC.

The batching is the whole speed of it.  One value per print meant one chip run
and one oracle process each, and 1140 comparisons took two minutes; io.write
appends raw text with no 64-character line cap, so a run carries GROUP values per
call and a program carries BATCH of them, which is 30-odd runs instead of 400
and a tenth of the time.  The log's 32-append cap is what bounds a program, not
the width of a line.

    python -u tools/fmtsweep.py            # 96 values x precisions 0..15
    python -u tools/fmtsweep.py 400        # more values
    FMTSWEEP_P=0,1,6 python -u tools/fmtsweep.py 64 e

A mismatch prints the value, the precision and both answers, so the failing case
is a program you can paste into tools/check.py.
"""
import os
import random
import struct
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "tests"))
from timing import Elapsed
from chipdiff import diff

GROUP = 6             # values per group: the group's text is one expression, and a
                      # call's window is MAXVALS = 16 registers, so eight values
                      # plus separators and the marker overflowed it with "too
                      # many results to select"
BATCH = 180           # values per program: 30 groups of 6, under the log's
                      # 32-append cap -- past it the oldest appends go and the
                      # comparison loses whole groups
# The chip's source buffer holds about 4 KB *including* the library the program
# pulls in, and %.6g of a random double is a 24-character literal: 48 values is
# 2.6 KB and runs, 96 is 5.1 KB and comes back "program too long".  Budget for
# the program's own text and leave the library's few hundred.
PROG_CHARS = 2800
LIMIT = 9.007199254740992e15   # 2^53: above this the chip says so rather than guess


def chunks(chunk, p, conv):
    """Split a run's values into programs that fit the chip's source buffer."""
    out = []
    cur = []
    for v in chunk:
        if cur and len(program(cur + [v], p, conv)) > PROG_CHARS:
            out.append(cur)
            cur = []
        cur.append(v)
    if cur:
        out.append(cur)
    return out


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


def program(chunk, p, conv):
    """One chip run for this many values: GROUP per io.write, each marked with
    its own number, and its text built a few values at a time.

    The marker is what makes the comparison survive a value that errors: one
    error takes the rest of the program with it, and comparing field by field
    across the whole log then reports every value after it as wrong.  Marked
    groups are found by their own marker, so one missing group costs one group.

    The text is built in pieces because a call's window is MAXVALS = 16
    registers: one expression holding a whole group's values and separators is
    fifteen operands, and the tail came out dropped -- the last value of every
    group read as its first seven characters.
    """
    spec = "%%.%d%s" % (p, conv)
    out = []
    for i in range(0, len(chunk), GROUP):
        grp = chunk[i:i + GROUP]
        out.append("local t = '#' .. %d .. ':'\n" % (i // GROUP))
        for k, v in enumerate(grp):
            piece = " .. '%s' .. string.format('%s', %s)" % (
                ";" if k == len(grp) - 1 else " ", spec, lit(v))
            out.append("t = t%s\n" % piece)
        out.append("io.write(t)\n")
    return "".join(out)


def groups(log):
    """The log back into {group number: [values]}, for comparing."""
    out = {}
    for piece in log.split("#")[1:]:
        head, _, rest = piece.partition(":")
        try:
            out[int(head)] = rest.rstrip(";").split(" ")
        except ValueError:
            pass
    return out


def part_chunks(part):
    """The values of one run, in the groups the program wrote them in."""
    return [part[i:i + GROUP] for i in range(0, len(part), GROUP)]


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 96
    conv = sys.argv[2] if len(sys.argv) > 2 else "f"
    with Elapsed("fmtsweep(%d values, %%%s)" % (n, conv)):
        # Values above 2^53 raise an error rather than print, and one error
        # takes the rest of the program with it, so they are left out here and
        # the error itself is a suite case.  What is measured here is whether
        # the digits are right, not where the range stops.
        vals = tie_values()[:240] + random_values(n)
        bad = 0
        ran = 0
        badprecs = []
        precs = [int(x) for x in os.environ.get("FMTSWEEP_P", "0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15").split(",")]
        for p in precs:
            # %e and %g also stop below a magnitude that depends on the
            # precision: the walk takes the fraction's leading zeros, the
            # mantissa's places and two more, and the double-double carries
            # sixteen of them exactly, so a value below 10^(p-14) cannot be
            # converted and says so.  %f scales only the fraction and has no
            # such limit.
            small = 10.0 ** (p - 14.0) if conv in ("e", "E", "g", "G") else 0.0
            seen = set()
            uniq = []
            for v in vals:
                if v not in seen and v == v and abs(v) < LIMIT and (v == 0.0 or abs(v) >= small):
                    seen.add(v)
                    uniq.append(v)
            t0 = time.time()
            here = 0
            runs = 0
            for i in range(0, len(uniq), BATCH):
                chunk = uniq[i:i + BATCH]
                for part in chunks(chunk, p, conv):
                    ok, got, want, err = diff(program(part, p, conv), ticks=200000)
                    ran += len(part)
                    here += len(part)
                    runs += 1
                    if not ok:
                        bad += 1
                        if p not in badprecs:
                            badprecs.append(p)
                        gv = groups(got)
                        wv = groups(want)
                        for gi, grp in enumerate(part_chunks(part)):
                            g = gv.get(gi, [])
                            w = wv.get(gi, [])
                            if g != w:
                                print("  group %d chip %r" % (gi, g))
                                print("  group %d puc  %r" % (gi, w))
                            for k, v in enumerate(grp):
                                gg = g[k] if k < len(g) else "?"
                                ww = w[k] if k < len(w) else "?"
                                if gg != ww:
                                    print("  %%.%d%s of %-24s chip %-28s puc %s"
                                          % (p, conv, lit(v), repr(gg), repr(ww)))
                        if err:
                            print("  err: %s" % err)
                        if "too long" in err:
                            # every value in this program is then unaccounted
                            # for, and the comparison that follows is noise
                            print("  PROG_CHARS is %d: lower it" % PROG_CHARS)
                            return
                        if bad > 12:
                            print("  ... stopping after 12 failing batches")
                            print("compared %d values, %d batches differ, at "
                                  "precisions %s" % (ran, bad, badprecs))
                            return
            dt = time.time() - t0
            print("  %%.%d%s  %d values in %d runs, %.1fs (%.0f values/s)"
                  % (p, conv, here, runs, dt, here / dt if dt else 0.0))
        print("%%.%s: %d values compared, %d mismatching batches, at precisions %s"
              % (conv, ran, bad, badprecs or "none"))


if __name__ == "__main__":
    main()
