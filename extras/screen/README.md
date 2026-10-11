# screen: a 64x64 rect-fill pixel screen with no outputs

Pixels are player-screen overlay texts (`DisplayText` gates with stable
textIds), repainted in place -- so nothing in the graph scales with the pixel
count.  64x64 at 64 painter lanes is 3,417 nodes.

## Files

- `gen.py` -- the source of truth.  `python -u extras/screen/gen.py [lanes]`
  writes `screen.ws`.  Edit the consts at the top, not the generated file.
- `screen.ws` -- generated.
- `screen.brz` -- built by `python -u extras/screen/build.py`.  This is what
  the game imports.
- `painttest.py` -- functional test.  The sim cannot run the two native game
  gates, so it models both (`DisplayText` records, `ControllerOf` answers)
  and asserts the real graph paints, clips, mirrors, keeps alive, and goes
  quiet.  `python -u extras/screen/painttest.py` (exit 0 = green).

## Protocol

`pushRect` latches the rect (color + bounds). `redraw` paints it.  Two signals
so a driver can write params across ticks and commit atomically -- no torn
rects.  Bounds are normalized (x0>x1 works) and clipped; a fully off-screen
rect paints nothing.  `posLeft`/`posUp` pick the anchor corner as screen
fractions (0 = left/top, 1 = right/bottom), and every pixel offsets INWARD
from it in slate units (~pixels at 1080p): a 20 + 63*10 = 650-unit grid fits
a 1080p screen from any corner.  `persistAll=true` runs a keepalive sweep so
pixels never expire; `persistAll=false` re-shows the frame once per input
update and lets it expire after `LIFE`.  A bare chip (nothing wired) is
silent: `persistAll` latches false and no sweep runs.

No `prev` edge flags anywhere: `on Change` fires only on a transition, so the
event IS the edge.  A same-handler read-then-write of one var (`prevX = x`
under the branch that reads it) loses the race -- the write lands first and
every real edge evaluates false.  Cross-handler flags (`pending`, `rectOn`)
are fine.

## Timing (60Hz game)

64 lanes paint 64 px/tick: a 10x10 rect lands in 2 ticks, a full repaint in 64
(~1s).  The keepalive sweep re-emits the frame every 64 ticks, which must stay
under `LIFE` (10s) or pixels expire.

## Tuning consts (top of gen.py)

`MGX`/`MGY`/`CELL` place the grid (margin + cell size in slate units), `FSIZE` should match `CELL`, `TIDB`
must not collide with other overlays on the same screen, `LANES` is the speed
knob at ~45 nodes a lane.  One chip shows to ONE player: wire that viewer's
character into `player`.

## First light (in-game order)

1. Wire `player` only.  Expect NOTHING: the bare chip is silent by design.
   Any motion here is game-side, not the chip.
2. Wire `persistAll=true`.  Expect the full white grid to sweep on, row by
   row, and stay.
3. Push a small red rect, `redraw`.  Expect a red square inside the grid.

## In-game checklist

- `FSIZE`/`CELL` vs the font's advance: if columns drift or glyphs overlap,
  they disagree about the glyph width.  Overlap also reads as one blobby
  "line" where a square should be.
- Coordinate range: the grid spans 650 slate units (~650px at 1080p) inward
  from the anchored corner.  Pixels outside the visible area simply never
  show -- a partial grid means the anchor/margins are off, not that painting
  stopped.  The old center-anchored scheme put most of a 64-wide grid
  off-screen; if you see a fragment, check `MGX`/`MGY` first.
- `pushRect`/`redraw` are bool ports; a driver with no bool output can try a
  1.0/0.0 float, else they want float edge-detect inputs.
- `textId`s from `TIDB` must be exclusive to this chip per viewer, AND to its
  past runs: stale overlays from an earlier import share the id space until
  they expire, so back-to-back tests can look inconsistent.
- Alpha: the color channel flows end to end (tested to 0.5 in-sim); whether
  the overlay renders it see-through is the one thing only the game can say.
- Orientation: the anchor fractions are absolute (0 = left/top per the
  compiler docs), so the grid cannot mirror -- but which corner is which on
  YOUR screen is unverified.  If top-left settings draw bottom-left, say so
  and the anchor mapping gets corrected.
