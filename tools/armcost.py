"""Which arm of a dispatch chain costs what, and what a whole feature costs.

gateHigh is the builtin dispatch and it is inlined into every copy of vmStep, so
it is most of the chip's per-step cost -- more than the whole opcode dispatch
beside it.  A 12-arm `fid ==` chain is under the ~16-arm limit where arms stop
taking effect, so this is a size question rather than a correctness one, but it
is the first place a reduction can come from that does not also cost throughput.

One arm at a time gives the ranking; a GROUP of arms gives what a feature costs,
which is the question when the answer is "delete it or move it to Lua":

    python -u tools/armcost.py [gateHigh|gateLow|vmStep]
    python -u tools/armcost.py vmStep 35,36,37,38,39,40

A blanked arm keeps its head and its closing brace and loses its body, so the
chain still builds -- the same shape an unknown fid takes.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'irrun'))
from irdump import dump_source

WS = os.path.join(ROOT, 'lua.ws')
TMP = os.path.join(os.environ.get('TEMP', ROOT), 'armcost.ws')

KEY = None            # 'fid' or 'op', from the chain the target mod uses


def mod_span(lines, name):
    start = next(i for i, l in enumerate(lines) if l.startswith('mod %s(' % name))
    depth = 0
    for j in range(start, len(lines)):
        depth += lines[j].count('{') - lines[j].count('}')
        if j > start and depth <= 0:
            return start, j
    raise SystemExit('no end for %s' % name)


def arms(lines, lo, hi):
    """(first, last, head) for each `if fid ==` / `} else if fid ==` in a chain.

    Two attempts at brace counting failed here, and both failures are worth
    knowing: the arms are at depth 1, not 0, and the depth does *not* return to 1
    between arms because `} else if` closes the previous arm and opens the next
    in the same line.  So one is not measured by counting braces at all: arm N
    simply runs to the line where arm N+1 begins, and the last runs to the mod's
    closing brace.  An indented `if fid ==` (the nested one inside the 21/22 arm)
    is not at the chain's indent, which is what tells them apart.

    The chain variable is `fid` for the builtin dispatch and `op` for the opcode
    dispatch, so the same code measures both.
    """
    span = "".join(lines[lo:hi + 1])
    key = 'op' if re.search(r'^\s*\}?\s*(else\s+if|if)\s+op\s+==', span,
                            re.M) else 'fid'

    # the chain's indent is the mod's own nesting depth, not a constant: the
    # builtin dispatch's arms are at two spaces and vmStep's opcode chain at four,
    # and a fixed indent silently finds nothing in one of them.
    indent, first_arm = None, None
    for i in range(lo + 1, hi + 1):
        m = re.match(r'^( *)(if|\} else if) %s ==' % key, lines[i])
        if m:
            indent = len(m.group(1))
            first_arm = i
            break
    if first_arm is None:
        raise SystemExit('no %s == chain in this mod' % key)
    starts = []
    for i in range(first_arm, hi + 1):
        l = lines[i]
        # the chain's first arm is a bare `if <key> ==`; the rest are `} else if`.
        # Both sit at the chain's own indent, which is what keeps a nested
        # `if fid == 21` inside the 21/22 arm out of the list.
        if re.match(r'^ {%d}(if|\} else if) %s ==' % (indent, key), l):
            starts.append((i, l.strip()[:56]))
    out = []
    for n, (i, head) in enumerate(starts):
        # An arm ends at its OWN closing brace, not at the next arm's head: the
        # last arm of vmStep's chain is followed by the pc-advance epilogue and
        # the mod's closing brace, and blanking those collapses the whole mod
        # (measured: blanking the six bitwise arms took the chip from 40,112
        # nodes to 411, which is a broken build and not a cost).
        stop = starts[n + 1][0] - 1 if n + 1 < len(starts) else hi - 1
        for k in range(i + 1, stop + 1):
            if re.match(r'^ {%d}\}\s*$' % indent, lines[k]):
                stop = k
                break
        out.append((i, stop, head))
    return out


def count(text):
    with open(TMP, 'w', encoding='utf-8', newline='\n') as f:
        f.write(text)
    try:
        nodes, _w, _ = dump_source(os.path.abspath(TMP))
        return len(nodes)
    except Exception as e:
        return None


if __name__ == '__main__':
    which = sys.argv[1] if len(sys.argv) > 1 else 'gateHigh'
    lines = open(WS, encoding='utf-8').read().splitlines(keepends=True)
    lo, hi = mod_span(lines, which)
    spans = arms(lines, lo, hi)
    base = count(''.join(lines))
    if len(sys.argv) > 2:
        # a group of arms, blanked together: what a FEATURE costs
        want = {int(x) for x in sys.argv[2].split(',')}
        pick = [s for s in spans
                if any(re.search(r'\b(\w+) == %d\b' % n, s[2])
                       and re.search(r'\b%s ==' % re.search(r'\b(\w+) == %d\b' % n, s[2]).group(1), s[2])
                       for n in want)]
        if not pick:
            raise SystemExit('no arm matches %s in %s' % (sorted(want), which))
        blanked = list(lines)
        for first, last, _head in pick:
            for k in range(first + 1, last + 1):
                blanked[k] = ''
        n = count(''.join(blanked))
        print('%s: blanking %d arms of %d, %s -> %s'
              % (which, len(pick), len(spans), base, n))
        for first, last, head in pick:
            print('  %-52s lines %d..%d' % (head, first + 1, last + 1))
        sys.exit(0)
    print('%s: %d arms, %d nodes as built' % (which, len(spans), base))
    rows = []
    for first, last, head in spans:
        blanked = list(lines)
        for k in range(first + 1, last + 1):
            blanked[k] = ''
        n = count(''.join(blanked))
        if n is None:
            rows.append((None, head))
            print('  %-52s (will not build without it)' % head)
        else:
            d = base - n
            rows.append((d, head))
            print('  %-52s %7d nodes' % (head, d))
    print('\nlargest first:')
    for d, h in sorted((r for r in rows if r[0] is not None), key=lambda r: -r[0]):
        print('  %7d  %s' % (d, h))
