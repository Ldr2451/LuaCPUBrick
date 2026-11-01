"""End-to-end test for anim.lua driving the wall screen.

The game wiring this program drives (via the connector), v2: everything
rides ONE array port -- the CPU's outNumArr wired to the connector:
  outNumArr -> point floats (1..) plus a terminator, then optional
               colours; the push, draw and clear pulses ride slots
               200/201/202, the float count and animation length ride
               196/198 above the shape data, and the control block
               stays at 200..214; the connector truncates at the
               terminator and defaults missing colours to white
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
ANIM = os.path.join(os.path.dirname(HERE), "cpu-screen-connector",
                     "sample-programs/anim.lua")
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
    rows = luastream.sample_rows(
        luastream.record(src, gfx_path, budget=budget),
        n_arr=216, cols=4)
    # v2 protocol: the pulses ride the array too, slots 200..202, so
    # read them where the game reads them, not off scalar ports.
    out = []
    for (_p, _r, _c, a) in rows:
        out.append((1.0 if len(a) > 199 and a[199] > 0.5 else 0.0,
                    1.0 if len(a) > 200 and a[200] > 0.5 else 0.0,
                    1.0 if len(a) > 201 and a[201] > 0.5 else 0.0,
                    a))
    return out


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


def port_slice(sim, res, n=216):
    """port_val, but array ports are truncated to n slots: the protocol
    ends at the control block's slot 214, and the full 16k copy every
    tick dominates phase-1 wall time."""
    kind, sid = res
    if kind == "arr":
        v = sim.arrays.get(sid)
        return list(v[:n]) if v is not None else []
    return port_val(sim, res)


def tight(a):
    """The connector's truncation and colour split, mirrored: with a
    point count in 1-based slot 196 the terminator is read directly
    instead of scanned for, so coordinates are unrestricted; without
    one the legacy scan applies (an exact integer in [-17, -1] ends
    the list).  Either way the count after the terminator is colours
    -- white where the driver sent none."""
    n = None
    if len(a) > 195 and a[195] > 0.5:
        n = max(0, min(16, int(a[195])))
        term = a[2 * n] if len(a) > 2 * n else -1.0
        if not (-17.0 <= term <= -1.0 and term == int(term)):
            term = -1.0
    pts = []
    if n is None:
        term = -1.0
        for i in range(16):
            x = a[2 * i] if len(a) > 2 * i else -1.0
            if -17.0 <= x <= -1.0 and x == int(x):
                term = x
                break
            y = a[2 * i + 1] if len(a) > 2 * i + 1 else 0.0
            pts += [x, y]
        n = len(pts) // 2
    else:
        for i in range(n):
            x = a[2 * i] if len(a) > 2 * i else 0.0
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


def zero_point_forever_case():
    """The cube's forever pivot is a ZERO-POINT arm push to a live
    retained slot: it must keep the stored points and colours, keep the
    slot live, and keep the wall animating.  Regression: the commit used
    to hit the n<1 delete branch before the animation branch, so the arm
    erased the pivot and the children recomposited unpainted -- the
    'second frame draws on it' report.  Asserts:
      1. the established triangle survives the arm (slot kept),
      2. something keeps rotating (frames differ across the tail),
      3. no frame ever grows past a ghost bound (the second frame)."""
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

        def painted_on():
            return sum(1 for i in range(SW * SW)
                       if tuple(float(x) / BF if k < 3 else float(x)
                                for k, x in
                                enumerate(ssim.vars.get(
                                    gids[i], (0.0, 0.0, 0.0, 0.0))[:4])
                                )[:3] != (0.0, 0.0, 0.0))

        def full_frame():
            return tuple(tuple(float(x) / BF if k < 3 else float(x)
                               for k, x in
                               enumerate(ssim.vars.get(
                                   gids[i], (0.0, 0.0, 0.0, 0.0))[:4]))
                         for i in range(SW * SW))

        ssim.inputs = {"shapePoints": [0.0] * 8,
                       "shapeColors": [],
                       "pushShape": False, "shapeWireMode": False,
                       "shapeId": 0.0, "drawAllShapes": False,
                       "clearAllShapes": False,
                       "shapePosition": (0.0, 0.0, 0.0),
                       "shapeRotation": (0.0, 0.0, 0.0),
                       "shapeScale": (1.0, 1.0, 1.0),
                       "parentShapeId": 0.0, "addToShapeInTicks": 0.0,
                       "brightness": 100.0}
        ssim.run(2)
        ssim.inputs = {k: v for k, v in ssim.inputs.items()
                       if k != "shapePoints"}

        # run() delivers inputs only from tick 1 (tick 0 runs literals
        # only), so a pulse must span two ticks of a run; a one-tick
        # pulse inside run(1) is consumed by tick 0 and never fires.
        def edge(pin, extra=None):
            if extra is not None:
                ssim.inputs = dict(ssim.inputs, **extra)
            ssim.inputs = dict(ssim.inputs, **{pin: True})
            ssim.run(2)
            ssim.inputs = dict(ssim.inputs, **{pin: False})
            ssim.run(2)

        # the screen boots with a staged black fill consumed by the
        # FIRST draw; every driver clears first, so does this case.
        slide(ssim, spts, scols, [], [])
        ssim.run(2)
        edge("clearAllShapes")
        edge("drawAllShapes")

        # establish a coloured triangle on retained slot 1 (instant).
        # painttest's staging rule: the array must be visible BEFORE the
        # edge tick, so slide first, run one idle tick, then pulse.
        pts = [(10.0, 10.0), (34.0, 12.0), (22.0, 30.0)]
        cols = [(1.0, 0.2, 0.2, 1.0), (0.2, 1.0, 0.2, 1.0),
                (0.2, 0.2, 1.0, 1.0)]
        slide(ssim, spts, scols, [v for p in pts for v in p], cols)
        ssim.run(2)
        edge("pushShape", {"shapeId": 1.0})
        edge("drawAllShapes")
        ssim.run(140)
        base_px = painted_on()
        ok = expect(base_px > 0, "slot 1 established (%d px)" % base_px)

        # the zero-point forever arm, exactly like the cube's pivot:
        # empty points, ticks = -1.0 (forever on the wire), all scale
        # rates zero (scale fields are per-tick DELTAS here; a nonzero
        # walk makes the shape explode by design)
        slide(ssim, spts, scols, [], [])
        ssim.run(2)
        edge("pushShape", {
            "shapeId": 1.0, "addToShapeInTicks": -1.0,
            "shapePosition": (0.0, 0.0, 0.0),
            "shapeRotation": (0.0, 0.0, 0.03),
            "shapeScale": (0.0, 0.0, 0.0)})
        edge("drawAllShapes")
        ssim.run(140)

        # watch ~12 repaints: the slot must survive and keep spinning,
        # and the painted area must never balloon into a second frame.
        # The self-refresh cycle runs ~100 ticks (advance -> idle ->
        # recomposite walk), so 40-tick sampling crosses phases.
        seen = []
        frames = []
        for step in range(12):
            ssim.run(40)
            frames.append(full_frame())
            seen.append(painted_on())
        diff = sum(1 for i in range(SW * SW)
                   if frames[0][i] != frames[-1][i])
        nframes = len(set(hash(f) for f in frames))
        ok &= expect(min(seen) > 0,
                     "zero-point arm keeps the slot live",
                     "painted after arm: %s" % seen)
        ok &= expect(nframes >= 3,
                     "forever arm keeps animating",
                     "only %d distinct frames across the tail; painted=%s"
                     % (nframes, seen))
        ok &= expect(max(seen) <= max(base_px, 1) * 3 / 2 + 8,
                     "no ghost growth over the tail",
                     "base=%d tail=%s" % (base_px, seen))
        return ok
    finally:
        if os.path.exists(scr_dump):
            os.unlink(scr_dump)


def slot_two_animates_case():
    """An animated shape in slot 2 must move.

    The animation ladder was `if slot < 1.5 { body0 } else if slot < 2.5 {
    body1 } ...` over `slot = (pId - 1.0) | 0`, so every slot but the
    first took the PREVIOUS slot's deltas: slot 1 wrote slot 0's, slot 2
    wrote slot 1's, and the last body was unreachable.  An animated shape
    in slot 2 therefore never moved -- its deltas landed in a slot that
    held nothing.  The suite only ever animated slot 1, where the
    off-by-one lands on the right slot by luck.

    This establishes a triangle in slot 2, arms the forever animation on
    slot 2, and asserts the wall CHANGES: with the ladder's off-by-one
    the shape sits still.
    """
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

        def painted_on():
            return sum(1 for i in range(SW * SW)
                       if tuple(float(x) / BF if k < 3 else float(x)
                                for k, x in
                                enumerate(ssim.vars.get(
                                    gids[i], (0.0, 0.0, 0.0, 0.0))[:4])
                                )[:3] != (0.0, 0.0, 0.0))

        def full_frame():
            return tuple(tuple(float(x) / BF if k < 3 else float(x)
                               for k, x in
                               enumerate(ssim.vars.get(
                                   gids[i], (0.0, 0.0, 0.0, 0.0))[:4]))
                         for i in range(SW * SW))

        ssim.inputs = {"shapePoints": [0.0] * 8,
                       "shapeColors": [],
                       "pushShape": False, "shapeWireMode": False,
                       "shapeId": 0.0, "drawAllShapes": False,
                       "clearAllShapes": False,
                       "shapePosition": (0.0, 0.0, 0.0),
                       "shapeRotation": (0.0, 0.0, 0.0),
                       "shapeScale": (1.0, 1.0, 1.0),
                       "parentShapeId": 0.0, "addToShapeInTicks": 0.0,
                       "brightness": 100.0}
        ssim.run(2)
        ssim.inputs = {k: v for k, v in ssim.inputs.items()
                       if k != "shapePoints"}

        def edge(pin, extra=None):
            if extra is not None:
                ssim.inputs = dict(ssim.inputs, **extra)
            ssim.inputs = dict(ssim.inputs, **{pin: True})
            ssim.run(2)
            ssim.inputs = dict(ssim.inputs, **{pin: False})
            ssim.run(2)

        slide(ssim, spts, scols, [], [])
        ssim.run(2)
        edge("clearAllShapes")
        edge("drawAllShapes")

        # the triangle goes in slot 2, NOT slot 1.
        pts = [(10.0, 10.0), (34.0, 12.0), (22.0, 30.0)]
        cols = [(1.0, 0.2, 0.2, 1.0), (0.2, 1.0, 0.2, 1.0),
                (0.2, 0.2, 1.0, 1.0)]
        slide(ssim, spts, scols, [v for p in pts for v in p], cols)
        ssim.run(2)
        edge("pushShape", {"shapeId": 2.0})
        edge("drawAllShapes")
        ssim.run(140)
        base_px = painted_on()
        ok = expect(base_px > 0, "slot 2 established (%d px)" % base_px)

        # the same forever arm the cube's pivot uses, on slot 2.
        slide(ssim, spts, scols, [], [])
        ssim.run(2)
        edge("pushShape", {
            "shapeId": 2.0, "addToShapeInTicks": -1.0,
            "shapePosition": (0.0, 0.0, 0.0),
            "shapeRotation": (0.0, 0.0, 0.03),
            "shapeScale": (0.0, 0.0, 0.0)})
        edge("drawAllShapes")
        ssim.run(140)

        frames = []
        seen = []
        for _step in range(12):
            ssim.run(40)
            frames.append(full_frame())
            seen.append(painted_on())
        diff = sum(1 for i in range(SW * SW)
                   if frames[0][i] != frames[-1][i])
        nframes = len(set(hash(f) for f in frames))
        ok &= expect(min(seen) > 0,
                     "slot 2 arm keeps the slot live",
                     "painted after arm: %s" % seen)
        ok &= expect(nframes >= 3,
                     "slot 2 animates",
                     "only %d distinct frames across the tail; painted=%s"
                     % (nframes, seen))
        ok &= expect(diff > 0,
                     "slot 2 pixels move",
                     "no pixel changed across the tail")
        return ok
    finally:
        if os.path.exists(scr_dump):
            os.unlink(scr_dump)


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
            pid_arr = out_port_id(lsim, "outNumArr")
            r_arr = resolve_port(lsim, pid_arr)

            samples = Stream()
            live = [False]

            def hook(s, tick):
                # v2 protocol: the push, draw and clear pulses ride the
                # array at slots 200..202, so read them off the slice,
                # exactly where the connector reads them.
                a = port_slice(s, r_arr, 216)
                p = a[199] if len(a) > 199 else 0.0
                r = a[200] if len(a) > 200 else 0.0
                c = a[201] if len(a) > 201 else 0.0
                if live[0]:
                    samples.push((p, r, c, a), True)
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
        # the next push -- that is what keeps a burst from being abandoned.
        # The leading clearScreen contributes a draw before the first
        # push, so pairing starts from the first draw after it; a final
        # push cut off by the tick budget has no following draw and is
        # excluded, like everywhere else.
        reds2 = [r for r in reds if not pushes or r > pushes[0]]
        seq_ok = all(pushes[i] < reds2[i] < pushes[i + 1]
                     for i in range(min(len(reds2), len(pushes)) - 1))
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
    a = main()
    z = zero_point_forever_case()
    print("zero_point_forever_case:", "OK" if z else "FAIL")
    s = slot_two_animates_case()
    print("slot_two_animates_case:", "OK" if s else "FAIL")
    sys.exit(0 if (a and z and s) else 1)
