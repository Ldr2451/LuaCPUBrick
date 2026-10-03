"""How many ticks a character of Lua source costs, and what a piece's BOOT would be.

The repo quotes two rates for the lexer that cannot both be true.  lua.ws's header
says `lexChunk() = 4 characters per tick`, and three comments in it turn that rate
into a boot figure (10769 characters -> 2692 ticks); AGENTS.md says the scan floor
is 2 chars/tick (0.507 ticks/char, measured), and its own tonumber line implies 4
again (760 chars -> 190 ticks of lexing).  This measures the rates rather than
choosing between the records, and then prices a piece file under the measured ones.

Six rates, because a prepended piece pays all of them and the "10769 characters"
figure prices only the first:

  scan     a comment of N characters, which lexes to no tokens at all: the raw
           scan, and the floor the two records disagree about.
  assign   N `x = x + 1` statements in a function that is NEVER called: lexing AND
           parsing of real source, with the run cost constant.  The per-character
           term of a piece, whose bodies are not run at boot either.
  cond     the same with an `if ... then ... end` statement, a longer statement
           with fewer tokens per character.  It is the CHEAPER of the two per
           character and the dearer per statement, so the per-character term is a
           property of the code and these two bracket it.
  closure  N empty functions at top level, which ARE run: one closure each.
  funclit  N functions with a parameter, a local and a return: a body, fixed, so
           the difference is one closure plus the parse of that one body, and the
           two terms overlap by that much - second order beside the per-character
           term, and the honest way to read the number.
  funccap  the same, capturing an upvalue: a cell each, which is the one thing
           AGENTS.md says a closure adds per captured local.

The first three are per character and the last three per function, and a piece's
boot is `chars * per_char + functions * per_function`, so the price is printed as
a RANGE over the per-character and per-function terms rather than a single
product of two point estimates.  The per-character band is the two real-source
shapes, NOT the scan floor: a piece's characters are lexed AND parsed, and the
floor is what a character that produces no token costs.

Each rate is the difference between the largest and smallest program of its family,
which differ in that one dimension only, timed from boot to the program's first
output: the same clock tools/chip/restartcost.py uses, because `finished` is a
latch only reset() clears.  A tick count is deterministic, so the spread printed
per point is a determinism check rather than a noise estimate.

    python -u tools/chip/lexrate.py                      # the six rates
    python -u tools/chip/lexrate.py lib/str_format.lua    # + what that file costs
    python -u tools/chip/lexrate.py --chip other.ws ...   # a revision, or a
                                                          # damaged chip, asked
                                                          # the same question
"""
import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "irrun"))
sys.path.insert(0, os.path.join(ROOT, "tests"))

from irsims import ChipRunner  # noqa: E402
from timing import Elapsed  # noqa: E402

# Statement shapes.  None of them declares a local per statement, so a family's
# length is set by its statement count alone and the register file cannot be the
# thing being measured.  The sizes are bounded by the two limits a program of this
# shape can hit -- MAX_INSTR 1024 and the ~4 KB source buffer -- not by taste.
SIZES = [0, 500, 1000, 2000]
STMTS = [0, 60, 120]
FUNCS = [0, 10, 20]
TICK_BUDGET = 20000
# In game a tick is 16.7ms whatever the chip does in it, so a boot cost in ticks
# is a boot cost in seconds there and nowhere else.
TICKS_PER_SECOND = 60.0

# The probes are 46 INDEPENDENT boot-to-first-output runs, each up to 20,000
# ticks of a gate-level simulation, and they were done one after another: 476
# seconds, of which about 5 is the compile.  Nothing in one probe depends on
# another, so they go to a process pool -- the GIL means threads would not help,
# and this is the same share_dump/sim_from_dump shape the suite already uses, so
# the chip is compiled once and every worker indexes that one dump.
DEFAULT_WORKERS = min(12, (os.cpu_count() or 4))
_POOL = None
ARGS_CHIP = None


def _pool_init(dump_path):
    global _POOL
    from irsims import sim_from_dump
    _POOL = ChipRunner(sim=sim_from_dump(dump_path))


def _pool_probe(job):
    """One probe in a worker: (key, src) -> (key, ticks, log) or (key, None, err).

    A probe that never prints is a RESULT here, not a crash: `first_run` raises
    SystemExit because a silent run means the tool is measuring nothing, and that
    has to reach the parent as a value so the parent can say which probe failed.
    """
    key, src = job
    try:
        at, log = first_run(_POOL, src)
    except SystemExit as e:
        return key, None, str(e)
    return key, at, log


def first_run(runner, src):
    """Ticks from boot to the first output: the parse plus the run.  (sec, log)."""
    sim = runner.sim
    sim.reset()
    sim.keep_going = True
    sim.inputs = {"program": src, "run": True}
    seen = {}

    def watch(sim_now, tick):
        if not sim_now.log:
            seen["cleared"] = True
        elif seen.get("cleared") and "at" not in seen:
            seen["at"] = tick

    sim.run(TICK_BUDGET, on_tick=watch)
    if "at" not in seen:
        raise SystemExit("a run never printed (budget %d):\n%s"
                         % (TICK_BUDGET, src))
    return seen["at"], sim.log


def scan_prog(n):
    """A comment: characters the lexer reads and the parser never sees.

    This WAS the scan floor, and it stopped being one: a line comment is one
    Find now, so this family is flat and a flat family cannot price anything.
    It is kept because "O(1)" is the measurement, and because the floor moving
    off this family is the thing a reader needs to see.
    """
    return "-- %s\nprint(1)\n" % ("x" * n)


def space_prog(n):
    """Whitespace: also characters no token comes from, and still per character.

    This is the scan floor now that `scan` is flat.  Indentation is the one
    thing a real program has that neither this nor a comment covers, and a Find
    cannot help it: skipping a run of spaces needs the first character that is
    NOT a space, and the host's search finds a substring rather than a character
    class.
    """
    return "%s\nprint(1)\n" % (" " * n)


def body_prog(body, n):
    """`n` statements in a function that is never called: lexed and parsed, not run."""
    return "local f = function()\n%s x = 0\nend\nprint(1)\n" \
        % "".join(body % (i % 7 + 1) for i in range(n))


SOURCE_BODY = "x = x + %d\n"               # 11 chars, 5 tokens
COND_BODY = "if x == %d then x = 2 end\n"   # 25 chars, 9 tokens


def closure_prog(n):
    return "".join("local f%d = function() end\n" % i for i in range(n)) \
        + "print(1)\n"


def funclit_prog(n):
    return "".join("local f%d = function(a)\n local b = a + %d\n return b + 1\n"
                   "end\n" % (i, i % 7 + 1) for i in range(n)) + "print(1)\n"


def funccap_prog(n):
    """Each function writes the SAME captured local, so each still gets its own cell."""
    return "local c = 0\n" + "".join(
        "local f%d = function()\n c = c + 1\n return c\nend\n" % i
        for i in range(n)) + "print(1)\n"


def slope(runner, label, sizes, make, unit, use, reps, results=None):
    """The cost of one unit of `label`, from the two ends of its family.

    Endpoints, not a fit: every point is printed so a non-linearity is visible
    rather than averaged away, and the two ends are the two programs differing by
    the most of the dimension being measured.  `unit` is what one `n` is (a
    character, a statement, a function); `use` is which of the two rates the price
    below is allowed to use, per character or per function.

    `results` is {n: [(ticks, log), ...]} measured elsewhere -- by a worker
    process, in the parallel path -- so that this stays the single place numbers
    become rates.  Everything downstream reads the printed table and the whole
    point of this tool is that the table is comparable between runs, so the
    printing must not depend on which process happened to run a probe.
    """
    if results is None:
        results = {n: [first_run(runner, make(n)) for _ in range(reps)]
                   for n in sizes}
    print("  %-8s %-5s %-7s %-7s %s" % (label, "n", "chars", "ticks", "spread"))
    points = []
    for n in sizes:
        seen = results[n]
        ticks = [t for t, _ in seen]
        logs = {log for _, log in seen}
        if logs != {"1\n"}:
            raise SystemExit("%s n=%d printed %r, want '1\\n' - the probe is not "
                             "measuring a successful run" % (label, n, logs))
        points.append((n, len(make(n)), min(ticks), max(ticks)))
        print("  %-8s %-5d %-7d %-7d %s" % (label, n, len(make(n)), min(ticks),
                                             ticks))
    (n0, c0, t0, _), (n1, c1, t1, _) = points[0], points[-1]
    per_n = (t1 - t0) / float(n1 - n0)
    chars_each = (c1 - c0) / float(n1 - n0)
    # A rate at or below zero used to mean the probe had measured nothing, and
    # failing was the honest answer.  It now means the region is O(1): a comment
    # is one Find, so 2,013 characters cost the same 17 ticks as 13.  That is a
    # RESULT and the most interesting thing this tool can say, so it is printed
    # rather than raised -- and it is reported as a flat family, never as a rate,
    # because "0.000 ticks/char" would read as "free" and it is not: it is
    # "this dimension no longer costs per character".
    if per_n <= 0:
        print("  %-8s %6.2f ticks per %-4s = O(1): %d chars cost the same %d "
              "ticks as %d\n" % ("", per_n, unit, c1, t1, c0))
        return {"label": label, "unit": unit, "use": use, "per_n": 0.0,
                "per_char": 0.0, "points": points, "flat": True}
    print("  %-8s %6.2f ticks per %-4s = %.3f ticks/char  (%.1f chars each)\n"
          % ("", per_n, unit, per_n / chars_each, chars_each))
    return {"label": label, "unit": unit, "use": use, "per_n": per_n,
            "per_char": per_n / chars_each, "points": points}


def price(runner, path, per_char, per_func, floor):
    """What prepending this file would cost: MEASURED, with the model beside it.

    The model is `chars * per_char`, and per_char comes from synthetic programs
    with no comments in them, so it charges every character of a commented file
    the code rate.  That overstated demo.lua by about 2x (8,180-11,426 modelled
    against 4,532 measured) and it did so silently, which is the worst way to be
    wrong: a piece priced with it looked twice as dear as it is.  So the number
    that leads is the one from running the file, and the model is kept as the
    comparison it has become.
    """
    text = open(path, encoding="utf-8").read()
    chars = len(text)
    funcs = len(re.findall(r"function", text))
    # A library piece DEFINES functions and prints nothing, and first_run times to
    # the first line of output -- so measuring the piece alone would time out
    # rather than measure.  The chip's real path is the piece prepended to a user
    # program, so that is what gets run: the piece's characters plus the smallest
    # program that produces a line.
    #
    # A file that will not fit is not a pricing problem, it is an ANSWER: the
    # source buffer is about 4 KB including everything prepended, so a piece this
    # size could not be delivered at all.  That is the whole reason string.format
    # is a gate and lib/str_format.lua is only its reference implementation.
    prog = text + "\nprint(1)\n"
    limit = 4096
    if len(prog) > limit:
        print("\n%s: %d chars, %d `function`s" % (path, chars, funcs))
        print("  NOT MEASURABLE: %d chars with the smallest program that prints,"
              " over" % len(prog))
        print("  the ~%d-char source buffer.  A piece this size cannot be"
              " delivered at all, so the" % limit)
        print("  modelled %.0f - %.0f ticks is academic and the gate it should"
              " be is" % (chars * per_char[0], chars * per_char[1]))
        print("  not optional.")
        return None, None
    seen = sorted(first_run(runner, prog) for _ in range(2))
    lo, hi = seen[0][0], seen[-1][0]
    model = chars * per_char[0] + funcs * per_func[0]
    print("\n%s: %d chars, %d `function`s" % (path, chars, funcs))
    print("  MEASURED boot     %6d - %-6d ticks  = %.0f - %.0f s in game at"
          " %.0f ticks/s" % (lo, hi, lo / TICKS_PER_SECOND,
                             hi / TICKS_PER_SECOND, TICKS_PER_SECOND))
    print("  modelled          %6.0f - %-6.0f ticks  (chars x %.2f-%.2f, which"
          " is the code rate)" % (chars * per_char[0], chars * per_char[1],
                                  per_char[0], per_char[1]))
    print("  closures            %3.0f - %-6.0f ticks  (%.0f - %.0f ticks each,"
          " already inside the measured total)"
          % (funcs * per_func[0], funcs * per_func[1], per_func[0], per_func[1]))
    if model > 0:
        print("  the model says %.1fx the measured cost, because it charges"
              " comment and" % (model / float(lo)))
        print("  whitespace characters the code rate and neither costs that"
              " any more")
    print("  for comparison: at the scan floor (%.2f ticks/char) the SCANNING"
          " alone would be %.0f" % (floor, chars * floor))
    print("  ticks, so the parsing of the source is most of the boot either way")
    return lo, hi


def measure_all(families, reps, workers):
    """Run every probe, in parallel if there is more than one worker.

    Returns {family_index: {n: [(ticks, log), ...]}} with the reps of each point
    in the order they were asked for, so the printed table does not depend on the
    order the pool happened to finish in.
    """
    jobs = []
    for fi, (_label, sizes, make, _unit, _use) in enumerate(families):
        for n in sizes:
            for _r in range(reps):
                jobs.append(((fi, n), make(n)))
    if workers <= 1:
        runner = ChipRunner(ARGS_CHIP)
        out = {}
        for key, src in jobs:
            at, log = first_run(runner, src)
            out.setdefault(key, []).append((at, log))
        return out

    import multiprocessing as mp
    import tempfile
    from irsims import share_dump
    fd, pkl = tempfile.mkstemp(prefix="lexrate", suffix=".pkl")
    os.close(fd)
    try:
        share_dump(ARGS_CHIP, pkl)
        got = {}
        with mp.Pool(workers, initializer=_pool_init, initargs=(pkl,)) as pool:
            for key, at, log in pool.imap_unordered(_pool_probe, jobs,
                                                    chunksize=1):
                if at is None:
                    raise SystemExit(log)
                got.setdefault(key, []).append((at, log))
    finally:
        os.unlink(pkl)
    # imap_unordered returns results in whatever order they finished, so a
    # point's reps would print in a different order on every run -- and the
    # printed spread is this tool's determinism check, which is exactly the
    # thing that must not wobble.  Sorting puts it back.
    for key in got:
        got[key] = sorted(got[key])
    return got


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("piece", nargs="*",
                        help="piece files to price under the measured rates")
    parser.add_argument("--repeat", type=int, default=2,
                        help="reps of each program; the tick count is "
                             "deterministic, so this is a determinism check")
    parser.add_argument("--workers", type=int, default=DEFAULT_WORKERS,
                        help="processes; 1 runs everything in this one")
    parser.add_argument("--chip", default=os.path.join(ROOT, "lua.ws"),
                        help="a .ws to measure, so a revision or a deliberately "
                             "damaged chip can be asked the same question")
    args = parser.parse_args()
    global ARGS_CHIP
    ARGS_CHIP = args.chip
    if args.repeat < 1:
        parser.error("--repeat must be positive")
    if args.workers < 1:
        parser.error("--workers must be positive")
    for path in [args.chip] + [os.path.join(ROOT, p) for p in args.piece]:
        if not os.path.exists(path):
            parser.error("no such file: %s" % path)

    families = [("scan", SIZES, scan_prog, "char", "char"),
                ("space", SIZES, space_prog, "char", "char"),
                ("assign", STMTS, lambda n: body_prog(SOURCE_BODY, n),
                 "stmt", "char"),
                ("cond", STMTS, lambda n: body_prog(COND_BODY, n),
                 "stmt", "char"),
                ("closure", FUNCS, closure_prog, "func", "func"),
                ("funclit", FUNCS, funclit_prog, "func", "func"),
                ("funccap", FUNCS, funccap_prog, "func", "func")]
    reps = args.repeat
    print("rates, as the difference between the two ends of each family")
    print("  %d probes on %d workers" % (sum(len(f[1]) for f in families) * reps,
                                          args.workers))
    got = measure_all(families, reps, args.workers)
    # price() runs the piece prepended to a program that prints, so it needs a
    # sim in THIS process -- only when a piece was actually named, because it
    # would otherwise pay a second compile for nothing.
    runner = ChipRunner(args.chip) if args.piece else None
    rates = [slope(runner, label, sizes, make, unit, use, reps,
                   results={n: got[(fi, n)] for n in sizes})
             for fi, (label, sizes, make, unit, use) in enumerate(families)]

    print("summary")
    # The floor is the `space` family, and it is the floor BECAUSE `scan` went
    # flat: a comment is one Find now, so the cheapest per-character thing left
    # is a run of spaces.  If `space` ever goes flat too there is no floor left
    # to quote, and saying so beats dividing by zero.
    space = [r for r in rates if r["label"] == "space"][0]
    if space.get("flat"):
        raise SystemExit("space is flat too, so there is no per-character floor "
                         "left to quote - re-derive the piece rates from a family "
                         "that still costs per character")
    floor = space["per_char"]
    chars = sorted(r["per_char"] for r in rates
                   if r["use"] == "char" and r["label"] not in ("scan", "space"))
    funcs = sorted(r["per_n"] for r in rates if r["use"] == "func")
    for got in rates:
        if got.get("flat"):
            print("  %-8s %6s ticks/char  %6s per %s  (O(1): a Find, not a walk)"
                  % (got["label"], "-", "-", got["unit"]))
        else:
            print("  %-8s %6.3f ticks/char  %6.2f ticks per %s"
                  % (got["label"], got["per_char"], got["per_n"], got["unit"]))
    print("\n  the scan floor is %.2f ticks/char = %.2f chars/tick, measured with"
          " WHITESPACE" % (floor, 1.0 / floor))
    print("  -- a comment used to be the probe and is O(1) now, and a string with"
          " no escape in it always was")
    print("  the floor is what a character that lexes to no token costs -- NOT a"
          " piece's rate")
    print("  a piece's per-char term is %.2f to %.2f ticks/char (real source, lexed"
          " and parsed)" % (chars[0], chars[-1]))
    print("  its per-function term is %.0f to %.0f ticks" % (funcs[0], funcs[-1]))

    for path in args.piece:
        price(runner, os.path.join(ROOT, path), (chars[0], chars[-1]),
              (funcs[0], funcs[-1]), floor)
    return 0


if __name__ == "__main__":
    with Elapsed("lexrate"):
        sys.exit(main())
