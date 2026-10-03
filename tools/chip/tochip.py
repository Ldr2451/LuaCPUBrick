"""Convert named void mods to chips, refusing the shapes that are known broken.

A `mod` inlines at every call site; a `chip` compiles to one shared body and
costs no tick per run.  That makes a multi-site void mod worth (N-1) copies of
its body, and the class used to be written off wholesale on the belief that a
chip boundary costs a tick -- measured false on `vmStepFast` (4 sites) and then
on `vSet` (137 sites), both at identical ticks.

Refuses, because each was measured rather than assumed:

  a return type       a chip publishing a value is a different mechanism
  a parse-path caller costs one boot tick -- check with whocalls.py first
  --only-runtime      skip anything called from the parse/lex driver

  python -u tools/chip/tochip.py --check vSetNum pushOp
  python -u tools/chip/tochip.py vSetNum pushOp
  python -u tools/chip/tochip.py --only-runtime nxStep vmForLoop

Prints what it did and refuses to touch a name that does not exist, so a typo
cannot silently do nothing.
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
WS = os.path.join(ROOT, "lua.ws")


def parse_path_names():
    """Names called from the parse/lex driver, via whocalls.py's own table."""
    src = open(os.path.join(HERE, "whocalls.py"), encoding="utf-8").read()
    m = re.search(r"PARSE = \((.*?)\)\n", src, re.S)
    return set(re.findall(r'"(\w+)"', m.group(1))) if m else set()


def callers(lines):
    own, cur = [], "<top level>"
    for l in lines:
        m = re.match(r"(?:mod|chip) (\w+)\(", l)
        if m:
            cur = m.group(1)
        elif re.match(r"on \w+", l):
            cur = "on " + l.split()[1]
        own.append(cur)
    out = {}
    for i, l in enumerate(lines):
        for m in re.finditer(r"(?<![\w.])([A-Za-z_]\w*)\(", l.split("//")[0]):
            if own[i] != "<top level>":
                out.setdefault(m.group(1), set()).add(own[i])
    return out


def main(argv):
    check = "--check" in argv
    only_rt = "--only-runtime" in argv
    names = [a for a in argv if not a.startswith("--")]
    if not names:
        print(__doc__)
        return 1

    src = open(WS, encoding="utf-8", newline="").read()
    lines = src.split("\n")
    decl = {}
    for i, l in enumerate(lines):
        m = re.match(r"(mod|chip) (\w+)\(", l)
        if m:
            decl[m.group(2)] = (i, m.group(1))
    calls = callers(lines)
    parse_drivers = parse_path_names()

    changed = []
    for n in names:
        if n not in decl:
            print("  %-14s NO SUCH DECLARATION" % n)
            continue
        i, kind = decl[n]                    # decl maps name -> (line, kind)
        if kind == "chip":
            print("  %-14s already a chip" % n)
            continue
        if "->" in lines[i].split("{")[0]:
            print("  %-14s REFUSED: returns a value" % n)
            continue
        if only_rt and (calls.get(n, set()) & parse_drivers):
            print("  %-14s REFUSED: parse-path (costs a boot tick)" % n)
            continue
        print("  %-14s %s" % (n, "would convert" if check else "converted"))
        lines[i] = "chip" + lines[i][3:]
        decl[n] = ("chip", i)
        changed.append(n)

    if check or not changed:
        print("check only: %d would change" % len(changed))
        return 0
    open(WS, "w", encoding="utf-8", newline="").write("\n".join(lines))
    print("converted %d mods to chips: %s" % (len(changed), ", ".join(changed)))
    print("now: python -u tools/buildbrz.py")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))