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
    for k, v in enumerate(inputs or []):
        si["inNum%d" % k] = float(v)
    for k, v in (sinputs or {}).items():
        si["inStr%d" % int(k)] = v
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
    finally:
        os.unlink(dump_path)
    if fails:
        print("host_compat_check: %d FAILED (%s)" % (len(fails), ", ".join(fails)))
        print("  a value that was on the port before the chip started did not")
        print("  reach the program, so the chip is learning it from an edge only.")
        return 1
    print("host_compat_check: every input reached the program with no edge at all")
    return 0


if __name__ == "__main__":
    with Elapsed("host_compat_check"):
        sys.exit(main())
