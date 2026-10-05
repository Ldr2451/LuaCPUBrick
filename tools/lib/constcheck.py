"""Check the const <-> master map: does every master rebuild its const?

  python -u tools/lib/constcheck.py

Two directions, because both are mistakes nobody can see:

- a master that no longer rebuilds its const is a chip carrying something other
  than what lib/ says -- either lua.ws was hand-edited, or the master was edited
  without reinstalling.  The latter is the common one and it is silent: the
  piece still parses and still runs, it just is not the piece you can read.
- a const with no master is library code with no readable source at all, and
  ten of them were exactly that (LIB_io, LIB_iter, LIB_math_const,
  LIB_math_exp, LIB_math_trig, LIB_str_fmt, LIB_str_gmatch, LIB_str_pat,
  LIB_tab_concat, LIB_tab_sort) before lib/constmap.txt existed.

`--fix` prints the const lines that differ, ready to install; it does not
install, because a diff is what a reader needs to see first.
`--chip PATH` points it at another lua.ws, which is how the check is proved:
point it at a copy with one character changed and it must say so.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
from libconst import const_text                      # noqa: E402

MAP = os.path.join(ROOT, "lib", "constmap.txt")
WS = os.path.join(ROOT, "lua.ws")


def read_map():
    """(const, master) pairs, in file order.  Split on any whitespace: the
    manifest is tab-aligned, and splitting on one literal space made every
    const name carry its own indentation."""
    out = []
    with open(MAP, encoding="utf-8") as f:
        for line in f:
            line = line.split("#")[0].strip()
            if not line:
                continue
            parts = line.split()
            if len(parts) != 2:
                raise SystemExit("lib/constmap.txt: %r is not `CONST path`"
                                 % line)
            out.append((parts[0], parts[1]))
    return out


def read_consts(path):
    out = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            m = re.match(r'^const (LIB_\w+) = "(.*)"$', line.rstrip("\n"))
            if m:
                out[m.group(1)] = m.group(2)
    return out


def main(argv):
    fix = "--fix" in argv
    chip = WS
    if "--chip" in argv:
        chip = argv[argv.index("--chip") + 1]
    shipped = read_consts(chip)
    pairs = read_map()
    diffs = 0
    mapped = set()

    for const, master in pairs:
        mapped.add(const)
        path = os.path.join(ROOT, master)
        if not os.path.exists(path):
            print("MISSING  %s -> %s (no such file)" % (const, master))
            diffs += 1
            continue
        if const not in shipped:
            print("NO CONST %s -> %s" % (const, master))
            diffs += 1
            continue
        try:
            _, esc, _ = const_text(open(path, encoding="utf-8").read())
        except ValueError as e:
            print("REFUSED  %s: %s" % (const, e))
            diffs += 1
            continue
        if esc != shipped[const]:
            was = len(shipped[const])
            print("DIFFERS  %-20s %-22s %6d -> %6d chars (%+d)"
                  % (const, master, was, len(esc), len(esc) - was))
            if fix:
                print('const %s = "%s"' % (const, esc))
            diffs += 1

    for const in sorted(set(shipped) - mapped):
        print("ORPHAN   %s (%d chars, no master)" % (const,
                                                      len(shipped[const])))
        diffs += 1

    print("%d pairs, %d const(s), %d problem(s)"
          % (len(pairs), len(shipped), diffs))
    return 1 if diffs else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))