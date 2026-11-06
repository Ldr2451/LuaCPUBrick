"""Does a fully off-wall stroke skip its walk, and an edge one still paint?

The stroke arm culls a shape whose points all sit outside the wall (with
a 2 px margin for spans and joins), exactly as the fill arm has always
culled.  The probe stores FOUR strokes and commits the same picture
several times:

  slot 1  a stroke at x = -40 .. -26  (fully left of the wall)
  slot 2  an on-wall zigzag          (must paint)
  slot 3  a stroke from (0,32) west  (its bbox reaches -30 but it
          touches column 0 -- must NOT be culled)
  slot 4  a stroke at y = -40 .. -26 (fully above the wall)

Every settled frame's wall must be exactly the pixels of slots 2 and 3
(painttest's stroke oracle), everything else black.  The structural
signal: the stroke walk must arm exactly once per commit that has an
on-wall stroke -- a culled slot that still armed a walk is the tick
cost the cull removes, and it shows here as an extra sOn rise.  The
probe also prints the settled-frame ticks so a walk that still runs
for the off-wall slots is visible in the pacing.

  python -u extras/screen/cullprobe.py [screen.ws]
"""
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "irrun"))
sys.path.insert(0, HERE)

from irsims import share_dump, _extract  # noqa: E402
from painttest import fresh_sim, slide3, stroke_pixels, close  # noqa
from watchdog import make_watch          # noqa: E402

WS = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 \
    and sys.argv[1] != "trace" else os.path.join(HERE, "screen.ws")

OFF_X = [-40.0, 8.0, 0.0, -26.0, 40.0, 0.0, -33.0, 24.0, 0.0]
ZAG = [8.0, 8.0, 0.0, 24.0, 20.0, 0.0, 8.0, 32.0, 0.0]
EDGE = [0.0, 32.0, 0.0, -30.0, 32.0, 0.0]
OFF_Y = [8.0, -40.0, 0.0, 24.0, -26.0, 0.0, 16.0, -33.0, 0.0]
CY = (0.0, 1.0, 1.0, 1.0)
MA = (1.0, 0.0, 1.0, 1.0)
OR = (1.0, 0.6, 0.0, 1.0)
GR = (0.0, 1.0, 0.0, 1.0)
BLACK = (0.0, 0.0, 0.0, 1.0)

# The chip dims colours by the live brightness factor (FULL_BRIGHT at
# brightness 100), so the expectation is the pushed colour times BF --
# the same convention animprobe checks.
BF = 0.35


def dim(c):
    return tuple(BF * v if k < 3 else v for k, v in enumerate(c))


def want_wall():
    """pixel index -> expected colour for the committed picture."""
    want = [BLACK] * 4096
    for i in stroke_pixels(ZAG[:2] + ZAG[3:5] + ZAG[6:8]):
        want[i] = dim(CY)
    for i in stroke_pixels(EDGE[:2] + EDGE[3:5]):
        want[i] = dim(OR)
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

        def stage(t, sid, pts, col, draw):
            plan[t] = {"shapePoints": list(pts),
                       "shapeColors": [col] * (len(pts) // 3),
                       "shapeWireMode": True, "shapeId": float(sid),
                       "shapePosition": (0.0, 0.0, 0.0),
                       "shapeRotation": (0.0, 0.0, 0.0),
                       "shapeScale": (0.0, 0.0, 0.0),
                       "parentShapeId": 0.0}
            plan[t + 2] = {"pushShape": True}
            plan[t + 4] = {"pushShape": False}
            if draw:
                plan[t + 6] = {"drawAllShapes": True}
                plan[t + 8] = {"drawAllShapes": False}

        stage(10, 1, OFF_X, GR, True)
        stage(120, 2, ZAG, CY, True)
        stage(230, 3, EDGE, OR, True)
        stage(340, 4, OFF_Y, MA, True)
        # four RE-PUSH commits of the same picture: every commit arms
        # all four stroke slots, and only slots 2 and 3 may walk.
        COMMITS = 4
        for k in range(COMMITS):
            t0 = 450 + 130 * k
            stage(t0, 1, OFF_X, GR, False)
            stage(t0 + 12, 2, ZAG, CY, False)
            stage(t0 + 24, 3, EDGE, OR, False)
            stage(t0 + 36, 4, OFF_Y, MA, True)

        settled = []
        walls = []
        state = {"was": False, "sPrev": False}
        sOn_rises = [0]

        def watch(sn, tick):
            wd(sn, tick)
            if tick in plan:
                step = dict(plan[tick])
                if "shapePoints" in step:
                    slide3(sn, pts_aid, cols_aid, step.pop("shapePoints"),
                           step.pop("shapeColors", None))
                sn.inputs = dict(sn.inputs, **step)
            act = any(bool(sn.vars.get(wvid[n])) for n in wvid)
            if state["was"] and not act:
                settled.append(tick)
                walls.append([sn.vars.get(gids[i], (0.0, 0.0, 0.0, 0.0))[:4]
                              for i in range(4096)])
            state["was"] = act
            sNow = bool(sn.vars.get(wvid["sOn"]))
            if sNow and not state["sPrev"]:
                sOn_rises[0] += 1
            state["sPrev"] = sNow

        sim.run(1100, on_tick=watch)

        # Every settled frame from the first commit (t=16 edge lag) on
        # must hold the full picture: slots 2 and 3 painted, nothing
        # else.  The very first settled frame is the idle window BEFORE
        # any paint -- skip nothing else.
        want = want_wall()
        bad = 0
        # Only frames past the FOURTH store + draw can hold the whole
        # picture; earlier settled frames legitimately miss slots.
        for t, wall in zip(settled, walls):
            if t <= 350:
                continue
            wrong = [i for i in range(4096) if not close(wall[i], want[i])]
            if wrong:
                print("t=%-5d wrong=%-4d first=%r got=%r want=%r"
                      % (t, len(wrong), wrong[0], wall[wrong[0]][:3],
                         want[wrong[0]][:3]))
                bad += len(wrong)
        print("settled at:", " ".join(str(t) for t in settled))
        gaps = [b - a for a, b in zip(settled, settled[1:])]
        print("settle gaps:", " ".join(str(g) for g in gaps))
        # sOn rises, by plan: the draw at t=10 arms no walk (only slot
        # 1, culled); the draw at 120 arms slot 2 (1); at 230 slots 2
        # and 3 (2); at 340 the same (2); each of the four re-pushed
        # commits arms slots 2 and 3 (2 each).  With the cull: 13.
        print("sOn rises: %d" % sOn_rises[0])
        if sOn_rises[0] != 13:
            print("sOn rises %d != 13 (off-wall strokes still walk)"
                  % sOn_rises[0])
            bad += 1
        print("RESULT: %s" % ("BUG" if bad else "ok"))
        return 1 if (bad or wd.failures()) else 0
    finally:
        os.unlink(dump)


if __name__ == "__main__":
    sys.exit(main())
