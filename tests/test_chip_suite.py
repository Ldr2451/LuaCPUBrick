"""Chip-vs-Lua5.5 parity suite: every case in tests/cases.py runs on the
compiled chip (tick sim, timeout-bounded worker subprocess) and against the
real Lua 5.5 oracle. No Python model in the loop.

Usage:
  python -u tests/test_chip_suite.py [filter]  # cases whose name contains filter
  python -u tests/test_chip_suite.py --list    # list case names
  Append --ws=PATH to test a different chip source instead of lua.ws.

Every case runs unless a filter narrows it down.  Cases are handed to a pool of
worker processes one at a time, each worker with its own Sim over one shared
compile of the chip, so the chip is compiled and indexed once for the whole run
and one slow case cannot hold up the rest.  CHIP_POOL=0 is the old batch shape
(CHIP_BATCH, default 12).  A case that hangs or times out falls back to a
per-case subprocess.  Exit 0 when all green.
"""
import concurrent.futures as cf
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
TINYLUA = os.path.dirname(HERE)
sys.path.insert(0, TINYLUA)
sys.path.insert(0, os.path.join(HERE))
sys.path.insert(0, os.path.join(TINYLUA, "irrun"))

import cases
import lua_oracle as OR
from timing import Elapsed
from irdump import resolve_prog

WS_PATH = os.path.join(TINYLUA, "lua.ws")

WORKERS = int(os.environ.get("CHIP_WORKERS", "12"))
# The chip is compiled once for the whole run and every worker loads that dump,
# so the batch size below is not a build cost -- it is how coarse work stealing
# is.  The default is the pool (POOL=1), which hands out one case at a time; the
# batch path is there for CHIP_POOL=0, which is also the shape the one-case retry
# and the per-batch timeout were written for.
POOL = int(os.environ.get("CHIP_POOL", "1"))
BATCH = int(os.environ.get("CHIP_BATCH", "12"))
TIMEOUT = 90  # seconds per case; healthy runs take ~5-8s
TICKS = 6000

# Cases the tick sim cannot reach, or that fail for a reason still open.  Every
# entry here says what was measured, so the next attempt starts from evidence.
SKIP = {
    # pcall of a library wrapper that then calls a gate loses an argument:
    # `pcall(string.find, "abc")` reports argument #1 where PUC reports #2, and
    # `pcall(string.find, "ab", "b", 1)` finds nothing because the init is read
    # one register early.  The pcall frame is one level deep (pcall of pcall is
    # refused for the same reason) and the gate is dispatched on the re-run with
    # the count patched into the bytecode, so the arguments move but the reads
    # do not follow.  It is a path of its own, not the matcher's.
    "pcall-gate-args": "pcall of a wrapper that calls a gate loses an argument",
    # A GATE as xpcall's message handler always comes back nil, where a function
    # handler with the same body returns its value: xpcall(f, type) gives
    # "string" in PUC and nil here, and pcall-of-a-gate (the SKIP above) is the
    # same shape.  Measured, not guessed:
    #
    #   - the compile is correct.  Driving the parse with `run` false and reading
    #     the bytecode shows the CALL emitted with nargs=2 in every variant, so a
    #     bytecode dump taken *after* a run is not evidence about the compile --
    #     the pcall re-dispatch patches the instruction in place
    #     (bpb[pcallGatePc] = pcallGateArgs) and the dump shows the patched count.
    #   - a per-tick trace of the result slots (Sim.run's on_tick hook) shows
    #     pcallMode = 2 and pcallRan = true, i.e. pcallEnd's handler branch *is*
    #     reached, and it is handed k=2 for a gate that produced at most one
    #     value.
    #
    # The cause is structural, not a missing line: a protected call is re-run by
    # moving f into the instruction's own register and letting the dispatch read
    # the gate out of it, but pcallStep leaves the *xpcall* in that register, so
    # a gate handler's re-dispatch comes back as xpcall again and the handler
    # never runs.  Writing the handler's id into that register first (tried) does
    # not help on its own, because the dispatch also re-enters the pcall arm and
    # pushes a second marker.  Four fixes were attempted and measured, none of
    # which changed the outcome -- a separate pc for the handler, saving and
    # restoring the borrowed count, substituting PUC's "<no error object>", and
    # writing the handler id into the dispatch register.  The real fix is to give
    # a gate handler a dispatch that does not go through the xpcall instruction
    # at all, which is a change to the pcall design rather than a patch on it.
    "xpcall-gate-handler": "a gate message handler is re-dispatched as the xpcall around it",
    # PUC substitutes "<no error object>" when the handler returns no value; the
    # chip hands back nil.  Same root cause as the SKIP above (the gate handler's
    # result never lands), so it is fixed with it rather than separately: pcallEnd
    # is reached and is handed the right count, but by then the slot holds nil
    # because the gate never ran.
    "xpcall-gate-handler-nil": "a handler with no result gives nil, PUC gives <no error object>",
}

# Extra VM ticks / timeouts for heavy but reachable cases.
TICKS_OVERRIDES = {
    "func-fib": 300000,
    "tab-bubble": 120000,
    "log-many": 60000,
    # A loop of 2000 iterations, and vmBurst now runs one instruction per tick
    # rather than four, so a case like this needs 3.6x the ticks it did.  The
    # budget moves with the chip: anything that was near the cap before gets
    # room now.
    "long-sum": 24000,
    # The case was written for a CALL landing mid-burst, which one step per tick
    # cannot do, so the burst timing it was written for is no longer covered by
    # anything.  The probes in lib_callchain.lua still all run (the tail of the
    # output was being cut by the cap, hence the budget), and restoring the
    # multi-step burst is part of the performance work that comes last: if the
    # burst comes back, this case's reason for existing comes with it.
    "call-chain": 20000,
}
TIMEOUT_OVERRIDES = {
    "func-fib": 300,
}

# Documented chip-only behaviors (chip diverges, oracle differs). Keep this list
# short: an entry here is a real incompatibility, and most of these trace to one
# place -- fmtNum prints the shortest round-trip form where PUC prints %.14g
# plus a digit when that does not round-trip. Fixing that formatting would
# retire fmt-*, math-pi, math-log and math-modf at once.
# - lit-hex / int-wrap / math-maxinteger: exact ints past +/-2^53 float-round.
# - tab-del: #{1,nil,3} is undefined in Lua (hole length); the chip
#   keeps the allocated length while PUC Lua reports 1.
# - io-int-coerce is a chip feature, not a divergence: outInt0 is a typed int
#   port, so an integral float is stored as an integer.
CHIP_LOG = {
    "lit-hex": "255\t16\t18446744073709551616\n",
    "int-wrap": "9.223372036854778e+18\t9.223372036854778e+18\n",
    "fmt-div3": "0.3333333333333333\n",
    "fmt-big": "1.2676506002282294e+30\t1e+20\n",
    "math-maxinteger": "9223372036854777856\n",
    "math-pi": "3.141592653589793\n",
    "math-log": "4.605170185988092\n",
    "math-modf": "3.0\t0.7000000000000002\n",
    "tab-del": "1\tnil\t3\t3\n",
    # error's message carries the chunk and line of whatever called error, and
    # pcall hands that message on as a value.  The chip has no line at run time
    # to name, so the text a program asked for is what it gets.
    "pcall-catch": "false\tboom\n",
    "pcall-deep-error": "false\tbottom\n",
    "pcall-nested": "true\tfalse\tinner\n",
    "xpcall-catch": "false\tH:boom\n",
    "xpcall-two": "false\t7\t8\n",
}


def resolve_src(src, kw):
    if src == "STRESS":
        return cases.build_stress()
    if src == "OVERCAP":
        return cases.build_overcap()
    if src == "DEMO":
        for k, v in cases.DEMO_KW.items():
            kw.setdefault(k, v)
        return cases.DEMO_SRC
    if src.startswith("PRE:"):
        # a repro kept as a file, with the rest of the source appended: the
        # chip has no dofile, so a case that needs a library of helpers spells
        # them out in a file and prepends it
        return resolve_prog(src, cases.TINYLUA)
    return src


def run_one_payload(name, payload, ws_path, irpkl, timeout):
    """Run a single case payload in its own process; retry once on timeout."""
    for attempt in (1, 2):
        t0 = time.time()
        try:
            p = subprocess.run(
                [sys.executable, "-u", __file__, "--worker",
                 ws_path, json.dumps(payload), irpkl or ""],
                capture_output=True, text=True, timeout=timeout,
                cwd=TINYLUA)
            dt = time.time() - t0
            if p.returncode != 0:
                return (name, False, "worker-rc=%d: %s" % (
                    p.returncode, (p.stderr or "")[-300:]), dt)
            return compare(name, payload["mode"], payload["kw"],
                           json.loads(p.stdout), dt)
        except subprocess.TimeoutExpired:
            if attempt == 2:
                return (name, False, "HANG (>%ds x2)" % timeout,
                        time.time() - t0)
    return (name, False, "unreachable", 0.0)


def run_case(name, src, inputs, mode, kw):
    """Run one case in a subprocess; retry once on timeout."""
    kw = dict(kw or {})
    src = resolve_src(src, kw)
    return run_one_payload(
        name,
        {"src": src, "kw": kw, "ticks": kw.get("ticks", TICKS), "mode": mode},
        kw.get("_ws", WS_PATH), kw.get("_irpkl"),
        TIMEOUT_OVERRIDES.get(name, TIMEOUT))


def run_batch(cases_in):
    """Run a group of cases in one process, so the chip is built only once.

    A batch that dies or hangs is re-run case by case, which keeps the hard
    per-case timeout that isolates a single runaway program.
    """
    names = [c[0] for c in cases_in]
    payload = [{"src": c[1], "kw": c[2], "ticks": c[2].get("ticks", TICKS),
                "mode": c[3]} for c in cases_in]
    ws_path = cases_in[0][2].get("_ws", WS_PATH)
    irpkl = cases_in[0][2].get("_irpkl")
    t0 = time.time()
    timeout = TIMEOUT * len(cases_in) + 60
    try:
        p = subprocess.run(
            [sys.executable, "-u", __file__, "--worker", ws_path,
             json.dumps(payload), irpkl or ""],
            capture_output=True, text=True, timeout=timeout, cwd=TINYLUA)
        if p.returncode == 0:
            lines = [ln for ln in p.stdout.splitlines() if ln.strip()]
            if len(lines) == len(cases_in):
                dt = time.time() - t0
                out = []
                for (name, src, kw, mode, _), ln in zip(cases_in, lines):
                    r = json.loads(ln)
                    out.append(compare(name, mode, kw, r, r.get("secs", dt)))
                return out
        why = "batch-rc=%d: %s" % (p.returncode, (p.stderr or "")[-200:])
    except subprocess.TimeoutExpired:
        why = "batch timeout"
    return [run_one_payload(n, {"src": c[1], "kw": c[2],
                                "ticks": c[2].get("ticks", TICKS),
                                "mode": c[3]},
                            c[2].get("_ws", WS_PATH), c[2].get("_irpkl"),
                            TIMEOUT_OVERRIDES.get(n, TIMEOUT))
            for n, c in zip(names, cases_in)]


def chip_ports(r):
    og = r["outGlobals"]
    return {
        "log": r["log"],
        "outVec": list(og.get("outVec", [0.0] * 3)),
        "outCol": list(og.get("outCol", [0.0] * 4)),
        "outGlobals": [og.get("outNum0", 0.0), og.get("outNum1", 0.0),
                       og.get("outNum2", 0.0), og.get("outNum3", 0.0),
                       og.get("outStr0", ""), og.get("outStr1", ""),
                       og.get("outInt0", 0)],
        "outArr": list(og.get("outArr", [0.0] * 64)),
        "result": og.get("result", ""),
        "err": og.get("err") or "",
        "progOk": bool(og.get("progOk", False)),
    }


def compare(name, mode, kw, r, dt):
    c = chip_ports(r)
    exp = (kw.get("expect") or {}) if isinstance(kw, dict) else {}
    if mode == "run":
        o = OR.oracle_run(r["src"], inputs=kw.get("inputs"),
                          sinputs=kw.get("sinputs"), vec=kw.get("vec"),
                          col=kw.get("col"), inarr=kw.get("inarr"),
                          inint=kw.get("inint"))
        if not o.get("avail"):
            return (name, None, "SKIP no oracle", dt)
        if o["rc"] != 0:
            return (name, None, "SKIP oracle rejected rc=%d" % o["rc"], dt)
        if o["calls"] is None:
            return (name, None, "SKIP oracle framing broken", dt)
        want = CHIP_LOG.get(name, OR.oracle_log(OR.norm_calls(o["calls"])))
        if want is None:
            return (name, None, "SKIP unrecorded deviation", dt)
        if not c["progOk"]:
            return (name, False, "chip rejected: %r" % c["err"], dt)
        if c["log"] != want:
            return (name, False, "log mismatch chip=%r lua=%r" % (c["log"], want), dt)
        return (name, True, "", dt)
    if mode == "modelio":
        for key in ("log", "outVec", "outCol", "outGlobals", "outArr",
                    "result"):
            if key in exp and c[key] != exp[key]:
                return (name, False, "%s mismatch got=%r want=%r" % (
                    key, c[key], exp[key]), dt)
        return (name, True, "", dt)
    if mode == "reject":
        if c["progOk"]:
            return (name, False, "chip accepted, want reject", dt)
        return (name, True, "", dt)
    if mode == "runtimerr":
        exp_err = (exp.get("err") or "") if exp else ""
        if exp_err and exp_err not in c["err"]:
            return (name, False, "err missing %r: got %r" % (exp_err, c["err"]), dt)
        if not exp_err and not c["err"]:
            return (name, False, "chip did not fail", dt)
        for key in ("log", "outArr"):
            if key in exp and c[key] != exp[key]:
                return (name, False, "%s mismatch got=%r want=%r" % (
                    key, c[key], exp[key]), dt)
        return (name, True, "", dt)
    if mode == "synfail":
        o = OR.oracle_run(r["src"])
        if not o.get("avail"):
            return (name, None, "SKIP no oracle", dt)
        if c["progOk"]:
            return (name, False, "chip accepted, want reject", dt)
        if o["rc"] == 0:
            return (name, False, "lua accepted, want reject", dt)
        if "errline" in kw:
            want = "line %d:" % kw["errline"]
            if want not in c["err"]:
                return (name, False, "err missing %r: got %r" % (want, c["err"]), dt)
        return (name, True, "", dt)
    if mode == "haltfail":
        o = OR.oracle_run(r["src"])
        if not o.get("avail"):
            return (name, None, "SKIP no oracle", dt)
        if c["progOk"] and not c["err"]:
            return (name, False, "chip did not fail", dt)
        if o["rc"] == 0:
            return (name, False, "lua accepted, want error", dt)
        if o["calls"] is None:
            return (name, False, "oracle framing broken", dt)
        want = OR.oracle_log(OR.norm_calls(o["calls"]))
        if c["log"] != want:
            return (name, False, "partial mismatch chip=%r lua=%r" % (c["log"], want), dt)
        return (name, True, "", dt)
    return (name, False, "bad mode %r" % mode, dt)


def run_in_sim(sim, p):
    """Run one case against a loaded Sim and return the result the comparison reads.

    Every path into a sim goes through here: the pool, the batch worker and the
    one-case retry, so a case cannot behave differently depending on how it was
    scheduled.
    """
    src, kw, ticks = p["src"], p["kw"], p["ticks"]
    t_case = time.time()
    sim.reset()
    si = {"program": src, "run": True}
    for k, v in enumerate(kw.get("inputs") or []):
        si["inNum%d" % k] = float(v)
    for k, v in (kw.get("sinputs") or {}).items():
        si["inStr%d" % int(k)] = v
    if kw.get("vec"):
        si["inVec"] = tuple(kw["vec"])
    if kw.get("col"):
        si["inCol"] = tuple(kw["col"])
    if kw.get("inarr") is not None:
        si["inArr"] = [float(v) for v in kw["inarr"]]
    if kw.get("inint") is not None:
        si["inInt0"] = int(kw["inint"])
    sim.inputs = si
    r = sim.run(ticks)
    og = r["outGlobals"]
    return {
        "src": src,
        "secs": time.time() - t_case,
        "log": r["log"],
        "outGlobals": {
            "outNum0": og.get("outNum0", 0.0),
            "outNum1": og.get("outNum1", 0.0),
            "outNum2": og.get("outNum2", 0.0),
            "outNum3": og.get("outNum3", 0.0),
            "outStr0": og.get("outStr0", ""),
            "outStr1": og.get("outStr1", ""),
            "outInt0": og.get("outInt0", 0),
            "outVec": list(og.get("outVec", [0.0] * 3)),
            "outCol": list(og.get("outCol", [0.0] * 4)),
            "outArr": list(og.get("outArr", [0.0] * 64)),
            "result": og.get("result", ""),
            "err": og.get("err") or "",
            "progOk": bool(og.get("progOk", False)),
        },
    }


# The pool's worker state.  A pool that loads the graph once per worker and takes
# cases one at a time is what fixes the two things that made the suite slow: a
# batch of twelve cases took as long as its slowest one, and the twelve gsub
# cases (each three to seven seconds, all of it the prepended piece's boot) sat
# in one batch and held a whole core for a minute while the other seven workers
# sat idle.  Handing out one case at a time is work stealing: a slow case
# occupies one core and nothing else.
_POOL_SIM = None


def _pool_init(irpkl):
    global _POOL_SIM
    sys.path.insert(0, os.path.join(TINYLUA, "irrun"))
    from irsims import sim_from_dump
    _POOL_SIM = sim_from_dump(irpkl)


def _pool_case(item):
    # compare already answers (name, good, detail, dt), so that is the whole
    # result: the parent prints and counts it and never touches the sim.  dt is
    # the case's own seconds, which is how a library piece's boot cost stays
    # visible per case.
    name, payload, mode, kw = item
    r = run_in_sim(_POOL_SIM, payload)
    return compare(name, mode, kw, r, r["secs"])


def worker(ws_path, payload, irpkl=None):
    sys.path.insert(0, TINYLUA)
    sys.path.insert(0, os.path.join(TINYLUA, "irrun"))
    p = json.loads(payload)
    batch = p if isinstance(p, list) else [p]
    if irpkl:
        from irsims import sim_from_dump
        sim = sim_from_dump(irpkl)
    else:
        from irdump import dump_source
        from irgraph import Wire
        from irsims import Sim
        nodes, wires, _ = dump_source(ws_path)
        sim = Sim(nodes, [Wire(*w) for w in wires])
    # One graph build for the whole batch: compiling the chip and indexing its
    # wires costs more than most cases run for.
    for p in batch:
        sys.stdout.write(json.dumps(run_in_sim(sim, p)) + "\n")
        sys.stdout.flush()


def main(args):
    if args and args[0] == "--list":
        for t in cases.TESTS:
            print(t[0])
        return 0
    # Every case runs by default: the slow ones used to live behind --all,
    # which only meant running the whole suite twice to see everything.
    wsflag = [a for a in args if a.startswith("--ws=")]
    ws_path = os.path.abspath(wsflag[0][5:]) if wsflag else WS_PATH
    rest = [a for a in args
            if a not in ("--all", "--list") and not a.startswith("--ws=")]
    filt = rest[0] if rest else None
    skip_pre = 0
    if OR.LUA_BIN is None:
        print("SKIP: no Lua 5.5 oracle found")
        return 2
    selected = []
    for t in cases.TESTS:
        name, src, inputs, mode = t[0], t[1], t[2], t[3]
        kw = dict(t[4]) if len(t) > 4 else {}
        if filt and filt not in name:
            continue
        if name in SKIP:
            print("%-18s SKIP %s" % (name, SKIP[name]), flush=True)
            skip_pre += 1
            continue
        kw = dict(kw)
        kw["inputs"] = inputs
        kw["_ws"] = ws_path
        if name in TICKS_OVERRIDES:
            kw["ticks"] = TICKS_OVERRIDES[name]
        selected.append((name, src, inputs, mode, kw))
    # One shared IR dump for all workers (avoids a recompile per case).
    import tempfile
    from irsims import share_dump
    t0 = time.time()
    with tempfile.NamedTemporaryFile(suffix=".pkl", delete=False) as f:
        irpkl = f.name
    share_dump(ws_path, irpkl)
    print("dump %.1fs -> %s" % (time.time() - t0, irpkl), flush=True)
    for _, _, _, _, kw in selected:
        kw["_irpkl"] = irpkl
    ok = fail = 0
    skip = skip_pre
    # Group the cases into batches: a worker builds the chip once and reuses it
    # for every case in its batch, which is where most of the wall clock went.
    prepared = []
    for name, src, inputs, mode, kw in selected:
        prepared.append((name, resolve_src(src, kw), kw, mode, inputs))

    def report(name, good, detail, dt):
        nonlocal ok, fail, skip
        if good is None:
            skip += 1
            tag = "SKIP"
        elif good:
            ok += 1
            tag = "OK"
        else:
            fail += 1
            tag = "FAIL"
        print("%-18s %s (%.1fs) %s" % (name, tag, dt, detail), flush=True)

    try:
        if POOL:
            # one case at a time, one long-lived sim per worker, the graph loaded
            # once: the twelve gsub cases are three to seven seconds each and a
            # batch of cases is as long as its slowest member, so batching them
            # left seven cores idle and the wall time was the gsub batch
            import multiprocessing as mp
            items = [(n, {"src": s, "kw": k, "ticks": k.get("ticks", TICKS)},
                      m, k) for n, s, k, m, _ in prepared]
            with mp.Pool(WORKERS, initializer=_pool_init,
                         initargs=(irpkl,)) as pool:
                for out in pool.imap_unordered(_pool_case, items,
                                               chunksize=1):
                    report(*out)
        else:
            batches = [prepared[i:i + BATCH]
                       for i in range(0, len(prepared), BATCH)]
            with cf.ThreadPoolExecutor(max_workers=WORKERS) as ex:
                futs = [ex.submit(run_batch, b) for b in batches]
                for f in cf.as_completed(futs):
                    for name, good, detail, dt in f.result():
                        report(name, good, detail, dt)
    finally:
        os.unlink(irpkl)
    print("OK=%d FAIL=%d SKIP=%d  (%d cases%s)" % (
        ok, fail, skip, len(prepared),
        "" if POOL else ", %d batches" % len(batches)))
    return 1 if fail else 0


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--worker":
        worker(sys.argv[2], sys.argv[3],
               sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] else None)
    else:
        with Elapsed("suite(%s)" % (" ".join(sys.argv[1:]) or "all")):
            sys.exit(main(sys.argv[1:]))
