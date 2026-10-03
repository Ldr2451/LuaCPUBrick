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


def extract_arm(lines, lo, hi, op):
    """The lines of the top-level arm for `op`, as a STANDALONE arm.

    No brace counting, and that is the point.  The chain is written

        } else if op == 42 {
          body
        } else if op == 43 {

    so an arm's closing brace is the FIRST CHARACTER of the next arm's head
    line.  A depth walk therefore never sees the arm end -- depth returns to
    base and immediately goes back up on the same line -- and the first version
    of this ran past arm 43 and stopped at an inner `}` two arms later.  What
    it copied was arm 43 PLUS A TRUNCATED arm 42, which compiles, passes 772
    cases and 400 fuzz seeds, and costs four wasted fast dispatches on every
    RETURNM forever.

    So find the next CHAIN HEAD instead, which is unambiguous: `} else if op ==
    N` and `} else` occur only in the dispatcher, never nested.  The closing
    brace is taken from that head line, and a final arm ends at a lone `}`.
    """
    head = None
    for i in range(lo, hi):
        m = re.match(r"\s*\}? else if op == (\d+)", lines[i])
        if m and int(m.group(1)) == op:
            head = i
            break
    if head is None:
        return None
    nxt = None
    for i in range(head + 1, hi):
        s = lines[i].strip()
        if re.match(r"\} else (if op == \d+|if |\w|$)", s) or s == "}":
            nxt = i
            break
    if nxt is None:
        return None
    body = list(lines[head:nxt])
    # No closing brace here: the caller dedents every line it is given, so a
    # closer added now would be dedented too and land in column 0 -- which is a
    # syntax error that reads as "unexpected token '}'", not as a bad indent.
    return body


def _strip(line, quote):
    """(code without comments/strings, quote state after it)."""
    out = []
    i = 0
    while i < len(line):
        c = line[i]
        if quote:
            if c == "\\":
                i += 2
                continue
            if c == quote:
                quote = None
            i += 1
            continue
        if line[i:i + 2] == "//":
            break
        if c in "\"'":
            quote = c
            i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out), quote


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
        got = extract_arm(lines, s0, v0, op)
        if got is None:
            print("  op %-3d NOT FOUND in vmStep" % op)
            return 1
        taken.append((op, got))
        print("  op %-3d %d lines from vmStep" % (op, len(got)))

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
    halt = extract_arm(lines, v0, v1, 0)
    if halt is None:
        print("  HALT arm not found in vmStepFast")
        return 1
    block = []
    for op, arm in taken:
        for line in arm:
            block.append(line[2:] if line.startswith("  ") else line)
        # NO closing brace.  In this chain the arm's `}` is the first character
        # of the NEXT head line, and the arm is inserted immediately before an
        # existing one, so that line already closes it.  Adding a closer gives
        # one brace too many and the compiler says "unexpected token 'else'".
        print("  %-4s -> vmStepFast" % ("op%d" % op))
    # insert before HALT, which must stay the last arm
    at = next(i for i in range(v0, v1)
              if re.match(r"\s*\}? else if op == 0", lines[i]))
    lines[at:at] = block

    if check:
        print("--check: nothing written")
        return 0
    open(WS, "w", encoding="utf-8", newline="").write("\n".join(lines))
    print("wrote %s -- now build it" % WS)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))