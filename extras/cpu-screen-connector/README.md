# cpu-screen-connector

A bridge chip between the Lua CPU and the screen: Lua-named inputs,
screen-named outputs, no state at all.  Wire it once and the two chips
talk; the mapping is a few hundred gates (459 nodes, 868 wires).

```
lua chip out      connector in     connector out       screen in
--------------    ------------     -----------------   -----------------
outNumArr        -> outNumArr     -> pushShape        -> pushShape
                                  -> drawAllShapes    -> drawAllShapes
                                  -> clearAllShapes   -> clearAllShapes
                                  -> shapeWireMode    -> shapeWireMode
                                  -> shapeId          -> shapeId
                                  -> shapeColors     -> shapeColors
                                  -> shapePoints     -> shapePoints
                                  -> parentShapeId   -> parentShapeId
                                  -> shapePosition   -> shapePosition
                                  -> shapeRotation   -> shapeRotation
                                  -> shapeScale      -> shapeScale
                                  -> addToShapeInTicks -> addToShapeInTicks
```

The middle two columns are one chip: the single Lua-side port on the
left, screen-side outputs on the right -- 12 wires from connector to
screen in total, every one required.  The connector re-reads on
`ContainerChange(outNumArr)` (a `Change` trigger on the array never
fires -- WS059).  `addToShapeInTicks` is easy to miss because it has no
port of its own (it rides `outNumArr` slot 100); without that wire every
animation arm reads an instant push, the chip deletes instead of arming,
and retained shapes fall apart.  `brightness` on the screen stays
unwired (defaults bright).


Everything travels over ONE port pair -- the CPU's `outNumArr` numeric
array wired straight to the connector's. The driver only ever writes
that array; the CPU's other output ports stay free for other work (gfx
lua v2, and the samples, all speak it). `outNumArr` takes at most
8 values per call, slots are 1-based, and a slot keeps its last value
until written again -- which is why `stage` restates what matters:

```
1..m    point floats, ALWAYS triples: x1, y1, z1, ... (a flat shape
        carries z = 0; the screen reads the delivered length's parity
        as 2D/3D, so a closed 3D outline repeats the first vertex)
m+1     terminator: -1 = no colours (all white), -(1+c) = c colours
        follow; with the count stated at slot 98, coordinates are
        completely unrestricted
m+2..   colours r1, g1, b1, a1, ... four floats per point
98      point FLOAT count (the library writes it every push: a stale
        count would ghost-parse the next shape)
100     animation: 0 instant, N steps (one per repaint), -1 forever
200     push pulse: 1 stages the shape on the ports, 0 ends the pulse
201     draw pulse: 1 repaints every retained shape
202     clear pulse: 1 forgets every slot
203     wire mode: nonzero strokes an outline, 0 fills
204     slot id: 0 immediate, 1..32 a retained slot, -1 the camera
205     parent slot: 0 none, 1..32 a shape, -1 the camera (view space)
206..208  position x, y, z
209..211  rotation x, y, z in radians
212..214  scale x, y, z (zeroes mean identity)
```

A white triangle is one call: `outNumArr(1, x1,y1,z1, x2,y2,z2, x3,y3,z3,
-1)`.  A per-point coloured one encodes the count in the terminator and
adds the colours.  A terminator straight at slot 1 is the empty shape
(paints nothing, deletes a retained slot).

**3D**: send three floats per point and the screen reads the delivered
array's odd length as (x,y,z) triples -- it transforms each point's own
z through the whole parent chain, keeps the world z as the depth, and
projects with a perspective divide (eye at z = -48, denominator clamped
at 1.0).  Nothing else changes: no extra port, no mesh helper, no
triangulation.  Because a 2D array is always even, a 3D outline is sent
with an ODD number of points: a triangle needs nothing (three points,
nine floats), a quad is sent closed, four corners plus the first again
(five points, fifteen floats).  The chip projects the result, so the CPU
never computes a pixel.

ids, parents and the transform are NUMBERS in this protocol -- slots
204, 205 and 206..214 -- so no string port is involved anywhere; the
library converts `""`/nil to 0 (immediate / no parent).

One driver rule covers all three channels (points, colours,
transform): everything stages per push, so every push must carry its
full shape -- points, colours (or nothing, for white), and transform
(or identity).  Anything not restaged keeps whatever the last push
left behind: a background pushed after a mover frame without its own
transform would otherwise inherit the mover's.  The library in `gfx.lua`
keeps this tidy -- one call stages a full shape, so a frame is `stage`
then push-then-draw (`fire` does both pulses and waits):

```lua
-- gfx.lua v2: everything through outNumArr.
-- stage(pts, cols, xf, parent, ticks, wire, id): put one shape on the
-- array, ready for the next push.  pts is a flat list of point FLOATS
-- (three per point); stage2d takes PAIRS and appends the zeros.  cols is
-- optional (nil = all white), four floats per point.  xf is the nine-
-- number transform {px,py,pz, rx,ry,rz, sx,sy,sz} (nil = identity),
-- parent the slot id (-1/"" none), ticks the animation length (0/nil
-- instant, N repaints, -1 forever), wire nonzero = stroke, id the slot
-- to store (nil/"" = immediate).  Slots are sticky: stage writes 98,
-- 100, 203..205 and 206..214 on EVERY push.
-- A step lands at a repaint, not at a clock tick: the screen holds the
-- animation while it scans out a pass, so ticks counts frames.
stage({0,0,0, 8,0,0, 8,6,0, 0,6,0}, nil, {5,6,0, 0,0,0.5, 1,1,1}, "0", 30)
stagePush(...)  -- stage + the push pulse in one call
fire()          -- push pulse, draw pulse, nap(after)
editShape(id, pts, cols, xf, parent, ticks, wire)  -- store/edit a slot
pushMesh(points, pcols, faces, xf, parent, ticks, wire, firstId)
camera(xf, ticks)  -- move the view; camera(nil) forgets it
clearScreen(after) -- clear pulse, draw, nap
```

(`sample-programs/showcase2.lua` has the same shape with a tiny `xf()`
plus inline points: the mover's points never change, so only its
transform moves.)

**Under a tick count the whole stage is deltas**, including the
transform: `xf = {2,0,0, 0,0,0, 0,0,0}` moves a shape +2 x per repaint,
while `{0,0,0, 0,0,0, 1,1,1}` would grow its scale by 1 every repaint.
Leaving a slot unwritten parses as 0.0, which is the identity delta: a
shape whose transform is never restaged simply holds still.  So an
animated push must restate the slots it means to move -- and the first
push to a shape is instant (it is an establish, not a delta).

Everything is combinational except a one-tick array pass, and nothing
is retained: every output is a pure function of the current inputs.

## Running the test

```
python -u extras/cpu-screen-connector/connectortest.py   (~14 min)
```

A small Lua driver pushes a fill, a stroke (via slot 203), a moved
square (transform via slots 206..214, parent via slot 205), a retained
store (via slot 204) and the clear pulse (via slot 202) through all
three chips; the wall is diffed against the protocol model, and the
connector's own translation is spot-checked (tight points, the colour
slice behind the terminator, the parsed vecs and parent id).

## How long a draw takes (the handshake)

A `draw()` pulse arms a pass; the pass paints over many ticks (the fill
and stroke walks scan four rows at a tick, a redraw erases the old
coverage first).  The screen has no "done" output -- the contract is a
**wait**: after `draw()`, wait at least **224 ticks** -- the measured
worst pass -- before assuming the wall holds the whole picture, and
before the next `draw()` if you want the previous frame complete on
screen.

Measured worst waits, draw pulse to the tick every walk has fallen
(`extras/cpu-screen-connector/cubetest.py` with `CUBE_SETTLE=1`, and
asserted by `extras/screen/screenchecks.py`):

| pass | worst wait |
| --- | --- |
| filled redraw (mover, scale) | 23 ticks |
| wireframe cube redraw under a spinning pivot | 144 ticks |
| wave stroke redraw (curve, 11 points) | 100 ticks |
| tallest protocol stroke (13 colored points, full wall) | 224 ticks |

224 is the worst the protocol can make: the cost scales with how many
tall segments a wireframe has -- a stroke's walk rebuilds a segment every
tick, so steep segments dominate (both walks paint four rows a tick, and
a redraw paints every shape exactly once; the old worsts were 507 and
428).  A program that wants fast frames should push short strokes or
fills.  Game bodies pace with `nap(224)`, which now covers even the
zigzag; a program may wait as little as `nap(224)`.
