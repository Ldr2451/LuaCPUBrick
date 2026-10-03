"""Void mods that a chip would shrink, ranked, with the traps that cost builds.

A `mod` inlines at every call site; a `chip` compiles to one shared body and
costs no tick per run from a runtime call site.  So a void mod called from N
places is worth (N-1) copies of its body -- which is how a chip is worth 520
nodes on `vSet` (137 sites), 3,110 on `vmStepFast` (4 sites) and 1,638 on
`lexStep` (2 sites, 453 lines).

Call sites alone are a BAD rank, and finding out why cost a build.  A mod's body
is instantiated once per call site *per copy of whatever calls it*: emitTok has
38 lexical call sites but 34 of them are inside lexStep, which lexChunk calls
TWICE, so emitTok really existed ~72 times over.  After lexStep became a chip it
exists ~37 times, and chipping emitTok then ADDS 443 nodes -- one body against 38
sets of pin wiring.  So the column that matters is `under`, the mod that most of
the call sites sit inside: if that mod has more than one site of its own, its own
chipping may already have collected the saving.  Measure before converting.

Comments and string literals are stripped first: the first version of this screen
counted `vmBurst` as having two call sites when it has one, because lua.ws
documents it in a comment.

The two flags are the measured reasons a chip body cannot be one at all:

  indexes   the body reads a shared array element.  bumpMax does, and it is six
            lines that silently empty the whole parse: the store is lost.
  reads str the body reads a STRING variable.  patSetBegin does, and it breaks
            the pattern matcher in two places.

AND THE NODE EFFECT IS NOT PREDICTABLE FROM THE SHAPE, so measure it.  `vSet`
(137 sites, a 3-line body) is worth -520 and `emitTok` (38 sites, a 10-line
body) is worth +443 -- one body against 38 sets of pin wiring.  Both are
write-only, both take a string parameter, both are pure.  So the columns below
find candidates and flag the two shapes known to be fatal; they do not decide.

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

# which mod/chip/handler each line belongs to
OWNER, cur = [], "<top level>"
for l in CODE:
    m = re.match(r"(mod|chip) (\w+)\(", l)
    if m:
        cur = m.group(2)
    elif re.match(r"on \w+", l):
        cur = "on " + l.split()[1]
    OWNER.append(cur)


def main():
    decl = {}
    for i, l in enumerate(CODE):
        m = re.match(r"(mod|chip) (\w+)\(", l)
        if m:
            decl[m.group(2)] = (i, m.group(1))
    span = {}
    for name, (start, _k) in decl.items():
        span[name] = next((j for j in range(start + 1, len(CODE))
                           if re.match(r"(mod|chip) \w+\(", CODE[j])), len(CODE))

    sites = collections.defaultdict(list)     # callee -> [(caller, line)]
    for i, l in enumerate(CODE):
        for m in re.finditer(r"(?<![\w.])([A-Za-z_]\w*)\(", l):
            nm = m.group(1)
            if nm == OWNER[i]:
                continue
            if decl.get(nm, ("", ""))[1] == "chip":
                continue
            sites[nm].append((OWNER[i], i))

    rows = []
    for name, (start, kind) in sorted(decl.items()):
        if kind != "mod" or "->" in CODE[start].split("{")[0]:
            continue
        where = sites.get(name, [])
        if len(where) < 2:
            continue
        body = "\n".join(CODE[start + 1:span[name]])
        tally = collections.Counter(c for c, _ in where)
        top, topn = tally.most_common(1)[0]
        # a parent with sites of its own may already have collected this saving
        parent_multi = tally.get(top, 0) and len(sites.get(top, [])) > 1
        rows.append((name, len(where), span[name] - start,
                     bool(re.search(r"\w+\s*\[\s*[^\]]", body)),
                     top, topn, parent_multi))
    rows.sort(key=lambda r: -(r[1] * r[2]))

    print("void mods with >=2 call sites (comments excluded)")
    print(" %-14s %-6s %-6s %-8s %-14s %s"
          % ("mod", "sites", "lines", "indexes", "most calls from", "note"))
    for name, n, ln, elem, top, topn, multi in rows:
        note = ""
        if multi:
            note = "%d/%d under %s, which has %d sites itself" % (
                topn, n, top, len(sites.get(top, [])))
        print(" %-14s %-6d %-6d %-8s %-14s %s"
              % (name, n, ln, "YES" if elem else "-",
                 "%s(%d)" % (top, topn), note))
    print("\n%d candidates.  'note' means the parent may already have the saving:"
          "\nmeasure one before converting it -- emitTok cost a build to learn it."
          % len(rows))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())