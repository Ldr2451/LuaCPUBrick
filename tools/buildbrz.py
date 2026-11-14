"""Build the shippable artifact: lua.ws -> lua.brz.

This is the deliverable.  The game loads lua.brz, not lua.ws, and the compiler
writes NO artifact when it has diagnostics -- it printed the IR and exited
non-zero, and left the previous lua.brz sitting there looking current.  So a
build that does not check the exit code can "succeed" and ship yesterday's
chip.

  python -u tools/buildbrz.py

Refuses to report success unless the compiler exited 0, and prints what it
wrote.  The compile itself lives in tests/simdrv_sim.py (`compile_ws`), the
one place that knows where the compiler is, so the build and the harness
cannot disagree about which artifact is current.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "tests"))
from simdrv_sim import compile_ws

src = os.path.join(ROOT, "lua.ws")
out = os.path.join(ROOT, "lua.brz")
before = os.path.getsize(out) if os.path.exists(out) else 0
stamp = os.path.getmtime(out) if os.path.exists(out) else 0

try:
    compile_ws(src, out)
except RuntimeError as e:
    print(str(e))
    sys.exit(1)

after = os.path.getsize(out)
moved = "unchanged" if os.path.getmtime(out) == stamp else "rebuilt"
print("lua.brz %s: %d -> %d bytes" % (moved, before, after))
