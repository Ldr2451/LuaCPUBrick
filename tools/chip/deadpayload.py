"""Drop vSet payloads that docs/vm-isa says cannot be read.

The register table: tag 0 nil ignores both payloads, tags 1/3/4/5/6 use `num`
and ignore `str`, tag 2 string uses `str` and ignores `num`.  vSet writes all
three cells and it is a mod, so every one of those writes is a separate copy at
each of its call sites.  Three classes, and the third is the one that is easy to
get wrong:

  vSet(r, 0, 0.0, "")   -> vSetNil(r)      both payloads dead, tag is literal
  vSet(r, T, n, "")     -> vSetN(r, T, n)  str dead, but ONLY for a LITERAL
                          tag that is not 2 -- a computed tag could BE 2 at
                          run time, so its string payload is not provably dead
  vSet(r, 2, 0.0, s)    -> vSetS(r, s)     num dead, tag is literal 2

`tools/chip/payload.py` counts the classes before any of this is changed, so
the ceiling is known first.  The nets judge the result: this is a change to how
every register write reaches the arrays, and "the ISA says so" is a claim about
the reader, not about the writer.

  python -u tools/chip/deadpayload.py --check
  python -u tools/chip/deadpayload.py
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))))
WS = os.path.join(ROOT, "lua.ws")
CHECK = "--check" in sys.argv

HELPERS = [
    ("vSetNil", """// A nil store writes only the tag, and a store whose tag is not 2 writes no
// string, and a string store writes no number: docs/vm-isa says those payloads
// are ignored, and vSet is a mod, so each of those writes was a separate copy.
mod vSetNil(r: int) {
  vtag[vmBase + r] = 0
}
"""),
    ("vSetN", """mod vSetN(r: int, tag: int, num: float) {
  vtag[vmBase + r] = tag
  vnum[vmBase + r] = num
}
"""),
    ("vSetS", """mod vSetS(r: int, s: string) {
  vtag[vmBase + r] = 2
  vstr[vmBase + r] = s
}
"""),
]


ONLY = None
for a in sys.argv:
    if a.startswith("--only="):
        ONLY = set(a.split("=", 1)[1].split(","))
# noNum is OFF by default and stays off.  It is the one class that breaks the
# chip: dropping the numeric payload of a string store (`vSet(r, 2, 0.0, s)` ->
# `vSetS(r, s)`, 22 sites) kills the suite with "cannot convert float infinity to
# integer", with nil-only and noStr-only both green.  So the chip's readers DO
# consult vnum at tag 2, and docs/vm-isa's "ignored" describes a conforming
# reader rather than this one.  A tool must not do by default the thing that
# breaks the thing it is measuring.
OFF_BY_DEFAULT = {"noNum"}


def split_top(inner):
    """Split a call's arguments on commas that are not inside brackets or strings.

    String-aware because a comma inside a literal is not an argument separator:
    `vSet(a, 1, x .. ",", "")` split naively gives five arguments, the rewrite
    then fires on the wrong ones, and the suite dies with "cannot convert float
    infinity to integer" -- which is what happened before this learned to skip
    over `"..."`.
    """
    parts, depth, cur, quote = [], 0, "", None
    i = 0
    while i < len(inner):
        ch = inner[i]
        if quote:
            cur += ch
            if ch == "\\" and i + 1 < len(inner):
                cur += inner[i + 1]
                i += 2
                continue
            if ch == quote:
                quote = None
            i += 1
            continue
        if ch in "\"'":
            quote = ch
            cur += ch
        elif ch in "([{":
            depth += 1
            cur += ch
        elif ch in ")]}":
            depth -= 1
            cur += ch
        elif ch == "," and depth == 0:
            parts.append(cur.strip())
            cur = ""
        else:
            cur += ch
        i += 1
    parts.append(cur.strip())
    return parts


def call_end(src, j):
    """Index just past the `)` closing the `vSet(` at j, skipping string literals.

    A paren inside a string literal would otherwise close the call early and the
    rewrite would land inside a string.
    """
    k, depth, quote = j + 5, 1, None
    while k < len(src):
        ch = src[k]
        if quote:
            if ch == "\\":
                k += 2
                continue
            if ch == quote:
                quote = None
        elif ch in "\"'":
            quote = ch
        elif ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return k + 1
        k += 1
    raise ValueError("unbalanced vSet( at %d" % j)


def rewrite(src):
    out, i, counts = [], 0, {"nil": 0, "noStr": 0, "noNum": 0}
    while True:
        j = src.find("vSet(", i)
        if j < 0:
            out.append(src[i:])
            break
        k = call_end(src, j)
        call = src[j:k]
        inner = call[5:-1]
        p = split_top(inner)
        new = None
        if len(p) == 4:
            tag, num, st = p[1], p[2], p[3]
            # A literal tag in 1/3/4/5/6 uses num and ignores str.  Written as a
            # membership test, not a character class: `[1-356]` is the set
            # {1,-,3,5,6} and would have matched a subtraction.
            if tag == "0" and num == "0.0" and st == '""':
                new, kind = "vSetNil(%s)" % ", ".join(p[:1]), "nil"
            elif st == '""' and tag in ("1", "3", "4", "5", "6"):
                new, kind = "vSetN(%s)" % ", ".join(p[:3]), "noStr"
            elif tag == "2" and num == "0.0" and st != '""':
                new, kind = "vSetS(%s, %s)" % (p[0], st), "noNum"
        if new and kind in OFF_BY_DEFAULT and ONLY != {kind}:
            new = None
        if new:
            out.append(src[i:j])
            out.append(new)
            counts[kind] += 1
            i = k
        else:
            out.append(src[i:k])
            i = k
    return "".join(out), counts


def main():
    src = open(WS, encoding="utf-8", newline="").read()
    new, counts = rewrite(src)
    print("rewrites: %s" % counts)
    if not any(counts.values()):
        print("nothing to do")
        return 0
    # Each helper is checked on its own.  Gating the whole block on one name
    # meant that a chip already carrying vSetNil -- which it does after the nil
    # pass -- silently got no vSetN or vSetS, and the compiler answered WS002 on
    # 52 call sites instead.
    anchor = "mod vSet(r: int, tag: int, num: float, s: string) {"
    i = new.index(anchor)
    j = new.index("}", i) + 1
    missing = [body for name, body in HELPERS
               if ("mod %s(" % name) not in new]
    if missing:
        new = new[:j] + "\n" + "".join(missing) + new[j:]
    if CHECK:
        print("--check: nothing written")
        return 0
    open(WS, "w", encoding="utf-8", newline="").write(new)
    print("wrote %s -- now build it" % WS)
    return 0


if __name__ == "__main__":
    sys.exit(main())