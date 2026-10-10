"""What does the chip see when an input's driving gate is deleted?

The in-game report: a scalar input works when the variable wired to it is
UPDATED, but keeps its old value when that variable gate is DELETED -- as if
the wire were still there.  Expected was that the input falls back to zero.

Whether that is ours to fix turns on one thing: does the PORT itself lose
the value when nothing drives it?  The two possible engine behaviours want
opposite fixes.

  (a) the port RETAINS its last value -> the chip cannot see the wire is
      gone.  "Driven with the same value" and "not driven" are the same
      observation: one value, no edge.  No reading of the port, at any
      frequency, can tell them apart, so no chip change can help.

  (b) the port RESETS to its default but raises no edge -> the chip can see
      it, but only by RE-READING the port rather than waiting to be told.
      That is a fix on our side.

So this measures it as strongly as the chip can.  The chip already re-reads
all six input ports at parse completion -- `on goParse2` seeds the latches
from the ports, precisely so a value present before the chip started still
reaches the program (see tests/host_compat_check.py).  So the probe holds
the input at 7, then removes it from the input map ENTIRELY (exactly what a
deleted gate does: the port stops being written, rather than being written a
new value) and delivers a second program that prints the input.  Whatever
that program prints is what the port held, read at full strength and not
through a latch.

An earlier version of this probe failed its own self-check: the first
program halts, `Sim.finished` latches and the sim stops ticking, so the
second program was never parsed and the probe read nothing at all.  A probe
that reports the port's value must keep the chip running until it has one,
which is why the first program loops forever and the drop is delivered
mid-run by an on_tick hook.

  python -u tools/chip/inputdrop.py
"""
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "irrun"))

from irsims import ChipRunner, share_dump, sim_from_dump  # noqa: E402

KEEP = "local i = 0 while true do i = i + 1 end"
ASK = "print('v2', inNum1)"
DROP_AT = 400
CAP = 4000


def main():
    with tempfile.NamedTemporaryFile(suffix=".pkl", delete=False) as f:
        dump_path = f.name
    try:
        share_dump(os.path.join(ROOT, "lua.ws"), dump_path)
        runner = ChipRunner(sim=sim_from_dump(dump_path))
        sim = runner.sim
        sim.host_baselines = True      # the host observed in game
        sim.keep_going = True
        sim.reset()
        sim.inputs = {"program": KEEP, "run": True, "inNum1": 7.0}

        dropped = [False]

        def on_tick(sim_now, tick):
            # At DROP_AT the driving gate is deleted: the port is simply no
            # longer written (its key leaves the input map) and a second
            # program asks what the input reads as now.
            if tick == DROP_AT:
                nxt = dict(sim_now.inputs)
                nxt.pop("inNum1", None)
                sim_now.inputs = nxt
                sim_now.inputs = dict(nxt, program=ASK)
                dropped[0] = True

        sim.run(CAP, on_tick=on_tick)
        log = sim.log
        og = sim._out_globals()
        print("input driven with 7, deleted at tick %d" % DROP_AT)
        print("log=%r" % log)
        print("progDebug=%r" % ((og.get("progDebug") or "")[-120:],))
        if not dropped[0]:
            print("\nRESULT: the drop never fired -- the probe is broken.")
            return 2
        if "v2" not in log:
            print("\nRESULT: the second program never ran, so the probe")
            print("never read the port again.  It says nothing either way.")
            return 2
        if "7" in log.split("v2", 1)[1]:
            print("\nRESULT: the port RETAINED 7 with nothing driving it, and the")
            print("chip's strongest read -- a fresh parse seeding every input")
            print("latch from the ports -- still saw 7.  A deleted gate and a")
            print("gate holding the same value are the SAME observation to the")
            print("chip: one value, no edge.  There is no chip-side fix, and")
            print("reading the ports every tick would read the same 7.")
            return 0
        print("\nRESULT: the port lost the value, so the chip CAN see it -- by")
        print("re-reading the port rather than waiting for an edge.")
        return 1
    finally:
        os.unlink(dump_path)


if __name__ == "__main__":
    sys.exit(main())
