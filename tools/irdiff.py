"""Compare IR node-kind histograms between two .ws files.

  python -u tools/irdiff.py before.ws after.ws

Use it to see what a change costs in gates, and to find what to simplify when
the total moves the wrong way.  Both files go through the same --dump-ir-full
path as tools/audit.py, so the totals here and the counts there agree, and the
compile result is cached per source, so re-diffing a file is free.
"""
import collections
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'irrun'))
from irdump import dump_source


def hist(src):
    nodes, _, _ = dump_source(os.path.abspath(src))
    return collections.Counter(nd.cls for nd in nodes.values())


a = hist(sys.argv[1])
b = hist(sys.argv[2])
print("%-64s %8s %8s %8s" % ('kind', 'old', 'new', 'delta'))
for k in sorted(set(a) | set(b)):
    d = b.get(k, 0) - a.get(k, 0)
    if d:
        print("%-64s %8d %8d %+8d" % (k, a.get(k, 0), b.get(k, 0), d))
print("%-64s %8d %8d %+8d" % ('TOTAL', sum(a.values()), sum(b.values()),
                               sum(b.values()) - sum(a.values())))
