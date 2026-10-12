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
PAD = 32          # the arm reads shapePoints[0..31] whatever the count is


def fresh_sim(dump_path):
    sim = sim_from_dump(dump_path)
    sim.reset()
    gids = {}
    polyon = None
    son = None
    pts_aid = None
    for nid, nd in sim.nodes.items():
        lb = _extract(nd.props.get("_label", ("raw", "")))
        if not isinstance(lb, str):
            lb = ""
        if lb.startswith("g") and lb[1:].isdigit():
            gids[int(lb[1:])] = nid
        elif lb == "polyOn":
            polyon = nid
        elif lb == "sOn":
            son = nid
        elif _extract(nd.props.get("PortLabel", ("raw", ""))) == "shapePoints":
            pts_aid = nid
    assert len(gids) == SW * SW, "globals found: %d" % len(gids)
    assert polyon is not None, "no polyOn var"
    assert son is not None, "no sOn var"
    assert pts_aid is not None, "no shapePoints port"
    return sim, gids, polyon, son, pts_aid


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

    A transcription of gen.py -- the same count (the array's length), the
    same per-edge records (base x/y, x-per-y slope, half-open y range),
    the same 200.0 off-screen sentinel, the same min/max span and clamp
    -- so chip and test agree by construction.  The span is a row's hull,
    exact for a convex polygon; a concave outline fills its hull, so the
    driver decomposes one into convex pieces.  Points are in pixel-corner
    coordinates: a rect covering pixels 0..3 has corners 0 and 4.
    """
    n = len(pts) // 2
    if n < 3:
        return set()
    pts = list(pts) + [0.0] * (32 - len(pts))
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
        cmn, cmx = [], []
        for ex, ey, es, elo, ehi in edges:
            if elo <= row < ehi:
                x = ex + es * (row - ey)
                cmn.append(x)
                cmx.append(x)
            else:
                cmn.append(200.0)
                cmx.append(-200.0)
        lo, hi = min(cmn), max(cmx)
        if not (lo >= 200.0 or hi < 0.0 or lo >= 64.0):
            l = 0.0 if lo < 0.0 else float(int(lo))
            r = 63.0 if hi >= 64.0 else float(int(hi))
            if l <= r:
                for c in range(int(l), int(r) + 1):
                    out.add(int(row) * SW + c)
        row += 1.0
    return out


def stroke_pixels(pts):
    """The chip's 2px stroke: the set of painted pixel indices.

    A transcription of gen.py's stroke arm and walk -- consecutive pairs
    with no wrap, a 2px quad per segment offset by the unit normal and
    extended a pixel along the tangent, degenerate pairs skipped, a
    single point as a 2x2 dot -- so chip and test agree by construction.
    """
    import math
    n = len(pts) // 2
    if n < 1:
        return set()
    if n == 1:
        x, y = pts[0], pts[1]
        if x < 0.0 or x >= 64.0 or y < 0.0 or y >= 64.0:
            return set()
        out = set()
        for dr in (0, 1):
            for dc in (0, 1):
                r, c = int(y) + dr, int(x) + dc
                if r < 64 and c < 64:
                    out.add(r * SW + c)
        return out
    out = set()
    for i in range(n - 1):
        ax, ay = pts[2 * i], pts[2 * i + 1]
        bx, by = pts[2 * i + 2], pts[2 * i + 3]
        dx, dy = bx - ax, by - ay
        if dx * dx + dy * dy <= 0.0:
            continue
        l = math.sqrt(dx * dx + dy * dy)
        tx, ty = dx / l, dy / l
        nx, ny = -ty, tx
        sax, say = ax - tx, ay - ty
        sbx, sby = bx + tx, by + ty
        quad = [(sax + nx, say + ny), (sbx + nx, sby + ny),
                (sbx - nx, sby - ny), (sax - nx, say - ny)]
        ys = [q[1] for q in quad]
        first = 0.0 if min(ys) < 0.0 else float(int(min(ys)))
        last = 63.0 if max(ys) >= 64.0 else float(int(max(ys)))
        row = first
        while row <= last:
            cmn, cmx = [], []
            for k in range(4):
                x0, y0 = quad[k]
                x1, y1 = quad[(k + 1) % 4]
                lo, hi = (y0, y1) if y0 < y1 else (y1, y0)
                if lo <= row < hi:
                    s = (x1 - x0) / (y1 - y0) if y1 != y0 else 0.0
                    x = x0 + s * (row - y0)
                    cmn.append(x)
                    cmx.append(x)
                else:
                    cmn.append(200.0)
                    cmx.append(-200.0)
            lo, hi = min(cmn), max(cmx)
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
    """Deliver a new point array on the port's wire.

    The array object is replaced, not patched: the count IS the length,
    so a shorter shape must arrive as a shorter list.  Going through
    sim.inputs re-materialises the port on every change, which costs
    seconds a tick in the sim, while replacing the delivered value is
    the same wire event at the normal rate.
    """
    sim.arrays[pts_aid] = list(values)


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
        # would abandon it) without paying for the widest shape's pace.
        # Params stage a full two ticks before the push: the sim delivers
        # a same-tick color+push merge unreliably (the detector fires but
        # the body reads stale), while a real driver always stages across
        # ticks and commits after -- which is what this now does.
        spans = []
        t = 10
        for pts, _color in shapes:
            rows = max((p // SW for p in poly_pixels(pts)), default=0) + 1
            spans.append((t, rows))
            t += rows + 30
        total = t + 10

        # per-tick plan: stage the shape, then pulse push and redraw
        plan = {}
        for i, (pts, color) in enumerate(shapes):
            t0, _rows = spans[i]
            plan[t0] = {"shapePoints": list(pts),
                        "shapeColor": color}
            plan[t0 + 2] = {"pushFill": True}
            plan[t0 + 4] = {"pushFill": False}
            plan[t0 + 6] = {"redrawAll": True}
            plan[t0 + 8] = {"redrawAll": False}
        # a bare redrawAll at the end replays the last shape
        replay_at = total
        plan[replay_at] = {"redrawAll": True}
        plan[replay_at + 2] = {"redrawAll": False}
        total = replay_at + 80

        sim, gids, polyon, son, pts_aid = fresh_sim(dump_path)
        # the array is seeded once, at reset (a reset-time seed is cheap;
        # a mid-run change through sim.inputs is not), then dropped from
        # the inputs so every later pulse merges only scalars and the
        # shapes are staged by slide() alone.  Each shape's array is
        # exactly as long as its point list: the count IS the length.
        sim.inputs = {"shapePoints": [0.0] * 32, "shapeColor": RED,
                      "pushFill": False, "pushStroke": False,
                      "redrawAll": False}
        sim.run(1)
        sim.inputs = {k: v for k, v in sim.inputs.items()
                      if k != "shapePoints"}
        on = []
        son_on = []

        def watch(sn, tick):
            if tick in plan:
                step = plan[tick]
                if "shapePoints" in step:
                    slide(sn, pts_aid, step["shapePoints"])
                    step = {k: v for k, v in step.items()
                            if k != "shapePoints"}
                sn.inputs = dict(sn.inputs, **step)
            if sn.vars.get(polyon):
                on.append(tick)
            if sn.vars.get(son):
                son_on.append(tick)

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
        # the tick-0 seeding fires every Change detector once, so the
        # stroke arms from the seeded (all-zero, degenerate) array too:
        # it walks ~30 empty advances painting nothing, then ends.  The
        # model diff above already proves it painted nothing wrong.
        ok &= expect(not any(t > 40 for t in son_on),
                     "phantom stroke goes silent",
                     "walk at %r" % ([t for t in son_on if t > 40][:8],))

        # ---- strokes: a wireframe, an open curve, a dot ------------------
        # One more composed run: the stroke walk paints 2px quads along
        # consecutive pairs (no wrap), so a wireframe repeats its first
        # point and an open curve simply ends.  The trailing replay fires
        # after the array is overwritten with junk, which proves the
        # replay restores the preserved points instead of re-reading.
        strokes = [
            ([5.0, 30.0, 20.0, 15.0, 35.0, 30.0], blue),   # open curve
            ([40.0, 40.0], blue),                           # a dot
            ([10.0, 10.0, 20.0, 10.0, 20.0, 20.0, 10.0, 20.0,
              10.0, 10.0], blue),                           # wireframe square
        ]
        spans2 = []
        t = 10
        for pts, _color in strokes:
            rows = max((p // SW for p in stroke_pixels(pts)), default=0) + 1
            spans2.append((t, rows))
            t += rows + 34
        plan2 = {}
        for i, (pts, color) in enumerate(strokes):
            t0, _rows = spans2[i]
            plan2[t0] = {"shapePoints": list(pts),
                         "shapeColor": color}
            plan2[t0 + 2] = {"pushStroke": True}
            plan2[t0 + 4] = {"pushStroke": False}
            plan2[t0 + 6] = {"redrawAll": True}
            plan2[t0 + 8] = {"redrawAll": False}
        # overwrite the array with junk, then replay: the wall must still
        # show the staged square, not the junk
        junk_at = t + 4
        plan2[junk_at] = {"shapePoints": [1.0, 2.0, 3.0, 4.0, 5.0, 6.0]}
        replay2_at = t + 14
        plan2[replay2_at] = {"redrawAll": True}
        plan2[replay2_at + 2] = {"redrawAll": False}
        total2 = replay2_at + 60

        sim, gids, polyon, son, pts_aid = fresh_sim(dump_path)
        sim.inputs = {"shapePoints": [0.0] * 32, "shapeColor": RED,
                      "pushFill": False, "pushStroke": False,
                      "redrawAll": False}
        sim.run(1)
        sim.inputs = {k: v for k, v in sim.inputs.items()
                      if k != "shapePoints"}
        on2 = []
        on2p = []

        def watch2(sn, tick):
            if tick in plan2:
                step = plan2[tick]
                if "shapePoints" in step:
                    slide(sn, pts_aid, step["shapePoints"])
                    step = {k: v for k, v in step.items()
                            if k != "shapePoints"}
                sn.inputs = dict(sn.inputs, **step)
            if sn.vars.get(son):
                on2.append(tick)
            if sn.vars.get(polyon):
                on2p.append(tick)

        sim.run(total2, on_tick=watch2)

        model2 = {}
        for pts, color in strokes:
            for p in stroke_pixels(pts):
                model2[p] = color
        bad = [i for i in range(SW * SW)
               if col(sim, gids, i) != model2.get(i, BLACK)]
        ok &= expect(not bad, "wireframe, curve and dot compose",
                     "%d of 4096 differ, first at %d"
                     % (len(bad), bad[0] if bad else 0))
        ok &= expect(not on2p or not any(t > 40 for t in on2p),
                     "phantom fill goes silent",
                     "walk at %r" % ([t for t in on2p if t > 40][:8],))
        ok &= expect(any(replay2_at <= t <= replay2_at + 50 for t in on2),
                     "redrawAll replays the staged stroke",
                     "bursts at %r" % ([t for t in on2 if t >= replay2_at],))
        ok &= expect(not any(t > replay2_at + 55 for t in on2),
                     "silence after the stroke replay",
                     "strays at %r" % (
                         [t for t in on2 if t > replay2_at + 55][:8],))

        # ---- the load-time phantom paints correctly -----------------------
        # Tick-0 seeding fires every Change detector once, so both walks
        # arm from the seeded array with no pulse at all.  Seed a real
        # closed square: whatever paints must be exactly that square's
        # fill and/or outline in the seeded colour -- anything else is a
        # torn span -- and both walks must end on their own.
        sq = [10.0, 10.0, 20.0, 10.0, 20.0, 20.0, 10.0, 20.0, 10.0, 10.0]
        sim, gids, polyon, son, pts_aid = fresh_sim(dump_path)
        sim.inputs = {"shapePoints": list(sq), "shapeColor": blue,
                      "pushFill": False, "pushStroke": False,
                      "redrawAll": False}
        on3 = []
        on3s = []

        def watch3(sn, tick):
            if sn.vars.get(polyon):
                on3.append(tick)
            if sn.vars.get(son):
                on3s.append(tick)

        sim.run(140, on_tick=watch3)
        allowed = poly_pixels(sq) | stroke_pixels(sq)
        outline = stroke_pixels(sq)
        painted = {i for i in range(SW * SW) if col(sim, gids, i) == blue}
        ok &= expect(painted <= allowed, "phantom paints only the seed",
                     "%d strays, first at %d"
                     % (len(painted - allowed),
                        min(painted - allowed) if painted - allowed else 0))
        ok &= expect(outline <= painted, "phantom paints the outline",
                     "missing %d of %d"
                     % (len(outline - painted), len(outline)))
        ok &= expect(not any(t > 120 for t in on3), "phantom fill ends",
                     "walk at %r" % ([t for t in on3 if t > 120][:8],))
        ok &= expect(not any(t > 120 for t in on3s), "phantom stroke ends",
                     "walk at %r" % ([t for t in on3s if t > 120][:8],))

        # ---- a bare chip paints nothing ---------------------------------
        sim, gids, polyon, son, pts_aid = fresh_sim(dump_path)
        sim.inputs = {}
        sim.run(60)
        ok &= expect(all(col(sim, gids, i) == BLACK
                         for i in (0, 100, 1000, 4095)),
                     "bare chip stays black", "")
        ok &= expect(not sim.vars.get(polyon), "painter never arms", "")
        ok &= expect(not sim.vars.get(son), "stroke never arms", "")
    finally:
        os.unlink(dump_path)
    print("painttest: %s (%.0fs)"
          % ("ALL GREEN" if ok else "FAILURES", time.time() - t_start))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
