"""Node cost per mod, measured by building the chip with that mod emptied.

Nothing in the compiled graph records a source line and 91% of nodes carry no
bind name, so the only honest way to ask "what does this mod cost" is to delete
it and see what the build loses.  This does that one mod at a time: replace the
body with `return` (keeping the signature, so callers still compile), build, and
report the node delta.  The delta is the mod's true cost *including* every copy
the compiler inlines of it, which is the number a sweep has to beat -- a mod
called from four places costs four times what reading it suggests.

    python -u tools/modcost.py [--top N] [mod ...]

With no mod named, this costs one build per candidate, so pass a shortlist
rather than letting it run over every mod in the file.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'irrun'))
from irdump import dump_source
from irsims import _extract

WS = os.path.join(ROOT, 'lua.ws')
TMP = os.path.join(os.environ.get('TEMP', ROOT), 'modcost_ws.ws')


def build_count(path):
    try:
        nodes, _w, _ = dump_source(os.path.abspath(path))
        return len(nodes)
    except Exception as e:                      # a mod the chip cannot lose
        return None


def mods_in(path):
    src = open(path, encoding='utf-8').read().splitlines(keepends=True)
    out = []
    i = 0
    while i < len(src):
        m = re.match(r'(?:mod|gate)\s+(\w+)\s*\(', src[i])
        if m:
            j = i
            depth = 0
            started = False
            while j < len(src):
                depth += src[j].count('{') - src[j].count('}')
                if '{' in src[j]:
                    started = True
                if started and depth <= 0:
                    break
                j += 1
            out.append((m.group(1), i, j))
            i = j + 1
        else:
            i += 1
    return src, out


def blanked(src, lo, hi, name):
    """The mod's body replaced by a return, keeping the signature line intact."""
    out = list(src)
    head = out[lo].rstrip()
    # keep everything on the head up to the opening brace, then give it a body
    cut = head.find('{')
    if cut < 0:
        return out
    sig = head[:cut + 1]
    out[lo] = sig + '\n  return nil\n}\n'
    for k in range(lo + 1, hi + 1):
        out[k] = ''
    return out


if __name__ == '__main__':
    args = sys.argv[1:]
    top = 20
    if '--top' in args:
        i = args.index('--top')
        top = int(args[i + 1])
        del args[i:i + 2]
    src, mods = mods_in(WS)
    named = {m[0]: m for m in mods}
    base = build_count(WS)
    print('baseline %s: %d nodes, %d mods' % (os.path.basename(WS), base, len(mods)))
    if args:
        want = [a for a in args if a in named]
    else:
        want = [m[0] for m in mods]
    rows = []
    for name in want:
        _n, lo, hi = named[name]
        text = ''.join(blanked(src, lo, hi, name))
        with open(TMP, 'w', encoding='utf-8', newline='\n') as f:
            f.write(text)
        n = build_count(TMP)
        if n is None:
            rows.append((None, name))
            print('  %-24s (does not compile without it)' % name)
        else:
            rows.append((base - n, name))
            print('  %-24s %7d nodes' % (name, base - n))
    print('\nlargest first:')
    for d, name in sorted((r for r in rows if r[0] is not None),
                          key=lambda r: -r[0])[:top]:
        print('  %7d  %s' % (d, name))
