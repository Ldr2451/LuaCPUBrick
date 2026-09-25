"""Which arm of gateHigh costs what.

gateHigh is 13,217 nodes and it is inlined into every one of vmStep's four
copies, so it is 70% of the chip's per-step cost -- more than the whole opcode
dispatch beside it.  A 12-arm `fid ==` chain is under the ~16-arm limit where
arms stop taking effect, so this is a size question rather than a correctness
one, but it is the first place a reduction can come from that does not also cost
throughput.

This blanks one arm at a time and reports the node delta, so the arms are
ranked by what they actually cost rather than by how many lines they read like.
A blanked arm is replaced with a bare `return`, which is what an unknown fid
does anyway, so the chip still builds.

    python -u tools/armcost.py [gateHigh|gateLow]
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'irrun'))
from irdump import dump_source

WS = os.path.join(ROOT, 'lua.ws')
TMP = os.path.join(os.environ.get('TEMP', ROOT), 'armcost.ws')


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
    """
    starts = []
    for i in range(lo + 1, hi + 1):
        l = lines[i]
        # the chain's first arm is a bare `if fid ==`; the rest are `} else if`.
        # Both sit at the mod's own indent (two spaces), which is what keeps the
        # nested `if fid == 21` inside the 21/22 arm out of the list.
        if re.match(r'^  (if|\} else if) fid ==', l):
            starts.append((i, l.strip()[:56]))
    out = []
    for n, (i, head) in enumerate(starts):
        last = starts[n + 1][0] - 1 if n + 1 < len(starts) else hi - 1
        out.append((i, last, head))
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
