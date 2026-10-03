"""Void mods that a chip would shrink, counted HONESTLY, with the rules attached.

A `mod` inlines at every call site; a `chip` compiles to one shared body, and a
chip costs no tick per run from a runtime call site.  So a void mod called from
N places is worth (N-1) copies of its body -- which is how the chip is now worth
520 nodes on `vSet` (137 sites) and 3,110 on `vmStepFast` (4 sites).

The first screen counted every `name(` in the file including inside comments, so
`vmBurst` scored two call sites when it has one (lua.ws documents it in a
comment).  Comments and string literals are stripped first here.

It also prints the two things measured about a chip body that decide whether it
CAN be one, because both were learned by bisecting a broken batch:

  indexes   the body reads a shared array element.  bumpMax does, and it is six
            lines that silently empty the whole parse: the store is lost.
  reads str the body reads a STRING variable.  patSetBegin does, and it breaks
            the pattern matcher in two places.

  python -u tools/chip/chipscreen.py
"""
import collections
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))))
LINES = open(os.path.join(ROOT, "lua.ws"), encoding="utf-8").read().split("\n")


def strip(line):
    """Line with // comments and "..." literals blanked out."""
    out, quote, i = [], False, 0
    while i < len(line):
        c = line[i]
        if quote:
            if c == "\\":
                i += 2
                continue
            if c == '"':
                quote = False
            out.append(" ")
            i += 1
            continue
        if c == '"':
            quote = True
            out.append(" ")
            i += 1
            continue
        if line[i:i + 2] == "//":
            break
        out.append(c)
        i += 1
    return "".join(out)


CODE = [strip(l) for l in LINES]


def main():
    decl = {}
    for i, l in enumerate(CODE):
        m = re.match(r"(mod|chip) (\w+)\(", l)
        if m:
            decl[m.group(2)] = (i, m.group(1))

    uses = collections.Counter()
    for l in CODE:
        for m in re.finditer(r"(?<![\w.])([A-Za-z_]\w*)\(", l):
            uses[m.group(1)] += 1

    rows = []
    for name, (start, kind) in sorted(decl.items()):
        if kind != "mod":
            continue
        if "->" in CODE[start].split("{")[0]:
            continue                      # returns a value: not measured
        end = next((j for j in range(start + 1, len(CODE))
                    if re.match(r"(mod|chip) \w+\(", CODE[j])), len(CODE))
        n = uses[name] - 1
        if n < 2:
            continue
        body = "\n".join(CODE[start + 1:end])
        rows.append((name, n, end - start,
                     bool(re.search(r"\w+\s*\[\s*[^\]]", body)),
                     bool(re.search(r'Substring|ToCharCode|\.Length\(\)|\w+\.\w+\(',
                                    body))))
    rows.sort(key=lambda r: -(r[1] * r[2]))
    print("void mods with >=2 real call sites (comments excluded)")
    print(" %-16s %-6s %-6s %-8s %s"
          % ("mod", "sites", "lines", "indexes", "reads str"))
    for name, n, ln, elem, s in rows:
        print(" %-16s %-6d %-6d %-8s %s"
              % (name, n, ln, "YES" if elem else "-", "YES" if s else "-"))
    print("\n%d candidates, worth at most %d extra body copies"
          % (len(rows), sum(r[1] - 1 for r in rows)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())