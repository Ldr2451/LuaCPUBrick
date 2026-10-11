"""Functional test for the wall screen: drive it, read the pixel globals.

Unlike the overlay variant, every gate here is sim-modelled, so there are no
mocks: the test pushes rects and triangles through the real protocol and
reads the real per-pixel globals (g0..g4095) the save wires to the bricks.

  python -u extras/screen/painttest.py   (exit 0 = all green)
"""
import itertools
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "irrun"))

from irsims import (  # noqa: E402
    ChipRunner,
    share_dump,
    sim_from_dump,
    _extract,
)

WS = os.path.join(HERE, "screen.ws")
SW = 64
BLACK = (0.0, 0.0, 0.0, 1.0)
RED = (1.0, 0.0, 0.0, 1.0)


def fresh_sim(dump_path):
    sim = sim_from_dump(dump_path)
    sim.reset()
    gids = {}
    recton = None
    for nid, nd in sim.nodes.items():
        lb = _extract(nd.props.get("_label", ("raw", "")))
        if not isinstance(lb, str):
            continue
        if lb.startswith("g") and lb[1:].isdigit():
            gids[int(lb[1:])] = nid
        elif lb == "rectOn":
            recton = nid
    assert len(gids) == SW * SW, "globals found: %d" % len(gids)
    assert recton is not None, "no rectOn var"
    return sim, gids, recton


def find_flag(sim, name):
    for nid, nd in sim.nodes.items():
        if _extract(nd.props.get("_label", ("raw", ""))) == name:
            return nid
    return None


def tri_spans(x0, y0, x1, y1, x2, y2):
    """The chip's triangle fill, row by row: [(row, lo, hi), ...].

    A transcription of gen.py's arm and walk -- the same six flat sort arms
    (last match wins, the same itertools order), the same guarded slopes, the
    same span clamp and empty-span marking -- so the test pins the exact
    pixels the chip paints rather than an idealised triangle.
    """
    verts = [x0, y0, x1, y1, x2, y2]
    v = [0.0] * 6
    for i, j, k in itertools.permutations((0, 1, 2)):
        if verts[2 * i + 1] <= verts[2 * j + 1] <= verts[2 * k + 1]:
            v = [verts[2 * i], verts[2 * i + 1],
                 verts[2 * j], verts[2 * j + 1],
                 verts[2 * k], verts[2 * k + 1]]
    vAx, vAy, vBx, vBy, vCx, vCy = v
    dyAB = vBy - vAy
    sAB = (vBx - vAx) / dyAB if dyAB > 0.0 else 0.0
    dyAC = vCy - vAy
    sAC = (vCx - vAx) / dyAC if dyAC > 0.0 else 0.0
    dyBC = vCy - vBy
    sBC = (vCx - vBx) / dyBC if dyBC > 0.0 else 0.0
    if not (vCy >= 0.0 and vAy < 64.0
            and max(vAx, vBx, vCx) >= 0.0 and min(vAx, vBx, vCx) < 64.0):
        return []
    first = 0.0 if vAy < 0.0 else float(int(vAy))
    last = 63.0 if vCy >= 64.0 else float(int(vCy))
    out = []
    row = first
    while row <= last:
        ex = (vAx + sAB * (row - vAy) if row < vBy
              else vBx + sBC * (row - vBy))
        fx = vAx + sAC * (row - vAy)
        sl, sr = (ex, fx) if ex < fx else (fx, ex)
        if sl >= 64.0 or sr < 0.0:
            lo, hi = 1.0, -1.0
        else:
            lo = 0.0 if sl < 0.0 else float(int(sl))
            hi = 63.0 if sr >= 64.0 else float(int(sr))
        out.append((row, lo, hi))
        row += 1.0
    return out


def tri_pixels(x0, y0, x1, y1, x2, y2):
    px = set()
    for row, lo, hi in tri_spans(x0, y0, x1, y1, x2, y2):
        if lo <= hi:
            for c in range(int(lo), int(hi) + 1):
                px.add(int(row) * SW + c)
    return px


def col(sim, gids, i):
    v = sim.vars.get(gids[i], (0.0, 0.0, 0.0, 0.0))
    if isinstance(v, (tuple, list)) and len(v) >= 4:
        return tuple(float(x) for x in v[:4])
    return v


def pulse_at(plan):
    def hook(sim_now, tick):
        if tick in plan:
            sim_now.inputs = dict(sim_now.inputs, **plan[tick])
    return hook


def expect(cond, label, detail=""):
    print("%-34s %s %s" % (label, "OK  " if cond else "FAIL",
                           detail if not cond else ""))
    return cond


def main():
    with tempfile.NamedTemporaryFile(suffix=".pkl", delete=False) as f:
        dump_path = f.name
    ok = True
    try:
        share_dump(WS, dump_path)

        base = {"rectColor": RED, "rectX0": 0.0, "rectY0": 0.0,
                "rectX1": 3.0, "rectY1": 2.0, "pushRect": False,
                "redrawAll": False, "triX2": 0.0, "triY2": 0.0,
                "pushTri": False}
        plan = {10: {"pushRect": True}, 12: {"pushRect": False},
                14: {"redrawAll": True}, 16: {"redrawAll": False}}

        # A. a 4x3 red rect lands in fb and shows on the globals.
        sim, gids, recton = fresh_sim(dump_path)
        sim.inputs = dict(base)
        sim.run(40, on_tick=pulse_at(plan))
        want = {r * SW + c for r in range(3) for c in range(4)}
        got = {i for i in want if col(sim, gids, i) == RED}
        ok &= expect(got == want, "rect paints its pixels",
                     "missing %d of 12" % (len(want - got),))
        ok &= expect(col(sim, gids, 4) == BLACK and
                     col(sim, gids, 1000) == BLACK,
                     "rest stays black", "")

        # B. clipping: a rect hanging off the corner paints only inside.
        sim, gids, recton = fresh_sim(dump_path)
        sim.inputs = dict(base, rectX0=60.0, rectY0=60.0,
                          rectX1=70.0, rectY1=70.0)
        sim.run(60, on_tick=pulse_at(plan))
        want = {r * SW + c for r in range(60, 64) for c in range(60, 64)}
        got = {i for i in want if col(sim, gids, i) == RED}
        ok &= expect(got == want, "clip to the grid",
                     "missing %d of 16" % (len(want - got),))
        ok &= expect(col(sim, gids, 59 * SW + 59) == BLACK,
                     "outside stays black", "")

        # C. alpha rides along untouched.
        green = (0.0, 1.0, 0.0, 0.5)
        sim, gids, recton = fresh_sim(dump_path)
        sim.inputs = dict(base, rectColor=green, rectX1=0.0, rectY1=0.0)
        sim.run(40, on_tick=pulse_at(plan))
        ok &= expect(col(sim, gids, 0) == green, "alpha flows end to end",
                     "got %r" % (col(sim, gids, 0),))

        # D. a full-screen rect paints; then silence -- there is no timer, no
        # keepalive, nothing that re-arms.  Brick colors persist until
        # rewritten, so re-arming would only re-emit identical values.
        base5 = dict(base, rectX1=63.0, rectY1=63.0)
        sim, gids, recton = fresh_sim(dump_path)
        sim.inputs = dict(base5)
        on = []

        def watch(sn, tick):
            if tick in plan:
                sn.inputs = dict(sn.inputs, **plan[tick])
            if sn.vars.get(recton):
                on.append(tick)

        sim.run(1100, on_tick=watch)
        ok &= expect(any(14 <= t <= 90 for t in on),
                     "redrawAll bursts the rect",
                     "bursts at %r" % (on[:8],))
        ok &= expect(all(col(sim, gids, i) == RED for i in (0, 1000, 4095)),
                     "full screen went red", "")
        ok &= expect(not any(200 <= t <= 1000 for t in on),
                     "silence after the burst",
                     "bursts at %r" % ([t for t in on if t > 200][:8],))

        # E. one burst, then nothing forever: no timer exists anymore.
        sim, gids, recton = fresh_sim(dump_path)
        sim.inputs = dict(base)
        on = []

        def watch2(sn, tick):
            if tick in plan:
                sn.inputs = dict(sn.inputs, **plan[tick])
            if sn.vars.get(recton):
                on.append(tick)

        sim.run(600, on_tick=watch2)
        ok &= expect(any(14 <= t <= 40 for t in on), "burst paints once",
                     "bursts at %r" % (on[:8],))
        ok &= expect(not any(t > 60 for t in on), "silence after the burst",
                     "bursts at %r" % ([t for t in on if t > 60][:8],))

        # F. redrawAll alone replays the last rect (full-screen: unmissable).
        sim, gids, recton = fresh_sim(dump_path)
        sim.inputs = dict(base5)
        on = []

        def watch3(sn, tick):
            if tick in plan:
                sn.inputs = dict(sn.inputs, **plan[tick])
            if tick == 210:
                sn.inputs = dict(sn.inputs, redrawAll=True)
            if tick == 212:
                sn.inputs = dict(sn.inputs, redrawAll=False)
            if sn.vars.get(recton):
                on.append(tick)

        sim.run(320, on_tick=watch3)
        ok &= expect(any(205 <= t <= 285 for t in on),
                     "redrawAll replays the last rect",
                     "bursts at %r" % (on,))
        ok &= expect(not any(100 <= t <= 200 for t in on),
                     "silence between the two shows",
                     "bursts at %r" % ([t for t in on if 100 <= t <= 200],))

        # G. a bare chip paints nothing and leaves every pixel black.
        sim, gids, recton = fresh_sim(dump_path)
        sim.inputs = {}
        sim.run(200)
        ok &= expect(all(col(sim, gids, i) == BLACK
                         for i in (0, 100, 1000, 4095)),
                     "bare chip stays black", "")
        ok &= expect(not sim.vars.get(recton), "painter never arms", "")

        # ---- triangles -------------------------------------------------
        tplan = {10: {"pushTri": True}, 12: {"pushTri": False},
                 14: {"redrawAll": True}, 16: {"redrawAll": False}}
        blue = (0.1, 0.4, 1.0, 1.0)

        # H. a triangle paints exactly the span model's pixels, and the
        # walk stays one row per tick (tOn high for many ticks).
        sim, gids, recton = fresh_sim(dump_path)
        trion = find_flag(sim, "tOn")
        assert trion is not None, "no tOn var"
        sim.inputs = dict(base, rectColor=blue, rectX0=0.0, rectY0=0.0,
                          rectX1=31.0, rectY1=0.0, triX2=0.0, triY2=31.0)
        on = []

        def watch_tri(sn, tick):
            if tick in tplan:
                sn.inputs = dict(sn.inputs, **tplan[tick])
            if sn.vars.get(trion):
                on.append(tick)

        sim.run(120, on_tick=watch_tri)
        want = tri_pixels(0.0, 0.0, 31.0, 0.0, 0.0, 31.0)
        got = {i for i in want if col(sim, gids, i) == blue}
        outside = {i for i in range(SW * SW) if i not in want
                   and col(sim, gids, i) != BLACK}
        ok &= expect(got == want, "triangle paints its pixels",
                     "missing %d of %d" % (len(want - got), len(want)))
        ok &= expect(not outside, "triangle exterior stays black",
                     "%d strays, first at %d" % (len(outside),
                                                 min(outside) if outside else 0))
        ok &= expect(len(on) > 20, "triangle walks row by row",
                     "%d walk ticks" % len(on))
        ok &= expect(not any(t > 90 for t in on), "triangle goes silent",
                     "walk at %r" % ([t for t in on if t > 90][:8],))

        # I. clipping: a triangle hanging off the corner paints only inside.
        sim, gids, recton = fresh_sim(dump_path)
        sim.inputs = dict(base, rectColor=blue, rectX0=60.0, rectY0=60.0,
                          rectX1=75.0, rectY1=60.0, triX2=60.0, triY2=75.0)
        sim.run(120, on_tick=pulse_at(tplan))
        want = tri_pixels(60.0, 60.0, 75.0, 60.0, 60.0, 75.0)
        got = {i for i in want if col(sim, gids, i) == blue}
        ok &= expect(got == want, "triangle clips to the grid",
                     "missing %d of %d" % (len(want - got), len(want)))
        ok &= expect(col(sim, gids, 59 * SW + 59) == BLACK,
                     "outside the triangle stays black", "")

        # J. alpha rides along on a triangle too.
        sim, gids, recton = fresh_sim(dump_path)
        sim.inputs = dict(base, rectColor=green, rectX0=0.0, rectY0=0.0,
                          rectX1=20.0, rectY1=0.0, triX2=0.0, triY2=20.0)
        sim.run(80, on_tick=pulse_at(tplan))
        ok &= expect(col(sim, gids, 0) == green, "triangle alpha end to end",
                     "got %r" % (col(sim, gids, 0),))

        # K. two triangles clear the whole wall -- the two-command clear,
        # and proof that a second arming waits the first burst out (a
        # mid-burst re-arm would abandon rows and leave a hole).
        sim, gids, recton = fresh_sim(dump_path)
        trion = find_flag(sim, "tOn")
        sim.inputs = dict(base, rectColor=RED, rectX0=0.0, rectY0=0.0,
                          rectX1=63.0, rectY1=0.0, triX2=63.0, triY2=63.0)
        on = []

        def watch4(sn, tick):
            if tick in tplan:
                sn.inputs = dict(sn.inputs, **tplan[tick])
            if tick == 120:
                sn.inputs = dict(sn.inputs, rectX0=0.0, rectY0=0.0,
                                 rectX1=63.0, rectY1=63.0,
                                 triX2=0.0, triY2=63.0, pushTri=True)
            if tick == 122:
                sn.inputs = dict(sn.inputs, pushTri=False)
            if tick == 124:
                sn.inputs = dict(sn.inputs, redrawAll=True)
            if tick == 126:
                sn.inputs = dict(sn.inputs, redrawAll=False)
            if sn.vars.get(trion):
                on.append(tick)

        sim.run(280, on_tick=watch4)
        ok &= expect(all(col(sim, gids, i) == RED
                         for i in (0, 1000, 2048, 4095)),
                     "two triangles clear the wall", "")
        ok &= expect(not any(200 <= t <= 270 for t in on),
                     "silence after both clear", "walk at %r" % (on[-6:],))

        # L. a fully off-screen triangle paints nothing and never walks.
        sim, gids, recton = fresh_sim(dump_path)
        trion = find_flag(sim, "tOn")
        sim.inputs = dict(base, rectX0=-20.0, rectY0=-20.0,
                          rectX1=-10.0, rectY1=-5.0, triX2=-5.0, triY2=-1.0)
        sim.run(80, on_tick=pulse_at(tplan))
        ok &= expect(all(col(sim, gids, i) == BLACK
                         for i in (0, 100, 1000, 4095)),
                     "off-screen triangle stays black", "")
        ok &= expect(not sim.vars.get(trion), "off-screen never walks", "")

        # M. redrawAll alone replays the last triangle, from its first row.
        sim, gids, recton = fresh_sim(dump_path)
        trion = find_flag(sim, "tOn")
        sim.inputs = dict(base, rectColor=blue, rectX0=10.0, rectY0=10.0,
                          rectX1=20.0, rectY1=10.0, triX2=10.0, triY2=20.0)
        on = []

        def watch5(sn, tick):
            if tick in tplan:
                sn.inputs = dict(sn.inputs, **tplan[tick])
            if tick == 120:
                sn.inputs = dict(sn.inputs, redrawAll=True)
            if tick == 122:
                sn.inputs = dict(sn.inputs, redrawAll=False)
            if sn.vars.get(trion):
                on.append(tick)

        sim.run(220, on_tick=watch5)
        want = tri_pixels(10.0, 10.0, 20.0, 10.0, 10.0, 20.0)
        got = {i for i in want if col(sim, gids, i) == blue}
        ok &= expect(any(115 <= t <= 140 for t in on),
                     "redrawAll replays the triangle", "walk at %r" % (on[:8],))
        ok &= expect(got == want, "replayed triangle is complete",
                     "missing %d of %d" % (len(want - got), len(want)))
    finally:
        os.unlink(dump_path)
    print("painttest: %s" % ("ALL GREEN" if ok else "FAILURES"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
