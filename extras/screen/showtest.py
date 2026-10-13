"""End-to-end test for showcase.lua driving the wall screen.

Phase 1 runs the program on the Lua chip, sampling push/draw/clear,
wire, the id string and outNumArr every tick.  Phase 2 replays that
stream into the screen chip the way the connector would deliver it
(tight points, per-point colours, bool edges 2 ticks after their
arrays -- painttest's staging rule).  Phase 3 diffs the wall against
a Python model with retained slots and the deferred clearAll: the
pulse forgets every slot, and the drawAll right after it is the one
that blacks the wall -- so a lost edge, a torn latch, a wrong colour,
a misread id or an abandoned burst shows up as pixels, while the
coarse intent asserts (wire seen both ways, ids 1..3 plus immediate,
an empty delete, a clear pulse) catch driver-side mode mistakes the
pixel diff cannot see.

showcase.lua sends no colours (the screen defaults every point to
white), so this program stays the protocol/perf driver; the colour
feature's own end-to-end coverage lives in showtest2.py.

  python -u extras/screen/showtest.py [ticks]   (exit 0 = green)
"""
import os
import re
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "irrun"))
sys.path.insert(0, HERE)

from irsims import share_dump, sim_from_dump  # noqa: E402
import colormath  # noqa: E402

colormath.install()
from animtest import (out_port_id, resolve_port, port_val,  # noqa: E402
                      tight, expect)
from painttest import poly_colors, stroke_colors, slide  # noqa: E402

LUA_WS = os.path.join(ROOT, "lua.ws")
SCREEN_WS = os.path.join(HERE, "screen.ws")
SHOW = os.path.join(HERE, "showcase.lua")
SW = 64
TICKS = int(sys.argv[1]) if len(sys.argv) > 1 else 22000
BLACK = (0.0, 0.0, 0.0, 1.0)


def parse_id(s):
    try:
        return float(s)
    except (ValueError, TypeError):
        return 0.0


def main():
    src = open(SHOW, encoding="utf-8").read()
    dumps = []
    ok = True
    try:
        # ---- phase 1: run the showcase on the Lua chip ----------------
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
            raw = s.vars.get(rs[1], "")
            if not isinstance(raw, str):
                raw = ""
            else:
                m = re.search(r'"([^"]*)"', raw)
                raw = m.group(1) if m else raw
            samples.append((port_val(s, r1), port_val(s, r2),
                            port_val(s, r3), port_val(s, r4),
                            port_val(s, ra), raw))

        lsim.reset()
        lsim.inputs = {"program": src, "run": True}
        lsim.run(TICKS, on_tick=hook)
        og = lsim.capture()["outGlobals"]
        ok &= expect(not og.get("runErrors"), "showcase runs clean",
                     str(og.get("runErrors")))
        dbg = og.get("progDebug") or ""
        ok &= expect(not any(l.startswith("err:") for l in dbg.splitlines()),
                     "showcase compiles clean", str(dbg))

        # ---- latch the stream ----------------------------------------
        pushes, reds, clrs, latched = [], [], [], []
        prev = [0.0, 0.0, 0.0]
        for k, (p, r, c, w, a, st) in enumerate(samples):
            if p > 0.5 and prev[0] <= 0.5:
                pushes.append(k)
                pts, cols = tight(a)
                latched.append((pts, cols, w > 0.5, st))
            if r > 0.5 and prev[1] <= 0.5:
                reds.append(k)
            if c > 0.5 and prev[2] <= 0.5:
                clrs.append(k)
            prev = [p, r, c]
        print("   pushes=%d reds=%d clears=%s first push at %s" %
              (len(pushes), len(reds), clrs[:4],
               pushes[0] if pushes else None))

        # intent: every expressive channel actually used
        ok &= expect(len(pushes) >= 190, "full loop ran (%d pushes)"
                     % len(pushes))
        ok &= expect(len(reds) >= len(pushes) and all(
            pushes[i] < reds[i] for i in range(len(pushes))),
            "push-then-redraw pairing")
        wires = set(w for _p, _c, w, _s in latched)
        ok &= expect(wires == {True, False}, "fills and strokes both",
                     str(wires))
        ids = set(s for _p, _c, _w, s in latched)
        ok &= expect({"1", "2", "3"} <= ids and "" in ids,
                     "retained slots 1..3 plus immediate", str(ids))
        ok &= expect(any(len(p) == 0 and s == "2"
                         for p, _c, _w, s in latched),
                     "empty shape deletes slot 2")
        ok &= expect(len(clrs) >= 1, "clearAll pulse seen")

        # End replay and model at the last push edge: every burst before
        # it is complete (the driver's naps cover each burst by
        # construction, which the wall diff verifies), while a fixed
        # tick cutoff can land mid-burst of an infinite loop and fail
        # spuriously.  The never-redrawn last push stays pending in both.
        T_end = pushes[-1] if pushes else TICKS
        # No "bursts settled" check here: the program loops forever, so
        # any fixed run ends at an arbitrary point past some redraw.
        # The wall diff below subsumes it -- a burst cut off mid-flight
        # necessarily differs from the model, while a completed one
        # matches.

        # ---- phase 2: replay into the screen --------------------------
        with tempfile.NamedTemporaryFile(suffix=".pkl", delete=False) as f:
            scr_dump = f.name
        dumps.append(scr_dump)
        share_dump(SCREEN_WS, scr_dump)
        ssim = sim_from_dump(scr_dump)
        ssim.reset()
        from irsims import _extract as _ex
        spts = scols = None
        for nid, nd in ssim.nodes.items():
            pl = _ex(nd.props.get("PortLabel", ("raw", "")))
            if pl == "shapePoints":
                spts = nid
            elif pl == "shapeColors":
                scols = nid
        assert spts is not None and scols is not None
        ssim.inputs = {"shapePoints": [0.0] * 32,
                       "shapeColors": [],
                       "pushShape": False, "wireMode": False,
                       "shapeId": 0.0, "drawAll": False,
                       "clearAll": False, "position": (0.0, 0.0, 0.0), "rotation": (0.0, 0.0, 0.0), "scale": (0.0, 0.0, 0.0), "parentShapeId": 0.0, "brightness": 100.0}
        ssim.run(1)
        ssim.inputs = {k: v for k, v in ssim.inputs.items()
                       if k != "shapePoints"}
        last_slid = [None, None]

        def hook2(s, tick):
            if tick >= T_end:
                return
            _p, _r, _c, _w, a, st = samples[tick]
            b = samples[tick - 2] if tick >= 2 else (0, 0, 0, 0, [], "")
            pts, cols = tight(a)
            if pts != last_slid[0] or cols != last_slid[1]:
                slide(s, spts, scols, pts, cols)
                last_slid[0] = pts
                last_slid[1] = cols
            s.inputs = dict(s.inputs, **{
                "pushShape": (b[0] or 0.0) > 0.5,
                "wireMode": (b[3] or 0.0) > 0.5,
                "shapeId": parse_id(b[5]),
                "drawAll": (b[1] or 0.0) > 0.5,
                "clearAll": (b[2] or 0.0) > 0.5,
            })

        ssim.run(T_end, on_tick=hook2)
        gids = {}
        for nid, nd in ssim.nodes.items():
            lb = _ex(nd.props.get("_label", ("raw", "")))
            if isinstance(lb, str) and lb.startswith("g") and lb[1:].isdigit():
                gids[int(lb[1:])] = nid
        got = [tuple(float(x) for x in
                     ssim.vars.get(gids[i], (0, 0, 0, 0))[:4])
               for i in range(SW * SW)]

        # ---- phase 3: slot model --------------------------------------
        # The deferred clear: the pulse forgets every slot and stages
        # the black fill; the next drawAll runs it -- with a shape
        # staged that means black first, then the shape over it.
        fb = {}
        slots = {}
        pending = None
        black = False
        li = 0

        def paint(pts, cols, wire):
            model = stroke_colors(pts, cols) if wire \
                else poly_colors(pts, cols)
            fb.update(model)

        for k in range(T_end):
            p, r, c = samples[k][0], samples[k][1], samples[k][2]
            if c > 0.5 and (samples[k - 1][2] if k else 0.0) <= 0.5:
                slots = {}
                pending = None
                black = True
            if p > 0.5 and (samples[k - 1][0] if k else 0.0) <= 0.5:
                pts, cols, wire, st = latched[li]
                li += 1
                pending = (pts, cols, wire, st)
            if r > 0.5 and (samples[k - 1][1] if k else 0.0) <= 0.5:
                if black:
                    fb = {}
                    black = False
                if pending is not None:
                    pts, cols, wire, st = pending
                    sid = parse_id(st)
                    if sid < 0.5:
                        paint(pts, cols, wire)
                    else:
                        key = int(sid)
                        if not pts:
                            slots.pop(key, None)
                        else:
                            slots[key] = (pts, cols, wire)
                        fb = {}
                        for kk in sorted(slots):
                            paint(*slots[kk])
                    pending = None

        bad = [i for i in range(SW * SW)
               if got[i] != fb.get(i, BLACK)]
        ok &= expect(not bad, "wall matches the slot model",
                     "%d differ, first at %d" % (len(bad), bad[0])
                     if bad else "")
        if bad:
            wall_only = [i for i in bad if got[i][:3] != (0.0, 0.0, 0.0)]
            model_only = [i for i in bad if got[i][:3] == (0.0, 0.0, 0.0)]

            def bbox(idxs):
                rs = [i // SW for i in idxs]
                cs = [i % SW for i in idxs]
                return (min(rs), max(rs), min(cs), max(cs))

            print("   wall-only %d %s  model-only %d %s" %
                  (len(wall_only), bbox(wall_only) if wall_only else None,
                   len(model_only),
                   bbox(model_only) if model_only else None))
            # which latched shapes overlap the model-only region?
            mo = set(model_only)
            scored = []
            for li2, (pts, cols, wire, st) in enumerate(latched):
                px = (set(stroke_colors(pts, cols)) if wire
                      else set(poly_colors(pts, cols))) & mo
                if px:
                    scored.append((len(px), li2, wire, st, len(pts) // 2))
            scored.sort(reverse=True)
            print("   top overlapping latched shapes "
                  "(overlap, idx, wire, id, npts): %s" % scored[:6])
        painted = sum(1 for v in got if v[:3] != (0.0, 0.0, 0.0))
        print("   painted px: %d  model px: %d" %
              (painted, len(fb)))
        return ok
    finally:
        for p in dumps:
            if os.path.exists(p):
                os.unlink(p)


if __name__ == "__main__":
    sys.exit(0 if main() else 1)
