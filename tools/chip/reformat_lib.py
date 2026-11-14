"""One-off: join each `const LIB_x = "..."` Lua text onto one line.

Statement-separator newlines (the `\n` escapes in the .ws literal, not the
`\\n` escapes that are Lua's own newline inside a library string) become
single spaces, so the library pieces contain no real newlines at all.
Refuses loudly when a join could change Lua: a fragment ending with `-`
(comment merge), or a next fragment starting with `(` or `-` (call or
subtraction merge).
"""
import re

path = "lua.ws"
src = open(path, encoding="utf-8").read()
lines = src.split("\n")

pat = re.compile(r'^const (LIB_[A-Za-z0-9_]*) = "(.*)"$')
targets = [i for i, ln in enumerate(lines) if pat.match(ln)]
print("LIB constants found:", len(targets))

NL = "\u0000NL\u0000"
changed = 0
for i in targets:
    m = pat.match(lines[i])
    name, body = m.group(1), m.group(2)
    # Protect Lua's own \n (written \\n in the literal) before splitting.
    body = body.replace("\\\\n", NL)
    parts = body.split("\\n")
    for j, chunk in enumerate(parts):
        if j + 1 < len(parts):
            if chunk.rstrip().endswith("-"):
                raise SystemExit("join hazard: fragment ends with '-'")
            nxt = parts[j + 1].lstrip()
            if nxt.startswith("(") or nxt.startswith("-"):
                raise SystemExit("join hazard: next fragment starts with ( or -")
    out = " ".join(p.strip() for p in parts).replace(NL, "\\\\n")
    lines[i] = 'const %s = "%s"' % (name, out)
    print("%s: joined %d" % (name, len(parts) - 1))
    changed += 1

open(path, "w", encoding="utf-8").write("\n".join(lines))
print("rewrote", changed, "lines")
