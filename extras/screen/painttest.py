"""Functional test for the wall screen: drive it, read the pixel globals.

Unlike the overlay variant, every gate here is sim-modelled, so there are no
mocks: the test pushes rects through the real protocol and reads the real
per-pixel globals (g0..g4095) the save wires to the decals.

  python -u extras/screen/painttest.py   (exit 0 = all green)
"""
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "irrun"))

from irsims import (  # noqa: E402
    ChipRunner,
    share_dump,
    sim_from_dump,
    _extract,
)

WS = os.path.join(HERE, "screen.ws")
SW = 64
BLACK = (0.0, 0.0, 0.0, 1.0)
RED = (1.0, 0.0, 0.0, 1.0)


def fresh_sim(dump_path):
    sim = sim_from_dump(dump_path)
    sim.reset()
    gids = {}
    recton = None
    for nid, nd in sim.nodes.items():
        lb = _extract(nd.props.get("_label", ("raw", "")))
        if not isinstance(lb, str):
            continue
        if lb.startswith("g") and lb[1:].isdigit():
            gids[int(lb[1:])] = nid
        elif lb == "rectOn":
            recton = nid
    assert len(gids) == SW * SW, "globals found: %d" % len(gids)
    assert recton is not None, "no rectOn var"
    return sim, gids, recton


def col(sim, gids, i):
    v = sim.vars.get(gids[i], (0.0, 0.0, 0.0, 0.0))
    if isinstance(v, (tuple, list)) and len(v) >= 4:
        return tuple(float(x) for x in v[:4])
    return v


def pulse_at(plan):
    def hook(sim_now, tick):
        if tick in plan:
            sim_now.inputs = dict(sim_now.inputs, **plan[tick])
    return hook


def expect(cond, label, detail=""):
    print("%-34s %s %s" % (label, "OK  " if cond else "FAIL",
                           detail if not cond else ""))
    return cond


def main():
    with tempfile.NamedTemporaryFile(suffix=".pkl", delete=False) as f:
        dump_path = f.name
    ok = True
    try:
        share_dump(WS, dump_path)

        base = {"rectColor": RED, "rectX0": 0.0, "rectY0": 0.0,
                "rectX1": 3.0, "rectY1": 2.0, "pushRect": False,
                "redrawAll": False}
        plan = {10: {"pushRect": True}, 12: {"pushRect": False},
                14: {"redrawAll": True}, 16: {"redrawAll": False}}

        # A. a 4x3 red rect lands in fb and shows on the globals.
        sim, gids, recton = fresh_sim(dump_path)
        sim.inputs = dict(base)
        sim.run(40, on_tick=pulse_at(plan))
        want = {r * SW + c for r in range(3) for c in range(4)}
        got = {i for i in want if col(sim, gids, i) == RED}
        ok &= expect(got == want, "rect paints its pixels",
                     "missing %d of 12" % (len(want - got),))
        ok &= expect(col(sim, gids, 4) == BLACK and
                     col(sim, gids, 1000) == BLACK,
                     "rest stays black", "")

        # B. clipping: a rect hanging off the corner paints only inside.
        sim, gids, recton = fresh_sim(dump_path)
        sim.inputs = dict(base, rectX0=60.0, rectY0=60.0,
                          rectX1=70.0, rectY1=70.0)
        sim.run(60, on_tick=pulse_at(plan))
        want = {r * SW + c for r in range(60, 64) for c in range(60, 64)}
        got = {i for i in want if col(sim, gids, i) == RED}
        ok &= expect(got == want, "clip to the grid",
                     "missing %d of 16" % (len(want - got),))
        ok &= expect(col(sim, gids, 59 * SW + 59) == BLACK,
                     "outside stays black", "")

        # C. alpha rides along untouched.
        green = (0.0, 1.0, 0.0, 0.5)
        sim, gids, recton = fresh_sim(dump_path)
        sim.inputs = dict(base, rectColor=green, rectX1=0.0, rectY1=0.0)
        sim.run(40, on_tick=pulse_at(plan))
        ok &= expect(col(sim, gids, 0) == green, "alpha flows end to end",
                     "got %r" % (col(sim, gids, 0),))

        # D. a full-screen rect paints; then silence -- there is no timer, no
        # keepalive, nothing that re-arms.  Brick colors persist until
        # rewritten, so re-arming would only re-emit identical values.
        base5 = dict(base, rectX1=63.0, rectY1=63.0)
        sim, gids, recton = fresh_sim(dump_path)
        sim.inputs = dict(base5)
        on = []

        def watch(sn, tick):
            if tick in plan:
                sn.inputs = dict(sn.inputs, **plan[tick])
            if sn.vars.get(recton):
                on.append(tick)

        sim.run(1100, on_tick=watch)
        ok &= expect(any(14 <= t <= 90 for t in on),
                     "redrawAll bursts the rect",
                     "bursts at %r" % (on[:8],))
        ok &= expect(all(col(sim, gids, i) == RED for i in (0, 1000, 4095)),
                     "full screen went red", "")
        ok &= expect(not any(200 <= t <= 1000 for t in on),
                     "silence after the burst",
                     "bursts at %r" % ([t for t in on if t > 200][:8],))

        # E. one burst, then nothing forever: no timer exists anymore.
        sim, gids, recton = fresh_sim(dump_path)
        sim.inputs = dict(base)
        on = []

        def watch2(sn, tick):
            if tick in plan:
                sn.inputs = dict(sn.inputs, **plan[tick])
            if sn.vars.get(recton):
                on.append(tick)

        sim.run(600, on_tick=watch2)
        ok &= expect(any(14 <= t <= 40 for t in on), "burst paints once",
                     "bursts at %r" % (on[:8],))
        ok &= expect(not any(t > 60 for t in on), "silence after the burst",
                     "bursts at %r" % ([t for t in on if t > 60][:8],))

        # F. redrawAll alone replays the last rect (full-screen: unmissable).
        sim, gids, recton = fresh_sim(dump_path)
        sim.inputs = dict(base5)
        on = []

        def watch3(sn, tick):
            if tick in plan:
                sn.inputs = dict(sn.inputs, **plan[tick])
            if tick == 210:
                sn.inputs = dict(sn.inputs, redrawAll=True)
            if tick == 212:
                sn.inputs = dict(sn.inputs, redrawAll=False)
            if sn.vars.get(recton):
                on.append(tick)

        sim.run(320, on_tick=watch3)
        ok &= expect(any(205 <= t <= 285 for t in on),
                     "redrawAll replays the last rect",
                     "bursts at %r" % (on,))
        ok &= expect(not any(100 <= t <= 200 for t in on),
                     "silence between the two shows",
                     "bursts at %r" % ([t for t in on if 100 <= t <= 200],))

        # G. a bare chip paints nothing and leaves every pixel black.
        sim, gids, recton = fresh_sim(dump_path)
        sim.inputs = {}
        sim.run(200)
        ok &= expect(all(col(sim, gids, i) == BLACK
                         for i in (0, 100, 1000, 4095)),
                     "bare chip stays black", "")
        ok &= expect(not sim.vars.get(recton), "painter never arms", "")
    finally:
        os.unlink(dump_path)
    print("painttest: %s" % ("ALL GREEN" if ok else "FAILURES"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
