"""Show the Internal_MicrochipInput nodes that are NOT declared @left ports.

test_consistency's graph-inputs-match-source fails with ~110 extra graph labels
(a, b, base, _exec_in, ...).  This prints what those nodes actually are, so the
fix targets the real cause instead of the check text.

  python -u tools/chip/portnodes.py [N]
"""
import os
import re
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "irrun"))
from irsims import sim_from_dump, share_dump, _extract  # noqa: E402

WS = os.path.join(ROOT, "lua.ws")


def main(argv):
    want = int(argv[0]) if argv else 12
    src = open(WS, encoding="utf-8").read()
    declared = set(re.findall(r"@left\s+in\s+(\w+)\s*:", src))
    tag = int(os.path.getmtime(WS))
    path = os.path.join(tempfile.gettempdir(),
                        "tinylua-ultprobe-%d.pkl" % tag)
    if not os.path.exists(path):
        share_dump(WS, path)
    sim = sim_from_dump(path)
    labels = {}
    for nid, label in sim.port_label.items():
        labels.setdefault(label, []).append(nid)
    print("declared @left: %d  port_label entries: %d" % (
        len(declared), len(sim.port_label)))
    extra = sorted(l for l in labels if l not in declared)
    print("extra labels: %d, first %d:" % (len(extra), min(want, len(extra))))
    shown = 0
    for label in extra[:want]:
        nid = labels[label][0]
        nd = sim.nodes[nid]
        print("  %-14r keys=%s" % (label, sorted(nd.props.keys())))
        shown += 1
        if shown >= 3:
            break
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
