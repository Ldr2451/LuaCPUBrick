# screen: a 64x64 rect-fill pixel screen for a decal-free wall

One color output per pixel (`px0`..`px4095`), each wired in the save to one
brick's property changer.  No decals, no text, no fonts: each pixel IS its
microbrick, dyed by wire.  A plain brick exposes no wire ports, so the
changer component is the mandatory endpoint -- brick color is save data, not
a port, and there is no way to drive it without the component.

The wall itself (bricks, changers, wires) is NOT compilable -- the emitter
only emits the microchip, logic gates and ports -- so a helper appends it to
`screen.brz` afterwards (see "Wall" below).  What the compiler CAN do is the
whole chip: a rect painter into a framebuffer plus a generated straight-line
scanout into the pixel globals, because a computed pixel index cannot address
ports and an if-chain past ~16 arms stops taking effect.  64x64 lands ~17.7k
nodes.

## Files

- `gen.py` -- the source of truth.  `python -u extras/screen/gen.py [lanes]`
  writes `screen.ws`.  Edit the generator, not the generated file.
- `screen.ws` -- generated.  The chip only: painter, scanout, protocol.
- `screen.brz` -- the shippable artifact: chip + wall, built with the
  `--wall` compiler flag (see "Wall" below).  This is what the game imports.
- `compiler-wall.patch` + `compiler-wall.rs` -- the compiler fork diff that
  makes `--wall` exist, recorded so the fork is reproducible byte-for-byte.
- `painttest.py` -- functional test.  Every gate here is sim-modelled, so
  there are no mocks: it pushes rects through the real protocol and reads the
  real pixel globals.  `python -u extras/screen/painttest.py` (exit 0 =
  green, 12 scenarios).

## Protocol

`pushRect` latches one rect (color + bounds `rectX0/rectY0/rectX1/rectY1`).
`redrawAll` paints the CURRENT drawing: the latched rect, else the last rect
again.  Two signals so a driver can write params across ticks and commit
atomically -- no torn rects.  Bounds are normalized (x0>x1 works) and
clipped; a fully off-screen rect paints nothing.  Brick colors persist until
rewritten, so there is no keepalive, no timer, no expiry: the chip emits one
rect burst per trigger and is silent otherwise.  A bare chip paints nothing;
every pixel starts black.

No `prev` edge flags anywhere: `on Change` fires only on a transition, so the
event IS the edge.  A same-handler read-then-write of one var (`prevX = x`
under the branch that reads it) loses the race -- the write lands first and
every real edge evaluates false.  Cross-handler flags (`pending`, `rectOn`)
are fine.  Sequential arms are kept flat (depth-1) throughout.

## Timing (60Hz game)

64 lanes paint 64 px/tick: a 10x10 rect lands in 2 ticks, a 41x41 rect in
~27, a full screen in 64 (~1s).  `LANES` is the speed knob at ~6 nodes a
lane.  The chip emits one rect burst per trigger and is silent otherwise.

## Tuning consts (top of gen.py)

Only `LANES` matters now.  Placement is physical: the wall builder lays the
64x64 bricks, so there are no screen coordinates here.

## Wall (emitted by the compiler, not compiled)

4096 `PB_DefaultMicroBrick` 1x1x1 cubes in a 64x64 square at 2-unit pitch,
each carrying one `Component_BrickPropertyChanger`, each changer's `Color`
wired 1:1 to one `px` output. Bricks are visible (they ARE the pixels),
without collision, black -- brick save colour black AND changer struct
`Color` black (the struct default is light grey 200,200,200, so a dataless
stub would paste a grey wall until the first paint).

The emitter only emits chip logic, so the wall is a `--wall` post-pass in a
small compiler fork (base commit `0ae21e4` in the checkout the sim tools
already use). The fork diff is on this branch: `compiler-wall.patch` (5
files) plus `compiler-wall.rs` (the new `emit/wall.rs`, reproduced whole).
It stacks on the fork's pre-existing sim-support hunks (`dump_ir_full`).

Build (needs the patched binary; `WIRESCRIPT` overrides the toolchain the
same way for every other tool here):

```
set WIRESCRIPT=<fork>\target\release\wirescript.exe
wirescript compile extras/screen/screen.ws -o extras/screen/screen.brz --wall px:64x64
```

No RGB splitting: the changer takes a composite `Color` input, so one
colour wire per pixel. The `Color.R/G/B/A` sub-ports exist but would triple
the wire count for no benefit. No array output either: a wire addresses one
(brick, component, port) triple and there are no per-element endpoints, so
an array port cannot fan out to 4096 changers -- 4096 scalar colour outputs
is the design, not a workaround.

Contract the pass satisfies (all verified by re-parsing the artifact):

- pixel `i` = brick (col `i%64`, row `i/64`), row 0 at top (high Z), wall
  centred on the chip in X/Z at fixed Y (+16, clear of shell and pins).
- every wall wire is `MicrochipOutput.RER_Output -> Changer.Color`, drawn
  through the same fan-in/port choke point as all other wires.
- `check_no_overlap` covers the wall (procedural bricks use their own size
  as extent -- the catalog's 5,5,2 changer footprint is its dump host's,
  not the microbrick's, and applying it false-fires on any spaced wall).
- chip ports, painter and protocol untouched: without `--wall` the world is
  byte-identical to the stock compiler's output.

Measured on the shipped `screen.brz`: 4096 changer structs all
`Color=(0,0,0,255)`; 4096 changer wires + 4096 pin wires on the outer grid;
70,366 wire endpoints re-validated against the game loader's own resolution
rules, 0 bad; `painttest` 14/14; chip still ~17.7k nodes.

## In-game checklist

- Pixels light with pushed colors, 1:1 with the grid.
- `pushRect`/`redrawAll` are bool ports; a driver with no bool output can try
  a 1.0/0.0 float, else they want float edge-detect inputs.
- Alpha: the color channel flows end to end (tested to 0.5 in-sim); whether a
  brick renders it see-through is game-only.
