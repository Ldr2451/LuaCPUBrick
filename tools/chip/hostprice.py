"""Host-priced op census per commit: resizes/clears the sim calls free.

Usage: python -u tools/chip/hostprice.py <rev> [<rev> ...]
Prints per rev: resize count, clear count, and key size consts.
Pure text over git blobs: seconds, no chip compile.
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))))


def blob(rev):
    proc = subprocess.run(
        ["git", "cat-file", "blob", "%s:lua.ws" % rev],
        cwd=ROOT, capture_output=True, check=True)
    return proc.stdout.decode("utf-8")


def main(argv):
    for rev in argv:
        try:
            src = blob(rev)
        except subprocess.CalledProcessError:
            print("%-10s MISSING" % rev)
            continue
        resizes = len(re.findall(r"\.resize\(", src))
        clears = len(re.findall(r"\.clear\(\)", src))
        consts = {}
        for name in ("VREGS", "ARR_SLOTS", "PAT_WALKS", "MAX_VA",
                     "MAX_HEAP", "MAX_FUNCS", "MAX_TABLES", "PAT_STACK"):
            m = re.search(r"const %s = (\d+)" % name, src)
            consts[name] = m.group(1) if m else "-"
        print("%-10s resize=%-4d clear=%-4d %s" % (
            rev, resizes, clears,
            " ".join("%s=%s" % kv for kv in sorted(consts.items()))))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
