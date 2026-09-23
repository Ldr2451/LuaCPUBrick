"""Structural consistency of the WireScript chip against the spec.

The chip-vs-oracle suite proves behavior matches real Lua. These checks prove
the chip's static structure matches the spec where behavior tests cannot
reach: builtin ids vs reserved function slots, global slot order, limits,
port bindings, opcode coverage, keyword coverage, and re-parse/restart
clearing of every state array. A mismatch here is a gate bug no behavior
test can catch (e.g. the parseJobStart six-slot collision that broke every
function once inarr and outarr took ids 6 and 7).

Run: python test_ws_consistency.py  (exit 0 = all green)
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import spec as m

WS = open(os.path.join(HERE, "lua.ws"), encoding="utf-8").read()

FAILS = []


def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name
          + ("" if cond or not detail else f": {detail}"))
    if not cond:
        FAILS.append(name)


def mod_body(name):
    """Extract the full body of `mod name(...) { ... }` by brace matching."""
    i = WS.index(f"mod {name}(")
    i = WS.index("{", i)
    depth, j = 0, i
    while True:
        if WS[j] == "{":
            depth += 1
        elif WS[j] == "}":
            depth -= 1
            if depth == 0:
                return WS[i:j + 1]
        j += 1


# 1. builtins: ids, reserved slots, fid dispatch ---------------------------
n_builtin = len(m.BUILTINS)
check("builtin-count-8", n_builtin == 8, f"got {n_builtin}")
ids = sorted(fid for _, fid in m.BUILTINS)
check("builtin-ids-0-7", ids == list(range(8)), f"got {ids}")
pjs = mod_body("parseJobStart")
slots = pjs.count("fStart.push(-1)")
check("reserved-slots-match-builtins", slots == n_builtin,
      f"parseJobStart reserves {slots}, builtins need {n_builtin}")
vm = mod_body("vmStep")
for fid in range(n_builtin):
    check(f"fid-{fid}-dispatched",
          re.search(rf"fid == {fid}\b", vm) is not None)
check("fid-user-else", "} else {" in vm)

# 2. global slot order ------------------------------------------------------
model_order = list(m.GSLOT_ORDER)
decls = re.findall(r'gDeclare\("(\w+)"\)', mod_body("parseInit"))
check("global-order-match", decls == model_order,
      f"\n  ws   ={decls}\n  spec ={model_order}")
check("global-count-64", len(model_order) <= m.MAX_GLOBALS,
      f"{len(model_order)} slots vs MAX_GLOBALS={m.MAX_GLOBALS}")
for arr, n in (("GTAG_INIT", None), ("GNUM_INIT", None)):
    vals = re.search(arr + r": (?:int|float)\[\] = \[([^\]]*)\]",
                     WS).group(1).split(",")
    check(f"{arr}-len", len(vals) == len(model_order),
          f"{len(vals)} vs {len(model_order)}")

# 3. limits -----------------------------------------------------------------
for name in ["MAX_INSTR", "MAX_REGS", "MAX_FUNCS", "MAX_GLOBALS",
             "MAX_TABLES", "MAX_HEAP"]:
    wv = int(re.search(rf"const {name} = (\d+)", WS).group(1))
    check(f"limit-{name}-{getattr(m, name)}", wv == getattr(m, name),
          f"ws={wv}")
check("log-lines-32", "logLines.length() > 32" in WS)
check("log-width-64", ".Length() > 64" in WS
      and "Substring(0, 63)" in WS)
check("outarr-64", "outArrV.resize(64, 0.0)" in WS)
check("call-args-16", "nargs > 16" in WS)
check("call-params-8", "max 8 in-gate" in WS)

# 4. ports ------------------------------------------------------------------
outs = re.findall(r"@right out (\w+)(?:: (\S+))? = (\S+)", WS)
outs_d = {n: (t, b) for n, t, b in outs}
for port, typ in [("log", "string"), ("outNum0", "float"),
                  ("outNum1", "float"), ("outNum2", "float"),
                  ("outNum3", "float"), ("outInt0", "int"),
                  ("outStr0", "string"),
                  ("outStr1", "string"), ("outArr", "float[]"),
                  ("result", "string"), ("err", "string"),
                  ("progOk", "bool"), ("busy", "bool")]:
    check(f"port-{port}", port in outs_d,
          f"missing (have {sorted(outs_d)})")
    if port in outs_d and typ:
        check(f"port-{port}-type", outs_d[port][0] == typ,
              f"got {outs_d[port][0]}")
for port, bindvar in [("log", "logV"), ("outNum0", "oF0"),
                      ("outInt0", "oI0"),
                      ("outStr0", "oS4"), ("result", "resultV"),
                      ("err", "errV"), ("progOk", "progOkV")]:
    check(f"port-{port}-bound", re.search(
        rf"^(var|let) {bindvar}\b", WS, re.M) is not None)
check("no-halted-port", "out halted" not in WS)
check("no-proglen-port", "out progLen" not in WS)
check("no-nprint-port", "out nPrint" not in WS)
for hw, port in [("inarr", "inArr"), ("outarr", "outArr"),
                 ("setvec", "outVec"), ("setcol", "outCol"),
                 ("print", "log")]:
    check(f"hw-{hw}-{port}", re.search(
        rf"@(?:left|right) (?:in|out) {port}\b", WS) is not None)
check("no-change-on-array", "on Change(inArr)" not in WS)

# 5. state clearing: every array/Map cleared on re-parse or restart ---------
decls_arr = set(re.findall(r"^var (\w+): (?:.*\[\]|Map<[^>]*>)",
                           WS, re.M))
with_init = set(re.findall(r"^var (\w+): (?:.*\[\]|Map<[^>]*>) =",
                           WS, re.M))
must_clear = decls_arr - with_init
pi = mod_body("parseInit")
vr = mod_body("vmReset")
cleared = (set(re.findall(r"(\w+)\.clear\(\)", pi))
           | set(re.findall(r"(\w+)\.clear\(\)", vr)))
missing = sorted(n for n in must_clear if n not in cleared)
check("all-state-cleared", not missing, f"never cleared: {missing}")
for where, body in (("parseInit", pi), ("vmReset", vr)):
    for tgt in set(re.findall(r"(\w+)\.clear\(\)", body)):
        check(f"clear-target-{tgt}-{where}", tgt in decls_arr,
              "clears undeclared array")
# restart resets outputs, log and error text
for var in ["logV", "oF0", "oI0", "oS4", "outVecV", "outColV",
            "resultV", "errV"]:
    check(f"reset-{var}", re.search(rf"\b{var} = ", vr) is not None)
check("reset-logLines", "logLines.clear()" in vr)
check("reset-outArrV", "outArrV.resize(64, 0.0)" in vr)

# 6. opcode coverage: every model opcode handled in vmStep -------------------
# (8..13 share one range-dispatched arithmetic branch)
handled = set(int(x) for x in re.findall(r"op == (\d+)", vm))
if re.search(r"op >= 8 && op <= 13", vm):
    handled |= set(range(8, 14))
emitted = set(int(x) for x in re.findall(r"bEmit\((\d+)", WS))
check("opcodes-0-42-handled", handled >= set(range(43)),
      f"missing {[o for o in range(43) if o not in handled]}")
check("no-op-43", max(emitted | {0}) <= 42,
      f"max emitted {max(emitted)}")
check("spec-43-ops", m.N_OPS == 43 and m.HALT == 0 and m.RETURNM == 42 and m.CALLM == 41)

# 7. keyword coverage --------------------------------------------------------
model_kw = set(m.KEYWORDS)
ws_kw = set(re.findall(r'n == "(\w+)"', mod_body("resolveKw")))
check("keywords-match", ws_kw == model_kw,
      f"\n  ws-only={sorted(ws_kw - model_kw)}"
      f"\n  model-only={sorted(model_kw - ws_kw)}")

# 8. error-line wiring -------------------------------------------------------
check("tl-push", "tl.push(lline)" in WS)
check("tl-clear", "tl.clear()" in pi)
check("tl-read", "tl[epos]" in WS)
check("lex-line-tracked", "lerrLine = lline" in WS)

print(f"{len(FAILS)} failed" if FAILS else "ALL-OK")
sys.exit(1 if FAILS else 0)
