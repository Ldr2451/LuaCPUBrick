"""Build the shippable screen artifact: screen.ws -> screen.brz.

The wall IS the screen: every build lays the 64x64 microbrick wall
and wires it to the chip's pixel outputs (--wall), so the artifact
holds the wall and the chip, properly connected.  Same discipline as
the repo's buildbrz.py, which this folder may not touch: the compiler
writes NO artifact when it has diagnostics, so a build that does not
check the exit code can "succeed" and ship yesterday's chip.  Refuses
to report success unless rc == 0.

  python -u extras/screen/build.py
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "irrun"))
from irdump import WS_EXE, WS_DIR

src = os.path.join(HERE, "screen.ws")
out = os.path.join(HERE, "screen.brz")
before = os.path.getsize(out) if os.path.exists(out) else 0
stamp = os.path.getmtime(out) if os.path.exists(out) else 0

p = subprocess.run([WS_EXE, "compile", src, "--wall", "px:64x64",
                    "-o", out], capture_output=True,
                   text=True, cwd=WS_DIR, encoding="utf-8", errors="replace")
diag = [l.strip() for l in (p.stdout + "\n" + p.stderr).splitlines()
        if "WS" in l and "Error" in l]
if p.returncode != 0:
    print("compile FAILED rc=%d, %d diagnostic(s); screen.brz not written"
          % (p.returncode, len(diag)))
    for l in diag[:8]:
        print("  %s" % l[:170])
    sys.exit(1)

after = os.path.getsize(out)
moved = "unchanged" if os.path.getmtime(out) == stamp else "rebuilt"
print("screen.brz %s: %d -> %d bytes (%d diagnostics)" % (moved, before, after,
                                                          len(diag)))
