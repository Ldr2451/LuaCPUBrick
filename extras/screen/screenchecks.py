"""Fast screen-chip checks -- cheap regression gate for the paint/animation path.

animtest is the full gate but takes tens of minutes; these checks catch the
same CLASS of bug in seconds: a chip-level change that silently stops the
wall painting, or that stops an animation from committing, is visible here
without replaying the whole oracle stream.  It runs the proven cubetest.py
replay on two short bodies -- cube.lua (filled faces + a forever pivot turn,
so the animation-commit path is exercised) and curve.lua (open wireframe
strokes) -- and asserts each paints.  cube's pivot turn angle must advance
across settled frames, which is what a committed animation delta shows.

  python -u extras/screen/screenchecks.py

Exit 0 if every check passes, 1 if any fails.  Cheap: two short oracle
replays plus a compile, on the order of a minute.
"""
import os
import re
import sys
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
CONN = os.path.join(ROOT, "extras", "cpu-screen-connector")
sys.path.insert(0, ROOT)
from irrun.irdump import WS_EXE  # noqa: E402

SCREEN_WS = os.path.join(HERE, "screen.ws")
TMP = os.environ.get("TMP", ".")
# short budgets: enough to paint a couple settled frames, not a full animation.
# cube's turn lines need >=3 settled frames (the report skips frame 0), and a
# settled frame appears once per pass, which is ~160 ticks for cube.
BUDGET = {"cube": "4200", "curve": "2200"}
TAIL = {"cube": "600", "curve": "150"}


def compile_screen():
    """Compile screen.ws and report errors/warnings."""
    out = os.path.join(TMP, "screencheck_probe.brz")
    p = subprocess.run([WS_EXE, "compile", SCREEN_WS, "-o", out],
                       capture_output=True, text=True, cwd=ROOT, timeout=300)
    combined = (p.stdout + p.stderr)
    errs = len(re.findall(r"\bERROR\b", combined))
    warns = len(re.findall(r"WS\d+", combined))
    if os.path.exists(out):
        os.remove(out)
    ok = p.returncode == 0 and errs == 0
    print("compile: rc=%d errors=%d warnings=%d -> %s"
          % (p.returncode, errs, warns, "OK" if ok else "FAIL"))
    return ok


def clean(text):
    text = re.sub(r"\x1b\[[0-9;]*m", "", text)
    return "".join(c if ord(c) < 128 and (c == "\n" or c.isprintable()) else " "
                   for c in text)


def run_body(body):
    """Replay one body through cubetest and report painted + turn advance."""
    frames = os.path.join(TMP, "screencheck_%s" % body)
    env = dict(os.environ, CUBE_BODY=body + ".lua", CUBE_FRAMES=frames)
    p = subprocess.run(["python", "-u", "cubetest.py", BUDGET[body], TAIL[body], "--save"],
                       cwd=CONN, env=env, capture_output=True, text=True, timeout=900)
    raw = clean(p.stdout + p.stderr)
    painted = 0
    for line in raw.splitlines():
        m = re.match(r"final: painted=(\d+)", line.strip())
        if m:
            painted = int(m.group(1))
    green = re.search(r"PROBE: GREEN", raw) is not None
    staged = "NO non-zero shapePoints" in raw
    # angle lines the pivot carried: cubetest annotates the first painted
    # pass and prints one line per turn step, so >=2 distinct angles means
    # a committed animation delta advanced between settled frames
    angles = []
    for line in raw.splitlines():
        m = re.match(r".*angle \((.+)\)", line.strip())
        if m:
            angles.append(m.group(1))
    turn_moves = len(set(angles)) >= 2
    print("body %-8s rc=%d painted=%d staged=%s green=%s%s%s%s"
          % (body, p.returncode, painted,
             "yes" if not staged else "NO", "yes" if green else "NO",
             " turn=%d frames" % len(angles) if angles else "",
             " turn-advances=yes" if turn_moves else "",
             " traceback" if "traceback" in raw.lower() else ""))
    ok = painted > 0 and not staged and green and "traceback" not in raw.lower()
    if body == "cube":
        # the forever pivot delta committing shows as a changing turn angle
        ok = ok and turn_moves
    return ok


def main():
    checks = []
    checks.append(("compile", compile_screen()))
    checks.append(("cube paint+turn", run_body("cube")))
    checks.append(("curve paint", run_body("curve")))
    print("\n=== screenchecks ===")
    all_ok = True
    for name, ok in checks:
        print("  %-20s %s" % (name, "OK" if ok else "FAIL"))
        all_ok = all_ok and ok
    print("RESULT:", "GREEN" if all_ok else "RED")
    sys.exit(0 if all_ok else 1)


if __name__ == "__main__":
    main()
