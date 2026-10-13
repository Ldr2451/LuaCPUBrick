"""End-to-end test for anim.lua driving the wall screen.

The game wiring this program was written for is (via the connector):
  outNum1   -> pushShape
  outNum2   -> drawAll
  outNum3   -> clearAll
  outNumArr -> only the points the shape needs (1..) plus one -1
               terminator, then optional colours (four per point);
               the connector truncates there and defaults missing
               colours to white
(wireMode and shapeId stay at their defaults: immediate fills.)

So the test builds exactly that wiring in the sim.  Phase 1 runs the
Lua chip and samples outNum1/outNum2/outNum3/outNumArr every tick.
Phase 2 replays that stream into the screen chip, pulsing the ports
the same way the Lua chip does (the array is delivered by replacing
the port's list, the same wire event the game delivers, not the
sim's slow input path).  Phase 3 compares the wall against a Python
model of the screen protocol, so a lost edge, a torn latch or a
burst abandoned mid-flight all show up as a pixel diff.  The model
mirrors the new clearAll semantics: the pulse only forgets, and the
drawAll right after it is what blacks the wall.

The sim's math gates are float-only, so colour arithmetic reads as
0.0 there; colormath.install() patches them to the documented
channel-wise LinearColor semantics (test-side only).

  python -u extras/screen/animtest.py [ticks]   (exit 0 = green)
"""
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "irrun"))
sys.path.insert(0, HERE)

from irsims import share_dump, sim_from_dump, _extract  # noqa: E402
import colormath  # noqa: E402

colormath.install()
from painttest import poly_pixels, poly_colors, slide  # noqa: E402

LUA_WS = os.path.join(ROOT, "lua.ws")
SCREEN_WS = os.path.join(HERE, "screen.ws")
ANIM = os.path.join(HERE, "anim.lua")
SW = 64
WHITE = (1.0, 1.0, 1.0, 1.0)
TICKS = int(sys.argv[1]) if len(sys.argv) > 1 else 3600


def out_port_id(sim, name):
    for w in sim.wires:
        dn = sim.nodes.get(w.dst_id)
        if not dn or dn.kind != "Output":
            continue
        if _extract(dn.props.get("PortLabel", ("raw", ""))) == name:
            return w.dst_id
    raise RuntimeError("no output port %r" % name)


def resolve_port(sim, pid):
    """Map an output port to the var/array holding its live value.

    _in_val only answers on the tick a source publishes, so sticky ports
    (the exact thing this animation needs) read back empty every other
    tick.  Resolving the wiring once and reading sim.vars / sim.arrays
    directly sees the written value until the next write.
    """
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
    return float(v) if isinstance(v, (int, float)) else 0.0


def tight(a):
    """The connector's truncation and colour split, mirrored: points
    from slot 1 on, the first x <= -0.5 ends the list (at most 16
    points) and its magnitude minus one is the colour count, then
    four floats per point as that point's colour -- white where the
    driver sent none."""
    pts = []
    term = -1.0
    for i in range(16):
        x = a[2 * i] if len(a) > 2 * i else -1.0
        if x < -0.5:
            term = x
            break
        y = a[2 * i + 1] if len(a) > 2 * i + 1 else 0.0
        pts += [x, y]
    n = len(pts) // 2
    kc = max(0, min(16, int(-term) - 1)) if term <= -1.0 else 16
    cols = []
    for i in range(n):
        b = 2 * n + 1 + 4 * i
        if i < kc and len(a) > b + 3:
            cols.append(tuple(float(v) for v in a[b:b + 4]))
        else:
            cols.append(WHITE)
    return pts, cols


def expect(cond, label, detail=""):
    print("%-38s %s %s" % (label, "OK  " if cond else "FAIL",
                           detail if not cond else ""))
    return cond


def main():
    src = open(ANIM, encoding="utf-8").read()
    dumps = []
    ok = True
    try:
        # ---- phase 1: run the animation on the Lua chip ----------------
        with tempfile.NamedTemporaryFile(suffix=".pkl", delete=False) as f:
            lua_dump = f.name
        dumps.append(lua_dump)
        share_dump(LUA_WS, lua_dump)
        lsim = sim_from_dump(lua_dump)
        pid_push = out_port_id(lsim, "outNum1")
        pid_red = out_port_id(lsim, "outNum2")
        pid_clr = out_port_id(lsim, "outNum3")
        pid_arr = out_port_id(lsim, "outNumArr")
        r_push = resolve_port(lsim, pid_push)
        r_red = resolve_port(lsim, pid_red)
        r_clr = resolve_port(lsim, pid_clr)
        r_arr = resolve_port(lsim, pid_arr)

        samples = []

        def hook(s, tick):
            samples.append((
                port_val(s, r_push),
                port_val(s, r_red),
                port_val(s, r_clr),
                port_val(s, r_arr),
            ))

        lsim.reset()
        lsim.inputs = {"program": src, "run": True}
        lsim.run(TICKS, on_tick=hook)

        og = lsim.capture()["outGlobals"]
        dbg = og.get("progDebug") or ""
        ok &= expect(not og.get("runErrors"),
                     "animation runs without errors", str(og.get("runErrors")))
        ok &= expect(not any(l.startswith("err:") for l in dbg.splitlines()),
                     "animation compiles clean", str(dbg))

        # ---- parse the stream ------------------------------------------
        pushes, reds, clears, latched = [], [], [], []
        prev_p = prev_r = prev_c = 0.0
        for k, (p, r, c, a) in enumerate(samples):
            if p > 0.5 and prev_p <= 0.5:
                pushes.append(k)
                latched.append(tight(a))
            if r > 0.5 and prev_r <= 0.5:
                reds.append(k)
            if c > 0.5 and prev_c <= 0.5:
                clears.append(k)
            prev_p, prev_r, prev_c = p, r, c

        ok &= expect(len(pushes) >= 4,
                     "animation draws (%d shapes seen)" % len(latched))
        if pushes:
            print("   boot: first shape at tick %d (%ds of 100Hz sim), "
                  "%d ticks/frame"
                  % (pushes[0], pushes[0] // 100,
                     (pushes[-1] - pushes[0]) // max(1, len(pushes) - 1)))
        # each shape is pushed then redrawn, and the redraw comes before
        # the next push -- that is what keeps a burst from being abandoned
        seq_ok = all(pushes[i] < reds[i] < pushes[i + 1]
                     for i in range(min(len(reds), len(pushes)) - 1))
        ok &= expect(seq_ok, "push-then-redraw ordering")
        # no redraw may fire while the previous burst could still be
        # running: pair each redraw with its shape and require the gap to
        # cover that shape's rows (a polygon burst is one tick per row)
        def shape_rows(pts):
            px = poly_pixels(pts)
            return (max((p // SW for p in px), default=0) -
                    min((p // SW for p in px), default=0) + 1) if px else 1

        gap_ok = True
        for i in range(len(reds) - 1):
            shapes_before = [j for j, t in enumerate(pushes) if t < reds[i]]
            if not shapes_before:
                continue
            rows = shape_rows(latched[shapes_before[-1]][0])
            if reds[i + 1] - reds[i] < rows + 4:
                gap_ok = False
        ok &= expect(gap_ok, "redraws spaced past burst time")
        colors_ok = all(0.0 <= v <= 1.0
                        for _pts, cols in latched
                        for col in cols for v in col)
        ok &= expect(colors_ok, "colors in 0..1")
        # every clearAll pulse is followed by a drawAll (the pulse that
        # runs the deferred black fill)
        pair_ok = all(c < reds[-1] for c in clears) if clears else True
        ok &= expect(pair_ok, "clearAll pulses land before a drawAll",
                     "clears=%s reds=%s" % (clears[:6], reds[:6]))

        # ---- phase 2: replay into the screen chip -----------------------
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
        assert spts is not None, "no shapePoints port"
        assert scols is not None, "no shapeColors port"
        ssim.inputs = {"shapePoints": [0.0] * 32,
                       "shapeColors": [],
                       "pushShape": False, "wireMode": False,
                       "shapeId": 0.0, "drawAll": False,
                       "clearAll": False, "position": (0.0, 0.0, 0.0), "rotation": (0.0, 0.0, 0.0), "scale": (0.0, 0.0, 0.0), "parentShapeId": 0.0, "brightness": 100.0}
        ssim.run(1)
        ssim.inputs = {k: v for k, v in ssim.inputs.items()
                       if k != "shapePoints"}

        def hook2(s, tick):
            if tick >= len(samples):
                return
            p, r, c, a = samples[tick]
            pts, cols = tight(a)
            if len(pts) >= 2:
                slide(s, spts, scols, pts, cols)
            s.inputs = dict(s.inputs, **{
                "pushShape": p > 0.5,
                "drawAll": r > 0.5,
                "clearAll": c > 0.5,
            })

        ssim.run(TICKS, on_tick=hook2)

        gids = {}
        for nid, nd in ssim.nodes.items():
            lb = _extract(nd.props.get("_label", ("raw", "")))
            if isinstance(lb, str) and lb.startswith("g") and lb[1:].isdigit():
                gids[int(lb[1:])] = nid
        if len(gids) != SW * SW:
            print("FAIL globals found: %d" % len(gids))
            return False
        got = []
        for i in range(SW * SW):
            v = ssim.vars.get(gids[i], (0.0, 0.0, 0.0, 0.0))
            got.append(tuple(float(x) for x in v[:4]))

        # ---- phase 3: model of the protocol ----------------------------
        # Immediate mode: each drawAll paints the pushed shape.  A
        # clearAll pulse only forgets -- the drawAll right after it is
        # what blacks the wall -- so the model clears there.
        fb = {}
        li = 0
        clear_pending = False
        prev_p = prev_r = prev_c = 0.0
        for p, r, c, a in samples:
            if r > 0.5 and prev_r <= 0.5:
                if clear_pending:
                    fb = {}
                    clear_pending = False
                elif li < len(latched):
                    pts, cols = latched[li]
                    for q, colr in poly_colors(pts, cols).items():
                        fb[q] = colr
                    li += 1
            if c > 0.5 and prev_c <= 0.5:
                clear_pending = True
            prev_p, prev_r, prev_c = p, r, c
        bad = [i for i in range(SW * SW)
               if got[i] != fb.get(i, (0.0, 0.0, 0.0, 1.0))]
        ok &= expect(not bad, "wall matches the protocol model",
                     "%d pixels differ, first at %d" % (len(bad), bad[0])
                     if bad else "")
        painted = sum(1 for i in range(SW * SW)
                      if got[i][:3] != (0.0, 0.0, 0.0))
        ok &= expect(painted > 20, "screen has content (%d px painted)"
                     % painted)

        # ---- what it looks like, in ASCII --------------------------------
        print("\nframe at tick %d (%ds of 100Hz sim):" % (TICKS, TICKS // 100))
        ramp = " .:-=+*#%@"
        for y in range(0, 64, 2):
            row = []
            for x in range(0, 64, 2):
                v = got[(y + 1) * 64 + x + 1]
                lum = (v[0] + v[1] + v[2]) / 3.0
                row.append(ramp[min(9, int(lum * 9.999))])
            print("   " + "".join(row))
        print()
        return ok
    finally:
        for p in dumps:
            if os.path.exists(p):
                os.unlink(p)


if __name__ == "__main__":
    sys.exit(0 if main() else 1)
