"""CPU-only probe for the in-game tour stall (lua.ws side only).

Runs extras/cpu-screen-connector/sample-programs/tour.lua in the IR sim with
no screen/connector attached and reports both error channels the chip has:
runErrors (errV, runtime) and progDebug (progDebugV, compile-time `err:`),
plus the busy components (jobBusy, progOkV, vmHalted), parse flags, and log
growth over time. A stall with busy true and neither channel reporting is a
different finding from a rejected program the progDebug port did report.

  python -u tools/chip/tourprobe.py [ticks]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "irrun"))

from irsims import ChipRunner  # noqa: E402

TOUR = os.path.join(ROOT, "extras", "cpu-screen-connector",
                    "sample-programs", "tour.lua")


def main(argv):
    budget = int(argv[0]) if argv else 25000
    src = open(TOUR, encoding="utf-8").read()
    print("tour chars: %d" % len(src), flush=True)
    runner = ChipRunner(os.path.join(ROOT, "lua.ws"))
    print("chip built", flush=True)
    sim = runner.sim
    sim.reset()
    sim.inputs = {"program": src, "run": True}
    events = []
    last_lines = 0
    last_debug = ""
    last_err = ""

    def watch(s, tick):
        nonlocal last_lines, last_debug, last_err
        lines = s.log.count("\n")
        if lines != last_lines:
            events.append((tick, "log-lines=%d log=%r"
                           % (lines, s.log[-120:])))
            last_lines = lines
        dbg = s.chip_var("progDebugV", "") or ""
        if dbg != last_debug:
            for line in dbg.splitlines():
                if line not in last_debug:
                    events.append((tick, "progDebug: %r" % line[:160]))
            last_debug = dbg
        err = s.chip_var("errV", "") or ""
        if err != last_err:
            events.append((tick, "runErrors: %r" % err[:200]))
            last_err = err
        if len(events) > 40:
            pass

    port_events = []
    last_ports = {}

    def watch_ports(s, tick):
        nonlocal last_ports
        og = s._out_globals()
        for key in ("outNum1", "outNum2", "outNum3", "outNum4"):
            v = og.get(key, 0.0)
            if v != last_ports.get(key, 0.0):
                port_events.append((tick, "%s=%r" % (key, v)))
                last_ports[key] = v
        watch(s, tick)

    out = sim.run(budget, on_tick=watch_ports)
    og = out.get("outGlobals", {})
    print("ticks: %d finished: %r" % (budget, sim.finished), flush=True)
    print("log: %r" % (sim.log[:600],), flush=True)
    print("runErrors: %r" % (og.get("runErrors", ""),), flush=True)
    print("progDebug: %r" % (og.get("progDebug", "")[:800],), flush=True)
    print("busy: %r" % (og.get("busy", None),), flush=True)
    for f in ("lerr", "lerrMsg", "perr", "perrMsg", "progOkV",
              "jobBusy", "vmHalted", "pDone", "result"):
        print("  %-9s %r" % (f, sim.chip_var(f, "<absent>")), flush=True)
    print("events (%d):" % len(events), flush=True)
    for tick, msg in events[:40]:
        print("  t=%-6d %s" % (tick, msg), flush=True)
    print("port edges (%d, push/draw/clear):" % len(port_events), flush=True)
    for tick, msg in port_events[:40]:
        print("  t=%-6d %s" % (tick, msg), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
