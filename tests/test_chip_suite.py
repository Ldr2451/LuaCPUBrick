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
import re
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

# PUC prints an address after a table/function/thread/userdata and the chip
# prints its own, so a log line can carry either spelling and only the type is
# being compared.  oracle_log already folds the reference's side; this folds the
# chip's, on both sides of the comparison, so a case may hold either.  It also
# drops one trailing newline, because oracle_log joins lines and the chip's log
# ends with the last print's own -- a case that took its expectation from the
# reference would otherwise be one character long.  It is applied to the log
# only: the writable-output globals are chip ports with no reference counterpart,
# and a case that spells one out means the value it saw.
_ADDR = re.compile(r"\b(table|function|thread|userdata): 0x[0-9a-fA-F]+")


def norm_log(s):
    if not isinstance(s, str):
        return s
    return _ADDR.sub(r"\1", s).rstrip("\n")

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
# - io-int-coerce is a chip feature, not a divergence: outInt0 is a typed int
#   port, so an integral float is stored as an integer.
#
# A hole length is NOT on this list, and used to be described here: the note said
# `#{1,nil,3}` was a divergence because the chip kept the allocated length while
# PUC reported 1.  There is no CHIP_LOG entry for it and there has not been one
# since the border chase learned to count tombstones -- `tab-del` and
# `len-hole-bridge` compare against the oracle and both agree, and so do
# `#{1,nil,3}`, `#{1,2,nil,4}` and `#{nil,2,3}`.  A comment that outlives the
# entry it explains is worse than no comment: it reads as a live divergence and
# sends the next person looking for a bug that is not there.
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
    # Found by tools/chip/pucsuite.py against lua-5.5.1-tests (sha256 verified).
    # The harvest lifts every self-contained assert(EXPR) out of the suite and
    # compares it with the oracle; these are the ones that do not agree, and they
    # are here so a known divergence reads as a known answer.  The cause is
    # HOST-bound in the first two and chip code in the rest:
    #   tonumber's conversion is `v + 0`, i.e. the host's own string->float, and
    #   that refuses the 0x form that PUC's luaO_str2num accepts.  Making it
    #   accept hex means a host change, the same wall as exact 64-bit integers
    #   and as matching PUC's math.random.
    "puc-hex-tonumber": "nil\n",
    "puc-hex-sign": "nil\n",
    "puc-fpct-a": "nil\n",          # %f, the frontier pattern, is absent
    "puc-fpct-b": "1\t0\n",
    "puc-wstar-anchor": "false\n",  # (%w*)$ should match empty at end
    "puc-format-alt-zero": "+0000000000100\n",
    "puc-tostring-func": "false\n",  # the chip spells a function address its own way
    "math-random-interval":
        "false\tbad argument #1 to 'random' (interval is empty)\n",
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
    # Three math.random messages in one line, and BOTH divergences at once: the
    # piece raises under pcall so the name is the short 'random' where PUC says
    # 'math.random', and PUC's text is three characters longer before the
    # 64-character log cap, so its line is cut earlier ("...interval is" against
    # "...interval is empt").  The argument INDEXES agree -- that is the rule
    # this case is for, and the index is the thing the piece used to get wrong.
    "math-random-argidx":
        "false\tfalse\tfalse\tbad argument #1 to 'random' (interval is empt\n",
    # #t is the first nil minus one, and the cached border now follows a delete
    # AND extends across a bridged gap, so none of these need an entry.  The
    # bridge is the pair: {} t[1]=1 t[3]=3 t[2]=2 is 3 on both sides, and
    # len-hole-bridge2 is the same program with five ticks in between, so the
    # check cannot pass by luck of timing.  What made it fail was tmap.has on a
    # concatenated key, which never fired; tblHas asks tmap.get(...).Found the
    # way the rest of the table code does, and the chase is live again.
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
    if src == "GLOBALSOVER":
        return cases.build_globals_over()
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


def fatal(prog_debug):
    """A rejection is a line that says `err:`, not a non-empty string.

    progDebug also carries `warn: ` lines, and a warned program RUNS, so testing
    emptiness reported a warned program as rejected - which is what made the
    program-arrives-in-pieces cases fail before the port was split by severity.
    """
    return any(l.startswith("err:") for l in (prog_debug or "").splitlines())


# The output ports, in the order the `modelio` expectations read them.  This is
# the ONE place allowed to know port names (docs/lessons.md), and it must not be
# able to answer a default for a port that is not in the graph: that mirror is
# exactly what made four cases read 0.0 for an output the chip was writing
# correctly, after outCol and outInt0 had been deleted days earlier.  A name here
# with no matching port is an error, never a 0.0.
OUT_NUMS = ["outNum0", "outNum1", "outNum2", "outNum3"]
OUT_STRS = ["outStr0", "outStr1"]


def _port(og, name, default):
    if name not in og:
        raise AssertionError("port %r is not in the graph, so the port list in "
                             "chip_ports is stale -- deleting a port has to "
                             "delete its name here too" % name)
    return og[name]


def chip_ports(r):
    og = r["outGlobals"]
    # four numbers then two strings: the numeric outputs are all float now, so
    # there is no separate int to carry and this list has one shape fewer
    return {
        "log": r["log"],
        "outGlobals": [_port(og, n, 0.0) for n in OUT_NUMS]
                      + [_port(og, n, "") for n in OUT_STRS],
        "outArr": list(_port(og, "outArr", None)),
        "result": og.get("result", ""),
        "err": og.get("err") or "",
        "progDebug": og.get("progDebug") or "",
        "progOk": not fatal(og.get("progDebug")),
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
                          col=kw.get("col"), innumarr=kw.get("innumarr"), instrarr=kw.get("instrarr"),
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
            return (name, False, "chip rejected: %r" % c["progDebug"], dt)
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
                    run_name, run.get("progDebug")), dt)
            if run.get("err"):
                return (name, False, "%s error: %r" % (
                    run_name, run.get("err")), dt)
            if run.get("finished") != want_finished:
                return (name, False, "%s finished got=%r want=%r" % (
                    run_name, run.get("finished"), want_finished), dt)
            if not want_finished and run.get("tick") != run.get("budget", 0) - 1:
                return (name, False, "%s stopped at tick %r/%r" % (
                    run_name, run.get("tick"), run.get("budget", 0) - 1), dt)
            if want_log is not None and run.get("log") != want_log:
                return (name, False, "%s log got=%r want=%r" % (
                    run_name, run.get("log"), want_log), dt)
            # the checkpoints are the ticks the case asked about; a case that
            # asked for none has nothing to sample, and the final sample is
            # wherever the run stopped, which is the budget only when the program
            # was still going
            if checkpoints:
                samples = run.get("samples", [])
                sample_ticks = [sample.get("tick") for sample in samples]
                want_ticks = list(checkpoints)
                if not want_finished:
                    want_ticks.append(run.get("budget", 0) - 1)
                # the harness always appends one final sample at wherever the run
                # stopped, so a case that asks about ticks AND lets the program
                # finish legitimately has one more sample than it asked for.  Only
                # the requested ticks are the case's business; the tail is the run's.
                if sample_ticks[:len(want_ticks)] != want_ticks:
                    return (name, False, "%s samples got=%r want=%r" % (
                        run_name, sample_ticks, want_ticks), dt)
            # the progress and per-sample checks describe the shape the two
            # infinite-loop cases have (a counter that only goes up, busy the
            # whole time).  A schedule case asserts the log instead, so it asks
            # for progress: false rather than having those assumptions applied to
            # it; a case with checkpoints means them, as it always did.
            if exp.get("progress", bool(checkpoints)):
                values = [sample.get("outNum0", 0.0) for sample in samples]
                if not values or values[0] <= 0.0 or any(
                        left >= right for left, right in zip(values, values[1:])):
                    return (name, False, "%s no progress: %r" % (run_name, values), dt)
                if any(sample.get("finished") != want_finished or
                       not sample.get("busy") for sample in samples):
                    return (name, False, "%s invalid sample state: %r" % (
                        run_name, samples), dt)
        # `idleBusy` names ticks at which the chip must NOT be busy.  It pins "a
        # stopped chip does nothing": a program edited while `run` is low must not
        # start a parse, so busy stays false until the run edge.
        # `secondRunUnder` bounds the ticks of the run after the LAST rising edge.
        # It is the only assertion that can see a skipped parse, because a re-parse
        # clears the log and so prints identically - the bound is what separates a
        # restart that reuses the loaded program from one that recompiles it.  The
        # first window runs the schedule to its end, so its own edge is the only
        # one measured, and the two windows must agree or the chip is not
        # deterministic.
        cap = exp.get("secondRunUnder")
        if cap:
            got = [life.get(k, {}).get("runTicks") for k in ("first", "second")]
            if any(g is None or g > int(cap) for g in got):
                return (name, False,
                        "restart cost %r ticks, want under %r" % (got, cap), dt)
            # "reliably", not "at least once": a chip that re-parsed on some starts
            # would pass a bound fitted to the best of them, so the two windows
            # must agree exactly.
            if got[0] != got[1]:
                return (name, False, "restart cost varies: %r then %r"
                        % (got[0], got[1]), dt)

        idle = exp.get("idleBusy") or []
        if idle:
            # the FIRST window, because that is the one the checkpoints were given
            # to: reading `run` here would use whatever the loop left behind, which
            # is the second window, and it samples nothing
            by_tick = {s.get("tick"): s
                       for s in life.get("first", {}).get("samples", [])}
            for t in idle:
                smp = by_tick.get(t)
                if smp is None:
                    return (name, False, "first no sample at tick %d" % (
                        run_name, t), dt)
                if smp.get("busy"):
                    return (name, False, "%s busy=%r at idle tick %d, want false"
                            % (run_name, smp.get("busy"), t), dt)
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
        # Two chips agreeing is not an answer, only a repeatability: both are the
        # same source, so a case's hand-written `want` can hold the chip's own
        # wrong answer and stay green.  lockstep-pcall did -- it said 6 where PUC
        # says 21, and only the closure fix made the disagreement visible.  So the
        # oracle is the authority here too, the same as `run`; the two-chip check
        # above is what this mode adds on top of it.
        want = exp.get("log")
        if want is not None and lk["finalA"] != want:
            return (name, False, "log got=%r want=%r" % (
                lk["finalA"], want), dt)
        o = OR.oracle_run(r["src"], inputs=kw.get("inputs"),
                          sinputs=kw.get("sinputs"),
                          innumarr=kw.get("innumarr"),
                          instrarr=kw.get("instrarr"))
        if not o.get("avail"):
            return (name, None, "SKIP no oracle", dt)
        if o["rc"] == 0 and o["calls"] is not None:
            got = OR.norm_val(lk["finalA"])
            if got != OR.oracle_log(OR.norm_calls(o["calls"])):
                return (name, False, "log mismatch chip=%r lua=%r" % (
                    lk["finalA"], OR.oracle_log(OR.norm_calls(o["calls"]))), dt)
        elif lk["errA"]:
            # the program raises on both sides: the contract is the message, and
            # the oracle's carries a "lua: " prefix and a trace
            if OR.LUA_BIN is not None and lk["errA"] not in (o.get("stderr") or ""):
                return (name, False, "err %r not in the oracle's %r" % (
                    lk["errA"], (o.get("stderr") or "")[:120]), dt)
        elif o["rc"] != 0:
            return (name, False, "oracle rejected rc=%d, chip did not" % o["rc"],
                    dt)
        return (name, True, "", dt)
    if mode == "state":
        if not c["progOk"]:
            return (name, False, "chip rejected: %r" % c["progDebug"], dt)
        want_log = exp.get("log")
        if want_log is not None and c["log"] != want_log:
            return (name, False, "log mismatch got=%r want=%r" % (
                c["log"], want_log), dt)
        want_dbg = exp.get("progDebug")
        if want_dbg is not None and want_dbg not in c["progDebug"]:
            return (name, False, "progDebug missing %r: got %r" % (
                want_dbg, c["progDebug"]), dt)
        no_dbg = exp.get("noProgDebug")
        if no_dbg is not None and no_dbg in c["progDebug"]:
            return (name, False, "progDebug should not mention %r: got %r" % (
                no_dbg, c["progDebug"]), dt)
        for key, value in exp.get("state", {}).items():
            got = r.get("state", {}).get(key)
            if got != value:
                return (name, False, "state %s got=%r want=%r" % (
                    key, got, value), dt)
        return (name, True, "", dt)
    if mode == "modelio":
        for key in ("log", "outGlobals", "outArr", "result"):
            got, want_v = c[key], exp.get(key)
            if key in exp and (norm_log(got) if key == "log" else got) != (
                    norm_log(want_v) if key == "log" else want_v):
                return (name, False, "%s mismatch got=%r want=%r" % (
                    key, got, want_v), dt)
        return (name, True, "", dt)
    if mode == "reject":
        if c["progOk"]:
            return (name, False, "chip accepted, want reject", dt)
        # a limit the chip enforces and PUC does not (64 registers against 200)
        # lands here, so the line is worth asserting: the message is how a user
        # finds the declaration that asked for too much.  `errText` is the other
        # half of that -- WHICH limit -- because "rejected" alone says nothing
        # about whether the reason is one a reader can act on.
        if "errline" in kw:
            want = "line %d:" % kw["errline"]
            if want not in c["progDebug"]:
                return (name, False, "progDebug missing %r: got %r" % (
                    want, c["progDebug"]), dt)
        if "errText" in kw and kw["errText"] not in c["progDebug"]:
            return (name, False, "progDebug missing %r: got %r" % (
                kw["errText"], c["progDebug"]), dt)
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
            if want not in c["progDebug"]:
                return (name, False, "progDebug missing %r: got %r" % (
                    want, c["progDebug"]), dt)
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
    if kw.get("innumarr") is not None:
        si["inNumArr"] = [float(v) for v in kw["innumarr"]]
    if kw.get("instrarr") is not None:
        si["inStrArr"] = [str(v) for v in kw["instrarr"]]
    if kw.get("inint") is not None:
        si["inInt0"] = int(kw["inint"])
    return si


def lifecycle_sample(sim_, tick):
    og = sim_.capture()["outGlobals"]
    return {
        "tick": tick,
        "finished": bool(sim_.finished),
        "log": sim_.log,
        # the whole capture, not a hand-picked few: chip_ports compares the
        # output ports for EVERY mode, so a partial dict here would make it
        # report the ports it was not given as missing ones
        "outGlobals": og,
        "outNum0": float(og.get("outNum0", 0.0)),
        "busy": bool(og.get("busy", False)),
        "err": og.get("err") or "",
        "progDebug": og.get("progDebug") or "",
        "progOk": not fatal(og.get("progDebug")),
    }


def lifecycle_window(sim_, si, ticks, checkpoints, phases=None, steps=None):
    sim_.reset()
    sim_.inputs = si
    # A SCHEDULE of run levels, because "the first run edge does nothing" is a
    # claim about the ORDER of the edges and a mode that sets every input once at
    # tick zero cannot see it.  phases is [{"ticks": n, "run": true|false}, ...].
    # The whole schedule is ONE run() call: Sim.finished is a latch that only
    # reset() clears, so a second run() after the program finished returns at
    # once, and a phase boundary has to be crossed INSIDE the run.
    wanted = set(checkpoints)
    samples = []
    edges = []
    live_now = [None]
    program_at = []
    # grid_every: re-fire ReadBrickGrid every N ticks, which is what a host does
    # when it syncs the chip and is the only thing that reaches the chip's
    # `on ReadBrickGrid` handler after the first tick.  That handler asks for a
    # parse, so this is the shape that can start a second parse while the first
    # is still running.
    grid_every = [0]

    def set_live(name):
        live_now[0] = [0.0, name] if name else None

    # `program` is a string PORT, and a string that arrives in pieces is several
    # CHANGES, each of which asks for a parse.  steps is [{"ticks": n, "src":
    # text}, ...]: the first entry is the initial text and each later one is
    # delivered at the end of the phase before it.  The sim delivers a string in
    # one value, so this is the closest analogue of a host that fills the port
    # over time -- and the shape a case could not ask about before the sim
    # re-read its ports.
    # `steps` is a delivery schedule for the program PORT, on its own clock: each
    # entry's src arrives at the end of its own ticks.  It is deliberately NOT
    # tied to phase transitions - the first version did that, so a case with one
    # phase never delivered anything and ran the first fragment forever, which
    # read as a chip that cannot recover.
    prog_edges = []
    if steps:
        at = 0
        for i, st in enumerate(steps):
            at += int(st["ticks"])
            if i:
                prog_edges.append((at, st["src"]))
        si = dict(si, program=steps[0]["src"])

    if phases:
        # a schedule keeps clocking past an error, because that is what a host
        # does and it is the only way to see whether the chip recovers
        sim_.keep_going = True
        # The FIRST phase is the level the run starts at, not an edge.  Every
        # later phase's level arrives at the END of the one before it, so the
        # boundary is the running total BEFORE this phase is added.  Getting
        # either of those wrong produces a schedule that never raises run at all,
        # which is a test that cannot fail the bug it was written for.
        at = 0
        for i, ph in enumerate(phases):
            if i:
                edges.append((at, bool(ph["run"]), ph.get("jitter"), None))
            at += int(ph["ticks"])
        sim_.inputs = dict(si, run=bool(phases[0]["run"]))
        set_live(phases[0].get("jitter"))
    pending_prog = list(prog_edges)
    for ph in (phases or []):
        if ph.get("grid_every"):
            grid_every[0] = int(ph["grid_every"])
    pending = list(edges)

    # The tick the most recent RISING run edge fell on, and the ticks counted while
    # running since.  A case that asks whether a restart is cheap needs the cost of
    # the run that followed the edge, and the log cannot see it: a re-parse calls
    # vmReset, which clears the log, so a recompiled program prints exactly what a
    # skipped parse prints.  Only the ticks tell them apart.
    edge = [-1]
    done = [None]

    def on_tick(sim_now, tick):
        # The tick the run after the last rising edge produced its output on,
        # which is what a case asking about a restart's cost needs.  It cannot be
        # `finished`: that is a latch only reset() clears, so it is still set from
        # the PREVIOUS run and every restart would measure as 1 tick.  The log is
        # cleared by the vmReset on the run edge, so it going from empty to
        # non-empty is exactly the end of this run.
        if edge[0] >= 0 and done[0] is None and sim_now.log:
            done[0] = tick - edge[0] + 1
        while pending and tick + 1 >= pending[0][0]:
            _at, level, jitter, text = pending.pop(0)
            if level:
                # a rising edge starts a new accounting window: the run that
                # follows is the one whose cost the case is asking about
                edge[0] = tick + 1
                done[0] = None
            # A phase edge resets the other inputs to the baseline, but it must
            # NOT rewind `program`.  It used to, because `si` holds the INITIAL
            # program, so every run-level change silently rewound the program port
            # to its first value and the chip dutifully re-parsed the old text.
            # That made "edit the program, then change the run level" impossible to
            # express, which is why no case ever covered that shape - and it
            # produced a convincing false bug report before it was caught.  The
            # live program is carried across unless a step delivers a new one.
            sim_now.inputs = dict(
                si, run=level,
                program=sim_now.inputs.get("program", si.get("program")))
            if text is not None:
                sim_now.inputs = dict(sim_now.inputs, program=text)
            # jitter belongs to the PHASE it is declared on: a case that jitters
            # while stopped and then raises run is asking whether the stopped-time
            # activity broke the next start, and it cannot also be asking the
            # running-time question in the same run
            set_live(jitter)
        while pending_prog and tick + 1 >= pending_prog[0][0]:
            _at, text = pending_prog.pop(0)
            sim_now.inputs = dict(sim_now.inputs, program=text)
        # `jitter` changes one input EVERY tick, which is what an input wired to
        # something live does in game.  The chip restarts the program on a scalar
        # input change while run is high, so this is the shape that can restart
        # forever -- and until the sim re-read its ports, no case could ask.
        live = live_now[0]
        if live is not None:
            live[0] += 1.0
            sim_now.inputs = dict(sim_now.inputs)
            sim_now.inputs[live[1]] = live[0]
        if grid_every[0] and tick % grid_every[0] == 0:
            for nid in sim_now.grid_ids:
                sim_now.exec_queue.add((nid, "RER_Output"))
        if tick in wanted:
            samples.append(lifecycle_sample(sim_now, tick))

    sim_.run(ticks, on_tick=on_tick)
    # SELF-CHECK.  The harness must end holding the LAST program it was told to
    # deliver.  It did not, for a long time: a phase edge restored the initial
    # program, so any schedule that edited the program and then changed the run
    # level silently lost the edit, and the resulting failure looked exactly like
    # a chip bug - a stale program, reported as a real defect, chased for a while.
    # A harness that quietly changes a port it was not asked to change is the
    # dangerous kind, because every symptom it produces is a lie about the chip.
    if steps:
        _want = prog_edges[-1][1] if prog_edges else steps[0]["src"]
        _got = sim_.inputs.get("program")
        if _got != _want:
            raise AssertionError(
                "lifecycle harness lost the program: delivered %r, sim holds %r"
                % (_want, _got))
    # `runTicks` is the cost of the run after the last rising edge: the tick it
    # finished on, from the edge.  It is the only thing in a lifecycle result that
    # can tell a restart which skipped the parse from one which recompiled, because
    # a re-parse clears the log and so prints identically.
    samples.append(lifecycle_sample(sim_, sim_.tick))
    return {"budget": ticks, "samples": samples,
            "edgeTick": edge[0], "runTicks": done[0],
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
    # a schedule of run levels replaces the single run of `ticks` ticks, and the
    # budget is the schedule's total, because the comparator checks that the run
    # used exactly the ticks it asked for
    phases = kw.get("phases")
    if phases:
        ticks = sum(int(ph["ticks"]) for ph in phases)
    else:
        ticks = p["ticks"]
    checkpoints = kw.get("expect", {}).get("checkpoints", [])
    sim_.reset()
    baseline = lifecycle_reset_state(sim_)
    first = lifecycle_window(sim_, si, ticks, checkpoints, phases,
                             kw.get("steps"))
    sim_.reset()
    reset = lifecycle_reset_state(sim_)
    second = lifecycle_window(sim_, si, ticks, checkpoints, phases,
                              kw.get("steps"))
    return baseline, first, reset, second


def run_trace(sim, src, kw, ticks):
    """Run one program on a chip and keep the log after every tick."""
    marks = []
    sim.reset()
    sim.inputs = sim_inputs(src, kw)
    r = sim.run(ticks, on_tick=lambda s, tick: marks.append(s.log))
    pd = r["outGlobals"].get("progDebug") or ""
    return {"log": marks, "ticks": sim.tick, "outGlobals": r["outGlobals"],
            "err": (r["outGlobals"].get("err")
                    or ""),
            "progDebug": pd, "progOk": not fatal(pd)}


def _assert_graph_is_this_chip(sim):
    """A worker must be running the graph THIS lua.ws compiles to.

    Four cases read a deleted output as 0.0 for a whole session while a direct
    probe of the same program read the real value, and the graph the suite was
    running still had outCol and outInt0 - ports removed days earlier - while
    missing one that existed.  A stale graph is a silent wrong answer that looks
    exactly like a chip bug, so the port set a worker actually has is compared
    with the source's, once per process, and the mismatch is said out loud
    instead of being discovered four cases later.
    """
    global _GRAPH_CHECKED
    if _GRAPH_CHECKED:
        return
    _GRAPH_CHECKED = True
    try:
        src = open(WS_PATH, encoding="utf-8").read()
        want = set(re.findall(r"@right\s+out\s+(\w+)\s*:", src))
        got = set()
        for nid, nd in sim.nodes.items():
            if "Internal_MicrochipOutput" in nd.cls:
                lab = nd.props.get("PortLabel", ("raw", ""))
                lab = lab[0] if isinstance(lab, tuple) else lab
                if isinstance(lab, str) and lab:
                    got.add(lab)
        if got != want:
            print("WARNING: this worker is running a DIFFERENT chip: graph has %s,"
                  " source has %s" % (sorted(got - want), sorted(want - got)),
                  file=sys.stderr, flush=True)
    except Exception as e:  # never silent
        print("WARNING: could not check the graph against lua.ws: %r" % (e,),
              file=sys.stderr, flush=True)


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
        r = {"log": first["log"], "outGlobals": first["outGlobals"]}
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
             "outGlobals": a["outGlobals"]}
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
        # The sim's OWN capture, passed through.  This used to be a hand-written
        # dict of ports, and it drifted: it still listed outCol and outInt0 -
        # ports removed days earlier - while missing one that existed, so four
        # cases read 0.0 for an output the chip was writing correctly, while a
        # direct probe of the same program read the right value.  A hand-kept
        # mirror of somebody else's dict is a second source of truth; the shape
        # belongs to chip_ports, which is allowed to know about ports AND refuses
        # to invent a default for a port the graph does not have, and the VALUES
        # come from here.
        "outGlobals": og,
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
        from irdump import dump_source_modules, chip_call_groups
        from irgraph import Wire
        from irsims import Sim
        mods = dump_source_modules(ws_path)
        nodes, wires = {}, []
        for m in mods:
            nodes.update(m["nodes"])
            wires.extend(m["wires"])
        sim = Sim(nodes, [Wire(*w) for w in wires], chip_call_groups(mods))
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
            from irdump import dump_source_modules, chip_call_groups
            from irgraph import Wire
            from irsims import Sim
            mods = dump_source_modules(ws_path)
            nodes, wires = {}, []
            for m in mods:
                nodes.update(m["nodes"])
                wires.extend(m["wires"])
            sim2 = Sim(nodes, [Wire(*w) for w in wires],
                       chip_call_groups(mods))
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
    # A skip that is not in SKIP is a case that was NOT compared, and an
    # uncompared case is not a pass -- the same rule the suite's SKIP dict
    # already encodes, applied to the other place a skip can come from.  The exit
    # code used to look only at `fail`, so a run in which every case skipped
    # reported OK=0 FAIL=0 and exited 0: green, having checked nothing.  That is
    # not hypothetical, it is how tools/fuzz.py hid 30 unparseable programs for
    # long enough to look like a clean sweep -- its oracle rejected them, the
    # harness called it a skip, and the exit code never noticed.  Here the
    # reachable unexplained skips are "oracle rejected rc=N" (a case whose program
    # raises in real Lua, which is a broken case) and "oracle framing broken";
    # "SKIP unrecorded deviation" is unreachable, because oracle_log returns a
    # string for any call list and a None one is caught as framing above.
    uncompared = 0
    # Group the cases into batches: a worker builds the chip once and reuses it
    # for every case in its batch, which is where most of the wall clock went.
    prepared = []
    for name, src, inputs, mode, kw in selected:
        prepared.append((name, resolve_src(src, kw), kw, mode, inputs))

    def report(name, good, detail, dt):
        nonlocal ok, fail, skip, uncompared
        if good is None:
            skip += 1
            uncompared += 1
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
    if uncompared:
        # named, not counted: "3 skipped" reads as a tally and this is the list of
        # cases whose answer nobody has
        print("UNCOMPARED %d: not in SKIP, so their answer is unknown, not agreed"
              % uncompared, flush=True)
    # `or uncompared` is what makes this exit code mean "compared and agreed".
    # Delete it and this run reports success having compared nothing.
    return 1 if fail or uncompared else 0


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--worker":
        worker(sys.argv[2], sys.argv[3],
               sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] else None)
    else:
        with Elapsed("suite(%s)" % (" ".join(sys.argv[1:]) or "all")):
            sys.exit(main(sys.argv[1:]))
