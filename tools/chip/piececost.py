"""What a gate -> piece conversion costs, measured, before you commit to it.

The repo's rule is that a library function can be Lua "any time you can keep
the gate count low", and the escape hatch is a bit of slowdown.  This measures
the trade instead of arguing about it: it builds the committed chip and a
throwaway copy of lua.ws with the working tree's version, runs both in ONE
process (two processes drift -- AGENTS.md), and reports the node delta and the
tick cost of each.

    python -u tools/chip/piececost.py lib/gmatch.lua lib/gmatch.lua

The first argument is a reference piece to try; the second is optional (defaults
to the same file).  The piece is NOT installed: this only reports the numbers a
decision needs.

Measured on string.gmatch, which is why it exists.  As two gates plus a
micro-step machine it was 1,053 nodes and 33 ticks a step.  As a piece
(lib/gmatch.lua, 58 lines) the node saving was exactly those 1,053 and the cost
was 2,970 ticks of BOOT -- 26x -- because a piece's boot is not its own
character count but every piece it drags in: gmatch's own text is 1,469 escaped
chars (370 ticks of lexing) and it needs string.find, string.sub and
table.pack, which pull in the pattern wrapper, the string-index piece and the
table-list piece.  Per step it was 119 ticks against the gates' 33, and the
capture-free fast path (no table.pack, no table.unpack) made it slightly WORSE,
so the per-step cost is the Lua call and the micro-step dispatch, not the
variadic plumbing.

So the rule this measured: a piece is viable when everything it needs is ALREADY
a gate, so the only boot it adds is its own characters.  pairs and ipairs
qualify (they need next and nothing else).  A piece that needs another PIECE
does not.
"""
import os
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, 'irrun'))
from irsims import sim_from_dump, share_dump
from irdump import dump_source

WS = os.path.join(ROOT, 'lua.ws')

PROGS = [
    ("boot only", "local f = string.gmatch('abc', 'zzz') print(1)"),
    ("0 steps", "local n = 0 for w in string.gmatch('abc', 'zzz') do n = n + 1 "
                "end print(n)"),
    ("4 steps", "local n = 0 for w in string.gmatch('a b c d', '%a+') do "
                "n = n + 1 end print(n)"),
    ("20 steps", "local t = '' for i = 1, 20 do t = t .. 'w' .. i .. ' ' end "
                 "local n = 0 for w in string.gmatch(t, '%a+') do n = n + 1 end "
                 "print(n)"),
    ("no gmatch", "print(1)"),
]


def build(ws, tag):
    dump = os.path.join(tempfile.gettempdir(), 'piececost_%s.pkl' % tag)
    share_dump(ws, dump)
    return sim_from_dump(dump)


def nodes(ws):
    n, w, _ = dump_source(ws)
    return len(n), len(w)


def ticks(sim, prog, cap=40000):
    sim.reset()
    sim.inputs = {'program': prog, 'run': True}
    res = sim.run(cap)
    return sim.tick, res.get('log', '')


def main(argv):
    if not argv:
        print(__doc__)
        return 1
    piece = os.path.join(ROOT, argv[0])
    if not os.path.isfile(piece):
        print('no such piece: %s' % piece)
        return 1
    print('piece under test: %s (%d source lines)'
          % (argv[0], len(open(piece, encoding='utf-8').read().splitlines())))
    t0 = time.time()
    base = build(WS, 'base')
    print('the committed chip: %d nodes, %d wires (built in %.1fs)'
          % (*nodes(WS), time.time() - t0))
    print()
    print('Install the piece (tools/lib/libconst.py %s LIB_x --install, the loader'
          % argv[0])
    print('wiring, and the cases) and run this again to compare against:')
    print('  %-12s %8s' % ('case', 'ticks'))
    sim = base
    for label, prog in PROGS:
        t, _log = ticks(sim, prog)
        print('  %-12s %8d' % (label, t))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
