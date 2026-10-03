"""Add an opcode to the fast path, by copying its arm out of vmStep.

`vmBurst` gives a tick four cheap dispatches and one full one, and a cheap
dispatch that meets an opcode it does not handle returns having done NOTHING --
so ONE unhandled opcode in a loop body takes that loop from five instructions per
tick to one.  tools/chip/opcount.py measures which opcodes are actually executed
and which of those miss; this adds the ones worth adding.

The arm is COPIED, never re-derived: it is extracted from vmStep verbatim and
dedented, so `tools/chip/twopaths.py` (which compares the two bodies) keeps
passing.  A re-typed arm is how the two copies drifted before, and the pow arm
that drifted answered -0.0 as 0.0 in a program that only ever ran the fast copy.

HALT stays last in the chain: it is the catch-all, and in first position its
failed comparison is paid by every instruction the step ever dispatches.

The guard gains one `|| op == N` term per opcode.  That is gates, not ticks --
`||` does not short-circuit here, so every fast dispatch pays every term.

  python -u tools/chip/fastarm.py 29 30 --check
  python -u tools/chip/fastarm.py 29 30
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))))
WS = os.path.join(ROOT, "lua.ws")


def find_arm(lines, lo, hi, op):
    """(start, end) of the top-level arm for `op`, by brace depth."""
    depth = 0
    start = None
    base = None
    for i in range(lo, hi):
        l = lines[i]
        if start is None:
            m = re.match(r"\s*(\} else if|if) op == (\d+)(.*)\{$", l)
            if m and int(m.group(2)) == op and base is None:
                start = i
                head_open = l.count("{")
                base = depth
                depth += l.count("{") - l.count("}")
                continue
            depth += l.count("{") - l.count("}")
            continue
        depth += l.count("{") - l.count("}")
        if depth == base and l.strip() == "}":
            return start, i
    return None


def main(argv):
    check = "--check" in argv
    ops = [int(a) for a in argv if a.isdigit()]
    if not ops:
        print(__doc__)
        return 1
    lines = open(WS, encoding="utf-8", newline="").read().split("\n")

    v0 = next(i for i, l in enumerate(lines) if re.match(r"chip vmStepFast\(", l))
    v1 = next(i for i, l in enumerate(lines) if re.match(r"mod vmBurst\(", l))
    s0 = next(i for i, l in enumerate(lines) if re.match(r"mod vmStep\(\)", l))

    taken = []
    for op in ops:
        got = find_arm(lines, s0, v0, op)
        if got is None:
            print("  op %-3d NOT FOUND in vmStep" % op)
            return 1
        taken.append((op, got))
        print("  op %-3d lines %d-%d (%d lines)"
              % (op, got[0] + 1, got[1] + 1, got[1] - got[0] + 1))

    # The guard is patched BEFORE the arms go in.  Inserting the arms shifts every
    # line below them, so searching for the guard afterwards looks in a range
    # whose end is now stale -- which is a StopIteration, not a wrong answer, so
    # it is at least loud.  Order matters here, and that is the whole bug.
    g = next(i for i in range(v0, v1)
             if re.search(r"if \(\(op <= \d+ && op != \d+\)", lines[i]))
    old = lines[g]
    # the guard wraps onto a second line -- `) && !advanced && !vmHalted {` -- so
    # the term goes in before THIS line's own closing paren, which is the last
    # character.  Anchoring on `) && !advanced` silently matched nothing.
    for op in ops:
        if "op == %d" % op in old:
            continue
        if not old.rstrip().endswith(")"):
            print("  guard line does not end in ')': %r" % old)
            return 1
        old = old.rstrip()[:-1] + " || op == %d)" % op
    lines[g] = old
    print("  guard: %s" % " ".join(old.split())[:96])

    # insert before HALT, which must stay the last arm
    halt = find_arm(lines, v0, v1, 0)
    if halt is None:
        print("  HALT arm not found in vmStepFast")
        return 1
    block = []
    for op, (a, b) in taken:
        for k in range(a, b + 1):
            line = lines[k]
            block.append(line[2:] if line.startswith("  ") else line)
        print("  %-4s -> vmStepFast" % ("op%d" % op))
    lines[halt[0]:halt[0]] = block

    if check:
        print("--check: nothing written")
        return 0
    open(WS, "w", encoding="utf-8", newline="").write("\n".join(lines))
    print("wrote %s -- now build it" % WS)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))