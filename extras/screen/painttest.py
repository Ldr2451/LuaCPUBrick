"""Functional test for the wall screen: drive it, read the pixel globals.

The screen takes a point array and a per-point colour array, fills
polygons with true scanline interpolation, and strokes 2px quads,
so this pushes real shapes through the real protocol and reads the
real per-pixel globals (g0..g4095) the save wires to the bricks.
A Python model of the fill (same edge records, same crossings,
same sort, same clamping) pins the exact pixels, so a dropped span,
a bad sort or an off-by-one row shows up as a diff.  Shapes whose
points all share one colour interpolate to that colour exactly, so
the flat-colour model below still pins them pixel-exact; the
per-point interpolation gets its own exact section at the end.

One sim run composes a whole frame from nine shapes in sequence --
the driver's actual usage -- because the chip's boot and the
4096-slot scanout (~67ms a tick in the sim, the price of mirroring
a framebuffer into 4096 ports) dominate any per-scenario split.
Shapes are staged by writing the port's delivered array in place:
re-seeding through sim.inputs re-materialises the port on every
change, which costs seconds a tick in the sim, while the in-place
write is the same wire event at the normal rate.

  python -u extras/screen/painttest.py   (exit 0 = all green)
"""
import math
import os
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "irrun"))
sys.path.insert(0, os.path.join(HERE))

from irsims import (  # noqa: E402
    sim_from_dump,
    share_dump,
    _extract,
)
import colormath  # noqa: E402

colormath.install()

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
    cols_aid = None
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
        elif _extract(nd.props.get("PortLabel", ("raw", ""))) == "shapeColors":
            cols_aid = nid
    assert len(gids) == SW * SW, "globals found: %d" % len(gids)
    assert polyon is not None, "no polyOn var"
    assert son is not None, "no sOn var"
    assert pts_aid is not None, "no shapePoints port"
    assert cols_aid is not None, "no shapeColors port"
    return sim, gids, polyon, son, pts_aid, cols_aid


def col(sim, gids, i):
    v = sim.vars.get(gids[i], (0.0, 0.0, 0.0, 0.0))
    if isinstance(v, (tuple, list)) and len(v) >= 4:
        return tuple(float(x) for x in v[:4])
    return v


def expect(cond, label, detail=""):
    print("%-38s %s %s" % (label, "OK  " if cond else "FAIL",
                           detail if not cond else ""))
    return cond


def close(a, b, tol=1e-9):
    """Channel-wise near-equality (the chip multiplies by the
    reciprocal where the model divides, so last-ulp differences
    are expected on irrational geometry)."""
    if isinstance(a, (tuple, list)) and isinstance(b, (tuple, list)):
        return len(a) == len(b) and all(
            abs(float(x) - float(y)) <= tol for x, y in zip(a, b))
    return a == b


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


def poly_colors(pts, colors):
    """The chip's interpolated fill: pixel -> colour.

    A transcription of gen.py's colour path -- the same edge
    records, each straddling edge's crossing colour lerped
    along the edge from its own start point (the endpoint
    colours), the min/max winners' colours, then the span
    lerp between them -- so chip and test agree by
    construction.  A flat colour list reproduces the flat
    model exactly; per-point lists give the gradient.
    """
    WHITE = (1.0, 1.0, 1.0, 1.0)
    n = len(pts) // 2
    if n < 3:
        return {}
    pts = list(pts) + [0.0] * (32 - len(pts))
    colors = list(colors) + [WHITE] * (16 - len(colors))
    edges = []
    gyMin, gyMax = 200.0, -200.0
    gxMin, gxMax = 200.0, -200.0
    for i in range(16):
        px, py = pts[2 * i], pts[2 * i + 1]
        j = i + 1 if (i + 1) < n else 0
        qx, qy = pts[2 * j], pts[2 * j + 1]
        dx, dy = qx - px, qy - py
        s = dx / dy if dy != 0.0 else 0.0
        dny = qy - py
        ein = 1.0 / dny if dny != 0.0 else 0.0
        lo, hi = (py, qy) if py < qy else (qy, py)
        if i < n:
            elo, ehi = lo, hi
            gyMin = min(gyMin, py)
            gyMax = max(gyMax, py)
            gxMin = min(gxMin, px)
            gxMax = max(gxMax, px)
        else:
            elo, ehi = 200.0, -200.0
        edges.append((px, py, s, elo, ehi, ein,
                      colors[i], colors[j]))
    if gyMax < 0.0 or gyMin >= 64.0 or gxMax < 0.0 or gxMin >= 64.0:
        return {}
    first = 0.0 if gyMin < 0.0 else float(int(gyMin))
    last = 63.0 if gyMax >= 64.0 else float(int(gyMax))
    out = {}
    row = first
    while row <= last:
        # Two masks, one per reduction, exactly as the chip's trees
        # need: the min wants its dead edges large, the max small.
        xmn, xmx, cs = [], [], []
        for ex, ey, es, elo, ehi, ein, ci, cj in edges:
            if elo <= row < ehi:
                x = ex + es * (row - ey)
                xmn.append(x)
                xmx.append(x)
                t = (row - ey) * ein
                cs.append(tuple(ci[k] + t * (cj[k] - ci[k])
                                for k in range(4)))
            else:
                xmn.append(200.0)
                xmx.append(-200.0)
                cs.append(WHITE)
        lo, hi = min(xmn), max(xmx)
        if not (lo >= 200.0 or hi < 0.0 or lo >= 64.0):
            l = 0.0 if lo < 0.0 else float(int(lo))
            r = 63.0 if hi >= 64.0 else float(int(hi))
            if l <= r:
                cLo = cs[xmn.index(lo)]
                cHi = cs[xmx.index(hi)]
                span = hi - lo
                inv = 1.0 / span if span > 0.0 else 0.0
                slope = tuple((cHi[k] - cLo[k]) * inv
                              for k in range(4))
                for c in range(int(l), int(r) + 1):
                    tj = float(c)
                    out[int(row) * SW + c] = tuple(
                        cLo[k] + slope[k] * (tj - lo)
                        for k in range(4))
        row += 1.0
    return out


def stroke_colors(pts, colors):
    """The chip's interpolated stroke: pixel -> colour.

    A transcription of gen.py's stroke colour path -- the
    quad's four corners carry (cA, cB, cB, cA), each sloped
    edge lerps its endpoints' colours by the row parameter,
    the caps stay flat, the min/max winners' colours then
    lerp across the span.  The dot takes its point's colour.
    """
    WHITE = (1.0, 1.0, 1.0, 1.0)
    n = len(pts) // 2
    if n < 1:
        return {}
    colors = list(colors) + [WHITE] * (16 - len(colors))
    if n == 1:
        x, y = pts[0], pts[1]
        if x < 0.0 or x >= 64.0 or y < 0.0 or y >= 64.0:
            return {}
        out = {}
        for dr in (0, 1):
            for dc in (0, 1):
                r, c = int(y) + dr, int(x) + dc
                if r < 64 and c < 64:
                    out[r * SW + c] = colors[0]
        return out
    out = {}
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
        qc = [colors[i], colors[i + 1], colors[i + 1], colors[i]]
        ys = [q[1] for q in quad]
        first = 0.0 if min(ys) < 0.0 else float(int(min(ys)))
        last = 63.0 if max(ys) >= 64.0 else float(int(max(ys)))
        row = first
        while row <= last:
            # Two masks, one per reduction: the min wants its dead
            # crossings large, the max small (the chip's u-trees).
            xmn, xmx, cs = [], [], []
            for k in range(4):
                x0, y0 = quad[k]
                x1, y1 = quad[(k + 1) % 4]
                lo, hi = (y0, y1) if y0 < y1 else (y1, y0)
                if lo <= row < hi:
                    s = (x1 - x0) / (y1 - y0) if y1 != y0 else 0.0
                    xmn.append(x0 + s * (row - y0))
                    xmx.append(x0 + s * (row - y0))
                    if y1 != y0:
                        t = (row - y0) / (y1 - y0)
                        cs.append(tuple(qc[k][m] + t * (qc[(k + 1) % 4][m]
                                                        - qc[k][m])
                                        for m in range(4)))
                    else:
                        cs.append(qc[k])
                else:
                    xmn.append(200.0)
                    xmx.append(-200.0)
                    cs.append(WHITE)
            lo, hi = min(xmn), max(xmx)
            if not (lo >= 200.0 or hi < 0.0 or lo >= 64.0):
                l = 0.0 if lo < 0.0 else float(int(lo))
                r = 63.0 if hi >= 64.0 else float(int(hi))
                if l <= r:
                    cLo = cs[xmn.index(lo)]
                    cHi = cs[xmx.index(hi)]
                    span = hi - lo
                    inv = 1.0 / span if span > 0.0 else 0.0
                    slope = tuple((cHi[k] - cLo[k]) * inv
                                  for k in range(4))
                    for c in range(int(l), int(r) + 1):
                        tj = float(c)
                        out[int(row) * SW + c] = tuple(
                            cLo[k] + slope[k] * (tj - lo)
                            for k in range(4))
            row += 1.0
    return out


def rect_pts(x0, y0, x1, y1):
    return [x0, y0, x1, y0, x1, y1, x0, y1]


def xf_points(pts, pos, ang, scl):
    """The chip's point transform, transcribed: scale, rotate about the
    origin by ang radians, translate -- mirrors applyXF exactly,
    including the scale-zero-means-identity default."""
    sx = scl[0] if scl[0] != 0.0 else 1.0
    sy = scl[1] if scl[1] != 0.0 else 1.0
    ct, st = math.cos(ang), math.sin(ang)
    out = []
    for i in range(0, len(pts), 2):
        ox, oy = pts[i] * sx, pts[i + 1] * sy
        out += [pos[0] + ox * ct - oy * st,
                pos[1] + ox * st + oy * ct]
    return out


def xf_compose(parent, child):
    """parent_world composed with child_local -> world, as (pos, ang,
    scl) triples.  Mirrors one ancestor-walk step exactly."""
    (ppx, ppy), pra, (psx, psy) = parent
    (cpx, cpy), cra, (csx, csy) = child
    ct, st = math.cos(pra), math.sin(pra)
    ox, oy = psx * cpx, psy * cpy
    return ((ppx + ox * ct - oy * st, ppy + ox * st + oy * ct),
            pra + cra, (psx * csx, psy * csy))


IDENT = ((0.0, 0.0), 0.0, (1.0, 1.0))


def oval_pts(cx, cy, rx, ry, k=16):
    pts = []
    for i in range(k):
        a = 2.0 * math.pi * i / k
        pts += [cx + rx * math.cos(a), cy + ry * math.sin(a)]
    return pts


def slide(sim, pts_aid, cols_aid, values, colors=None):
    """Deliver a new point array (and its colour array) on the ports.

    The array objects are replaced, not patched: the count IS the
    length, so a shorter shape must arrive as a shorter list.  Going
    through sim.inputs re-materialises the port on every change, which
    costs seconds a tick in the sim, while replacing the delivered
    value is the same wire event at the normal rate.
    """
    sim.arrays[pts_aid] = list(values)
    if colors is not None:
        sim.arrays[cols_aid] = list(colors)


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
        # a burst always finishes before the next drawAll (a re-arm
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

        # per-tick plan: stage the shape, then pulse push and redraw.
        # Params stage two ticks before the push (a same-tick color+push
        # merge delivers unreliably in the sim); wire and slot ride with
        # the colour -- immediate fills here.
        plan = {}
        for i, (pts, color) in enumerate(shapes):
            t0, _rows = spans[i]
            plan[t0] = {"shapePoints": list(pts),
                        "shapeColors": [color] * (len(pts) // 2),
                        "wireMode": False, "shapeId": 0.0}
            plan[t0 + 2] = {"pushShape": True}
            plan[t0 + 4] = {"pushShape": False}
            plan[t0 + 6] = {"drawAll": True}
            plan[t0 + 8] = {"drawAll": False}
        # a bare drawAll at the end replays the last shape
        replay_at = total
        plan[replay_at] = {"drawAll": True}
        plan[replay_at + 2] = {"drawAll": False}
        total = replay_at + 80

        sim, gids, polyon, son, pts_aid, cols_aid = fresh_sim(dump_path)
        # the array is seeded once, at reset (a reset-time seed is cheap;
        # a mid-run change through sim.inputs is not), then dropped from
        # the inputs so every later pulse merges only scalars and the
        # shapes are staged by slide() alone.  Each shape's array is
        # exactly as long as its point list: the count IS the length.
        sim.inputs = {"shapePoints": [0.0] * 32, "shapeColors": [],
                      "pushShape": False, "wireMode": False,
                      "shapeId": 0.0, "drawAll": False,
                      "clearAll": False, "position": (0.0, 0.0, 0.0), "rotation": (0.0, 0.0, 0.0), "scale": (0.0, 0.0, 0.0), "parentShapeId": 0.0, "brightness": 100.0}
        sim.run(1)
        sim.inputs = {k: v for k, v in sim.inputs.items()
                      if k != "shapePoints"}
        on = []
        son_on = []

        def watch(sn, tick):
            if tick in plan:
                step = plan[tick]
                if "shapePoints" in step:
                    slide(sn, pts_aid, cols_aid, step["shapePoints"],
                          step.get("shapeColors"))
                    step = {k: v for k, v in step.items()
                            if k != "shapePoints" and k != "shapeColors"}
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
                     "drawAll replays the last shape",
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

        # ---- per-point colours interpolate across the fill -------------
        # A 4x4 rect whose four corners carry four different colours:
        # every pixel is the scanline interpolation of its row's two
        # crossing colours (each itself lerped along its edge), so the
        # corners keep their colour and the interior blends.  The model
        # transcribes the chip's colour path, so the exact channel
        # values pin the interpolation.
        grad_pts = [0.0, 0.0, 4.0, 0.0, 4.0, 4.0, 0.0, 4.0]
        grad_cols = [RED, (0.0, 1.0, 0.0, 1.0),
                     (0.0, 0.0, 1.0, 1.0), (1.0, 1.0, 0.0, 1.0)]
        gplan = {}
        t = 10
        gplan[t] = {"shapePoints": list(grad_pts),
                    "shapeColors": list(grad_cols),
                    "wireMode": False, "shapeId": 0.0}
        gplan[t + 2] = {"pushShape": True}
        gplan[t + 4] = {"pushShape": False}
        gplan[t + 6] = {"drawAll": True}
        gplan[t + 8] = {"drawAll": False}
        gtotal = t + 80

        sim, gids, polyon, son, pts_aid, cols_aid = fresh_sim(dump_path)
        sim.inputs = {"shapePoints": [0.0] * 32, "shapeColors": [],
                      "pushShape": False, "wireMode": False,
                      "shapeId": 0.0, "drawAll": False,
                      "clearAll": False, "position": (0.0, 0.0, 0.0), "rotation": (0.0, 0.0, 0.0), "scale": (0.0, 0.0, 0.0), "parentShapeId": 0.0, "brightness": 100.0}
        sim.run(1)
        sim.inputs = {k: v for k, v in sim.inputs.items()
                      if k != "shapePoints"}

        def watchg(sn, tick):
            if tick in gplan:
                step = gplan[tick]
                if "shapePoints" in step:
                    slide(sn, pts_aid, cols_aid, step["shapePoints"],
                          step.get("shapeColors"))
                    step = {k: v for k, v in step.items()
                            if k != "shapePoints" and k != "shapeColors"}
                sn.inputs = dict(sn.inputs, **step)

        sim.run(gtotal, on_tick=watchg)

        gmodel = poly_colors(grad_pts, grad_cols)
        badg = [i for i in range(SW * SW)
                if not close(col(sim, gids, i), gmodel.get(i, BLACK))]
        ok &= expect(not badg, "per-point colours interpolate",
                     "%d of 4096 differ, first at %d"
                     % (len(badg), badg[0] if badg else 0))
        # a 4x4 rect covers rows 0..3 (the fill's y range is
        # half-open): row 0's corners are the pure endpoint
        # colours, row 3's edges are the 75% blends
        ok &= expect(close(col(sim, gids, 0), RED)
                     and close(col(sim, gids, 4), grad_cols[1]),
                     "top corners keep their colours",
                     "%r %r" % (col(sim, gids, 0), col(sim, gids, 4)))
        ok &= expect(close(col(sim, gids, 3 * SW), (1.0, 0.75, 0.0, 1.0))
                     and close(col(sim, gids, 3 * SW + 4),
                               (0.0, 0.25, 0.75, 1.0)),
                     "bottom row edges blend to 75%",
                     "%r %r" % (col(sim, gids, 3 * SW),
                                col(sim, gids, 3 * SW + 4)))
        ok &= expect(close(col(sim, gids, 2 * SW + 2),
                           (0.5, 0.5, 0.25, 1.0)),
                     "centre is the four-way blend",
                     "%r" % (col(sim, gids, 2 * SW + 2),))

        # ---- strokes: a wireframe, an open curve, a dot ------------------
        # One more composed run: the stroke walk paints 2px quads along
        # consecutive pairs (no wrap), so a wireframe repeats its first
        # point and an open curve simply ends.  The trailing replay fires
        # after the array is overwritten with junk, which proves the
        # replay restores the preserved points instead of re-reading.
        strokes = [
            ([5.0, 30.0, 20.0, 15.0, 35.0, 30.0],
             [blue, blue]),                        # open curve
            ([40.0, 40.0], [blue]),                           # a dot
            ([10.0, 10.0, 20.0, 10.0, 20.0, 20.0, 10.0, 20.0,
              10.0, 10.0], [blue] * 5),                     # wireframe square
            ([2.0, 8.0, 6.0, 12.0],
             [RED, blue]),                   # diagonal, red -> blue
        ]
        spans2 = []
        t = 10
        for pts, _color in strokes:
            rows = max((p // SW for p in stroke_pixels(pts)), default=0) + 1
            spans2.append((t, rows))
            t += rows + 34
        plan2 = {}
        for i, (pts, cols) in enumerate(strokes):
            t0, _rows = spans2[i]
            plan2[t0] = {"shapePoints": list(pts),
                         "shapeColors": list(cols),
                         "wireMode": True, "shapeId": 0.0}
            plan2[t0 + 2] = {"pushShape": True}
            plan2[t0 + 4] = {"pushShape": False}
            plan2[t0 + 6] = {"drawAll": True}
            plan2[t0 + 8] = {"drawAll": False}
        # overwrite the array with junk, then replay: the wall must still
        # show the staged square, not the junk
        junk_at = t + 4
        plan2[junk_at] = {"shapePoints": [1.0, 2.0, 3.0, 4.0, 5.0, 6.0]}
        replay2_at = t + 14
        plan2[replay2_at] = {"drawAll": True}
        plan2[replay2_at + 2] = {"drawAll": False}
        total2 = replay2_at + 60

        sim, gids, polyon, son, pts_aid, cols_aid = fresh_sim(dump_path)
        sim.inputs = {"shapePoints": [0.0] * 32, "shapeColors": [],
                      "pushShape": False, "wireMode": False,
                      "shapeId": 0.0, "drawAll": False,
                      "clearAll": False, "position": (0.0, 0.0, 0.0), "rotation": (0.0, 0.0, 0.0), "scale": (0.0, 0.0, 0.0), "parentShapeId": 0.0, "brightness": 100.0}
        sim.run(1)
        sim.inputs = {k: v for k, v in sim.inputs.items()
                      if k != "shapePoints"}
        on2 = []
        on2p = []

        def watch2(sn, tick):
            if tick in plan2:
                step = plan2[tick]
                if "shapePoints" in step:
                    slide(sn, pts_aid, cols_aid, step["shapePoints"],
                          step.get("shapeColors"))
                    step = {k: v for k, v in step.items()
                            if k != "shapePoints" and k != "shapeColors"}
                sn.inputs = dict(sn.inputs, **step)
            if sn.vars.get(son):
                on2.append(tick)
            if sn.vars.get(polyon):
                on2p.append(tick)

        sim.run(total2, on_tick=watch2)

        model2 = {}
        for pts, cols in strokes:
            for p, c in stroke_colors(pts, cols).items():
                model2[p] = c
        bad = [i for i in range(SW * SW)
               if not close(col(sim, gids, i), model2.get(i, BLACK))]
        ok &= expect(not bad, "wireframe, curve, dot and gradient compose",
                     "%d of 4096 differ, first at %d"
                     % (len(bad), bad[0] if bad else 0))
        ok &= expect(not on2p or not any(t > 40 for t in on2p),
                     "phantom fill goes silent",
                     "walk at %r" % ([t for t in on2p if t > 40][:8],))
        ok &= expect(any(replay2_at <= t <= replay2_at + 50 for t in on2),
                     "drawAll replays the staged stroke",
                     "bursts at %r" % ([t for t in on2 if t >= replay2_at],))
        ok &= expect(not any(t > replay2_at + 55 for t in on2),
                     "silence after the stroke replay",
                     "strays at %r" % (
                         [t for t in on2 if t > replay2_at + 55][:8],))

        # ---- retained shapes: store, edit, delete -------------------------
        # Slot 1 keeps a square, slot 2 a triangle; every retained commit
        # clears the wall and repaints all live slots in order, so an edit
        # replaces geometry in place and an empty push deletes.  The wall
        # is snapshotted at each commit's end within one run (re-running
        # per commit would triple the sim cost; snapshots are cheap).
        # Commits are slow in the sim (one 32-access computed load per
        # live shape), so this stays at two slots and four commits.
        sq1 = rect_pts(4.0, 4.0, 12.0, 12.0)
        tri2 = [8.0, 8.0, 20.0, 8.0, 8.0, 20.0]
        sq1b = rect_pts(8.0, 8.0, 16.0, 16.0)
        rcommits = [
            (sq1, RED, 1.0),    # store the square in slot 1
            (tri2, blue, 2.0),  # store the triangle in slot 2
            (sq1b, green, 1.0),  # move + recolor the square (edit slot 1)
            ([], blue, 2.0),    # delete the triangle (empty slot 2)
        ]
        rplan = {}
        t = 10
        ends = []
        for pts, color, sid in rcommits:
            rplan[t] = {"shapePoints": list(pts),
                        "shapeColors": [color] * (len(pts) // 2),
                        "wireMode": False, "shapeId": sid}
            rplan[t + 2] = {"pushShape": True}
            rplan[t + 4] = {"pushShape": False}
            rplan[t + 6] = {"drawAll": True}
            rplan[t + 8] = {"drawAll": False}
            # a commit clears (64 rows) and repaints every live slot; the
            # slot below is sized for two small shapes with margin
            t += 64 + 60
            ends.append(t)
        rtotal = t + 20

        sim, gids, polyon, son, pts_aid, cols_aid = fresh_sim(dump_path)
        sim.inputs = {"shapePoints": [0.0] * 32, "shapeColors": [],
                      "pushShape": False, "wireMode": False,
                      "shapeId": 0.0, "drawAll": False,
                      "clearAll": False, "position": (0.0, 0.0, 0.0), "rotation": (0.0, 0.0, 0.0), "scale": (0.0, 0.0, 0.0), "parentShapeId": 0.0, "brightness": 100.0}
        sim.run(1)
        sim.inputs = {k: v for k, v in sim.inputs.items()
                      if k != "shapePoints"}
        snaps = {}

        def watchr(sn, tick):
            if tick in rplan:
                step = rplan[tick]
                if "shapePoints" in step:
                    slide(sn, pts_aid, cols_aid, step["shapePoints"],
                          step.get("shapeColors"))
                    step = {k: v for k, v in step.items()
                            if k != "shapePoints" and k != "shapeColors"}
                sn.inputs = dict(sn.inputs, **step)
            if tick in ends:
                snaps[tick] = {i: col(sn, gids, i)
                               for i in range(SW * SW)}

        sim.run(rtotal, on_tick=watchr)

        def expect_wall(snap, want, label):
            bad = [i for i in range(SW * SW) if snap[i] != want.get(i, BLACK)]
            return expect(not bad, label,
                          "%d of 4096 differ, first at %d"
                          % (len(bad), bad[0] if bad else 0))

        want1 = {p: RED for p in poly_pixels(sq1)}
        ok &= expect_wall(snaps[ends[0]], want1, "retained store paints")
        want2 = dict(want1)
        for p in poly_pixels(tri2):
            want2[p] = blue
        ok &= expect_wall(snaps[ends[1]], want2, "second slot composes")
        want3 = {p: green for p in poly_pixels(sq1b)}
        for p in poly_pixels(tri2):
            want3[p] = blue
        ok &= expect_wall(snaps[ends[2]], want3,
                          "edit replaces in place (old square gone)")
        want4 = {p: green for p in poly_pixels(sq1b)}
        ok &= expect_wall(snaps[ends[3]], want4,
                          "delete removes (triangle gone)")

        # ---- clearAll forgets everything and blacks the wall ---------------
        # Pulse clearAll on top of the live green square: the wall must go
        # fully black, and a later store into slot 2 must show ONLY the new
        # triangle -- if the clear had merely blacked without forgetting,
        # the square would resurrect on recomposite.
        cplan = {}
        # setup commit first (ticks 2..10 stage and fire, recomposite after)
        cplan[2] = {"shapePoints": list(sq1b),
                    "shapeColors": [green] * 4,
                    "wireMode": False, "shapeId": 1.0}
        cplan[4] = {"pushShape": True}
        cplan[6] = {"pushShape": False}
        cplan[8] = {"drawAll": True}
        cplan[10] = {"drawAll": False}
        # clear pulse once the setup recomposite is done (~90 ticks):
        # clearAll forgets the slots and stages the black fill, which
        # the NEXT drawAll runs -- so pulse drawAll right after and the
        # wall is black ~64 rows later.  A later store into slot 2 must
        # show ONLY the new triangle -- if the clear had merely blacked
        # without forgetting, the square would resurrect on recomposite.
        ct = 110
        cplan[ct] = {"clearAll": True}
        cplan[ct + 2] = {"clearAll": False, "position": (0.0, 0.0, 0.0), "rotation": (0.0, 0.0, 0.0), "scale": (0.0, 0.0, 0.0), "parentShapeId": 0.0, "brightness": 100.0}
        cplan[ct + 4] = {"drawAll": True}
        cplan[ct + 6] = {"drawAll": False}
        st = ct + 110
        cplan[st] = {"shapePoints": list(tri2),
                     "shapeColors": [blue] * 3,
                     "wireMode": False, "shapeId": 2.0}
        cplan[st + 2] = {"pushShape": True}
        cplan[st + 4] = {"pushShape": False}
        cplan[st + 6] = {"drawAll": True}
        cplan[st + 8] = {"drawAll": False}
        cblack_at = ct + 90
        cend = st + 200

        sim, gids, polyon, son, pts_aid, cols_aid = fresh_sim(dump_path)
        sim.inputs = {"shapePoints": [0.0] * 32, "shapeColors": [],
                      "pushShape": False, "wireMode": False,
                      "shapeId": 1.0, "drawAll": False,
                      "clearAll": False, "position": (0.0, 0.0, 0.0), "rotation": (0.0, 0.0, 0.0), "scale": (0.0, 0.0, 0.0), "parentShapeId": 0.0, "brightness": 100.0}
        sim.run(1)
        sim.inputs = {k: v for k, v in sim.inputs.items()
                      if k != "shapePoints"}
        # first re-create the live square with a normal retained commit
        cplan[2] = {"shapePoints": list(sq1b),
                    "shapeColors": [green] * 4,
                    "wireMode": False, "shapeId": 1.0}
        cplan[4] = {"pushShape": True}
        cplan[6] = {"pushShape": False}
        cplan[8] = {"drawAll": True}
        cplan[10] = {"drawAll": False}
        cblack = {}
        cwall = {}

        def watchc(sn, tick):
            if tick in cplan:
                step = cplan[tick]
                if "shapePoints" in step:
                    slide(sn, pts_aid, cols_aid, step["shapePoints"],
                          step.get("shapeColors"))
                    step = {k: v for k, v in step.items()
                            if k != "shapePoints" and k != "shapeColors"}
                sn.inputs = dict(sn.inputs, **step)
            if tick == cblack_at:
                cblack.update({i: col(sn, gids, i)
                               for i in range(SW * SW)})
            if tick == cend:
                cwall.update({i: col(sn, gids, i)
                              for i in range(SW * SW)})

        sim.run(cend + 1, on_tick=watchc)
        ok &= expect(all(v == BLACK for v in cblack.values()),
                     "clearAll blacks the wall",
                     "%d non-black" % sum(
                         1 for v in cblack.values() if v != BLACK))
        wantc = {p: blue for p in poly_pixels(tri2)}
        badc = [i for i in range(SW * SW)
                if cwall.get(i, BLACK) != wantc.get(i, BLACK)]
        ok &= expect(not badc, "slots stay forgotten after clear",
                     "%d of 4096 differ, first at %d"
                     % (len(badc), badc[0] if badc else 0))

        # ---- brightness: the live slider dims RGB, keeps alpha --------
        # Two non-overlapping rects in one run: rectA paints while the
        # slider reads 50 (RGB halved, alpha untouched), rectB after it
        # returns to 0.0 -- the unwired default, full colours.  Both
        # immediate fills; the slider rides the plan like any level.
        bA = rect_pts(2.0, 2.0, 6.0, 6.0)
        bB = rect_pts(10.0, 10.0, 14.0, 14.0)
        bplan = {}
        bplan[10] = {"shapePoints": list(bA), "shapeColors": [RED] * 4,
                     "wireMode": False, "shapeId": 0.0,
                     "brightness": 50.0}
        bplan[12] = {"pushShape": True}
        bplan[14] = {"pushShape": False}
        bplan[16] = {"drawAll": True}
        bplan[18] = {"drawAll": False}
        bplan[40] = {"shapePoints": list(bB), "shapeColors": [blue] * 4,
                     "wireMode": False, "shapeId": 0.0,
                     "brightness": 0.0}
        bplan[42] = {"pushShape": True}
        bplan[44] = {"pushShape": False}
        bplan[46] = {"drawAll": True}
        bplan[48] = {"drawAll": False}
        btotal = 130

        sim, gids, polyon, son, pts_aid, cols_aid = fresh_sim(dump_path)
        sim.inputs = {"shapePoints": [0.0] * 32, "shapeColors": [],
                      "pushShape": False, "wireMode": False,
                      "shapeId": 0.0, "drawAll": False,
                      "clearAll": False, "position": (0.0, 0.0, 0.0), "rotation": (0.0, 0.0, 0.0), "scale": (0.0, 0.0, 0.0), "parentShapeId": 0.0, "brightness": 100.0}
        sim.run(1)
        sim.inputs = {k: v for k, v in sim.inputs.items()
                      if k != "shapePoints"}

        def watchb(sn, tick):
            if tick in bplan:
                step = bplan[tick]
                if "shapePoints" in step:
                    slide(sn, pts_aid, cols_aid, step["shapePoints"],
                          step.get("shapeColors"))
                    step = {k: v for k, v in step.items()
                            if k != "shapePoints" and k != "shapeColors"}
                sn.inputs = dict(sn.inputs, **step)

        sim.run(btotal, on_tick=watchb)

        def dim(c):
            return (c[0] * 0.5, c[1] * 0.5, c[2] * 0.5, c[3])

        wantb = {}
        for p in poly_pixels(bA):
            wantb[p] = dim(RED)
        for p in poly_pixels(bB):
            wantb[p] = blue
        badb = [i for i in range(SW * SW)
                if not close(col(sim, gids, i), wantb.get(i, BLACK))]
        ok &= expect(not badb, "brightness dims RGB, keeps alpha",
                     "%d of 4096 differ, first at %d"
                     % (len(badb), badb[0] if badb else 0))

        # ---- brightness repaints by itself, no drawAll ----------------
        # A retained square plus one immediate rect, both painted at
        # full brightness; then ONLY the slider moves to 50.  The chip
        # reruns the retained recomposite (no clear -- nothing moved,
        # so overwriting is exact) and replays the immediate rect, and
        # the whole wall dims with no push and no drawAll.
        rA = rect_pts(4.0, 4.0, 12.0, 12.0)
        rB = rect_pts(20.0, 20.0, 26.0, 24.0)
        aplan = {}
        aplan[10] = {"shapePoints": list(rA),
                     "shapeColors": [RED] * 4,
                     "wireMode": False, "shapeId": 1.0,
                     "brightness": 100.0}
        aplan[12] = {"pushShape": True}
        aplan[14] = {"pushShape": False}
        aplan[16] = {"drawAll": True}
        aplan[18] = {"drawAll": False}
        aplan[140] = {"shapePoints": list(rB),
                      "shapeColors": [blue] * 4,
                      "wireMode": False, "shapeId": 0.0}
        aplan[142] = {"pushShape": True}
        aplan[144] = {"pushShape": False}
        aplan[146] = {"drawAll": True}
        aplan[148] = {"drawAll": False}
        aplan[170] = {"brightness": 50.0}
        aend = 320

        sim, gids, polyon, son, pts_aid, cols_aid = fresh_sim(dump_path)
        sim.inputs = {"shapePoints": [0.0] * 32, "shapeColors": [],
                      "pushShape": False, "wireMode": False,
                      "shapeId": 0.0, "drawAll": False,
                      "clearAll": False, "position": (0.0, 0.0, 0.0), "rotation": (0.0, 0.0, 0.0), "scale": (0.0, 0.0, 0.0), "parentShapeId": 0.0, "brightness": 100.0}
        sim.run(1)
        sim.inputs = {k: v for k, v in sim.inputs.items()
                      if k != "shapePoints"}

        def watcha(sn, tick):
            if tick in aplan:
                step = aplan[tick]
                if "shapePoints" in step:
                    slide(sn, pts_aid, cols_aid, step["shapePoints"],
                          step.get("shapeColors"))
                    step = {k: v for k, v in step.items()
                            if k != "shapePoints" and k != "shapeColors"}
                sn.inputs = dict(sn.inputs, **step)

        sim.run(aend, on_tick=watcha)

        wanta = {}
        for p in poly_pixels(rA):
            wanta[p] = dim(RED)
        for p in poly_pixels(rB):
            wanta[p] = dim(blue)
        bada = [i for i in range(SW * SW)
                if not close(col(sim, gids, i), wanta.get(i, BLACK))]
        ok &= expect(not bada, "brightness repaints with no drawAll",
                     "%d of 4096 differ, first at %d"
                     % (len(bada), bada[0] if bada else 0))

        # ---- transforms + parents: move, scale, rotate, follow -------
        # Five retained commits in one run, snapshotted each time: a
        # scaled+moved square, a rotated rect edit, a child attached to
        # slot 1, the parent moved again (child follows), the child
        # deleted.  The model composes each slot's world transform
        # through its ancestors exactly like the chip's walk.
        xcommits = [
            (rect_pts(4.0, 4.0, 12.0, 12.0), [RED] * 4, 1.0,
             (8.0, 0.0), 0.0, (2.0, 1.0), 0.0),
            (rect_pts(20.0, 20.0, 28.0, 24.0), [blue] * 4, 1.0,
             (4.0, 4.0), 0.5, (1.0, 1.0), 0.0),
            ([20.0, 20.0, 26.0, 20.0, 20.0, 26.0],
             [green] * 3, 2.0, (0.0, 0.0), 0.0, (1.0, 1.0), 1.0),
            (rect_pts(20.0, 20.0, 28.0, 24.0), [blue] * 4, 1.0,
             (12.0, 4.0), 0.5, (1.0, 1.0), 0.0),
            ([], [], 2.0, (0.0, 0.0), 0.0, (1.0, 1.0), 0.0),
        ]
        xplan = {}
        t = 10
        xends = []
        for pts, cols, sid, pos, ang, scl, par in xcommits:
            xplan[t] = {"shapePoints": list(pts),
                        "shapeColors": list(cols),
                        "wireMode": False, "shapeId": sid,
                        "position": (pos[0], pos[1], 0.0),
                        "rotation": (0.0, 0.0, ang),
                        "scale": (scl[0], scl[1], 1.0),
                        "parentShapeId": par}
            xplan[t + 2] = {"pushShape": True}
            xplan[t + 4] = {"pushShape": False}
            xplan[t + 6] = {"drawAll": True}
            xplan[t + 8] = {"drawAll": False}
            # a commit clears (64 rows) and repaints every live slot;
            # parented slots pay one ancestor walk of slow computed
            # reads each, so this allows extra margin over the plain
            # retained section
            t += 64 + 110
            xends.append(t)
        xtotal = t + 20

        sim, gids, polyon, son, pts_aid, cols_aid = fresh_sim(dump_path)
        sim.inputs = {"shapePoints": [0.0] * 32, "shapeColors": [],
                      "pushShape": False, "wireMode": False,
                      "shapeId": 0.0, "drawAll": False,
                      "clearAll": False, "position": (0.0, 0.0, 0.0), "rotation": (0.0, 0.0, 0.0), "scale": (0.0, 0.0, 0.0), "parentShapeId": 0.0, "brightness": 100.0}
        sim.run(1)
        sim.inputs = {k: v for k, v in sim.inputs.items()
                      if k != "shapePoints"}
        xsnaps = {}

        def watchx(sn, tick):
            if tick in xplan:
                step = xplan[tick]
                if "shapePoints" in step:
                    slide(sn, pts_aid, cols_aid, step["shapePoints"],
                          step.get("shapeColors"))
                    step = {k: v for k, v in step.items()
                            if k != "shapePoints" and k != "shapeColors"}
                sn.inputs = dict(sn.inputs, **step)
            if tick in xends:
                xsnaps[tick] = {i: col(sn, gids, i)
                                for i in range(SW * SW)}

        sim.run(xtotal, on_tick=watchx)

        def world_of(slots, key, depth=0):
            _p, _c, _w, pos, ang, scl, par = slots[key]
            local = (pos, ang, (scl[0] or 1.0, scl[1] or 1.0))
            if depth > 8 or par < 0.5 or int(par) not in slots:
                return local
            return xf_compose(world_of(slots, int(par), depth + 1),
                              local)

        xslots = {}
        xlabels = ["scaled+moved square paints",
                   "rotated rect edit paints",
                   "child attaches to slot 1",
                   "parent move carries the child",
                   "delete drops the child"]
        for ci, end in enumerate(xends):
            pts, cols, sid, pos, ang, scl, par = xcommits[ci]
            if not pts:
                xslots.pop(int(sid), None)
            else:
                xslots[int(sid)] = (pts, cols, False, pos, ang, scl,
                                    par)
            wantx = {}
            for kk in sorted(xslots):
                spts, scols = xslots[kk][0], xslots[kk][1]
                wpos, wang, wscl = world_of(xslots, kk)
                for q, c in poly_colors(
                        xf_points(spts, wpos, wang, wscl),
                        scols).items():
                    wantx[q] = c
            badx = [i for i in range(SW * SW)
                    if not close(xsnaps[end][i], wantx.get(i, BLACK))]
            ok &= expect(not badx, xlabels[ci],
                         "%d of 4096 differ, first at %d"
                         % (len(badx), badx[0] if badx else 0))

        # ---- the load-time phantom paints correctly -----------------------
        # Tick-0 seeding fires every Change detector once, so a walk arms
        # from the seeded array with no pulse at all.  Seed a real closed
        # square with wire low: the single push stages a fill.  The arm can
        # race the seed landing, so this pins what matters -- every painted
        # pixel belongs to the square (no torn spans), and both walks end
        # on their own -- rather than the exact extent.
        sq = [10.0, 10.0, 20.0, 10.0, 20.0, 20.0, 10.0, 20.0, 10.0, 10.0]
        sim, gids, polyon, son, pts_aid, cols_aid = fresh_sim(dump_path)
        sim.inputs = {"shapePoints": list(sq), "shapeColors": [blue] * 5,
                      "pushShape": False, "wireMode": False,
                      "shapeId": 0.0, "drawAll": False,
                      "clearAll": False, "position": (0.0, 0.0, 0.0), "rotation": (0.0, 0.0, 0.0), "scale": (0.0, 0.0, 0.0), "parentShapeId": 0.0, "brightness": 100.0}
        on3 = []
        on3s = []

        def watch3(sn, tick):
            if sn.vars.get(polyon):
                on3.append(tick)
            if sn.vars.get(son):
                on3s.append(tick)

        sim.run(140, on_tick=watch3)
        allowed = poly_pixels(sq)
        painted = {i for i in range(SW * SW) if col(sim, gids, i) == blue}
        ok &= expect(painted <= allowed, "phantom paints only the seed",
                     "%d strays, first at %d"
                     % (len(painted - allowed),
                        min(painted - allowed) if painted - allowed else 0))
        ok &= expect(not any(t > 120 for t in on3), "phantom fill ends",
                     "walk at %r" % ([t for t in on3 if t > 120][:8],))
        ok &= expect(not any(t > 120 for t in on3s), "phantom stroke ends",
                     "walk at %r" % ([t for t in on3s if t > 120][:8],))

        # ---- a bare chip paints nothing ---------------------------------
        # All scalar ports at their game defaults (unwired reads 0/False;
        # the sim reads None for unset, which string-compares wrong -- an
        # unset shapeId once read back as 8 -- so defaults are seeded to
        # model unwired faithfully).  No array: a missing array reads
        # length 0, an empty shape, silent.
        sim, gids, polyon, son, pts_aid, cols_aid = fresh_sim(dump_path)
        sim.inputs = {"pushShape": False, "wireMode": False,
                      "shapeId": 0.0, "drawAll": False,
                      "clearAll": False, "position": (0.0, 0.0, 0.0), "rotation": (0.0, 0.0, 0.0), "scale": (0.0, 0.0, 0.0), "parentShapeId": 0.0, "brightness": 100.0}
        sim.run(60)
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
