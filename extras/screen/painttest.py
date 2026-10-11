"""Functional test for the rect-fill screen: drive it, watch the pixels.

The sim cannot execute the two native game gates this chip leans on
(DisplayText draws the pixel, GetFromEntity resolves the viewer), so this
models both minimally instead of pretending they run:

  GetFromEntity  answers a fixed controller sentinel, whatever the input.
  DisplayText    records (textId -> text, x, y, color) and advances the chain.

Everything else -- the pushRect/redraw protocol, the painter walk, clipping,
directions, the keepalive sweep -- is the real compiled graph, so an assertion
about WHICH textIds show WHICH color WHERE is an assertion about the chip.

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
    Sim,
    _as_float,
    _as_int,
    _extract,
    share_dump,
    sim_from_dump,
)

WS = os.path.join(HERE, "screen.ws")

SW, SH, NP = 64, 64, 4096
MGX, MGY, CELL = 20.0, 20.0, 10.0
TIDB = 1000
LANES = 64

_orig_exec = Sim._exec_node


def _emit(self, nid, port="ExecOut"):
    for w in self.out_wires.get((nid, port), []):
        # nq is the third positional of _exec_node; recovered via the queue
        self.exec_queue.add((w.dst_id, w.dst_port))


def patched_exec(self, nid, node, nq):
    cls = node.cls
    if "PlayerState_DisplayText" in cls:
        tid = _as_int(self._in_val(nid, "TextId", 0))
        x = _as_float(self._in_val(nid, "Position.X", 0.0))
        y = _as_float(self._in_val(nid, "Position.Y", 0.0))
        ax = _as_float(self._in_val(nid, "Anchor.X", 0.5))
        ay = _as_float(self._in_val(nid, "Anchor.Y", 0.5))
        col = self._in_val(nid, "FontColor", (0.0, 0.0, 0.0, 1.0))
        if isinstance(col, (tuple, list)) and len(col) >= 4:
            col = tuple(round(_as_float(v), 6) for v in col[:4])
        else:
            col = (round(_as_float(col), 6), 0.0, 0.0, 1.0)
        self.overlay_log.append((self.tick, tid, round(x, 6),
                                 round(y, 6), col, round(ax, 6),
                                 round(ay, 6)))
        for w in self.out_wires.get((nid, "ExecOut"), []):
            nq.add((w.dst_id, w.dst_port))
        return
    if "PlayerState_GetFromEntity" in cls:
        self._out_val(nid, "PlayerState", ("controller", 0))
        for w in self.out_wires.get((nid, "ExecOut"), []):
            nq.add((w.dst_id, w.dst_port))
        return
    return _orig_exec(self, nid, node, nq)


Sim._exec_node = patched_exec


def fresh_sim(dump_path):
    sim = sim_from_dump(dump_path)
    sim.overlay_log = []
    sim.reset()
    return sim


def pulse_at(plan):
    """on_tick hook from {tick: {key: value}}."""
    def hook(sim_now, tick):
        if tick in plan:
            sim_now.inputs = dict(sim_now.inputs, **plan[tick])
    return hook


def run_case(dump_path, base, plan, ticks):
    sim = fresh_sim(dump_path)
    sim.inputs = dict(base)
    sim.run(ticks, on_tick=pulse_at(plan))
    return sim


def expect(cond, label, detail=""):
    print("%-34s %s %s" % (label, "OK  " if cond else "FAIL",
                           detail if not cond else ""))
    return cond


def pos(col, row, ax=0.0, ay=0.0):
    x = MGX + col * CELL
    y = MGY + row * CELL
    if ax > 0.5:
        x = -x
    if ay > 0.5:
        y = -y
    return (round(x, 6), round(y, 6))


def main():
    with tempfile.NamedTemporaryFile(suffix=".pkl", delete=False) as f:
        dump_path = f.name
    ok = True
    try:
        share_dump(WS, dump_path)
        red = (1.0, 0.0, 0.0, 1.0)

        # A. a 4x3 red rect paints exactly its 12 pixels, where they belong.
        # Window starts at the redraw edge with slack for the hook's one-tick
        # shift; the keepalive sweep also emits, so the assertion is presence
        # of the exact tuples (sweep re-emits the same ones, identically).
        base = {"player": "P1", "rectColor": red, "rX0": 0.0, "rY0": 0.0,
                "rX1": 3.0, "rY1": 2.0, "pushRect": False, "redraw": False,
                "posLeft": True, "posUp": True, "persistAll": True}
        sim = run_case(dump_path, base, {
            10: {"pushRect": True}, 12: {"pushRect": False},
            14: {"redraw": True}, 16: {"redraw": False}}, 34)
        win = [(tid, x, y, col, ax, ay) for (t, tid, x, y, col, ax, ay) in sim.overlay_log
               if 14 <= t <= 30]
        want = set()
        for i in range(12):
            c, r = i % 4, i // 4
            x, y = pos(c, r)
            want.add((TIDB + r * SW + c, x, y, red))
        ok &= expect(want <= {(t, x, y, c) for (t, x, y, c, ax, ay) in win},
                     "rect paints its pixels",
                     "missing %d of 12" % (len(want - {(t, x, y, c) for (t, x, y, c, ax, ay) in win}),))
        ok &= expect(all(col != red or tid in {w[0] for w in want}
                         for (tid, x, y, col, ax, ay) in win),
                     "nothing else paints red", "")
        ok &= expect(all((ax, ay) == (0.0, 0.0) for (t, x, y, c, ax, ay) in win),
                     "top-left anchor on every emission", "")

        # B. directions mirror the grid: bottom-right anchors (1, 1).
        base2 = dict(base, posLeft=False, posUp=False)
        sim = run_case(dump_path, base2, {
            10: {"pushRect": True}, 12: {"pushRect": False},
            14: {"redraw": True}, 16: {"redraw": False}}, 34)
        win = [(tid, x, y, ax, ay) for (t, tid, x, y, col, ax, ay) in sim.overlay_log
               if 14 <= t <= 30 and col == red]
        want = set()
        for i in range(12):
            c, r = i % 4, i // 4
            x, y = pos(c, r, 1.0, 1.0)
            want.add((TIDB + r * SW + c, x, y))
        ok &= expect(want <= {(t, x, y) for (t, x, y, ax, ay) in win},
                     "directions mirror the grid",
                     "missing %d of 12" % (len(want - {(t, x, y) for (t, x, y, ax, ay) in win}),))
        ok &= expect(all((ax, ay) == (1.0, 1.0) for (t, x, y, ax, ay) in win),
                     "bottom-right anchor on every emission", "")

        # C. clipping: a rect hanging off the grid paints only inside.
        base3 = dict(base, rX0=60.0, rY0=60.0, rX1=70.0, rY1=70.0)
        sim = run_case(dump_path, base3, {
            10: {"pushRect": True}, 12: {"pushRect": False},
            14: {"redraw": True}, 16: {"redraw": False}}, 34)
        reds = {(tid, x, y) for (t, tid, x, y, col, ax, ay) in sim.overlay_log
                if 14 <= t <= 30 and col == red}
        want = set()
        for r in range(60, 64):
            for c in range(60, 64):
                x, y = pos(c, r)
                want.add((TIDB + r * SW + c, x, y))
        ok &= expect(reds == want, "clip to the screen",
                     "got %d want 16" % len(reds))

        # D. alpha rides along: a half-transparent green stays half.
        green = (0.0, 1.0, 0.0, 0.5)
        base4 = dict(base, rectColor=green, rX1=0.0, rY1=0.0)
        sim = run_case(dump_path, base4, {
            10: {"pushRect": True}, 12: {"pushRect": False},
            14: {"redraw": True}, 16: {"redraw": False}}, 34)
        cols = {col for (t, tid, x, y, col, ax, ay) in sim.overlay_log
                if 14 <= t <= 30 and tid == TIDB}
        ok &= expect(green in cols, "alpha flows end to end",
                     "got %r" % (cols,))

        # E. persistAll=true keeps sweeping; the full frame passes in 64 ticks.
        sim = run_case(dump_path, base, {
            10: {"pushRect": True}, 12: {"pushRect": False},
            14: {"redraw": True}, 16: {"redraw": False}}, 14 + 1 + 64 + 4)
        seen = {tid for (t, tid, x, y, col, ax, ay) in sim.overlay_log
                if t >= 15}
        ok &= expect(len(seen) == NP, "keepalive covers the frame",
                     "got %d want %d" % (len(seen), NP))
        n_before = len(sim.overlay_log)
        sim.run(64)
        ok &= expect(len(sim.overlay_log) > n_before,
                     "sweep continues while persistAll",
                     "no emissions after %d" % n_before)

        # G. sweep POSITIONS: every pixel of the full pass lands on the grid
        # formula, not just on distinct ids.  This is the scenario the first
        # version never checked -- ids alone cannot see a collapsed row.
        at = {}
        for (t, tid, x, y, col, ax, ay) in sim.overlay_log:
            if t >= 15:
                at[tid] = (x, y)
        bad = 0
        for p in range(NP):
            c, r = p % SW, p // SW
            x, y = pos(c, r)
            if at.get(TIDB + p) != (x, y):
                bad += 1
                if bad < 4:
                    print("   misplaced %d: got %r want (%r, %r)" % (
                        TIDB + p, at.get(TIDB + p), x, y))
        ok &= expect(bad == 0 and len(at) == NP, "sweep lands on the grid",
                     "%d misplaced of %d" % (bad, NP))

        # F. persistAll=false: one pass after the update, then silence.
        base6 = dict(base, persistAll=False)
        sim = fresh_sim(dump_path)
        sim.inputs = dict(base6)
        sim.run(140, on_tick=pulse_at({
            10: {"pushRect": True}, 12: {"pushRect": False},
            14: {"redraw": True}, 16: {"redraw": False}}))
        tail = [t for (t, tid, x, y, col, ax, ay) in sim.overlay_log if t > 82]
        ok &= expect(not tail, "no sweep without persistAll",
                     "%d late emissions" % len(tail))
        lit = [e for e in sim.overlay_log if 14 <= e[0] <= 82]
        ok &= expect(len({e[1] for e in lit}) == NP,
                     "update re-shows the frame once",
                     "got %d ids" % len({e[1] for e in lit}))
    finally:
        os.unlink(dump_path)
    print("painttest: %s" % ("ALL GREEN" if ok else "FAILURES"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
