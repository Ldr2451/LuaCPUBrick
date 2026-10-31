"""One command: rebuild the chip and run the whole chip-level gate.

  python -u extras/screen/checkall.py

gen -> build (rc=0 required) -> the probes (each carries the watchdog's
per-tick structural checks) -> screenchecks.py's six gates.  Minutes --
the chain test (extras/cpu-screen-connector/connectortest.py, ~14 min)
CONFIRMS a green gate; it does not discover, so chip scheduling work
happens at this level first (docs/lessons.md, "Fixing bugs").

Exit code 0 only when every step is green.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))

STEPS = [
    ("gen", ["extras/screen/gen.py"]),
    ("build", ["extras/screen/build.py"]),
    ("animprobe (translucent refresh)", ["extras/screen/animprobe.py"]),
    ("ghostprobe (opaque refresh)", ["extras/screen/ghostprobe.py"]),
    ("ptprobe (one-point shapes)", ["extras/screen/ptprobe.py"]),
    ("screenchecks (six gates)", ["extras/screen/screenchecks.py"]),
]


def main():
    bad = []
    for name, argv in STEPS:
        t0 = __import__("time").time()
        p = subprocess.run([sys.executable, "-u"] + argv, cwd=ROOT,
                           capture_output=True, text=True, env=os.environ)
        out = (p.stdout or "") + (p.stderr or "")
        ok = p.returncode == 0
        # watchdog violations print at the probe's own end; a probe that
        # passes visually but breaks structure must fail: probes that
        # wire the watchdog exit non-zero on violations themselves.
        print("%-38s rc=%d %5.0fs" % (name, p.returncode,
                                      __import__("time").time() - t0))
        if not ok:
            bad.append(name)
            tail = out.strip().splitlines()[-24:]
            print("  " + "\n  ".join("  " + ln for ln in tail))
    print("checkall: %s" % ("GREEN" if not bad else "RED: " + ", ".join(bad)))
    return 0 if not bad else 1


if __name__ == "__main__":
    sys.exit(main())
