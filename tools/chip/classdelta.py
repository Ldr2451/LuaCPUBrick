"""Gate-class delta between HEAD's lua.ws and the working copy.

  python -u tools/chip/classdelta.py

Prints classes whose count changed, patched minus baseline.
"""
import os
import sys
from collections import Counter

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, 'irrun'))
from irdump import parse_modules  # noqa

import subprocess


def short(cls):
    for p in ("BrickComponentType_", "WireGraphPseudo_", "WireGraph_"):
        if cls.startswith(p):
            cls = cls[len(p):]
    if "_" in cls and cls.split("_")[0] in ("Expr", "Exec", "Logic", "Data"):
        cls = cls.split("_", 1)[1]
    return cls


def counts(path):
    mods = parse_modules(_compile_dump(path))
    c = Counter()
    for m in mods:
        for n in m["nodes"].values():
            c[short(n.cls)] += 1
    return c


def _compile_dump(path):
    # local copy of irdump's helper (it is private but importable)
    from irdump import _compile_dump as dump
    return dump(path)


tmp = os.path.join(ROOT, "_base_lua.ws")
raw = subprocess.run(["git", "show", "HEAD:lua.ws"], capture_output=True,
                     cwd=ROOT)
with open(tmp, "wb") as f:
    f.write(raw.stdout)

base = counts(tmp)
cur = counts(os.path.join(ROOT, "lua.ws"))
keys = sorted(set(base) | set(cur), key=lambda k: -(abs(cur.get(k, 0) - base.get(k, 0))))
for k in keys:
    d = cur.get(k, 0) - base.get(k, 0)
    if d:
        print("%-28s %+d  (%d -> %d)" % (k, d, base.get(k, 0), cur.get(k, 0)))
print("nodes: %d -> %d" % (sum(base.values()), sum(cur.values())))
print("git show HEAD:lua.ws written to _base_lua.ws")
