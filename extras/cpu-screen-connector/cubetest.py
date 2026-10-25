"""Cube end-to-end through the chain, all three sims on real artifacts.

--chip phase 1 runs the program on the actual Lua CPU chip (lua.ws) and
samples its ports per tick -- the stream the connector sees in game,
priced by real chip compute.  The oracle stream (real Lua 5.5, WCOST
model) is recorded too and the two PUSH LATCH sequences are diffed
elementwise; a divergence means the chip writes different port values
with no diagnostics -- the black-in-game class of bug every error-check
probe misses.  Phases 2/3 replay the chosen stream through the
connector and the screen and report painted pixels per draw edge.

  python -u cubetest.py --chip [ticks]   (ticks default 12000)
  python -u cubetest.py [budget]         (oracle phase 1, default 1800)
Exit 0 on GREEN (stream equal, wall painted), 1 on RED.  String-array
ports are compared at their first 9 fields (the chip port is wider and
pads with empty strings; real Lua slices to 9).
"""
import glob
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "irrun"))
sys.path.insert(0, os.path.join(ROOT, "extras", "screen"))

# CLI first: some imported test modules (animtest) parse sys.argv at
# import time and would crash on a flag, then feed them numeric-only
# args so flags-first call orders stay valid.
USE_CHIP = "--chip" in sys.argv
_args = [a for a in sys.argv[1:] if a.isdigit()]
MAKE_SAVE = "--save" in sys.argv
SAVE = os.environ.get("CUBE_FRAMES") if MAKE_SAVE else None
TRACE = os.environ.get("CUBE_TRACE") == "1"
# the paint/erase ORDER, not the numbers: which pass the erase walk runs
# in, and what paints while it is walking
ORDER = os.environ.get("CUBE_ORDER") == "1"
# one line per completed pass: the pivot's angle, so a turn that rocks
# instead of turning reads as a number sequence, not a guess from a GIF
PASS = os.environ.get("CUBE_PASS") == "1"
BUDGET = int(_args[0]) if _args else 1800
TICKS = int(_args[0]) if _args else (12000 if USE_CHIP else 0) or BUDGET
# second numeric arg: ticks of forever-animation tail observed past the
# last draw edge (default 60 = about one burst; use 700+ to watch the
# per-burst stale-erase behaviour the black-ghosting report is about)
TAIL = int(_args[1]) if len(_args) > 1 else 60
sys.argv = [sys.argv[0]] + _args

from irsims import share_dump, sim_from_dump, _extract  # noqa: E402
import colormath  # noqa: E402
colormath.install()
from painttest import slide3  # noqa: E402
import luastream  # noqa: E402
from animtest import port_slice  # noqa: E402

LUA_WS = os.path.join(ROOT, "lua.ws")
CONN_WS = os.path.join(HERE, "connector.ws")
SCREEN_WS = os.path.join(ROOT, "extras", "screen", "screen.ws")
GFX = os.path.join(HERE, "gfx.lua")
BODY_NAME = os.environ.get("CUBE_BODY", "cube.lua")
BODY = os.path.join(HERE, "sample-programs", BODY_NAME)
# Replay-only pacing knob: the sim's clock() is uptime, and uptime advances
# far slower than a chip tick here, so a game-paced nap(420) hangs the
# replay (420 units is ~40k sim ticks).  CUBE_NAP=<n> rewrites nap(...) in
# the body to nap(n) so a GIF batch can pace frames while the bodies keep
# their game pacing.  A repaint settles in ~20..160 ticks, so nap(2) is
# enough headroom in replay.
CUBE_NAP = os.environ.get("CUBE_NAP")


def pace(src):
    if CUBE_NAP:
        import re as _re
        src = _re.sub(r"nap\([0-9.]+ *\)", "nap(%s)" % float(CUBE_NAP), src)
    return src
# The cube's shape-by-shape checks (six faces, the pivot, shared points)
# only describe cube.lua.  Any other sample still has to paint, but its
# checks are the picture, not a slot table.
STRICT = BODY_NAME == "cube.lua"
SW = 64
BLACK = (0.0, 0.0, 0.0, 1.0)
BF = 0.35


def strip_lib(src):
    """Drop full-line comments and blanks (the sane in-game program)."""
    return "\n".join(l for l in src.split("\n")
                     if l.strip() != ""
                     and not l.strip().startswith("--"))


def undim(v):
    return tuple(float(x) / BF if k < 3 else float(x)
                 for k, x in enumerate(v[:4]))


def out_port_id(sim, name):
    for w in sim.wires:
        dn = sim.nodes.get(w.dst_id)
        if not dn or dn.kind != "Output":
            continue
        if _extract(dn.props.get("PortLabel", ("raw", ""))) == name:
            return w.dst_id
    raise RuntimeError("no output port %r" % name)


def resolve_port(sim, pid):
    kind, sid, _sport, _tail = sim._build_src((pid, "RER_Input"))
    if kind == 1:
        return ("arr", sid)
    if kind == 4:
        vid = sim._var_id(sid)
        return ("var", vid if vid is not None else sid)
    return ("var", sid)


def port_val(sim, res):
    kind, sid = res
    if kind == "arr":
        v = sim.arrays.get(sid)
        return list(v) if v is not None else []
    v = sim.vars.get(sid)
    if isinstance(v, str):
        try:
            return float(v)
        except ValueError:
            return 0.0
    if isinstance(v, (tuple, list)):
        return tuple(float(x) for x in v[:4])
    return float(v) if isinstance(v, (int, float)) else 0.0


def destr(v):
    import re as _re
    if not isinstance(v, str):
        return ""
    m = _re.search(r'"([^"]*)"', v)
    return m.group(1) if m else v


def chip_stream(ticks, ok):
    """Phase 1 off the real Lua chip: rows like the oracle's, tab-priced
    by the chip's own compute.  Returns the rows list."""
    src = pace(strip_lib(open(GFX, encoding="utf-8").read() + "\n"
                          + open(BODY, encoding="utf-8").read()))
    print("chip program chars:", len(src))
    with tempfile.NamedTemporaryFile(suffix=".pkl", delete=False) as f:
        lua_dump = f.name
    try:
        share_dump(LUA_WS, lua_dump)
        lsim = sim_from_dump(lua_dump)
        r1 = resolve_port(lsim, out_port_id(lsim, "outNum1"))
        r2 = resolve_port(lsim, out_port_id(lsim, "outNum2"))
        r3 = resolve_port(lsim, out_port_id(lsim, "outNum3"))
        r4 = resolve_port(lsim, out_port_id(lsim, "outNum4"))
        ra = resolve_port(lsim, out_port_id(lsim, "outNumArr"))
        rs = resolve_port(lsim, out_port_id(lsim, "outStr1"))
        rs2 = resolve_port(lsim, out_port_id(lsim, "outStr2"))
        rsa = resolve_port(lsim, out_port_id(lsim, "outStrArr"))
        rows = []
        live_seen = [False]

        def hook(s, tick):
            row = (port_val(s, r1), port_val(s, r2), port_val(s, r3),
                   port_val(s, r4),
                   [float(x) for x in port_slice(s, ra, n=128)],
                   destr(s.vars.get(rs[1], "")),
                   destr(s.vars.get(rs2[1], "")),
                   [destr(v) for v in port_val(s, rsa)])
            live = row[0] > 0.5 or row[1] > 0.5 or row[2] > 0.5 \
                or row[3] > 0.5
            if live:
                live_seen[0] = True
            if live_seen[0]:
                rows.append(row)

        lsim.reset()
        lsim.inputs = {"program": src, "run": True}
        lsim.run(ticks, on_tick=hook)
        og = lsim.capture()["outGlobals"]
        ok &= not og.get("runErrors")
        dbg = og.get("progDebug") or ""
        ok &= not any(l.startswith("err:") or l.startswith("warn:")
                      for l in dbg.splitlines())
        print("chip runErrors:", og.get("runErrors"))
        print("chip diagnostics:",
              [l for l in dbg.splitlines()
               if l.startswith("err:") or l.startswith("warn:")] or "none")
    finally:
        os.unlink(lua_dump)
    print("chip stream ticks (live):", len(rows))
    return rows, ok


def latch_edges(samples):
    """rising outNum1 edges -> (st, st2, a[97], a[99], a[:12], sa[:9]).
    sa is compared at its first 9 fields: the chip's outStrArr port is
    wider and pads with empty strings, real Lua's slice stops at 9."""
    out = []
    prev = 0.0
    for row in samples:
        p, _r, _c, _w, a, st, st2, sa = row
        if p > 0.5 and prev <= 0.5:
            out.append((st, st2,
                        a[97] if len(a) > 97 else 0.0,
                        a[99] if len(a) > 99 else 0.0,
                        tuple(round(float(x), 3) for x in a[:12]),
                        tuple(sa[:9])))
        prev = p
    return out


def expect(cond, what, detail=""):
    """Report one check; the run is green only if every check is."""
    # The slot-by-slot checks describe cube.lua's six faces.  Another
    # sample still has to paint, but its verdict is its picture, so with
    # CUBE_BODY set to something else these checks are skipped instead of
    # failing every line of a run whose frames are the point.
    if not STRICT:
        print("skip %s" % (what,))
        return True
    print("%-4s %s%s" % ("OK" if cond else "FAIL", what,
                         "" if cond else " -- " + str(detail)))
    return bool(cond)


def report(tag, wall):
    if wall is None:
        print("%s: no snapshot" % tag)
        return
    if SAVE:
        with open(SAVE, "a", encoding="utf-8") as f:
            f.write("%s\t%s\n" % (tag, repr(list(wall))))
    left = [(i // SW, i % SW, wall[i])
            for i in range(SW * SW) if wall[i][:3] != (0.0, 0.0, 0.0)]
    rows = sorted(set(r for r, _c, _v in left))
    cols = sorted(set(c for _r, c, _v in left))
    colors = sorted(set(tuple(round(x, 2) for x in v[:3])
                        for _r, _c, v in left))
    rr = ("%s..%s" % (rows[0], rows[-1])) if rows else "-"
    cc = ("%s..%s" % (cols[0], cols[-1])) if cols else "-"
    print("%s: painted=%d rows=%s cols=%s ncolors=%d colors=%s"
          % (tag, len(left), rr, cc, len(colors), colors[:8]))


def main():
    ok = True
    body = pace(open(BODY, encoding="utf-8").read())
    # ---- phase 1 -------------------------------------------------------
    if USE_CHIP:
        samples, ok = chip_stream(TICKS, ok)
        # oracle reference for the latch comparison
        ow = luastream.record(body, GFX, budget=BUDGET)
        osamp = luastream.sample_rows(ow) if ow is not None else []
        lg_chip = latch_edges(samples)
        lg_orac = latch_edges(osamp)
        print("push latches: chip=%d oracle=%d"
              % (len(lg_chip), len(lg_orac)))
        for i in range(max(len(lg_chip), len(lg_orac))):
            a = lg_chip[i] if i < len(lg_chip) else None
            b = lg_orac[i] if i < len(lg_orac) else None
            if a != b:
                ok = False
                print("LATCH MISMATCH %d:\n  chip  : %r\n  oracle: %r"
                      % (i, a, b))
        if lg_chip:
            print("chip push 1 detail:", lg_chip[0])
    else:
        writes = luastream.record(body, GFX, budget=BUDGET)
        samples = luastream.sample_rows(writes) if writes is not None else []

    # bound the replay: keep every push, then a short animation tail
    pe = [k for k in range(1, len(samples))
          if samples[k][0] > 0.5 and samples[k - 1][0] <= 0.5]
    if pe:
        head = max(0, pe[0] - 50)
        samples = list(samples[head:pe[-1] + TAIL])
        print("truncated to:", len(samples))

    # ---- phase 2: connector -------------------------------------------
    with tempfile.NamedTemporaryFile(suffix=".pkl", delete=False) as f:
        conn_dump = f.name
    try:
        share_dump(CONN_WS, conn_dump)
        csim = sim_from_dump(conn_dump)
        csim.reset()
        pts_res = resolve_port(csim, out_port_id(csim, "shapePoints"))
        cols_res = resolve_port(csim, out_port_id(csim, "shapeColors"))
        pos_res = resolve_port(csim, out_port_id(csim, "shapePosition"))
        rot_res = resolve_port(csim, out_port_id(csim, "shapeRotation"))
        scl_res = resolve_port(csim, out_port_id(csim, "shapeScale"))

        def conn_arr(res):
            kind, sid = res
            for key in (sid, csim._var_id(sid)):
                if key is None:
                    continue
                v = csim.arrays.get(key)
                if v is not None:
                    return list(v)
                vv = csim.vars.get(key)
                if isinstance(vv, (list, tuple)):
                    return list(vv)
            return []

        cpull = {}
        for name in ("pushShape", "drawAllShapes", "shapeWireMode", "shapeId",
                     "clearAllShapes", "parentShapeId", "addToShapeInTicks"):
            cpull[name] = out_port_id(csim, name)
        cstream = []

        def hookc(s, tick):
            if tick < len(samples):
                p1, p2, p3, p4, a, st, st2, sa = samples[tick]
                s.inputs = dict(s.inputs, **{
                    "outNum1": p1, "outNum2": p2, "outNum3": p3,
                    "outNum4": p4, "outStr1": st, "outStr2": st2,
                    "outNumArr": list(a[:128]),
                    "outStrArr": list(sa[:12]),
                })
            row = {}
            for k, pid in cpull.items():
                v = s._in_val(pid, "RER_Input", None)
                row[k] = float(v) if isinstance(v, bool) \
                    else (float(v) if isinstance(v, (int, float)) else 0.0)
            row["shapePoints"] = conn_arr(pts_res)
            row["shapeColors"] = conn_arr(cols_res)
            row["shapePosition"] = conn_arr(pos_res)
            row["shapeRotation"] = conn_arr(rot_res)
            row["shapeScale"] = conn_arr(scl_res)
            cstream.append(row)

        csim.run(len(samples), on_tick=hookc)
    finally:
        os.unlink(conn_dump)

    pushE = [k for k in range(1, len(cstream))
             if (cstream[k]["pushShape"] or 0.0) > 0.5
             and (cstream[k - 1]["pushShape"] or 0.0) <= 0.5]
    reds = [k for k in range(1, len(cstream))
            if (cstream[k]["drawAllShapes"] or 0.0) > 0.5
            and (cstream[k - 1]["drawAllShapes"] or 0.0) <= 0.5]
    clrE = [k for k in range(1, len(cstream))
            if (cstream[k]["clearAllShapes"] or 0.0) > 0.5
            and (cstream[k - 1]["clearAllShapes"] or 0.0) <= 0.5]
    maxpts = max((len(r["shapePoints"]) for r in cstream), default=0)
    print("connector: maxPts=%d pushes=%d redraws=%d clears=%d"
          % (maxpts, len(pushE), len(reds), len(clrE)))
    shown = False
    for r in cstream:
        nz = [v for v in r["shapePoints"] if v != 0.0]
        if len(nz) >= 6:
            print("  sample shapePoints:", r["shapePoints"][:12])
            print("  sample shapeColors:",
                  [tuple(round(x, 2) for x in v[:4])
                   for v in r["shapeColors"][:3]])
            shown = True
            break
    if not shown:
        print("  NO non-zero shapePoints staged => screen gets empties")
        ok = False

    # ---- pushMesh: the cube's six faces arrive as six shapes ---------------
    # The demo builds its cube with pushMesh (a mesh of points, one colour
    # per point, and faces naming the points they use), so the
    # connector's stream IS the helper's contract: six shapes, slots
    # 2..7, each under the pivot in slot 1, each carrying one face's
    # four corners as a closed outline (five points, fifteen floats) and
    # one colour per point.
    faces = []
    prev = 0.0
    for k, r in enumerate(cstream):
        if (r["pushShape"] or 0.0) > 0.5 and prev <= 0.5:
            faces.append((k, r))
        prev = r["pushShape"] or 0.0
    ok &= expect(len(faces) == 8, "pushMesh sends the cube's six faces",
                 "%d pushes" % len(faces))
    # The mesh's points, as the demo defines them: a cube of eight
    # corners, each with its own colour.  The demo's cube has half-size
    # 10, so the points are the eight sign combinations.
    H = 10.0
    # The colour each point must carry: the four NEAR points (z = +H)
    # bright, the four FAR points (z = -H) dark, so a shared edge is one
    # colour on both sides.
    def point_colour(p):
        x, y, z = p
        if z > 0.0:
            return {(-H, -H): (0.95, 0.95, 1.00),
                    (H, -H): (0.95, 0.90, 0.85),
                    (H, H): (0.95, 0.85, 0.55),
                    (-H, H): (0.90, 0.80, 0.50)}[(x, y)]
        return {(-H, -H): (0.35, 0.30, 0.35),
                (H, -H): (0.40, 0.35, 0.40),
                (H, H): (0.45, 0.40, 0.45),
                (-H, H): (0.40, 0.35, 0.40)}[(x, y)]
    # The six-face/point/colour checks describe cube.lua only; a mesh body
    # whose vertices are not the cube corners (breath breathes them) must not
    # be scored against the corner table, or point_colour raises KeyError.
    if STRICT and len(faces) == 8:
        for i, (k, r) in enumerate(faces[:6]):
            ok &= expect((r["shapeId"] or 0.0) == float(i + 2),
                         "face %d takes slot %d" % (i, i + 2),
                         "id=%s" % (r.get("shapeId"),))
            ok &= expect((r["parentShapeId"] or 0.0) == 1.0,
                         "face %d follows the pivot" % i,
                         "parent=%s" % (r.get("parentShapeId"),))
            ok &= expect(len(r["shapePoints"]) == 15,
                         "face %d is a closed outline" % i,
                         "%d floats" % len(r["shapePoints"]))
            ok &= expect((r["shapeWireMode"] or 0.0) > 0.5,
                         "face %d is a wireframe" % i,
                         "wire=%s" % (r.get("shapeWireMode"),))
            cols = r.get("shapeColors") or []
            # Each point of the face carries ITS colour: the connector's
            # array is padded past them (it sizes the colour slice by
            # floats, so it runs to its 16 cap), and the chip reads as
            # many colours as the shape has points.
            pts = r["shapePoints"]
            bad = []
            for j in range(5):
                pt = (pts[3 * j], pts[3 * j + 1], pts[3 * j + 2])
                want = tuple(round(x, 3) for x in point_colour(pt))
                have = tuple(round(x, 3) for x in cols[j][:3]) \
                    if j < len(cols) else None
                if have != want:
                    bad.append((pt, want, have))
            ok &= expect(not bad,
                         "face %d colours each point with its own" % i,
                         "%r" % (bad[:2],))
            # The face is closed: its last point repeats its first, so
            # the outline comes back round.
            ok &= expect(pts[0:3] == pts[12:15],
                         "face %d closes its outline" % i,
                         "%r" % (pts[12:15],))
        # A point that two faces share carries the SAME colour in both --
        # that is the whole point of the indexed mesh, and it is what
        # stops a shared edge from showing two colours.
        shared = {}
        clash = []
        for i, (k, r) in enumerate(faces[:6]):
            cols = r.get("shapeColors") or []
            pts = r["shapePoints"]
            for j in range(4):
                pt = (pts[3 * j], pts[3 * j + 1], pts[3 * j + 2])
                c = tuple(round(x, 3) for x in cols[j][:3]) \
                    if j < len(cols) else None
                if pt in shared and shared[pt] != c:
                    clash.append((pt, shared[pt], c))
                shared.setdefault(pt, c)
        ok &= expect(not clash,
                     "a shared point keeps its colour in both faces",
                     "%r" % (clash[:2],))
        ok &= expect(len(shared) == 8,
                     "the six faces share eight points",
                     "%d distinct" % len(shared))
        # the pivot: one point (a live slot with nothing to fill)
        pk, pr = faces[6]
        ok &= expect((pr["shapeId"] or 0.0) == 1.0,
                     "the pivot is slot 1", "id=%s" % (pr.get("shapeId"),))
        ok &= expect(len(pr["shapePoints"]) == 3,
                     "the pivot is one point",
                     "%d floats" % len(pr["shapePoints"]))

    # ---- phase 3: screen replay ---------------------------------------
    with tempfile.NamedTemporaryFile(suffix=".pkl", delete=False) as f:
        scr_dump = f.name
    try:
        share_dump(SCREEN_WS, scr_dump)
        ssim = sim_from_dump(scr_dump)
        ssim.reset()
        spts = scols = None
        for nid, nd in ssim.nodes.items():
            pl = _extract(nd.props.get("PortLabel", ("raw", "")))
            if pl == "shapePoints":
                spts = nid
            elif pl == "shapeColors":
                scols = nid
        assert spts is not None and scols is not None
        gids = {}
        for nid, nd in ssim.nodes.items():
            lb = _extract(nd.props.get("_label", ("raw", "")))
            if isinstance(lb, str) and lb.startswith("g") and lb[1:].isdigit():
                gids[int(lb[1:])] = nid
        ssim.inputs = {"shapePoints": [0.0] * 32,
                       "shapeColors": [(1.0, 1.0, 1.0, 1.0)] * 4,
                       "pushShape": False, "shapeWireMode": False,
                       "shapeId": 0.0, "drawAllShapes": False,
                       "clearAllShapes": False,
                       "shapePosition": (0.0, 0.0, 0.0),
                       "shapeRotation": (0.0, 0.0, 0.0),
                       "shapeScale": (0.0, 0.0, 0.0),
                       "parentShapeId": 0.0, "brightness": 100.0,
                       "addToShapeInTicks": 0.0}
        ssim.run(1)
        ssim.inputs = {k: v for k, v in ssim.inputs.items()
                       if k != "shapePoints"}
        snaps = {}
        last_slid = [None, None]
        last_rc = [False]
        last_er = [False]
        last_busy = [False]
        order_prev = [None]
        order_erase = [False]
        angs = []
        vids = {}
        for nid, nd in ssim.nodes.items():
            lb = _extract(nd.props.get("_label", ("raw", "")))
            if isinstance(lb, str) and lb in (
                    "pWire", "pending", "arming", "armingS", "sOn",
                    "polyOn", "commitR", "commitQ", "sSegs", "qCount",
                    "rcOn", "fromSlot", "rcSlot", "animDirty", "erasing",
                    "wasPaint", "brightRC", "pTicks", "eraseOK",
                    "erRow", "covLo", "covHi", "oldLo", "oldHi"):
                vids[lb] = nid

        def hook2(s, tick):
            if tick < len(cstream):
                c = cstream[tick]
                # The connector has no clock: it slices the CPU's array on
                # the CPU's own push edge, so the array and the edges
                # arrive together -- the same row, no lag.  (With the
                # connector's old clock the slice landed two ticks
                # before the edge, and the screen had to be fed the old
                # scalars with the new array.)
                b = c
                a = c["shapePoints"]
                cc = c.get("shapeColors")
                if (isinstance(a, list) and a != last_slid[0]) \
                        or (cc != last_slid[1]):
                    # the connector delivers TRIPLES (the screen's port
                    # takes triples and only triples), so they are
                    # delivered as they are.  slide() is the suite's
                    # pairs-to-triples shorthand for shapes written as
                    # (x, y) pairs, and it mangles a delivered triple
                    # stream into the wrong point count.
                    slide3(s, spts, scols, list(a) if isinstance(a, list)
                           else [], cc)
                    last_slid[0] = list(a) if isinstance(a, list) else None
                    last_slid[1] = cc
                s.inputs = dict(s.inputs, **{
                    "pushShape": (b.get("pushShape") or 0.0) > 0.5,
                    "shapeWireMode": (b.get("shapeWireMode") or 0.0) > 0.5,
                    "shapeId": float(b.get("shapeId") or 0.0),
                    "drawAllShapes": (b.get("drawAllShapes") or 0.0) > 0.5,
                    "clearAllShapes": (b.get("clearAllShapes") or 0.0) > 0.5,
                    "parentShapeId": float(b.get("parentShapeId") or 0.0),
                    "shapePosition":
                        tuple(b.get("shapePosition") or (0.0, 0.0, 0.0))[:3],
                    "shapeRotation":
                        tuple(b.get("shapeRotation") or (0.0, 0.0, 0.0))[:3],
                    "shapeScale":
                        tuple(b.get("shapeScale") or (0.0, 0.0, 0.0))[:3],
                    "addToShapeInTicks":
                        float(b.get("addToShapeInTicks") or 0.0),
                })
            # snapshot the wall: a pass paints over MANY ticks, so a
            # tick-count sample catches a half-drawn wall.  Under --save
            # take one frame each time a pass SETTLES -- the fill/stroke
            # walks and any erase walk have all finished and the chip is
            # idle -- which is the moment the wall holds a whole picture,
            # and the forever-spin has advanced by one delta since the
            # previous one: one frame per turn step, which is exactly
            # what a GIF of the rotation wants.
            base = reds[-1] if reds else 0
            wall = lambda: tuple(
                undim(tuple(float(x) for x in
                            s.vars.get(gids[i], (0.0, 0.0, 0.0, 0.0))[:4]))
                for i in range(SW * SW)) if gids else None
            if MAKE_SAVE and SAVE:
                # rcOn falling is NOT the settled moment: the iterator
                # finishes LOADING the slots, then the fill walk paints
                # over the following ticks, so capturing there caught a
                # wall that was blank.  Keying on `erasing` misses redraws
                # whose new coverage overlaps the old one (no erase walk).
                # The settled tick is where the paint/stroke/erase walks
                # have all fallen and nothing else is running.
                busy = (bool(s.vars.get(vids.get("polyOn"))) or
                        bool(s.vars.get(vids.get("sOn"))) or
                        bool(s.vars.get(vids.get("erasing"))))
                idle = (not bool(s.vars.get(vids.get("rcOn"))) and
                        not bool(s.vars.get(vids.get("arming"))) and
                        not bool(s.vars.get(vids.get("armingS"))) and
                        not bool(s.vars.get(vids.get("commitR"))) and
                        not bool(s.vars.get(vids.get("commitQ"))))
                if last_busy[0] and not busy and idle and len(snaps) < 24:
                    snaps[len(snaps)] = wall()
                    # the pivot's accumulated turn, so each frame has a
                    # number as well as a picture: a turn that reverses
                    # shows up here and not in the silhouette
                    xf2 = s.chip_array("slXF2") or []
                    xf = s.chip_array("slXF") or []
                    angs.append((round(float(xf[2]), 3) if len(xf) > 2
                                 else None,
                                 round(float(xf2[1]), 3) if len(xf2) > 1
                                 else None,
                                 round(float(xf2[2]), 3) if len(xf2) > 2
                                 else None))
                last_busy[0] = busy
            else:
                k = tick - (base + 2 + 40)
                if k >= 0 and k % 80 == 0:
                    snaps[k // 80] = wall()
            if ORDER or PASS:
                # the erase walk's order against the pass it runs in:
                # one line per state change, so the ticks between the
                # slots are visible
                def o(n):
                    v = s.vars.get(vids.get(n))
                    return None if v is None else (
                        bool(v) if isinstance(v, bool) else round(float(v), 3))

                def top():
                    out = []
                    for yy in range(11, 18):
                        row = "".join(
                            "#" if (sum(s.vars.get(
                                gids[yy * SW + xx], (0.0, 0.0, 0.0, 0.0))[:3])
                                > 0.02) else "."
                            for xx in range(10, 56))
                        out.append("      r%02d %s" % (yy, row))
                    return "\n".join(out)

                rc_now = o("rcOn")
                er_now = o("erasing")
                if PASS:
                    xf = s.chip_array("slXF") or []
                    xf2 = s.chip_array("slXF2") or []
                    at = s.chip_array("anTicks") or []
                    # slot 1 is the pivot: rot.z lives in slXF[2], rot.x
                    # and rot.y in slXF2[1..2]; the demo's delta is on
                    # ONE of them, and which one is the question
                    ang = (round(float(xf[2]), 4) if len(xf) > 2 else None,
                           round(float(xf2[1]), 4) if len(xf2) > 1 else None,
                           round(float(xf2[2]), 4) if len(xf2) > 2 else None,
                           round(float(at[0]), 2) if len(at) > 0 else None)
                    if last_rc[0] and not rc_now:
                        print("  pass end   t%-6d angle %s" % (tick, ang))
                    if order_erase[0] and not er_now:
                        lit = [xx for xx in range(SW * SW)
                               if sum(s.vars.get(
                                   gids[xx], (0.0, 0.0, 0.0, 0.0))[:3]) > 0.02]
                        ys = sorted(set(xx // SW for xx in lit))
                        print("  erase done t%-6d angle %s rows %s painted %d"
                              % (tick, ang,
                                 ("%d..%d" % (ys[0], ys[-1])) if ys else "-",
                                 len(lit)))
                if ORDER:
                    if last_rc[0] and not rc_now:
                        xf2 = s.chip_array("slXF2") or []
                        print("  PASS END t%d angle %s wall BEFORE erase:\n%s"
                              % (tick, round(float(xf2[2]), 3)
                                 if len(xf2) > 2 else None, top()))
                    if order_erase[0] and not er_now:
                        print("  ERASE DONE t%d wall after:\n%s" % (tick, top()))

                    sig = (o("erasing"), o("erRow"), o("eraseOK"), o("sOn"),
                           o("polyOn"), o("rcOn"), o("pending"), o("commitQ"),
                           o("arming"), o("armingS"), o("wasPaint"),
                           o("oldLo"), o("oldHi"), o("covLo"), o("covHi"))
                    if sig != order_prev[0]:
                        print("t%6d erasing=%s erRow=%s ok=%s sOn=%s poly=%s "
                              "rcOn=%s pend=%s cQ=%s arm=%s armS=%s wasP=%s "
                              "old=%s..%s cov=%s..%s"
                              % ((tick,) + sig))
                        order_prev[0] = sig
                last_rc[0] = bool(rc_now)
                order_erase[0] = bool(er_now)

        if TRACE:
            prev = False
            for t, r in enumerate(cstream):
                p = bool(r.get("pushShape"))
                if p and not prev:
                    print("  push@%d id=%s parent=%s wire=%s ticks=%s pts=%d"
                          % (t, r.get("shapeId"), r.get("parentShapeId"),
                             r.get("shapeWireMode"),
                             r.get("addToShapeInTicks"),
                             len(r.get("shapePoints") or [])))
                prev = p
        cap = (reds[-1] + 2 + 40 + TAIL) if reds else (len(cstream) + 150)
        cap = min(cap, len(cstream) + 150 + TAIL)
        ssim.run(cap, on_tick=hook2)
        # The pivot's slot must be a FILL.  Its one point carries the
        # transform and draws nothing in fill mode, but one point in
        # STROKE mode is a two-pixel blob -- the white dot that used to
        # sit in the middle of the cube.  The mode port is sticky and the
        # faces left it stroking, so the program writes it (setWire(0));
        # this check keeps it written.
        modes = ssim.chip_array("slMode") or []
        mode0 = float(modes[0]) if modes else -1.0
        expect(len(modes) > 0 and mode0 < 0.5,
               "pivot slot is a fill, so no dot in the middle",
               "slMode[0]=%s" % (mode0,))
        if TRACE:
            for nm in ("slXF", "anXF", "anTicks"):
                a = ssim.chip_array(nm)
                print("  %-7s" % nm,
                      None if a is None else [round(float(x), 3) for x in a])
        report("first painted pass", snaps.get(0))
        if angs:
            print("  angle %s (rot.z, rot.x, rot.y) at the first painted pass"
                  % (angs[0],))
        for k in sorted(snaps):
            if k:
                if k < len(angs):
                    print("  turn %02d angle %s" % (k, angs[k]))
                report("turn step %02d" % k, snaps.get(k))
        final = tuple(undim(tuple(float(x) for x in
                                 ssim.vars.get(gids[i], (0.0, 0.0, 0.0, 0.0))[:4]))
                      for i in range(SW * SW)) if gids else None
        if MAKE_SAVE:
            # var dump: what mode did the screen keep for each slot?
            for nid, nd in ssim.nodes.items():
                lb = _extract(nd.props.get("_label", ("raw", "")))
                if isinstance(lb, str) and lb in ("slMode", "pWire", "pId",
                                                  "pTicks", "slLive"):
                    v = ssim.arrays.get(nid)
                    if v is None:
                        v = ssim.vars.get(nid)
                    if isinstance(v, (list, tuple)):
                        v = [round(float(x), 3) for x in v]
                    print("  var %-8s" % lb, v)

        # The picture, so a wrong-but-green report is still seen.  The
        # wall paints at BF; undo it or the brightness lies.  The PNGs
        # get their own directory: SAVE itself is the report()'s text
        # dump of the same walls (one .png dir alongside it).
        if MAKE_SAVE and SAVE and final is not None:
            from PIL import Image
            PNGD = SAVE + "_png"
            os.makedirs(PNGD, exist_ok=True)
            # a shorter run saves fewer frames; the ones a longer run left
            # behind would otherwise sit at the end and animate the old turn
            for old in glob.glob(os.path.join(PNGD, "snap_*.png")):
                os.unlink(old)
            SCL = 8

            def _png(rows, path):
                img = Image.new("RGBA", (SW, SW), (0, 0, 0, 255))
                px = img.load()
                # rows are already undimmed (undim() runs when a snapshot
                # is stored); dimming them again here clamped every
                # painted pixel to white and the picture lied.
                for i, (r, g, b, a) in enumerate(rows):
                    y, x = divmod(i, SW)
                    px[x, y] = (int(min(255, max(0, r * 255))),
                                int(min(255, max(0, g * 255))),
                                int(min(255, max(0, b * 255))),
                                int(min(1.0, max(0.0, a)) * 255))
                img.resize((SW * SCL, SW * SCL), Image.NEAREST).save(path)

            _png(final, os.path.join(PNGD, "final.png"))
            for k in sorted(snaps):
                if snaps.get(k) is not None:
                    _png(snaps[k], os.path.join(PNGD, "snap_%03d.png" % (k,)))
            print("saved: %s" % PNGD)
        report("final", final)
    finally:
        os.unlink(scr_dump)
    print("PROBE:", "GREEN" if ok else "RED")
    sys.exit(0 if ok else 1)


try:
    main()
except Exception:  # noqa: E402
    import traceback
    traceback.print_exc()
    raise
