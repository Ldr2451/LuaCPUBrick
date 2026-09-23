import sys, os
sys.path.insert(0, '.')
sys.path.insert(0, 'irrun')
from irdump import dump_source
from irsims import Sim, Wire
import lua_oracle as OR

CASES = [
    'local t = {10, 20, x=1} local k, v = next(t) print(k, v)',
    'local t = {} t.a=1 t.b=2 local k, v = next(t) print(k, v)',
    'local t = {1,2,3} local s = 0 for k, v in next, t do s = s + v end print(s)',
    'local t = {1,2,3} print(next(t, 1))',
    'local t = {1,2,3} print(next({}))',
    'local t = {1,2,3} t[2] = nil local k, v = next(t) print(k, v)',
    'local t = {1,2,3} t[2] = nil local k, v = next(t, 1) print(k, v)',
    'local t = {1,2,3} t[2] = nil local k, v = next(t, 3) print(k, v)',
    'local t = {} local a, b, c = pairs(t) print(a, b, c)',
    'local t = {5} local a, b, c = pairs(t) print(a, b, c)',
    'local t = {5} local a, b, c = ipairs(t) print(a, b, c)',
    'local t = {7,8,9} local f, s, ctl = ipairs(t) print(f, s, ctl)',
    'local t = {1,2,3} local n = 0 for k, v in next, t do n = n + 1 end print(n)',
]

def chip(src, ticks=8000):
    nodes, wires, _ = dump_source(os.path.abspath('lua.ws'))
    sim = Sim(nodes, [Wire(*w) for w in wires])
    sim.inputs = {'program': src, 'run': True}
    r = sim.run(max_ticks=ticks)
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
    good = got == want
    ok += good
    fail += not good
    print(f"{'OK ' if good else 'FAIL'} chip={got!r} lua={want!r} err={err!r} :: {src}")
print(f"\nOK={ok} FAIL={fail}")
