"""Structural map of the `lerr`/`lstage` var traffic in the compiled IR.

The official simulator hangs on every lexFail path (busy stays true, progDebug
stuck at "info: parse start") while the game answers the error.  All the lerr
reads are CSE'd onto ONE Var-Get gate; the sim's exec Var-Get fires only when
its Exec chain fires, and pure consumers read its persisted Value port.  So
the shape that matters is: which exec gate each consumer chain bottoms at,
and which Var-Set writes feed that Var gate.

Every Var node named in VARS gets its lines:

  VAR g            the container gate
  GET g            exec Var-Get reading it, with its Exec source and the
                   pure chains its Value port feeds (walked to exec gates)
  SET g            exec Var-Set writing it, with the written value shape and
                   the exec gate that drives it

  python -u tools/chip/lerrpath.py [lua.ws]
"""
import os
import sys
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, 'irrun'))
from irdump import parse_modules, _compile_dump  # noqa

path = os.path.join(ROOT, 'lua.ws')
if len(sys.argv) > 1:
    path = os.path.join(ROOT, sys.argv[1])

dump = _compile_dump(path)
mods = parse_modules(dump)

node_by_id = {}
for m in mods:
    node_by_id.update(m["nodes"])

# in-edges: wires arriving at a node, by dest port name
inp = defaultdict(dict)
# out-edges: wires leaving a node, by source port name
out = defaultdict(list)
for m in mods:
    for (src, sport, dst, dport) in m["wires"]:
        inp[dst][dport] = (src, sport)
        out[src].append((sport, dst, dport))


def short(cls):
    c = cls
    for p in ("BrickComponentType_", "WireGraphPseudo_", "WireGraph_"):
        if c.startswith(p):
            c = c[len(p):]
    if "_" in c and c.split("_")[0] in ("Expr", "Exec", "Logic", "Data"):
        c = c.split("_", 1)[1]
    return c


def vname(nid):
    """The variable a Var container node names, or None."""
    n = node_by_id.get(nid)
    if n is None or short(n.cls) != "Var":
        return None
    for (k, v) in (getattr(n, "props", None) or {}).items():
        if k in ("VarName", "name", "Name", "VarRef"):
            if isinstance(v, tuple) and v[0] == "str":
                return v[1]
    # props may be empty; the PortLabel of the container sometimes names it
    return None


def shape(nid):
    """(gets, sets, stored-value shapes) for a Var container."""
    gets = [d for (sp, d, dp) in out[nid] if sp == "VarRef"
            and short(node_by_id[d].cls) in ("Var_Get", "Exec_Var_Get")]
    sets = [d for (sp, d, dp) in out[nid] if sp == "VarRef"
            and short(node_by_id[d].cls) in ("Var_Set", "Exec_Var_Set",
                                             "Var_Increment")]
    vals = []
    for s in sets:
        w = inp[s].get("Value")
        if w is None:
            pr = (getattr(node_by_id[s], "props", None) or {}).get("Value")
            vals.append(repr(pr) if pr else "stored?")
        else:
            vals.append(short(node_by_id[w[0]].cls) if w[0] in node_by_id
                        else "wire")
    return gets, sets, vals


print("Var containers, one-line shape each (get set vals):")
cands = []
for nid, n in node_by_id.items():
    if short(n.cls) != "Var":
        continue
    gets, sets, vals = shape(nid)
    key = (len(gets), len(sets), tuple(sorted(set(vals))))
    cands.append((nid, key))
# the lerr candidate: exactly one GET, and a stored-true write next to stored-false
hist = {}
for (nid, key) in cands:
    hist[key] = hist.get(key, 0) + 1
for key in sorted(hist, key=lambda k: (k[0], k[1], str(k[2]))):
    if hist[key] <= 3:
        ids = [nid for (nid, k) in cands if k == key]
        print("  %-40s x%d  ids=%s" % (str(key), hist[key], ids))
# The sim says the lerr Var gate has exactly ONE Var-Get reader and three VarSet
# writes (two stored false, one stored true). Find that shape, then report the
# GET's exec source, the pure chains its Value feeds, and each SET's exec driver.
cand = []
for nid, n in node_by_id.items():
    if short(n.cls) != "Var":
        continue
    gets, sets, vals = shape(nid)
    if len(gets) == 1 and any("bool" in str(v) for v in vals):
        key = (len(sets), tuple(sorted(set(vals))))
        if key in ((3, ("('bool', False)", "('bool', True)")),
                   (4, ("('bool', False)", "('bool', True)")),
                   (5, ("('bool', False)", "('bool', True)")),
                   (13, ("('bool', False)", "('bool', True)"))):
            cand.append(nid)
targets = dict(("lerr-cand %d" % i, nid) for (i, nid) in enumerate(cand))


def walk_pure(src, sport, depth=0, seen=None):
    """Pure consumers of `src`'s `sport`, printed to the exec gate that reads
    them; exec consumers print at once."""
    if seen is None:
        seen = set()
    for (dport, dst) in [(dp, d2) for (sp, d2, dp) in out[src] if sp == sport]:
        if dst in seen:
            continue
        seen.add(dst)
        c = short(node_by_id[dst].cls) if dst in node_by_id else "?"
        if c == "VarRef":
            continue
        print("    " * (depth + 1) + "<-%s %d (%s)" % (dport, dst, c))
        if c in ("VarRef", "Var_Get", "Exec_Var_Get") or depth >= 8:
            continue
        for (dsp, d2, ddp) in out[dst]:
            walk_pure(dst, dsp, depth + 1, seen)


for v, root in sorted(targets.items()):
    print("\n== %s (var gate %d)" % (v, root))
    for (sport, dst, dport) in sorted(out[root]):
        if sport != "VarRef":
            print("  var port %s -> %d" % (sport, dst))
    gets = [d for (sp, d, dp) in out[root] if sp == "VarRef"
            and short(node_by_id[d].cls) in ("Var_Get", "Exec_Var_Get")]
    sets = [d for (sp, d, dp) in out[root] if sp == "VarRef"
            and short(node_by_id[d].cls) in ("Var_Set", "Exec_Var_Set",
                                             "Var_Increment")]
    print("  GETs: %s" % [g for g in gets])
    print("  SETs: %s" % [s for s in sets])
    for g in gets:
        src = inp[g].get("Exec")
        print("  GET %d: Exec <- %s %s" % (g, src[0] if src else "-",
              short(node_by_id[src[0]].cls) if src and src[0] in node_by_id else "-"))
        walk_pure(g, "Value")
    for s in sets:
        src = inp[s].get("Exec")
        val = inp[s].get("Value")
        shape = "stored"
        if val and val[0] in node_by_id:
            shape = short(node_by_id[val[0]].cls)
        print("  SET %d: Exec <- %s; Value <- %s" % (
            s, short(node_by_id[src[0]].cls) if src and src[0] in node_by_id else "-",
            shape))
