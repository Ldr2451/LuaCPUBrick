# cpu-screen-connector

A bridge chip between the Lua CPU and the screen: Lua-named inputs,
screen-named outputs, no state at all.  Wire it once and the two chips
talk; the mapping is a few hundred gates (279 nodes).

```
connector.ws              the chip, hand-written -- fixed logic, no generator
connector.brz             the shippable artifact, built by build.py
build.py                  python -u extras/cpu-screen-connector/build.py
connectortest.py          three-chip chain: driver -> connector -> screen
```

## The interface

```
             outNum1 --|           |-- pushShape
             outNum2 --| connector |-- drawAll
             outNum3 --|           |-- clearAll
             outNum4 --|           |-- wireMode
             outStr1 --|           |-- shapeId
           outNumArr --|           |-- shapeColors
             outStr2 --|           |-- shapePoints
           outStrArr --|           |-- position
                       |           |-- rotation
                       |           |-- scale
                       |           |-- parentShapeId
```

`outNum1`/`outNum2`/`outNum3` pulse push/draw/clear straight through
(nonzero reads true); `outNum4` holds wire mode (nonzero = stroke) and
`outStr1` the slot id as text (`"0"`..`"8"`, empty = immediate), parsed
here -- the parse is pure, costs ~2 nodes, and keeps strings out of the
screen's hot path.  All three default to off, so drivers that never
touch them -- like `anim.lua` -- behave exactly as before.

`outNumArr` carries POINTS FIRST, then the colours, separated by one
terminator (1-based Lua slots):
```
1..2k   points x1, y1, x2, y2, ... (at most 16 points)
2k+1    terminator: any value <= -1 in the x slot after the last
        point.  Its magnitude carries the colour count: -1 means NO
        colours (every point defaults to white), -(1+c) means c
        colours follow.
2k+2..  colours r1, g1, b1, a1, ... four per point
```

A white triangle is one call: `outNumArr(1, x1,y1, x2,y2, x3,y3, -1)`.
A per-point coloured one encodes the count in the terminator and adds
the colours: `outNumArr(1, x1,y1, x2,y2, x3,y3, -4, r,g,b,a, r,g,b,a,
r,g,b,a)`.  The count matters because `outNumArr` is a fixed
16,384-slot port: unwritten slots hold whatever the last shape left
there, so a fixed-width colour read would paint stale floats as
colours -- the magnitude is what tells the bridge there is nothing to
read, and a colourless driver keeps writing the plain `-1` it always
did.  Two more Lua-side limits to know: `outNumArr` takes at most 8
values per call (a 16-colour shape is two calls), and valid
coordinates are 0..63 so any value <= -1 is unambiguous.

The first x below -0.5 ends the point scan, so stale slots past it can
never leak in as `(0,0)` points; forgetting the terminator reads up to
16 points, all white.  A terminator straight at slot 1 is the empty
shape (paints nothing, deletes a retained slot).  The colour floats
feed real `Color` outputs -- the one thing the Lua chip cannot emit
itself -- and the points are truncated to a tight array the screen's
length-based count reads directly.

`outStr2` carries the parent slot id as text (`"0"`..`"8"`, empty =
no parent), parsed the same pure way as `outStr1`.  `outStrArr`
carries the transform as nine numeric strings (1-based slots):

```
1..3   position x, y, z (only x and y are used)
4..6   rotation x, y, z (only z, radians about the origin)
7..9   scale x, y, z (only x and y; zeroes mean identity)
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
transform would otherwise inherit the mover's.  `showcase2.lua` has
a tiny `xf()` helper that keeps this tidy.

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
