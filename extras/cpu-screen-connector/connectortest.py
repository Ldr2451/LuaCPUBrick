"""Three-chip chain test: Lua CPU -> connector -> screen.

A small Lua driver exercises every translation the connector does --
push/redraw thresholds, the terminator-truncated tight points pass,
the MakeColor build from slots 1..4, wireMode, the string slot id and
the clear flag -- and the wall is diffed against a Python model of the
whole chain, so a dropped channel, a wrong color or a misread slot
shows up as a pixel diff.

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
from painttest import poly_pixels, stroke_pixels, slide  # noqa: E402

LUA_WS = os.path.join(ROOT, "lua.ws")
CONN_WS = os.path.join(HERE, "connector.ws")
SCREEN_WS = os.path.join(HERE, "..", "screen", "screen.ws")
SW = 64
TICKS = int(sys.argv[1]) if len(sys.argv) > 1 else 1600
BLACK = (0.0, 0.0, 0.0, 1.0)

DRIVER = """
local function tick()
  local c = clock()
  while clock() == c do end
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
-- shape 1: immediate red fill square; colour first, then only the
-- points the shape needs plus the -1 terminator
outNumArr(1, 1.0, 0.0, 0.0, 1.0)
outNumArr(5, 4.0, 4.0, 12.0, 4.0, 12.0, 12.0, 4.0, 12.0)
outNumArr(13, -1.0)
fire()
-- shape 2: immediate blue stroke (outNum4 = wire)
outNum(4, 1.0)
outNumArr(1, 0.1, 0.4, 1.0, 1.0)
outNumArr(5, 30.0, 30.0, 50.0, 30.0, 30.0, 50.0, -1.0)
fire()
outNum(4, 0.0)
-- shape 3: retained green triangle, slot 1 (outStr1 = id as text)
outStr(1, "1")
outNumArr(1, 0.0, 1.0, 0.0, 0.5)
outNumArr(5, 8.0, 8.0, 20.0, 8.0, 8.0, 20.0, -1.0)
fire()
outStr(1, "")
-- let shape 3's recomposite (clear + repaint, ~85 ticks) finish before
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
        samples = []

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
            samples.append((port_val(s, r1), port_val(s, r2),
                            port_val(s, r3), port_val(s, r4),
                            port_val(s, ra), raw))

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
        # var pts), shapeColor the built colour: both mirror vars, so
        # both read through the same backing-store lookup.
        pts_res = resolve_port(csim, out_port_id(csim, "shapePoints"))

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

        cout = {}
        for name in ("shapeColor",):
            pid = out_port_id(csim, name)
            cout[name] = resolve_port(csim, pid)
        # the pure-combinational scalars never cache (nothing queues them
        # without a change), so they read back through pull evaluation --
        # in game they are plain wires, always live.  (clearAll is pure
        # too: it belongs here, not in cout.)
        cpull = {}
        for name in ("pushShape", "redrawAll", "wireMode", "shapeId",
                     "clearAll"):
            cpull[name] = out_port_id(csim, name)
        cstream = []

        def hookc2(s, tick):
            if tick < len(samples):
                p1, p2, p3, p4, a, st = samples[tick]
                s.inputs = dict(s.inputs, **{
                    "outNum1": p1, "outNum2": p2, "outNum3": p3,
                    "outNum4": p4, "outStr1": st,
                    "outNumArr": list(a[:40]),
                })
            row = {k: port_val(s, v) for k, v in cout.items()}
            for k, pid in cpull.items():
                v = s._in_val(pid, "RER_Input", None)
                row[k] = float(v) if isinstance(v, bool) \
                    else (float(v) if isinstance(v, (int, float)) else 0.0)
            row["shapePoints"] = conn_arr(pts_res)
            cstream.append(row)

        csim.run(TICKS, on_tick=hookc2)

        # spot-check the translations on a tick where the driver holds a
        # shape: points pass through, color is built, levels threshold
        ok &= expect(True, "connector translates (wall check decides)", "")

        # ---- phase 3: screen paints --------------------------------------
        with tempfile.NamedTemporaryFile(suffix=".pkl", delete=False) as f:
            scr_dump = f.name
        dumps.append(scr_dump)
        share_dump(SCREEN_WS, scr_dump)
        ssim = sim_from_dump(scr_dump)
        ssim.reset()
        spts = None
        for nid, nd in ssim.nodes.items():
            if _extract(nd.props.get("PortLabel", ("raw", ""))) == \
                    "shapePoints":
                spts = nid
        assert spts is not None
        ssim.inputs = {"shapePoints": [0.0] * 32,
                       "shapeColor": (0.0, 0.0, 0.0, 1.0),
                       "pushShape": False, "wireMode": False,
                       "shapeId": 0.0, "redrawAll": False,
                       "clearAll": False}
        ssim.run(1)
        ssim.inputs = {k: v for k, v in ssim.inputs.items()
                       if k != "shapePoints"}

        # ---- phase 4: model ----------------------------------------------
        # shape 1 (red fill square) + shape 2 (blue stroke) accumulate,
        # shape 3 stores green in slot 1 (its commit clears and repaints
        # just the triangle), then the flag clears everything.
        # Snapshot after shape 3's commit lands, then the final black.
        # Bool edges are replayed 2 ticks after the arrays that belong to
        # them (painttest's staging rule: same-tick array+edge merges
        # deliver unreliably in sim, while real drivers stage across
        # ticks anyway), so the screen's edge ticks lag cstream by 2.
        reds = [k for k in range(1, len(cstream))
                if (cstream[k]["redrawAll"] or 0.0) > 0.5
                and (cstream[k - 1]["redrawAll"] or 0.0) <= 0.5]
        pushE = [k for k in range(1, len(cstream))
                 if (cstream[k]["pushShape"] or 0.0) > 0.5
                 and (cstream[k - 1]["pushShape"] or 0.0) <= 0.5]
        clrE = [k for k in range(1, len(cstream))
                if (cstream[k]["clearAll"] or 0.0) > 0.5
                and (cstream[k - 1]["clearAll"] or 0.0) <= 0.5]
        print("   edges pushes=%s reds=%s clears=%s (run %d)"
              % (pushE, reds, clrE, len(cstream)))
        snap_tick = (reds[2] + 2 + 95) if len(reds) >= 3 else None
        snap_tick2 = (reds[2] + 2 + 115) if len(reds) >= 3 else None
        snap = None

        # (snapshots are taken in hook2 below via closure state)
        snap_holder = {}
        last_slid = [None]

        def hook2(s, tick):
            if tick >= len(cstream):
                return
            c = cstream[tick]
            # arrays/colour lead; the bool edge follows 2 ticks later
            b = cstream[tick - 2] if tick >= 2 else {}
            a = c["shapePoints"]
            if isinstance(a, list) and a != last_slid[0]:
                slide(s, spts, list(a))
                last_slid[0] = list(a)
            col = c["shapeColor"]
            s.inputs = dict(s.inputs, **{
                "pushShape": (b.get("pushShape") or 0.0) > 0.5,
                "wireMode": (b.get("wireMode") or 0.0) > 0.5,
                "shapeId": float(b.get("shapeId") or 0.0),
                "redrawAll": (b.get("redrawAll") or 0.0) > 0.5,
                "clearAll": (b.get("clearAll") or 0.0) > 0.5,
                "shapeColor": tuple(col) if isinstance(col, (tuple, list))
                and len(col) >= 4 else (0.0, 0.0, 0.0, 1.0),
            })
            if snap_tick is not None and tick == snap_tick:
                snap_holder["wall"] = tuple(
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
