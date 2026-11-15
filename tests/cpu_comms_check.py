"""The CPU-to-CPU handoff: one program's outNumArr becomes another's inNumArr.

The old model kept a program's port values in its own storage, so the
handoff was a list the harness passed around. The official simulator keeps
containers private: the OUT array's CONTENTS come back from the element
probes the driver appended (`_arr_on` turns them on, and only the probed
head and tail answer -- the middle is what vmReset left, by construction),
and the IN side is fed back at `new` as a full port set. Same story the
in-game host tells: CPU A writes a request on its out array, the host wires
it to CPU B's in array, CPU B reads it and answers on its own out array.

Run: python -u tests/cpu_comms_check.py   (exit 0 = all green)
"""
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

from simdrv_sim import share_dump, sim_from_dump  # noqa: E402
from timing import Elapsed  # noqa: E402


def run_cpu(name, sim, src, inNumArr=None, ticks=1200):
    sim.reset()
    # the case reads the OUT array's contents: ask for the element probes
    sim._arr_on = True
    sim.inputs = {"program": src, "run": True}
    if inNumArr is not None:
        sim.inputs["inNumArr"] = list(inNumArr)
    result = sim.run(ticks)
    og = result.get("outGlobals") or {}
    if not sim.finished:
        raise RuntimeError("%s did not finish: %s"
                           % (name, og.get("runErrors", "")))
    if any(l.startswith("err:")
           for l in (og.get("progDebug") or "").splitlines()) or og.get("runErrors"):
        raise RuntimeError("%s failed: %s" % (name, og.get("runErrors", "")))
    result["outNumArr"] = og.get("outNumArr") or []
    print("%-18s OK log=%r" % (name, result.get("log", "")), flush=True)
    return result


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def main():
    with tempfile.NamedTemporaryFile(suffix=".brz", delete=False) as f:
        dump_path = f.name
    try:
        share_dump(os.path.join(ROOT, "lua.ws"), dump_path)
        # two machines: separate children, separate graphs, like two CPUs
        sim_a = sim_from_dump(dump_path)
        sim_b = sim_from_dump(dump_path)

        isolated = run_cpu("cpu-b-isolated", sim_b, "print(inNumArr(1))")
        require(isolated["log"] == "nil\n", "CPU B inherited CPU A state")

        # the outputs are calls now, so a program cannot read one back: the
        # check is what the OUTSIDE reader sees on the ports, which is the
        # thing that actually has to work
        self_out = run_cpu(
            "self-output", sim_a,
            "outNum(1, 5) outStr(1, 'self') outNum(4, 7) "
            "outNumArr(1, 41) print('A3')")
        require(self_out["log"] == "A3\n", "the program did not finish")
        og = self_out["outGlobals"]
        require(og["outNum1"] == 5.0, "outNum1 was not written")
        require(og["outStr1"] == "self", "outStr1 was not written")
        require(og["outNum4"] == 7.0, "outNum4 was not written")
        require(self_out["outNumArr"][0] == 41.0, "outNumArr[1] was not written")

        self_in = run_cpu(
            "self-input", sim_a,
            "print(inNumArr(1), inNumArr(16385))", self_out["outNumArr"])
        require(self_in["log"] == "41.0\tnil\n",
                "outNumArr-to-inNumArr handoff failed")

        request = run_cpu(
            "cpu-a-request", sim_a,
            "outNumArr(1, 7) outNumArr(2, 11) print('A', 8)")
        require(request["outNumArr"][:2] == [7.0, 11.0],
                "CPU A request mismatch")

        response = run_cpu(
            "cpu-b-response", sim_b,
            "local x = inNumArr(1) local y = inNumArr(2) "
            "outNumArr(1, x + y) print('B', x, y, x + y)",
            request["outNumArr"])
        require(response["log"] == "B\t7.0\t11.0\t18.0\n",
                "CPU B response mismatch")
        require(response["outNumArr"][0] == 18.0, "CPU B reply mismatch")

        reply = run_cpu(
            "cpu-a-reply", sim_a,
            "outNum(1, inNumArr(1)) print('A2', inNumArr(1), inNumArr(1) * 2)",
            response["outNumArr"])
        require(reply["log"] == "A2\t18.0\t36.0\n", "CPU A reply mismatch")
        require(reply["outGlobals"]["outNum1"] == 18.0,
                "CPU A did not retain the reply")
    finally:
        os.unlink(dump_path)
    print("cpu_comms_check: OK", flush=True)
    return 0


if __name__ == "__main__":
    with Elapsed("cpu_comms_check"):
        sys.exit(main())
