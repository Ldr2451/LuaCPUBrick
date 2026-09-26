"""Throwaway: do two equal chips stay in step, tick by tick?

The chip is a network of gates that re-evaluates when its inputs change, so two
copies given the same program at the same moment ought to produce the same output
at the same tick -- and if they ever do not, a program that reads an input port
mid-run would be one scheduling accident away from a different answer on the
second copy.  That is the property a deterministic simulator has to have before
any diff it produces means anything.
"""
import os
import sys

HERE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(HERE, "irrun"))
from irsims import Sim, Wire
from irdump import dump_source

nodes, wires, _ = dump_source(os.path.join(HERE, "lua.ws"))

PROGRAMS = [
    ("hello", "print('hello')", None),
    ("loop", "local s = 0 for i = 1, 20 do s = s + i end print(s)", None),
    ("calls", "local function f(n) if n == 0 then return 0 end "
              "return f(n - 1) + 1 end print(f(12))", None),
    ("tables", "local t = {} for i = 1, 8 do t[i] = i * 2 end "
               "local s = 0 for _, v in pairs(t) do s = s + v end print(s)",
     None),
    ("closures", "local function c() local n = 0 return function() n = n + 1 "
                 "return n end end local f = c() for i = 1, 10 do f() end "
                 "print(f())", None),
    ("pcall", "local s = 0 for i = 1, 6 do "
              "local ok, v = pcall(function() s = s + i return s end) end "
              "print(s)", None),
    ("string", "print(string.format('%d/%s', 42, string.rep('ab', 3)))", None),
    ("input", "print(inStr0, inNum0, #tostring(inNum1))", ("hi", 2.5, 7.0)),
    ("io", "print(inStr0 .. '!')", ("x", None, None)),
]


def trace(ws_path, src, sin, limit=4000):
    """The log after every tick, so two runs can be compared tick by tick."""
    n, w, _ = dump_source(ws_path)
    sim = Sim(n, [Wire(*x) for x in w])
    if sin:
        sim.inputs = {"inStr0": sin[0], "run": True}
        sim.inputs["inNum1"] = sin[2] if len(sin) > 2 else 0.0
    sim.inputs.update({"program": src, "run": True})
    marks = []
    sim.run(max_ticks=limit, on_tick=lambda sim, tick: marks.append(sim.log))
    return marks, sim


bad = 0
for name, src, sin in PROGRAMS:
    a, sa = trace(os.path.join(HERE, "lua.ws"), src, sin)
    b, sb = trace(os.path.join(HERE, "lua.ws"), src, sin)
    same_log = a == b
    n = min(len(a), len(b))
    first = next((i for i in range(n) if a[i] != b[i]), None)
    same_ticks = sa.tick == sb.tick
    ok = same_log and same_ticks
    bad += 0 if ok else 1
    print("%-10s ticks %4d/%-4d  per-tick log %-5s  final %r"
          % (name, sa.tick, sb.tick, "same" if same_log else "DIFFER",
             sa.log[:28]))
    if first is not None:
        print("           first difference at tick %d: %r vs %r"
              % (first, a[first][:40], b[first][:40]))
print("\n%s" % ("all in step" if not bad else "%d of %d NOT in step"
                % (bad, len(PROGRAMS))))
