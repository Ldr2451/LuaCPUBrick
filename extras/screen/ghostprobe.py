"""Does an animation refresh leave the previous frame's pixels on the wall?

The tour's beat 7 turns a cube forever inside a full-wall background.  A
refresh repaint (animation deltas, no geometry change) skips the up-front
erase, so the depth buffer it paints into still holds the last frame's
depths.  A pixel the old cube covered keeps its old depth, the background
that repaints it is FARTHER and loses the depth test, and the old silhouette
stays on the wall -- which reads as "only parts of the screen update".

This drives the smallest version of that scene at screen.ws alone: a
full-wall background at z=0 in slot 1 (it projects 1:1, so it covers the
wall), a red quad at z=10 in slot 2 (nearer, so it wins the depth test where
it lands), one draw, then a pure-delta animation moving the quad +4 world x
per frame.  Every settled frame must be background everywhere except the
quad's projected footprint; a pixel of an old footprint that stays red is the
bug, and a pixel of the current footprint that is not red is the same bug
seen from the other side.

This is the regression case for the depth reset gen.py stages at every
recomposite start; screenchecks.py runs it as a gate.

  python -u extras/screen/ghostprobe.py [screen.ws]
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

WS = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 \
    else os.path.join(HERE, "screen.ws")
BG = (0.05, 0.05, 0.20, 1.0)
RED = (1.0, 0.0, 0.0, 1.0)
DX = 4.0
EYE = 48.0
EX = EY = 32.0


def rect3(x0, y0, x1, y1, z):
    out = []
    for x, y in ((x0, y0), (x1, y0), (x1, y1), (x0, y1)):
        out += [x, y, z]
    return out


def project(pts3, pos):
    """The chip's 3D projection, transcribed: translate, then divide by the
    distance to the eye plane (eye at the wall's centre, z = +EYE), so a
    point at z = 0 lands exactly where a 2D point would."""
    out = []
    for i in range(0, len(pts3), 3):
        wx = pts3[i] + pos[0]
        wy = pts3[i + 1] + pos[1]
        wd = EYE - (pts3[i + 2] + pos[2])
        if wd < 1.0:
            wd = 1.0
        out += [EYE * (wx - EX) / wd + EX, EYE * (wy - EY) / wd + EY]
    return out


def same(a, b, tol=1e-9):
    """Channel-wise near-equality: the wall stores colour * bf and the probe
    divides bf back out, so last-ulp drift is expected."""
    return (isinstance(a, (tuple, list)) and len(a) >= 4
            and all(abs(float(a[k]) - float(b[k])) <= tol for k in range(4)))


def var_id(sim, name):
    for nid, nd in sim.nodes.items():
        if _extract(nd.props.get("_label", ("raw", ""))) == name:
            return nid
    raise RuntimeError("no var %r" % name)


def stage(t, sid, pts, cols, pos, scl, parent, ticks, draw):
    """Stage, pulse push, and optionally draw, two ticks apart each."""
    p = {t: {"shapePoints": list(pts), "shapeColors": list(cols),
             "shapeWireMode": False, "shapeId": float(sid),
             "shapePosition": tuple(pos), "shapeRotation": (0.0, 0.0, 0.0),
             "shapeScale": tuple(scl), "parentShapeId": float(parent),
             "addToShapeInTicks": float(ticks)},
         t + 2: {"pushShape": True},
         t + 4: {"pushShape": False}}
    if draw:
        p[t + 6] = {"drawAllShapes": True}
        p[t + 8] = {"drawAllShapes": False}
    return p


def main():
    fd, dump = tempfile.mkstemp(suffix=".pkl")
    os.close(fd)
    try:
        share_dump(WS, dump)
        print("chip built from %s" % WS)
        sim, gids, _polyon, _son, pts_aid, cols_aid = fresh_sim(dump)
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

        quad = rect3(16.0, 16.0, 32.0, 48.0, 10.0)
        plan = {}
        # slot 1: the background, the whole wall, behind everything
        plan.update(stage(10, 1, rect3(0.0, 0.0, 64.0, 64.0, 0.0),
                          [BG] * 4, (0, 0, 0), (0, 0, 0), 0, 0, True))
        # slot 2: a red quad in front of it
        plan.update(stage(220, 2, quad, [RED] * 4,
                          (0, 0, 0), (0, 0, 0), 0, 0, True))
        # a pure-delta animation: +4 x per frame, forever, scale untouched
        plan.update(stage(430, 2, [0.0, 0.0, 0.0], [],
                          (DX, 0.0, 0.0), (0, 0, 0), 0, -1, False))

        frames = []
        state = {"was": False, "dx": None}

        def watch(sn, tick):
            if tick in plan:
                step = dict(plan[tick])
                if "shapePoints" in step:
                    slide3(sn, pts_aid, cols_aid, step.pop("shapePoints"),
                           step.pop("shapeColors", None))
                sn.inputs = dict(sn.inputs, **step)
            xf = sn.chip_array("slXF")
            dx_now = xf[2 * 6 + 0] if xf else None
            fell = bool(sn.vars.get(rc_fell))
            # The advance runs at rcFell, before this tick's rows: the frame
            # that just settled was armed from the PREVIOUS tick's position,
            # so that is the one its footprint must be checked against.
            if fell and not state["was"] and tick > 440:
                frames.append((tick, state["dx"],
                               [col(sn, gids, i) for i in range(4096)]))
            state["was"] = fell
            state["dx"] = dx_now

        sim.run(880, on_tick=watch)
        print("settled frames: %d" % len(frames))
        bad_total = 0
        for tick, dx, wall in frames:
            want = set(poly_pixels(project(quad, (dx, 0.0, 0.0))))
            ghosts = [i for i in range(4096)
                      if i not in want and not same(wall[i], BG)]
            missing = [i for i in want if not same(wall[i], RED)]
            bad_total += len(ghosts) + len(missing)
            print("  t=%-5d quad-x=%-6s ghosts=%-4d missing=%-4d %s"
                  % (tick, dx, len(ghosts), len(missing),
                     "BUG" if (ghosts or missing) else "ok"))
            if ghosts:
                rows = sorted({i // 64 for i in ghosts})
                print("      ghost rows %r, first pixels %r"
                      % (rows[:8], ghosts[:6]))
        print("RESULT: %s" % ("BUG (old pixels survive a refresh)"
                              if bad_total else "ok"))
        return 1 if bad_total else 0
    finally:
        os.unlink(dump)


if __name__ == "__main__":
    sys.exit(main())
