"""End-to-end test for showcase2.lua driving the wall screen.

Phase 1 runs the program on the Lua chip, sampling push/draw/clear,
wire, the id string and outNumArr every tick.  Phase 2 replays that
stream into the screen chip the way the connector would deliver it
(tight points plus the per-point colours, bool edges 2 ticks after
their arrays -- painttest's staging rule).  Phase 3 diffs the wall
against a Python model with retained slots and the new clearAllShapes
semantics: the pulse only forgets the slots, and the drawAllShapes right
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
import luastream  # noqa: E402
import colormath  # noqa: E402

colormath.install()
from animtest import out_port_id, resolve_port, port_val, tight  # noqa: E402
from animtest import port_slice  # noqa: E402
from painttest import (poly_colors, stroke_colors, slide,  # noqa: E402
                       expect, xf_points, xf_compose)

LUA_WS = os.path.join(ROOT, "lua.ws")
SCREEN_WS = os.path.join(HERE, "screen.ws")
SHOW = os.path.join(os.path.dirname(HERE), "cpu-screen-connector",
                    "sample-programs/showcase2.lua")
GFX = os.path.join(os.path.dirname(HERE), "cpu-screen-connector",
                   "sample-programs/gfx.lua")
SW = 64
TICKS = int(sys.argv[1]) if len(sys.argv) > 1 else 16000
# Virtual-tick budget for the real-Lua stream.  The program's own
# tick()/nap() pace decides how many ticks the writes span, so this is
# just where a forever-looping showcase is cut off -- it has to cover
# every phase the checks below name (20+ pushes, two deletes, a clear,
# a translator, the animation run) with room to spare.
BUDGET = int(os.environ.get("STREAM_BUDGET") or 16000)
force_chip = "--chip" in sys.argv
BLACK = (0.0, 0.0, 0.0, 1.0)
BLACK = (0.0, 0.0, 0.0, 1.0)


def parse_id(s):
    try:
        return float(s)
    except (ValueError, TypeError):
        return 0.0


# Brightness 100 is FULL_BRIGHT (the pre-port factor), and the screen is
# driven at 100, so the wall reads at 0.35 * pushed colour.  Divided
# back out here so the rest of the suite compares a pushed colour
# against the wall; see painttest.col for why it lives in one place.
BF = 0.35


def close(a, b, tol=1e-9):
    return len(a) == len(b) and all(
        abs(float(x) - float(y)) <= tol for x, y in zip(a, b))


def strip_lib(src):
    """Drop full-line comments and blanks for the in-game length cap."""
    return "\n".join(l for l in src.split("\n")
                     if l.strip() != ""
                     and not l.strip().startswith("--"))


def destr(v):
    # one string-array element: strip the "quoted" wrapper the same
    # way as the scalar string ports
    if not isinstance(v, str):
        return ""
    m = re.search(r'"([^"]*)"', v)
    return m.group(1) if m else v


def stof(s):
    try:
        return float(s)
    except (ValueError, TypeError):
        return 0.0


def stovec(sa, off):
    # three numeric strings at an offset: the connector's fixed slots
    # for one vec (missing/garbage parses to 0.0, which the screen
    # defaults -- shapeScale zeroes mean identity there too)
    return tuple(stof(sa[off + i]) if len(sa) > off + i else 0.0
                 for i in range(3))


class Stream:
    """A port sampler that stops paying for the dead parse head.

    The Lua chip takes ~1 char/tick to parse the program (measured:
    3861 chars -> parse end at tick 4029), and a showcase plus the gfx
    library is 6-7k chars -- so several thousand ticks at the start of
    phase 1 carry nothing at all.  Sampling the 128-slot arrays through
    them costs a fresh list per tick for values that are all zero, and
    the old full-history list grew 13500 of them.

    A short ring holds the lookback the edge logic needs (the bools and
    transform strings two ticks before a push); full sampling starts at
    the first live edge, which is also the first tick the 128-slot
    array is read.  `samples` is then indexed exactly like the old
    list -- index k is tick k + head -- so every existing check is
    unchanged.
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


def lua_stream(src, gfx_path, budget, force_chip=False):
    """The program's port stream: real Lua 5.5 when it is on the box.

    Returns per-tick rows, or None to tell the caller to run the chip.
    --chip forces the chip, and a box with no Lua 5.5 falls back to it,
    so the suite never silently depends on the oracle being installed.
    """
    if force_chip or luastream.LUA_BIN is None:
        return None
    return luastream.sample_rows(
        luastream.record(src, gfx_path, budget=budget))


def main():
    body = open(SHOW, encoding="utf-8").read()
    # the body calls the gfx library: prepend it, stripped (see
    # showtest for why).  `body` stays lib-free: the oracle prepends
    # the library itself, so handing it the assembled program would
    # load the library twice and its busy-wait tick would win over the
    # harness's virtual one.
    src = strip_lib(open(GFX, encoding="utf-8").read() + "\n" + body)
    print("program chars: %d" % len(src))
    dumps = []
    ok = True
    try:
        # ---- phase 1: the program's port stream -----------------------
        # Real Lua 5.5 (the same reference the language suites use) runs
        # the program with a virtual clock and records every write, so
        # the several thousand ticks the Lua chip spends parsing the
        # program (~1 char/tick) are never simulated.  The chip runs only
        # when no oracle is on the box (--chip forces it).
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
            r1 = resolve_port(lsim, out_port_id(lsim, "outNum1"))
            r2 = resolve_port(lsim, out_port_id(lsim, "outNum2"))
            r3 = resolve_port(lsim, out_port_id(lsim, "outNum3"))
            r4 = resolve_port(lsim, out_port_id(lsim, "outNum4"))
            ra = resolve_port(lsim, out_port_id(lsim, "outNumArr"))
            rs = resolve_port(lsim, out_port_id(lsim, "outStr1"))
            rs2 = resolve_port(lsim, out_port_id(lsim, "outStr2"))
            rsa = resolve_port(lsim, out_port_id(lsim, "outStrArr"))
            stream = Stream()

            def hook(s, tick):
                p, r, c = port_val(s, r1), port_val(s, r2), \
                    port_val(s, r3)
                w = port_val(s, r4)
                live = p > 0.5 or r > 0.5 or c > 0.5 or w > 0.5
                if stream.out:
                    raw = s.vars.get(rs[1], "")
                    if not isinstance(raw, str):
                        raw = ""
                    else:
                        m = re.search(r'"([^"]*)"', raw)
                        raw = m.group(1) if m else raw
                    raw2 = destr(s.vars.get(rs2[1], ""))
                    stream.push((p, r, c, w,
                                 port_slice(s, ra), raw, raw2,
                                 [destr(v) for v in port_val(s, rsa)]),
                                live)
                else:
                    stream.push((p, r, c, w, [], "", "", []), live)

            lsim.reset()
            lsim.inputs = {"program": src, "run": True}
            lsim.run(TICKS, on_tick=hook)
            samples = stream
            og = lsim.capture()["outGlobals"]
            ok &= expect(not og.get("runErrors"), "showcase runs clean",
                         str(og.get("runErrors")))
            dbg = og.get("progDebug") or ""
            ok &= expect(not any(l.startswith("err:")
                                 for l in dbg.splitlines()),
                         "showcase compiles clean", str(dbg))
            print("   stream: %d ticks (Lua chip)"
                  % len(samples))

        # ---- latch the stream ----------------------------------------
        pushes, reds, clrs, latched = [], [], [], []
        prev = [0.0, 0.0, 0.0]
        for k, (p, r, c, w, a, st, st2, sa) in enumerate(samples):
            if p > 0.5 and prev[0] <= 0.5:
                pushes.append(k)
                pts, cols = tight(a)
                pos = stovec(sa, 0)[:2]
                ang = stovec(sa, 3)[2]
                scl = stovec(sa, 6)[:2]
                latched.append((pts, cols, w > 0.5, st, pos, ang, scl,
                                parse_id(st2)))
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
        # a batch shares one draw across several pushes, so the old
        # one-to-one pairing cannot hold; the invariant that matters is
        # that every push is eventually drawn (no staged shape is ever
        # abandoned).  Pushes after the final draw are cut off by the
        # tick budget, not abandoned, so they are excluded.
        ok &= expect(all(any(r > p for r in reds) for p in pushes
                         if not reds or p < reds[-1]),
                     "every push is drawn")
        ids = set(s for _p, _c, _w, s, _x, _y, _z, _t in latched)
        ok &= expect({"1", "2", "3", "4"} <= ids,
                     "retained slots 1..4 all used", str(ids))
        deletes = [i for i, (p, _c, _w, s, _x, _y, _z, _t)
                   in enumerate(latched)
                   if len(p) == 0 and s == "3"]
        ok &= expect(len(deletes) >= 2,
                     "empty shape deletes slot 3 (%d times)"
                     % len(deletes))
        deletes4 = [i for i, (p, _c, _w, s, _x, _y, _z, _t)
                    in enumerate(latched)
                    if len(p) == 0 and s == "4"]
        ok &= expect(len(deletes4) >= 1,
                     "empty shape deletes slot 4 (%d times)"
                     % len(deletes4))
        ok &= expect(len(clrs) >= 1, "clearAllShapes pulse seen")
        # colours: at least half the shapes carry a real gradient
        coloured = [pc for pts, cols, _w, _s, _x, _y, _z, _t in latched
                    for pc in [cols] if len(pts) >= 6
                    and any(not close(c, (1.0, 1.0, 1.0, 1.0))
                            for c in cols)]
        ok &= expect(len(coloured) >= 10,
                     "per-point colours drive the wall (%d shapes)"
                     % len(coloured))
        alphas = set()
        for _pts, cols, _w, _s, _x, _y, _z, _t in latched:
            for c in cols:
                alphas.add(round(c[3], 3))
        ok &= expect(any(a < 0.9 for a in alphas),
                     "translucency present (alphas %s)"
                     % sorted(alphas))
        # transforms: the mover frames carry nonzero shapePosition,
        # shapeRotation and breathing shapeScale (its points never change), and
        # slot 4 attaches to slot 3 (the satellite follows the mover)
        moved = [l for l in latched
                 if (l[4] != (0.0, 0.0) or l[5] != 0.0
                     or l[6] != (1.0, 1.0))]
        ok &= expect(len(moved) >= 5,
                     "transforms drive shapes (%d pushes)"
                     % len(moved))
        kids = [l for l in latched if l[3] == "4" and l[7] == 3.0
                and len(l[0]) > 0]
        ok &= expect(len(kids) >= 1,
                     "slot 4 parents to slot 3 (%d pushes)"
                     % len(kids))

        # End replay and model at the last push edge (showtest's
        # boundary rule): every earlier burst is complete by the
        # driver's pacing, which the wall diff verifies.
        T_end = pushes[-1] if pushes else TICKS
        # Start the replay 100 ticks before the first push: everything
        # before that is boot and staging (no edges), so a fresh sim is
        # already in the identical state -- and those thousands of idle
        # screen ticks are the slowest part of the suite.
        T_start = max(0, (pushes[0] if pushes else T_end) - 100)

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
                       "pushShape": False, "shapeWireMode": False,
                       "shapeId": 0.0, "drawAllShapes": False,
                       "clearAllShapes": False, "shapePosition": (0.0, 0.0, 0.0), "shapeRotation": (0.0, 0.0, 0.0), "shapeScale": (0.0, 0.0, 0.0), "parentShapeId": 0.0, "brightness": 100.0}
        ssim.run(1)
        ssim.inputs = {k: v for k, v in ssim.inputs.items()
                       if k != "shapePoints"}
        last_slid = [None, None]

        def hook2(s, tick):
            k = tick + T_start
            if k >= T_end:
                return
            _p, _r, _c, _w, a, st, _st2, _sa = samples[k]
            b = samples[k - 2] if k >= 2 else \
                (0, 0, 0, 0, [], "", "", [])
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
                "shapeWireMode": (b[3] or 0.0) > 0.5,
                "shapeId": parse_id(b[5]),
                "drawAllShapes": (b[1] or 0.0) > 0.5,
                "clearAllShapes": (b[2] or 0.0) > 0.5,
                # the transform + parent ride with the bools (they are
                # staged at the push edge, settled long before it)
                "parentShapeId": parse_id(b[6]),
                "shapePosition": stovec(b[7], 0),
                "shapeRotation": stovec(b[7], 3),
                "shapeScale": stovec(b[7], 6),
            })

        ssim.run(T_end - T_start, on_tick=hook2)
        gids = {}
        for nid, nd in ssim.nodes.items():
            lb = _extract(nd.props.get("_label", ("raw", "")))
            if isinstance(lb, str) and lb.startswith("g") and lb[1:].isdigit():
                gids[int(lb[1:])] = nid
        got = [tuple(float(x) / BF if k < 3 else float(x)
                     for k, x in enumerate(
                         ssim.vars.get(gids[i], (0, 0, 0, 0))[:4]))
               for i in range(SW * SW)]

        # ---- phase 3: slot model --------------------------------------
        # The deferred clear: the pulse forgets every slot and stages
        # the black fill; the next drawAllShapes runs it -- with a shape
        # staged that means black first, then the shape over it.
        # Retained slots compose their world transform through every
        # ancestor exactly like the chip's walk, then paint.
        fb = {}
        slots = {}
        pending = []
        black = False
        li = 0
        snaps = []

        def world_of(table, key, depth=0):
            _p, _c, _w, _s, pos, ang, scl, par = table[key]
            local = (pos, ang, (scl[0] or 1.0, scl[1] or 1.0))
            if depth > 8 or par < 0.5 or int(par) not in table:
                return local
            return xf_compose(world_of(table, int(par), depth + 1),
                              local)

        def paint(pts, cols, wire, world):
            wpos, wang, wscl = world
            model = stroke_colors(
                xf_points(pts, wpos, wang, wscl), cols) if wire \
                else poly_colors(
                    xf_points(pts, wpos, wang, wscl), cols)
            fb.update(model)

        for k in range(T_end):
            p, r, c = samples[k][0], samples[k][1], samples[k][2]
            if c > 0.5 and (samples[k - 1][2] if k else 0.0) <= 0.5:
                slots = {}
                pending = []
                black = True
            if p > 0.5 and (samples[k - 1][0] if k else 0.0) <= 0.5:
                pts, cols, wire, st, pos, ang, scl, par = latched[li]
                li += 1
                pending.append((pts, cols, wire, st, pos, ang, scl, par))
            if r > 0.5 and (samples[k - 1][1] if k else 0.0) <= 0.5:
                if black:
                    fb = {}
                    black = False
                # the queue: every push since the last draw commits here,
                # in order.  A retained entry is stored in its slot; an
                # id-0 entry paints immediately (the chip's scratch slot:
                # painted with the scene, gone on the next commit).
                retained = False
                for entry in pending:
                    pts, cols, wire, st, pos, ang, scl, par = entry
                    sid = parse_id(st)
                    if sid < 0.5:
                        paint(pts, cols, wire,
                              (pos, ang, (scl[0] or 1.0,
                                          scl[1] or 1.0)))
                    else:
                        key = int(sid)
                        if not pts:
                            slots.pop(key, None)
                        else:
                            slots[key] = (pts, cols, wire, st, pos,
                                          ang, scl, par)
                        retained = True
                if retained:
                    fb = {}
                    for kk in sorted(slots):
                        spts, scols, swire = slots[kk][:3]
                        paint(spts, scols, swire,
                              world_of(slots, kk))
                pending = []
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
            # every snapshot the model took at a drawAllShapes edge.
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


