"""Is the affordable %f algorithm correct, or only usually right?

string.format's float conversions need the correctly rounded decimal expansion
of a double.  The chip cannot afford that: a double's exact expansion runs to
55 digits for 0.1 and to 767 for a denormal, and getting it needs bignum
arithmetic.  What the chip *can* do in a few hundred ticks is scale by a power
of ten, take the integer part, and read digits off it -- one rounding, and no
way to tell a true tie from a rounded one.

This measures how often that differs from PUC, and what an exact bignum would
cost in ticks, so the choice is made on numbers rather than on taste.

    python -u tools/fmt/fmtdiff.py            # 2000 values, precisions 0..8
    python -u tools/fmt/fmtdiff.py 20000      # more values, same shape

The reference is PUC-Lua itself (tests/lua_oracle.py), not Python's formatter,
and the run first checks that Python agrees with PUC everywhere -- otherwise
the comparison would be measuring Python rather than the algorithm.
"""
import math
import os
import random
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "tests"))
from timing import Elapsed
import lua_oracle as OR


def scaled_fixed(v, p):
    """What a chip can afford: one multiply by 10^p, round, read digits.

    The rounding is the best a single-rounding scale can do: add a half and
    truncate, which gets 0.7 at precision 1 right (0.7 * 10 lands just under 7
    and the half carries it) and gets the true ties wrong, because a scaled
    value that lands exactly on .5 cannot be told from one that was rounded
    there.  Ties are taken to even, which is what PUC does.
    """
    neg = math.copysign(1.0, v) < 0
    x = -v if neg else v
    scale = 10.0 ** p
    s = x * scale
    if not math.isfinite(s):
        return None
    fl = math.floor(s)
    fr = s - fl
    if fr > 0.5:
        fl += 1
    elif fr == 0.5 and int(fl) % 2 == 1:
        fl += 1
    digits = str(int(fl))
    if p == 0:
        out = digits
    else:
        if len(digits) <= p:
            digits = "0" * (p - len(digits) + 1) + digits
        out = digits[:-p] + "." + digits[-p:]
    # the sign belongs to the value, not to the digits: PUC prints -0 for a
    # negative that rounds to zero, and dropping it is a whole category of
    # apparent disagreement that has nothing to do with the algorithm
    return ("-" if neg else "") + out


def py_fixed(v, p):
    return "%.*f" % (p, v)


def samples(n, seed=20260924):
    """Doubles worth converting: random bit patterns, tidy decimals, and the
    values that are famous for being where a conversion goes wrong."""
    rng = random.Random(seed)
    out = []
    for k in range(n):
        bits = rng.getrandbits(64)
        v = struct.unpack("<d", struct.pack("<Q", bits))[0]
        if math.isfinite(v):
            out.append(v)
    out += [0.1, 0.2, 0.3, 0.7, 1.5, 2.5, 0.5, 1e15, 1e16, 2.675, 1.005,
            0.125, 0.375, 8.835, 1.0 / 3.0, 2.0 / 3.0, 1e-300, 1e300,
            123456789.123456789, 0.05, 0.15, 0.25, 0.35, 1.1, 2.2, 3.3]
    # decimals with one to four places, which is what programs actually format
    for _ in range(n // 2):
        out.append(round(rng.uniform(-1000, 1000), rng.randint(1, 4)))
    return out


def oracle_fixed(vals, p):
    """PUC-Lua's own answer, one program, so the comparison is with the oracle.

    One io.write per value and no separator: the harness frames a write as
    \\0w\\0<text>\\2 and wants exactly three NUL-separated parts, so a separator
    inside the text is one part too many."""
    spec = "%." + str(p) + "f"
    lits = ", ".join(OR.lua_num_lit(v) for v in vals)
    src = ("local t = {%s}\nfor i = 1, #t do io.write(string.format('%s', t[i])) end"
           % (lits, spec))
    r = OR.oracle_run(src)
    if r.get("calls") is None:
        raise SystemExit("oracle: %s" % r.get("stderr"))
    out = [c[1] for c in r["calls"] if c and c[0] == "\0w"]
    if len(out) != len(vals):
        raise SystemExit("oracle returned %d of %d" % (len(out), len(vals)))
    return out


def bignum_cost(v):
    """Word operations an exact conversion would cost, in the shape a chip can
    run: a decimal bignum in base 10^9, multiplied by 5^13 (1220703125, the
    largest power of five that fits in an int) once per 13 factors of two, and
    one tick per word multiply.  v = m * 2^e, so the exact expansion needs
    |e| factors of five and about log10(m * 5^|e|) digits."""
    m, e = math.frexp(abs(v))
    m = int(m * (1 << 53))
    e -= 53
    if e >= 0:
        return 0, 0            # an integer: no bignum, digits come straight off
    k = -e
    rounds = (k + 12) // 13
    words = (len(str(m)) + k * 0.69897) // 9 + 1
    return rounds, int(words)


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 2000
    with Elapsed("fmtdiff(%d values)" % n):
        vals = samples(n)
        batch = 200
        bad_total = 0
        seen_total = 0
        py_disagree = 0
        first = []
        costs = []
        # split by whether the scaled value could be held exactly: |v| * 10^p is
        # what the algorithm multiplies out, and a product past 2^53 has lost
        # the digits that %f has to print
        in_bad = in_seen = out_bad = out_seen = 0
        real_bad = real_seen = 0
        for p in range(0, 9):
            for i in range(0, len(vals), batch):
                chunk = vals[i:i + batch]
                want = oracle_fixed(chunk, p)
                for v, w in zip(chunk, want):
                    seen_total += 1
                    if py_fixed(v, p) != w:
                        py_disagree += 1
                    got = scaled_fixed(v, p)
                    if got is not None and got != w:
                        bad_total += 1
                    scaled = abs(v) * (10.0 ** p)
                    fits = scaled < 9007199254740992.0
                    if fits:
                        in_seen += 1
                        if got != w:
                            in_bad += 1
                    else:
                        out_seen += 1
                        if got != w:
                            out_bad += 1
                    if abs(v) < 1000000.0:
                        real_seen += 1
                        if got != w:
                            real_bad += 1
                            if len(first) < 12:
                                first.append((p, v, got, w))
        for v in samples(400):
            rounds, words = bignum_cost(v)
            if rounds:
                costs.append(rounds * words)
        costs.sort()
        print("values x precisions compared: %d" % seen_total)
        print("Python's formatter vs the oracle: %d disagreements" % py_disagree)
        print("the scaled algorithm vs the oracle: %d disagreements (%.4f%%)"
              % (bad_total, 100.0 * bad_total / seen_total))
        print("  where |v| * 10^p < 2^53: %d of %d (%.4f%%)"
              % (in_bad, in_seen, 100.0 * in_bad / max(in_seen, 1)))
        print("  where it does not:       %d of %d (%.2f%%)"
              % (out_bad, out_seen, 100.0 * out_bad / max(out_seen, 1)))
        print("  where |v| < 1e6:         %d of %d (%.4f%%)"
              % (real_bad, real_seen, 100.0 * real_bad / max(real_seen, 1)))
        for p, v, got, want in first:
            print("  %%.%df of %-24r scaled %-24s puc %s" % (p, v, got, want))
        if costs:
            print("exact bignum, word-multiplies per value: median %d, mean %d, "
                  "max %d (of 400 values)" % (costs[len(costs) // 2],
                                              sum(costs) // len(costs), costs[-1]))


if __name__ == "__main__":
    main()
