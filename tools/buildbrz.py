"""Build the shippable artifact: lua.ws -> lua.brz.

This is the deliverable.  The game loads lua.brz, not lua.ws, and the compiler
writes NO artifact when it has diagnostics -- it printed the IR and exited
non-zero, and left the previous lua.brz sitting there looking current.  So a
build that does not check the exit code can "succeed" and ship yesterday's chip.

  python -u tools/buildbrz.py

Refuses to report success unless the compiler exited 0, and prints what it wrote.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "irrun"))
from irdump import WS_EXE, WS_DIR

src = os.path.join(ROOT, "lua.ws")
out = os.path.join(ROOT, "lua.brz")
before = os.path.getsize(out) if os.path.exists(out) else 0
stamp = os.path.getmtime(out) if os.path.exists(out) else 0

p = subprocess.run([WS_EXE, "compile", src, "-o", out], capture_output=True,
                   text=True, cwd=WS_DIR, encoding="utf-8", errors="replace")
diag = [l.strip() for l in (p.stdout + "\n" + p.stderr).splitlines()
        if "WS" in l and "Error" in l]
if p.returncode != 0:
    print("compile FAILED rc=%d, %d diagnostic(s); lua.brz not written"
          % (p.returncode, len(diag)))
    for l in diag[:8]:
        print("  %s" % l[:170])
    for i, l in enumerate((p.stdout + p.stderr).splitlines()):
        if "Error" in l:
            print("  full: %s" % l[:400])
            break
    sys.exit(1)

after = os.path.getsize(out)
moved = "unchanged" if os.path.getmtime(out) == stamp else "rebuilt"
print("lua.brz %s: %d -> %d bytes (%d diagnostics)" % (moved, before, after,
                                                       len(diag)))
