import sys, os
sys.path.insert(0, '.')
sys.path.insert(0, 'irrun')
from irdump import dump_source
from irsims import Sim, Wire, ChipRunner
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
        _RUNNER = ChipRunner(os.path.abspath('lua.ws'))
    r = _RUNNER.run(src, ticks)
    return r.get('log', ''), r.get('outGlobals', {})

ok = fail = 0
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
    status = "OK " if got == want else "FAIL"
    if got == want:
        ok += 1
    else:
        fail += 1
    print(f"{status} chip={got!r} lua={want!r} err={err!r} :: {src}")
print(f"\nOK={ok} FAIL={fail}")
