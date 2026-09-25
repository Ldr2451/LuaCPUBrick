"""Nodes and wires per binding, largest first.

`tools/audit.py` reports one total, which is the number to watch but not the
one to act on: a sweep needs to know *where* the nodes are.  The compiler
records a `_bindname` on the nodes it builds, and every bind name comes from a
`let` / `var` / `mod` declaration, so counting by name and resolving each name
back to its line says which mod the size is in.

  python -u tools/nodbysize.py [chip.ws] [--top N] [--vs other.ws]

The --vs form builds two chips and prints the binds whose count moved most, so a
change's cost is attributed rather than guessed.

What it cannot do, which is the reason to know about it before a sweep: 96% of
the nodes carry no `_bindname` at all, so the breakdown attributes the small
remainder and the rest lands in one bucket.  A node-size sweep needs that bucket
broken up, and nothing in the compiled graph says which source line a node came
from -- the compiler records the binding, not the position.  Until something
records a line, this tool says what a named part of the chip costs and that the
rest did not move, which is enough to catch a regression and not enough to
choose a target.
"""
import os
import re
import sys
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'irrun'))
from irdump import dump_source
from irsims import _extract

DECL = re.compile(r'\b(?:let|var|mod)\s+(\w+)')


def decl_index(path):
    """bind name -> (mod it is declared in, line)"""
    out = {}
    cur = '<top level>'
    for i, line in enumerate(open(path, encoding='utf-8').read().splitlines(), 1):
        for name in DECL.findall(line):
            out.setdefault(name, (cur, i))
        m = re.match(r'\s*mod\s+(\w+)\s*\(', line)
        if m:
            cur = m.group(1)
    return out


def by_mod(path):
    nodes, wires, _ = dump_source(os.path.abspath(path))
    idx = decl_index(path)
    ncount = defaultdict(int)
    wcount = defaultdict(int)
    for nd in nodes.values():
        name = _extract(nd.props.get('_bindname', ('raw', '')))
        if not isinstance(name, str) or not name:
            name = '<no bind name>'
        mod = idx.get(name, (name, 0))[0]
        ncount[mod] += 1
    for w in wires:
        s = (w[0], w[1], w[2], w[3]) if not hasattr(w, 'dst_id') \
            else (w.src_id, w.src_port, w.dst_id, w.dst_port)
        nd = nodes.get(s[0])
        if nd is None:
            continue
        name = _extract(nd.props.get('_bindname', ('raw', '')))
        if not isinstance(name, str) or not name:
            name = '<no bind name>'
        wcount[idx.get(name, (name, 0))[0]] += 1
    return ncount, wcount


if __name__ == '__main__':
    args = sys.argv[1:]
    top = 25
    if '--top' in args:
        i = args.index('--top')
        top = int(args[i + 1])
        del args[i:i + 2]
    vs = None
    if '--vs' in args:
        i = args.index('--vs')
        vs = args[i + 1]
        del args[i:i + 2]

    path = args[0] if args else os.path.join(ROOT, 'lua.ws')
    n1, w1 = by_mod(path)
    if vs:
        n2, _ = by_mod(vs)
        keys = set(n1) | set(n2)
        rows = sorted(((n1.get(k, 0) - n2.get(k, 0), k) for k in keys),
                      key=lambda kv: -abs(kv[0]))
        print('node delta  %s -> %s   (total %+d)'
              % (os.path.basename(vs), os.path.basename(path),
                 sum(n1.values()) - sum(n2.values())))
        for d, k in rows[:top]:
            if d:
                print('  %+7d  %-26s %6d -> %6d'
                      % (d, k, n2.get(k, 0), n1.get(k, 0)))
    else:
        print('%s  (%d nodes)' % (os.path.basename(path), sum(n1.values())))
        for name, n in sorted(n1.items(), key=lambda kv: -kv[1])[:top]:
            print('  %-28s %7d nodes %8d wires' % (name, n, w1.get(name, 0)))
