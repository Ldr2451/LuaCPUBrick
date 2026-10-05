"""What each library PIECE costs to parse, ranked.

Boot is charged in ticks and ticks are charged in characters, so the piece sizes are
the thing to shrink -- and a piece's length costs boot and NOT nodes, because piece
text is a string constant the loader splices into `lsrc`.  That is the whole reason
correctness fixes can be free (see lib/str_case.lua) and the whole reason shrinking a
piece cannot claw back a node.

  python -u tools/chip/piecesize.py
"""
import io
import os
import re
import sys

P = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__)))), 'lua.ws')
SRC = io.open(P, encoding='utf-8', newline='').read()

# the const's Lua text, unescaped, which is what the lexer actually reads
CONST = re.compile(r'^const (LIB_\w+) = "((?:[^"\\]|\\.)*)"\r?$', re.M)


def unescape(t):
    return (t.replace('\\n', '\n').replace('\\t', '\t')
             .replace('\\"', '"').replace("\\\\", '\\'))


def main():
    rows = []
    for m in CONST.finditer(SRC):
        lua = unescape(m.group(2))
        rows.append((len(lua), len(lua.splitlines()), m.group(1)))
    total = sum(r[0] for r in rows)
    print("%d pieces, %d characters of Lua in total" % (len(rows), total))
    print("%-24s %7s %6s" % ("piece", "chars", "lines"))
    for n, nl, name in sorted(rows, reverse=True):
        print("%-24s %7d %6d" % (name, n, nl))
    return 0


if __name__ == "__main__":
    sys.exit(main())
