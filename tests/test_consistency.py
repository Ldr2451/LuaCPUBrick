"""Structural consistency of the WireScript chip against the spec.

The chip-vs-oracle suite proves behavior matches real Lua. These checks prove
the chip's static structure matches the spec where behavior tests cannot
reach: builtin ids vs reserved function slots, global slot order, limits,
port bindings, opcode coverage, keyword coverage, and re-parse/restart
clearing of every state array. A mismatch here is a gate bug no behavior
test can catch (e.g. the parseJobStart six-slot collision that broke every
function once innumarr and outarr took ids 6 and 7).

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
    """Extract the full body of `mod name(...) { ... }` by brace matching.

    Either keyword.  resolveKw became a `chip` -- it is called twice from inside
    lexStep, which is itself a chip, so its body existed twice over, and -57
    nodes is what that was worth -- and keying the search on `mod` alone made
    this net die with "substring not found" on a chip that is perfectly fine,
    which is how a net gets ignored.  The body is what this net is about, not
    how it is declared.
    """
    for prefix in (f"mod {name}(", f"chip {name}("):
        if prefix in WS:
            return _braced(prefix)
    raise ValueError("no mod or chip named %r" % name)


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
# Two ids are RESERVED with no builtin behind them: 3 was outvec and 4 was
# outcol.  Both ports are gone, and renumbering the builtins above them
# would move every one for no gain, so the holes stay.  The rule is therefore
# "contiguous with declared holes", and a hole has to be deliberate -- which is
# what RESERVED_FIDS is for.
RESERVED_FIDS = {3, 4}
n_builtin = len(m.BUILTINS)
ids = sorted(fid for _, fid in m.BUILTINS)
expected = [i for i in range(max(ids) + 1) if i not in RESERVED_FIDS]
check("builtin-ids-contiguous", ids == expected,
      f"got {ids}, want {expected} with {sorted(RESERVED_FIDS)} reserved")
nb_ws = re.search(r"const NB = (\d+)", WS)
check("nb-const-present", nb_ws is not None, "no `const NB` in lua.ws")
if nb_ws:
    check("nb-matches-builtins", int(nb_ws.group(1)) == max(ids) + 1,
          f"lua.ws NB={nb_ws.group(1)}, spec has {n_builtin} builtins")
pjs = mod_body("parseJobStart")
check("reserved-slots-sized", "fStart.resize(NB, -1)" in pjs,
      "parseJobStart must size the reserved slots from NB, not push them")
vm = mod_body("vmStep")
# the arms live in gateLow and gateHigh now, two named mods, because one chain
# of them all was seventeen inside a mod inlined four times; the call site picks
# between the two on the fid and the generic Lua call is gateHigh's last arm
gate = mod_body("gateLow") + mod_body("gateHigh")
for _name, fid in sorted(m.BUILTINS, key=lambda kv: kv[1]):
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
             "MAX_CALLS", "MAX_TABLES", "MAX_HEAP", "MAX_CLO", "MAXVALS"]:
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
# The inNumArr/outArr index warnings need the width while PARSING, and an input port
# cannot be read then - it empties every program's log - so the width is a const.
# That makes two rules that have to agree, and a comment is not a check: this one
# is, and it also fails if the warnings go back to reading the array or a literal.
_m_arr = re.search(r"const ARR_SLOTS = (\d+)", WS)
check("arr-slots-declared", _m_arr is not None, "no ARR_SLOTS const in lua.ws")
if _m_arr:
    check(f"arr-slots-{m.OUTARR}", int(_m_arr.group(1)) == m.OUTARR,
          f"ws={_m_arr.group(1)} spec={m.OUTARR}")
check("arr-slots-used", "v > ARR_SLOTS" in WS,
      "the index warnings must compare against the const, not a literal")
check("call-params-8", "max 8 in-gate" in WS)

# 4. ports ------------------------------------------------------------------
outs = re.findall(r"@right out (\w+)(?:: (\S+))? = (\S+)", WS)
outs_d = {n: (t, b) for n, t, b in outs}
for port, typ in [("log", "string"), ("outNum0", "float"),
                  ("outNum1", "float"), ("outNum2", "float"),
                  ("outNum3", "float"), ("outNum4", "float"),
                  ("outStr0", "string"),
                  ("outStr1", "string"), ("outArr", "float[]"),
                  ("result", "string"), ("err", "string"),
                  ("progDebug", "string"), ("busy", "bool")]:
    check(f"port-{port}", port in outs_d,
          f"missing (have {sorted(outs_d)})")
    if port in outs_d and typ:
        check(f"port-{port}-type", outs_d[port][0] == typ,
              f"got {outs_d[port][0]}")
for port, bindvar in [("log", "logV"), ("outNum0", "oF0"),
                      ("outNum4", "oF4"),
                      ("outStr0", "oS4"), ("result", "resultV"),
                      ("err", "errV"), ("progDebug", "progDebugV")]:
    check(f"port-{port}-bound", re.search(
        rf"^(var|let) {bindvar}\b", WS, re.M) is not None)
check("no-halted-port", "out halted" not in WS)
check("no-proglen-port", "out progLen" not in WS)
check("no-nprint-port", "out nPrint" not in WS)
for hw, port in [("innumarr", "inNumArr"), ("instrarr", "inStrArr"),
                 ("outarr", "outArr"), ("print", "log")]:
    check(f"hw-{hw}-{port}", re.search(
        rf"@(?:left|right) (?:in|out) {port}\b", WS) is not None)
# An array port cannot be watched: `Change` observes one wire value and a
# container has none (WS059 from the compiler).  BOTH array ports are named here
# rather than the one that turned out to be un-watchable, because the second one
# is added later and would otherwise be added unwatched by nobody noticing.
for _arr in ("inNumArr", "inStrArr"):
    check(f"no-change-on-array-{_arr}", f"on Change({_arr})" not in WS)

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
for var in ["logV", "oF0", "oF4", "oS4",
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
# The opcode table lives in docs/vm-isa.md, not in the README: the README says
# what the project is, and a reference table of 51 opcodes is not that.  The
# invariant is unchanged -- every opcode in the spec must be documented -- it
# just follows the documentation where it went.
isa_doc = open(os.path.join(os.path.dirname(HERE), "docs", "vm-isa.md"),
               encoding="utf-8").read()
missing_docs = [name for i, name in enumerate(m.OP_NAMES)
                if not re.search(rf"\| {i} \| `{re.escape(name)}` \|", isa_doc)]
check("isa-doc-opcodes-0-50", not missing_docs,
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

# 10. every builtin the chip declares must be accounted for in the oracle model --
#     the rot that let outvec/outcol go missing for the whole life of the demo, so
#     that any program touching a vector or a colour made the MODEL raise and the
#     demo's expected log had to be written by hand (and could not fail).
# spec.BUILTINS is the source of truth: it is the function builtins, and the
# checks above already hold it against the chip's ids.  Adding a builtin therefore
# forces a decision, and the decision is the point:
#   modelled    the prelude provides it, so a differential case can call it;
#   puc_native  PUC itself has it, so the model needs no shim;
#   chip_only   the reference cannot have it -- an internal gate, a fixed-arity
#               helper PUC spells differently, ServerUptime.
PUC_NATIVE = {"print", "type", "tostring", "next", "select", "error", "assert",
              "pcall", "xpcall", "pairs", "ipairs", "tonumber", "math", "string",
              "table", "io"}
CHIP_ONLY = {"_s", "_m", "_fmt", "_pat", "_gmatch", "_gmnext", "_rd", "_wr",
             "unpack", "clock"}

declared_builtins = set(name for name, _fid in m.BUILTINS)
prelude = open(os.path.join(HERE, "lua_oracle.py"), encoding="utf-8").read()
# the shims the prelude installs: "name = function", and the loop that installs
# the writable output globals
shims = set(re.findall(r'pre\.append\("(\w+) = function', prelude))
unmodelled = sorted(declared_builtins - shims - PUC_NATIVE - CHIP_ONLY)
check("declared-builtins-modelled", not unmodelled,
      f"neither modelled nor accounted for: {unmodelled}")

# and the other direction: a shim for a builtin the chip does not have is rot too
stale = sorted(s_ for s_ in shims
               if s_ not in declared_builtins and s_ not in PUC_NATIVE)
check("no-stale-prelude-shims", not stale,
      f"the model shims builtins the chip does not declare: {stale}")

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
# 11. the README's picture of the interface, and the demo's expected log -------
# Both are things a person reads or a person maintains, and both rot silently.
import subprocess

_diag = subprocess.run(
    [sys.executable, "-u", os.path.join(os.path.dirname(HERE), "tools", "chip",
                                        "port_diagram.py"), "--check"],
    cwd=os.path.dirname(HERE), capture_output=True, text=True,
    encoding="utf-8", errors="replace")
check("readme-port-diagram", _diag.returncode == 0,
      (_diag.stdout + _diag.stderr).strip()[:160])

# The suite reads a case's numeric inputs from the tuple's THIRD slot and copies
# that slot over any `inputs` in the kw, so a case that carries `inputs` in the kw
# has them silently discarded.  Three cases did, and it cost a session: one went
# red for a reason that had nothing to do with the chip, and one - inputs-int -
# went on PASSING VACUOUSLY, because the chip and the oracle were both given no
# inputs and agreed with each other.  A silently dropped input is worse than a
# wrong one, because it turns a test off without saying so.
try:
    sys.path.insert(0, HERE)
    import cases as _c2
    _misplaced = [t[0] for t in _c2.TESTS
                  if len(t) > 4 and isinstance(t[4], dict)
                  and "inputs" in t[4] and t[2] is None]
    check("case-inputs-in-the-inputs-slot", not _misplaced,
          "these carry `inputs` in the kw, which the suite overwrites with the "
          "third slot (None): %s" % (_misplaced,))
except Exception as _e:
    check("case-inputs-in-the-inputs-slot", False, "the check failed: %r" % (_e,))

# The graph the tests RUN must be the graph this lua.ws compiles to.  Four cases
# read outNum4 as 0.0 for a whole session while a direct probe of the same program
# read -3.5, and the reason was that the suite's graph still had outCol and
# outInt0 - ports deleted days earlier - and no outNum4.  Nothing said so: a
# stale graph is a silent wrong answer, and it looks exactly like a chip bug.
# So the port sets are compared, here, by compiling the source and asking the
# resulting Sim what ports it has.
try:
    sys.path.insert(0, os.path.join(os.path.dirname(HERE), "irrun"))
    sys.path.insert(0, HERE)
    from irsims import Sim, Wire, _extract  # noqa: E402
    from irdump import dump_source  # noqa: E402
    _ws_path = os.path.join(os.path.dirname(HERE), "lua.ws")
    _src = open(_ws_path, encoding="utf-8").read()
    _want_in = set(re.findall(r"@left\s+in\s+(\w+)\s*:", _src))
    _want_out = set(re.findall(r"@right\s+out\s+(\w+)\s*:", _src))
    _nodes, _wires, _ = dump_source(_ws_path)
    _sim = Sim(_nodes, [Wire(*w) for w in _wires])
    _got_in = set(_sim.port_label.values())
    _got_out = {_extract(nd.props.get("PortLabel", ("raw", "")))
                for _nid, nd in _sim.nodes.items()
                if "Internal_MicrochipOutput" in nd.cls}
    _got_out = {g for g in _got_out if isinstance(g, str) and g}
    check("graph-inputs-match-source", _got_in == _want_in,
          "source %s vs graph %s" % (sorted(_want_in - _got_in),
                                     sorted(_got_in - _want_in)))
    check("graph-outputs-match-source", _got_out == _want_out,
          "source %s vs graph %s; THE TESTS ARE RUNNING A DIFFERENT CHIP"
          % (sorted(_want_out - _got_out), sorted(_got_out - _want_out)))
except Exception as _e:
    check("graph-ports-match-source", False,
          "the check itself failed: %r" % (_e,))

try:
    sys.path.insert(0, HERE)
    import cases as _cases
    import lua_oracle as _or
    # the SAME normaliser the suite compares with, so the two cannot disagree
    # about what a log is: oracle_log joins lines and folds a table's address,
    # and DEMO_LOG is a literal that spells both
    from test_chip_suite import norm_log
    _kw = dict(_cases.DEMO_KW)
    _kw["inputs"] = [3, 1, 4, 1.5]
    _o = _or.oracle_run(_cases.DEMO_SRC, inputs=_kw["inputs"],
                        sinputs=_kw.get("sinputs"), vec=_kw.get("vec"),
                        innumarr=_kw.get("innumarr"),
                        instrarr=_kw.get("instrarr"))
    if not _o.get("avail") or _o["calls"] is None:
        check("demo-log-current", False, "no oracle, so DEMO_LOG is unchecked")
    else:
        _want = norm_log(_or.oracle_log(_or.norm_calls(_o["calls"])))
        check("demo-log-current", _want == norm_log(_cases.DEMO_LOG),
              "DEMO_LOG is stale -- regenerate it from the oracle:\\n"
              "  want %r\\n  have %r" % (_want[:120], norm_log(_cases.DEMO_LOG)[:120]))
except Exception as _e:
    # a check that cannot run is not a check
    check("demo-log-current", False, "the check itself failed: %r" % (_e,))


sys.exit(1 if FAILS else 0)
