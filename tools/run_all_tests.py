"""Run EVERY test in the repo, one at a time, and report each result.

The suite is spread over several entry points, and "all green" has to mean
all of them: the chip suite, the language checks, the screen's own suites,
the connector's, and the official Lua tests through the PUC harness.

    python -u tools/run_all_tests.py [--quick]

`--quick` leaves out the two slowest (the official Lua suite and the
screen's paint suite), which is for iteration, not for a claim.
"""
import os
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# (label, path, extra args).  Run from the repo root.
TESTS = [
    ("chip suite", "tests/test_chip_suite.py", []),
    ("syntax", "tests/syntax_check.py", []),
    ("stdlib", "tests/stdlib_check.py", []),
    ("vararg", "tests/vararg_check.py", []),
    ("iter", "tests/iter_check.py", []),
    ("multi", "tests/multi_check.py", []),
    ("host compat", "tests/host_compat_check.py", []),
    ("cpu comms", "tests/cpu_comms_check.py", []),
    ("consistency", "tests/test_consistency.py", []),
    ("screen paint", "extras/screen/painttest.py", []),
    ("screen anim", "extras/screen/animtest.py", []),
    ("connector", "extras/cpu-screen-connector/connectortest.py", []),
    ("cube", "extras/cpu-screen-connector/cubetest.py", []),
]

SLOW = ("puc", "official")


def run(label, path, args):
    t0 = time.time()
    p = subprocess.run([sys.executable, "-u", path] + args, cwd=ROOT,
                       capture_output=True, text=True, encoding="utf-8",
                       errors="replace")
    out = (p.stdout or "") + (p.stderr or "")
    tail = [l for l in out.splitlines() if l.strip()][-3:]
    return p.returncode, time.time() - t0, tail, out


def main():
    quick = "--quick" in sys.argv
    results = []
    for label, path, args in TESTS:
        if quick and any(s in label for s in SLOW):
            continue
        if not os.path.exists(os.path.join(ROOT, path)):
            print("MISSING  %-14s %s" % (label, path))
            results.append((label, "missing", 0.0, []))
            continue
        rc, dt, tail, out = run(label, path, args)
        results.append((label, "ok" if rc == 0 else "FAIL", dt, tail))
        print("%-4s %-14s %6.1fs  %s" % ("PASS" if rc == 0 else "FAIL",
                                         label, dt,
                                         tail[-1][:90] if tail else ""))
        sys.stdout.flush()
    print("\n=== summary ===")
    bad = [r for r in results if r[1] != "ok"]
    for label, status, dt, tail in results:
        print("  %-6s %-14s %6.1fs" % (status.upper(), label, dt))
    print("%d/%d green" % (len(results) - len(bad), len(results)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
