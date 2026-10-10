"""Diff library piece sizes between two chip sources, biggest growers first.

Usage: python -u tools/chip/piecesdiff.py <old.ws> <new.ws>
Pure text: unescapes every const LIB_* and compares lengths.
"""
import io
import os
import re
import sys

CONST = re.compile(r'^const (LIB_\w+) = "((?:[^"\\]|\\.)*)"', re.M)


def unescape(t):
    return (t.replace('\\n', '\n').replace('\\t', '\t')
              .replace('\\"', '"').replace("\\\\", '\\'))


def pieces(path):
    src = io.open(path, encoding='utf-8', newline='').read()
    out = {}
    for m in CONST.finditer(src):
        out[m.group(1)] = len(unescape(m.group(2)))
    return out


def main(argv):
    if len(argv) != 2:
        print("usage: piecesdiff.py <old.ws> <new.ws>")
        return 1
    old, new = (pieces(a) for a in argv)
    rows = []
    for name in sorted(set(old) | set(new)):
        a, b = old.get(name, 0), new.get(name, 0)
        if a != b:
            rows.append((b - a, a, b, name))
    rows.sort(reverse=True)
    print("%-24s %7s %7s %7s" % ("piece", "old", "new", "delta"))
    for d, a, b, name in rows:
        print("%-24s %7d %7d %+7d" % (name, a, b, d))
    print("total chars: %d -> %d (%+d)" % (
        sum(old.values()), sum(new.values()),
        sum(new.values()) - sum(old.values())))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
