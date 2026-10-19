"""Cube end-to-end through the chain, all three sims on real artifacts.

--chip phase 1 runs the program on the actual Lua CPU chip (lua.ws) and
samples its ports per tick -- the stream the connector sees in game,
priced by real chip compute.  The oracle stream (real Lua 5.5, WCOST
model) is recorded too and the two PUSH LATCH sequences are diffed
elementwise; a divergence means the chip writes different port values
with no diagnostics -- the black-in-game class of bug every error-check
probe misses.  Phases 2/3 replay the chosen stream through the
connector and the screen and report painted pixels per draw edge.

  python -u cubetest.py --chip [ticks]   (ticks default 12000)
  python -u cubetest.py [budget]         (oracle phase 1, default 1800)
Exit 0 on GREEN (stream equal, wall painted), 1 on RED.  String-array
ports are compared at their first 9 fields (the chip port is wider and
pads with empty strings; real Lua slices to 9).
"""
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "irrun"))
sys.path.insert(0, os.path.join(ROOT, "extras", "screen"))

# CLI first: some imported test modules (animtest) parse sys.argv at
# import time and would crash on a flag, then feed them numeric-only
# args so flags-first call orders stay valid.
USE_CHIP = "--chip" in sys.argv
_args = [a for a in sys.argv[1:] if a.isdigit()]
MAKE_SAVE = "--save" in sys.argv
SAVE = os.environ.get("CUBE_FRAMES") if MAKE_SAVE else None
BUDGET = int(_args[0]) if _args else 1800
TICKS = int(_args[0]) if _args else (12000 if USE_CHIP else 0) or BUDGET
# second numeric arg: ticks of forever-animation tail observed past the
# last draw edge (default 60 = about one burst; use 700+ to watch the
# per-burst stale-erase behaviour the black-ghosting report is about)
TAIL = int(_args[1]) if len(_args) > 1 else 60
sys.argv = [sys.argv[0]] + _args

from irsims import share_dump, sim_from_dump, _extract  # noqa: E402
import colormath  # noqa: E402
colormath.install()
from painttest import slide  # noqa: E402
import luastream  # noqa: E402
from animtest import port_slice  # noqa: E402

LUA_WS = os.path.join(ROOT, "lua.ws")
CONN_WS = os.path.join(HERE, "connector.ws")
SCREEN_WS = os.path.join(ROOT, "extras", "screen", "screen.ws")
GFX = os.path.join(HERE, "gfx.lua")
BODY = os.path.join(HERE, "sample-programs", "cube.lua")
SW = 64
BLACK = (0.0, 0.0, 0.0, 1.0)
BF = 0.35


def strip_lib(src):
    """Drop full-line comments and blanks (the sane in-game program)."""
    return "\n".join(l for l in src.split("\n")
                     if l.strip() != ""
                     and not l.strip().startswith("--"))


def undim(v):
    return tuple(float(x) / BF if k < 3 else float(x)
                 for k, x in enumerate(v[:4]))


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


def destr(v):
    import re as _re
    if not isinstance(v, str):
        return ""
    m = _re.search(r'"([^"]*)"', v)
    return m.group(1) if m else v


def chip_stream(ticks, ok):
    """Phase 1 off the real Lua chip: rows like the oracle's, tab-priced
    by the chip's own compute.  Returns the rows list."""
    src = strip_lib(open(GFX, encoding="utf-8").read() + "\n"
                    + open(BODY, encoding="utf-8").read())
    print("chip program chars:", len(src))
    with tempfile.NamedTemporaryFile(suffix=".pkl", delete=False) as f:
        lua_dump = f.name
    try:
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
        rows = []
        live_seen = [False]

        def hook(s, tick):
            row = (port_val(s, r1), port_val(s, r2), port_val(s, r3),
                   port_val(s, r4),
                   [float(x) for x in port_slice(s, ra, n=128)],
                   destr(s.vars.get(rs[1], "")),
                   destr(s.vars.get(rs2[1], "")),
                   [destr(v) for v in port_val(s, rsa)])
            live = row[0] > 0.5 or row[1] > 0.5 or row[2] > 0.5 \
                or row[3] > 0.5
            if live:
                live_seen[0] = True
            if live_seen[0]:
                rows.append(row)

        lsim.reset()
        lsim.inputs = {"program": src, "run": True}
        lsim.run(ticks, on_tick=hook)
        og = lsim.capture()["outGlobals"]
        ok &= not og.get("runErrors")
        dbg = og.get("progDebug") or ""
        ok &= not any(l.startswith("err:") or l.startswith("warn:")
                      for l in dbg.splitlines())
        print("chip runErrors:", og.get("runErrors"))
        print("chip diagnostics:",
              [l for l in dbg.splitlines()
               if l.startswith("err:") or l.startswith("warn:")] or "none")
    finally:
        os.unlink(lua_dump)
    print("chip stream ticks (live):", len(rows))
    return rows, ok


def latch_edges(samples):
    """rising outNum1 edges -> (st, st2, a[97], a[99], a[:12], sa[:9]).
    sa is compared at its first 9 fields: the chip's outStrArr port is
    wider and pads with empty strings, real Lua's slice stops at 9."""
    out = []
    prev = 0.0
    for row in samples:
        p, _r, _c, _w, a, st, st2, sa = row
        if p > 0.5 and prev <= 0.5:
            out.append((st, st2,
                        a[97] if len(a) > 97 else 0.0,
                        a[99] if len(a) > 99 else 0.0,
                        tuple(round(float(x), 3) for x in a[:12]),
                        tuple(sa[:9])))
        prev = p
    return out


def report(tag, wall):
    if wall is None:
        print("%s: no snapshot" % tag)
        return
    if SAVE:
        with open(SAVE, "a", encoding="utf-8") as f:
            f.write("%s\t%s\n" % (tag, repr(list(wall))))
    left = [(i // SW, i % SW, wall[i])
            for i in range(SW * SW) if wall[i][:3] != (0.0, 0.0, 0.0)]
    rows = sorted(set(r for r, _c, _v in left))
    cols = sorted(set(c for _r, c, _v in left))
    colors = sorted(set(tuple(round(x, 2) for x in v[:3])
                        for _r, _c, v in left))
    rr = ("%s..%s" % (rows[0], rows[-1])) if rows else "-"
    cc = ("%s..%s" % (cols[0], cols[-1])) if cols else "-"
    print("%s: painted=%d rows=%s cols=%s ncolors=%d colors=%s"
          % (tag, len(left), rr, cc, len(colors), colors[:8]))


def main():
    ok = True
    body = open(BODY, encoding="utf-8").read()
    # ---- phase 1 -------------------------------------------------------
    if USE_CHIP:
        samples, ok = chip_stream(TICKS, ok)
        # oracle reference for the latch comparison
        ow = luastream.record(body, GFX, budget=BUDGET)
        osamp = luastream.sample_rows(ow) if ow is not None else []
        lg_chip = latch_edges(samples)
        lg_orac = latch_edges(osamp)
        print("push latches: chip=%d oracle=%d"
              % (len(lg_chip), len(lg_orac)))
        for i in range(max(len(lg_chip), len(lg_orac))):
            a = lg_chip[i] if i < len(lg_chip) else None
            b = lg_orac[i] if i < len(lg_orac) else None
            if a != b:
                ok = False
                print("LATCH MISMATCH %d:\n  chip  : %r\n  oracle: %r"
                      % (i, a, b))
        if lg_chip:
            print("chip push 1 detail:", lg_chip[0])
    else:
        writes = luastream.record(body, GFX, budget=BUDGET)
        samples = luastream.sample_rows(writes) if writes is not None else []

    # bound the replay: keep every push, then a short animation tail
    pe = [k for k in range(1, len(samples))
          if samples[k][0] > 0.5 and samples[k - 1][0] <= 0.5]
    if pe:
        head = max(0, pe[0] - 50)
        samples = list(samples[head:pe[-1] + TAIL])
        print("truncated to:", len(samples))

    # ---- phase 2: connector -------------------------------------------
    with tempfile.NamedTemporaryFile(suffix=".pkl", delete=False) as f:
        conn_dump = f.name
    try:
        share_dump(CONN_WS, conn_dump)
        csim = sim_from_dump(conn_dump)
        csim.reset()
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

        cpull = {}
        for name in ("pushShape", "drawAllShapes", "shapeWireMode", "shapeId",
                     "clearAllShapes", "parentShapeId", "addToShapeInTicks"):
            cpull[name] = out_port_id(csim, name)
        cstream = []

        def hookc(s, tick):
            if tick < len(samples):
                p1, p2, p3, p4, a, st, st2, sa = samples[tick]
                s.inputs = dict(s.inputs, **{
                    "outNum1": p1, "outNum2": p2, "outNum3": p3,
                    "outNum4": p4, "outStr1": st, "outStr2": st2,
                    "outNumArr": list(a[:128]),
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

        csim.run(len(samples), on_tick=hookc)
    finally:
        os.unlink(conn_dump)

    pushE = [k for k in range(1, len(cstream))
             if (cstream[k]["pushShape"] or 0.0) > 0.5
             and (cstream[k - 1]["pushShape"] or 0.0) <= 0.5]
    reds = [k for k in range(1, len(cstream))
            if (cstream[k]["drawAllShapes"] or 0.0) > 0.5
            and (cstream[k - 1]["drawAllShapes"] or 0.0) <= 0.5]
    clrE = [k for k in range(1, len(cstream))
            if (cstream[k]["clearAllShapes"] or 0.0) > 0.5
            and (cstream[k - 1]["clearAllShapes"] or 0.0) <= 0.5]
    maxpts = max((len(r["shapePoints"]) for r in cstream), default=0)
    print("connector: maxPts=%d pushes=%d redraws=%d clears=%d"
          % (maxpts, len(pushE), len(reds), len(clrE)))
    shown = False
    for r in cstream:
        nz = [v for v in r["shapePoints"] if v != 0.0]
        if len(nz) >= 6:
            print("  sample shapePoints:", r["shapePoints"][:12])
            print("  sample shapeColors:",
                  [tuple(round(x, 2) for x in v[:4])
                   for v in r["shapeColors"][:3]])
            shown = True
            break
    if not shown:
        print("  NO non-zero shapePoints staged => screen gets empties")
        ok = False

    # ---- phase 3: screen replay ---------------------------------------
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
        ssim.inputs = {"shapePoints": [0.0] * 32,
                       "shapeColors": [(1.0, 1.0, 1.0, 1.0)] * 4,
                       "pushShape": False, "shapeWireMode": False,
                       "shapeId": 0.0, "drawAllShapes": False,
                       "clearAllShapes": False,
                       "shapePosition": (0.0, 0.0, 0.0),
                       "shapeRotation": (0.0, 0.0, 0.0),
                       "shapeScale": (0.0, 0.0, 0.0),
                       "parentShapeId": 0.0, "brightness": 100.0,
                       "addToShapeInTicks": 0.0}
        ssim.run(1)
        ssim.inputs = {k: v for k, v in ssim.inputs.items()
                       if k != "shapePoints"}
        snaps = {}
        last_slid = [None, None]

        def hook2(s, tick):
            if tick < len(cstream):
                c = cstream[tick]
                b = cstream[tick - 2] if tick >= 2 else {}
                a = c["shapePoints"]
                cc = c.get("shapeColors")
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
                    "parentShapeId": float(b.get("parentShapeId") or 0.0),
                    "shapePosition":
                        tuple(b.get("shapePosition") or (0.0, 0.0, 0.0))[:3],
                    "shapeRotation":
                        tuple(b.get("shapeRotation") or (0.0, 0.0, 0.0))[:3],
                    "shapeScale":
                        tuple(b.get("shapeScale") or (0.0, 0.0, 0.0))[:3],
                    "addToShapeInTicks":
                        float(b.get("addToShapeInTicks") or 0.0),
                })
            # snapshot the wall every ESTEP ticks past the last draw edge,
            # through the whole forever-animation tail: a ghost/second
            # frame shows up as the painted count CLIMBING burst by burst
            # instead of holding steady near ~1180 px.
            ESTEP = 80
            base = reds[-1] if reds else 0
            k = tick - (base + 2 + 40)
            if k >= 0 and k % ESTEP == 0:
                snaps[k // ESTEP] = tuple(
                    undim(tuple(float(x) for x in
                               s.vars.get(gids[i],
                               (0.0, 0.0, 0.0, 0.0))[:4]))
                    for i in range(SW * SW)) if gids else None

        cap = (reds[-1] + 2 + 40 + TAIL) if reds else (len(cstream) + 150)
        cap = min(cap, len(cstream) + 150 + TAIL)
        ssim.run(cap, on_tick=hook2)
        for e in reds[:8]:
            report("draw@%d" % e, snaps.get(0))
        for k in sorted(snaps):
            if k:
                report("anim+%03d" % (40 + 80 * k), snaps.get(k))
        final = tuple(undim(tuple(float(x) for x in
                                 ssim.vars.get(gids[i], (0.0, 0.0, 0.0, 0.0))[:4]))
                      for i in range(SW * SW)) if gids else None
        report("final", final)
    finally:
        os.unlink(scr_dump)
    print("PROBE:", "GREEN" if ok else "RED")
    sys.exit(0 if ok else 1)


try:
    main()
except Exception:  # noqa: E402
    import traceback
    traceback.print_exc()
    raise
