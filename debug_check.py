"""Fast chip probe: build the chip once, run every program given on the command
line, and show the chip result next to the Lua 5.5 oracle when it differs.

  python -u debug_check.py "print(1)" "local t = {1,2} print(#t)"

Each argument is one program.  This is the narrow probe to use while iterating;
run the full suite once at the end of a change.
"""
import os
import sys

sys.path.insert(0, '.')
sys.path.insert(0, 'irrun')
from irsims import ChipRunner
import lua_oracle as OR

progs = sys.argv[1:] or [
    "function f() return 1,2 end local a, b = f() print(a, b)"]
runner = ChipRunner(os.path.abspath('lua.ws'))
ticks = int(os.environ.get("PROBE_TICKS", "6000"))

for src in progs:
    r = runner.run(src, ticks)
    og = r.get('outGlobals', {})
    got = r.get('log', '')
    err = og.get('err', '')
    want = None
    if OR.LUA_BIN is not None:
        try:
            o = OR.oracle_run(src)
            want = OR.oracle_log(o['calls']) if o.get('calls') is not None \
                else '<oracle: %s>' % o.get('stderr')
        except Exception as e:
            want = '<oracle failed: %s>' % e
    mark = '   '
    if want is not None:
        mark = 'OK ' if (got == want and not err) else 'DIFF'
    print('%s chip=%r err=%r :: %s' % (mark, got, err, src))
    if want is not None and got != want:
        print('     lua=%r' % (want,))
