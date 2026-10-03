"""Which memory limit does a PLAUSIBLE program hit FIRST, and what fails how?

Every limit in the chip is `resize`d at reset rather than declared with a size,
so raising one costs no nodes -- measured, not assumed: MAX_HEAP 512->1024,
ARR_SLOTS 64->128 and spec.OUTARR 64->128 each left the audit at 30,290.

So the question is not what a bigger heap costs.  It is which ceiling a real
program meets first, and -- the part that actually matters -- whether meeting it
raises a Luaerror or dies silently.  A silent ceiling is a bug; a loud one is a
documented limit.

THE TWO CHANNELS.  A ceiling reports on one of two ports and they are not the
same one: a LIMIT hit while compiling is a parse error and lands on `progDebug`
as `err: line N: <msg>`, while a ceiling hit while running (`call depth
exceeded`, `out of table memory`) lands on `err`.  Reading only `err` calls
every compile-time ceiling a silent failure, which is what the first version of
this probe did -- it reported five limits as "silent!" and every one of them
was in fact reporting correctly on the other port.

  python -u tools/chip/limits.py
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "irrun"))
from irsims import ChipRunner  # noqa: E402

CAP = 40000

# (label, program, what PUC answers).  Each is the SMALLEST program that reaches
# the named ceiling: one step past it where the limit is a round number.
PROBES = [
    ("table entries (MAX_HEAP 512)", "local t = {} for i = 1, %d do t[i] = i end "
     "print(#t)", (500, 600)),
    ("call depth (MAX_CALLS 32)", "local function d(n) if n == 0 then return 0 "
     "end return 1 + d(n - 1) end print(d(%d))", (30, 40)),
    ("upvalues/function (MAX_UP 16)",
     "local function f() %s local g = function() return u0 end return g() end "
     "print(f())", (16, 20)),
    ("values per call (MAXVALS 16)",
     "local function g() return %s end print(g())", (16, 20)),
    ("registers/function (MAX_REGS 64)",
     "local function f() %s return r0 end print(f())", (60, 70)),
    ("tables (MAX_TABLES 68)", "local t = {} for i = 1, %d do t[i] = {} end "
     "print(#t)", (60, 80)),
    ("outArr slots", "for i = 1, %d do outarr(i, i) end print('wrote')",
     (60, 100)),
]


def run(runner, src):
    """Return (log, message, reported) -- `reported` is False only if the
    program neither printed nor said anything on either channel."""
    out = runner.run(src, CAP)
    g = out["outGlobals"]
    log = (g.get("log") or "").strip()
    msg = (g.get("err") or "").strip()
    if not msg:
        # a parse error is the last "err: line N: ..." line of progDebug
        for line in (g.get("progDebug") or "").split("\n"):
            if line.startswith("err:"):
                msg = line.strip()
    return log, msg, bool(log or msg)


def main():
    runner = ChipRunner(os.path.join(ROOT, "lua.ws"))
    for label, tmpl, (under, over) in PROBES:
        if "local u%d" in tmpl or "local r%d" in tmpl:
            pre = "local u" if "u0" in tmpl else "local r"
            body = lambda n: " ".join("%s%d = %d" % (pre, i, i) for i in range(n))
        elif "return %s" in tmpl:
            body = lambda n: ", ".join(str(i) for i in range(n))
        else:
            body = lambda n: n
        under_src = tmpl % body(under)
        over_src = tmpl % body(over)
        ulog, uerr, _ = run(runner, under_src)
        olog, oerr, reported = run(runner, over_src)
        verdict = "" if reported else "SILENT"
        print("%-31s %4d %-14s | %4d %-34s %s"
              % (label, under, (ulog or uerr)[:14],
                 over, (olog or oerr)[:34], verdict))
    return 0


if __name__ == "__main__":
    sys.exit(main())