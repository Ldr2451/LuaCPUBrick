"""How many programs would pay for a `](` trigger?  Count, do not guess.

libStrDyn firing on `](` is what catches a string VARIABLE reached by a name the
program assembled -- the last of the run-time-name holes.  The cost is that `](` is
also what ordinary table dispatch spells (`t[k](v)`), and every program containing
it installs the whole string library, which is about 9,000 ticks of parse.

So the decision needs a number: how many of the suite's programs contain `](`, and
therefore how many would pay.  Read off cases.py, which is the same list the suite
runs.

  python -u tools/chip/dynblast.py
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "tests"))
import cases  # noqa: E402

TRIGGERS = ("](", "string[", "\"[", ")[", "table[", "math[")


def computed_tonumber(tests):
    """Cases whose `tonumber(` is followed by something that is not a quote.

    These are the ones libTonumberHex's character check newly sends to the 2,779
    character hex walk -- the trigger is precise, but "precise" is not "free", and
    the number is what decides whether it stays.
    """
    out = []
    for t in tests:
        src = t[1]
        i = src.find("tonumber(")
        while i >= 0:
            c = src[i + 9:i + 10]
            if c and c not in "\"'":
                out.append(t[0])
                break
            i = src.find("tonumber(", i + 1)
    return out


def main():
    tests = cases.TESTS
    print("%d cases" % len(tests))
    for trig in TRIGGERS:
        n = [t[0] for t in tests if trig in t[1]]
        print("  %-8s %4d  %s" % (repr(trig), len(n), n[:6]))
    cn = computed_tonumber(tests)
    print("  computed tonumber( -> %4d  %s" % (len(cn), cn[:8]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
