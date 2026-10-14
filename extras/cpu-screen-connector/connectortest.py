"""Three-chip chain test: Lua CPU -> connector -> screen.

A small Lua driver exercises every translation the connector does --
push/draw thresholds, the terminator-truncated tight points pass,
the per-point colour slice (points first, terminator, then four
floats per point), the parent id from outStr2, the transform vecs
from outStrArr, shapeWireMode, the string slot id and the clear flag --
and the wall is diffed against a Python model of the whole chain,
so a dropped channel, a wrong colour or a misread slot shows up as
a pixel diff.

The sim's math gates are float-only, so colour arithmetic reads as
0.0 there; colormath.install() patches them to the documented
channel-wise LinearColor semantics (test-side only -- the repo's
irrun/ simulator is untouched shared infrastructure).

  python -u extras/cpu-screen-connector/connectortest.py   (exit 0 = green)
"""
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "irrun"))
sys.path.insert(0, os.path.join(HERE, "..", "screen"))

from irsims import share_dump, sim_from_dump, _extract  # noqa: E402
import colormath  # noqa: E402

colormath.install()
from painttest import poly_pixels, stroke_pixels, slide, xf_points  # noqa: E402
from animtest import port_slice  # noqa: E402

LUA_WS = os.path.join(ROOT, "lua.ws")
CONN_WS = os.path.join(HERE, "connector.ws")
SCREEN_WS = os.path.join(HERE, "..", "screen", "screen.ws")
SW = 64
TICKS = int(sys.argv[1]) if len(sys.argv) > 1 else 2100
BLACK = (0.0, 0.0, 0.0, 1.0)
# The driver is quiet until ~1500 (boot and staging); both replays skip
# that dead head (phases 2-3 run TICKS - SLICE ticks feeding samples and
# rows at +SLICE).  The connector is combinational and the screen has no
# edges before the first push, so the slice is exactly equivalent.
SLICE = 1400

DRIVER = """
local function tick()
  local c = clock()
  while clock() == c do end
end
local function nap(c)
  local t = clock()
  while clock() < t + c do end
end
local function fire()
  outNum(1, 1.0)
  tick()
  outNum(1, 0.0)
  outNum(2, 1.0)
  tick()
  outNum(2, 0.0)
  tick()
end
-- shape 1: immediate red fill square; points first, then a -5
-- terminator (its magnitude is the colour count: 4), then the colours.
-- outNumArr takes at most 8 values a call, so 16 colour floats are two
-- calls.
outNumArr(1, 4.0, 4.0, 12.0, 4.0, 12.0, 12.0, 4.0, 12.0)
outNumArr(9, -5.0)
outNumArr(10, 1.0, 0.0, 0.0, 1.0,
              1.0, 0.0, 0.0, 1.0)
outNumArr(18, 1.0, 0.0, 0.0, 1.0,
              1.0, 0.0, 0.0, 1.0)
fire()
-- shape 2: immediate blue stroke (outNum4 = wire)
outNum(4, 1.0)
outNumArr(1, 30.0, 30.0, 50.0, 30.0, 30.0, 50.0)
outNumArr(7, -4.0)
outNumArr(8, 0.1, 0.4, 1.0, 1.0,
             0.1, 0.4, 1.0, 1.0)
outNumArr(16, 0.1, 0.4, 1.0, 1.0)
fire()
outNum(4, 0.0)
-- the stroke is ~22 rows plus its segment steps: nap past the burst
-- (drivers pace bursts; a push would abort the walk mid-flight and
-- the wall would keep a partial stroke)
nap(0.4)
-- shape 3: immediate moved square -- the transform rides outStrArr
-- (8 values a call at most, so nine slots are two calls), the parent
-- rides outStr2 ("2" here, a dead slot: proves a nonzero id parses
-- while painting with the identity, like an empty outStr1 would)
outStr(2, "2")
outStrArr(1, "8", "4", "0", "0", "0", "0", "1", "1")
outStrArr(9, "1")
outNumArr(1, 4.0, 4.0, 12.0, 4.0, 12.0, 12.0, 4.0, 12.0)
outNumArr(9, -5.0)
outNumArr(10, 0.0, 0.0, 1.0, 1.0,
              0.0, 0.0, 1.0, 1.0)
outNumArr(18, 0.0, 0.0, 1.0, 1.0,
              0.0, 0.0, 1.0, 1.0)
fire()
outStr(2, "")
-- shape 4: retained green triangle, slot 1 (outStr1 = id as text).
-- The transform and parent stage per push, so this resets both to
-- identity first -- otherwise the slot would inherit shape 3's move.
outStr(1, "1")
outStr(2, "")
outStrArr(1, "0", "0", "0", "0", "0", "0", "1", "1")
outStrArr(9, "1")
outNumArr(1, 8.0, 8.0, 20.0, 8.0, 8.0, 20.0)
outNumArr(7, -4.0)
outNumArr(8, 0.0, 1.0, 0.0, 0.5,
             0.0, 1.0, 0.0, 0.5)
outNumArr(16, 0.0, 1.0, 0.0, 0.5)
fire()
outStr(1, "")
-- let shape 4's recomposite (clear + repaint, ~85 ticks) finish before
-- clearing, or the pulse abandons it mid-flight and no complete triangle
-- ever lands for the snapshot below
local wc = clock()
while clock() < wc + 1.2 do end
-- clear via outNum3 pulse, then off again
outNum(3, 1.0)
tick()
tick()
outNum(3, 0.0)
tick()
tick()
-- clearAllShapes only forgets the slots: the next drawAllShapes is the pulse that
-- actually blacks the wall
outNum(2, 1.0)
tick()
outNum(2, 0.0)
tick()
tick()
print('driver done')
"""


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


def expect(cond, label, detail=""):
    print("%-38s %s %s" % (label, "OK  " if cond else "FAIL",
                           detail if not cond else ""))
    return cond


def main():
    dumps = []
    ok = True
    try:
        # ---- phase 1: Lua chip runs the driver -------------------------
        with tempfile.NamedTemporaryFile(suffix=".pkl", delete=False) as f:
            lua_dump = f.name
        dumps.append(lua_dump)
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
        samples = []

        def destr(v):
            # one string-array element: strip the "quoted" wrapper the
            # same way as the scalar string ports
            import re as _re
            if not isinstance(v, str):
                return ""
            m = _re.search(r'"([^"]*)"', v)
            return m.group(1) if m else v

        def hook(s, tick):
            # the id travels as text: read the raw string port (values may
            # carry "quoted" wrappers, stripped the same way as _out_globals)
            import re as _re
            kind, sid = rs
            raw = s.vars.get(sid, "")
            if not isinstance(raw, str):
                raw = ""
            else:
                m = _re.search(r'"([^"]*)"', raw)
                raw = m.group(1) if m else raw
            kind2, sid2 = rs2
            raw2 = s.vars.get(sid2, "")
            if not isinstance(raw2, str):
                raw2 = ""
            else:
                m = _re.search(r'"([^"]*)"', raw2)
                raw2 = m.group(1) if m else raw2
            samples.append((port_val(s, r1), port_val(s, r2),
                            port_val(s, r3), port_val(s, r4),
                            port_slice(s, ra), raw, raw2,
                            [destr(v) for v in port_val(s, rsa)]))

        lsim.reset()
        lsim.inputs = {"program": DRIVER, "run": True}
        lsim.run(TICKS, on_tick=hook)
        og = lsim.capture()["outGlobals"]
        ok &= expect(not og.get("runErrors"), "driver runs without errors",
                     str(og.get("runErrors")))
        dbg = og.get("progDebug") or ""
        ok &= expect(not any(l.startswith("err:") for l in dbg.splitlines()),
                     "driver compiles clean", str(dbg))
        p3_hi = [k for k, s in enumerate(samples) if s[2] > 0.5]
        p4_hi = [k for k, s in enumerate(samples) if s[3] > 0.5]
        print("   lua outNum3 high at: %s  outNum4 high at: %s"
              % (p3_hi[:8], p4_hi[:8]))

        # ---- phase 2: connector translates ------------------------------
        with tempfile.NamedTemporaryFile(suffix=".pkl", delete=False) as f:
            conn_dump = f.name
        dumps.append(conn_dump)
        share_dump(CONN_WS, conn_dump)
        csim = sim_from_dump(conn_dump)
        csim.reset()
        # output port value readers (resolved once the sim exists).
        # shapePoints is the connector's truncated tight array (backing
        # var pts) and shapeColors its per-point colour array (backing
        # var cols): both mirror vars, so both read through the same
        # backing-store lookup.
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

        # the pure-combinational scalars never cache (nothing queues them
        # without a change), so they read back through pull evaluation --
        # in game they are plain wires, always live.  (clearAllShapes is pure
        # too: it belongs here, not in cout.)
        cpull = {}
        for name in ("pushShape", "drawAllShapes", "shapeWireMode", "shapeId",
                     "clearAllShapes", "parentShapeId"):
            cpull[name] = out_port_id(csim, name)
        cstream = []

        def hookc2(s, tick):
            k = tick + SLICE
            if k < len(samples):
                p1, p2, p3, p4, a, st, st2, sa = samples[k]
                s.inputs = dict(s.inputs, **{
                    "outNum1": p1, "outNum2": p2, "outNum3": p3,
                    "outNum4": p4, "outStr1": st, "outStr2": st2,
                    "outNumArr": list(a[:40]),
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

        csim.run(TICKS - SLICE, on_tick=hookc2)

        # spot-check the translation on a tick where the driver holds a
        # shape: the points pass through tight, the colours follow the
        # terminator, and the levels threshold.  Shape 1's first burst
        # sits well before shape 2 overwrites the array; skip the boot
        # ticks, where the scan's no-terminator fallback stages all 16
        # points (32 zeros).
        held = None
        for k in range(1, len(cstream)):
            cc = cstream[k]["shapeColors"]
            if cstream[k]["shapePoints"] == \
                    [4.0, 4.0, 12.0, 4.0, 12.0, 12.0, 4.0, 12.0] \
                    and len(cc) >= 4 \
                    and all(tuple(v[:4]) == (1.0, 0.0, 0.0, 1.0)
                            for v in cc[:4]):
                held = k
                break
        ok &= expect(held is not None, "connector sees a tight array", "")
        if held is not None:
            ok &= expect(cstream[held]["shapePoints"] ==
                         [4.0, 4.0, 12.0, 4.0, 12.0, 12.0, 4.0, 12.0],
                         "points truncate at the terminator",
                         "%r" % (cstream[held]["shapePoints"],))
            cc = cstream[held]["shapeColors"]
            ok &= expect(len(cc) >= 4
                         and all(tuple(v[:4]) == (1.0, 0.0, 0.0, 1.0)
                                 for v in cc[:4]),
                         "colours slice behind the terminator",
                         "%r" % (cc,))

        # the transform + parent ride the string channels: find shape 3
        # (the moved square) and check its parsed vecs and parent id
        th = None
        for k in range(1, len(cstream)):
            if cstream[k]["shapePoints"] == \
                    [4.0, 4.0, 12.0, 4.0, 12.0, 12.0, 4.0, 12.0] \
                    and (cstream[k].get("parentShapeId") or 0.0) == 2.0:
                th = k
                break
        ok &= expect(th is not None, "parent id parses from outStr2",
                     "no tick with the square + parent 2")
        if th is not None:
            prow = cstream[th]
            ok &= expect(tuple(prow["shapePosition"][:3]) == (8.0, 4.0, 0.0),
                         "shapePosition parses from outStrArr",
                         "%r" % (prow["shapePosition"],))
            ok &= expect(tuple(prow["shapeRotation"][:3]) == (0.0, 0.0, 0.0),
                         "shapeRotation parses from outStrArr",
                         "%r" % (prow["shapeRotation"],))
            ok &= expect(tuple(prow["shapeScale"][:3]) == (1.0, 1.0, 1.0),
                         "shapeScale parses from outStrArr",
                         "%r" % (prow["shapeScale"],))

        # ---- phase 3: screen paints --------------------------------------
        with tempfile.NamedTemporaryFile(suffix=".pkl", delete=False) as f:
            scr_dump = f.name
        dumps.append(scr_dump)
        share_dump(SCREEN_WS, scr_dump)
        ssim = sim_from_dump(scr_dump)
        ssim.reset()
        spts = None
        scols = None
        for nid, nd in ssim.nodes.items():
            pl = _extract(nd.props.get("PortLabel", ("raw", "")))
            if pl == "shapePoints":
                spts = nid
            elif pl == "shapeColors":
                scols = nid
        assert spts is not None
        assert scols is not None
        ssim.inputs = {"shapePoints": [0.0] * 32,
                       "shapeColors": [(1.0, 1.0, 1.0, 1.0)] * 4,
                       "pushShape": False, "shapeWireMode": False,
                       "shapeId": 0.0, "drawAllShapes": False,
                       "clearAllShapes": False, "shapePosition": (0.0, 0.0, 0.0), "shapeRotation": (0.0, 0.0, 0.0), "shapeScale": (0.0, 0.0, 0.0), "parentShapeId": 0.0, "brightness": 100.0}
        ssim.run(1)
        ssim.inputs = {k: v for k, v in ssim.inputs.items()
                       if k != "shapePoints"}

        # ---- phase 4: model ----------------------------------------------
        # shape 1 (red fill square) + shape 2 (blue stroke) accumulate,
        # shape 3 paints the moved blue square over them (immediate,
        # dead-slot parent = identity), shape 4 stores green in slot 1
        # (its commit clears and repaints just the triangle), then the
        # flag clears everything.
        # Snapshot after shape 4's commit lands, then the final black.
        # Bool edges are replayed 2 ticks after the arrays that belong to
        # them (painttest's staging rule: same-tick array+edge merges
        # deliver unreliably in sim, while real drivers stage across
        # ticks anyway), so the screen's edge ticks lag cstream by 2.
        reds = [k for k in range(1, len(cstream))
                if (cstream[k]["drawAllShapes"] or 0.0) > 0.5
                and (cstream[k - 1]["drawAllShapes"] or 0.0) <= 0.5]
        pushE = [k for k in range(1, len(cstream))
                 if (cstream[k]["pushShape"] or 0.0) > 0.5
                 and (cstream[k - 1]["pushShape"] or 0.0) <= 0.5]
        clrE = [k for k in range(1, len(cstream))
                if (cstream[k]["clearAllShapes"] or 0.0) > 0.5
                and (cstream[k - 1]["clearAllShapes"] or 0.0) <= 0.5]
        print("   edges pushes=%s reds=%s clears=%s (run %d)"
               % (pushE, reds, clrE, len(cstream)))
        snap_tick = (reds[3] + 2 + 95) if len(reds) >= 4 else None
        snap_tick2 = (reds[3] + 2 + 115) if len(reds) >= 4 else None
        # shape 3's immediate burst lands well before shape 4's push:
        # snapshot the composed wall (red square + blue stroke + the
        # moved square) to prove the transform end to end.  The burst
        # is ~12 rows from the redraw; the snapshot sits past its end
        # but strictly before the next push, which would abort it.
        snap3_tick = (reds[2] + 2 + 18) if len(reds) >= 4 else None
        snap = None

        # (snapshots are taken in hook2 below via closure state)
        snap_holder = {}
        last_slid = [None, None]

        def hook2(s, tick):
            if tick >= len(cstream):
                return
            c = cstream[tick]
            # arrays/colour lead; the bool edge follows 2 ticks later
            b = cstream[tick - 2] if tick >= 2 else {}
            a = c["shapePoints"]
            cc = c.get("shapeColors")
            # the connector's colour slice can land a tick after its
            # points, so re-slide when either half changes
            if (isinstance(a, list) and a != last_slid[0]) \
                    or (cc != last_slid[1]):
                slide(s, spts, scols, list(a) if isinstance(a, list)
                      else [], cc)
                last_slid[0] = list(a) if isinstance(a, list) else None
                last_slid[1] = cc
            s.inputs = dict(s.inputs, **{
                "pushShape": (b.get("pushShape") or 0.0) > 0.5,
                "shapeWireMode": (b.get("shapeWireMode") or 0.0) > 0.5,
                "shapeId": float(b.get("shapeId") or 0.0),
                "drawAllShapes": (b.get("drawAllShapes") or 0.0) > 0.5,
                "clearAllShapes": (b.get("clearAllShapes") or 0.0) > 0.5,
                "parentShapeId":
                    float(b.get("parentShapeId") or 0.0),
                "shapePosition":
                    tuple(b.get("shapePosition") or (0.0, 0.0, 0.0))[:3],
                "shapeRotation":
                    tuple(b.get("shapeRotation") or (0.0, 0.0, 0.0))[:3],
                "shapeScale":
                    tuple(b.get("shapeScale") or (0.0, 0.0, 0.0))[:3],
            })
            if snap_tick is not None and tick == snap_tick:
                snap_holder["wall"] = tuple(
                    tuple(float(x) for x in s.vars.get(
                        gids[i], (0.0, 0.0, 0.0, 0.0))[:4])
                    for i in range(SW * SW)) if gids else None
            if snap3_tick is not None and tick == snap3_tick:
                snap_holder["wall3"] = tuple(
                    tuple(float(x) for x in s.vars.get(
                        gids[i], (0.0, 0.0, 0.0, 0.0))[:4])
                    for i in range(SW * SW)) if gids else None
            if snap_tick2 is not None and tick == snap_tick2:
                snap_holder["wall2"] = tuple(
                    tuple(float(x) for x in s.vars.get(
                        gids[i], (0.0, 0.0, 0.0, 0.0))[:4])
                    for i in range(SW * SW)) if gids else None

        # gids must exist before hook2 snapshots; collect them first
        gids = {}
        for nid, nd in ssim.nodes.items():
            lb = _extract(nd.props.get("_label", ("raw", "")))
            if isinstance(lb, str) and lb.startswith("g") and lb[1:].isdigit():
                gids[int(lb[1:])] = nid
        ssim.run(TICKS, on_tick=hook2)
        got = []
        for i in range(SW * SW):
            v = ssim.vars.get(gids[i], (0.0, 0.0, 0.0, 0.0))
            got.append(tuple(float(x) for x in v[:4]))

        tri = [8.0, 8.0, 20.0, 8.0, 8.0, 20.0]
        sq = [4.0, 4.0, 12.0, 4.0, 12.0, 12.0, 4.0, 12.0]
        if snap_holder.get("wall3") is not None:
            # Root cause of the quarantined kill (fixed in irsims): the
            # sim's exec drain ran exec-class nodes queued on DATA ports,
            # so the driver's outNum(4, 0.0) after shape 2's fire re-ran
            # the push handler's staging tail with pushShape steady --
            # pending+pWire(False) staged, the stroke walk killed ~13
            # ticks after its arm.  Deterministic every run, invisible in
            # painttest (staging there always precedes its own push, and
            # bursts finish before the next stage).  The chip was never
            # at fault; the drain now gates exec bodies to exec pins.
            want3 = {p: (1.0, 0.0, 0.0, 1.0) for p in poly_pixels(sq)}
            for p in stroke_pixels([30.0, 30.0, 50.0, 30.0,
                                    30.0, 50.0]):
                want3[p] = (0.1, 0.4, 1.0, 1.0)
            moved = xf_points(sq, (8.0, 4.0), 0.0, (1.0, 1.0))
            for p in poly_pixels(moved):
                want3[p] = (0.0, 0.0, 1.0, 1.0)
            bad3 = [i for i in range(SW * SW)
                    if snap_holder["wall3"][i] != want3.get(
                        i, (0.0, 0.0, 0.0, 1.0))]
            ok &= expect(not bad3, "moved square paints through chain",
                         "%d of 4096 differ, first at %d"
                         % (len(bad3), bad3[0] if bad3 else 0))
        else:
            ok &= expect(False, "moved square paints through chain",
                         "no snapshot (only %d redraws)" % len(reds))
        if snap_holder.get("wall") is not None:
            want_tri = {p: (0.0, 1.0, 0.0, 0.5)
                        for p in poly_pixels(tri)}
            bad = [i for i in range(SW * SW)
                   if snap_holder["wall"][i] != want_tri.get(
                       i, (0.0, 0.0, 0.0, 1.0))]
            detail = [(b // 64, b % 64, snap_holder["wall"][b])
                      for b in bad]
            ok &= expect(not bad, "retained store through connector",
                         "%d of 4096 differ: %s" % (len(bad), detail))
            if snap_holder.get("wall2") is not None:
                moved = sum(
                    1 for i in range(SW * SW)
                    if snap_holder["wall"][i] != snap_holder["wall2"][i])
                print("   wall movement +95..+115: %d px" % moved)
        else:
            ok &= expect(False, "retained store through connector",
                         "no snapshot (only %d redraws)" % len(reds))
        painted = sum(1 for v in got if v[:3] != (0.0, 0.0, 0.0))
        left = [(i // 64, i % 64, got[i])
                for i in range(SW * SW) if got[i][:3] != (0.0, 0.0, 0.0)]
        rows = sorted(set(r for r, _c, _v in left))
        cols = sorted(set(c for _r, c, _v in left))
        ok &= expect(painted == 0,
                     "clear flag blacks the wall (%d px)" % painted,
                     "rows %s..%s cols %s..%s e.g. %s"
                     % (rows[:1], rows[-1:], cols[:1], cols[-1:],
                        left[:3]) if left else "")
        return ok
    finally:
        for p in dumps:
            if os.path.exists(p):
                os.unlink(p)


if __name__ == "__main__":
    sys.exit(0 if main() else 1)



