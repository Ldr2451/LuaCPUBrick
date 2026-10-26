# cpu-screen-connector

A bridge chip between the Lua CPU and the screen: Lua-named inputs,
screen-named outputs, no state at all.  Wire it once and the two chips
talk; the mapping is a few hundred gates (279 nodes).

```
lua chip out        connector in       connector out       screen in
-------------       -------------      -----------------   -----------------
outNum1            -> outNum1         -> pushShape        -> pushShape
outNum2            -> outNum2         -> drawAllShapes    -> drawAllShapes
outNum3            -> outNum3         -> clearAllShapes   -> clearAllShapes
outNum4            -> outNum4         -> shapeWireMode    -> shapeWireMode
outStr1            -> outStr1         -> shapeId          -> shapeId
outNumArr          -> outNumArr       -> shapeColors      -> shapeColors
outStr2            -> outStr2         -> parentShapeId    -> parentShapeId
outStrArr          -> outStrArr       -> shapePosition    -> shapePosition
                                         shapeRotation      -> shapeRotation
                                         shapeScale         -> shapeScale
                                         parentShapeId      -> parentShapeId
                                         addToShapeInTicks  -> addToShapeInTicks
```

The middle two columns are one chip: Lua-side inputs on the left,
screen-side outputs on the right -- 12 wires from connector to screen
in total, every one required.  `addToShapeInTicks` is easy to miss in
the diagram because it has no Lua-side row of its own (it rides
`outNumArr` slot 100); without that wire every animation arm reads an
instant push, the chip deletes instead of arming, and retained shapes
fall apart.  `brightness` on the screen stays unwired (defaults
bright).


`outNum1`/`outNum2`/`outNum3` pulse push/draw/clear straight through
(nonzero reads true); `outNum4` holds wire mode (nonzero = stroke) and
`outStr1` the slot id as text (`"0"`..`"32"`, `"-1"` the camera, empty =
immediate), and `outStr2` the parent the same way (`"-1"` hangs the shape
off the camera, in view space), parsed
here -- the parse is pure, costs ~2 nodes, and keeps strings out of the
screen's hot path.  All three default to off, so drivers that never
touch them -- like `anim.lua` -- behave exactly as before.

`outNumArr` carries POINTS FIRST, then the colours (1-based Lua slots):
```
1..m   point floats: x1, y1, ... two per point for a 2D shape, three
       (x, y, z) per point for a 3D one (at most 32 floats: 16 points
       of 2D, or 10 points of 3D; any values)
m+1    terminator: -1 means NO colours (all white), -(1+c) means c
       colours follow
m+2..  colours r1, g1, b1, a1, ... four per point
98     point FLOAT count (the library writes it; coordinates then have
       no restrictions at all, and it is how a 3D shape arrives)
100    animation ticks: 0 instant, N steps (one per repaint), -1 forever
```

A white triangle is one call: `outNumArr(1, x1,y1, x2,y2, x3,y3, -1)`.
A per-point coloured one encodes the count in the terminator and adds
the colours.  `outNumArr` takes at most 8 values per call.  A
terminator straight at slot 1 is the empty shape (paints nothing,
deletes a retained slot).

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

`outStr2` carries the parent slot id as text (`"0"`..`"8"`, empty =
no parent), parsed the same pure way as `outStr1`.  `outStrArr`
carries the transform as nine numeric strings (1-based slots):

```
1..3   shapePosition x, y, z (z is depth: nearer wins; with 3D points it
       is also what the perspective divide scales by)
4..6   shapeRotation x, y, z in radians (x/y tilt off-axis, z spins)
7..9   shapeScale x, y, z (zeroes mean identity; z scales depth)
```

Missing or garbage slots parse to 0.0, which the screen defaults, so
a driver that never touches `outStrArr` behaves exactly as before --
and a driver that only moves shapes writes just slots 1..2.
(`outStrArr` takes at most 8 values a call, like `outNumArr`, so all
nine slots are two calls.)

One driver rule covers all three channels (points, colours,
transform): everything stages per push, so every push must carry its
full shape -- points, colours (or nothing, for white), and transform
(or identity).  Anything not restaged keeps whatever the last push
left behind: a background pushed after a mover frame without its own
transform would otherwise inherit the mover's.  The helper below
keeps this tidy -- one call stages a full shape, so a frame is
`stage` then push-then-draw (`outStrArr` takes strings only, unlike
`outStr`, hence `tostring`; at most 8 values a call, hence the
chunking; functions take at most 8 parameters, hence the packed
`xf` table):

```lua
-- stage a full shape: points, terminator, colours (or nil = white),
-- transform as {px, py, ang, sx, sy}, parent slot ("0" = none),
-- animation ticks (nil/0 = instant, -1 = forever).  The tick count
-- rides slot 100 as a second terminator: 0 instant, -(1+T) animate
-- over T REPAINTS, -1 forever (until another command edits the slot).
-- A step lands at a repaint, not at a clock tick: the screen holds the
-- animation while it scans out a pass, so T is frames, the rate the eye
-- can actually see.
-- It is always written (even 0): an unwritten slot keeps the previous
-- push's value, which would ghost-animate later shapes.
local function putn(slot, t, first)
  local i = first or 1
  while i <= #t do
    outNumArr(slot + i - 1,
      table.unpack(t, i, math.min(i + 7, #t)))
    i = i + 8
  end
  return slot + #t
end
local function stage(pts, term, cols, xf, parent, ticks)
  local termAt = putn(1, pts)         -- points from slot 1
  outNumArr(termAt, term)             -- -1, or -(1 + colour count)
  if cols then                        -- four floats per point, or omit
    putn(termAt + 1, cols)
  end
  outStrArr(1, tostring(xf[1]), tostring(xf[2]), "0", "0", "0",
    tostring(xf[3]), tostring(xf[4]), tostring(xf[5]))
  outStrArr(9, "1")
  outStr(2, parent or "0")
  if ticks and ticks >= 1.0 then
    outNumArr(100, -(1.0 + ticks))
  else
    outNumArr(100, -1.0)
  end
end
-- stage({0,0, 8,0, 8,6, 0,6}, -5, {1,0,0,1, ...}, {5,6, 0.5, 2,2}, "3")
-- stage({0,0, 8,0}, -1, nil, {2,0, 0, 1,1}, "0", 30) -- +2 x/tick, 30 ticks
```

(`showcase2.lua` has the same shape as a tiny `xf()` plus inline
points: the mover's points never change, so only its transform moves.)

**Under a tick count the whole stage is deltas**, including the
transform: `xf = {2,0, 0, 0,0}` moves a shape +2 x per tick, while
`{0,0, 0, 1,1}` would grow its scale by 1 every tick.  Leaving a slot
unwritten parses as 0.0, which is the identity delta: a shape whose
transform is never restaged simply holds still.  So an animated push
must restate the slots it means to move — and the first push to a
shape is instant (it is an establish, not a delta).

Everything is combinational except a one-tick array pass, and nothing
is retained: every output is a pure function of the current inputs.

## Running the test

```
python -u extras/cpu-screen-connector/connectortest.py   (~14 min)
```

A small Lua driver pushes a fill, a stroke (via `outNum4`), a moved
square (transform via `outStrArr`, parent via `outStr2`), a retained
store (via `outStr1`) and the clear pulse (via `outNum3`) through all
three chips; the wall is diffed against the protocol model, and the
connector's own translation is spot-checked (tight points, the colour
slice behind the terminator, the parsed vecs and parent id).

## How long a draw takes (the handshake)

A `draw()` pulse arms a pass; the pass paints over many ticks (the fill
and stroke walks scan four rows at a tick, a redraw erases the old
coverage first).  The screen has no "done" output — the contract is a
**wait**: after `draw()`, wait at least **428 ticks** — the measured
worst pass — before assuming the wall holds the whole picture, and
before the next `draw()` if you want the previous frame complete on
screen.

Measured worst waits, draw pulse to the tick every walk has fallen
(`extras/cpu-screen-connector/cubetest.py` with `CUBE_SETTLE=1`, and
asserted by `extras/screen/screenchecks.py`):

| pass | worst wait |
| --- | --- |
| filled redraw (mover, scale) | 31 ticks |
| wireframe cube redraw under a spinning pivot | 168 ticks |
| wave stroke redraw (curve, 11 points) | 124 ticks |
| tallest protocol stroke (13 colored points, full wall) | 428 ticks |

428 is the worst the protocol can make: the cost scales with how many
tall segments a wireframe has — a stroke's walk rebuilds a segment every
tick, so steep segments dominate (both walks now paint four rows a tick,
which cut the old worst of 507).  A program that wants fast frames should
push short strokes or fills.  Game bodies pace with `nap(420)`, which
covers every typical pass; a full-wall zigzag needs `nap(428)`.
