"""Boot latency: ticks to FIRST output, which is the parser and nothing else.

Everything a program does before its first print is lexing and parsing, so
ticks-to-first-output measures the parser and not the VM.  It is the number
AGENTS.md quotes for demo.lua (2,994), and it is the one to re-measure after
anything that touches the chip, because a chip on the parse path costs a boot
tick even when every other tick count is unchanged.

Ticks are deterministic, so one run per chip is enough and two chips can be
compared from two processes.  Wall clock cannot be (drift alone reads 1.66ms as
2.22ms), which is why this prints ticks and not seconds.

  python -u tools/chip/bootprobe.py demo.lua
  python -u tools/chip/bootprobe.py demo.lua --chip C:/path/to/other/lua.ws

Note a file over the ~4 KB source buffer cannot be measured at all, and a
program with more than 32 live locals reads them as globals -- both produce "no
output" rather than a slow number, so read a miss as a miss, not as a latency.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "irrun"))
from irsims import ChipRunner  # noqa: E402

CAP = 20000


def main(argv):
    chip = os.path.join(ROOT, "lua.ws")
    files = []
    i = 0
    while i < len(argv):
        if argv[i] == "--chip":
            chip = argv[i + 1]
            i += 2
            continue
        files.append(argv[i])
        i += 1
    files = files or [os.path.join(ROOT, "demo.lua")]

    runner = ChipRunner(os.path.abspath(chip))
    for f in files:
        src = open(f, encoding="utf-8").read()
        seen = {}

        def watch(sim, tick, seen=seen):
            if "first" not in seen and sim.log:
                seen["first"] = tick

        runner.sim.reset()
        runner.sim.inputs = {"program": src, "run": True}
        runner.sim.run(CAP, on_tick=watch)
        print("%-16s chars=%-6d first_output=%s"
              % (os.path.basename(f), len(src), seen.get("first", "NEVER")))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))