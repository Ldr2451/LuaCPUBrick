"""Parse vs run split for one program on one chip.

Ticks to progOk (compile_ticks) is the parse cost; the rest is the run.
One chip, one run, prints both. No comparison, no drift to argue about.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "irrun"))

from irsims import ChipRunner, _extract

CAP = 30000


def main(argv):
    chips = []
    files = []
    repeat = 1
    rename = {}
    i = 0
    while i < len(argv):
        if argv[i] == "--chip":
            chips.append(argv[i + 1])
            i += 2
            continue
        if argv[i] == "--repeat":
            repeat = int(argv[i + 1])
            i += 2
            continue
        files.append(argv[i])
        i += 1
    # OPTIONAL LABELS: a chip path may be followed by "=label"; parsesplit
    # prints the basename, so a revision needs a readable name (histbisect.py
    # passes the path twice, once as path once as label).
    labelled = []
    for c in chips:
        if "=" in c and not os.path.exists(c):
            path, name = c.split("=", 1)
            labelled.append((path, name))
        else:
            labelled.append((c, os.path.basename(c)))
    orig_base = os.path.basename

    def base(p):
        for path, name in labelled:
            if os.path.abspath(path) == os.path.abspath(p):
                return name
        return orig_base(p)

    os.path.basename = base
    try:
        return _run(labelled, files, repeat)
    finally:
        os.path.basename = orig_base


def _run(labelled, files, repeat):
    runners = [(name, ChipRunner(os.path.abspath(path)))
               for path, name in labelled] or [
        ("lua.ws", ChipRunner(os.path.join(ROOT, "lua.ws")))]
    for f in files:
        src = open(f, encoding="utf-8").read()
        for rep in range(repeat):
            order = runners if rep % 2 == 0 else list(reversed(runners))
            for c, runner in order:
                sim = runner.sim
                sim.reset()
                labels = {}
                for nid, node in sim.nodes.items():
                    label = _extract(node.props.get("_label", ("raw", "")))
                    if isinstance(label, str):
                        labels[label] = nid
                prog_ok = labels.get("progOkV")
                state = {"compiled": None, "first": None}

                def watch(sim_now, tick, state=state, prog_ok=prog_ok):
                    if state["compiled"] is None and sim_now.vars.get(prog_ok):
                        state["compiled"] = tick
                    if state["first"] is None and sim_now.log:
                        state["first"] = tick

                sim.inputs = {"program": src, "run": True}
                result = sim.run(CAP, on_tick=watch)
                og = result.get("outGlobals", {})
                dbg = (og.get("progDebug") or "").splitlines()
                start = next((l for l in dbg if "parse start" in l), "?")
                print("%-40s rep=%d chars=%-6d parse=%s first=%s ticks=%d %s log=%.40r err=%r" % (
                    os.path.basename(c), rep, len(src), state["compiled"],
                    state["first"], sim.tick + 1, start,
                    result.get("log", ""),
                    og.get("runErrors", "")))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
