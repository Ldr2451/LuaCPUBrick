"""The README's IO diagram, generated from the chip's port declarations -- and
checked, so it cannot go stale silently.

A picture of the interface is the first thing a human reads, and a hand-typed one
lies the moment a port is added or removed.  This reads the @left/@right lines out
of lua.ws, lays the ports out as two columns either side of a box, and with
--check it re-derives the picture and fails if the README's copy differs:

    python -u tools/chip/port_diagram.py            # print it
    python -u tools/chip/port_diagram.py --check    # is the README current?

The boxes get three rows of their own in the middle with the port columns blank,
so the chip reads as sitting in the flow rather than as a row that repeats a port
name three times.
"""
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
WS = os.path.join(ROOT, "lua.ws")
README = os.path.join(ROOT, "README.md")

# what a program calls it, where that is not simply the port name
LUA_NAME = {
    "program": "the source text", "run": "high runs, low stops",
    "inNum0": "inNum0 .. inNum3", "inStr0": "inStr0 .. inStr1",
    "inVec": "invecx .. invecz", "inArr": "inarr(i), inarr(i,k)",
    "inInt0": "a whole number",
    "log": "print, io.write", "outNum0": "outNum0 .. outNum3",
    "outStr0": "outStr0 .. outStr1", "outInt0": "a whole number",
    "outArr": "outarr(i, v, ...)", "outVec": "outvec(x, y, z)",
    "result": "the top-level return", "err": "runtime error text",
    "progOk": "false if it did not compile", "busy": "true while it works",
}
NAME_W, DESC_W, GAP, BOX_W = 10, 20, 4, 13
LABEL = "  Lua 5.5  "


def ports():
    ws = io.open(WS, encoding="utf-8").read()
    found = re.findall(r"@(left|right) (in|out) (\w+) ?: ?([^\n]*)", ws)
    return ([p[2] for p in found if p[0] == "left" and p[1] == "in"],
            [p[2] for p in found if p[0] == "right" and p[1] == "out"])


def diagram():
    IN, OUT = ports()
    L = NAME_W + 1 + DESC_W
    R = NAME_W + 1 + 25
    n = max(len(IN), len(OUT))
    mid = n // 2
    box_rows = {mid, mid + 1, mid + 2}

    def row(li, ri, box=None):
        ln = IN[li] if li is not None and li < len(IN) else ""
        ld = LUA_NAME.get(ln, "") if ln else ""
        rn = OUT[ri] if ri is not None and ri < len(OUT) else ""
        rd = LUA_NAME.get(rn, "") if rn else ""
        left = "{:<{w}} {:<{d}}".format(ln, ld, w=NAME_W, d=DESC_W)
        right = "{:<{w}} {}".format(rn, rd, w=NAME_W)
        tail = "-" * GAP if box else " " * GAP
        return "%s %s%s%s %s" % (left, "-" * GAP, box or "", tail, right)

    width = L + GAP + BOX_W + GAP + 1 + R
    out = [" " * width]
    li = ri = 0
    for r in range(n + 3):
        if r in box_rows:
            out.append(row(None, None,
                           box=LABEL if r - mid == 1 else "-" * BOX_W))
            continue
        out.append(row(li, ri))
        li += 1
        ri += 1
    out.append(" " * width)
    return "\n".join(out)


def main():
    art = diagram()
    if "--check" in sys.argv:
        readme = io.open(README, encoding="utf-8").read()
        if art not in readme:
            print("FAIL readme-port-diagram: the README's picture does not match "
                  "the ports.  Re-run without --check and paste it in.")
            return 1
        print("PASS readme-port-diagram")
        return 0
    print(art)
    IN, OUT = ports()
    print("\n(%d inputs, %d outputs)" % (len(IN), len(OUT)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
