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
SKIP = {}

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
    # cannot do, so that exact burst timing is no longer covered. The probes in
    # lib_callchain.lua still exercise the call paths, and this case remains a
    # useful deep-chain and cap check.
    "call-chain": 20000,
    "life-proc": 1200,
    "life-prog": 1200,
}
TIMEOUT_OVERRIDES = {
    "func-fib": 300,
}

# Documented chip-only behaviors (chip diverges, oracle differs). Keep this list
# short: an entry here is a real incompatibility. The float-printing entries are
# host-bound: concat exposes only the host's shortest round-trip form and no
# configurable 17-digit formatter; a synchronous in-chip replacement expands at
# every fmtNum call site and does not lower. Exact int64 is the same boundary in
# the value model: registers hold floats, so integers past 2^53 have already lost
# their value before printing. Fixing either needs a host primitive or a parallel
# integer representation, not another formatter patch.
# - lit-hex / int-wrap / math-maxinteger: exact ints past +/-2^53 float-round.
# - tab-del: #{1,nil,3} is undefined in Lua (hole length); the chip
#   keeps the allocated length while PUC Lua reports 1.
# - io-int-coerce is a chip feature, not a divergence: outInt0 is a typed int
#   port, so an integral float is stored as an integer.
CHIP_LOG = {
    "lit-hex": "255\t16\t9223372036854775808\n",
    "fmt-div3": "0.3333333333333333\n",
    "fmt-big": "1.2676506002282294e+30\t1e+20\n",
    "math-maxinteger": "9223372036854775808\n",
    "math-pi": "3.141592653589793\n",
    "math-log": "4.605170185988092\n",
    "math-modf": "3\t0.7000000000000002\n",
    # math.random is a Lua piece with a 32-bit LCG, so its SEQUENCE is the
    # chip's and not PUC's (PUC seeds xoshiro256** on a 64-bit state).  The API,
    # the ranges, the float's interval and randomseed's two return values are
    # PUC's, so only the two pinned sequences are divergences.
    "math-random-seed42": "1\t6\t3\n",
    "math-random-ten": "6,1,8,7,1\n",
    "math-random-interval":
        "false\tbad argument #2 to 'random' (interval is empty)\n",
    # NOT a lost message: the whole 66-character message is in the register (a
    # case prints string.len(m) == 66).  Both sides cap a printed line at 64
    # (oracle_log applies "the same caps the chip enforces"), and PUC's line is
    # one character longer, so the oracle's capped line ends "...integer repre"
    # where the chip's ends "...integer repres".  A one-character disagreement at
    # the width boundary, not the pcall path losing anything.
    "math-random-noint":
        "false\tbad argument #1 to 'random' (number has no integer repres\n",
    # PUC 5.5's string.gmatch answers one value; the chip answers three because
    # its generic for reads the walk's state out of the call.
    "gmatch-arity": "function\t0\tnil\n3\n",
    # A builtin reached as a VALUE through pcall names itself by its short name
    # where PUC names it by its library path.  A named call agrees with PUC.
    "pcall-gate-name": "false\tbad argument #2 to 'format' "
                       "(number expected, got string)\n",
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
    # Structural first, and for every mode: a lost push or pop shows up as
    # plausible output several frames later, so the cases that could see it are
    # the wrong place to look.  The sim checks these itself (see
    # Sim.state_invariants) and this is every case's one chance to read them.
    bad = r.get("invariants") or []
    if bad:
        return (name, False, "state invariant: " + "; ".join(bad), dt)
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
        if "finished" in exp and bool(r.get("finished")) != exp["finished"]:
            return (name, False, "finished got=%r want=%r" % (
                r.get("finished"), exp["finished"]), dt)
        if OR.norm_val(c["log"]) != want:
            return (name, False, "log mismatch chip=%r lua=%r" % (c["log"], want), dt)
        return (name, True, "", dt)
    if mode == "lifecycle":
        life = r.get("lifecycle")
        if not isinstance(life, dict):
            return (name, False, "missing lifecycle result", dt)
        want_finished = exp.get("finished", False)
        want_log = exp.get("log")
        checkpoints = exp.get("checkpoints", [])
        for run_name in ("first", "second"):
            run = life.get(run_name, {})
            if not run.get("progOk"):
                return (name, False, "%s chip rejected: %r" % (
                    run_name, run.get("err")), dt)
            if run.get("err"):
                return (name, False, "%s error: %r" % (
                    run_name, run.get("err")), dt)
            if run.get("finished") != want_finished:
                return (name, False, "%s finished got=%r want=%r" % (
                    run_name, run.get("finished"), want_finished), dt)
            if run.get("tick") != run.get("budget", 0) - 1:
                return (name, False, "%s stopped at tick %r/%r" % (
                    run_name, run.get("tick"), run.get("budget", 0) - 1), dt)
            if want_log is not None and run.get("log") != want_log:
                return (name, False, "%s log got=%r want=%r" % (
                    run_name, run.get("log"), want_log), dt)
            samples = run.get("samples", [])
            sample_ticks = [sample.get("tick") for sample in samples]
            want_ticks = list(checkpoints) + [run.get("budget", 0) - 1]
            if sample_ticks != want_ticks:
                return (name, False, "%s samples got=%r want=%r" % (
                    run_name, sample_ticks, want_ticks), dt)
            values = [sample.get("outNum0", 0.0) for sample in samples]
            if not values or values[0] <= 0.0 or any(
                    left >= right for left, right in zip(values, values[1:])):
                return (name, False, "%s no progress: %r" % (run_name, values), dt)
            if any(sample.get("finished") != want_finished or
                   not sample.get("busy") for sample in samples):
                return (name, False, "%s invalid sample state: %r" % (
                    run_name, samples), dt)
        baseline = life.get("baseline", {})
        reset = life.get("reset", {})
        if baseline.get("tick") != 0 or baseline.get("finished") or \
                baseline.get("log") or baseline.get("deferred"):
            return (name, False, "bad initial reset: %r" % baseline, dt)
        if reset != baseline:
            return (name, False, "dirty reset: got=%r want=%r" % (
                reset, baseline), dt)
        if life["first"] != life["second"]:
            return (name, False, "restart differs", dt)
        return (name, True, "", dt)
    if mode == "lockstep":
        lk = r.get("lockstep") or {}
        if not lk:
            return (name, False, "no lockstep result", dt)
        if lk["ticksA"] != lk["ticksB"]:
            return (name, False, "tick count differs %r vs %r" % (
                lk["ticksA"], lk["ticksB"]), dt)
        if not lk["sameLog"]:
            return (name, False, "output diverged at tick %r: %r vs %r" % (
                lk["firstDiff"], lk["logA"][:60], lk["logB"][:60]), dt)
        if lk["errA"] != lk["errB"]:
            return (name, False, "one chip errored: %r vs %r" % (
                lk["errA"], lk["errB"]), dt)
        if lk["okA"] != lk["okB"]:
            return (name, False, "one chip rejected the program", dt)
        # Nothing else: a program that raises is still one the two must agree
        # about, and whether it was supposed to print anything is the case's own
        # expectation, which the check below reads.
        want = exp.get("log")
        if want is not None and lk["finalA"] != want:
            return (name, False, "log got=%r want=%r" % (
                lk["finalA"], want), dt)
        return (name, True, "", dt)
    if mode == "state":
        if not c["progOk"]:
            return (name, False, "chip rejected: %r" % c["err"], dt)
        want_log = exp.get("log")
        if want_log is not None and c["log"] != want_log:
            return (name, False, "log mismatch got=%r want=%r" % (
                c["log"], want_log), dt)
        for key, value in exp.get("state", {}).items():
            got = r.get("state", {}).get(key)
            if got != value:
                return (name, False, "state %s got=%r want=%r" % (
                    key, got, value), dt)
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


def sim_inputs(src, kw):
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
    return si


def lifecycle_sample(sim_, tick):
    og = sim_.capture()["outGlobals"]
    return {
        "tick": tick,
        "finished": bool(sim_.finished),
        "log": sim_.log,
        "outNum0": float(og.get("outNum0", 0.0)),
        "busy": bool(og.get("busy", False)),
        "err": og.get("err") or "",
        "progOk": bool(og.get("progOk", False)),
    }


def lifecycle_window(sim_, si, ticks, checkpoints):
    sim_.reset()
    sim_.inputs = si
    wanted = set(checkpoints)
    samples = []

    def on_tick(sim_now, tick):
        if tick in wanted:
            samples.append(lifecycle_sample(sim_now, tick))

    sim_.run(ticks, on_tick=on_tick)
    samples.append(lifecycle_sample(sim_, sim_.tick))
    return {"budget": ticks, "samples": samples,
            **samples[-1]}


def lifecycle_reset_state(sim_):
    return {
        "tick": sim_.tick,
        "finished": bool(sim_.finished),
        "log": sim_.log,
        "queued": len(sim_.exec_queue),
        "deferred": len(sim_._deferred),
    }


def run_lifecycle(sim_, p):
    kw = p["kw"]
    si = sim_inputs(p["src"], kw)
    ticks = p["ticks"]
    checkpoints = kw.get("expect", {}).get("checkpoints", [])
    sim_.reset()
    baseline = lifecycle_reset_state(sim_)
    first = lifecycle_window(sim_, si, ticks, checkpoints)
    sim_.reset()
    reset = lifecycle_reset_state(sim_)
    second = lifecycle_window(sim_, si, ticks, checkpoints)
    return baseline, first, reset, second


def run_trace(sim, src, kw, ticks):
    """Run one program on a chip and keep the log after every tick."""
    marks = []
    sim.reset()
    sim.inputs = sim_inputs(src, kw)
    r = sim.run(ticks, on_tick=lambda s, tick: marks.append(s.log))
    return {"log": marks, "ticks": sim.tick, "err": (r["outGlobals"].get("err")
                                                     or ""),
            "progOk": bool(r["outGlobals"].get("progOk", False))}


def run_in_sim(sim, p, sim2=None):
    """Run one case against a loaded Sim and return the result the comparison reads.

    Every path into a sim goes through here: the pool, the batch worker and the
    one-case retry, so a case cannot behave differently depending on how it was
    scheduled.
    """
    src, kw, ticks = p["src"], p["kw"], p["ticks"]
    t_case = time.time()
    lifecycle = None
    lockstep = None
    if p["mode"] == "lifecycle":
        baseline, first, reset, second = run_lifecycle(sim, p)
        lifecycle = {"baseline": baseline, "first": first,
                     "reset": reset, "second": second}
        r = {"log": first["log"], "outGlobals": {
            "outNum0": first["outNum0"], "err": first["err"],
            "progOk": first["progOk"]}}
    elif p["mode"] == "lockstep":
        # Two equal chips, the same program, the same start: the output must be the
        # same AT EVERY TICK, not merely the same at the end, or a program that
        # read a port mid-run could see different bytes on the two copies.  The
        # second chip is a SEPARATE Sim built from the same graph, not a reset of
        # the first: a reset would leave the objects that carry state between runs
        # shared, which is the thing that has to be ruled out.
        other = sim2 if sim2 is not None else sim
        a, b = run_trace(sim, src, kw, ticks), run_trace(other, src, kw, ticks)
        first_diff = next((i for i in range(min(len(a["log"]), len(b["log"])))
                           if a["log"][i] != b["log"][i]), None)
        lockstep = {"ticksA": a["ticks"], "ticksB": b["ticks"],
                    "sameLog": a["log"] == b["log"],
                    "firstDiff": first_diff,
                    "logA": a["log"][first_diff] if first_diff is not None else "",
                    "logB": b["log"][first_diff] if first_diff is not None else "",
                    "finalA": a["log"][-1] if a["log"] else "",
                    "finalB": b["log"][-1] if b["log"] else "",
                    # A program that raises is still a program the two chips must
                    # agree about, so the error is compared rather than refused.
                    "errA": a["err"], "errB": b["err"],
                    "okA": a["progOk"], "okB": b["progOk"]}
        r = {"log": a["log"][-1] if a["log"] else "",
             "outGlobals": {"err": a["err"], "progOk": a["progOk"]}}
    else:
        sim.reset()
        sim.inputs = sim_inputs(src, kw)
        r = sim.run(ticks)
    og = r["outGlobals"]
    state = {}
    if p["mode"] == "state":
        wanted = p["kw"].get("expect", {}).get("state", {})
        for label in wanted:
            state[label] = sim.chip_var(label)
    return {
        "src": src,
        "secs": time.time() - t_case,
        "finished": bool(sim.finished),
        "invariants": sim.state_invariants(
            bool(sim.finished) and not og.get("err")),
        "lifecycle": lifecycle,
        "lockstep": lockstep,
        "state": state,
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
    # A lockstep case needs a SECOND, independent chip built from the same graph,
    # so one is made here rather than per case.
    sim2 = None
    if any(p.get("mode") == "lockstep" for p in batch):
        if irpkl:
            from irsims import sim_from_dump
            sim2 = sim_from_dump(irpkl)
        else:
            from irdump import dump_source
            from irgraph import Wire
            from irsims import Sim
            nodes, wires, _ = dump_source(ws_path)
            sim2 = Sim(nodes, [Wire(*w) for w in wires])
    for p in batch:
        sys.stdout.write(json.dumps(run_in_sim(sim, p, sim2)) + "\n")
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
            items = [(n, {"src": s, "kw": k, "ticks": k.get("ticks", TICKS),
                          "mode": m}, m, k)
                     for n, s, k, m, _ in prepared]
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
