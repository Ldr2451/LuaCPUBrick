"""Did the chips cost gates?  Node executions per tick, current chip vs a baseline.

The claim the chip work rests on is that a chip boundary costs no TICK -- true,
and measured on every benchmark.  It is a separate question whether it costs
GATES, and gates are what the simulator pays for.  perfbench's table has no gates
column (its `b/c` columns are ticks, compile and bytecode), so this measures it
directly: `execs` is node executions, which is the simulator's cost driver.

Two chips in one process would be ideal, but the baseline lua.ws does not run
green under the current simulator, so this alternates whole runs per chip and
prints both.  Ticks are deterministic, so the ticks column is trustworthy; the
execs column is a count, not a timing, so it is too.

  python -u gatesA.py <baseline.ws>
"""
import importlib.util
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))

# The benchmark list is perfbench's, imported rather than copied.  This file had
# its own copy, and it predated `fields` and `concat` -- so it reported +8.1%
# gates while EXCLUDING the very program the change is for.  A second list of
# the same benchmarks is a second thing to forget to update.
_spec = importlib.util.spec_from_file_location(
    "_pb", os.path.join(HERE, "perfbench.py"))
_pb = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_pb)
PROGRAMS = dict(_pb.PROGRAMS)


def measure(ws):
    """(ticks, execs, log) per program, one compile, by asking profile_sim."""
    out = subprocess.run(
        [sys.executable, "-u", os.path.join(HERE, "profile_sim.py")] +
        list(PROGRAMS.values()),
        capture_output=True, text=True, cwd=ROOT,
        encoding="utf-8", errors="replace")
    rows = []
    for line in out.stdout.splitlines():
        if " execs= " not in line:
            continue
        ticks = int(line.split("ticks=")[1].split()[0])
        execs = int(line.split("execs=")[1].split()[0])
        log = line.split("log=")[1].split(" err=")[0]
        rows.append((ticks, execs, log))
    return rows


def main():
    base_ws = sys.argv[1]
    # the baseline has to be the one profile_sim compiles, so it is copied over
    # lua.ws for the run and the working tree restored afterwards
    cur = open(os.path.join(ROOT, "lua.ws"), encoding="utf-8").read()
    try:
        now = measure(os.path.join(ROOT, "lua.ws"))
        open(os.path.join(ROOT, "lua.ws"), "w", encoding="utf-8",
             newline="").write(open(base_ws, encoding="utf-8").read())
        was = measure(base_ws)
    finally:
        open(os.path.join(ROOT, "lua.ws"), "w", encoding="utf-8",
             newline="").write(cur)

    print("%-10s %-18s %-18s %s" % ("program", "ticks was->now",
                                    "execs was->now", "delta"))
    tw = tn = ew = en = 0
    for name, a, b in zip(PROGRAMS, was, now):
        tw += a[0]; tn += b[0]; ew += a[1]; en += b[1]
        flag = "" if a[2] == b[2] else "  OUTPUT DIFFERS"
        print("%-10s %-18s %-18s %+.1f%%%s"
              % (name, "%d -> %d" % (a[0], b[0]),
                 "%d -> %d" % (a[1], b[1]),
                 (b[1] - a[1]) * 100.0 / a[1], flag))
    print("%-10s %-18s %-18s %+.1f%%"
          % ("TOTAL", "%d -> %d" % (tw, tn), "%d -> %d" % (ew, en),
             (en - ew) * 100.0 / ew))
    return 0


if __name__ == "__main__":
    sys.exit(main())