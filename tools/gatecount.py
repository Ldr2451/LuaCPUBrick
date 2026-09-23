"""Compile a .ws file with --dump-ir and sum the IR node counts as a gate proxy.

  python -u tools/gatecount.py lua.ws [out.brz]

Budget for the chip: watch this when adding compiler or library code, and buy
headroom by simplifying what is already there when it grows.
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, 'irrun'))
from irdump import WS_EXE, WS_DIR

src = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'lua.ws')
out = sys.argv[2] if len(sys.argv) > 2 else None
args = [WS_EXE, "compile", src]
if out:
    args += ["-o", out]
args += ["--dump-ir"]
p = subprocess.run(args, capture_output=True, text=True, cwd=WS_DIR)
err = p.stderr
mods = re.findall(
    r"module '([^']+)' \((\d+) nodes, (\d+) wires, (\d+) chips\)", err)
nodes = sum(int(n) for _, n, _, _ in mods)
wires = sum(int(w) for _, _, w, _ in mods)
print(f"modules: {len(mods)}  nodes: {nodes}  wires: {wires}")
for name, n, w, c in mods[:15]:
    print(f"  {name}: {n} nodes {w} wires {c} chips")
if len(mods) > 15:
    print(f"  ... +{len(mods) - 15} more")
print("STDOUT tail:", (p.stdout or "")[-200:])
print("rc:", p.returncode)
warns = [l for l in err.splitlines() if "WARN" in l or "ERROR" in l]
for w in warns[:10]:
    print(w[:160])
