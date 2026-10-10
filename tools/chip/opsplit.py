"""Run-phase opcode histogram for one program across chips.

Same ticks with more game seconds means the same instructions at a higher
per-tick host price -- or extra instructions the tick count hides. The tick
count alone cannot tell those apart; the per-op histogram can: it names the
opcodes whose dynamic count moved.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "irrun"))
sys.path.insert(0, os.path.join(ROOT, "tests"))
from irsims import ChipRunner, _extract  # noqa: E402
from spec import OP_NAMES  # noqa: E402

CAP = 30000


def main(argv):
    chips = []
    files = []
    i = 0
    while i < len(argv):
        if argv[i] == "--chip":
            chips.append(argv[i + 1])
            i += 2
            continue
        files.append(argv[i])
        i += 1
    chips = chips or [os.path.join(ROOT, "lua.ws")]
    runners = [(c, ChipRunner(os.path.abspath(c))) for c in chips]
    for f in files:
        src = open(f, encoding="utf-8").read()
        for c, runner in runners:
            sim = runner.sim
            sim.reset()
            labels = {}
            for nid, node in sim.nodes.items():
                label = _extract(node.props.get("_label", ("raw", "")))
                if isinstance(label, str):
                    labels[label] = nid
            prog_ok = labels.get("progOkV")
            vm_pc = labels.get("vmPc")
            bop_id = labels.get("bop")
            state = {"compiled": None, "counts": {}, "ticks": 0}

            def watch(sim_now, tick, state=state):
                if state["compiled"] is None and sim_now.vars.get(prog_ok):
                    state["compiled"] = tick + 1
                    return
                if state["compiled"] is not None:
                    bop = sim_now.arrays.get(bop_id, [])
                    pc = int(sim_now.vars.get(vm_pc, 0))
                    if 0 <= pc < len(bop):
                        op = int(bop[pc])
                        name = OP_NAMES[op] if 0 <= op < len(OP_NAMES) else str(op)
                        state["counts"][name] = state["counts"].get(name, 0) + 1
                state["ticks"] = tick + 1

            sim.inputs = {"program": src, "run": True}
            result = sim.run(CAP, on_tick=watch)
            og = result.get("outGlobals", {})
            ranked = sorted(state["counts"].items(), key=lambda kv: -kv[1])
            print("%-28s parse=%s ticks=%d err=%r" % (
                os.path.basename(c), state["compiled"], state["ticks"],
                og.get("runErrors", "")))
            print("    " + " ".join("%s=%d" % kv for kv in ranked))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
