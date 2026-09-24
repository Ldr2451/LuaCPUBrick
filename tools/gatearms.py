"""Report which vmStep locals the gate-dispatch arms use, and where they are.

The gate dispatch is one else-if chain of seventeen arms inside vmStep, which is
inlined four times, and pcall would make it nineteen.  The fix the file already
uses twice is two named mods, so the arms move out of vmStep and the mod
signatures have to be whatever the arms read: a, b, c, fid, nargs, mtArg,
mtSelf, tailN, nbase, np and the caller's `advanced` flag.

This is the measurement that decides the signatures, so it prints the source of
every arm with the locals it touches marked, and nothing is written.  The move
itself is done by tools/gatesplit.py once the signatures are settled.

Usage: python -u tools/gatearms.py [--src N]
"""

import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tests.timing import Elapsed

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHIP = os.path.join(ROOT, "lua.ws")
LOCALS = ["a", "b", "c", "fid", "nargs", "mtArg", "mtSelf", "tailN", "nbase",
          "np", "advanced"]


def strip_line(line):
    out = []
    i = 0
    n = len(line)
    while i < n:
        c = line[i]
        if c == "/" and i + 1 < n and line[i + 1] == "/":
            break
        if c == '"':
            i += 1
            while i < n:
                if line[i] == "\\":
                    i += 2
                    continue
                if line[i] == '"':
                    i += 1
                    break
                i += 1
            out.append('""')
            continue
        out.append(c)
        i += 1
    return "".join(out)


def main(argv):
    with open(CHIP, encoding="utf-8") as fh:
        lines = fh.read().splitlines()
    start = None
    for i, l in enumerate(lines):
        if l.strip().startswith("} else if op == 23 || op == 41 {"):
            start = i
            break
    if start is None:
        print("op 23 arm not found")
        return 1
    # the fid chain: the first `if fid == 0 {` after it, and the arms after
    first = None
    for i in range(start, start + 200):
        if lines[i].strip().startswith("if fid == 0 {"):
            first = i
            break
    if first is None:
        print("fid chain not found")
        return 1
    indent = len(lines[first]) - len(lines[first].lstrip())
    arms = []
    j = first
    depth = 0
    while j < len(lines):
        bare = strip_line(lines[j])
        depth += bare.count("{") - bare.count("}")
        j += 1
        if depth <= 0:
            break
        if j < len(lines):
            nxt = lines[j]
            if (len(nxt) - len(nxt.lstrip())) == indent and \
                    re.match(r"^\s*\}?\s*else if ", nxt):
                arms.append(j)
    end = j
    arms.append(end)
    print(f"chain at line {first + 1}, {len(arms) - 1} arms, ends line {end}")
    used = {}
    for k in range(len(arms) - 1):
        lo, hi = arms[k], arms[k + 1]
        head = lines[lo].strip()
        body = "\n".join(lines[lo:hi])
        names = [v for v in LOCALS
                 if re.search(r"(?<![A-Za-z0-9_.])" + v + r"(?![A-Za-z0-9_])",
                              strip_line(body))]
        used[head] = names
        print(f"  {head[:70]:70s} {','.join(names)}")
    allnames = sorted({v for names in used.values() for v in names})
    print("every arm together needs:", ", ".join(allnames))
    with Elapsed("gatearms") as _t:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
