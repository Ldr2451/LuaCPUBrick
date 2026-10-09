import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "irrun"))

from irsims import ChipRunner, share_dump, sim_from_dump
from timing import Elapsed


def run_cpu(name, runner, src, inNumArr=None, ticks=1200):
    inputs = {"inNumArr": list(inNumArr)} if inNumArr is not None else None
    result = runner.run(src, ticks, inputs)
    og = result.get("outGlobals", {})
    if not runner.sim.finished:
        raise RuntimeError("%s did not finish: %s" % (name, og.get("runErrors", "")))
    if any(l.startswith("err:") for l in (og.get("progDebug") or "").splitlines()) or og.get("runErrors"):
        raise RuntimeError("%s failed: %s" % (name, og.get("runErrors", "")))
    print("%-18s OK log=%r" % (name, result.get("log", "")), flush=True)
    return result


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def main():
    ws_path = os.path.join(ROOT, "lua.ws")
    with tempfile.NamedTemporaryFile(suffix=".pkl", delete=False) as f:
        dump_path = f.name
    try:
        share_dump(ws_path, dump_path)
        cpu_a = ChipRunner(sim=sim_from_dump(dump_path))
        cpu_b = ChipRunner(sim=sim_from_dump(dump_path))

        isolated = run_cpu("cpu-b-isolated", cpu_b, "print(inNumArr(1))")
        require(isolated["log"] == "nil\n", "CPU B inherited CPU A state")

        # the outputs are calls now, so a program cannot read one back: the
        # check is what the OUTSIDE reader sees on the ports, which is the thing
        # that actually has to work
        self_out = run_cpu(
            "self-output", cpu_a,
            "outNum(1, 5) outStr(1, 'self') outNum(4, 7) "
            "outNumArr(1, 41) print('A3')")
        require(self_out["log"] == "A3\n", "the program did not finish")
        require(self_out["outGlobals"]["outNum1"] == 5.0, "outNum1 was not written")
        require(self_out["outGlobals"]["outStr1"] == "self", "outStr1 was not written")
        require(self_out["outGlobals"]["outNum4"] == 7.0, "outNum4 was not written")
        require(self_out["outNumArr"][0] == 41.0, "outNumArr[1] was not written")

        self_in = run_cpu(
            "self-input", cpu_a,
            "print(inNumArr(1), inNumArr(16385))", self_out["outNumArr"])
        require(self_in["log"] == "41.0\tnil\n", "outNumArr-to-inNumArr handoff failed")

        request = run_cpu(
            "cpu-a-request", cpu_a,
            "outNumArr(1, 7) outNumArr(2, 11) print('A', 8)")
        require(request["outNumArr"][:2] == [7.0, 11.0], "CPU A request mismatch")

        response = run_cpu(
            "cpu-b-response", cpu_b,
            "local x = inNumArr(1) local y = inNumArr(2) "
            "outNumArr(1, x + y) print('B', x, y, x + y)",
            request["outNumArr"])
        require(response["log"] == "B\t7.0\t11.0\t18.0\n",
                "CPU B response mismatch")
        require(response["outNumArr"][0] == 18.0, "CPU B reply mismatch")

        reply = run_cpu(
            "cpu-a-reply", cpu_a,
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
