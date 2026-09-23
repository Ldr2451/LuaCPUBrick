import sys, os
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.dirname(HERE), 'irrun'))
from irdump import dump_source
from irsims import Sim, Wire, ChipRunner
from timing import Elapsed
import lua_oracle as OR

CASES = [
    # --- varargs ---
    'function f(...) print(...) end f(1, 2, 3)',
    'function f(...) print(...) end f()',
    'function f(...) print(select("#", ...)) end f(1, 2, 3)',
    'function f(...) local a, b = ... print(a, b) end f(7, 8)',
    'function f(...) return ... end print(f(1, 2, 3))',
    'function f(...) local t = {...} print(#t, t[1], t[3]) end f(4, 5, 6)',
    'function f(a, ...) print(a, ...) end f(1, 2, 3)',
    'function f(a, ...) print(a, select("#", ...)) end f(1, 2, 3)',
    'function f(...) print((...)) end f(9)',
    'function outer() return 1, 2 end function f(...) print(...) end f(outer())',
    'function f(...) for i = 1, select("#", ...) do io_write(tostring((select(i, ...)))) end end f(1,2,3)',
    # --- select ---
    'print(select("#", 1, 2, 3))',
    'print(select(2, "a", "b", "c"))',
    'print(select(-1, "a", "b", "c"))',
    'function f(...) return select("#", ...) end print(f(1,2,3,4,5))',
    'function f(...) return select(2, ...) end print(f("x","y","z"))',
]

_RUNNER = None

def chip(src, ticks=6000):
    global _RUNNER
    if _RUNNER is None:
        _RUNNER = ChipRunner(os.path.join(os.path.dirname(HERE), 'lua.ws'))
    r = _RUNNER.run(src, ticks)
    return r.get('log', ''), r.get('outGlobals', {})

ok = fail = 0
with Elapsed('vararg_check'):
    for src in CASES:
        o = OR.oracle_run(src)
        if not o.get("avail"):
            want = "<oracle unavailable>"
        elif o.get("calls") is None:
            want = f"<oracle: {o.get('stderr')}>"
        else:
            want = OR.oracle_log(o["calls"])
        try:
            got, og = chip(src)
            err = og.get('err', '')
        except Exception as e:
            got, err = f"<sim error: {e}>", ''
        good = got == want
        ok += good
        fail += not good
        print(f"{'OK ' if good else 'FAIL'} chip={got!r} lua={want!r} "
              f"err={err!r} :: {src}", flush=True)
print(f"\nOK={ok} FAIL={fail}")
