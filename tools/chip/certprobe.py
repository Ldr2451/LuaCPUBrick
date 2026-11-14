"""Which input SIGNATURES the simulator's certified table covers, per class.

An engine refusal says "Expr_MathPow ... not certified for inputs (float,
float)": the gate class and the value VARIANTS it was fed.  The table of what
IS certified is `gates` in data/gate_semantics.json inside the simulator crate,
keyed BrickComponentType_Expr_*, each with the probed `cases` and their
variants.  This prints the variant pairs covered for every class whose name
matches one of the given words (a bare word matches many classes, which is
usually what you want: compare Pow against PowerOfTwo, Ln against LnSafe).

    python -u tools/chip/certprobe.py MathPow MathLn MathSqrt
"""
import json
import sys

P = (r"C:\Users\Alessandro\Documents\New OpenCode Project\wirescript"
     r"\crates\wirescript-ir\data\gate_semantics.json")

d = json.load(open(P, encoding="utf-8"))
want = sys.argv[1:] or ["Floor", "Ceil", "Modulo", "CompareEqual"]
gates = d.get("gates") or {}
for name in sorted(gates):
    if not any(w in name for w in want):
        continue
    body = gates[name]
    sigs = {}
    for c in body.get("cases") or []:
        vs = tuple((i.get("variant") if isinstance(i, dict) else "?")
                   for i in c.get("inputs") or [])
        sigs[vs] = sigs.get(vs, 0) + 1
    print(name.replace("BrickComponentType_", ""), ":",
          len(body.get("cases") or []), "cases")
    for sig, n in sorted(sigs.items()):
        print("   ", "/".join(sig or ["-"]), "x%d" % n)
