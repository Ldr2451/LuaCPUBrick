"""Run PUC's own test suite against the chip, as far as the chip can take it.

The suite at https://www.lua.org/tests/ cannot be run whole, and the reasons are
worth stating rather than discovering one at a time:

  - the files are up to 40 KB; the chip's source buffer is about 4 KB
  - they need metatables, `require`, `io.stderr`, `os.exit`, `collectgarbage`,
    `load`, coroutines and the C API.  The chip has none of those, and CHIP_LOG
    already records metatables as absent
  - `all.lua` expects to print "final OK" from a real `lua` binary

So this harvests instead of executing: it takes the single-line `assert(EXPR)`
checks whose expression is SELF-CONTAINED -- every bare name in it is a global
the chip has, and every other token is a literal or an operator -- and runs each
one on both the chip and the oracle.  It prints `tostring(EXPR)` rather than
asserting, so a divergence shows up as a different VALUE and not merely as one
side raising.

That is a fraction of 3,287 assertions, and the fraction is the point: the
harvest is a superset of nothing and a subset of the suite, so it finds bugs in
the expressions it can reach and says nothing about the rest.  Every skipped
assertion is counted by reason, so "it passed" is never mistaken for "it ran".

  python -u tools/chip/pucsuite.py --dir <path> [--limit N] [--verbose]
"""
import argparse
import io
import os
import re
import sys
import time
from concurrent.futures import ProcessPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "irrun"))
sys.path.insert(0, os.path.join(ROOT, "tests"))
from irsims import ChipRunner  # noqa: E402
from lua_oracle import norm_val, oracle_log, oracle_run  # noqa: E402

# Bare names an expression may use.  Anything else means it closes over a local
# and cannot be lifted out of its file.  Deliberately excludes rawequal,
# rawget, rawset, setmetatable, getmetatable, coroutine, load, require, io and
# os: the chip has none of them, so an expression using one is not a test the
# chip could pass.  `bit32` IS here because the chip has it as a piece now
# (lib/bit32.lua, transcribed from bitwise.lua's own reference) -- and PUC's
# asserts bind it to that same reference via require, so both sides run the
# same functions.  `utf8` IS here for the same reason (lib/utf8.lua plus
# lib/utf8_char.lua) -- with one gap neither side can fix: PUC's tests spell
# high bytes as `\u{D7FF}`, which the chip's lexer does not decode, so those
# asserts do not parse and skip correctly.
GLOBALS = {
    "assert", "error", "ipairs", "pairs", "next", "select", "tonumber",
    "tostring", "type", "pcall", "xpcall", "print", "unpack", "rawequal",
    "math", "string", "table", "bit32", "utf8", "_VERSION",
}

# Names that appear after a dot or a colon are fields, not bindings.
IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
STRING = re.compile(r"'(\\.|[^'\\])*'|\"(\\.|[^\"\\])*\"")
# Keywords that mean this is not a self-contained expression.  and/or/not are
# OPERATORS, not statements, and the chip runs them -- an earlier version of
# this list banned them too, which threw out 83 harvestable checks including
# the short-circuit suite (`10 or assert(nil)`, `not (nil and assert(nil))`).
# What stays banned needs a statement: function, control flow, locals.
BANNED = re.compile(r"\b(function|local|return|for|while|repeat|until|do|"
                    r"then|else|elseif|end|::|goto|in|if)\b")
# true/false/nil are literals, not bindings: without them `(10 or 2) == 10`
# reads as closing over `nil`... they never did, they READ as values.
LITERALS = {"true", "false", "nil"}
# and/or/not are OPERATORS, so they appear in an expression and bind nothing.
# They are unbanned above, which is what let them reach the identifier scan --
# and there `not` matched IDENT, was in no allow-list, and came out as a
# captured file local.  That was 368 asserts, the largest single bucket in the
# harvest, and every one was this function's bug rather than a test the chip
# could not pass.
OPKEYWORDS = {"and", "or", "not"}
# File locals the runner binds with the same value their file gives them, so
# expressions using them stay self-contained.  math.lua, attrib.lua and
# files.lua all bind maxint to math.maxinteger (and math.lua binds minint to
# math.mininteger); anything bound DIFFERENTLY per file is excluded -- pack is
# table.pack in api.lua and string.pack in tpack.lua, so it stays out.
PRELUDE = {"minint": "math.mininteger", "maxint": "math.maxinteger"}
PRELUDE_SRC = "local " + ", ".join(sorted(PRELUDE)) + " = " + ", ".join(
    PRELUDE[k] for k in sorted(PRELUDE)) + "\n"


def strip_strings(expr):
    """Blank out string literals so identifiers inside them are not read."""
    return STRING.sub(lambda m: '"' + " " * (len(m.group(0)) - 2) + '"', expr)


def self_contained(expr):
    """(ok, reason).  Only single-line expressions of literals and operators."""
    if len(expr) > 400:
        return False, "too long"
    if "..." in expr or "->" in expr or ";" in expr:
        return False, "has vararg/arrow/statement"
    bare = strip_strings(expr)
    if BANNED.search(bare):
        return False, "has keyword"
    for m in IDENT.finditer(bare):
        # skip a field name: preceded by '.' or ':'
        start = m.start()
        if start and bare[start - 1] in ".:'":
            continue
        if m.group(0) not in GLOBALS and m.group(0) not in LITERALS \
                and m.group(0) not in PRELUDE \
                and m.group(0) not in OPKEYWORDS:
            return False, "closes over %r" % m.group(0)
    return True, ""


LOCAL_BIND = re.compile(r"^local\s+([A-Za-z_][\w,\s]*?)\s*=\s*(.+)$")
# A prelude is prepended to the program, and the chip's source buffer is ~4 KB
# INCLUDING whatever library pieces the expression itself pulls in (tonumber
# alone is 762 escaped characters and gsub drags the pattern piece).  So a
# prelude plus an expression over ~1.2 KB cannot be measured at all -- and a
# program that does not fit does not fail, it silently runs something else.
PRELUDE_MAX = 1200


def chip_members():
    """{library: {member}} for what the chip actually loads, read from lua.ws.

    DERIVED, not listed, because a hand-written list drifts the moment a piece
    lands and the drift is invisible: the prelude still parses, it just calls
    nil.  That is not hypothetical -- tpack.lua binds `local pack =
    string.pack`, the chip has no string.pack, and every one of that file's 48
    lifted asserts errored on both engines with nothing to say why.

    The gate bindings (`string.format = _fmt`, `string.gmatch = _gmatch`) are
    members too, so `lib.name =` catches them; a gate with no piece behind it
    would not, and those are named in the comment on GLOBALS above.
    """
    out = {}
    try:
        text = io.open(os.path.join(ROOT, "lua.ws"), encoding="utf-8").read()
    except OSError:
        return out
    # NOT anchored to a line start: the assignments live inside escaped const
    # strings, so `math.sin =` is preceded by a literal backslash-n and `^`
    # under re.M never matched -- which left the set EMPTY and the check
    # vacuously true, i.e. worse than not having it.
    for m in re.finditer(r"(?:string|math|table|io|os|bit32|utf8)\.(\w+)\s*=",
                         text):
        out.setdefault(m.group(0).split(".")[0], set()).add(m.group(1))
    return out


CHIP_MEMBERS = chip_members()
MEMBER_USE = re.compile(r"\b(string|math|table|io|os|bit32|utf8)\.(\w+)")
# The one library call whose cost its own text does not bound: string.rep
# builds as many characters as its argument asks for, so a prelude carrying one
# re-pays that on EVERY lifted assert.  literals.lua binds
# `local var1 = string.rep('a', 15000)`, and 37 characters of prelude cost
# 30,000 of string building per assert -- which is what made the sweep slow and
# then made the asserts skip at the tick cap.  Refused rather than capped: there
# is no character count that stands in for the work.
UNBOUNDED = re.compile(r"\bstring\.rep\b")


def _chip_can_run(expr):
    """No member of a known library that the chip does not have.

    The library NAME being known is not enough: `string.pack` parses on the
    chip and is nil at run time, which is a skip with no message.
    """
    if UNBOUNDED.search(strip_strings(expr)):
        return False
    for lib, member in MEMBER_USE.findall(strip_strings(expr)):
        have = CHIP_MEMBERS.get(lib)
        if have is not None and member not in have:
            return False
    return True


def _strip_comment(s):
    """Drop a trailing -- comment that is not inside a string."""
    out = []
    quote = None
    for i, c in enumerate(s):
        if quote:
            out.append(c)
            if c == quote:
                quote = None
            continue
        if c in "\"'":
            quote = c
            out.append(c)
            continue
        if s[i:i + 2] == '--':
            break
        out.append(c)
    return ''.join(out).strip()


def _balanced(s):
    """Do the brackets in s close? Counted outside strings, and a `--` ends the
    region: PUC's test files put comments after multi-line constructors.

    Long strings count as strings, which is the whole reason this is not a
    bracket counter: literals.lua binds `local a = [[001234567890...]]` over
    three lines, and counting its two `[` as brackets left the initializer
    looking unfinished -- so the name silently fell through to a LATER
    declaration in the same file (`local a = 1`), and every assert using it ran
    against a value PUC never meant.  A wrong binding is worse than no binding:
    it agrees with nothing and disagrees with the file.
    """
    depth = 0
    quote = None
    i = 0
    while i < len(s):
        c = s[i]
        if quote:
            if quote == '[':
                end = s.find(']' * len(quote), i)
                if end < 0:
                    return False
                i = end + len(quote)
                quote = None
                continue
            if c == '\\':
                i += 2
                continue
            if c == quote:
                quote = None
            i += 1
            continue
        if s[i:i + 2] == '--':
            break
        if c in "'\"":
            quote = c
        elif s[i:i + 2] == '[[' or s[i:i + 3] in ('[=[', '[=='):
            close = ']' * (len(s[i:].split('[')[0]) - 1)
            j = s.find(close + ']', i)
            if j < 0:
                return False
            i = j + len(close) + 1
            continue
        elif c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        i += 1
    return depth <= 0 and quote is None


def _top_level_locals(text):
    """[(name, init)] for the file's own UNINDENTED `local` lines.

    Indentation is the test for top level, and PUC's test files declare their
    file-locals in column 0.  A name declared inside a function is a parameter
    or a working local whose value at the assert is not the file's, so those
    are not bindings and must not be faked.

    An initializer may span lines -- nextvar.lua has
    `local sizes = {0, 1, ... 17,` and closes it two lines later, and literals.lua
    has a long string over three -- so the continuation is taken while the
    brackets are open AND the next line is indented.  Both conditions, because
    the first alone would swallow the next top-level statement.

    The FIRST top-level declaration of a name is its binding, and a later one is
    never used as a fallback: literals.lua rebinds `a` from a long string to
    `1`, and taking the second because the first could not be lifted is how a
    prelude ends up asserting against a value the file never meant.
    """
    lines = text.splitlines()
    out = []
    claimed = set()
    i = 0
    while i < len(lines):
        line = lines[i]
        i += 1
        if line[:1] in (' ', '\t'):
            continue
        m = LOCAL_BIND.match(line)
        if not m:
            continue
        names = [x.strip() for x in m.group(1).split(',')]
        if all(n in claimed for n in names if n):
            continue                      # every name already bound
        init = _strip_comment(m.group(2))
        took = 0
        while not _balanced(init) and i < len(lines) and took < 40:
            nxt = lines[i]
            if nxt[:1] not in (' ', '\t'):
                break
            init = init + ' ' + _strip_comment(nxt.strip())
            i += 1
            took += 1
        for name in names:
            if not name or name in claimed:
                continue
            claimed.add(name)            # claimed even if not liftable
            if _balanced(init):
                out.append((name, init))
    return out


def file_prelude(text):
    """(prelude source, bound names) for a file's own top-level locals.

    WHY: the single-letter buckets are the largest unharvested group -- `a`
    alone is 336 asserts spread over 28 files -- and `a` means something
    different in every one of them, so no fixed value can work.  The value each
    file chose CAN, and 345 asserts unblock on it.

    WHAT THIS DOES NOT CLAIM: this runs the EXPRESSION under a substituted
    binding, not PUC's file in its original context.  Both engines get the same
    prelude, so agreement is still a real parity result for the expression --
    but an assert lifted this way proves less than one harvested whole, and a
    lifted assert that ERRORS is counted SKIP, never agreement (the chip's own
    error path already says so).

    A local joins only when its initializer is self-contained, so the result is
    a fixpoint: one round binds what it can, the next round binds what those
    made self-contained.  Round order IS the dependency order, because a name
    only qualifies once everything it mentions is already bound.
    """
    locs = _top_level_locals(text)
    if not locs:
        return "", set()
    known = set(GLOBALS) | LITERALS | OPKEYWORDS | set(PRELUDE)
    rounds = []
    chosen = set()        # bound, and available for another init to depend on
    done = set()          # settled either way, so a rejected one is not retried
    for _ in range(len(locs) + 1):
        added = []
        for name, init in locs:
            if name in done:
                continue
            ok, why = self_contained(init)
            if not ok:
                m = re.match(r"closes over '(\w+)'$", why)
                if not m:
                    done.add(name)
                    continue
                if not (m.group(1) in known or m.group(1) in chosen):
                    continue      # not yet: a later round may bind it
            if not _chip_can_run(init):
                # The initializer would be nil on the chip -- a skip with no
                # message, which is worth no more than not lifting it.  It goes
                # in `done` and NOT in `chosen`, so nothing downstream comes to
                # depend on a name that was never bound.
                done.add(name)
                continue
            added.append((name, init))
            chosen.add(name)
            done.add(name)
        if not added:
            break
        rounds.append(added)
        known |= {n for n, _ in added}
    pairs = [pair for rnd in rounds for pair in rnd]
    if not pairs:
        return "", set()
    src = ''.join("local %s = %s\n" % (n, i) for n, i in pairs)
    if len(src) > PRELUDE_MAX:
        # too big to run with the pieces the expression itself pulls in
        return "", set()
    return src, chosen


# bit32's prelude is the piece's own master, minified but NOT renamed.
# WHY A PRELUDE AT ALL: lua55 has no bit32, so the oracle cannot run a bare
# `bit32.band()` -- it errors with rc=1 and empty calls, which reads as a DIFF
# against whatever the chip answered.  All 25 bit32 asserts looked broken until
# one was run by hand.  Prepending the master to BOTH sides keeps the harvest's
# identical-text invariant: both engines run the same functions, so agreement
# proves the chip's OPERATORS agree with PUC's (the reference is built on them).
# The chip ALSO auto-loads LIB_bit32 (the text mentions `bit32.`), which the
# prelude then overwrites with identical functions -- redundant but harmless,
# and measured to fit: ~1.8KB prelude + 1.7KB piece + expression stays under the
# ~4KB source buffer.  Minified (comments out) but not renamed, because the
# prelude is proof scaffolding rather than shipped code and renaming it would
# only add a way to be wrong.
def _bit32_prelude():
    try:
        sys.path.insert(0, os.path.join(ROOT, "tools", "lib"))
        from libconst import minify, master_to_const
        src = io.open(os.path.join(ROOT, "lib", "bit32.lua"),
                      encoding="utf-8").read()
        return minify(master_to_const(src))
    except (OSError, ImportError):
        return ""

BIT32_PRELUDE = _bit32_prelude()
BIT32_USE = re.compile(r"\bbit32\.")
# The bit32 prelude is BIGGER than PRELUDE_MAX (1,733 chars), and that is fine
# because it was MEASURED to fit: program 2,125 chars + auto-loaded LIB_bit32
# 1,722 = ~3.8KB against the ~4KB source buffer, and it agreed on both engines.
# So this limit is the measurement (prelude + longest bit32 assert + margin),
# not the generic one -- and anything over it is not lifted rather than
# truncated, because a truncated prelude is not Lua at all.
BIT32_MAX = 2200


def harvest(path):
    """(expr, file, lineno, prelude) for every self-contained single-line
    assert, plus the ones a file-local prelude makes self-contained."""
    out = []
    try:
        text = io.open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return out
    pre, bound = file_prelude(text)
    for n, line in enumerate(text.splitlines(), 1):
        s = line.strip()
        if not s.startswith("assert(") or not s.endswith(")"):
            continue
        expr = s[len("assert("):-1].strip()
        if not expr:
            continue
        ok, why = self_contained(expr)
        if ok:
            if BIT32_PRELUDE and BIT32_USE.search(expr) \
                    and len(BIT32_PRELUDE) + len(expr) <= BIT32_MAX:
                # bit32 is a GLOBAL now, so this harvested -- but bare lua55
                # has no bit32 and would error.  Both sides get the piece's own
                # master instead (see BIT32_PRELUDE).
                out.append((expr, os.path.basename(path), n, BIT32_PRELUDE))
            else:
                out.append((expr, os.path.basename(path), n, ""))
            continue
        # blocked only by a name this file binds at top level?
        m = re.match(r"closes over '(\w+)'$", why)
        if pre and m and m.group(1) in bound \
                and len(pre) + len(expr) <= PRELUDE_MAX:
            out.append((expr, os.path.basename(path), n, pre))
    return out


_RUNNER = None


def _init_worker(ws_path):
    """One ChipRunner per process: the build is ~6s, so it happens once here
    and every later run in this worker reuses it."""
    global _RUNNER
    _RUNNER = ChipRunner(ws_path)


def _prelude_probe(item):
    """(idx, ok, note) for one prelude: can the chip RUN it at all?

    Per FILE, not per assert, because the prelude is per file -- and that is
    worth 345 sim runs saved as well as a decision.  A prelude can use anything
    an expression can, so it hits the chip's edges: nextvar.lua's
    `local t = {..., [100.3] = 4, ...}` is a float table key and the chip says
    so, and every one of that file's 64 lifted asserts then failed the same way
    one at a time, at up to 30000 ticks each.

    One probe per distinct prelude answers it once.  The chip must merely not
    error; whether it AGREES is the assert's job, and an assert that errors is
    still SKIP, never agreement.
    """
    idx, pre = item
    prog = '%sprint("PRELUDE_OK")' % pre
    try:
        r = _RUNNER.run(prog, 8000)
        cg = r["outGlobals"]
        err = (cg.get("err") or "").strip()
        log = (cg.get("log") or "").strip()
        if not err and log != "PRELUDE_OK":
            r = _RUNNER.run(prog, 30000)
            cg = r["outGlobals"]
            err = (cg.get("err") or "").strip()
            log = (cg.get("log") or "").strip()
        if err:
            return idx, False, err[:60]
        if log != "PRELUDE_OK":
            return idx, False, "prelude produced no marker"
        return idx, True, ""
    except Exception as e:                            # noqa: BLE001
        return idx, False, repr(e)[:60]


def _chip_run(item):
    """(verdict, note) for one harvested expression, chip AND oracle together.

    The oracle side is milliseconds (one lua55 spawn), so doing it here removes
    the serial comparison tail entirely: the main process only tallies.  An
    exception anywhere is a skip, never agreement and never the end of the
    sweep: a harvested constant can overflow an int output (an `inf` reaching a
    gate that does int()), and one bad program must not take down the rest.
    Results come back out of order (imap_unordered, so a ten-second gsub
    harvest does not hold up three hundred quick ones behind it); the caller
    reattaches each to its expression by the index it carries.
    """
    idx, (expr, _fname, _lineno, fpre) = item
    # minint/maxint ride a prelude with the value their file gives them, and a
    # file-local prelude carries the rest of that file's own bindings.  Both are
    # plain Lua (no <const> attribute -- the chip need not parse one), so the
    # oracle runs the same text.
    needs_pre = any(re.search(r"\b%s\b" % k, expr) for k in PRELUDE)
    head = (fpre or "") + (PRELUDE_SRC if needs_pre else "")
    prog = ("%sprint(tostring(%s))" % (head, expr))
    try:
        # Two tiers: almost everything finishes in a few thousand ticks, but a
        # piece-heavy program (tonumber boots ~3700, gsub runs long) needs more
        # -- and a program that never finishes would eat the whole high cap in
        # sim wall time (a 30000-tick hang is over two minutes).  So try cheap
        # first and retry ONCE at the high cap whenever there is nothing to
        # compare yet and no error saying why.  `halted` is NOT the test: a
        # mid-parse micro-step can read as halted with empty queues while still
        # needing ticks, so halted-with-nothing is retried exactly like
        # still-going-with-nothing.  A program that is genuinely empty (no
        # print) retries cheaply -- it halts in the same low ticks again.
        chip = _RUNNER.run(prog, 8000)
        cg = chip["outGlobals"]
        clog = (cg.get("log") or "").strip()
        cerr = (cg.get("err") or "").strip()
        if not cerr and clog == "":
            chip = _RUNNER.run(prog, 30000)
            cg = chip["outGlobals"]
            clog = (cg.get("log") or "").strip()
            cerr = (cg.get("err") or "").strip()
        if cerr or clog == "":
            # The chip refused it: a limit, an unimplemented corner, or a
            # parse error.  Counted, never called agreement.
            return idx, ("SKIP", cerr[:60])
        res = oracle_run(prog)
        if not res.get("avail", True):
            return idx, ("SKIP", "no oracle")
        olog = oracle_log(res.get("calls") or []).strip()
    except Exception as e:
        return idx, ("SKIP", repr(e)[:60])
    # BOTH sides go through norm_val.  The oracle's side already has: PUC prints
    # an address after a table (`table: 0x7f...`) and the chip prints its own
    # (`table: 0x4`), so comparing a raw chip log against a normalized oracle
    # one means every assert whose value is a table or a function is a DIFF that
    # says nothing.  literals.lua:208 `assert(x)` was one, and it looked like a
    # chip bug until the same program was run by hand.
    clog = norm_val(clog)
    olog = norm_val(olog)
    if clog == olog:
        return idx, ("OK", "")
    return idx, ("DIFF", "chip=%r oracle=%r" % (clog, olog))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--file", action="append", default=[],
                    help="only this PUC file (repeatable); the sweep is a "
                         "minutes-long batch, so investigate with this")
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--workers", type=int, default=12)
    args = ap.parse_args()

    files = sorted(os.path.join(args.dir, f)
                   for f in os.listdir(args.dir) if f.endswith(".lua"))
    if args.file:
        want = set(args.file)
        files = [f for f in files if os.path.basename(f) in want]
    exprs = []
    for f in files:
        exprs.extend(harvest(f))
    if args.limit:
        exprs = exprs[:args.limit]

    # Twelve workers, each with its own Sim: the suite runs the whole machine
    # for the same reason (twelve worker processes, each with its own Sim), and
    # a sweep this size serial is dominated by its slowest programs -- a gsub
    # harvest is ten seconds of wall while a plain one is a blink.  Hand out
    # work one case at a time so a batch is not as long as its slowest member.
    # The oracle side stays serial: spawning lua55 is milliseconds, and sharing
    # nothing keeps every comparison independent.
    t0 = time.time()
    with ProcessPoolExecutor(max_workers=args.workers,
                             initializer=_init_worker,
                             initargs=(os.path.join(ROOT, "lua.ws"),)) as pool:
        # Phase 1: one probe per distinct prelude, so a file whose prelude the
        # chip cannot run costs ONE run instead of one per lifted assert.
        distinct = sorted({pre for (_e, _f, _n, pre) in exprs if pre})
        probe_ok = {}
        if distinct:
            probed = list(pool.map(_prelude_probe, list(enumerate(distinct)),
                                   chunksize=1))
            probe_ok = {distinct[i]: (ok, note) for i, ok, note in probed}
        # Phase 2: everything whose prelude is known to run.  The rest is a SKIP
        # carrying the probe's own message, so the count still says why.
        runnable, pre_skips = [], {}
        for i, (expr, fname, lineno, pre) in enumerate(exprs):
            if pre:
                ok, note = probe_ok.get(pre, (False, "not probed"))
                if not ok:
                    pre_skips[i] = note
                    continue
            runnable.append(i)
        results = [(i, ("SKIP", pre_skips[i])) for i in pre_skips]
        results += list(pool.map(_chip_run,
                                  [(i, exprs[i]) for i in runnable],
                                  chunksize=1))
    dt = time.time() - t0

    agree = differ = skipped = 0
    fails = []
    by_idx = dict(results)
    for i, (expr, fname, lineno, _pre) in enumerate(exprs):
        verdict, note = by_idx[i]
        if verdict == "SKIP":
            skipped += 1
            if args.verbose:
                fails.append(("SKIP", expr, fname, lineno, note))
        elif verdict == "OK":
            agree += 1
        else:
            differ += 1
            fails.append(("DIFF", expr, fname, lineno, note))

    print("harvested %d self-contained asserts from %d files in %.0fs"
          % (len(exprs), len(files), dt))
    print("agree %d   DIFFER %d   skipped %d" % (agree, differ, skipped))
    for kind, expr, fname, lineno, note in fails[:40]:
        print("  %-4s %s:%d  %s\n         %s" % (kind, fname, lineno,
                                               expr[:100], note))
    return 1 if differ else 0


if __name__ == "__main__":
    sys.exit(main())