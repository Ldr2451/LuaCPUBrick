import argparse
import os
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "tests"))

from simdrv_sim import sim_from_brz, ensure_brz
from timing import Elapsed

PROGRAMS = {
    "hello": "print('hello')",
    "loop-60": "local s = 0 local i = 1 while i <= 60 do "
              "s = s + i i = i + 1 end print(s)",
    "calls": "local function f(n) if n == 0 then return 0 end "
             "return f(n - 1) + 1 end print(f(20))",
    "table": "local t = {} for i = 1, 20 do t[i] = i * i end "
             "local s = 0 for _, v in pairs(t) do s = s + v end print(s)",
    "closures": "local function counter() local n = 0 return function() "
                "n = n + 1 return n end end local c = counter() "
                "for i = 1, 20 do c() end print(c())",
    # pcall is a loud stub on this chip now (catching cost the whole size
    # budget), so the benchmark is the same loop with a direct call: it still
    # prices a closure call per iteration, which is what this program was for.
    "pcall": "local s = 0 for i = 1, 20 do "
             "local v = (function() s = s + i return s end)() end "
             "print(s)",
    "string": "local s = 'abcdef' for i = 1, 10 do "
              "s = s:upper():sub(2, -2) end print(s, s:byte(1, -1))",
    # Field access and concatenation, which nothing above exercises in a loop.
    # `table` does t[i] = i * i, so SETFIELD once per iteration but only 20 of
    # them, and the pairs() half spends its time in CALL.  These two are long on
    # purpose: the other seven are short enough that BOOT is most of their tick
    # count, and a boot-dominated benchmark cannot show a throughput change at
    # all -- which is how a real fast-path win can measure as nothing at all.
    "fields": "local t = {a=0, b=0, c=0, d=0} local s = 0 for i = 1, 200 do "
              "t.a = t.a + i t.b = t.b + t.a t.c = t.c + t.b "
              "t.d = t.d + t.c s = s + t.d end print(s)",
    "concat": "local s = '' for i = 1, 60 do s = s .. 'x' end print(#s)",
    # Calls in a LOOP, and recursion, for the same reason as `fields`: `calls`
    # recurses 20 deep and dispatches 16 instructions in TOTAL, so it is almost
    # all boot and cannot price the CALL arm at all.  CALL is the most frequent
    # opcode in ordinary Lua and it is NOT in the fast set.
    "callloop": "local function f(a, b) return a + b end local s = 0 "
                "for i = 1, 150 do s = f(s, i) end print(s)",
    "recurse": "local function d(n) if n == 0 then return 0 end "
               "return 1 + d(n - 1) end print(d(30))",
    # Exponentiation, because there was no benchmark that used it and that is why
    # the cost of the negative-zero guard on the pow arm was unmeasurable for so
    # long: a wall-clock comparison of two chips read 1.66 -> 2.22ms for a change
    # that was really +7%, because the two runs drifted, and a multiply loop with
    # no pow in it moved 11.7 -> 12.3s across the same pair.  Ticks are
    # deterministic and the two chips are alternated in one process, which is the
    # only comparison this repo trusts.
    #
    # 20 iterations keeps it inside the default tick budget while still putting
    # 20 pows in the measurement, and the exponent is fractional in half of them
    # so the slow pow path is exercised too -- an integer exponent is the case the
    # guard is about, and a fractional one is the case it must not touch.
    "pow": "local s = 0.0 for i = 1, 20 do "
           "s = s + (i % 7) ^ 2 + (i % 5) ^ 0.5 end print(s)",
}


def measure(sim, src, ticks):
    """One benchmark run, read from the engine's own per-tick counters.

    The old harness counted gate fires and decoded the bytecode opcode at the
    pc every tick, both of which were reads of a model that owned the graph.
    The engine keeps its counters (an eval is one certified gate evaluation,
    a step one fired gate) and reads them once per tick here, so `steps` is a
    deterministic gate-cost currency.  The opcode histogram and the bytecode
    length are not readable mid-run through the engine's API -- an array's
    contents are private -- so this tool no longer prints them.
    """
    sim.reset()
    sim.inputs = {"program": src, "run": True}
    start = time.perf_counter()
    r = sim.watch_run(ticks)
    wall = time.perf_counter() - start
    og = r["outGlobals"]
    if not r["finished"]:
        raise RuntimeError("CAP at %d: %s (engine said %s)"
                           % (r["ticks"], og.get("runErrors", ""),
                              r.get("err", "busy never latched")))
    if any(l.startswith("err:") for l in (og.get("progDebug") or "").splitlines()) \
            or og.get("runErrors"):
        raise RuntimeError("chip failed: %s" % og.get("runErrors", ""))
    return {
        "wall": wall,
        "ticks": r["ticks"],
        "evals": r["evals"],
        "steps": r["steps"],
        "source_chars": len(src),
        "log": r["log"],
    }


def baseline_source(rev):
    proc = subprocess.run(
        ["git", "cat-file", "blob", "%s:lua.ws" % rev],
        cwd=ROOT, capture_output=True, check=True)
    fd, path = tempfile.mkstemp(suffix=".ws")
    with os.fdopen(fd, "wb") as f:
        f.write(proc.stdout)
    return path


def census(sim):
    """The artifact's gate and wire counts: the game loads the .brz, so this
    is the size the save carries."""
    c = sim._send({"cmd": "census"})
    if "err" in c:
        return -1, -1
    return c.get("gates", -1), c.get("wires", -1)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", default="HEAD~1")
    parser.add_argument("--filter", default="")
    parser.add_argument("--repeat", type=int, default=2)
    parser.add_argument("--ticks", type=int, default=8000)
    args = parser.parse_args()
    if args.repeat < 1:
        parser.error("--repeat must be positive")
    selected = [(name, src) for name, src in PROGRAMS.items()
                if args.filter in name]
    if not selected:
        parser.error("no benchmark matched %r" % args.filter)
    baseline_path = baseline_source(args.baseline)
    try:
        artifacts = {
            "baseline": ensure_brz(baseline_path),
            "current": ensure_brz(os.path.join(ROOT, "lua.ws")),
        }
        sims = {k: sim_from_brz(v) for k, v in artifacts.items()}
        for sim in sims.values():
            for _, src in selected:
                measure(sim, src, args.ticks)
        print("baseline=%s  repeat=%d  ticks=%d" % (
            args.baseline, args.repeat, args.ticks))
        bg, bw = census(sim_from_brz(artifacts["baseline"]))
        cg, cw = census(sim_from_brz(artifacts["current"]))
        print("gates: baseline=%d current=%d  wires: baseline=%d current=%d"
              % (bg, cg, bw, cw))
        print("%-10s %11s %13s %7s" % (
            "program", "ticks b/c", "steps b/c", "source"))
        for name, src in selected:
            results = {}
            for repeat in range(args.repeat):
                order = ("baseline", "current") if repeat % 2 == 0 else (
                    "current", "baseline")
                for which in order:
                    result = measure(sims[which], src, args.ticks)
                    previous = results.get(which)
                    if previous is None or result["wall"] < previous["wall"]:
                        results[which] = result
            before = results["baseline"]
            current = results["current"]
            if before["log"] != current["log"]:
                raise RuntimeError("%s output differs" % name)
            ratio = current["wall"] / before["wall"]
            print("%-10s %11s %13s %7d" % (
                name,
                "%d/%d" % (before["ticks"], current["ticks"]),
                "%d/%d" % (before["steps"], current["steps"]),
                before["source_chars"]))
            print("           evals %d/%d (%.1f/%.1f per tick) "
                  "wall %.1f/%.1f ms x%.3f" % (
                      before["evals"], current["evals"],
                      before["evals"] / before["ticks"],
                      current["evals"] / current["ticks"],
                      before["wall"] * 1000, current["wall"] * 1000, ratio))
    finally:
        os.unlink(baseline_path)
    return 0


if __name__ == "__main__":
    with Elapsed("perfbench"):
        sys.exit(main())
