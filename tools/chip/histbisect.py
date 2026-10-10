"""Parse/run cost per revision, for one program, across the git history.

The old chip's game numbers imply sim ticks BELOW tag 1.0's (5441 reported at
100/60 = 3265 parse ticks, against 1.0's measured 3836), so some revision
already ran faster than the tag does. This measures a spread of revisions on
one program so the minimum can be read off, and the revision that owns it
diffed. Each .ws is a blob written to a temp file and run with parsesplit.

  python -u tools/chip/histbisect.py <rev> [<rev> ...] [-- prog.lua]
"""
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "irrun"))

PROG = os.path.join(os.path.dirname(HERE), "..", "..", "bench-exact.lua")
if not os.path.exists(PROG):
    PROG = r"C:\Users\Alessandro\AppData\Local\Temp\opencode\bench-exact.lua"


def blob(rev):
    p = subprocess.run(["git", "cat-file", "blob", "%s:lua.ws" % rev],
                       cwd=ROOT, capture_output=True)
    if p.returncode:
        return None
    return p.stdout.decode("utf-8")


def main(argv):
    revs = []
    prog = PROG
    i = 0
    while i < len(argv):
        if argv[i] == "--":
            prog = argv[i + 1]
            i += 2
            continue
        revs.append(argv[i])
        i += 1
    from parsesplit import main as psmain  # noqa: E402
    chips = []
    tmpdir = tempfile.mkdtemp(prefix="histbisect")
    for rev in revs:
        src = blob(rev)
        if src is None:
            print("%-10s MISSING" % rev)
            continue
        path = os.path.join(tmpdir, "%s.ws" % rev.replace("/", "_"))
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(src)
        chips.append(path)
        chips.append(rev)          # label: parsesplit prints basename
    if chips:
        psmain(chips + [prog])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
