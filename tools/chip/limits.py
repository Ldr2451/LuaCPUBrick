"""Which memory limit does a PLAUSIBLE program hit FIRST, and what fails how?

Every limit in the chip is `resize`d at reset rather than declared with a size,
so raising one costs no nodes -- measured, not assumed: MAX_HEAP 512->1024,
ARR_SLOTS 64->128 and spec.OUTARR 64->128 each left the audit at 30,290,
ARR_SLOTS 64->16384 (both array ports, with the outstrarr arm already
in) left it unchanged, and MAX_HEAP 4096->65536 left it at 58,094: the
size is memory, not graph.  What a wide array port costs is wire width
in game: an @right out port carries its whole array every tick.

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
sys.path.insert(0, os.path.join(ROOT, "tests"))
from irsims import ChipRunner  # noqa: E402
import spec  # noqa: E402

CAP = 40000

# A probe may carry its own tick cap as a fourth element.  Only the
# table-entries row needs one: a full arena fill is ~6 ticks an entry and
# table work is gate-heavy, so at 64k that row is a ~30-minute slow lane all
# by itself.  It stays in the sweep because a ceiling probe that cannot reach
# its ceiling proves nothing -- but run limits.py expecting it.
HEAP_CAP = 450000

# Every probe point is derived from spec, and the "over" side is always past the
# ceiling.  Both halves used to be literals, which made this tool quietly stop
# probing anything the moment a limit was raised: it kept reporting the old
# ceiling in its own label and its 600th entry now succeeds, so the row reads as
# a pass when it is measuring a program well inside the arena.
PROBES = [
    ("table entries (MAX_HEAP %d; slow: full fill)" % spec.MAX_HEAP,
     "local t = {} for i = 1, %d do t[i] = i end print(#t)",
     (spec.MAX_HEAP - 12, spec.MAX_HEAP + 88),
     HEAP_CAP),
    ("call depth (MAX_CALLS %d)" % spec.MAX_CALLS,
     "local function d(n) if n == 0 then return 0 end "
     "return 1 + d(n - 1) end print(d(%d))",
     (spec.MAX_CALLS - 4, spec.MAX_CALLS + 40)),
    ("upvalues/function (MAX_UP)",
     "local function f() %s local g = function() return u0 end return g() end "
     "print(f())", (8, 20)),
    ("values per call (MAXVALS %d)" % spec.MAXVALS,
     "local function g() return %s end print(g())",
     (spec.MAXVALS - 1, spec.MAXVALS + 4)),
    ("registers/function (MAX_REGS %d)" % spec.MAX_REGS,
     "local function f() %s return r0 end print(f())",
     (spec.MAX_REGS - 4, spec.MAX_REGS + 6)),
    ("tables (MAX_TABLES %d)" % spec.MAX_TABLES,
     "local t = {} for i = 1, %d do t[i] = {} end print(#t)",
     (spec.MAX_TABLES - 4, spec.MAX_TABLES + 12)),
    ("outNumArr/outStrArr slots (ARR_SLOTS %d)" % spec.OUTARR,
     "for i = 1, %d do outnumarr(i, i) outstrarr(i, 'w') end print('wrote')",
     (spec.OUTARR - 4, spec.OUTARR + 36)),
]


def run(runner, src, cap):
    """Return (log, message, reported) -- `reported` is False only if the
    program neither printed nor said anything on either channel."""
    out = runner.run(src, cap)
    g = out["outGlobals"]
    log = (g.get("log") or "").strip()
    msg = (g.get("runErrors") or "").strip()
    if not msg:
        # a parse error is the last "err: line N: ..." line of progDebug
        for line in (g.get("progDebug") or "").split("\n"):
            if line.startswith("err:"):
                msg = line.strip()
    return log, msg, bool(log or msg)


def main():
    runner = ChipRunner(os.path.join(ROOT, "lua.ws"))
    for entry in PROBES:
        label, tmpl, (under, over) = entry[0], entry[1], entry[2]
        cap = entry[3] if len(entry) > 3 else CAP
        if "local u%d" in tmpl or "local r%d" in tmpl:
            pre = "local u" if "u0" in tmpl else "local r"
            body = lambda n: " ".join("%s%d = %d" % (pre, i, i) for i in range(n))
        elif "return %s" in tmpl:
            body = lambda n: ", ".join(str(i) for i in range(n))
        else:
            body = lambda n: n
        under_src = tmpl % body(under)
        over_src = tmpl % body(over)
        ulog, uerr, _ = run(runner, under_src, cap)
        olog, oerr, reported = run(runner, over_src, cap)
        verdict = "" if reported else "SILENT"
        print("%-31s %4d %-14s | %4d %-34s %s"
              % (label, under, (ulog or uerr)[:14],
                 over, (olog or oerr)[:34], verdict))
    return 0


if __name__ == "__main__":
    sys.exit(main())