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
    "pcall": "local s = 0 for i = 1, 20 do "
             "local ok, v = pcall(function() s = s + i return s end) end "
             "print(s)",
    "string": "local s = 'abcdef' for i = 1, 10 do "
              "s = s:upper():sub(2, -2) end print(s, s:byte(1, -1))",
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
    if not og.get("progOk", False) or og.get("err"):
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
