"""Vars the chip writes but never reads: the cheapest nodes there are.

Deleting state nothing reads is the one node lever that cannot break anything,
because there is nothing on the other end of it to be wrong.  AGENTS.md records the
last time this paid: four genuinely unread scalar parser flags, 30 nodes and 52
wires.  There is no tool for it -- `nodbysize.py` ranks by size and these are
invisible in it -- so this counts, per declaration, the lines that MENTION the name
against the lines that ASSIGN it.

A var is a candidate when it is mentioned only where it is assigned: the
declaration, `x = ...`, `x.push(...)`, `x.resize(...)`, `x.clear()`.  Anything else
-- `x` in an expression, `x[i]`, `x == v`, a call `f(x)` -- is a read, and the var
is not a candidate.

Deliberately conservative in what it reports: a false positive here costs a manual
check, a false negative costs nothing, so anything ambiguous is left alone rather
than guessed at.  And it is a SCREEN, not a verdict -- `sim.state_invariants` and
the suite are what decide, because a var can be read through a name this cannot see
(the sim reads `fVaB` and `vaTop` through gate labels, not through source text).

  python -u tools/chip/deadvars.py
"""
import io
import os
import re
import sys

P = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__)))), 'lua.ws')
SIM = os.path.join(os.path.dirname(P), 'irrun', 'irsims.py')

DECL = re.compile(r'^\s*var\s+([A-Za-z_]\w*)\s*:')
# Per MENTION, not per line.  The first version of this classified whole lines and
# reported 40 candidates, including `patFailTo` and `fBase` -- both of which are
# genuinely read.  The reason is `patSt = if patHit then patAfter else patFailTo`:
# the line starts with an assignment, so a line classifier saw a write to patSt and
# never looked at the read of patFailTo on the same line.  A tool that reports live
# state as dead is worse than no tool, so this counts occurrences.
#
# The second version then reported tmap, gmap, upIdx and tFree, because it treated
# ANY `x.method(` as a mutation -- and `.get`, `.find`, `.has` and `.length` are how
# this chip READS a map or array.  So the mutation list is explicit, and anything
# not on it counts as a read.
WRITE_AT = r'(?:\[[^\]]*\])?\s*=(?!=)'
MUTATORS = ('push', 'pop', 'clear', 'resize', 'set', 'add', 'remove', 'insert',
            'erase', 'append')
# A mutator call whose RESULT IS USED is a read.  The version without this rule
# reported blkNext, which is read by `blkNext.pop().Value` -- so the result of the
# pop is the point of the line, and a var that is only pushed and popped can still
# be carrying state.  Discarding is what a mutation looks like: the call is a
# statement and nothing follows it.
MUTATE = r'\b%s\.(?:%s)\((?!\s*[.)\]])' % ('%s', '|'.join(MUTATORS))


def mention_pats(name):
    esc = re.escape(name)
    return (re.compile(r'\b%s\b%s' % (esc, WRITE_AT)),        # x = / x[i] =
            re.compile(MUTATE % esc))                        # x.push( / x.clear(


def main():
    src = io.open(P, encoding='utf-8', newline='').read()
    lines = src.split('\n')

    # Two canaries, for the two ways this tool can be wrong.
    #
    # SOURCE canary: patFailTo IS read in lua.ws, in patSetStep's closing-bracket
    # arm, on a line that also assigns patSt.  A per-line classifier missed it and
    # reported 40 "dead" vars including this one, which is how the mention-level
    # version came to exist.  It must never be reported.
    SOURCE_CANARY = 'patFailTo'
    #
    # MAP canary: tmap is read by `tmap.get` / `tmap.has`, which a version that
    # treated every `.method(` as a mutation reported as dead.  Like patFailTo it
    # must never appear below.
    MAP_CANARY = 'tmap'
    #
    # LABEL canary: fBase is never read in SOURCE, and it must not be deleted
    # anyway, because sim.state_invariants reads it as a named chip var.  No text
    # search of lua.ws can see that -- the read is in tests and irrun, addressed by
    # node label.  So the names the sim uses are read out of irsims.py and excluded
    # below, which is what makes the rest of this list trustworthy.
    LABEL_CANARY = 'fBase'

    sim = io.open(SIM, encoding='utf-8', newline='').read()
    sim_names = set(re.findall(r'["\']([A-Za-z_]\w*)["\']', sim))

    names = []
    for i, ln in enumerate(lines):
        m = DECL.match(ln)
        if m:
            names.append((m.group(1), i))

    report = []
    for name, dline in names:
        if re.search(r'\.\s*%s\b' % re.escape(name), src):
            continue                       # a field of something else, not a var
        wpat, mpat = mention_pats(name)
        anypat = re.compile(r'\b%s\b' % re.escape(name))
        reads, writes = [], 0
        for i, ln in enumerate(lines):
            if i == dline or not anypat.search(ln):
                continue
            if ln.strip().startswith('//'):
                continue                   # a comment is not a read
            # blank out every WRITE/MUTATE occurrence, then see if the name is
            # still there: what is left is a read
            rest = wpat.sub(' ', mpat.sub(' ', ln))
            if anypat.search(rest):
                reads.append(i + 1)
            else:
                writes += 1
        if writes and not reads and name not in sim_names:
            report.append((name, dline + 1, writes))

    reported = [n for n, _, _ in report]
    for canary in (SOURCE_CANARY, MAP_CANARY):
        if canary in reported:
            print("TOOL IS BROKEN: %s is read and was reported dead" % canary)
            return 1
    if not report:
        print("no write-only vars found; canaries kept: %s (read in source), "
              "%s (read via tmap.get), %s (read by the sim by node label)"
              % (SOURCE_CANARY, MAP_CANARY, LABEL_CANARY))
        return 0
    print("%d var(s) written in source and never read in source "
          "(%d more excluded because irrun/irsims.py names them, so the sim reads "
          "them by node label -- %s is one of those):"
          % (len(report), len(sim_names & {n for n, _ in names}), LABEL_CANARY))
    for name, line, w in sorted(report, key=lambda r: -r[2]):
        print("  %-18s declared line %-6d assigned %d time(s)"
              % (name, line, w))
    print("\nA SCREEN, not a verdict: confirm with buildbrz (diagnostics) and the "
          "suite before committing.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
