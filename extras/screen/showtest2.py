"""End-to-end test for showcase2.lua driving the wall screen.

Phase 1 runs the program on the Lua chip, sampling push/draw/clear,
wire, the id string and outNumArr every tick.  Phase 2 replays that
stream into the screen chip the way the connector would deliver it
(tight points plus the per-point colours, bool edges 2 ticks after
their arrays -- painttest's staging rule).  Phase 3 diffs the wall
against a Python model with retained slots and the new clearAll
semantics: the pulse only forgets the slots, and the drawAll right
after it is what blacks the wall -- so a composed image never cuts
to black before its first commit lands.

  python -u extras/screen/showtest2.py [ticks]   (exit 0 = green)
"""
import os
import re
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "irrun"))
sys.path.insert(0, HERE)

from irsims import share_dump, sim_from_dump, _extract  # noqa: E402
import colormath  # noqa: E402

colormath.install()
from animtest import out_port_id, resolve_port, port_val, tight  # noqa: E402
from painttest import (poly_colors, stroke_colors, slide,  # noqa: E402
                       expect)

LUA_WS = os.path.join(ROOT, "lua.ws")
SCREEN_WS = os.path.join(HERE, "screen.ws")
SHOW = os.path.join(HERE, "showcase2.lua")
SW = 64
TICKS = int(sys.argv[1]) if len(sys.argv) > 1 else 15000
BLACK = (0.0, 0.0, 0.0, 1.0)


def parse_id(s):
    try:
        return float(s)
    except (ValueError, TypeError):
        return 0.0


def close(a, b, tol=1e-9):
    return len(a) == len(b) and all(
        abs(float(x) - float(y)) <= tol for x, y in zip(a, b))


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
        ok &= expect(len(pushes) >= 20,
                     "phases ran (%d pushes)" % len(pushes))
        ok &= expect(len(reds) >= len(pushes) - 1 and all(
            pushes[i] < reds[i]
            for i in range(min(len(reds), len(pushes)))),
            "push-then-draw pairing")
        ids = set(s for _p, _c, _w, s in latched)
        ok &= expect({"1", "2", "3"} <= ids,
                     "retained slots 1..3 all used", str(ids))
        deletes = [i for i, (p, _c, _w, s) in enumerate(latched)
                   if len(p) == 0 and s == "3"]
        ok &= expect(len(deletes) >= 2,
                     "empty shape deletes slot 3 (%d times)"
                     % len(deletes))
        ok &= expect(len(clrs) >= 1, "clearAll pulse seen")
        # colours: at least half the shapes carry a real gradient
        coloured = [pc for pts, cols, _w, _s in latched
                    for pc in [cols] if len(pts) >= 6
                    and any(not close(c, (1.0, 1.0, 1.0, 1.0))
                            for c in cols)]
        ok &= expect(len(coloured) >= 10,
                     "per-point colours drive the wall (%d shapes)"
                     % len(coloured))
        alphas = set()
        for _pts, cols, _w, _s in latched:
            for c in cols:
                alphas.add(round(c[3], 3))
        ok &= expect(any(a < 0.9 for a in alphas),
                     "translucency present (alphas %s)"
                     % sorted(alphas))

        # End replay and model at the last push edge (showtest's
        # boundary rule): every earlier burst is complete by the
        # driver's pacing, which the wall diff verifies.
        T_end = pushes[-1] if pushes else TICKS

        # ---- phase 2: replay into the screen --------------------------
        with tempfile.NamedTemporaryFile(suffix=".pkl", delete=False) as f:
            scr_dump = f.name
        dumps.append(scr_dump)
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
            # the driver writes the points and the colours in separate
            # outNumArr calls, so they land on different ticks: re-slide
            # when either half changes, or the shape paints with the
            # previous frame's colours
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
            lb = _extract(nd.props.get("_label", ("raw", "")))
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
        snaps = []

        def paint(pts, cols, wire):
            model = stroke_colors(pts, cols) if wire \
                else poly_colors(pts, cols)
            fb.update(model)

        for k in range(T_end):
            p, r, c, _w, _a, _st = samples[k][:6]
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
                snaps.append((k, dict(fb)))

        bad = [i for i in range(SW * SW)
               if not close(got[i], fb.get(i, BLACK))]
        ok &= expect(not bad, "wall matches the slot model",
                     "%d differ, first at %d" % (len(bad), bad[0])
                     if bad else "")
        if bad:
            print("   wall %r vs model %r at %d"
                  % (got[bad[0]], fb.get(bad[0]), bad[0]))
            # which burst does the wall actually reflect?  Compare against
            # every snapshot the model took at a drawAll edge.
            scored = []
            for k, snap in snaps:
                d = sum(1 for i in range(SW * SW)
                        if not close(got[i], snap.get(i, BLACK)))
                scored.append((d, k))
            scored.sort()
            print("   closest snapshots (differ, tick): %s"
                  % [(d, k) for d, k in scored[:4]])
            print("   last snapshots (tick, painted): %s"
                  % [(k, len(s)) for k, s in snaps[-4:]])
        painted = sum(1 for v in got if not close(v, BLACK))
        print("   painted px: %d  model px: %d" % (painted, len(fb)))
        return ok
    finally:
        for p in dumps:
            if os.path.exists(p):
                os.unlink(p)


if __name__ == "__main__":
    sys.exit(0 if main() else 1)

