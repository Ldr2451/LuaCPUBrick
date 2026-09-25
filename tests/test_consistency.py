"""Structural consistency of the WireScript chip against the spec.

The chip-vs-oracle suite proves behavior matches real Lua. These checks prove
the chip's static structure matches the spec where behavior tests cannot
reach: builtin ids vs reserved function slots, global slot order, limits,
port bindings, opcode coverage, keyword coverage, and re-parse/restart
clearing of every state array. A mismatch here is a gate bug no behavior
test can catch (e.g. the parseJobStart six-slot collision that broke every
function once inarr and outarr took ids 6 and 7).

Run: python -u tests/test_consistency.py  (exit 0 = all green)
"""
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import spec as m

_T0 = time.time()

WS = open(os.path.join(os.path.dirname(HERE), "lua.ws"),
          encoding="utf-8").read()

FAILS = []


def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name
          + ("" if cond or not detail else f": {detail}"))
    if not cond:
        FAILS.append(name)


def mod_body(name):
    """Extract the full body of `mod name(...) { ... }` by brace matching."""
    return _braced(f"mod {name}(")


def _braced(prefix):
    i = WS.index(prefix)
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
ids = sorted(fid for _, fid in m.BUILTINS)
check("builtin-ids-contiguous", ids == list(range(n_builtin)), f"got {ids}")
nb_ws = re.search(r"const NB = (\d+)", WS)
check("nb-const-present", nb_ws is not None, "no `const NB` in lua.ws")
if nb_ws:
    check("nb-matches-builtins", int(nb_ws.group(1)) == n_builtin,
          f"lua.ws NB={nb_ws.group(1)}, spec has {n_builtin} builtins")
pjs = mod_body("parseJobStart")
check("reserved-slots-sized", "fStart.resize(NB, -1)" in pjs,
      "parseJobStart must size the reserved slots from NB, not push them")
vm = mod_body("vmStep")
# the arms live in gateLow and gateHigh now, two named mods, because one chain
# of them all was seventeen inside a mod inlined four times; the call site picks
# between the two on the fid and the generic Lua call is gateHigh's last arm
gate = mod_body("gateLow") + mod_body("gateHigh")
for fid in range(n_builtin):
    check(f"fid-{fid}-dispatched",
          re.search(rf"fid == {fid}\b", gate) is not None)
check("fid-user-else", "} else {" in mod_body("gateHigh"))
check("gate-split-call", "gateLow(cid, a, nargs)" in vm
      and "gateHigh(fid, a, nargs, mtSelf, cid)" in vm)

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
    if len(vals) == len(model_order):
        globals()[arr] = [v.strip() for v in vals]
# a builtin's slot must be a function (tag 4) whose num is its fid: the dispatch
# reads the fid straight out of the value, so a slot pointing at the wrong number
# is a silently different builtin
for name, fid in m.BUILTINS:
    slot = model_order.index(name)
    check(f"builtin-slot-tag-{name}", GTAG_INIT[slot] == "4",
          f"slot {slot} has tag {GTAG_INIT[slot]}")
    check(f"builtin-slot-fid-{name}", float(GNUM_INIT[slot]) == fid,
          f"slot {slot} has num {GNUM_INIT[slot]}, fid {fid}")

# 3. limits -----------------------------------------------------------------
# Every limit is written in lua.ws as a const and mirrored in spec.py; the
# mirror is only useful if it is checked, which is what this loop is for.
for name in ["MAX_INSTR", "MAX_TOKENS", "MAX_REGS", "MAX_FUNCS", "MAX_GLOBALS",
             "MAX_CALLS", "MAX_TABLES", "MAX_HEAP", "MAXVALS"]:
    m_ws = re.search(rf"const {name} = (\d+)", WS)
    check(f"limit-{name}-declared", m_ws is not None, "no const in lua.ws")
    if m_ws:
        check(f"limit-{name}-{getattr(m, name)}",
              int(m_ws.group(1)) == getattr(m, name), f"ws={m_ws.group(1)}")
check(f"log-lines-{m.LOG_LINES}",
      f"logLines.length() > {m.LOG_LINES}" in WS)
check(f"log-width-{m.LOG_WIDTH}",
      f".Length() > {m.LOG_WIDTH}" in WS
      and f"Substring(0, {m.LOG_WIDTH - 1})" in WS)
check(f"outarr-{m.OUTARR}",
      f"outArrV.resize({m.OUTARR}, 0.0)" in WS)
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
check(f"opcodes-0-{m.N_OPS - 1}-handled", handled >= set(range(m.N_OPS)),
      f"missing {[o for o in range(m.N_OPS) if o not in handled]}")
check(f"no-op-{m.N_OPS}", max(emitted | {0}) <= m.N_OPS - 1,
      f"max emitted {max(emitted)}")
check(f"spec-{m.N_OPS}-ops", m.N_OPS == 51 and m.HALT == 0 and m.RETURNM == 42
      and m.CALLM == 41 and m.ADJUST == 43 and m.TAPPEND == 44
      and m.VARARG == 45 and m.GETUP == 46 and m.SETUP == 47
      and m.GETCLO == 48 and m.GEN == 49 and m.FOREND == 50)
readme = open(os.path.join(os.path.dirname(HERE), "README.md"),
             encoding="utf-8").read()
missing_docs = [name for i, name in enumerate(m.OP_NAMES)
                if not re.search(rf"\| {i} \| `{re.escape(name)}` \|", readme)]
check("readme-opcodes-0-49", not missing_docs,
      f"missing {missing_docs}")

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

# 9. library pieces: every piece is installed, and every installer is called ---
# A piece is Lua source the chip prepends, chosen by a mod that looks at the
# program.  A piece with no installer is a "attempt to call" at run time and
# nothing else: the loader has no way to know a library function was supposed to
# be there, which is exactly how gsub's replacement walk lost string.find.  So
# every const is named in some lib mod, and every lib mod goParse calls.
lib_consts = set(re.findall(r"^const (LIB_\w+) =", WS, re.M))
lib_mods = {m.group(1): mod_body(m.group(1))
            for m in re.finditer(r"^mod (lib\w+)\(p: string\) -> string \{", WS,
                                 re.M)}
installed = set()
for name, body in lib_mods.items():
    installed |= set(re.findall(r"\b(LIB_\w+)\b", body))
missing_mod = sorted(lib_consts - installed)
check("every-lib-piece-installed", not missing_mod,
      f"no lib mod mentions {missing_mod}")
goparse = _braced("on goParse {")
called = set(re.findall(r"\b(lib\w+)\(program\)", goparse))
orphan = sorted(set(lib_mods) - called)
check("every-lib-mod-called", not orphan,
      f"goParse never calls {orphan}; add `let libX = libX(program)` and its")
dangling = sorted(called - set(lib_mods))
check("no-missing-lib-mod", not dangling, f"goParse calls undefined {dangling}")
# the pieces are local under short names, so check the assignment reaches the
# concatenation: adding `let libX = ...` and forgetting the `.. libX` is silent
assigned = dict(re.findall(r"let (\w+) = (lib\w+)\(program\)", goparse))
chain = goparse[goparse.index("let lib = "):goparse.index("libLines =")]
used = set(re.findall(r"lib\w+", chain))
for local, mod in sorted(assigned.items()):
    check(f"piece-in-concat-{local}", local in used,
          f"`let {local} = {mod}(program)` is never concatenated")
for local in sorted(used - set(assigned)):
    check(f"concat-has-piece-{local}", False,
          f"the chain names {local}, which no `let {local} = ...` assigns")

print(f"{len(FAILS)} failed" if FAILS else "ALL-OK")
print("test_consistency: %.1fs" % (time.time() - _T0), file=sys.stderr)
sys.exit(1 if FAILS else 0)
