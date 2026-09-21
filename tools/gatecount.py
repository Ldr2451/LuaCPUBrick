"""Compile a .ws file with --dump-ir and sum IR node counts as gate proxy."""
import re
import subprocess
import sys

WS = (r"C:\Users\Alessandro\AppData\Local\Temp\opencode\wirescript"
      r"\target\release\wirescript.exe")

src = sys.argv[1]
out = sys.argv[2] if len(sys.argv) > 2 else None
args = [WS, "compile", src]
if out:
    args += ["-o", out]
args += ["--dump-ir"]
p = subprocess.run(args, capture_output=True, text=True, cwd=
                   r"C:\Users\Alessandro\AppData\Local\Temp\opencode"
                   r"\wirescript")
err = p.stderr
mods = re.findall(r"module '([^']+)' \((\d+) nodes, (\d+) wires, (\d+) chips\)",
                  err)
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
