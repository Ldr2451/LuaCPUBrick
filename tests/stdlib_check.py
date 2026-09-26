import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "irrun"))

import lua_oracle as OR
from irsims import ChipRunner
from timing import Elapsed

CASES = [
    ("library-tables",
     "print(type(math), type(string), type(table), type(io))",
     {}, 8000),
    ("base",
     "local f = {assert, error, ipairs, next, pairs, pcall, print, "
     "select, tostring, type, xpcall} local ok = true "
     "for i = 1, #f do ok = ok and type(f[i]) == 'function' end "
     "print(ok) print(select('#', 'a', 'b'), select(2, 'a', 'b', 'c')) "
     "print(select('#', pairs({})))",
     {}, 8000),
    ("string-index",
     "local s = 'abcdef' print(s:len(), s:sub(2, -2), s:sub(0, 2), "
     "s:sub(9, 12)) print(s:byte(1), s:byte(-1), "
     "select('#', s:byte(1, -1))) print(s:upper(), s:lower(), "
     "('ab'):rep(3, '-'), ('abc'):reverse()) "
     "local z = string.char(72, 105, 0, 255) print(#z, z:byte(1, 4))",
     {}, 8000),
    ("math",
     "print(math.floor(3.7), math.ceil(3.2), math.tointeger(4.0), "
     "math.type(4), math.abs(-5), math.sqrt(9)) "
     "print(math.sin(0), math.cos(0), math.tan(0), math.asin(0), "
     "math.acos(1), math.atan(0), math.atan(1, 1) == math.pi / 4) "
     "print(math.exp(0), math.log(1), math.log(8, 2) == 1, "
     "math.max(1, 5, 3), math.min(1, 5, 3), math.fmod(7, 3) == 1) "
     "local i, f = math.modf(-3.7) print(i, f < 0, i + f == -3.7) "
     "print(math.pi == math.pi, math.huge > math.maxinteger, "
     "math.type(math.maxinteger), math.type(math.mininteger))",
     {}, 8000),
    ("table",
     "local t = {3, 1, 2} table.sort(t) print(t[1], t[2], t[3]) "
     "table.insert(t, 2, 9) print(table.concat(t, ',')) "
     "print(table.remove(t, 2), table.concat(t, ',')) "
     "local p = table.pack('a', nil, 'c') print(p.n, p[1], p[3]) "
     "local u = {table.unpack({4, 5, 6})} print(u[1], u[3]) "
     "local m = table.move({1, 2, 3, 4}, 2, 4, 1) "
     "print(table.concat(m, ','))",
     {}, 8000),
    ("io",
     "local a = io.read() local b = io.read('*l') "
     "local c = io.read('*a') print(a, b, c, #c) "
     "for line in io.lines() do io.write(line, ';') end io.write('\\n')",
     {"sinputs": {"0": "alpha\nbeta\n"}}, 8000),
]


def sim_inputs(src, inputs):
    result = {"program": src, "run": True}
    for key, value in inputs.items():
        if key == "sinputs":
            for slot, text in value.items():
                result["inStr%d" % int(slot)] = text
        else:
            result[key] = value
    return result


def run_case(runner, src, inputs, ticks):
    sim = runner.sim
    sim.reset()
    sim.inputs = sim_inputs(src, inputs)
    sim_start = time.perf_counter()
    result = sim.run(ticks)
    sim_seconds = time.perf_counter() - sim_start
    oracle_start = time.perf_counter()
    oracle = OR.oracle_run(src, **inputs)
    oracle_seconds = time.perf_counter() - oracle_start
    og = result.get("outGlobals", {})
    got = OR.norm_val(result.get("log", ""))
    if not oracle.get("avail"):
        return False, "oracle unavailable", sim_seconds, oracle_seconds
    if oracle.get("rc") != 0 or oracle.get("calls") is None:
        return False, "oracle failed: %s" % oracle.get("stderr"), sim_seconds, oracle_seconds
    want = OR.oracle_log(oracle["calls"])
    if any(l.startswith("err:") for l in (og.get("progDebug") or "").splitlines()):
        return False, "chip rejected: %s" % og.get("err", ""), sim_seconds, oracle_seconds
    if og.get("err"):
        return False, "chip error: %s" % og["err"], sim_seconds, oracle_seconds
    if not sim.finished:
        return False, "CAP at tick %d" % sim.tick, sim_seconds, oracle_seconds
    if got != want:
        return False, "log got=%r want=%r" % (got, want), sim_seconds, oracle_seconds
    return True, "", sim_seconds, oracle_seconds


def main():
    if OR.LUA_BIN is None:
        print("stdlib_check: Lua 5.5 oracle unavailable", flush=True)
        return 2
    version = subprocess.run([OR.LUA_BIN, "-v"], capture_output=True,
                             text=True, timeout=10)
    print((version.stdout + version.stderr).strip(), flush=True)
    runner = ChipRunner(os.path.join(ROOT, "lua.ws"))
    failures = 0
    for name, src, inputs, ticks in CASES:
        good, detail, sim_seconds, oracle_seconds = run_case(
            runner, src, inputs, ticks)
        failures += not good
        print("%-16s %s sim=%.3fs oracle=%.3fs %s" % (
            name, "OK" if good else "FAIL", sim_seconds, oracle_seconds,
            detail), flush=True)
    print("stdlib_check: OK=%d FAIL=%d" % (
        len(CASES) - failures, failures), flush=True)
    return 1 if failures else 0


if __name__ == "__main__":
    with Elapsed("stdlib_check"):
        sys.exit(main())
