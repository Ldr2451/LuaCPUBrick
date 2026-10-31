"""Does a one-point shape walk out, or break the chip?

The protocol's thinnest shape is a single point: one triple plus the
terminator.  A fill of one point covers no span; a stroke of one point is
the chip's single pixel (under two points there is no segment).  Either way the
walks must scan out and fall, the commit must erase what the slot used to
hold and repaint its new nothing, and the slot machinery must stay alive
for the NEXT push.  A walk that never ends, a slot that keeps its old
pixels through the replacement, or a later push that never lands is the
bug this probe catches.

   python -u extras/screen/ptprobe.py [screen.ws]
   python -u extras/screen/ptprobe.py trace   # per-tick state window
"""
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "irrun"))
sys.path.insert(0, HERE)

from irsims import share_dump, _extract  # noqa: E402
from painttest import fresh_sim, slide3, poly_pixels, col  # noqa
from watchdog import make_watch

WS = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 \
    and not sys.argv[1].startswith("-") else os.path.join(HERE, "screen.ws")
TRACE = [200, 340] if "trace" in sys.argv[2:] else None
RED = (1.0, 0.0, 0.0, 1.0)
BLACK = (0.0, 0.0, 0.0, 1.0)
ONE = [0.0, 0.0, 0.0]
SQ = [4.0, 4.0, 0.0, 12.0, 4.0, 0.0, 12.0, 12.0, 0.0, 4.0, 12.0, 0.0]


def main():
    fd, dump = tempfile.mkstemp(suffix=".pkl")
    os.close(fd)
    try:
        share_dump(WS, dump)
        print("chip built from %s" % WS)
        sim, gids, _polyon, _son, pts_aid, cols_aid = fresh_sim(dump)
        wd = make_watch(sim)

        def var_id(name):
            for nid, nd in sim.nodes.items():
                if _extract(nd.props.get("_label", ("raw", ""))) == name:
                    return nid
            raise RuntimeError("no var %r" % name)

        sim.inputs = {"shapePoints": [0.0] * 32, "shapeColors": [],
                      "pushShape": False, "shapeWireMode": False,
                      "shapeId": 0.0, "drawAllShapes": False,
                      "clearAllShapes": False,
                      "shapePosition": (0.0, 0.0, 0.0),
                      "shapeRotation": (0.0, 0.0, 0.0),
                      "shapeScale": (0.0, 0.0, 0.0),
                      "parentShapeId": 0.0, "brightness": 100.0,
                      "addToShapeInTicks": 0.0}
        sim.run(1)
        sim.inputs = {k: v for k, v in sim.inputs.items()
                      if k != "shapePoints"}

        def stage(t, sid, pts, cols, wire, draw):
            p = {t: {"shapePoints": list(pts), "shapeColors": list(cols),
                     "shapeWireMode": bool(wire), "shapeId": float(sid),
                     "shapePosition": (0.0, 0.0, 0.0),
                     "shapeRotation": (0.0, 0.0, 0.0),
                     "shapeScale": (0.0, 0.0, 0.0),
                     "parentShapeId": 0.0, "addToShapeInTicks": 0.0},
                 t + 2: {"pushShape": True},
                 t + 4: {"pushShape": False}}
            if draw:
                p[t + 6] = {"drawAllShapes": True}
                p[t + 8] = {"drawAllShapes": False}
            return p

        plan = {}
        # slot 1: a red square
        plan.update(stage(10, 1, SQ, [RED] * 4, False, True))
        # replace it with the thinnest shape the protocol sends: one point
        plan.update(stage(150, 1, ONE, [RED], False, True))
        # the slot must stay usable after that: the square comes back
        plan.update(stage(290, 1, SQ, [RED] * 4, False, True))
        # a one-point STROKE in a slot: one pixel, never a residue
        plan.update(stage(430, 1, ONE, [RED], True, True))
        # and the whole path again after the stroke walk
        plan.update(stage(570, 1, SQ, [RED] * 4, False, True))

        trace = TRACE
        if trace:
            fn = ["rcOn", "erasing", "erDone", "wasPaint", "arming",
                  "polyOn", "sOn", "recompFrame", "eraseOK", "fromSlot"]
            vids = {n: var_id(n) for n in fn}
            er_row = var_id("erRow")

            def trace_watch(sn, tick):
                if tick in plan:
                    step = dict(plan[tick])
                    if "shapePoints" in step:
                        slide3(sn, pts_aid, cols_aid, step.pop("shapePoints"),
                               step.pop("shapeColors", None))
                    sn.inputs = dict(sn.inputs, **step)
                if trace[0] <= tick <= trace[1]:
                    print("t%-4d " % tick + " ".join(
                        "%s=%d" % (n, int(bool(sn.vars.get(vids[n]))))
                        for n in fn) + " erRow=%s" % sn.vars.get(er_row))

            sim.run(trace[1] + 5, on_tick=trace_watch)
            return 0

        snaps = {95: "after slot 1's square", 235: "one-point fill commit",
                 375: "square again", 515: "one-point stroke commit",
                 655: "square after the stroke walk"}
        walls = {}

        def watch(sn, tick):
            wd(sn, tick)
            if tick in plan:
                step = dict(plan[tick])
                if "shapePoints" in step:
                    slide3(sn, pts_aid, cols_aid, step.pop("shapePoints"),
                           step.pop("shapeColors", None))
                sn.inputs = dict(sn.inputs, **step)
            if tick in snaps:
                walls[tick] = [col(sn, gids, i) for i in range(4096)]

        sim.run(700, on_tick=watch)

        sq_px = set(poly_pixels([SQ[i] for i in range(len(SQ))
                                 if i % 3 != 2]))
        bad_total = 0

        for tick, why in sorted((t, snaps[t]) for t in walls):
            wall = walls[tick]
            if why == "one-point stroke commit":
                want = {0}
            else:
                want = sq_px if why != "one-point fill commit" else set()
            bad = [i for i in range(4096)
                   if not (wall[i] == RED if i in want else
                           wall[i] == BLACK)]
            bad_total += len(bad)
            print("  t=%-4d %-32s bad=%-4d %s"
                  % (tick, why, len(bad), "BUG" if bad else "ok"))
            if bad:
                rows = sorted({i // 64 for i in bad})
                vals = sorted({wall[i] for i in bad})
                print("      rows %r first %r" % (rows[:6], bad[:4]))
                print("      vals %r seen %r"
                      % (vals[:4], [(i, wall[i]) for i in bad[:3]]))
        for f in wd.failures():
            print("WATCH: " + f)
        print("RESULT: %s" % ("BUG" if bad_total or wd.failures() else "ok"))
        return 1 if (bad_total or wd.failures()) else 0
    finally:
        os.unlink(dump)


if __name__ == "__main__":
    sys.exit(main())
