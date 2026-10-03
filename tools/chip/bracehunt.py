"""Where does a brace walk of a chip body go wrong?

twopaths.py extracts `vmStepFast`'s body by counting braces, and it stopped
finding one after a fast-path arm was added -- while the chip still compiles with
zero diagnostics.  So the imbalance is in something the walk does not model:
a brace or a quote inside a comment or a string literal.

Prints the depth at each line of the body, ignoring comments and string
literals, and flags the line where a comment- and string-aware count and a raw
count disagree -- which is where the walk is being fooled.

  python -u bracehunt.py vmStepFast
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))))
src = open(os.path.join(ROOT, "lua.ws"), encoding="utf-8").read()

name = sys.argv[1] if len(sys.argv) > 1 else "vmStepFast"
m = re.search(r'\b(?:mod|chip)\s+%s\s*\(' % re.escape(name), src)
start = src.index("{", m.end())


def scan(text, honour_comments):
    """(depth, disagreements) over text, line by line."""
    depth, bad, quote, i, line = 0, [], None, 0, 1
    while i < len(text):
        c = text[i]
        if quote:
            if c == "\\":
                i += 2
                continue
            if c == quote:
                quote = None
        elif honour_comments and text[i:i + 2] == "//":
            j = text.find("\n", i)
            i = len(text) if j < 0 else j
            continue
        elif c in "\"'":
            quote = c
        elif c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
        elif c == "\n":
            line += 1
        i += 1
    return depth, bad, line


raw_depth, _, _ = scan(src[start:], False)
print("%s: raw brace walk from its opening brace ends at depth %d "
      "(0 would be balanced)" % (name, raw_depth))

# now find the lines where a comment-aware walk and the raw walk diverge
depth = 0
quote = None
i = start
line = src.count("\n", 0, start) + 1
suspect = []
while i < len(src):
    c = src[i]
    if quote:
        if c == "\\":
            i += 2
            continue
        if c == quote:
            quote = None
    elif src[i:i + 2] == "//":
        j = src.find("\n", i)
        seg = src[i:len(src) if j < 0 else j]
        if "{" in seg or "}" in seg:
            suspect.append((line, seg.strip()[:78]))
        i = len(src) if j < 0 else j
        continue
    elif c in "\"'":
        quote = c
        j = src.find(c, i + 1)
        seg = src[i:(len(src) if j < 0 else j + 1)]
        if "{" in seg or "}" in seg:
            suspect.append((line, seg.strip()[:78]))
    elif c == "{":
        depth += 1
    elif c == "}":
        depth -= 1
    elif c == "\n":
        line += 1
    i += 1
print("comment/string-aware depth at end: %d" % depth)
if suspect:
    print("\nlines inside this body with a brace in a comment or a string:")
    for ln, seg in suspect[:12]:
        print("  %5d %s" % (ln, seg))
else:
    print("\nno braces in any comment or string in this body")