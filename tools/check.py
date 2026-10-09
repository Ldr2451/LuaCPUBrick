"""Fast chip probe: build the chip once, run every program given on the command
line, and show the chip result next to the Lua 5.5 oracle when it differs.

  python -u tools/check.py "print(1)" "local t = {1,2} print(#t)"

An argument of @path reads the programs from that file instead, one per
paragraph with a line of %% between them.  A shell that eats the double quotes
out of an argument turns `print("x")` into `print(x)`, which looks like a chip
bug and is not one; the file form cannot be mangled that way.

Each argument is one program.  This is the narrow probe to use while iterating;
run the full suite once at the end of a change.  ~10s to compile the chip, then
roughly a second per program -- and with four or more programs they run in
parallel (CHECK_WORKERS, default 12), because a file of thirty gsub shapes is
the common case and one core makes it thirty seconds of waiting.  The compile is
shared: the parent dumps it once and every worker loads that dump.
"""
import concurrent.futures as cf
import json
import os
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, 'irrun'))
sys.path.insert(0, os.path.join(ROOT, 'tests'))
from irsims import ChipRunner, share_dump, sim_from_dump
from irdump import resolve_prog
from timing import Elapsed
import lua_oracle as OR

# A probe's job is to show what happens first, and the budget is how long a stuck
# program takes to admit it: an unpatched jump or a for-in whose iterator keeps
# answering runs every tick of it, all of it waiting.  1200 ticks is about two
# seconds and covers every program that *finishes*; PROBE_TICKS raises it for one
# that is merely slow.  A program that hits the cap says CAP, because a truncated
# run that reads like a finished one is how a probe lies -- and there is no
# smarter way to tell the two apart in advance (a "stuck detector" built from the
# log, the table counts and the frame depth got the stuck case right and fib
# wrong, which is the one failure mode that matters).
TICKS = int(os.environ.get("PROBE_TICKS", "1200"))
WORKERS = int(os.environ.get("CHECK_WORKERS", "12"))
WS_PATH = os.path.join(ROOT, 'lua.ws')

_RUNNER = None


def describe(runner, src, ticks, sin):
    """Run one program and format the chip's line and the oracle's, as text.

    Text and not a verdict: the point of a probe is to see both, so this is what
    a worker sends back and the parent only prints it.
    """
    t0 = time.time()
    r = runner.run(src, ticks, {"inStr0": sin[0]} if sin else None)
    dt = time.time() - t0
    og = r.get('outGlobals', {})
    got = r.get('log', '')
    err = og.get('runErrors', '')
    capped = not err and not runner.sim.finished
    want = None
    oerr = ''
    if OR.LUA_BIN is not None:
        try:
            o = OR.oracle_run(src, sinputs=sin)
            want = OR.oracle_log(o['calls']) if o.get('calls') is not None \
                else '<oracle: %s>' % o.get('stderr')
            oerr = (o.get('stderr') or '').strip()
        except Exception as e:
            want = '<oracle failed: %s>' % e
    mark = '    '
    if want is not None:
        if err:
            # an error case: the contract is the message, not the log, and the
            # oracle's stderr carries a "lua: " prefix and a stack trace
            mark = 'OK  ' if err in oerr else 'DIFF'
        else:
            mark = 'OK  ' if got == want else 'DIFF'
    one = " ".join(src.split())
    if capped:
        # the budget ran out, so whatever the log says is a prefix: say so
        # rather than let a truncated run read like a finished one
        mark = 'CAP  '
    lines = ['%s %5.1fs chip=%r runErrors=%r :: %s' % (mark, dt, got, err, one[:90])]
    if capped:
        lines.append('     hit the %d-tick cap; PROBE_TICKS= to raise it' % ticks)
    if want is not None and got != want:
        lines.append('     lua=%r' % (want,))
    if oerr and (err or (want is not None and got != want)):
        lines.append('     lua stderr=%r' % (oerr[:200],))
    return lines


def _worker(payload):
    global _RUNNER
    if _RUNNER is None:
        _RUNNER = ChipRunner(sim=sim_from_dump(payload["dump"]))
    out = []
    for src in payload["progs"]:
        out += describe(_RUNNER, src, payload["ticks"], payload["sin"])
    return out


def main(argv):
    if argv and argv[0] == "--worker":
        for line in _worker(json.loads(argv[1])):
            print(line, flush=True)
        return 0
    progs = []
    for a in argv:
        if a.startswith("@"):
            with open(a[1:], encoding="utf-8") as f:
                for part in f.read().split("\n%%\n"):
                    if part.strip():
                        progs.append(part)
        else:
            progs.append(resolve_prog(a, ROOT))
    progs = progs or ["function f() return 1,2 end local a, b = f() print(a, b)"]
    # STDIN feeds inStr0, which is where the chip reads standard input from, so
    # a probe of io.read can set it without writing a case
    sin = {0: os.environ["STDIN"]} if "STDIN" in os.environ else None
    with Elapsed("check(%d programs)" % len(progs)):
        if len(progs) < 4 or WORKERS < 2:
            # one program (or three) is faster in one process than a pool
            t_build = time.time()
            runner = ChipRunner(WS_PATH)
            print("build %.1fs" % (time.time() - t_build), flush=True)
            for src in progs:
                for line in describe(runner, src, TICKS, sin):
                    print(line, flush=True)
            return 0
        # Four or more: compile once into a dump, then the programs in as many
        # chunks as there are workers.  A worker pays the load of the dump and
        # the build of a Sim before its first program, which is a second and a
        # half, so one program per worker spends most of the time loading; a
        # chunk of three or four amortises it and still finishes in one wave.
        t0 = time.time()
        fd, dump = tempfile.mkstemp(suffix=".pkl")
        os.close(fd)
        try:
            share_dump(WS_PATH, dump)
            print("dump %.1fs" % (time.time() - t0), flush=True)
            nchunk = min(WORKERS, len(progs))
            size = (len(progs) + nchunk - 1) // nchunk
            jobs = [{"dump": dump, "ticks": TICKS, "sin": sin,
                     "progs": progs[i:i + size]}
                    for i in range(0, len(progs), size)]
            results = []
            with cf.ThreadPoolExecutor(max_workers=len(jobs)) as ex:
                for lines in ex.map(_run_worker, jobs):
                    results += lines
            for line in results:
                print(line, flush=True)
        finally:
            os.unlink(dump)
    return 0


def _run_worker(job):
    p = subprocess.run(
        [sys.executable, "-u", os.path.abspath(__file__), "--worker",
         json.dumps(job)], capture_output=True, text=True, cwd=ROOT,
        timeout=300)
    if p.returncode != 0:
        return ['FAIL  worker rc=%d: %s' % (p.returncode, p.stderr[-200:])]
    return p.stdout.splitlines()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
