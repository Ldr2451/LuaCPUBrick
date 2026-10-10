"""Bulk-cost profile per phase: what the sim moves that ticks don't show.

Ticks count control steps; game wall pays for bulk -- array elements sized,
copied and cleared, string bytes found, sliced and concatenated. This counts
all of it, split at the parse boundary, so a game-only slowdown with flat
ticks points at its material instead of its logic.

Usage: python -u tools/chip/bulkprof.py --chip <a.ws> [--chip <b.ws>] <prog>
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "irrun"))
import irsims  # noqa: E402
from irsims import ChipRunner, _extract  # noqa: E402

CAP = 30000

_ORIGS = {}


def install(sim, acc):
    S = irsims.Sim
    if not _ORIGS:
        for name in ("_do_arr_resize", "_do_arr_copy", "_do_arr_clear",
                     "_do_arr_slice", "_do_concat", "_do_substr",
                     "_do_strfind"):
            _ORIGS[name] = getattr(S, name)
    o_resize, o_copy, o_clear = (_ORIGS["_do_arr_resize"],
                                 _ORIGS["_do_arr_copy"],
                                 _ORIGS["_do_arr_clear"])
    o_slice, o_concat = _ORIGS["_do_arr_slice"], _ORIGS["_do_concat"]
    o_substr, o_strfind = _ORIGS["_do_substr"], _ORIGS["_do_strfind"]

    def phase():
        return "run" if acc["parsed"] else "parse"

    def _do_arr_resize(self, nid, nq):
        aid = self._arr_id(nid)
        before = len(self._arr_list(aid))
        r = o_resize(self, nid, nq)
        elts = abs(len(self._arr_list(aid)) - before)
        acc[phase()]["resize_elts"] += elts
        acc[phase()]["resizes"] += 1
        by = acc[phase()].setdefault("by_array", {})
        e = by.setdefault(self._arr_name(nid), [0, 0, 0])
        e[0] += elts
        return r

    def _do_arr_copy(self, nid, nq):
        aid = self._arr_id(nid)
        r = o_copy(self, nid, nq)
        elts = len(self._arr_list(aid))
        acc[phase()]["copy_elts"] += elts
        by = acc[phase()].setdefault("by_array", {})
        e = by.setdefault(self._arr_name(nid), [0, 0, 0])
        e[1] += elts
        return r

    def _do_arr_clear(self, nid, nq):
        aid = self._arr_id(nid)
        elts = len(self._arr_list(aid))
        acc[phase()]["clear_elts"] += elts
        by = acc[phase()].setdefault("by_array", {})
        e = by.setdefault(self._arr_name(nid), [0, 0, 0])
        e[2] += elts
        return o_clear(self, nid, nq)

    def _do_arr_slice(self, nid, nq):
        r = o_slice(self, nid, nq)
        acc[phase()]["slices"] += 1
        return r

    def _do_concat(self, nid, nq):
        r = o_concat(self, nid, nq)
        acc[phase()]["concats"] += 1
        return r

    def _do_substr(self, nid, nq):
        r = o_substr(self, nid, nq)
        acc[phase()]["substrs"] += 1
        return r

    def _do_strfind(self, nid, nq):
        r = o_strfind(self, nid, nq)
        acc[phase()]["finds"] += 1
        return r

    def counted(nid, node, nq):
        acc[phase()]["gates"] += 1
        return o_exec(nid, node, nq)

    if not hasattr(sim, "_bulk_orig_exec"):
        sim._bulk_orig_exec = sim._exec_node
    # o_exec above may already be a wrapper from an earlier file; unwrap.
    o_exec = sim._bulk_orig_exec

    def counted(nid, node, nq):
        acc[phase()]["gates"] += 1
        return o_exec(nid, node, nq)

    S._do_arr_resize, S._do_arr_copy = _do_arr_resize, _do_arr_copy
    S._do_arr_clear, S._do_arr_slice = _do_arr_clear, _do_arr_slice
    S._do_concat, S._do_substr = _do_concat, _do_substr
    S._do_strfind = _do_strfind
    sim._exec_node = counted


def new_acc():
    return {"parsed": False,
            "parse": {"gates": 0, "resize_elts": 0, "resizes": 0,
                      "copy_elts": 0, "clear_elts": 0, "slices": 0,
                      "concats": 0, "substrs": 0, "finds": 0,
                      "ticks": 0},
            "run": {"gates": 0, "resize_elts": 0, "resizes": 0,
                    "copy_elts": 0, "clear_elts": 0, "slices": 0,
                    "concats": 0, "substrs": 0, "finds": 0,
                    "ticks": 0}}


def main(argv):
    chips = []
    files = []
    i = 0
    while i < len(argv):
        if argv[i] == "--chip":
            chips.append(argv[i + 1])
            i += 2
            continue
        files.append(argv[i])
        i += 1
    chips = chips or [os.path.join(ROOT, "lua.ws")]
    for c in chips:
        runner = ChipRunner(os.path.abspath(c))
        for f in files:
            src = open(f, encoding="utf-8").read()
            acc = new_acc()
            install(runner.sim, acc)
            sim = runner.sim
            sim.reset()
            labels = {}
            for nid, node in sim.nodes.items():
                label = _extract(node.props.get("_label", ("raw", "")))
                if isinstance(label, str):
                    labels[label] = nid
            prog_ok = labels.get("progOkV")

            def watch(sim_now, tick):
                if not acc["parsed"] and sim_now.vars.get(prog_ok):
                    acc["parsed"] = True
                (acc["run"] if acc["parsed"] else acc["parse"])["ticks"] = tick + 1

            sim.inputs = {"program": src, "run": True}
            sim.run(CAP, on_tick=watch)
            for ph in ("parse", "run"):
                d = acc[ph]
                print("%-16s %-5s ticks=%-5d gates=%-8d resizes=%-4d "
                      "rsz_elts=%-9d copy_elts=%-9d clr_elts=%-8d "
                      "concats=%-4d substrs=%-4d finds=%-5d" % (
                          os.path.basename(c), ph, d["ticks"], d["gates"],
                          d["resizes"], d["resize_elts"], d["copy_elts"],
                          d["clear_elts"], d["concats"], d["substrs"],
                          d["finds"]))
                ranked = sorted(d.get("by_array", {}).items(),
                                key=lambda kv: -(kv[1][0] + kv[1][1] + kv[1][2]))[:12]
                for name, (rz, cp, cl) in ranked:
                    print("    %-22s rsz=%-9d copy=%-9d clr=%-9d" % (
                        name, rz, cp, cl))
            for name, fn in _ORIGS.items():
                setattr(irsims.Sim, name, fn)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
