"""Chain/probe trace filter: show only ticks where the chip does work.

Usage: python -u tools/filttrace.py <tracefile> [more names]
Reads the trace lines ("t123  cDirty=... rcOn=...") and prints the ticks
where any activity flag is True, plus the check-result summary lines.
Handles the UTF-16 redirect PowerShell leaves behind.
"""
import os
import re
import sys

NAMES = ["rcOn", "pending", "commitR", "commitQ", "arming", "armingS",
         "polyOn", "sOn", "erasing", "erDone", "wasPaint", "cDirty",
         "brightRC", "erArm", "fullErase", "recompFrame"]


def main():
    lo, hi = (0, 10 ** 9)
    files = []
    for a in sys.argv[1:]:
        if a.startswith("--window="):
            lo, hi = (int(x) for x in a[9:].split(":"))
        else:
            files.append(a)
    for path in files:
        d = open(path, "rb").read()
        raw = (d.decode("utf-16", errors="ignore")
               if d[:2] in (b"\xff\xfe", b"\xfe\xff") else
               d.decode("utf-8", errors="ignore"))
        for line in raw.splitlines():
            if not line.startswith("t") or "  " not in line[:12]:
                if ("FAIL" in line or "OK" in line[:40]
                        or "wall movement" in line
                        or "motion diffs" in line
                        or "edges " in line):
                    print(line[:400])
                continue
            t = int(line[1:line.index(" ")])
            if t < lo:
                continue
            if t > hi:
                continue
            if any(re.search(r"(?:^| )%s=True" % n, line) for n in NAMES):
                print(line[:400])


if __name__ == "__main__":
    main()
