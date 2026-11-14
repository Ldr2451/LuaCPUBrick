"""Bitwise gates whose wired inputs can carry floats -- what the official
simulator refuses ("not certified for inputs (float, int)").

Every Bitwise* gate in the compiled IR gets one line: its inputs, classified
by the TYPE of the source port the wire comes from (Int/Bool are certified;
Float/Number are not). Baked literal operands are not wired, so they do not
appear -- they are certified by construction.

  python -u tools/chip/bitfloat.py [lua.ws]
"""
import os
import sys
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, 'irrun'))
from irdump import parse_modules, _compile_dump  # noqa

path = os.path.join(ROOT, 'lua.ws')
mode = ""
for a in sys.argv[1:]:
    if a in ("baseline", "dump"):
        mode = a
if mode == "baseline":
    import subprocess
    raw = subprocess.run(["git", "show", "HEAD:" + os.path.basename(path)],
                         capture_output=True, cwd=ROOT)
    tmp = os.path.join(ROOT, "_base_%s" % os.path.basename(path))
    with open(tmp, "wb") as f:
        f.write(raw.stdout)
    path = tmp
mode = sys.argv[2] if len(sys.argv) > 2 else ""

dump = _compile_dump(path)
mods = parse_modules(dump)

node_by_id = {}
for m in mods:
    node_by_id.update(m["nodes"])

wired = defaultdict(list)
for m in mods:
    for w in m["wires"]:
        wired[w[2]].append((w[0], w[1], w[3]))


def short(cls):
    c = cls
    for p in ("BrickComponentType_", "WireGraphPseudo_", "WireGraph_"):
        if c.startswith(p):
            c = c[len(p):]
    if "_" in c and c.split("_")[0] in ("Expr", "Exec", "Logic", "Data"):
        c = c.split("_", 1)[1]
    return c


def classify(nid, sport):
    """The type the wire carries out of `nid`'s port `sport`."""
    n = node_by_id.get(nid)
    if n is None:
        return "UNKNOWN"
    for (pname, ptype) in (getattr(n, "pout", None) or []):
        if pname == sport:
            t = ptype
            if t in ("Int", "Bool", "Enum"):
                return "INT"
            if t in ("Float", "Number"):
                return "FLOAT"
            if t in ("String", "Void", "Exec") or t.startswith("Ref("):
                return "OTHER"
            return "UNKNOWN"
    return "UNKNOWN"


bad = defaultdict(int)
total = 0
for nid, n in node_by_id.items():
    s = short(n.cls)
    if not s.startswith("Bitwise"):
        continue
    total += 1
    shapes = []
    for (src, sport, dport) in sorted(wired.get(nid, [])):
        kind = classify(src, sport)
        shapes.append((dport, kind if kind in ("INT", "OTHER") else short(node_by_id[src].cls), kind))
    if any(k == "FLOAT" for (_p, _c, k) in shapes):
        bad[tuple(sorted((p, c) for (p, c, _k) in shapes)) + (s,)] += 1

hist = {}
for nid, n in node_by_id.items():
    hist[short(n.cls)] = hist.get(short(n.cls), 0) + 1
if mode == "dump":
    import json
    print(json.dumps(hist))
    raise SystemExit(0)
top = sorted(hist.items(), key=lambda kv: -kv[1])[:15]
print("class histogram (top):")
for c, n in top:
    print("  %-32s %d" % (c, n))
print("Convert gates:", hist.get("Convert", 0))
print("BitwiseOR gates:", hist.get("BitwiseOR", 0))
print("total Bitwise gate nodes: %d" % len([n for n in node_by_id.values()
                                           if short(n.cls).startswith("Bitwise")]))

for key in sorted(bad, key=lambda k: (-bad[k], k)):
    n = bad[key]
    s = key[-1]
    parts = key[:-1]
    print("%d x  %s: %s" % (n, s, ", ".join("%s <- %s(FLOAT)" % (p, c) for (p, c) in parts)))
    # Show the offending gate's full ancestry for the float wires.
    if n <= 3:
        for nid, nd in node_by_id.items():
            if short(nd.cls) != s:
                continue
            shp = [(src, sport, dport, classify(src, sport))
                   for (src, sport, dport) in sorted(wired.get(nid, []))]
            if all(k != "FLOAT" for (_s, _sp, _dp, k) in shp):
                continue
            print("  gate %d:" % nid)
            for (src, sport, dport, k) in shp:
                if k != "FLOAT":
                    continue
                print("    %s <- %d.%s" % (dport, src, sport))
                sn = node_by_id[src]
                for (s2, sport2, dport2) in sorted(wired.get(src, [])):
                    print("      src %d (%s) in %s <- %d.%s (%s)" % (
                        src, short(sn.cls), dport2, s2, sport2, classify(s2, sport2)))
                    for (s3, sport3, dport3) in sorted(wired.get(s2, [])):
                        print("        src %d (%s) in %s <- %d.%s (%s)" % (
                            s2, short(node_by_id[s2].cls) if s2 in node_by_id else "?",
                            dport3, s3, sport3, classify(s3, sport3)))
                        for (s4, sport4, dport4) in sorted(wired.get(s3, [])):
                            print("          src %d (%s) in %s <- %d.%s (%s)" % (
                                s3, short(node_by_id[s3].cls) if s3 in node_by_id else "?",
                                dport4, s4, sport4, classify(s4, sport4)))

print("Bitwise gates: %d, with a float-typed wire: %d"
      % (total, sum(bad.values())))
