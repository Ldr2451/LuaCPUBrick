"""Did an AGENTS.md edit lose a number?

Trimming that file is only safe if the measurements survive, and a measurement is
a number with a unit.  This compares the numbers in the working tree against the
committed version and prints the ones that disappeared, so a trim can be proved
rather than trusted:

    python -u tools/agents_nums.py            # vs HEAD
    python -u tools/agents_nums.py <ref>     # vs any revision

It reports numbers, not sentences, on purpose: the sentences are what the trim is
allowed to rewrite, and a number that vanishes is a measurement nobody can check
again.  A number that is ADDED is listed too -- a new measurement is fine, a
replacement one is not, because two numbers for one fact is how a file starts
lying.

Material that was MOVED out of AGENTS.md into a doc is still context the next
session may not read, so the companion files are searched too and a number counts
as kept if it is in any of them.  That list is where a move has to be declared.
"""
import io
import re
import subprocess
import sys
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AGENTS = os.path.join(ROOT, "AGENTS.md")
# a move is not a loss, but the number must exist somewhere reachable.  AGENTS.md
# is kept short on purpose, so the traps, the ISA reference, the model rules and
# the two expensive lessons all live beside it and are found here.
COMPANIONS = ["docs/vm-isa.md", "docs/traps.md", "docs/lessons.md",
              "tools/model/README.md"]

# a number, its separators, and the unit that makes it a measurement
NUM = re.compile(
    r"\d[\d,]*(?:\.\d+)?\s*"
    r"(?:%|ms|s\b|sec|seconds|ticks?|nodes?|wires?|chars?|bytes?|KB|MB|"
    r"chars?/tick|registers?|values?|cases?|lines?|functions?|ops?|seeds?|"
    r"x|bit|b\b)?")


def digits(text):
    """Every numeric value, unit or not.  A measurement that moved into a table
    cell keeps its value and loses its unit token, so comparing digit strings is
    what tells a reflow from a loss; the unit-annotated tokens are reported
    separately below because a lost unit usually means a lost MEASUREMENT."""
    return set(t.rstrip(",")
               for t in re.findall(r"\d[\d,]*(?:\.\d+)?", re.sub(r"\s+", " ", text)))


def nums(text):
    # whitespace is normalised first, so a number whose unit was wrapped onto the
    # next line by an edit is the same token and cannot look lost
    text = re.sub(r"\s+", " ", text)
    out = {}
    for m in NUM.finditer(text):
        t = m.group(0).strip()
        if t and t not in out:
            out[t] = 0
        if t:
            out[t] += 1
    return out


def old_text(ref):
    if ref == "-":
        return io.open(AGENTS, encoding="utf-8").read()
    if ref is None:
        ref = "HEAD"
    p = subprocess.run(["git", "show", "%s:AGENTS.md" % ref], cwd=ROOT,
                       capture_output=True, text=True, encoding="utf-8",
                       errors="replace")
    if p.returncode != 0:
        return ""
    return p.stdout


def new_text():
    """AGENTS.md plus any file material was moved into."""
    out = io.open(AGENTS, encoding="utf-8").read()
    for rel in COMPANIONS:
        p = os.path.join(ROOT, rel.replace("/", os.sep))
        if os.path.isfile(p):
            out += "\n" + io.open(p, encoding="utf-8").read()
    return out


def main():
    ref = sys.argv[1] if len(sys.argv) > 1 else None
    new = new_text()
    old = old_text(ref)
    if not old:
        print("no reference text (git show %s failed?)" % (ref or "HEAD"))
        return 1
    a, b = nums(old), nums(new)
    da, db = digits(old), digits(new)
    lost_val = sorted(t for t in da if t not in db)
    lost = sorted(t for t in a if t not in b and
                  not any(u.startswith(t.rstrip("%")) for u in b))
    added = sorted(t for t in b if t not in a)
    print("AGENTS.md: %d chars -> %d chars" % (len(old), len(new)))
    print("numbers: %d before, %d after" % (len(a), len(b)))
    if lost_val:
        print("LOST VALUES %d: %s" % (len(lost_val), ", ".join(lost_val)))
    else:
        print("LOST VALUES none")
    if lost:
        print("LOST UNITS %d: %s" % (len(lost), ", ".join(lost)))
    else:
        print("LOST UNITS none")
    if added:
        print("ADDED %d: %s" % (len(added), ", ".join(added)))
    return 1 if lost_val else 0


if __name__ == "__main__":
    sys.exit(main())
