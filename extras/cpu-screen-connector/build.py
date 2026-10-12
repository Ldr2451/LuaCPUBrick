"""Build the connector artifact: connector.ws -> connector.brz.

Same discipline as extras/screen/build.py: the compiler writes NO
artifact when it has diagnostics, so refuse success unless rc == 0.
The connector uses no fork features, so the stock compiler builds it.

  python -u extras/cpu-screen-connector/build.py
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "irrun"))
from irdump import WS_EXE, WS_DIR

src = os.path.join(HERE, "connector.ws")
out = os.path.join(HERE, "connector.brz")
before = os.path.getsize(out) if os.path.exists(out) else 0
stamp = os.path.getmtime(out) if os.path.exists(out) else 0

p = subprocess.run([WS_EXE, "compile", src, "-o", out], capture_output=True,
                   text=True, cwd=WS_DIR, encoding="utf-8", errors="replace")
diag = [l.strip() for l in (p.stdout + "\n" + p.stderr).splitlines()
        if "WS" in l and "Error" in l]
if p.returncode != 0:
    print("compile FAILED rc=%d, %d diagnostic(s); connector.brz not written"
          % (p.returncode, len(diag)))
    for l in diag[:8]:
        print("  %s" % l[:170])
    sys.exit(1)

after = os.path.getsize(out)
moved = "unchanged" if os.path.getmtime(out) == stamp else "rebuilt"
print("connector.brz %s: %d -> %d bytes (%d diagnostics)"
      % (moved, before, after, len(diag)))
