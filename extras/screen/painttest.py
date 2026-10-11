"""Functional test for the wall screen: drive it, read the pixel globals.

The screen takes a point array and fills polygons, so this pushes real
shapes through the real protocol and reads the real per-pixel globals
(g0..g4095) the save wires to the bricks.  A Python model of the fill
(same edge records, same crossings, same sort, same clamping) pins the
exact pixels, so a dropped span, a bad sort or an off-by-one row shows
up as a diff.

One sim run composes a whole frame from nine shapes in sequence -- the
driver's actual usage -- because the chip's boot and the 4096-slot
scanout (~67ms a tick in the sim, the price of mirroring a framebuffer
into 4096 ports) dominate any per-scenario split.  Shapes are staged by
writing the port's delivered array in place: re-seeding through
sim.inputs re-materialises the port on every change, which costs
seconds a tick in the sim, while the in-place write is the same wire
event at the normal rate.

  python -u extras/screen/painttest.py   (exit 0 = all green; ~36s)
"""
import math
import os
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "irrun"))

from irsims import (  # noqa: E402
    sim_from_dump,
    share_dump,
    _extract,
)

WS = os.path.join(HERE, "screen.ws")
SW = 64
BLACK = (0.0, 0.0, 0.0, 1.0)
RED = (1.0, 0.0, 0.0, 1.0)
PAD = 32          # the arm reads pts[0..31] whatever the point count is


def fresh_sim(dump_path):
    sim = sim_from_dump(dump_path)
    sim.reset()
    gids = {}
    polyon = None
    pts_aid = None
    for nid, nd in sim.nodes.items():
        lb = _extract(nd.props.get("_label", ("raw", "")))
        if not isinstance(lb, str):
            lb = ""
        if lb.startswith("g") and lb[1:].isdigit():
            gids[int(lb[1:])] = nid
        elif lb == "polyOn":
            polyon = nid
        elif _extract(nd.props.get("PortLabel", ("raw", ""))) == "pts":
            pts_aid = nid
    assert len(gids) == SW * SW, "globals found: %d" % len(gids)
    assert polyon is not None, "no polyOn var"
    assert pts_aid is not None, "no pts port"
    return sim, gids, polyon, pts_aid


def col(sim, gids, i):
    v = sim.vars.get(gids[i], (0.0, 0.0, 0.0, 0.0))
    if isinstance(v, (tuple, list)) and len(v) >= 4:
        return tuple(float(x) for x in v[:4])
    return v


def expect(cond, label, detail=""):
    print("%-38s %s %s" % (label, "OK  " if cond else "FAIL",
                           detail if not cond else ""))
    return cond


def poly_pixels(pts):
    """The chip's polygon fill: the set of painted pixel indices.

    A transcription of gen.py -- the same per-edge records (base x/y,
    x-per-y slope, half-open y range), the same 200.0 off-screen
    sentinel, the same min/max span and clamp -- so chip and test agree
    by construction.  The span is a row's hull, which is exact for a
    convex polygon; a concave outline fills its hull, so the driver
    decomposes one into convex pieces.  Points are in pixel-corner
    coordinates: a rect covering pixels 0..3 has corners 0 and 4.
    """
    pts = list(pts) + [0.0] * (32 - len(pts))
    n = len(pts) // 2
    edges = []
    gyMin, gyMax = 200.0, -200.0
    gxMin, gxMax = 200.0, -200.0
    for i in range(16):
        px, py = pts[2 * i], pts[2 * i + 1]
        j = i + 1 if (i + 1) < n else 0
        qx, qy = pts[2 * j], pts[2 * j + 1]
        dx, dy = qx - px, qy - py
        s = dx / dy if dy != 0.0 else 0.0
        lo, hi = (py, qy) if py < qy else (qy, py)
        if i < n:
            elo, ehi = lo, hi
            gyMin = min(gyMin, py)
            gyMax = max(gyMax, py)
            gxMin = min(gxMin, px)
            gxMax = max(gxMax, px)
        else:
            elo, ehi = 200.0, -200.0
        edges.append((px, py, s, elo, ehi))
    if gyMax < 0.0 or gyMin >= 64.0 or gxMax < 0.0 or gxMin >= 64.0:
        return set()
    first = 0.0 if gyMin < 0.0 else float(int(gyMin))
    last = 63.0 if gyMax >= 64.0 else float(int(gyMax))
    out = set()
    row = first
    while row <= last:
        cs = []
        for ex, ey, es, elo, ehi in edges:
            if elo <= row < ehi:
                cs.append(ex + es * (row - ey))
            else:
                cs.append(200.0)
        lo, hi = min(cs), max(cs)
        if not (lo >= 200.0 or hi < 0.0 or lo >= 64.0):
            l = 0.0 if lo < 0.0 else float(int(lo))
            r = 63.0 if hi >= 64.0 else float(int(hi))
            if l <= r:
                for c in range(int(l), int(r) + 1):
                    out.add(int(row) * SW + c)
        row += 1.0
    return out


def rect_pts(x0, y0, x1, y1):
    return [x0, y0, x1, y0, x1, y1, x0, y1]


def oval_pts(cx, cy, rx, ry, k=16):
    pts = []
    for i in range(k):
        a = 2.0 * math.pi * i / k
        pts += [cx + rx * math.cos(a), cy + ry * math.sin(a)]
    return pts


def slide(sim, pts_aid, values):
    """Deliver a new point array on the port's wire, in place."""
    arr = sim.arrays.get(pts_aid)
    if arr is None:
        sim.arrays[pts_aid] = list(values)
        return
    arr[0:len(values)] = values


def main():
    t_start = time.time()
    with tempfile.NamedTemporaryFile(suffix=".pkl", delete=False) as f:
        dump_path = f.name
    ok = True
    try:
        share_dump(WS, dump_path)
        green = (0.0, 1.0, 0.0, 0.5)
        blue = (0.1, 0.4, 1.0, 1.0)
        shapes = [
            (rect_pts(0.0, 0.0, 3.0, 2.0), RED),          # a rect
            (rect_pts(60.0, 60.0, 70.0, 70.0), RED),      # clipped
            (rect_pts(0.0, 0.0, 1.0, 1.0), green),        # alpha pixel
            ([0.0, 0.0, 31.0, 0.0, 0.0, 31.0], blue),     # a triangle
            ([10.0, 10.0, 20.0, 10.0, 20.0, 25.0, 17.0, 25.0,
              17.0, 13.0, 13.0, 13.0, 13.0, 25.0, 10.0, 25.0], blue),  # convex hull            (oval_pts(40.0, 40.0, 20.0, 14.0), blue),     # an oval
            ([10.0, 4.0, 10.0, 40.0, 10.0, 40.0], blue),  # a hairline
            ([8.0, 6.0, 40.0, 14.0, 36.0, 20.0, 4.0, 12.0], blue),  # thick line
            (rect_pts(0.0, 0.0, 64.0, 64.0) + [0.0, 0.0] * 12, RED),  # N=16
        ]
        # schedule: each shape's slot is its own row span plus slack, so
        # a burst always finishes before the next redrawAll (a re-arm
        # would abandon it) without paying for the widest shape's pace
        spans = []
        t = 10
        for pts, _color in shapes:
            rows = max((p // SW for p in poly_pixels(pts)), default=0) + 1
            spans.append((t, rows))
            t += rows + 24
        total = t + 10

        # per-tick plan: stage the shape, then pulse push and redraw
        plan = {}
        for i, (pts, color) in enumerate(shapes):
            t0, _rows = spans[i]
            plan[t0] = {"pts": pts + [0.0] * (PAD - len(pts)),
                        "rectColor": color,
                        "shapeN": float(min(16, max(3, len(pts) // 2))),
                        "pushShape": True}
            plan[t0 + 2] = {"pushShape": False}
            plan[t0 + 4] = {"redrawAll": True}
            plan[t0 + 6] = {"redrawAll": False}
        # a bare redrawAll at the end replays the last shape
        replay_at = total
        plan[replay_at] = {"redrawAll": True}
        plan[replay_at + 2] = {"redrawAll": False}
        total = replay_at + 80

        sim, gids, polyon, pts_aid = fresh_sim(dump_path)
        # the array is seeded once, at reset (a reset-time seed is cheap;
        # a mid-run change through sim.inputs is not), then dropped from
        # the inputs so every later pulse merges only scalars and the
        # shapes are staged by slide() alone
        sim.inputs = {"pts": [0.0] * PAD, "shapeN": 3.0,
                      "rectColor": RED, "pushShape": False,
                      "redrawAll": False}
        sim.run(1)
        sim.inputs = {k: v for k, v in sim.inputs.items() if k != "pts"}
        on = []

        def watch(sn, tick):
            if tick in plan:
                step = plan[tick]
                if "pts" in step:
                    slide(sn, pts_aid, step["pts"])
                    step = {k: v for k, v in step.items() if k != "pts"}
                sn.inputs = dict(sn.inputs, **step)
            if sn.vars.get(polyon):
                on.append(tick)

        sim.run(total, on_tick=watch)

        model = {}
        for pts, color in shapes:
            for p in poly_pixels(pts):
                model[p] = color
        bad = [i for i in range(SW * SW)
               if col(sim, gids, i) != model.get(i, BLACK)]
        ok &= expect(not bad, "nine shapes compose one frame",
                     "%d of 4096 differ, first at %d"
                     % (len(bad), bad[0] if bad else 0))
        ok &= expect(any(14 <= t <= 90 for t in on),
                     "bursts ran for the shapes",
                     "no burst in 14..90")
        # the burst windows: nothing may fire between a shape's own burst
        # and the next push 20+ ticks later, and the replay fires last
        last_end = spans[-1][0] + 6 + spans[-1][1] + 4
        ok &= expect(not any(last_end + 4 <= t < replay_at for t in on),
                     "silence between the shapes",
                     "strays at %r" % (
                         [t for t in on if last_end + 4 <= t < replay_at][:8],))
        ok &= expect(any(replay_at <= t <= replay_at + 75 for t in on),
                     "redrawAll replays the last shape",
                     "bursts at %r" % ([t for t in on if t >= replay_at],))
        ok &= expect(not any(t > replay_at + 80 for t in on),
                     "silence after the replay",
                     "strays at %r" % (
                         [t for t in on if t > replay_at + 80][:8],))

        # ---- a bare chip paints nothing ---------------------------------
        sim, gids, polyon, pts_aid = fresh_sim(dump_path)
        sim.inputs = {}
        sim.run(60)
        ok &= expect(all(col(sim, gids, i) == BLACK
                         for i in (0, 100, 1000, 4095)),
                     "bare chip stays black", "")
        ok &= expect(not sim.vars.get(polyon), "painter never arms", "")
    finally:
        os.unlink(dump_path)
    print("painttest: %s (%.0fs)"
          % ("ALL GREEN" if ok else "FAILURES", time.time() - t_start))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
