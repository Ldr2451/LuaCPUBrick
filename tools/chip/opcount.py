"""Which opcodes actually execute, and which of them miss the fast path.

This is the measurement that prices widening `vmStepFast`, and it is the one
that decides whether instruction-count reductions are worth anything at all.

The reasoning it rests on: `vmBurst` gives a tick four cheap dispatches and one
full one, and a cheap dispatch that finds an opcode it does not handle returns
having done NOTHING.  So a loop body containing ONE opcode outside the fast set
dispatches one instruction per tick instead of five -- a 5x cliff that has
nothing to do with how many instructions the body has.  Two loop bodies of the
same length can differ 5x in throughput purely on opcode membership, which is
why counting instructions is the wrong way to price this.

perfbench's own opcode histogram cannot answer it: on_tick fires once per TICK
and reads one bop[pc], while a tick runs up to five instructions, so it samples
one instruction in five at whatever pc the tick boundary lands on.  It reported
`table` -- a program that is `t[i] = i * i` in a loop -- as having no SETFIELD
and no GETFIELD.

So: instrument a COPY of the chip.  lua.ws itself is never touched, and the copy
reverts vmStepFast to a `mod` first, because a histogram is
`opN[op] = opN[op] + 1` and that is exactly the read-then-write of one shared
array element that a chip body may not do.  A mod and a chip run the same body,
and the tick counts are identical (measured), so the dispatch counts this reads
are the real ones.

  python -u tools/chip/opcount.py                       # the perfbench set
  python -u tools/chip/opcount.py "for i=1,10 do t[i]=i end"
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "irrun"))

PROGRAMS = {
    "hello": "print('hello')",
    "loop-60": "local s = 0 local i = 1 while i <= 60 do s = s + i i = i + 1 "
               "end print(s)",
    "calls": "local function f(n) if n == 0 then return 0 end return f(n - 1) "
             "+ 1 end print(f(20))",
    "table": "local t = {} for i = 1, 20 do t[i] = i * i end local s = 0 for "
             "_, v in pairs(t) do s = s + v end print(s)",
    "closures": "local function counter() local n = 0 return function() n = n "
                "+ 1 return n end end local c = counter() for i = 1, 20 do c() "
                "end print(c())",
    "pcall": "local s = 0 for i = 1, 20 do local ok, v = pcall(function() s = s "
             "+ i return s end) end print(s)",
    "string": "local s = 'abcdef' for i = 1, 10 do s = s:upper():sub(2, -2) end "
              "print(s, s:byte(1, -1))",
}


def names():
    """opcode -> name, from docs/vm-isa.md, which is the one place they are."""
    src = open(os.path.join(ROOT, "docs", "vm-isa.md"), encoding="utf-8").read()
    out = {}
    for num, nm in re.findall(r"^\| (\d+) \| `([A-Z0-9]+)`", src, re.M):
        out[int(num)] = nm
    return out


def fast_set():
    """The opcodes vmStepFast handles, read out of the guard it actually uses."""
    src = open(os.path.join(ROOT, "lua.ws"), encoding="utf-8").read()
    m = re.search(r"if \(\(op <= (\d+) && op != (\d+)\) \|\| "
                  r"op == (\d+) \|\| op == (\d+) \|\| op == (\d+)\)", src)
    if not m:
        raise SystemExit("the fast-path guard is not the shape this reads")
    hi, skip = int(m.group(1)), int(m.group(2))
    out = set(range(0, hi + 1))
    out.discard(skip)
    for g in m.groups()[2:]:
        out.add(int(g))
    return out, skip


def instrument(dest):
    """lua.ws with an opcode histogram, as `dest`."""
    src = open(os.path.join(ROOT, "lua.ws"), encoding="utf-8").read()
    # a chip body may not read-then-write an array element, and a histogram is
    # exactly that, so the fast path goes back to being a mod for this build
    n_mod = src.count("chip vmStepFast(")
    src = src.replace("chip vmStepFast(", "mod vmStepFast(", 1)
    assert "var bop: int[]" in src
    src = src.replace("var bop: int[]", "var opN: int[]\nvar bop: int[]", 1)
    hits = src.count("let op = bop[vmPc]")
    src = src.replace("let op = bop[vmPc]",
                      "let op = bop[vmPc]\n  opN[op] = opN[op] + 1")
    open(dest, "w", encoding="utf-8", newline="").write(src)
    return hits, n_mod


def main(argv):
    progs = dict(PROGRAMS)
    if argv:
        progs = {"given": " ".join(argv)}
    nm = names()
    fast, skip = fast_set()
    tmpdir = tempfile.mkdtemp(prefix="opcount")
    ws = os.path.join(tmpdir, "counted.ws")
    hits, unchipped = instrument(ws)
    print("instrumented %d dispatch sites (vmStepFast reverted to a mod: %d)"
          % (hits, unchipped))
    print("fast path handles %d opcodes; %d is the one it skips in 0..22\n"
          % (len(fast), skip))
    from irsims import ChipRunner
    runner = ChipRunner(ws)
    for name, src in progs.items():
        runner.reset()
        out = runner.run(src)
        counts = {}
        for i, v in enumerate(runner.sim.chip_array("opN")):
            if v:
                counts[i] = int(v)
        total = sum(counts.values())
        slow = {k: v for k, v in counts.items() if k not in fast}
        print("== %s  ticks=%s  dispatches=%d  slow=%d (%.0f%%)"
              % (name, out.get("ticks"), total, sum(slow.values()),
                 100.0 * sum(slow.values()) / max(total, 1)))
        for op in sorted(counts, key=lambda k: -counts[k]):
            print("     %-10s %-3d %5d  %s"
                  % (nm.get(op, "op%d" % op), op, counts[op],
                     "" if op in fast else "SLOW"))
    shutil.rmtree(tmpdir, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))