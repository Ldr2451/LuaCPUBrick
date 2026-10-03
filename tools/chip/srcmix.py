"""What is the source made of?  Decides which lexer path is worth optimising.

The lexer has one path per region and they are not close in cost: a line comment
and a plain string are a single Find (O(1) in length), whitespace costs a
lexStep per character, and real code costs a lexStep plus parse work per token.
So "make the parser faster" is not one thing -- it depends entirely on which
region dominates the programs that matter.

Reports characters and estimated ticks per region, using the rates lexrate.py
measures: 0.500 ticks/char for whitespace, 1.30-1.75 for real source, and O(1)
for a comment or a plain string.

  python -u tools/chip/srcmix.py demo.lua lib/gmatch.lua
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))))


def classify(src):
    """(counts per region) with a tiny Lua lexer: good enough for proportions."""
    n = len(src)
    space = comment = string = 0
    i, in_str = 0, False
    code = 0
    while i < n:
        c = src[i]
        if in_str:
            string += 1
            if c == "\\":
                i += 2
                continue
            if c == '"':
                in_str = False
            i += 1
            continue
        if src.startswith("--", i):
            j = src.find("\n", i)
            j = n if j < 0 else j
            comment += j - i
            i = j
            continue
        if c == '"':
            in_str = True
            string += 1
            i += 1
            continue
        if c in " \t\r\n":
            space += 1
            i += 1
            continue
        code += 1
        i += 1
    return space, comment, string, code


def main(argv):
    files = argv or ["demo.lua"]
    lo, hi = 1.30, 1.75
    print("%-16s %7s %8s %8s %8s %10s" %
          ("file", "chars", "space", "comment", "string", "code"))
    for f in files:
        path = f if os.path.isabs(f) else os.path.join(ROOT, f)
        src = open(path, encoding="utf-8").read()
        sp, cm, st, cd = classify(src)
        # whitespace is charged the scan rate, code the real-source rate; a
        # comment or a plain string is one Find, so its cost is per-region not
        # per-character and is shown as a small constant per line/region
        regions = src.count("--") + src.count('"') // 2
        t_space = sp * 0.5
        t_code = cd * (lo + hi) / 2.0
        t_cs = regions * 17
        total = t_space + t_code + t_cs
        print("%-16s %7d %8d %8d %8d %10d" %
              (os.path.basename(f), len(src), sp, cm, st, cd))
        print("    modelled ticks: whitespace %.0f (%.0f%%)  code %.0f (%.0f%%)"
              "  comment+string regions %.0f (%.0f%%)"
              % (t_space, 100 * t_space / total, t_code, 100 * t_code / total,
                 t_cs, 100 * t_cs / total))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))