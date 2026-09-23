import sys, os
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.dirname(HERE), 'irrun'))
from irdump import dump_source
from irsims import Sim, Wire, ChipRunner
from timing import Elapsed
import lua_oracle as OR

CASES = [
    'function f() return 1, 2 end print(f())',
    'function f() return 1 end print(f())',
    'function f() return 1, 2, 3 end print(f())',
    'function f() return 1, 2 end print(9, f())',
    'function f() return 1, 2 end print(f(), 9)',
    'function f() return 1, 2 end print(9, f(), 8)',
    'function f() return 1, 2 end local a = f() print(a)',
    'function f() return 1, 2 end local a, b = f() print(a, b)',
    'function f() return 1, 2 end a, b = f() print(a, b)',
    'function f() return 1, 2, 3 end local a, b, c = f() print(a, b, c)',
    'function f() return 1, 2 end local a, b, c = f() print(a, b, c)',
    'function f() return 1, 2 end print(type(f()))',
    'function f() return 1, 2 end print(#f())',
    'function f() return 1, 2 end return f()',
    'function f() return 1, 2 end print((f()))',
    'function f() return 1, 2 end print(f(), f())',
    'function f() return end print(f())',
    'function f() return 1, 2 end g = f() print(g)',
    'function f() return 1, 2 end print(f() + 0)',
    'function f() return 1, 2 end local t = {f()} print(t[1], t[2])',
    'function f() return 7, 8 end function g() return f() end print(g())',
    'function f() return 1, 2 end print(select and 1 or 2)',
]

_RUNNER = None

def chip(src, ticks=6000):
    global _RUNNER
    if _RUNNER is None:
        _RUNNER = ChipRunner(os.path.join(os.path.dirname(HERE), 'lua.ws'))
    r = _RUNNER.run(src, ticks)
    return r.get('log', ''), r.get('outGlobals', {})

ok = fail = 0
with Elapsed('multi_check'):
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
