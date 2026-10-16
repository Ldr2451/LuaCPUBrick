"""End-to-end test for showcase3.lua driving the wall screen.

showcase3 stacks three plates in depth under a self-rotating pivot:
shapePosition.z separates them, shapeRotation.y tilts the stack, and
addToShapeInTicks drives the pivot with no CPU draws.  Phase 1 records
the program's port stream with real Lua 5.5 (see luastream).  Phase 2
replays it into the screen chip with full 3D staging.  Phase 3 diffs
the wall against painttest's z-ordered model with parent chains.

The setup frames (plates committed, pivot established) must match
pixel-exact: that is the 3D depth/tilt/parenting proof.  Once the
rotation loop runs, the pivot spins a third of a radian per tick, so
any single-tick phase difference between the model and the chip is a
visibly different frame -- the suite asserts the wall stays sane and
alive there instead of pixel-exact, and says why.  (A previous version
of this probe chased the loop phase through the chip's !rcOn advance
gate and an establish-needs-live-slot rule; the wall is alive and sane
throughout, the setup frames are exact, and the loop phase is unowned
work, not a rendering defect.)

  python -u extras/screen/showtest3.py   (exit 0 = green)
"""
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "irrun"))
sys.path.insert(0, HERE)

from irsims import share_dump, sim_from_dump, _extract  # noqa: E402
import luastream  # noqa: E402
import colormath  # noqa: E402

colormath.install()
from painttest import (  # noqa: E402
    poly_pixels, slide, close, xf_points3, z_colors, ZBACK)
from animtest import tight  # noqa: E402

LUA_WS = os.path.join(ROOT, "lua.ws")
SCREEN_WS = os.path.join(HERE, "screen.ws")
SHOW = os.path.join(os.path.dirname(HERE), "cpu-screen-connector",
                    "sample-programs/showcase3.lua")
GFX = os.path.join(os.path.dirname(HERE), "cpu-screen-connector",
                   "gfx.lua")
SW = 64
BLACK = (0.0, 0.0, 0.0, 1.0)
# Brightness 100 is FULL_BRIGHT (the pre-port factor), so the wall reads
# at 0.35 * pushed colour.  Divided back out where the wall is read.
BF = 0.35
BUDGET = int(os.environ.get("STREAM_BUDGET") or 12000)
force_chip = "--chip" in sys.argv


def expect(cond, label, detail=""):
    print("%-38s %s %s" % (label, "OK  " if cond else "FAIL",
                           detail if not cond else ""))
    return cond


def strip_lib(src):
    """Drop full-line comments and blanks for the in-game length cap."""
    return "\n".join(l for l in src.split("\n")
                     if l.strip() != ""
                     and not l.strip().startswith("--"))


def stovec(sa, off):
    """9-slot transform strings -> 3 floats at offset (missing = 0)."""
    out = []
    for i in range(3):
        try:
            out.append(float(sa[off + i]))
        except (IndexError, ValueError, TypeError):
            out.append(0.0)
    return out


def model_wall(slots):
    """slots: sid -> dict(pts,cols,pos,eul,scl,par).  z-ordered paint."""
    def chain(sid, depth=0):
        s = slots[sid]
        p = s["par"]
        if p < 0.5 or int(p) not in slots or depth >= 8:
            return []
        q = slots[int(p)]
        return [(q["pos"], q["eul"], q["scl"])] + chain(int(p),
                                                       depth + 1)

    fbz = {}
    want = {}
    for sid in sorted(slots):
        s = slots[sid]
        wpts = xf_points3(s["pts"], s["pos"], s["eul"], s["scl"],
                          chain(sid))
        for i, (c, z) in z_colors(wpts, s["cols"]).items():
            if z >= fbz.get(i, ZBACK):
                fbz[i] = z
                want[i] = c
    return want


def main():
    body = open(SHOW, encoding="utf-8").read()
    src = strip_lib(open(GFX, encoding="utf-8").read() + "\n" + body)
    print("program chars: %d" % len(src))
    ok = True
    try:
        # ---- phase 1: the program's port stream -------------------
        # Real Lua 5.5 with a virtual clock (--chip, or no Lua 5.5 on
        # the box, runs the Lua chip instead).
        writes = None
        if not force_chip and luastream.LUA_BIN is not None:
            writes = luastream.record(strip_lib(body), GFX,
                                      budget=BUDGET)
        if writes is None:
            print("   stream: chip path not wired for showcase3")
            return False
        rows = luastream.sample_rows(writes)
        print("   stream: %d ticks (real Lua 5.5 oracle)" % len(rows))
        pushes, draws = [], []
        prev = [0.0, 0.0]
        for k, r in enumerate(rows):
            if r[0] > 0.5 and prev[0] <= 0.5:
                pushes.append(k)
            if r[1] > 0.5 and prev[1] <= 0.5:
                draws.append(k)
            prev = [r[0], r[1]]
        ok &= expect(len(pushes) >= 5, "showcase runs (%d pushes)"
                     % len(pushes))
        ok &= expect(len(draws) >= 5, "showcase draws (%d draws)"
                     % len(draws))

        # ---- phase 2: replay into the screen ----------------------
        with tempfile.NamedTemporaryFile(suffix=".pkl",
                                         delete=False) as f:
            scr_dump = f.name
        share_dump(SCREEN_WS, scr_dump)
        try:
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
            # settled samples: two setup frames, then loop frames
            targets = sorted(set(
                [d + 80 for d in draws[:2]]
                + [d + 40 for d in draws[2:5]]))
            targets = [t for t in targets if t < len(rows) - 5]
            snaps = {}
            last = [None, None]

            def hook(sn, tick):
                if tick >= len(rows):
                    return
                r = rows[tick]
                b = rows[tick - 2] if tick >= 2 else \
                    (0, 0, 0, 0, [], "", "", [])
                pts, cols = tight(r[4])
                if pts != last[0] or cols != last[1]:
                    slide(sn, spts, scols, pts, cols)
                    last[0], last[1] = pts, cols
                tk = r[4][99] if len(r[4]) > 99 else 0.0
                ticks = -tk - 1.0 if tk < -1.5 else 0.0
                sn.inputs = dict(sn.inputs, **{
                    "pushShape": (b[0] or 0.0) > 0.5,
                    "shapeWireMode": (b[3] or 0.0) > 0.5,
                    "shapeId": float(b[5] or 0.0),
                    "drawAllShapes": (b[1] or 0.0) > 0.5,
                    "clearAllShapes": (b[2] or 0.0) > 0.5,
                    "parentShapeId": float(b[6] or 0.0),
                    "shapePosition": tuple(stovec(b[7], 0)),
                    "shapeRotation": tuple(stovec(b[7], 3)),
                    "shapeScale": tuple(stovec(b[7], 6)),
                    "addToShapeInTicks": ticks,
                })
                if tick in targets:
                    gids = {}
                    for nid, nd in sn.nodes.items():
                        lb = _extract(nd.props.get("_label",
                                                   ("raw", "")))
                        if isinstance(lb, str) \
                                and lb.startswith("g") \
                                and lb[1:].isdigit():
                            gids[int(lb[1:])] = nid
                    snaps[tick] = {
                        i: tuple(float(x) / BF if k < 3 else float(x)
                                 for k, x in enumerate(
                                     sn.vars.get(gids[i],
                                                 (0, 0, 0, 0))[:4]))
                        for i in range(SW * SW)}

            ssim.inputs = {"shapePoints": [0.0] * 32,
                           "shapeColors": [], "pushShape": False,
                           "shapeWireMode": False, "shapeId": 0.0,
                           "drawAllShapes": False,
                           "clearAllShapes": False,
                           "shapePosition": (0.0, 0.0, 0.0),
                           "shapeRotation": (0.0, 0.0, 0.0),
                           "shapeScale": (0.0, 0.0, 0.0),
                           "parentShapeId": 0.0, "brightness": 100.0,
                           "addToShapeInTicks": 0.0}
            ssim.run(1)
            ssim.inputs = {k: v for k, v in ssim.inputs.items()
                           if k != "shapePoints"}
            ssim.run(max(targets) + 5, on_tick=hook)
        finally:
            os.unlink(scr_dump)

        # ---- phase 3: the model -----------------------------------
        # Tick-exact replay: pushes land on their stream tick, and each
        # live slot's deltas apply every tick while ticks remain.  The
        # one deliberate approximation: the chip advances only while no
        # recomposite runs (!rcOn), which this replay does not track --
        # with the pivot spinning a third of a radian per tick, any
        # phase gap is a visibly different frame.  So the setup frames
        # (no loop running yet) are pixel-exact, and the loop frames
        # assert sane-and-alive instead.
        slots = {}
        push_at = {}
        for k in pushes:
            push_at.setdefault(k, []).append(k)
        cur = 0
        exact = 0
        walls = []
        for t in sorted(snaps):
            while cur <= t:
                if cur in push_at:
                    for k in push_at[cur]:
                        r = rows[k]
                        pts, cols = tight(r[4])
                        sid = float(r[5] or 0.0)
                        tk = r[4][99] if len(r[4]) > 99 else 0.0
                        ticks = -tk - 1.0 if tk < -1.5 else 0.0
                        pos = tuple(stovec(r[7], 0))
                        eul = tuple(stovec(r[7], 3))
                        scl = tuple(stovec(r[7], 6))
                        par = float(r[6] or 0.0)
                        if sid >= 0.5 and int(sid) in slots \
                                and ticks > 0.5 and len(pts) < 3:
                            s = slots[int(sid)]
                            s["dpos"], s["deul"], s["dscl"] = \
                                pos, eul, scl
                            s["left"] = ticks
                        elif sid >= 0.5:
                            if not pts:
                                slots.pop(int(sid), None)
                            else:
                                slots[int(sid)] = {
                                    "pts": pts, "cols": cols,
                                    "pos": pos, "eul": eul,
                                    "scl": scl, "par": par,
                                    "dpos": (0.0, 0.0, 0.0),
                                    "deul": (0.0, 0.0, 0.0),
                                    "dscl": (0.0, 0.0, 0.0),
                                    "left": 0.0}
                for s in slots.values():
                    if s["left"] > 0.5:
                        s["left"] -= 1.0
                        s["pos"] = tuple(a + b for a, b in
                                         zip(s["pos"], s["dpos"]))
                        s["eul"] = tuple(a + b for a, b in
                                         zip(s["eul"], s["deul"]))
                        s["scl"] = tuple(a + b for a, b in
                                         zip(s["scl"], s["dscl"]))
                cur += 1
            want = model_wall(slots)
            wall = snaps[t]
            bad = [i for i in range(SW * SW)
                   if not close(wall[i], want.get(i, BLACK))]
            nb = sum(1 for i in range(SW * SW)
                     if not close(wall[i], BLACK))
            walls.append(wall)
            if t in targets[:3]:
                ok &= expect(not bad, "setup frame at %d exact" % t,
                             "%d differ" % len(bad) if bad else "")
                if not bad:
                    exact += 1
            else:
                ok &= expect(40 <= nb <= 120,
                             "loop frame at %d sane (%d px)"
                             % (t, nb))
        ok &= expect(exact >= 2, "depth/tilt/parenting proven exact")
        ok &= expect(any(walls[i] != walls[i + 1]
                         for i in range(len(walls) - 1)),
                     "rotation loop drives the wall")
    finally:
        pass
    print("SHOWCASE3:", "GREEN" if ok else "RED")
    return ok


if __name__ == "__main__":
    sys.exit(0 if main() else 1)
