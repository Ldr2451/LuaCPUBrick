"""Does a value that was ALREADY on a port when the chip started reach the
program?

Every case in the suite delivers its inputs before the first tick, and with the
sim's default a change detector fires on a port's first sight -- so every input
case has been passing on an edge that a real host does not necessarily raise.  A
chip that learns a sticky input only from an edge therefore looks correct here
and reads nil in game, which is exactly what happened: inStr1 and inStr2 came
through as "" while inNum1 did not.

So this runs with `host_baselines` on, which is the observed host behaviour: the
detector's baseline is established before the chip can act, and a value already
present raises nothing.  Every input kind is checked, because the point is the
class of bug and not one port.

The last case is the same class from the other side: a value that STOPS being
written.  Deleting the variable gate wired to an input leaves the port holding
its last value in the observed host (see tools/chip/inputdrop.py, which measures
it against the chip's strongest possible read), so the program must keep seeing
it.  That is pinned here because the obvious "fix" for the in-game report -- a
latch that falls back to zero when it stops being told -- would break every case
above it.

Run: python -u tests/host_compat_check.py   (exit 0 = all green)
"""
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "irrun"))

from irsims import ChipRunner, share_dump, sim_from_dump  # noqa: E402
from timing import Elapsed  # noqa: E402

# (name, source, inputs, sinputs, num array, str array, expected log)
CASES = [
    ("num0", "print('v', inNum1)", [3.5], None, None, None, "v\t3.5\n"),
    ("num3", "print('v', inNum4)", [1.0, 2.0, 3.0, 4.5], None, None, None,
     "v\t4.5\n"),
    ("str0", "print('v', inStr1)", None, {0: "foo"}, None, None, "v\tfoo\n"),
    ("str1", "print('v', inStr2)", None, {1: "bar"}, None, None, "v\tbar\n"),
    ("numarr", "print('v', inNumArr(1), inNumArr(2))", None, None,
     [10.0, 20.0], None, "v\t10.0\t20.0\n"),
    ("strarr", "print('v', inStrArr(1), inStrArr(2))", None, None,
     None, ["alpha", "beta"], "v\talpha\tbeta\n"),
    # every kind at once, which is how a program actually meets them
    ("all", "print('v', inNum1, inStr1, inNumArr(1), inStrArr(1))",
     [7.0], {0: "foo"}, [9.0], ["x"], "v\t7.0\tfoo\t9.0\tx\n"),
]


def run_case(runner, name, src, inputs, sinputs, narr, sarr):
    sim = runner.sim
    sim.host_baselines = True          # the host that never reports a first value
    sim.reset()
    sim.keep_going = True
    si = {"program": src, "run": True}
    # +1: the ports are inNum1..inNum4 and inStr1..inStr2, 1-based like
    # everything a program can see.  The old spelling wrote inNum0..inNum3 and
    # inStr0/inStr1, and the port rename changed the CASES below without
    # changing this line -- so every scalar case delivered to a port name the
    # chip no longer has.  The sim drops an input key no port carries, silently,
    # and the program reads the default: the case then fails in a way that
    # looks EXACTLY like the chip bug this file exists to catch.  A red check
    # and a broken harness read the same, which is why this took a bisect to
    # find rather than a glance at the output.
    for k, v in enumerate(inputs or []):
        si["inNum%d" % (k + 1)] = float(v)
    for k, v in (sinputs or {}).items():
        si["inStr%d" % (int(k) + 1)] = v
    if narr is not None:
        si["inNumArr"] = [float(v) for v in narr]
    if sarr is not None:
        si["inStrArr"] = [str(v) for v in sarr]
    sim.inputs = si
    sim.run(6000)
    og = sim._out_globals()
    err = og.get("runErrors") or ""
    bad = [l for l in (og.get("progDebug") or "").splitlines()
           if l.startswith("err:")]
    return sim.log, err, bad


def run_dropped_input(runner):
    """A value that stops being written must NOT fall back to zero.

    In game: a scalar input behaves while the variable wired to it is UPDATED,
    but keeps its old value when that variable gate is DELETED -- expected was
    zero, i.e. "the wire is gone so the input is empty".  The port does not work
    that way: nothing writes it, so it holds the last value it was written, and
    the chip cannot tell that from the same value still being driven.  Measured
    in tools/chip/inputdrop.py against the strongest read the chip performs
    (a fresh parse seeding every input latch from the ports), which still saw
    the old value.

    This drives the input, deletes it mid-run (its key leaves the input map,
    exactly as a deleted gate stops writing the port) and delivers a program
    that prints it.  A chip that ever "fixes" the report by zeroing an input
    nobody has written to lately will fail here -- and will have broken the
    seeding fix above, which is the case that made a value present before the
    chip started reach the program at all.
    """
    sim = runner.sim
    sim.host_baselines = True
    sim.keep_going = True
    sim.reset()
    # An infinite loop, because a program that finishes latches Sim.finished
    # and the sim stops ticking -- an earlier version of this case then never
    # delivered its second program and read nothing.
    sim.inputs = {"program": "local i = 0 while true do i = i + 1 end",
                  "run": True, "inNum1": 7.0}

    def on_tick(sim_now, tick):
        if tick != 400:
            return
        nxt = dict(sim_now.inputs)
        nxt.pop("inNum1", None)          # the driving gate is deleted
        sim_now.inputs = dict(nxt, program="print('v2', inNum1)")

    sim.run(4000, on_tick=on_tick)
    og = sim._out_globals()
    err = og.get("runErrors") or ""
    bad = [l for l in (og.get("progDebug") or "").splitlines()
           if l.startswith("err:")]
    return sim.log, err, bad


def main():
    with tempfile.NamedTemporaryFile(suffix=".pkl", delete=False) as f:
        dump_path = f.name
    fails = []
    try:
        share_dump(os.path.join(ROOT, "lua.ws"), dump_path)
        runner = ChipRunner(sim=sim_from_dump(dump_path))
        for name, src, inputs, sinputs, narr, sarr, want in CASES:
            got, err, bad = run_case(runner, name, src, inputs, sinputs,
                                     narr, sarr)
            ok = (got == want and not err and not bad)
            print("%-9s %s log=%r%s" % (name, "OK  " if ok else "FAIL", got,
                                        (" err=%r" % err) if err else ""))
            if not ok:
                print("          want %r" % want)
                if bad:
                    print("          progDebug: %s" % "; ".join(bad))
                fails.append(name)
        got, err, bad = run_dropped_input(runner)
        # 7.0, not 0.0: nothing wrote the port a new value, so it holds what
        # was last written to it
        ok = (got == "v2\t7.0\n" and not err and not bad)
        print("%-9s %s log=%r%s" % ("dropped", "OK  " if ok else "FAIL", got,
                                    (" err=%r" % err) if err else ""))
        if not ok:
            print("          want 'v2\\t7.0\\n' -- the port keeps what was last")
            print("          written to it; a zero here means a latch was")
            print("          invented for an input nobody wrote to.")
            if bad:
                print("          progDebug: %s" % "; ".join(bad))
            fails.append("dropped")
    finally:
        os.unlink(dump_path)
    if fails:
        print("host_compat_check: %d FAILED (%s)" % (len(fails), ", ".join(fails)))
        print("  a value that was on the port before the chip started did not")
        print("  reach the program, so the chip is learning it from an edge only.")
        return 1
    print("host_compat_check: every input reached the program with no edge at all")
    print("host_compat_check: a value that stopped being written is still seen")
    return 0


if __name__ == "__main__":
    with Elapsed("host_compat_check"):
        sys.exit(main())
