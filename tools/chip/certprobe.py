"""Which input SIGNATURES the simulator's certified table covers, per class.

An engine refusal says "Expr_Floor ... not certified for inputs (int)": the
gate class and the value variants it was fed.  The table of what IS certified
is `gates` in data/gate_semantics.json inside the simulator crate, keyed by
BrickComponentType_Expr_*, each with the probed `cases` and their variants.
This prints, for every class whose name mentions one of the given words, the
set of variant pairs the table covers, so a chip edit can pick an operation
whose signature is covered rather than guess at the language's promotion rule.

    python -u tools/chip/_certprobe.py Floor Ceil Modulo CompareEqual
"""
import json
import sys

P = (r"C:\Users\Alessandro\Documents\New OpenCode Project\wirescript"
     r"\crates\wirescript-ir\data\gate_semantics.json")

d = json.load(open(P, encoding="utf-8"))
want = sys.argv[1:] or ["Floor", "Ceil", "Round", "Modulo", "CompareEqual",
                        "Multiply", "Subtract"]
gates = d.get("gates") or {}
for name in sorted(gates):
    short = name.split("_")[-1]
    if not any(w in name for w in want):
        continue
    body = gates[name]
    sigs = {}
    for c in body.get("cases") or []:
        vs = tuple((i.get("variant") if isinstance(i, dict) else "?")
                   for i in c.get("inputs") or [])
        sigs[vs] = sigs.get(vs, 0) + 1
    print(short, ":", len(body.get("cases") or []), "cases")
    for sig, n in sorted(sigs.items()):
        print("   ", "/".join(sig or ["-"]), "x%d" % n)
