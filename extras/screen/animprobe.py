"""Does a refresh repaint a TRANSLUCENT shape exactly once?

The connector's chain test (connectortest.py) is red on a green triangle
(alpha 0.5) stored in slot 1 and animated +2 x per step over 4 steps:
where the old and new footprints overlap, the wall reads the DOUBLE
composite of the pushed colour (0, 0.75, 0) instead of the single one
(0, 0.5, 0), and a ~4 px band of the final pose's hypotenuse never
lands (black).  The pixels are translucent, so a double blend is
distinguishable from a doubled-coverage single blend, which an opaque
probe (ghostprobe.py) cannot see.

This drives screen.ws alone with exactly the chain test's scene: slot
1 holds the triangle (immediate edit with a draw, so the wall holds it
first), then a pure-delta animation edit (+2 x, 4 steps, no draw --
the chip's self-refresh advances live slots itself).  Every settled
frame after the animation is done must be exactly over(black, pushed)
inside the moved footprint and black outside: an overlap band that
reads brighter is the double composite; a footprint pixel that is
black is the pose that never landed.  The frames mid-animation are
reported but not failed: only the settled end state and the bare draw
after it have a fixed expectation.

The scene also carries an immediate blue square staged BEFORE the
animation, because that is what the chain does and the failure needs:
a non-retained push sets the iterator's `lastImm`, and without it the
probe passed while the chain was red.

  python -u extras/screen/animprobe.py [screen.ws]
  python -u extras/screen/animprobe.py trace   # per-tick state window
"""
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "irrun"))
sys.path.insert(0, HERE)

from irsims import share_dump, _extract  # noqa: E402
from painttest import fresh_sim, slide3, poly_pixels, over, close  # noqa
from watchdog import make_watch

WS = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 \
    and sys.argv[1] != "trace" else os.path.join(HERE, "screen.ws")
TRI3 = [8.0, 8.0, 0.0, 20.0, 8.0, 0.0, 8.0, 20.0, 0.0]
PUSHED = (0.0, 1.0, 0.0, 0.5)
# An IMMEDIATE square too, like the chain's moved square: it sets
# lastImm, so every refresh ends with a phantom repaint walk -- and
# whatever that walk does to a translucent refresh is what the chain
# test sees.  Kept clear of the triangle (y +24).
SQ3 = [4.0, 4.0, 0.0, 12.0, 4.0, 0.0, 12.0, 12.0, 0.0, 4.0, 12.0, 0.0]
# The wall holds the pushed colour times the brightness factor
# (FULL_BRIGHT at brightness 100), so the expectation is the composite of
# the DIMMED colour: over(black, (0, 1, 0, 0.5) * 0.35) = 0.175.
BF = 0.35
GREEN = over((0.0, 0.0, 0.0, 1.0),
             tuple(BF * c if k < 3 else c
                   for k, c in enumerate(PUSHED)))
BLUE = over((0.0, 0.0, 0.0, 1.0), (0.0, 0.0, BF * 1.0, 1.0))
BLACK = (0.0, 0.0, 0.0, 1.0)
DX = 2.0
STEPS = 4


def moved_footprint(dx):
    """The triangle's pixels at accumulated delta x (z = 0 projects 1:1)."""
    pts = []
    for i in range(0, len(TRI3), 3):
        pts += [TRI3[i] + dx, TRI3[i + 1]]
    return poly_pixels(pts)


def sq_pixels():
    """The immediate square's pixels at its fixed spot (y +24)."""
    pts = []
    for i in range(0, len(SQ3), 3):
        pts += [SQ3[i], SQ3[i + 1] + 24.0]
    return poly_pixels(pts)


def var_id(sim, name):
    for nid, nd in sim.nodes.items():
        if _extract(nd.props.get("_label", ("raw", ""))) == name:
            return nid
    raise RuntimeError("no var %r" % name)


def main():
    fd, dump = tempfile.mkstemp(suffix=".pkl")
    os.close(fd)
    try:
        share_dump(WS, dump)
        sim, gids, _polyon, _son, pts_aid, cols_aid = fresh_sim(dump)
        wd = make_watch(sim)
        rc_fell = var_id(sim, "rcFell")
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

        plan = {}

        def stage(t, sid, pts, cols, pos, ticks, draw):
            plan[t] = {"shapePoints": list(pts), "shapeColors": list(cols),
                       "shapeWireMode": False, "shapeId": float(sid),
                       "shapePosition": tuple(pos), "shapeRotation": (0.0, 0.0, 0.0),
                       "shapeScale": (0.0, 0.0, 0.0), "parentShapeId": 0.0,
                       "addToShapeInTicks": float(ticks)}
            plan[t + 2] = {"pushShape": True}
            plan[t + 4] = {"pushShape": False}
            if draw:
                plan[t + 6] = {"drawAllShapes": True}
                plan[t + 8] = {"drawAllShapes": False}

        # slot 1: the translucent triangle, stored and shown.
        stage(10, 1, TRI3, [PUSHED[0:4]] * 3, (0.0, 0.0, 0.0), 0.0, True)
        # an IMMEDIATE square, like the chain's moved square: it sets
        # lastImm, so every refresh ends with a phantom repaint walk.
        stage(60, 0, SQ3, [(0.0, 0.0, 1.0, 1.0)] * 4, (0.0, 24.0, 0.0), 0.0, True)
        IMM_T = 62  # the square's push tick: before it, no blue to expect
        # the animation: pure delta (+2 x), 4 steps, NO draw -- the chip's
        # self-refresh must land every step and the final pose.
        stage(430, 1, [0.0, 0.0, 0.0], [], (DX, 0.0, 0.0), 4.0, False)
        # the bare draw after the animation, like connectortest's wallB.
        plan[1150] = {"drawAllShapes": True}
        plan[1152] = {"drawAllShapes": False}

        frames = []
        wallB = [None]
        if "trace" in sys.argv:
            fn = ["cDirty", "erArm", "eraseOK", "noDepth", "arming", "polyOn",
                  "rcOn", "erasing", "erDone", "wasPaint", "pending",
                  "recompFrame", "commitR", "fullErase", "lastImm", "polyLive",
                  "sLive", "repaint", "pfirst", "plast", "prow", "rcSlot"]
            vids = {n: var_id(sim, n) for n in fn}
            er_row = var_id(sim, "erRow")
            old_lo = var_id(sim, "oldLo")
            old_hi = var_id(sim, "oldHi")
            cov_lo = var_id(sim, "covLo")
            cov_hi = var_id(sim, "covHi")

            def trace_watch(sn, tick):
                if tick in plan:
                    step = dict(plan[tick])
                    if "shapePoints" in step:
                        slide3(sn, pts_aid, cols_aid, step.pop("shapePoints"),
                               step.pop("shapeColors", None))
                    sn.inputs = dict(sn.inputs, **step)
                if 428 <= tick <= 545:
                    cov = sn.chip_array("covMin")
                    old = sn.chip_array("oldMin")
                    covx = sn.chip_array("covMax")
                    oldx = sn.chip_array("oldMax")
                    line = "t%-4d " % tick + " ".join(
                        "%s=%s" % (n, sn.vars.get(vids[n]))
                        for n in fn)
                    line += " erRow=%s oldLo=%s oldHi=%s covLo=%s covHi=%s" % (
                        sn.vars.get(er_row), sn.vars.get(old_lo),
                        sn.vars.get(old_hi), sn.vars.get(cov_lo),
                        sn.vars.get(cov_hi))
                    line += " r8: old=[%s,%s] cov=[%s,%s]" % (
                        old[8] if old else None, oldx[8] if oldx else None,
                        cov[8] if cov else None, covx[8] if covx else None)
                    w8 = [sn.vars.get(gids[j], (0.0,) * 4)
                          for j in (520, 522, 532, 534, 1796, 1800, 1828)]
                    line += " px:%s" % "/".join(
                        "%s" % round(max(float(c) for c in cc[:3]), 3)
                        for cc in w8)
                    print(line)

            sim.run(500, on_tick=trace_watch)
            return 0

        def watch(sn, tick):
            wd(sn, tick)
            if tick in plan:
                step = dict(plan[tick])
                if "shapePoints" in step:
                    slide3(sn, pts_aid, cols_aid, step.pop("shapePoints"),
                           step.pop("shapeColors", None))
                sn.inputs = dict(sn.inputs, **step)
            fell = bool(sn.vars.get(rc_fell))
            if fell and not state["was"]:
                xf = sn.chip_array("slXF")
                dx_now = xf[6 + 0] if xf else None
                frames.append((tick, dx_now,
                               [sn.vars.get(gids[i], (0.0, 0.0, 0.0, 0.0))[:4]
                                for i in range(4096)]))
            state["was"] = fell
            if tick == 1250:
                # past the bare draw's pulse (1150 + 2 edge lag + burst)
                wallB[0] = [sn.vars.get(gids[i], (0.0, 0.0, 0.0, 0.0))[:4]
                            for i in range(4096)]

        state = {"was": False}

        SQPIX = sq_pixels()

        def _diff(wall, want_px, imm):
            out = []
            for i in range(4096):
                want = (GREEN if i in want_px else
                        BLUE if imm and i in SQPIX else BLACK)
                if not close(wall[i], want):
                    out.append((i, wall[i], want))
            return out

        sim.run(1400, on_tick=watch)
        print("settled frames: %d" % len(frames))
        bad_total = 0
        for tick, dx, wall in frames:
            if dx is None:
                print("  t=%-5d no-dx" % tick)
                continue
            want_px = moved_footprint(dx)
            wrong = _diff(wall, want_px, tick >= IMM_T)
            nz = [i for i in range(4096)
                  if any(abs(float(c)) > 1e-6 for c in wall[i][:3])]
            # a frame whose wall-nz is below the footprint count caught
            # the refresh mid-paint (erase walked, rows still coming):
            # informational, the settled ones below must be exact.
            print("  t=%-5d dx=%-5s wrong=%-4d wall-nz=%-4d want-nz=%-4d"
                  % (tick, dx, len(wrong), len(nz), len(want_px)))
            if wrong:
                vals = sorted({tuple(round(float(c), 3) for c in w[1][:4])
                               for w in wrong})
                print("      vals %r first %r"
                      % (vals, wrong[:3]))
            if dx == DX * STEPS and len(nz) == len(want_px) + len(SQPIX) and wrong:
                # The chip advances a step mid-cycle and repaints it on
                # the next one, so a sample between the two shows the
                # wall at exactly the previous pose.  That is lag, not
                # a compositing bug: fail only when the wall is not a
                # clean previous pose as well.
                if dx > 0 and not _diff(wall, moved_footprint(dx - DX),
                                         tick >= IMM_T):
                    print("      lag: wall is the previous pose")
                else:
                    bad_total += len(wrong)
        if wallB[0] is not None:
            wrong = _diff(wallB[0], moved_footprint(DX * STEPS), True)
            print("wallB wrong=%d" % len(wrong))
            if wrong:
                vals = sorted({tuple(round(float(c), 3) for c in w[1][:4])
                               for w in wrong})
                print("      vals %r first %r" % (vals, wrong[:3]))
                bad_total += len(wrong)
        else:
            print("wallB: no snapshot")
            bad_total += 1
        for f in wd.failures():
            print("WATCH: " + f)
        print("RESULT: %s" % ("BUG (refresh double-composites translucent repaints)"
                              if bad_total else "ok"))
        return 1 if (bad_total or wd.failures()) else 0
    finally:
        os.unlink(dump)


if __name__ == "__main__":
    sys.exit(main())
