"""Where every else-if chain in the chip is, and how long it is.

The trap is a chain of about sixteen arms: past that the arms near the top stop
taking effect, silently and confidently -- the 33-arm state dispatch meant %d of
42 came out 00.  Two chains were fixed by splitting them in two, and the split
that works is named mods rather than nesting, because a nested group is the
same chain one level down.

So the question is worth being able to ask without reading the file: how long is
each chain, which arms does it hold, and which mod is it in?  A chain at 14 is
two arms from a miscompile nobody will notice until a program that uses it
prints the wrong number.

Every arm is counted by indentation, not by brace matching: an else-if at the
same indent as the chain's first arm is in the chain, and one deeper is a nested
if inside an arm (which is a chain of its own and gets reported on its own).

Usage: python -u tools/chainmap.py [pattern]
  pattern  only chains whose source contains it (case-insensitive substring)

The elapsed time goes out with the rest, because a check script that cannot say
how long it took is a check script nobody runs twice.
"""

import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tests.timing import Elapsed

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHIP = os.path.join(ROOT, "lua.ws")
LIMIT = 16

# the arm of a chain: `if <expr> {` or `} else if <expr> {`, which is how the
# chip writes them -- the brace that closes the previous arm shares the line
ARM = re.compile(r"^(\s*)(?:\}\s*)?(?:if|else\s+if)\s+(\S.*?)\s*\{\s*$")


BLOCK = re.compile(r"^(\s*)(?:mod|var|const|buffer|gate|on)\s+(\w+)")


def blocks(lines):
    """(start, end, name) for every mod/var/const/buffer block, by brace depth.

    The chain inside a mod's arm is in the mod, and a chain inside the op
    dispatch is in vmStep even though the nearest shallower line is an arm of
    the chain above it -- so the enclosing block has to come from the braces,
    not from the indentation of the last declaration before it.
    """
    out = []
    i = 0
    while i < len(lines):
        m = BLOCK.match(lines[i])
        if not m or "{" not in strip(lines[i]):
            i += 1
            continue
        depth = 0
        j = i
        while j < len(lines):
            bare = strip(lines[j])
            depth += bare.count("{") - bare.count("}")
            j += 1
            if depth <= 0:
                break
        out.append((i, j, m.group(2)))
        i = j if j > i + 1 else i + 1
    return out


def mod_at(blocks_, line):
    """The innermost block containing a 0-based line, as 'name:line'."""
    best = None
    for start, end, name in blocks_:
        if start <= line < end:
            if best is None or start > best[0]:
                best = (start, end, name)
    if best is None:
        return f"file:{line + 1}"
    return f"{best[2]}:{best[0] + 1}"


def strip(line):
    """The line without its comments and string literals, for brace counting.

    A brace inside a string is not a brace, and lua.ws has strings full of them
    ("{" in a pattern test, for one), so counting the raw line would end every
    chain early and say the chip is full of one-arm ifs.
    """
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


def chains(lines, blocks_):
    """Every chain, as (first_line, indent, mod, [arms]).

    A chain's arms are not adjacent lines -- each has a body between it and the
    next -- so the walk follows the braces to the end of each arm and then asks
    whether what follows is another arm at the same indent.

    Only a bare `if` starts a chain.  The `} else if` lines are its other arms
    and must not each be reported as a chain of their own, and a bare `if` at
    any depth is a chain, which is why the scan goes one line at a time: the
    chains inside a chain's arms are chains too, and the longest in the chip is
    the gate dispatch inside vmStep's op chain.
    """
    out = []
    i = 0
    while i < len(lines):
        m = ARM.match(lines[i])
        if not m or not re.match(r"^\s*if\b", lines[i]):
            i += 1
            continue
        indent = len(m.group(1))
        first = i
        arms = [(i, m.group(2))]
        j = i
        depth = 0
        while j < len(lines):
            bare = strip(lines[j])
            depth += bare.count("{") - bare.count("}")
            j += 1
            if depth <= 0:
                break
            if j < len(lines):
                m2 = ARM.match(lines[j])
                if (m2 and len(m2.group(1)) == indent
                        and re.match(r"^\s*\}?\s*else if ", lines[j])):
                    arms.append((j, m2.group(2)))
        out.append((first, indent, mod_at(blocks_, first), arms))
        i = first + 1
    return out


def main(argv):
    pat = argv[0].lower() if argv else ""
    with open(CHIP, encoding="utf-8") as fh:
        lines = fh.read().splitlines()
    blks = blocks(lines)
    rows = []
    for first, indent, mod, arms in chains(lines, blks):
        if len(arms) < 2:
            continue
        span = "\n".join(lines[first:first + len(arms) * 400])
        if pat and pat not in span.lower():
            continue
        rows.append((len(arms), first + 1, mod, arms))
    rows.sort(reverse=True)
    with Elapsed("chainmap") as _t:
        for count, line, mod, arms in rows:
            mark = "OVER" if count > LIMIT else ("at " if count == LIMIT else "    ")
            head = arms[0][1]
            print(f"{mark} {count:3d} arms  line {line:5d}  in {mod}  first: {head}")
        print(f"{len(rows)} chains of 2+ arms, longest {rows[0][0] if rows else 0}, "
              f"limit {LIMIT}")


if __name__ == "__main__":
    main(sys.argv[1:])
