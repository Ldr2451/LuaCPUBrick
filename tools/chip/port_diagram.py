"""The README's IO diagram, generated from the chip's port declarations -- and
checked, so it cannot go stale silently.

A picture of the interface is the first thing a human reads, and a hand-typed one
lies the moment a port is added or removed.  This reads the @left/@right lines out
of lua.ws and draws the chip as a box on a line that runs from every input to
every output -- names only, because a column of descriptions beside every port
turns the picture into a table and stops it being a picture:

    python -u tools/chip/port_diagram.py            # print it
    python -u tools/chip/port_diagram.py --check    # is the README current?

The prose about what the ports MEAN lives under the picture in the README, where
it can be written properly instead of squeezed into a column.
"""
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
WS = os.path.join(ROOT, "lua.ws")
README = os.path.join(ROOT, "README.md")

NAME_W = 9
BOX_W = 13
BOX_ROWS = 3
LABEL = "   Lua 5.5   "
GAP = 2


def ports():
    ws = io.open(WS, encoding="utf-8").read()
    found = re.findall(r"@(left|right) (in|out) (\w+) ?: ?([^\n]*)", ws)
    return ([p[2] for p in found if p[0] == "left" and p[1] == "in"],
            [p[2] for p in found if p[0] == "right" and p[1] == "out"])


def diagram():
    IN, OUT = ports()
    n = max(len(IN), len(OUT))
    top = n // 2 - BOX_ROWS // 2

    def bus(i):
        if top <= i < top + BOX_ROWS:
            if i == top or i == top + BOX_ROWS - 1:
                return "+" + "-" * (BOX_W - 2) + "+"
            return "|" + LABEL + "|"
        if top - 1 <= i <= top + BOX_ROWS:
            return "|" + " " * (BOX_W - 2) + "|"
        return "-" * BOX_W

    lines = []
    for i in range(n):
        left = "{:<{w}}".format(IN[i] if i < len(IN) else "", w=NAME_W)
        right = OUT[i] if i < len(OUT) else ""
        lines.append("%s %s%s%s %s" % (left, "-" * GAP, bus(i), "-" * GAP,
                                        right))
    return "\n".join(lines), IN, OUT


def main():
    art, IN, OUT = diagram()
    if "--check" in sys.argv:
        readme = io.open(README, encoding="utf-8").read()
        if art not in readme:
            print("FAIL readme-port-diagram: the README's picture does not match "
                  "the ports.  Re-run without --check and paste it in.")
            return 1
        print("PASS readme-port-diagram")
        return 0
    print(art)
    print("\n(%d inputs, %d outputs)" % (len(IN), len(OUT)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
