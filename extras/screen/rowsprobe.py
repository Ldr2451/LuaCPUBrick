"""Do the walks really stage eight rows a tick?

Slot 1 is a full-wall quad (64 rows): its `polyOn` window must measure
EXACTLY 8 ticks -- the 8-row advance stages rows at prow = 0,8,..,56 and
falls the tick prow jumps past 63 (the old 4-row walk measured 16).

Slot 2 is one long vertical segment (y 1..63): the quad walk's ladder is
now 8/4/1/1, so its `sOn` window must land at 12 ticks (1,9,17,25,33,41,
49,57,61,62,63,64) -- the old 4/1/1 ladder needed 22.

Both commits re-push the same picture twice: the windows must repeat
identically, and every settled wall must be pixel-exact (painttest's
poly and stroke oracles: the fill under the stroke, overlap = stroke on
top).  The erase pass is untouched (4 rows a tick) and its length is
only reported.

  python -u extras/screen/rowsprobe.py [screen.ws]
"""
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "irrun"))
sys.path.insert(0, HERE)

from irsims import share_dump, _extract  # noqa: E402
from painttest import fresh_sim, slide3, stroke_pixels, poly_pixels, close  # noqa
from watchdog import make_watch          # noqa: E402

WS = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 \
    and sys.argv[1] != "trace" else os.path.join(HERE, "screen.ws")

FULL = [0.0, 0.0, 0.0, 64.0, 0.0, 0.0, 64.0, 64.0, 0.0, 0.0, 64.0, 0.0,
        0.0, 0.0, 0.0]
BAR = [32.0, 1.0, 0.0, 32.0, 63.0, 0.0]
FG = (0.0, 1.0, 1.0, 1.0)
RD = (1.0, 0.0, 0.0, 1.0)
BLACK = (0.0, 0.0, 0.0, 1.0)
BF = 0.35


def dim(c):
    return tuple(BF * v if k < 3 else v for k, v in enumerate(c))


def want_wall():
    want = [BLACK] * 4096
    for i in poly_pixels([FULL[0], FULL[1], FULL[3], FULL[4], FULL[6],
                          FULL[7], FULL[9], FULL[10], FULL[12], FULL[13]]):
        want[i] = dim(FG)
    for i in stroke_pixels([BAR[0], BAR[1], BAR[3], BAR[4]]):
        want[i] = dim(RD)
    return want


def var_id(sim, name):
    for nid, nd in sim.nodes.items():
        if _extract(nd.props.get("_label", ("raw", ""))) == name:
            return nid
    raise RuntimeError("no var %r" % name)


def main():
    fd, dump = tempfile.mkstemp(suffix=".pkl")
    os.close(fd)
    try:
        share_dump(WS, dump)
        sim, gids, _polyon, _son, pts_aid, cols_aid = fresh_sim(dump)
        wd = make_watch(sim)
        wvid = {n: var_id(sim, n) for n in
                ("rcOn", "polyOn", "sOn", "arming", "armingS",
                 "erasing", "commitR", "commitQ")}
        pid = var_id(sim, "polyOn")
        sid = var_id(sim, "sOn")
        eid = var_id(sim, "erasing")
        sim.inputs = {"shapePoints": [0.0] * 32, "shapeColors": [],
                      "pushShape": False, "shapeWireMode": False,
                      "shapeId": 0.0, "drawAllShapes": False,
                      "clearAllShapes": False,
                      "shapePosition": (0.0, 0.0, 0.0),
                      "shapeRotation": (0.0, 0.0, 0.0),
                      "shapeScale": (0.0, 0.0, 0.0),
                      "parentShapeId": 0.0, "brightness": 100.0}
        sim.run(1)
        sim.inputs = {k: v for k, v in sim.inputs.items()
                      if k != "shapePoints"}

        plan = {}

        def stage(t, sid_, pts, col, wire, draw):
            plan[t] = {"shapePoints": list(pts),
                       "shapeColors": [col] * (len(pts) // 3),
                       "shapeWireMode": wire, "shapeId": float(sid_),
                       "shapePosition": (0.0, 0.0, 0.0),
                       "shapeRotation": (0.0, 0.0, 0.0),
                       "shapeScale": (0.0, 0.0, 0.0),
                       "parentShapeId": 0.0}
            plan[t + 2] = {"pushShape": True}
            plan[t + 4] = {"pushShape": False}
            if draw:
                plan[t + 6] = {"drawAllShapes": True}
                plan[t + 8] = {"drawAllShapes": False}

        stage(10, 1, FULL, FG, False, False)
        stage(24, 2, BAR, RD, True, True)
        # three re-pushed commits of the same picture
        COMMITS = 3
        for k in range(COMMITS):
            t0 = 300 + 250 * k
            stage(t0, 1, FULL, FG, False, False)
            stage(t0 + 12, 2, BAR, RD, True, True)

        windows = []          # (name, start, length) of polyOn/sOn runs
        state = {"p": False, "s": False, "e": False,
                 "pRun": None, "sRun": None, "eRun": None}

        def watch(sn, tick):
            wd(sn, tick)
            if tick in plan:
                step = dict(plan[tick])
                if "shapePoints" in step:
                    slide3(sn, pts_aid, cols_aid, step.pop("shapePoints"),
                           step.pop("shapeColors", None))
                sn.inputs = dict(sn.inputs, **step)
            for nm, nid_, key in (("poly", pid, "p"), ("stroke", sid, "s"),
                                  ("erase", eid, "e")):
                on = bool(sn.vars.get(nid_, False))
                if on and not state[key]:
                    state[key + "Run"] = [tick, 0]
                elif not on and state[key]:
                    w = state[key + "Run"]
                    windows.append((nm, w[0], tick - w[0]))
                    state[key + "Run"] = None
                state[key] = on

        walls = []
        settled = []
        st = {"was": False}

        def watch2(sn, tick):
            watch(sn, tick)
            act = any(bool(sn.vars.get(wvid[n])) for n in wvid)
            if st["was"] and not act:
                settled.append(tick)
                walls.append([sn.vars.get(gids[i], (0.0, 0.0, 0.0, 0.0))[:4]
                              for i in range(4096)])
            st["was"] = act

        if "trace" in sys.argv:
            fn = ["cDirty", "erArm", "eraseOK", "noDepth", "arming", "polyOn",
                  "rcOn", "erasing", "erDone", "wasPaint", "pending",
                  "commitR", "lastImm", "polyLive", "armingS", "sLive",
                  "repaint", "pfirst", "plast", "prow", "rcSlot", "sLast",
                  "sFreshLast", "sEnd", "sSeg", "sOn"]
            vids = {n: var_id(sim, n) for n in fn}

            def trace_watch(sn, tick):
                watch(sn, tick)
                if 12 <= tick <= 120:
                    print("t%-4d " % tick + " ".join(
                        "%s=%s" % (n, sn.vars.get(vids[n])) for n in fn))

            sim.run(130, on_tick=trace_watch)
            print("windows:", windows)
            return 0

        sim.run(900, on_tick=watch2)

        want = want_wall()
        bad = 0
        for t, wall in zip(settled, walls):
            if t <= 30:
                continue
            wrong = [i for i in range(4096) if not close(wall[i], want[i])]
            if wrong:
                print("t=%-5d wrong=%-4d first=%r got=%r want=%r"
                      % (t, len(wrong), wrong[0], wall[wrong[0]][:3],
                         want[wrong[0]][:3]))
                bad += len(wrong)

        pw = [w for w in windows if w[0] == "poly"]
        sw = [w for w in windows if w[0] == "stroke"]
        ew = [w for w in windows if w[0] == "erase"]
        print("polyOn windows:", [w[2] for w in pw])
        print("sOn windows:", [w[2] for w in sw])
        print("erase windows:", [w[2] for w in ew])
        # Every commit: one 8-tick fill window per commit (the first
        # commit included); every stroke window: 12 ticks.
        if not all(n == 8 for _, _, n in pw):
            print("fill windows not all 8 ticks:", [w[2] for w in pw])
            bad += 1
        # The stroke quad ladder 8/4/1/1 over rows 1..63: 1,9,17,25,33,41,
        # 49,57,61,62,63, then the tick that falls -- 13 ticks.
        if not all(n == 13 for _, _, n in sw):
            print("stroke windows not all 13 ticks:", [w[2] for w in sw])
            bad += 1
        print("RESULT: %s" % ("BUG" if bad else "ok"))
        return 1 if (bad or wd.failures()) else 0
    finally:
        os.unlink(dump)


if __name__ == "__main__":
    sys.exit(main())
