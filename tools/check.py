"""Fast chip probe: build the chip once, run every program given on the command
line, and show the chip result next to the Lua 5.5 oracle when it differs.

  python -u tools/check.py "print(1)" "local t = {1,2} print(#t)"

Each argument is one program.  This is the narrow probe to use while iterating;
run the full suite once at the end of a change.  ~6s to build the chip, then
roughly a second per program.
"""
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, 'irrun'))
sys.path.insert(0, os.path.join(ROOT, 'tests'))
from irsims import ChipRunner
from timing import Elapsed
import lua_oracle as OR

progs = sys.argv[1:] or [
    "function f() return 1,2 end local a, b = f() print(a, b)"]
ticks = int(os.environ.get("PROBE_TICKS", "6000"))

with Elapsed("check(%d programs)" % len(progs)):
    t_build = time.time()
    runner = ChipRunner(os.path.join(ROOT, 'lua.ws'))
    print("build %.1fs" % (time.time() - t_build), flush=True)
    for src in progs:
        t0 = time.time()
        r = runner.run(src, ticks)
        dt = time.time() - t0
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
        mark = '    '
        if want is not None:
            if err:
                # an error case: the contract is the message, not the log, and the
                # oracle's stderr carries a "lua: " prefix and a stack trace
                oerr = (o.get('stderr') or '').strip()
                mark = 'OK  ' if err in oerr else 'DIFF'
                if mark == 'DIFF':
                    print('     lua stderr=%r' % (oerr[:200],), flush=True)
            else:
                mark = 'OK  ' if got == want else 'DIFF'
        print('%s %5.1fs chip=%r err=%r :: %s' % (mark, dt, got, err, src),
              flush=True)
        if want is not None and got != want:
            print('     lua=%r' % (want,), flush=True)
        oerr = (o.get('stderr') or '').strip() if want is not None else ''
        if oerr and (err or (want is not None and got != want)):
            print('     lua stderr=%r' % (oerr[:200],), flush=True)
