"""End-to-end test for anim.lua driving the wall screen.

The game wiring this program was written for is:
  outNum1   -> pushRect
  outNum2   -> redrawAll
  outNumArr -> x0, y0, x1, y1, r, g, b, a (elements 1..8)

So the test builds exactly that wiring in the sim.  Phase 1 runs the
Lua chip and samples outNum1/outNum2/outNumArr every tick.  Phase 2
replays that stream into the screen chip, pulsing the ports the same
way the Lua chip does.  Phase 3 compares the wall against a Python
model of the screen protocol (latch on push, paint on redraw, 64 px a
tick), so a lost edge, a torn latch, a wrong color or a burst abandoned
mid-flight all show up as a pixel diff.

  python -u extras/screen/animtest.py   (exit 0 = green)
"""
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "irrun"))

from irsims import share_dump, sim_from_dump, _extract  # noqa: E402

LUA_WS = os.path.join(ROOT, "lua.ws")
SCREEN_WS = os.path.join(HERE, "screen.ws")
ANIM = os.path.join(HERE, "anim.lua")
SW = 64
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
        pid_arr = out_port_id(lsim, "outNumArr")
        r_push = resolve_port(lsim, pid_push)
        r_red = resolve_port(lsim, pid_red)
        r_arr = resolve_port(lsim, pid_arr)

        samples = []

        def hook(s, tick):
            samples.append((
                port_val(s, r_push),
                port_val(s, r_red),
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
        pushes, reds, latched = [], [], []
        prev_p = prev_r = 0.0
        for k, (p, r, a) in enumerate(samples):
            if p > 0.5 and prev_p <= 0.5:
                pushes.append(k)
                latched.append((a[0], a[1], a[2], a[3],
                                tuple(a[4:8])))
            if r > 0.5 and prev_r <= 0.5:
                reds.append(k)
            prev_p, prev_r = p, r

        ok &= expect(len(pushes) >= 6,
                     "animation draws (%d rects seen)" % len(latched))
        if pushes:
            print("   boot: first rect at tick %d (%ds of 100Hz sim), "
                  "%d ticks/frame"
                  % (pushes[0], pushes[0] // 100,
                     (pushes[-1] - pushes[0]) // max(1, len(pushes) - 1)))
        # each rect is pushed then redrawn, and the redraw comes before the
        # next push -- that is what keeps a burst from being abandoned
        seq_ok = all(pushes[i] < reds[i] < pushes[i + 1]
                     for i in range(min(len(reds), len(pushes)) - 1))
        ok &= expect(seq_ok, "push-then-redraw ordering")
        # no redraw may fire while the previous burst could still be
        # running: a 1-tick rect burst finishes 2 ticks after its redraw
        gap_ok = all(reds[i + 1] - reds[i] >= 3 for i in range(len(reds) - 1))
        ok &= expect(gap_ok, "redraws spaced past burst time")
        colors_ok = all(0.0 <= c <= 1.0 for x0, y0, x1, y1, c in latched
                        for c in c)
        ok &= expect(colors_ok, "colors in 0..1")
        bounds_ok = all(x1 - x0 >= 1.0 and y1 - y0 >= 1.0
                        for x0, y0, x1, y1, c in latched)
        ok &= expect(bounds_ok, "rect bounds non-degenerate")

        # ---- phase 2: replay into the screen chip -----------------------
        with tempfile.NamedTemporaryFile(suffix=".pkl", delete=False) as f:
            scr_dump = f.name
        dumps.append(scr_dump)
        share_dump(SCREEN_WS, scr_dump)
        ssim = sim_from_dump(scr_dump)
        ssim.reset()
        ssim.inputs = {"rectColor": (0.0, 0.0, 0.0, 1.0),
                       "rectX0": 0.0, "rectY0": 0.0,
                       "rectX1": 0.0, "rectY1": 0.0,
                       "pushRect": False, "redrawAll": False}

        def hook2(s, tick):
            if tick >= len(samples):
                return
            p, r, a = samples[tick]
            if len(a) < 8:
                return
            s.inputs = dict(s.inputs, **{
                "pushRect": p > 0.5,
                "redrawAll": r > 0.5,
                "rectX0": a[0], "rectY0": a[1],
                "rectX1": a[2], "rectY1": a[3],
                "rectColor": tuple(a[4:8]),
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
        fb = [(0.0, 0.0, 0.0, 1.0)] * (SW * SW)
        for x0, y0, x1, y1, c in latched:
            ax0, ax1 = (x0, x1) if x0 <= x1 else (x1, x0)
            ay0, ay1 = (y0, y1) if y0 <= y1 else (y1, y0)
            c0 = 0.0 if ax0 < 0.0 else (63.0 if ax0 >= 64.0 else ax0)
            c1 = 0.0 if ax1 < 0.0 else (63.0 if ax1 >= 64.0 else ax1)
            r0 = 0.0 if ay0 < 0.0 else (63.0 if ay0 >= 64.0 else ay0)
            r1 = 0.0 if ay1 < 0.0 else (63.0 if ay1 >= 64.0 else ay1)
            rw = c1 - c0 + 1.0
            area = rw * (r1 - r0 + 1.0)
            tt = 0.0
            while tt < area:
                qd = float(int(tt / rw))
                ridx = int((r0 + qd) * 64.0 + c0 + (tt - qd * rw))
                if 0 <= ridx < SW * SW:
                    fb[ridx] = c
                tt += 1.0

        diff = [i for i in range(SW * SW) if got[i] != fb[i]]
        ok &= expect(not diff, "wall matches the protocol model",
                     "%d pixels differ, first at %d" % (len(diff), diff[0])
                     if diff else "")
        painted = sum(1 for i in range(SW * SW) if got[i][:3] != (0.0, 0.0, 0.0))
        ok &= expect(painted > 20, "screen has content (%d px painted)" % painted)

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
