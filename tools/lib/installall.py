"""Install every library piece from lib/constmap.txt, minified and renamed.

  python -u tools/lib/installall.py            # every piece
  python -u tools/lib/installall.py LIB_str_gsub   # just one

One command per call is the rule, so this is a script rather than a loop typed
at the prompt.  The map comes from lib/constmap.txt and not from matching
content: a master's text stops matching its const the moment it is installed,
which is the point of installing it, so a content match works exactly once.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
LIBCONST = os.path.join(HERE, "libconst.py")


def read_map():
    out = []
    with open(os.path.join(ROOT, "lib", "constmap.txt"),
              encoding="utf-8") as f:
        for line in f:
            line = line.split("#")[0].strip()
            if line:
                parts = line.split()
                out.append((parts[0], parts[1]))
    return out


def main(argv):
    only = set(argv)
    rc = 0
    for const, master in read_map():
        if only and const not in only:
            continue
        path = os.path.join(ROOT, master)
        r = subprocess.run([sys.executable, "-u", LIBCONST, path, const,
                            "--install"], capture_output=True, text=True,
                           cwd=ROOT)
        sys.stdout.write(r.stdout)
        sys.stderr.write(r.stderr)
        if r.returncode:
            rc = r.returncode
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))