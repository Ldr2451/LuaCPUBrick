import argparse
import os
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "irrun"))
sys.path.insert(0, os.path.join(ROOT, "tests"))

from irsims import ChipRunner, _extract
from spec import OP_NAMES
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


def labels_by_id(sim):
    result = {}
    for nid, node in sim.nodes.items():
        label = _extract(node.props.get("_label", ("raw", "")))
        if isinstance(label, str):
            result[label] = nid
    return result


def measure(runner, src, ticks):
    sim = runner.sim
    sim.reset()
    labels = labels_by_id(sim)
    prog_ok = labels.get("progOkV")
    vm_pc = labels.get("vmPc")
    bop_id = labels.get("bop")
    compiled = [None]
    gate_fires = [0]
    op_counts = [0] * len(OP_NAMES)
    pending_op = [None]
    original_exec = sim._exec_node

    def counted_exec(nid, node, next_queue):
        gate_fires[0] += 1
        return original_exec(nid, node, next_queue)

    def on_tick(sim_now, tick):
        if not sim_now.vars.get(prog_ok):
            return
        if compiled[0] is None:
            compiled[0] = tick + 1
        if pending_op[0] is not None:
            op_counts[pending_op[0]] += 1
        bop = sim_now.arrays.get(bop_id, [])
        pc = int(sim_now.vars.get(vm_pc, 0))
        pending_op[0] = None
        if 0 <= pc < len(bop):
            op = int(bop[pc])
            if 0 <= op < len(op_counts):
                pending_op[0] = op

    sim.inputs = {"program": src, "run": True}
    sim._exec_node = counted_exec
    start = time.perf_counter()
    result = sim.run(ticks, on_tick=on_tick)
    wall = time.perf_counter() - start
    sim._exec_node = original_exec
    og = result.get("outGlobals", {})
    if not sim.finished:
        raise RuntimeError("CAP at %d: %s" % (sim.tick, og.get("err", "")))
    if any(l.startswith("err:") for l in (og.get("progDebug") or "").splitlines()) or og.get("err"):
        raise RuntimeError("chip failed: %s" % og.get("err", ""))
    used_ticks = sim.tick + 1
    bop = sim.arrays.get(labels.get("bop"), [])
    return {
        "wall": wall,
        "ticks": used_ticks,
        "compile_ticks": compiled[0] or used_ticks,
        "gates": gate_fires[0],
        "source_chars": len(src),
        "bytecode": sum(1 for op in bop if op),
        "op_counts": op_counts,
        "log": result.get("log", ""),
    }


def baseline_source(rev):
    proc = subprocess.run(
        ["git", "cat-file", "blob", "%s:lua.ws" % rev],
        cwd=ROOT, capture_output=True, check=True)
    fd, path = tempfile.mkstemp(suffix=".ws")
    with os.fdopen(fd, "wb") as f:
        f.write(proc.stdout)
    return path


def top_opcodes(counts, limit=5):
    ranked = sorted(enumerate(counts), key=lambda item: (-item[1], item[0]))
    return [(OP_NAMES[op], count) for op, count in ranked[:limit] if count]


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
        runners = {
            "baseline": ChipRunner(baseline_path),
            "current": ChipRunner(os.path.join(ROOT, "lua.ws")),
        }
        for runner in runners.values():
            for _, src in selected:
                measure(runner, src, args.ticks)
        print("baseline=%s  repeat=%d  ticks=%d" % (
            args.baseline, args.repeat, args.ticks))
        print("nodes: baseline=%d current=%d  wires: baseline=%d current=%d" % (
            len(runners["baseline"].sim.nodes),
            len(runners["current"].sim.nodes),
            len(runners["baseline"].sim.wires),
            len(runners["current"].sim.wires)))
        print("%-10s %11s %13s %13s %7s" % (
            "program", "ticks b/c", "compile b/c", "bytecode b/c", "source"))
        for name, src in selected:
            results = {}
            for repeat in range(args.repeat):
                order = ("baseline", "current") if repeat % 2 == 0 else (
                    "current", "baseline")
                for which in order:
                    result = measure(runners[which], src, args.ticks)
                    previous = results.get(which)
                    if previous is None or result["wall"] < previous["wall"]:
                        results[which] = result
            before = results["baseline"]
            current = results["current"]
            if before["log"] != current["log"]:
                raise RuntimeError("%s output differs" % name)
            ratio = current["wall"] / before["wall"]
            print("%-10s %11s %13s %13s %7d" % (
                name,
                "%d/%d" % (before["ticks"], current["ticks"]),
                "%d/%d" % (before["compile_ticks"], current["compile_ticks"]),
                "%d/%d" % (before["bytecode"], current["bytecode"]),
                before["source_chars"]))
            print("           gates %d/%d (%.1f/%.1f per tick) "
                  "wall %.1f/%.1f ms x%.3f" % (
                      before["gates"], current["gates"],
                      before["gates"] / before["ticks"],
                      current["gates"] / current["ticks"],
                      before["wall"] * 1000, current["wall"] * 1000, ratio))
            before_ops = dict(top_opcodes(before["op_counts"]))
            current_ops = dict(top_opcodes(current["op_counts"]))
            names = [name for name, _ in top_opcodes(before["op_counts"])]
            names += [name for name, _ in top_opcodes(current["op_counts"])
                      if name not in names]
            print("           vm ops " + " ".join(
                "%s=%d/%d" % (name, before_ops.get(name, 0),
                              current_ops.get(name, 0)) for name in names))
    finally:
        os.unlink(baseline_path)
    return 0


if __name__ == "__main__":
    with Elapsed("perfbench"):
        sys.exit(main())
