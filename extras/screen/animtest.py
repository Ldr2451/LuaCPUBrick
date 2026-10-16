"""End-to-end test for anim.lua driving the wall screen.

The game wiring this program was written for is (via the connector):
  outNum1   -> pushShape
  outNum2   -> drawAllShapes
  outNum3   -> clearAllShapes
  outNumArr -> only the points the shape needs (1..) plus one -1
               terminator, then optional colours (four per point);
               the connector truncates there and defaults missing
               colours to white
(shapeWireMode and shapeId stay at their defaults: immediate fills.)

So the test builds exactly that wiring in the sim.  Phase 1 runs the
Lua chip and samples outNum1/outNum2/outNum3/outNumArr every tick.
Phase 2 replays that stream into the screen chip, pulsing the ports
the same way the Lua chip does (the array is delivered by replacing
the port's list, the same wire event the game delivers, not the
sim's slow input path).  Phase 3 compares the wall against a Python
model of the screen protocol, so a lost edge, a torn latch or a
burst abandoned mid-flight all show up as a pixel diff.  The model
mirrors the new clearAllShapes semantics: the pulse only forgets, and the
drawAllShapes right after it is what blacks the wall.

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
import luastream  # noqa: E402
import colormath  # noqa: E402

colormath.install()
from painttest import poly_pixels, poly_colors, slide, close  # noqa: E402

LUA_WS = os.path.join(ROOT, "lua.ws")
SCREEN_WS = os.path.join(HERE, "screen.ws")
ANIM = os.path.join(HERE, "anim.lua")
GFX = os.path.join(os.path.dirname(HERE), "cpu-screen-connector", "gfx.lua")
SW = 64
WHITE = (1.0, 1.0, 1.0, 1.0)
# Brightness 100 is FULL_BRIGHT (the pre-port factor), so the wall reads
# at 0.35 * pushed colour.  Divided back out where the wall is read, so
# the model below keeps comparing a pushed colour against the wall.
BF = 0.35
TICKS = int(sys.argv[1]) if len(sys.argv) > 1 else 9000
# Virtual-tick budget for the real-Lua stream.  The checks below name
# four shapes and a well-spaced redraw, and the program paces itself
# ~300 ticks a frame, so 3000 gives ~45 frames -- an order of magnitude
# more than the checks need, while keeping the screen replay (the only
# expensive part left) short.
BUDGET = int(os.environ.get("STREAM_BUDGET") or 3000)
force_chip = "--chip" in sys.argv


def lua_stream(src, gfx_path, budget, force_chip=False):
    """The program's port stream: real Lua 5.5 when it is on the box.

    Returns per-tick rows, or None to tell the caller to run the chip.
    --chip forces the chip, and a box with no Lua 5.5 falls back to it,
    so the suite never silently depends on the oracle being installed.
    """
    if force_chip or luastream.LUA_BIN is None:
        return None
    return luastream.sample_rows(
        luastream.record(src, gfx_path, budget=budget), cols=4)


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


def port_slice(sim, res, n=128):
    """port_val, but array ports are truncated to n slots: drivers never
    write past ~100 (16 points + terminator + 16 colours), and the full
    16k copy every tick dominates phase-1 wall time."""
    kind, sid = res
    if kind == "arr":
        v = sim.arrays.get(sid)
        return list(v[:n]) if v is not None else []
    return port_val(sim, res)


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


def strip_lib(src):
    """Drop full-line comments and blanks for the in-game length cap."""
    return "\n".join(l for l in src.split("\n")
                     if l.strip() != ""
                     and not l.strip().startswith("--"))


class Stream:
    """A port sampler that stops paying for the dead parse head.

    The Lua chip takes ~1 char/tick to parse the program (measured:
    3861 chars -> parse end at tick 4029), so the first few thousand
    ticks of phase 1 carry nothing.  Sampling the 128-slot arrays
    through them costs a fresh list per tick for all-zero values.

    A short ring holds the lookback the edge logic needs; full sampling
    starts at the first live edge, which is also the first tick the
    128-slot array is read.  `samples` then indexes exactly like the
    old list -- index k is tick k + head.
    """

    def __init__(self, look=256):
        self.look = look
        self.out = []
        self.ring = []
        self.head = 0

    def push(self, sample, live):
        if self.out:
            self.out.append(sample)
            return
        self.ring.append(sample)
        if len(self.ring) > self.look:
            self.head += 1
            self.ring.pop(0)
        if live:
            self.out = self.ring
            self.ring = []

    def __len__(self):
        return len(self.out)

    def __getitem__(self, k):
        return self.out[k]

    def __iter__(self):
        return iter(self.out)


def main():
    body = open(ANIM, encoding="utf-8").read()
    # the animation body calls the gfx library: prepend it, stripped
    # (see showtest).  `body` stays lib-free: the oracle prepends the
    # library itself, so handing it the assembled program would load
    # the library twice and its busy-wait tick would win over the
    # harness's virtual one.
    src = strip_lib(open(GFX, encoding="utf-8").read() + "\n" + body)
    print("program chars: %d" % len(src))
    dumps = []
    ok = True
    try:
        # ---- phase 1: the program's port stream -----------------------
        # Real Lua 5.5 with a virtual clock, so the several thousand
        # ticks the chip would spend parsing the program are never
        # simulated.  --chip (or no Lua 5.5 on the box) runs the chip.
        samples = lua_stream(body, GFX, BUDGET, force_chip=force_chip)
        if samples is not None:
            print("   stream: %d ticks (real Lua 5.5 oracle)"
                  % len(samples))
        if samples is None:
            with tempfile.NamedTemporaryFile(suffix=".pkl",
                                             delete=False) as f:
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

            samples = Stream()
            live = [False]

            def hook(s, tick):
                p = port_val(s, r_push)
                r = port_val(s, r_red)
                c = port_val(s, r_clr)
                if live[0]:
                    samples.push((p, r, c, port_slice(s, r_arr)), True)
                else:
                    samples.push((p, r, c, []), False)
                    if p > 0.5 or r > 0.5 or c > 0.5:
                        live[0] = True

            lsim.reset()
            lsim.inputs = {"program": src, "run": True}
            lsim.run(TICKS, on_tick=hook)

            og = lsim.capture()["outGlobals"]
            dbg = og.get("progDebug") or ""
            ok &= expect(not og.get("runErrors"),
                         "animation runs without errors",
                         str(og.get("runErrors")))
            ok &= expect(not any(l.startswith("err:")
                                 for l in dbg.splitlines()),
                         "animation compiles clean", str(dbg))
            print("   stream: %d ticks (Lua chip)" % len(samples))

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
        # cover that shape's rows (a polygon burst is two rows
        # per tick, so this is conservative)
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
        # every clearAllShapes pulse is followed by a drawAllShapes (the pulse that
        # runs the deferred black fill)
        pair_ok = all(c < reds[-1] for c in clears) if clears else True
        ok &= expect(pair_ok, "clearAllShapes pulses land before a drawAllShapes",
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
                       "pushShape": False, "shapeWireMode": False,
                       "shapeId": 0.0, "drawAllShapes": False,
                       "clearAllShapes": False, "shapePosition": (0.0, 0.0, 0.0), "shapeRotation": (0.0, 0.0, 0.0), "shapeScale": (0.0, 0.0, 0.0), "parentShapeId": 0.0, "brightness": 100.0}
        ssim.run(1)
        ssim.inputs = {k: v for k, v in ssim.inputs.items()
                       if k != "shapePoints"}

        # Start the replay 100 ticks before the first push: everything
        # before that is boot (no edges), so a fresh sim is already in
        # the identical state -- and those idle screen ticks are the
        # slowest part of the suite.
        S = max(0, (pushes[0] if pushes else TICKS) - 100)

        def hook2(s, tick):
            k = tick + S
            if k >= len(samples):
                return
            p, r, c, a = samples[k]
            pts, cols = tight(a)
            if len(pts) >= 2:
                slide(s, spts, scols, pts, cols)
            s.inputs = dict(s.inputs, **{
                "pushShape": p > 0.5,
                "drawAllShapes": r > 0.5,
                "clearAllShapes": c > 0.5,
            })

        ssim.run(TICKS - S, on_tick=hook2)

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
            got.append(tuple(float(x) / BF if k < 3 else float(x)
                             for k, x in enumerate(v[:4])))

        # ---- phase 3: model of the protocol ----------------------------
        # Immediate mode: each drawAllShapes paints the pushed shape.  A
        # clearAllShapes pulse only forgets -- the drawAllShapes right after it is
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
               if not close(got[i], fb.get(i, (0.0, 0.0, 0.0, 1.0)))]
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
