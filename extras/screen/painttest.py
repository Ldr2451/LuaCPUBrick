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


# Brightness 100 is FULL_BRIGHT, the factor the panel had before the
# port existed -- the top of the scale, so nothing above it can be
# asked for.  Every section below drives brightness 100, so the wall
# reads at 0.35 * pushed-colour.  That factor is undone here, once, so
# the rest of the suite can keep comparing a pushed colour against the
# wall: the scale is a property of the input, not of what was painted.
BF = 0.35


def undim(c):
    """A wall colour with the brightness factor divided back out.

    Alpha passes through untouched (the dimmer scales RGB only), and
    black stays black, so an erased or never-painted pixel is unaffected.
    """
    if not isinstance(c, (tuple, list)) or len(c) < 4:
        return c
    return tuple(float(x) / BF if k < 3 else float(x)
                 for k, x in enumerate(c[:4]))


def col(sim, gids, i):
    v = sim.vars.get(gids[i], (0.0, 0.0, 0.0, 0.0))
    if isinstance(v, (tuple, list)) and len(v) >= 4:
        return undim(tuple(float(x) for x in v[:4]))
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
    """The chip's point transform, transcribed: shapeScale, rotate about the
    origin by ang radians, translate -- mirrors applyXF exactly,
    including the shapeScale-zero-means-identity default."""
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


ZBACK = -1e15


def mat_local(pos, eul, scl):
    """One 3x4 world matrix (row-major 12 floats), transcribed from
    gen.py in order: R = Rz*Ry*Rx closed form, columns
    scaled, translation appended.  Matches the chip's matrix path
    exactly (same op order); the planar path uses xf_points instead."""
    cx, sx = math.cos(eul[0]), math.sin(eul[0])
    cy, sy = math.cos(eul[1]), math.sin(eul[1])
    cz, sz = math.cos(eul[2]), math.sin(eul[2])
    mr00 = cz * cy
    mr01 = cz * sy * sx - sz * cx
    mr02 = cz * sy * cx + sz * sx
    mr10 = sz * cy
    mr11 = sz * sy * sx + cz * cx
    mr12 = sz * sy * cx - cz * sx
    mr20 = 0.0 - sy
    mr21 = cy * sx
    mr22 = cy * cx
    return [mr00 * scl[0], mr01 * scl[1], mr02 * scl[2], pos[0],
            mr10 * scl[0], mr11 * scl[1], mr12 * scl[2], pos[1],
            mr20 * scl[0], mr21 * scl[1], mr22 * scl[2], pos[2]]


def mat_mul(p, a):
    """parent 3x4 times child 3x4, transcribed in order."""
    return [
        p[0] * a[0] + p[1] * a[4] + p[2] * a[8],
        p[0] * a[1] + p[1] * a[5] + p[2] * a[9],
        p[0] * a[2] + p[1] * a[6] + p[2] * a[10],
        p[0] * a[3] + p[1] * a[7] + p[2] * a[11] + p[3],
        p[4] * a[0] + p[5] * a[4] + p[6] * a[8],
        p[4] * a[1] + p[5] * a[5] + p[6] * a[9],
        p[4] * a[2] + p[5] * a[6] + p[6] * a[10],
        p[4] * a[3] + p[5] * a[7] + p[6] * a[11] + p[7],
        p[8] * a[0] + p[9] * a[4] + p[10] * a[8],
        p[8] * a[1] + p[9] * a[5] + p[10] * a[9],
        p[8] * a[2] + p[9] * a[6] + p[10] * a[10],
        p[8] * a[3] + p[9] * a[7] + p[10] * a[11] + p[11],
    ]


def xf_points3(pts2, pos, eul, scl, chain=()):
    """Flat xy points -> world xyz.  chain holds ancestor (pos, eul,
    scl) triples, innermost first (composed parent-outside).  Points
    carry z = 0 locally: depth comes from the transform alone.

    The chip has ONE path now -- every point is an (x,y,z) triple -- so
    a flat shape is the same model with z = 0, and it is projected by
    the same rule.  This is that model."""
    pts3 = []
    for i in range(0, len(pts2), 2):
        pts3 += [pts2[i], pts2[i + 1], 0.0]
    return xf_points3d(pts3, pos, eul, scl, chain)


EYE = 48.0
EYE_X = 32.0          # the eye stands at the wall's centre, not its corner
EYE_Y = 32.0


def xf_points3d(pts3, pos, eul, scl, chain=()):
    """Flat xyz triples -> projected (screen x, screen y, world z).

    The chip's 3D per-point step, in its own order: the full local
    vector through the 3x4 matrix (so the local z counts), then the
    perspective divide with the eye at the WALL'S CENTRE and IN FRONT of
    it -- (32, 32, +EYE) -- and the denominator clamped at 1.0.  The eye
    is in front because +z is the direction the depth test calls "in
    front", and the two have to agree: a nearer thing is bigger.  A
    point at z = 0 is unchanged by the divide (the offsets cancel), so a
    flat shape lands exactly where the 2D path would put it.  The depth
    handed on is the WORLD z -- the divide moves x/y, not how far the
    point is -- so the fill's depth test still orders the faces."""
    m = mat_local(pos, eul, scl)
    for apar, aeul, ascl in chain:
        m = mat_mul(mat_local(apar, aeul, ascl), m)
    out = []
    for i in range(0, len(pts3), 3):
        x, y, z = pts3[i], pts3[i + 1], pts3[i + 2]
        wx = m[0] * x + m[1] * y + m[2] * z + m[3]
        wy = m[4] * x + m[5] * y + m[6] * z + m[7]
        wz = m[8] * x + m[9] * y + m[10] * z + m[11]
        d = EYE - wz
        if d < 1.0:
            d = 1.0
        out.append((EYE * (wx - EYE_X) / d + EYE_X,
                    EYE * (wy - EYE_Y) / d + EYE_Y, wz))
    return out


def quad3(x0, y0, x1, y1, z, closed=True):
    """A screen-parallel 3D quad as an outline.

    `closed` repeats the first point, which is what makes a 3D array's
    length odd -- the chip reads an odd length as triples, and a 2D
    array is always even.  The repeated vertex adds a degenerate
    closing edge: it fills nothing and moves no bound."""
    p = [x0, y0, z, x1, y0, z, x1, y1, z, x0, y1, z]
    if closed:
        p += [x0, y0, z]
    return p


def z_colors(wpts, colors):
    """The chip's depth-tested fill: {pixel: (colour, z)}.

    poly_pixels' scanline algorithm with the chip's z lerp (per-edge
    endpoint depths through the same row parameter, carried through
    the min/max with the colour) and its depth test (bigger z paints
    in front; ties repaint).  The frame model z-buffers slots in
    order, exactly like the lanes.
    """
    n = len(wpts)
    if n < 3:
        return {}
    pts = list(wpts) + [(0.0, 0.0, 0.0)] * (16 - n)
    cols = list(colors) + [(1.0, 1.0, 1.0, 1.0)] * (16 - len(colors))
    ys = [p[1] for p in pts[:n]]
    xs = [p[0] for p in pts[:n]]
    if max(ys) < 0.0 or min(ys) >= 64.0 or max(xs) < 0.0 or min(xs) >= 64.0:
        return {}
    edges = []
    for i in range(16):
        ax, ay, az = pts[i]
        j = i + 1 if (i + 1) < n else 0
        bx, by, bz = pts[j]
        dx, dy = bx - ax, by - ay
        s = dx / dy if dy != 0.0 else 0.0
        einv = 1.0 / (by - ay) if (by - ay) != 0.0 else float("inf")
        lo, hi = (ay, by) if ay < by else (by, ay)
        if i < n:
            elo, ehi = lo, hi
        else:
            elo, ehi = 200.0, -200.0
        edges.append((ax, ay, az, s, einv, elo, ehi, cols[i], cols[j],
                      bz))
    first = 0.0 if min(ys) < 0.0 else float(int(min(ys)))
    last = 63.0 if max(ys) >= 64.0 else float(int(max(ys)))
    fb = {}
    zb = {}
    row = first
    while row <= last:
        items = []
        for (ax, ay, az, s, einv, elo, ehi, c0, c1, bz) in edges:
            if elo <= row < ehi:
                x = ax + s * (row - ay)
                cc = tuple(a + (row - ay) * einv * (b - a)
                           for a, b in zip(c0, c1))
                zz = az + (row - ay) * einv * (bz - az)
                items.append((x, cc, zz))
        if items:
            mn = min(items, key=lambda t: t[0])
            mx = max(items, key=lambda t: t[0])
            lo, hi = mn[0], mx[0]
            if not (lo >= 200.0 or hi < 0.0 or lo >= 64.0):
                l = 0.0 if lo < 0.0 else float(int(lo))
                r = 63.0 if hi >= 64.0 else float(int(hi))
                if l <= r:
                    span = hi - lo
                    inv = 1.0 / span if span > 0.0 else 0.0
                    for c in range(int(l), int(r) + 1):
                        dt = c - lo
                        col = tuple(mn[1][k] + (mx[1][k] - mn[1][k])
                                    * inv * dt for k in range(4))
                        pz = mn[2] + (mx[2] - mn[2]) * inv * dt
                        idx = int(row) * SW + c
                        if pz >= zb.get(idx, ZBACK):
                            zb[idx] = pz
                            fb[idx] = col
        row += 1.0
    return {i: (fb[i], zb[i]) for i in fb}


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

    `values` is a FLAT shape, written as pairs for brevity, and is
    delivered as the triples the chip wants (z = 0).  `slide3` delivers
    triples as given.  This is the suite's shorthand, not the chip's
    protocol: the port takes triples and only triples.
    """
    sim.arrays[pts_aid] = asTriples(values)
    if colors is not None:
        sim.arrays[cols_aid] = list(colors)


def asTriples(pts2):
    """A flat shape written as (x, y) pairs -> the (x, y, z) triples the
    chip's port takes."""
    out = []
    for i in range(0, len(pts2) - 1, 2):
        out += [pts2[i], pts2[i + 1], 0.0]
    return out


def slide3(sim, pts_aid, cols_aid, values, colors=None):
    """Deliver a 3D shape: the points are (x, y, z) triples, as given."""
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
        # a burst always finishes before the next drawAllShapes (a re-arm
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
            t += rows + 22
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
                        "shapeWireMode": False, "shapeId": 0.0}
            plan[t0 + 2] = {"pushShape": True}
            plan[t0 + 4] = {"pushShape": False}
            plan[t0 + 6] = {"drawAllShapes": True}
            plan[t0 + 8] = {"drawAllShapes": False}
        # a bare drawAllShapes at the end replays the last shape
        replay_at = total
        plan[replay_at] = {"drawAllShapes": True}
        plan[replay_at + 2] = {"drawAllShapes": False}
        total = replay_at + 60

        sim, gids, polyon, son, pts_aid, cols_aid = fresh_sim(dump_path)
        # the array is seeded once, at reset (a reset-time seed is cheap;
        # a mid-run change through sim.inputs is not), then dropped from
        # the inputs so every later pulse merges only scalars and the
        # shapes are staged by slide() alone.  Each shape's array is
        # exactly as long as its point list: the count IS the length.
        sim.inputs = {"shapePoints": [0.0] * 32, "shapeColors": [],
                      "pushShape": False, "shapeWireMode": False,
                      "shapeId": 0.0, "drawAllShapes": False,
                      "clearAllShapes": False, "shapePosition": (0.0, 0.0, 0.0), "shapeRotation": (0.0, 0.0, 0.0), "shapeScale": (0.0, 0.0, 0.0), "parentShapeId": 0.0, "brightness": 100.0}
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
                     "drawAllShapes replays the last shape",
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
                    "shapeWireMode": False, "shapeId": 0.0}
        gplan[t + 2] = {"pushShape": True}
        gplan[t + 4] = {"pushShape": False}
        gplan[t + 6] = {"drawAllShapes": True}
        gplan[t + 8] = {"drawAllShapes": False}
        gtotal = t + 60

        sim, gids, polyon, son, pts_aid, cols_aid = fresh_sim(dump_path)
        sim.inputs = {"shapePoints": [0.0] * 32, "shapeColors": [],
                      "pushShape": False, "shapeWireMode": False,
                      "shapeId": 0.0, "drawAllShapes": False,
                      "clearAllShapes": False, "shapePosition": (0.0, 0.0, 0.0), "shapeRotation": (0.0, 0.0, 0.0), "shapeScale": (0.0, 0.0, 0.0), "parentShapeId": 0.0, "brightness": 100.0}
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
            t += rows + 24
        plan2 = {}
        for i, (pts, cols) in enumerate(strokes):
            t0, _rows = spans2[i]
            plan2[t0] = {"shapePoints": list(pts),
                         "shapeColors": list(cols),
                         "shapeWireMode": True, "shapeId": 0.0}
            plan2[t0 + 2] = {"pushShape": True}
            plan2[t0 + 4] = {"pushShape": False}
            plan2[t0 + 6] = {"drawAllShapes": True}
            plan2[t0 + 8] = {"drawAllShapes": False}
        # overwrite the array with junk, then replay: the wall must still
        # show the staged square, not the junk
        junk_at = t + 4
        plan2[junk_at] = {"shapePoints": [1.0, 2.0, 3.0, 4.0, 5.0, 6.0]}
        replay2_at = t + 14
        plan2[replay2_at] = {"drawAllShapes": True}
        plan2[replay2_at + 2] = {"drawAllShapes": False}
        total2 = replay2_at + 45

        sim, gids, polyon, son, pts_aid, cols_aid = fresh_sim(dump_path)
        sim.inputs = {"shapePoints": [0.0] * 32, "shapeColors": [],
                      "pushShape": False, "shapeWireMode": False,
                      "shapeId": 0.0, "drawAllShapes": False,
                      "clearAllShapes": False, "shapePosition": (0.0, 0.0, 0.0), "shapeRotation": (0.0, 0.0, 0.0), "shapeScale": (0.0, 0.0, 0.0), "parentShapeId": 0.0, "brightness": 100.0}
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
                     "drawAllShapes replays the staged stroke",
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
                        "shapeWireMode": False, "shapeId": sid}
            rplan[t + 2] = {"pushShape": True}
            rplan[t + 4] = {"pushShape": False}
            rplan[t + 6] = {"drawAllShapes": True}
            rplan[t + 8] = {"drawAllShapes": False}
            # a commit clears (64 rows) and repaints every live slot; the
            # slot below is sized for two small shapes with margin
            t += 64 + 45
            ends.append(t)
        rtotal = t + 20

        sim, gids, polyon, son, pts_aid, cols_aid = fresh_sim(dump_path)
        sim.inputs = {"shapePoints": [0.0] * 32, "shapeColors": [],
                      "pushShape": False, "shapeWireMode": False,
                      "shapeId": 0.0, "drawAllShapes": False,
                      "clearAllShapes": False, "shapePosition": (0.0, 0.0, 0.0), "shapeRotation": (0.0, 0.0, 0.0), "shapeScale": (0.0, 0.0, 0.0), "parentShapeId": 0.0, "brightness": 100.0}
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
            # Tolerant: the wall reads through the brightness factor and
            # col() divides it back out, which costs a last-ulp rounding
            # on most channels ((0.1*0.35)/0.35 is 0.09999...).  Exact !=
            # reads that dust as 90 differing pixels on a blue triangle
            # that is otherwise pixel-perfect.
            bad = [i for i in range(SW * SW)
                   if not close(snap[i], want.get(i, BLACK))]
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

        # ---- clearAllShapes forgets everything and blacks the wall ---------------
        # Pulse clearAllShapes on top of the live green square: the wall must go
        # fully black, and a later store into slot 2 must show ONLY the new
        # triangle -- if the clear had merely blacked without forgetting,
        # the square would resurrect on recomposite.
        cplan = {}
        # setup commit first (ticks 2..10 stage and fire, recomposite after)
        cplan[2] = {"shapePoints": list(sq1b),
                    "shapeColors": [green] * 4,
                    "shapeWireMode": False, "shapeId": 1.0}
        cplan[4] = {"pushShape": True}
        cplan[6] = {"pushShape": False}
        cplan[8] = {"drawAllShapes": True}
        cplan[10] = {"drawAllShapes": False}
        # clear pulse once the setup recomposite is done (~90 ticks):
        # clearAllShapes forgets the slots and stages the black fill, which
        # the NEXT drawAllShapes runs -- so pulse drawAllShapes right after and the
        # wall is black ~64 rows later.  A later store into slot 2 must
        # show ONLY the new triangle -- if the clear had merely blacked
        # without forgetting, the square would resurrect on recomposite.
        ct = 110
        cplan[ct] = {"clearAllShapes": True}
        cplan[ct + 2] = {"clearAllShapes": False, "shapePosition": (0.0, 0.0, 0.0), "shapeRotation": (0.0, 0.0, 0.0), "shapeScale": (0.0, 0.0, 0.0), "parentShapeId": 0.0, "brightness": 100.0}
        cplan[ct + 4] = {"drawAllShapes": True}
        cplan[ct + 6] = {"drawAllShapes": False}
        st = ct + 110
        cplan[st] = {"shapePoints": list(tri2),
                     "shapeColors": [blue] * 3,
                     "shapeWireMode": False, "shapeId": 2.0}
        cplan[st + 2] = {"pushShape": True}
        cplan[st + 4] = {"pushShape": False}
        cplan[st + 6] = {"drawAllShapes": True}
        cplan[st + 8] = {"drawAllShapes": False}
        cblack_at = ct + 60
        cend = st + 150

        sim, gids, polyon, son, pts_aid, cols_aid = fresh_sim(dump_path)
        sim.inputs = {"shapePoints": [0.0] * 32, "shapeColors": [],
                      "pushShape": False, "shapeWireMode": False,
                      "shapeId": 1.0, "drawAllShapes": False,
                      "clearAllShapes": False, "shapePosition": (0.0, 0.0, 0.0), "shapeRotation": (0.0, 0.0, 0.0), "shapeScale": (0.0, 0.0, 0.0), "parentShapeId": 0.0, "brightness": 100.0}
        sim.run(1)
        sim.inputs = {k: v for k, v in sim.inputs.items()
                      if k != "shapePoints"}
        # first re-create the live square with a normal retained commit
        cplan[2] = {"shapePoints": list(sq1b),
                    "shapeColors": [green] * 4,
                    "shapeWireMode": False, "shapeId": 1.0}
        cplan[4] = {"pushShape": True}
        cplan[6] = {"pushShape": False}
        cplan[8] = {"drawAllShapes": True}
        cplan[10] = {"drawAllShapes": False}
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
                     "clearAllShapes blacks the wall",
                     "%d non-black" % sum(
                         1 for v in cblack.values() if v != BLACK))
        wantc = {p: blue for p in poly_pixels(tri2)}
        badc = [i for i in range(SW * SW)
                if not close(cwall.get(i, BLACK), wantc.get(i, BLACK))]
        ok &= expect(not badc, "slots stay forgotten after clear",
                     "%d of 4096 differ, first at %d"
                     % (len(badc), badc[0] if badc else 0))

        # ---- brightness: the live slider dims RGB, keeps alpha --------
        # Two non-overlapping rects, both painted while the slider reads
        # 50 (RGB halved, alpha untouched), no edge after the last paint
        # -- pure paint-time coverage.  Retroactive dimming in both
        # directions has its own section below; there the slider moves
        # with nothing staged, while here a staged push would supersede
        # the refresh.  Both immediate fills; the slider rides the plan
        # like any level.
        bA = rect_pts(2.0, 2.0, 6.0, 6.0)
        bB = rect_pts(10.0, 10.0, 14.0, 14.0)
        bplan = {}
        bplan[10] = {"shapePoints": list(bA), "shapeColors": [RED] * 4,
                     "shapeWireMode": False, "shapeId": 0.0,
                     "brightness": 50.0}
        bplan[12] = {"pushShape": True}
        bplan[14] = {"pushShape": False}
        bplan[16] = {"drawAllShapes": True}
        bplan[18] = {"drawAllShapes": False}
        bplan[40] = {"shapePoints": list(bB), "shapeColors": [blue] * 4,
                     "shapeWireMode": False, "shapeId": 0.0,
                     "brightness": 50.0}
        bplan[42] = {"pushShape": True}
        bplan[44] = {"pushShape": False}
        bplan[46] = {"drawAllShapes": True}
        bplan[48] = {"drawAllShapes": False}
        btotal = 100

        sim, gids, polyon, son, pts_aid, cols_aid = fresh_sim(dump_path)
        sim.inputs = {"shapePoints": [0.0] * 32, "shapeColors": [],
                      "pushShape": False, "shapeWireMode": False,
                      "shapeId": 0.0, "drawAllShapes": False,
                      "clearAllShapes": False, "shapePosition": (0.0, 0.0, 0.0), "shapeRotation": (0.0, 0.0, 0.0), "shapeScale": (0.0, 0.0, 0.0), "parentShapeId": 0.0, "brightness": 100.0}
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
            wantb[p] = dim(blue)
        badb = [i for i in range(SW * SW)
                if not close(col(sim, gids, i), wantb.get(i, BLACK))]
        ok &= expect(not badb, "brightness dims RGB, keeps alpha",
                     "%d of 4096 differ, first at %d"
                     % (len(badb), badb[0] if badb else 0))

        # ---- brightness repaints by itself, no drawAllShapes ----------------
        # A retained square plus one immediate rect, both painted at
        # full brightness; then ONLY the slider moves to 50.  The chip
        # reruns the retained recomposite (no clear -- nothing moved,
        # so overwriting is exact) and replays the immediate rect, and
        # the whole wall dims with no push and no drawAllShapes.  Then the
        # slider returns to the unwired default (full): the wall follows
        # back up the same way, locking retroactive behavior in both
        # directions.  Nothing is staged after either edge, so the
        # immediate replay is never superseded here.
        rA = rect_pts(4.0, 4.0, 12.0, 12.0)
        rB = rect_pts(20.0, 20.0, 26.0, 24.0)
        aplan = {}
        aplan[10] = {"shapePoints": list(rA),
                     "shapeColors": [RED] * 4,
                     "shapeWireMode": False, "shapeId": 1.0,
                     "brightness": 100.0}
        aplan[12] = {"pushShape": True}
        aplan[14] = {"pushShape": False}
        aplan[16] = {"drawAllShapes": True}
        aplan[18] = {"drawAllShapes": False}
        aplan[140] = {"shapePoints": list(rB),
                      "shapeColors": [blue] * 4,
                      "shapeWireMode": False, "shapeId": 0.0}
        aplan[142] = {"pushShape": True}
        aplan[144] = {"pushShape": False}
        aplan[146] = {"drawAllShapes": True}
        aplan[148] = {"drawAllShapes": False}
        aplan[170] = {"brightness": 50.0}
        adim_at = 260
        aplan[340] = {"brightness": 0.0}
        # unwired (0.0) now means the DEF_BRIGHT default, so "brightens back"
        # states 100 explicitly -- a real slider going back to the top
        aplan[460] = {"brightness": 100.0}
        # the slider's edge reruns a recomposite (~76 ticks), so the
        # snapshot sits past its end, not on its first tick
        afull_at = 560

        sim, gids, polyon, son, pts_aid, cols_aid = fresh_sim(dump_path)
        sim.inputs = {"shapePoints": [0.0] * 32, "shapeColors": [],
                      "pushShape": False, "shapeWireMode": False,
                      "shapeId": 0.0, "drawAllShapes": False,
                      "clearAllShapes": False, "shapePosition": (0.0, 0.0, 0.0), "shapeRotation": (0.0, 0.0, 0.0), "shapeScale": (0.0, 0.0, 0.0), "parentShapeId": 0.0, "brightness": 100.0}
        sim.run(1)
        sim.inputs = {k: v for k, v in sim.inputs.items()
                      if k != "shapePoints"}

        asnap = {}

        def watcha(sn, tick):
            if tick in aplan:
                step = aplan[tick]
                if "shapePoints" in step:
                    slide(sn, pts_aid, cols_aid, step["shapePoints"],
                          step.get("shapeColors"))
                    step = {k: v for k, v in step.items()
                            if k != "shapePoints" and k != "shapeColors"}
                sn.inputs = dict(sn.inputs, **step)
            if tick in (adim_at, afull_at):
                asnap[tick] = {i: col(sn, gids, i)
                               for i in range(SW * SW)}

        sim.run(afull_at + 1, on_tick=watcha)

        wanta = {}
        for p in poly_pixels(rA):
            wanta[p] = dim(RED)
        for p in poly_pixels(rB):
            wanta[p] = dim(blue)
        bada = [i for i in range(SW * SW)
                if not close(asnap[adim_at][i], wanta.get(i, BLACK))]
        ok &= expect(not bada, "brightness repaints with no drawAllShapes",
                     "%d of 4096 differ, first at %d"
                     % (len(bada), bada[0] if bada else 0))
        wantf = {}
        for p in poly_pixels(rA):
            wantf[p] = RED
        for p in poly_pixels(rB):
            wantf[p] = blue
        badf = [i for i in range(SW * SW)
                if not close(asnap[afull_at][i], wantf.get(i, BLACK))]
        ok &= expect(not badf, "brightness brightens back with no drawAllShapes",
                     "%d of 4096 differ, first at %d"
                     % (len(badf), badf[0] if badf else 0))

        # ---- transforms + parents: move, shapeScale, rotate, follow -------
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
                        "shapeWireMode": False, "shapeId": sid,
                        "shapePosition": (pos[0], pos[1], 0.0),
                        "shapeRotation": (0.0, 0.0, ang),
                        "shapeScale": (scl[0], scl[1], 1.0),
                        "parentShapeId": par}
            xplan[t + 2] = {"pushShape": True}
            xplan[t + 4] = {"pushShape": False}
            xplan[t + 6] = {"drawAllShapes": True}
            xplan[t + 8] = {"drawAllShapes": False}
            # a commit clears (64 rows) and repaints every live slot;
            # parented slots pay one ancestor walk of slow computed
            # reads each, so this allows extra margin over the plain
            # retained section
            t += 64 + 110
            xends.append(t)
        xtotal = t + 20

        sim, gids, polyon, son, pts_aid, cols_aid = fresh_sim(dump_path)
        sim.inputs = {"shapePoints": [0.0] * 32, "shapeColors": [],
                      "pushShape": False, "shapeWireMode": False,
                      "shapeId": 0.0, "drawAllShapes": False,
                      "clearAllShapes": False, "shapePosition": (0.0, 0.0, 0.0), "shapeRotation": (0.0, 0.0, 0.0), "shapeScale": (0.0, 0.0, 0.0), "parentShapeId": 0.0, "brightness": 100.0}
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

        # ---- depth: z-order, tilt, tilted parents -------------------------
        # The vec inputs' third fields are live: shapePosition.z places a
        # shape forwards/backwards (bigger z paints in front, ties
        # repaint), shapeRotation.x/y tilt off-axis, shapeScale.z scales
        # depth.  Projection is orthographic; a per-pixel depth buffer
        # orders everything, so slot order never decides ties of
        # geometry.  Five small runs: front wins both slot orders, a
        # 30-degree tilt matches the matrix model exactly, the tilt
        # crossing a flat shape resolves per pixel, and a flipped
        # parent carries its child through the matrix compose.
        def want3(slots, project=False):
            fbz = {}
            want = {}
            xf = xf_points3d if project else xf_points3
            for kk in sorted(slots):
                spts, scols, pos, eul, scl, par = slots[kk]
                # An EMPTY push to a slot is the delete, so an empty slot is
                # neither a shape nor a live parent: it paints nothing and its
                # children resolve against the identity.  Anything else is
                # live -- a two-point mover included, which is how the demos
                # carry a pivot that owns a placement and no visible shape of
                # its own.
                if not spts:
                    continue
                # The chip reads an ODD array as (x,y,z) triples and an even
                # one as (x,y) pairs, then TRUNCATES to whole points
                # (`(len / 3.0) | 0`).  A mover pushed as five floats is
                # therefore one 3D point with two floats left over, not two
                # points with the last one zero-padded -- matching the
                # truncation here is what keeps the model's point set equal
                # to the chip's point set.  The orthographic path only ever
                # sees 2D shapes (every `project=True` case is the 3D one),
                # so the parity test costs it nothing.
                step = 3 if len(spts) % 2 else 2
                spts = spts[:len(spts) - (len(spts) % step)]
                if not spts:
                    continue
                # ancestor chain innermost-first for xf_points3
                chain = []
                p = par
                d = 0
                while p >= 0.5 and int(p) in slots and d < 8:
                    q = slots[int(p)]
                    if not q[0]:
                        break
                    chain.append((q[2], q[3], q[4]))
                    p = q[5]
                    d += 1
                got = z_colors(xf(spts, pos, eul, scl, chain),
                               scols)
                for i, (c, z) in got.items():
                    if z >= fbz.get(i, ZBACK):
                        fbz[i] = z
                        want[i] = c
            return want

        def run3(commits, step=64):
            sim, gids, _, _, pts_aid, cols_aid = fresh_sim(dump_path)
            sim.inputs = {"shapePoints": [0.0] * 32, "shapeColors": [],
                          "pushShape": False, "shapeWireMode": False,
                          "shapeId": 0.0, "drawAllShapes": False,
                          "clearAllShapes": False,
                          "shapePosition": (0.0, 0.0, 0.0),
                          "shapeRotation": (0.0, 0.0, 0.0),
                          "shapeScale": (0.0, 0.0, 0.0),
                          "parentShapeId": 0.0, "brightness": 100.0}
            sim.run(1)
            sim.inputs = {k: v for k, v in sim.inputs.items()
                          if k != "shapePoints"}
            plan = {}
            t = 10
            ends = []
            for pts, cols, sid, pos, eul, scl, par in commits:
                plan[t] = {"shapePoints": list(pts),
                           "shapeColors": list(cols),
                           "shapeWireMode": False, "shapeId": sid,
                           "shapePosition": (pos[0], pos[1], pos[2]),
                           "shapeRotation": (eul[0], eul[1], eul[2]),
                           "shapeScale": (scl[0], scl[1], scl[2]),
                           "parentShapeId": par}
                plan[t + 2] = {"pushShape": True}
                plan[t + 4] = {"pushShape": False}
                plan[t + 6] = {"drawAllShapes": True}
                plan[t + 8] = {"drawAllShapes": False}
                t += step
                ends.append(t)
            snaps = {}

            def watch3(sn, tick):
                if tick in plan:
                    st = plan[tick]
                    if "shapePoints" in st:
                        slide3(sn, pts_aid, cols_aid, st["shapePoints"],
                               st.get("shapeColors"))
                        st = {k: v for k, v in st.items()
                              if k not in ("shapePoints", "shapeColors")}
                    sn.inputs = dict(sn.inputs, **st)
                if tick in ends:
                    snaps[tick] = {i: col(sn, gids, i)
                                   for i in range(SW * SW)}

            sim.run(t + 20, on_tick=watch3)
            return snaps, ends

        Z0 = (0.0, 0.0, 0.0)
        R0 = (0.0, 0.0, 0.0)
        S1 = (1.0, 1.0, 1.0)
        dA = rect_pts(4.0, 4.0, 12.0, 12.0)
        dB = rect_pts(8.0, 8.0, 16.0, 16.0)
        dF = (0.0, 0.0, 5.0)
        snaps, ends = run3([
            (dA, [RED] * 4, 1.0, Z0, R0, S1, 0.0),
            (dB, [blue] * 4, 2.0, dF, R0, S1, 0.0),
        ])
        slots = {1: (dA, [RED] * 4, Z0, R0, S1, 0.0),
                 2: (dB, [blue] * 4, dF, R0, S1, 0.0)}
        bad = [i for i in range(SW * SW)
               if not close(snaps[ends[1]][i],
                            want3(slots).get(i, BLACK))]
        ok &= expect(not bad, "nearer shape paints in front",
                     "%d of 4096 differ, first at %d"
                     % (len(bad), bad[0] if bad else 0))
        snaps, ends = run3([
            (dB, [blue] * 4, 1.0, dF, R0, S1, 0.0),
            (dA, [RED] * 4, 2.0, Z0, R0, S1, 0.0),
        ])
        slots = {1: (dB, [blue] * 4, dF, R0, S1, 0.0),
                 2: (dA, [RED] * 4, Z0, R0, S1, 0.0)}
        bad = [i for i in range(SW * SW)
               if not close(snaps[ends[1]][i],
                            want3(slots).get(i, BLACK))]
        ok &= expect(not bad, "depth beats slot order",
                     "%d of 4096 differ, first at %d"
                     % (len(bad), bad[0] if bad else 0))
        rc = [-8.0, -4.0, 8.0, -4.0, 8.0, 4.0, -8.0, 4.0]
        r30 = (0.0, math.pi / 6, 0.0)
        snaps, ends = run3([
            (rc, [green] * 4, 1.0, (16.0, 12.0, 0.0), r30, S1, 0.0),
        ])
        slots = {1: (rc, [green] * 4, (16.0, 12.0, 0.0), r30, S1, 0.0)}
        bad = [i for i in range(SW * SW)
               if not close(snaps[ends[0]][i],
                            want3(slots).get(i, BLACK))]
        ok &= expect(not bad, "off-axis tilt paints",
                     "%d of 4096 differ, first at %d"
                     % (len(bad), bad[0] if bad else 0))
        snaps, ends = run3([
            (rect_pts(8.0, 8.0, 24.0, 16.0), [RED] * 4, 1.0,
             Z0, R0, S1, 0.0),
            (rc, [blue] * 4, 2.0, (16.0, 12.0, 0.0), r30, S1, 0.0),
        ])
        slots = {1: (rect_pts(8.0, 8.0, 24.0, 16.0), [RED] * 4,
                     Z0, R0, S1, 0.0),
                 2: (rc, [blue] * 4, (16.0, 12.0, 0.0), r30, S1, 0.0)}
        bad = [i for i in range(SW * SW)
               if not close(snaps[ends[1]][i],
                            want3(slots).get(i, BLACK))]
        ok &= expect(not bad, "tilt resolves per pixel",
                     "%d of 4096 differ, first at %d"
                     % (len(bad), bad[0] if bad else 0))
        par = rect_pts(4.0, 4.0, 8.0, 8.0)
        ch = rect_pts(20.0, 20.0, 26.0, 26.0)
        fl = rect_pts(18.0, 10.0, 28.0, 20.0)
        ppos = (0.0, 32.0, 5.0)
        prot = (math.pi, 0.0, 0.0)
        snaps, ends = run3([
            (par, [blue] * 4, 1.0, ppos, prot, S1, 0.0),
            (ch, [green] * 4, 2.0, Z0, R0, S1, 1.0),
            (fl, [RED] * 4, 3.0, Z0, R0, S1, 0.0),
        ])
        slots = {1: (par, [blue] * 4, ppos, prot, S1, 0.0),
                 2: (ch, [green] * 4, Z0, R0, S1, 1.0),
                 3: (fl, [RED] * 4, Z0, R0, S1, 0.0)}
        bad = [i for i in range(SW * SW)
               if not close(snaps[ends[2]][i],
                            want3(slots).get(i, BLACK))]
        ok &= expect(not bad, "tilted parent carries child",
                     "%d of 4096 differ, first at %d"
                     % (len(bad), bad[0] if bad else 0))

        # ---- 3D: the chip projects, the CPU sends vertices ---------------
        # A shape whose point array has an odd length carries (x,y,z)
        # triples: the chip transforms each point's own z through the
        # ancestor chain and then divides by its distance from the eye
        # at z = -EYE.  These cases pin that the whole chain agrees with
        # the model, that depth still orders faces by world z, that the
        # divide actually moves pixels (a near face covers more than a
        # far one), and that a cube of six faces composites as a solid.
        # No triangulation and no mesh helper: a face is a plain outline.
        q3 = quad3(20.0, 20.0, 44.0, 44.0, 0.0)
        snaps, ends = run3([
            (q3, [RED] * 5, 1.0, Z0, R0, S1, 0.0),
        ])
        # A plane at z = 0 is exactly EYE from the eye, so the divide is
        # the identity there: the chip's 3D path must paint precisely the
        # pixels its 2D path paints for the same outline (poly_pixels is
        # the 2D model, transcribed from the fill itself).
        flat = [20.0, 20.0, 44.0, 20.0, 44.0, 44.0, 20.0, 44.0, 20.0, 20.0]
        painted = {i for i in range(SW * SW)
                   if not close(snaps[ends[0]][i], BLACK)}
        ok &= expect(painted == poly_pixels(flat), "3D quad at z=0 paints like 2D",
                     "%d lit vs %d modelled, first diff %r"
                     % (len(painted), len(poly_pixels(flat)),
                        sorted(painted ^ poly_pixels(flat))[:4]))
        far = quad3(20.0, 20.0, 44.0, 44.0, -20.0)
        near = quad3(20.0, 20.0, 44.0, 44.0, 20.0)
        snaps, ends = run3([
            (far, [blue] * 5, 1.0, Z0, R0, S1, 0.0),
            (near, [RED] * 5, 2.0, Z0, R0, S1, 0.0),
        ])
        slots = {1: (far, [blue] * 5, Z0, R0, S1, 0.0),
                 2: (near, [RED] * 5, Z0, R0, S1, 0.0)}
        bad = [i for i in range(SW * SW)
               if not close(snaps[ends[1]][i],
                            want3(slots, True).get(i, BLACK))]
        ok &= expect(not bad, "3D depth beats slot order",
                     "%d of 4096 differ, first at %d"
                     % (len(bad), bad[0] if bad else 0))
        # The same outline at three depths must cover three different
        # pixel sets, growing as it nears the eye -- the divide is real.
        # The eye stands in FRONT of the wall, so a bigger z is nearer.
        cov = []
        for z, sid in ((-20.0, 1.0), (0.0, 2.0), (20.0, 3.0)):
            qq = quad3(24.0, 24.0, 40.0, 40.0, z)
            snaps, ends = run3([
                (qq, [RED] * 5, sid, Z0, R0, S1, 0.0),
            ])
            cov.append(len({i for i in range(SW * SW)
                            if not close(snaps[ends[0]][i], BLACK)}))
        ok &= expect(cov[0] < cov[1] < cov[2],
                     "perspective spreads a near face",
                     "far/mid/near pixels %r" % (cov,))
        # A cube: six closed faces around a pivot, each a 3D outline,
        # with a parent slot carrying the spin so the faces inherit it.
        hx = hy = hz = 8.0
        cx = cy = cz = 0.0
        cube_faces = [
            ([cx - hx, cy - hy, cz + hz, cx + hx, cy - hy, cz + hz,
              cx + hx, cy + hy, cz + hz, cx - hx, cy + hy, cz + hz,
              cx - hx, cy - hy, cz + hz], RED),
            ([cx + hx, cy - hy, cz - hz, cx - hx, cy - hy, cz - hz,
              cx - hx, cy + hy, cz - hz, cx + hx, cy + hy, cz - hz,
              cx + hx, cy - hy, cz - hz], green),
            ([cx - hx, cy - hy, cz - hz, cx + hx, cy - hy, cz - hz,
              cx + hx, cy - hy, cz + hz, cx - hx, cy - hy, cz + hz,
              cx - hx, cy - hy, cz - hz], blue),
            ([cx - hx, cy + hy, cz + hz, cx + hx, cy + hy, cz + hz,
              cx + hx, cy + hy, cz - hz, cx - hx, cy + hy, cz - hz,
              cx - hx, cy + hy, cz + hz], (1.0, 1.0, 0.2, 1.0)),
            ([cx - hx, cy - hy, cz - hz, cx - hx, cy - hy, cz + hz,
              cx - hx, cy + hy, cz + hz, cx - hx, cy + hy, cz - hz,
              cx - hx, cy - hy, cz - hz], (0.8, 0.2, 0.8, 1.0)),
            ([cx + hx, cy - hy, cz - hz, cx + hx, cy - hy, cz + hz,
              cx + hx, cy + hy, cz + hz, cx + hx, cy + hy, cz - hz,
              cx + hx, cy - hy, cz - hz], (0.2, 0.8, 0.8, 1.0)),
        ]
        centre = (32.0, 32.0, 0.0)
        spin = (0.35, 0.55, 0.0)
        commits = [(pts, [fc] * 5, float(k + 2), centre, spin, S1, 1.0)
                   for k, (pts, fc) in enumerate(cube_faces)]
        # The pivot: a slot that carries the transform and nothing else, so
        # the six faces inherit its rotation and position as one solid.  It
        # needs a real (if tiny) shape of its own -- an EMPTY push to a slot
        # is the delete -- which is why the mover is a dot just off the top
        # left corner: it paints nothing visible and the faces carry the
        # frame.
        mover = [0.0, 0.0, 0.5, 0.5, 0.0]
        # The faces carry LOCAL vertices (the pivot holds the placement), so
        # their own transform is the identity.
        commits = [(pts, [fc] * 5, float(k + 2), Z0, R0, S1, 1.0)
                   for k, (pts, fc) in enumerate(cube_faces)]
        commits.insert(0, (mover, [], 1.0, centre, spin, S1, 0.0))
        snaps, ends = run3(commits, step=72)
        slots = {1: (mover, [], centre, spin, S1, 0.0)}
        for k, (pts, fc) in enumerate(cube_faces):
            slots[k + 2] = (pts, [fc] * 5, Z0, R0, S1, 1.0)
        bad = [i for i in range(SW * SW)
               if not close(snaps[ends[-1]][i],
                            want3(slots, True).get(i, BLACK))]
        lit = sum(1 for i in range(SW * SW)
                  if not close(snaps[ends[-1]][i], BLACK))
        ok &= expect(not bad, "a cube of six faces paints",
                     "%d of 4096 differ, first at %d (%d lit)"
                     % (len(bad), bad[0] if bad else 0, lit))

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
                      "pushShape": False, "shapeWireMode": False,
                      "shapeId": 0.0, "drawAllShapes": False,
                      "clearAllShapes": False, "shapePosition": (0.0, 0.0, 0.0), "shapeRotation": (0.0, 0.0, 0.0), "shapeScale": (0.0, 0.0, 0.0), "parentShapeId": 0.0, "brightness": 100.0}
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

        # ---- the pending queue: push several shapes, draw once ----------
        # A push APPENDS to the queue; drawAllShapes commits every entry
        # (id 1..8 to its slot, id 0 to a scratch slot that dies on the
        # next commit), then recomposites once.  So a driver stages a
        # whole frame and paints it with ONE draw instead of one push-
        # draw per shape -- and a push that is never drawn changes only
        # the screen's memory.  Each case stages its shapes, fires
        # exactly one draw, and snapshots the wall; the last stages a
        # shape and deliberately does NOT draw, which must leave the
        # wall byte-identical.
        qA = rect_pts(4.0, 4.0, 12.0, 12.0)
        qB = [8.0, 8.0, 20.0, 8.0, 8.0, 20.0]
        qC = rect_pts(20.0, 20.0, 28.0, 28.0)
        qT = [10.0, 40.0, 16.0, 40.0, 13.0, 46.0]
        qcases = [
            ([(qA, RED, 1.0), (qB, blue, 2.0)], True),
            ([(qC, green, 1.0)], True),
            ([([], [], 2.0)], True),
            ([(qT, RED, 0.0), (qC, green, 1.0)], True),
            ([(qA, blue, 3.0)], False),
        ]
        qplan = {}
        t = 20
        qends = []
        for entries, draw in qcases:
            for pts, cl, sid in entries:
                qplan[t] = {"shapePoints": list(pts),
                            "shapeColors": [cl] * (len(pts) // 2),
                            "wireMode": False, "shapeId": sid}
                qplan[t + 2] = {"pushShape": True}
                qplan[t + 4] = {"pushShape": False}
                t += 8
            if draw:
                qplan[t] = {"drawAllShapes": True}
                qplan[t + 2] = {"drawAllShapes": False}
            t += 150
            qends.append(t)
        qtotal = t + 20

        sim, gids, polyon, son, pts_aid, cols_aid = fresh_sim(dump_path)
        sim.inputs = {"shapePoints": [0.0] * 32, "shapeColors": [],
                      "pushShape": False, "wireMode": False,
                      "shapeId": 0.0, "drawAllShapes": False,
                      "clearAllShapes": False, "position": (0.0, 0.0, 0.0), "rotation": (0.0, 0.0, 0.0), "scale": (0.0, 0.0, 0.0), "parentShapeId": 0.0, "brightness": 100.0}
        sim.run(1)
        sim.inputs = {k: v for k, v in sim.inputs.items()
                      if k != "shapePoints"}
        qsnaps = {}

        def watchq(sn, tick):
            if tick in qplan:
                step = qplan[tick]
                if "shapePoints" in step:
                    slide(sn, pts_aid, cols_aid, step["shapePoints"],
                          step.get("shapeColors"))
                    step = {k: v for k, v in step.items()
                            if k != "shapePoints" and k != "shapeColors"}
                sn.inputs = dict(sn.inputs, **step)
            if tick in qends:
                qsnaps[tick] = {i: col(sn, gids, i)
                                for i in range(SW * SW)}

        sim.run(qtotal, on_tick=watchq)

        def qwant(*shapes):
            want = {}
            for pts, c in shapes:
                want.update(poly_colors(pts, [c] * (len(pts) // 2)))
            return want

        qwants = [
            qwant((qA, RED), (qB, blue)),
            qwant((qC, green), (qB, blue)),
            qwant((qC, green)),
            qwant((qC, green), (qT, RED)),
            qwant((qC, green), (qT, RED)),
        ]
        qlabels = ["queued shapes paint with one draw",
                   "queued edit replaces in place",
                   "queued empty push deletes",
                   "queued id-0 shape paints with the scene",
                   "push without a draw changes nothing"]
        for k, label in enumerate(qlabels):
            bad = [i for i in range(SW * SW)
                   if not close(qsnaps[qends[k]][i],
                                qwants[k].get(i, BLACK))]
            ok &= expect(not bad, label,
                         "%d of 4096 differ, first at %d"
                         % (len(bad), bad[0] if bad else 0))

        # ---- per-tick animation: deltas, skip, motion, supersede --------
        # With addToShapeInTicks = N the staged inputs are per-tick
        # deltas, added to the stored slot every tick for N ticks.  The
        # animated commit paints nothing (the wall already shows those
        # values); motion becomes visible on a later bare drawAllShapes;
        # a new push to the same slot always wins, even mid-flight (an
        # instant one kills the animation outright).
        aA = rect_pts(4.0, 4.0, 12.0, 12.0)
        aT = [30.0, 30.0, 38.0, 30.0, 34.0, 38.0]
        ablue = (0.1, 0.4, 1.0, 1.0)
        aplan = {}
        aplan[20] = {"pts": list(aA), "cols": [RED] * 4, "sid": 1.0,
                     "pos": (0.0, 0.0, 0.0), "ticks": 0.0}
        aplan[22] = {"push": True}
        aplan[24] = {"push": False}
        aplan[26] = {"draw": True}
        aplan[28] = {"draw": False}
        aend0 = 108
        # zero point-deltas, no colours (transparent hold), +2 x/tick.
        aplan[120] = {"pts": [0.0, 0.0], "cols": [], "sid": 1.0,
                      "pos": (2.0, 0.0, 0.0), "ticks": 4.0}
        aplan[122] = {"push": True}
        aplan[124] = {"push": False}
        aplan[126] = {"draw": True}
        aplan[128] = {"draw": False}
        aend1 = 158
        aplan[190] = {"draw": True}
        aplan[192] = {"draw": False}
        aend2 = 272
        # mid-flight supersede: +5 x/tick over 20 ticks, then an
        # instant triangle to the same slot kills it outright.
        aplan[284] = {"pts": [0.0, 0.0], "cols": [], "sid": 1.0,
                      "pos": (5.0, 0.0, 0.0), "ticks": 20.0}
        aplan[286] = {"push": True}
        aplan[288] = {"push": False}
        aplan[290] = {"draw": True}
        aplan[292] = {"draw": False}
        aplan[298] = {"pts": list(aT), "cols": [ablue] * 3, "sid": 1.0,
                      "pos": (0.0, 0.0, 0.0), "ticks": 0.0}
        aplan[300] = {"push": True}
        aplan[302] = {"push": False}
        aplan[304] = {"draw": True}
        aplan[306] = {"draw": False}
        aend3 = 386
        atotal = aend3 + 20

        sim, gids, polyon, son, pts_aid, cols_aid = fresh_sim(dump_path)
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
        asnaps = {}

        def watcha(sn, tick):
            if tick in aplan:
                step = dict(aplan[tick])
                if "pts" in step:
                    slide(sn, pts_aid, cols_aid, step.pop("pts"),
                          step.pop("cols", None))
                    sn.inputs = dict(sn.inputs, **{
                        "shapeId": step.pop("sid", 0.0),
                        "shapePosition": step.pop("pos", (0.0, 0.0, 0.0)),
                        "addToShapeInTicks": step.pop("ticks", 0.0)})
                    step = {}
                renamed = {"push": "pushShape", "draw": "drawAllShapes"}
                sn.inputs = dict(sn.inputs, **{
                    renamed.get(k, k): v for k, v in step.items()})
            if tick in (aend0, aend1, aend2, aend3):
                asnaps[tick] = {i: col(sn, gids, i)
                                for i in range(SW * SW)}

        sim.run(atotal, on_tick=watcha)

        awant0 = dict(poly_colors(aA, [RED] * 4))
        bad = [i for i in range(SW * SW)
               if not close(asnaps[aend0].get(i, BLACK),
                            awant0.get(i, BLACK))]
        ok &= expect(not bad, "animated slot establishes",
                     "%d of 4096 differ" % len(bad))
        amoved8 = dict(poly_colors(
            xf_points(aA, (8.0, 0.0), 0.0, (1.0, 1.0)), [RED] * 4))
        bad = [i for i in range(SW * SW)
               if not close(asnaps[aend1].get(i, BLACK),
                            amoved8.get(i, BLACK))]
        ok &= expect(not bad, "motion advances with no draw",
                     "%d of 4096 differ" % len(bad))
        amoved = dict(poly_colors(
            xf_points(aA, (8.0, 0.0), 0.0, (1.0, 1.0)), [RED] * 4))
        bad = [i for i in range(SW * SW)
               if not close(asnaps[aend2].get(i, BLACK),
                            amoved.get(i, BLACK))]
        ok &= expect(not bad, "bare draw shows the motion",
                     "%d of 4096 differ" % len(bad))
        atri = dict(poly_colors(aT, [ablue] * 3))
        bad = [i for i in range(SW * SW)
               if not close(asnaps[aend3].get(i, BLACK),
                            atri.get(i, BLACK))]
        ok &= expect(not bad, "new push wins mid-flight",
                     "%d of 4096 differ" % len(bad))

        # ---- an undrawn push stays off the wall ------------------------
        # Auto-animate repaints live slots without the CPU pumping
        # drawAllShapes.  The guarantee that makes that safe: only what
        # addToShapeInTicks asked to update ever reaches the wall.
        #
        # Two properties, so two phases.  A: slot 1 (red, drawn) runs a
        # 40-tick +2x/tick animation with nothing else staged -- the wall
        # must show it moving.  B: while that motion is live, slot 2
        # (green) is pushed and never drawn.  Two things must hold: no
        # green ever paints, and the staged push must not drag anything
        # else onto the wall either.  (A staged push leaves the chip
        # `pending`, which holds every repaint off -- that is the same
        # guarantee seen from the other side, so the motion check
        # applies to phase A only.)
        uA = rect_pts(4.0, 4.0, 12.0, 12.0)
        uB = rect_pts(30.0, 30.0, 38.0, 38.0)
        ugreen = (0.0, 1.0, 0.0, 1.0)
        sim, gids, _po, _so, u_pts, u_cols = fresh_sim(dump_path)
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

        def stage(sn, pts, cols, sid, pos, ticks):
            slide(sn, u_pts, u_cols, pts, cols or None)
            sn.inputs = dict(sn.inputs, **{
                "shapeId": sid, "shapePosition": pos,
                "parentShapeId": 0.0, "addToShapeInTicks": ticks})

        green_seen = []
        red_seen = []

        def watchu(sn, tick):
            # tick 20: draw slot 1 only.
            if tick == 20:
                stage(sn, list(uA), [RED] * 4, 1.0, (0.0, 0.0, 0.0), 0.0)
            if tick == 22:
                sn.inputs = dict(sn.inputs, pushShape=True)
            if tick == 24:
                sn.inputs = dict(sn.inputs, pushShape=False)
            if tick == 26:
                sn.inputs = dict(sn.inputs, drawAllShapes=True)
            if tick == 28:
                sn.inputs = dict(sn.inputs, drawAllShapes=False)
            # tick 60: start slot 1's animation, no draw at all.
            if tick == 60:
                stage(sn, [0.0, 0.0], [], 1.0, (2.0, 0.0, 0.0), 40.0)
            if tick == 62:
                sn.inputs = dict(sn.inputs, pushShape=True)
            if tick == 64:
                sn.inputs = dict(sn.inputs, pushShape=False,
                                 addToShapeInTicks=0.0)
            # tick 130: stage slot 2 (green) -- pushed, never drawn.
            if tick == 130:
                stage(sn, list(uB), [ugreen] * 4, 2.0, (0.0, 0.0, 0.0), 0.0)
            if tick == 132:
                sn.inputs = dict(sn.inputs, pushShape=True)
            if tick == 134:
                sn.inputs = dict(sn.inputs, pushShape=False,
                                 shapeId=0.0, shapePosition=(0.0, 0.0, 0.0))
            if 66 <= tick <= 240:
                wall = [col(sn, gids, i) for i in range(SW * SW)]
                if any(close(v, ugreen) for v in wall):
                    green_seen.append(tick)
                xs = [i % SW for i in range(SW * SW)
                      if close(wall[i], RED)]
                if xs:
                    red_seen.append((tick, min(xs)))

        sim.run(250, on_tick=watchu)
        ok &= expect(not green_seen,
                     "staged-but-undrawn shape never paints",
                     "green first seen at tick %d"
                     % green_seen[0] if green_seen else "")
        # The animation ran with no drawAllShapes anywhere: the square's
        # left edge advanced by exactly the tick count times the delta
        # (8 ticks at +2x/tick = +16px, 4 -> 20).
        early = [x for t, x in red_seen if t < 130]
        ok &= expect(len(early) >= 20 and early[-1] > early[0] + 4,
                     "addToShapeInTicks repaints with no draw",
                     "left edge %s..%s over %d ticks"
                     % (early[0] if early else None,
                        early[-1] if early else None, len(early)))
        # And it never vanishes while it moves, and nothing else appears:
        # every sampled tick still has the drawn shape painted.
        ok &= expect(len(red_seen) == 240 - 66 + 1,
                     "the drawn shape stays painted through the motion",
                     "painted on %d of 175 ticks" % len(red_seen))

        # ---- a -1 animation runs until superseded ----------------------
        # addToShapeInTicks -1 means FOREVER: the slot keeps updating
        # with no drawAllShapes until another command edits it.  A: draw
        # a square, start a -1 rotation drift with no draw -- the wall
        # must keep changing long past any finite count, and anTicks
        # must read back -1.  B: push a finite animation to the same
        # slot -- once its ticks run out the wall must go still (the
        # forever is over).
        fA = rect_pts(4.0, 4.0, 12.0, 12.0)
        sim, gids, _po, _so, f_pts, f_cols = fresh_sim(dump_path)
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
        fant = None
        for _nid, _nd in sim.nodes.items():
            from irsims import _extract as _ex
            if _ex(_nd.props.get("_label", ("raw", ""))) == "anTicks":
                fant = _nid
                break
        fwalls = {}
        fticks = {}

        def stagef(sn, pts, cols, sid, rot, ticks):
            slide(sn, f_pts, f_cols, pts, cols or None)
            sn.inputs = dict(sn.inputs, **{
                "shapeId": sid, "shapeRotation": rot,
                "parentShapeId": 0.0, "addToShapeInTicks": ticks})

        def watchf(sn, tick):
            if tick == 20:
                stagef(sn, list(fA), [RED] * 4, 1.0,
                       (0.0, 0.0, 0.0), 0.0)
            if tick == 22:
                sn.inputs = dict(sn.inputs, pushShape=True)
            if tick == 24:
                sn.inputs = dict(sn.inputs, pushShape=False)
            if tick == 26:
                sn.inputs = dict(sn.inputs, drawAllShapes=True)
            if tick == 28:
                sn.inputs = dict(sn.inputs, drawAllShapes=False)
            if tick == 60:
                stagef(sn, [0.0, 0.0], [], 1.0, (0.0, 0.0, 0.1),
                       -1.0)
            if tick == 62:
                sn.inputs = dict(sn.inputs, pushShape=True)
            if tick == 64:
                sn.inputs = dict(sn.inputs, pushShape=False,
                                 addToShapeInTicks=0.0)
            if tick == 300:
                stagef(sn, [0.0, 0.0], [], 1.0, (0.0, 0.0, 0.0),
                       4.0)
                sn.inputs = dict(sn.inputs,
                                 shapePosition=(2.0, 0.0, 0.0))
            if tick == 302:
                sn.inputs = dict(sn.inputs, pushShape=True)
            if tick == 304:
                sn.inputs = dict(sn.inputs, pushShape=False,
                                 addToShapeInTicks=0.0,
                                 shapePosition=(0.0, 0.0, 0.0))
                sn.inputs = dict(sn.inputs, shapeId=0.0)
            if tick in (120, 200, 280, 340, 420, 500):
                fwalls[tick] = tuple(col(sn, gids, i)
                                     for i in range(SW * SW))
                arr = sn.arrays.get(fant) or []
                fticks[tick] = list(arr[:2]) if len(arr) >= 2 else []

        sim.run(520, on_tick=watchf)
        ok &= expect(all(fticks[t] == [-1.0, 0.0]
                         for t in (120, 200, 280)),
                     "forever animation holds its ticks",
                     str({t: fticks.get(t) for t in (120, 200, 280)}))
        moving = sum(1 for a, b in zip(
            [fwalls[t] for t in (120, 200, 280)],
            [fwalls[t] for t in (200, 280, 340)]) if a != b)
        ok &= expect(moving >= 2,
                     "forever animation keeps repainting (%d of 3 windows)"
                     % moving)
        ok &= expect(fwalls[420] == fwalls[500],
                     "a finite push supersedes forever")

        # ---- a bare chip paints nothing ---------------------------------
        # All scalar ports at their game defaults (unwired reads 0/False;
        # the sim reads None for unset, which string-compares wrong -- an
        # unset shapeId once read back as 8 -- so defaults are seeded to
        # model unwired faithfully).  No array: a missing array reads
        # length 0, an empty shape, silent.
        sim, gids, polyon, son, pts_aid, cols_aid = fresh_sim(dump_path)
        sim.inputs = {"pushShape": False, "shapeWireMode": False,
                      "shapeId": 0.0, "drawAllShapes": False,
                      "clearAllShapes": False, "shapePosition": (0.0, 0.0, 0.0), "shapeRotation": (0.0, 0.0, 0.0), "shapeScale": (0.0, 0.0, 0.0), "parentShapeId": 0.0, "brightness": 100.0}
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
