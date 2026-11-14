"""Static audit of the compiled chip, from one build.

Three questions that all need the compiled graph, and the official
simulator's loader answers all three in one pass over the artifact:

  placeholders   the WireScript compiler silently gives up on an expression it
                 cannot lower.  The node it leaves behind is an `Unsupported`
                 gate, and the simulator refuses to run a graph that has one
                 rather than guessing at it -- which is why this check belongs
                 to the artifact, not to a model that papered over it.
  unhandled      gates whose evaluator the certified semantics has no rule
                 for.  The engine errors naming them at the program that
                 touches one, so the list here is the compiler's and the
                 evaluator's coverage, and an entry means "a program
                 touching this gate fails loudly".  Gates of a class the
                 engine runs as WORLD behaviour (a display, a chat line)
                 are listed apart: they are not certified expressions and
                 never were, and the run executes them.
  size           gates and wires, the gate-size proxy to watch when adding
                 compiler or library code.  The game loads the .brz, so the
                 gate count is the honest currency; the IR-node count is
                 printed alongside because the size ceiling is kept in that
                 older currency.

  python -u tools/chip/audit.py [chip.ws]      (exit 1 if a placeholder or
                                               uncertified gate is found)

One `load_brz` + `census` through tools/simdrv; the IR-node count is one
more compiler call for its dump.
"""
import os
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "tests"))
from simdrv_sim import ensure_brz, Sim, WS_EXE, WS_DIR

path = sys.argv[1] if len(sys.argv) > 1 else None
if path is None:
    ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
        os.path.abspath(__file__))))
    path = os.path.join(ROOT, "lua.ws")


def count_ir_nodes(ws_path):
    """IR-node statements in the compiler's `--dump-ir`: every node is one
    `%name = ...` line, in the root module and in every chip body, and an
    output pin's line starts `out %name` -- the pins count as nodes too,
    which is what the IR tools' node totals (the ceiling's currency)
    included."""
    fd, scratch = tempfile.mkstemp(suffix=".brz")
    os.close(fd)
    try:
        p = subprocess.run([WS_EXE, "compile", os.path.abspath(ws_path),
                            "-o", scratch, "--dump-ir"],
                           cwd=WS_DIR, capture_output=True, text=True,
                           encoding="utf-8", errors="replace")
        if p.returncode != 0:
            return -1
        return len(re.findall(r"^\s*(out\s+)?%\w+", p.stdout, re.M))
    finally:
        os.unlink(scratch)


sim = Sim(ensure_brz(path))
c = sim._send({"cmd": "census"})
if "err" in c:
    print("census: %s" % c["err"])
    sys.exit(1)

placeholders = c.get("placeholders", {})
world_only = c.get("worldOrUnclassified", {})
uncert = sorted(c.get("uncertifiedExpr", []))

print("%d placeholder(s)" % sum(placeholders.values()))
for cls, n in sorted(placeholders.items()):
    print("   %-72s x%d" % (cls.replace("BrickComponentType_", ""), n))

print("%d gates the evaluator does not certify by class, the engine runs as"
      " world behaviour (a run that READS one beyond these names it loudly):"
      % sum(world_only.values()))
for cls, n in sorted(world_only.items()):
    print("   %-72s x%d" % (cls.replace("BrickComponentType_", ""), n))

print("%d gates of %d classes, %d uncertified Expr gates"
      % (c["gates"], len(c.get("classes", {})), len(uncert)))
for cls in uncert:
    print("   %-72s" % cls)

print("gates: %d  wires: %d  ir nodes: %d"
      % (c["gates"], c["wires"], count_ir_nodes(path)))

sim.close()
sys.exit(1 if (placeholders or uncert) else 0)
