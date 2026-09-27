"""What does a RESTART cost, and what would a re-parse of the same text cost?

The suite's `life-no-reparse-second-run` bounds the restart's tick cost, so a
regression fails there.  This is the measurement behind that bound: it prints both
costs and the gap, so a bound that has stopped meaning anything is visible before
it is relied on.

The distinction that makes this measurable at all is between a host that REWRITES
the program port and one that only toggles `run`:

  * rewriting the port is an EDIT, and an edit must parse - that is the control
    `life-edit-while-running` holds down, and this tool measures its cost too;
  * toggling `run` is a restart, and a restart must NOT parse.  A harness that
    rewrites the port on every phase edge re-fires `Change(program)` and so
    measures the first shape while believing it measures the second.  Every
    measurement here therefore writes the port ONCE and afterwards only flips
    `run`.

Timing is on the log going from empty to non-empty, not on `finished`: that is a
latch only `reset()` clears, so it is still set from the PREVIOUS run and a
restart measures as 1 tick.  The log is cleared by the `vmReset` on the run edge,
so empty -> non-empty is exactly the end of the run being measured.

Run it with `python -u tools/chip/restartcost.py`; it prints its own elapsed time
through the usual Elapsed wrapper.
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "irrun"))
sys.path.insert(0, os.path.join(ROOT, "tests"))

from irsims import ChipRunner  # noqa: E402
from timing import Elapsed  # noqa: E402

# Long enough that the parse is the overwhelming majority of the first run, which
# is the only regime where "noticeably faster" is a statement about the parse
# rather than about measurement noise.  60 additions is 615 chars.
LONG = "x = 0\n" + "\n".join("x = x + %d" % (i % 7 + 1) for i in range(60)) \
    + "\nprint(x)\n"
SHORT = "print('hi')"
# The program's own text: a restart re-runs it, an edit replaces it.
EDIT = "x = 0\n" + "\n".join("x = x + %d" % (i % 7 + 1) for i in range(60)) \
    + "\nprint(x + 1)\n"


def _watcher(seen):
    """on_tick that records the tick the program printed on."""
    def watch(sim, tick):
        if not sim.log:
            seen["cleared"] = True
        elif seen.get("cleared") and "at" not in seen:
            seen["at"] = tick
    return watch


def first_run(runner, src, budget):
    """Ticks from boot to the first output, which is the parse plus the run."""
    sim = runner.sim
    sim.reset()
    sim.keep_going = True
    sim.inputs = {"program": src, "run": True}
    seen = {}
    sim.run(budget, on_tick=_watcher(seen))
    return seen.get("at"), sim.log


def restart(runner, src, budget, stop_ticks):
    """Ticks for a second run of the SAME text, with the port written once."""
    sim = runner.sim
    sim.inputs["run"] = False
    sim.run(stop_ticks)
    seen = {}
    sim.inputs["run"] = True
    sim.run(budget, on_tick=_watcher(seen))
    return seen.get("at"), sim.log


def edit_run(runner, src, new_src, budget, at):
    """Ticks for a run of DIFFERENT text delivered at tick `at`: the control.

    The cost is measured from the delivery, not from boot, or it would be the
    first run's cost again and prove nothing.
    """
    sim = runner.sim
    sim.reset()
    sim.keep_going = True
    sim.inputs = {"program": src, "run": True}
    seen = {}
    pending = [False]

    def watch(sim_now, tick):
        if tick + 1 == at and not pending[0]:
            pending[0] = True
            sim_now.inputs = dict(sim_now.inputs, program=new_src)
            seen["cleared"] = False
        if not sim_now.log:
            seen["cleared"] = True
        elif seen.get("cleared") and "at" not in seen:
            seen["at"] = tick - at
    sim.run(budget, on_tick=watch)
    return seen.get("at"), sim.log


def report(label, src, runner, reps, budget, stop_ticks):
    firsts, laters, logs = [], [], set()
    for _ in range(reps):
        first, log1 = first_run(runner, src, budget)
        later, log2 = restart(runner, src, budget, stop_ticks)
        if first is None or later is None:
            raise SystemExit("%s: a run never printed (first=%r later=%r)"
                             % (label, first, later))
        firsts.append(first)
        laters.append(later)
        logs.add((log1, log2))
    if len(logs) != 1:
        raise SystemExit("%s: the restart changed the output: %r" % (label, logs))
    log = logs.pop()[1]
    saved = min(firsts) - max(laters)
    # "noticeably" and "reliably" are two claims, so both are printed: the spread
    # is what says the second run is reliably the cheap one rather than cheaply
    # once.  A restart that re-parses on some starts shows a spread as wide as the
    # parse, which is the whole cost.
    print("%-8s %4d chars  first %-9s restart %-9s re-parse would cost %-5s"
          "  saved %-5d %3.0f%%  log %r"
          % (label, len(src), firsts, laters, min(firsts) + max(laters),
             saved, 100.0 * saved / min(firsts), log))
    if max(laters) >= min(firsts):
        raise SystemExit("%s: a restart is not cheaper than the first run" % label)
    return min(firsts), max(laters)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repeat", type=int, default=3,
                        help="reps of the pair; a restart that is not reliably "
                             "cheaper shows up as spread between them")
    parser.add_argument("--ticks", type=int, default=6000)
    parser.add_argument("--stop-ticks", type=int, default=2000)
    parser.add_argument("--chip", default=os.path.join(ROOT, "lua.ws"),
                        help="a .ws to measure, so a revision or a deliberately "
                             "damaged chip can be asked the same question")
    args = parser.parse_args()
    if args.repeat < 1:
        parser.error("--repeat must be positive")
    if not os.path.exists(args.chip):
        parser.error("no such chip: %s" % args.chip)
    runner = ChipRunner(args.chip)

    print("program: %d chars, %d lines" % (len(LONG), LONG.count("\n")))
    long_first, long_restart = report(
        "long", LONG, runner, args.repeat, args.ticks, args.stop_ticks)
    short_first, short_restart = report(
        "short", SHORT, runner, args.repeat, args.ticks, args.stop_ticks)

    # The control, on the same program: different text MUST pay a parse, or
    # "a restart skips the parse" would be true only because edits are broken too.
    at, log = edit_run(runner, LONG, EDIT, args.ticks, 400)
    print("%-8s an EDIT of the same length costs %-5s  (restart was %d)"
          % ("control", at, long_restart))
    if at is None:
        raise SystemExit("control: the edited program never printed")
    if at <= long_restart:
        raise SystemExit("control: an edit cost %d ticks, no more than a restart "
                         "at %d - the edit was not parsed" % (at, long_restart))

    print("\na restart skips %d of the %d ticks the first run pays, and a"
          " different program still pays them" % (long_first - long_restart,
                                                  long_first))
    print("suite bound: life-no-reparse-second-run asserts a restart under a cap "
          "fitted between these costs")
    _ = short_first, short_restart
    return 0


if __name__ == "__main__":
    with Elapsed("restartcost"):
        sys.exit(main())
