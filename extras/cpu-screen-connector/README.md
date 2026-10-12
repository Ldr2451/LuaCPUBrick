# cpu-screen-connector

A bridge chip between the Lua CPU and the screen: Lua-named inputs,
screen-named outputs, no state at all.  Wire it once and the two chips
talk; the mapping is a few dozen gates (78 nodes).

```
connector.ws              the chip, hand-written -- fixed logic, no generator
connector.brz             the shippable artifact, built by build.py
build.py                  python -u extras/cpu-screen-connector/build.py
connectortest.py          three-chip chain: driver -> connector -> screen
```

## The interface

```
            outNum1 --|           |-- pushShape
            outNum2 --| connector |-- redrawAll
            outNum3 --|           |-- clearAll
            outNum4 --|           |-- wireMode
            outStr1 --|           |-- shapeId
          outNumArr --|           |-- shapeColor
                      |           |-- shapePoints
```

`outNum1`/`outNum2`/`outNum3` pulse push/redraw/clear straight through
(nonzero reads true); `outNum4` holds wire mode (nonzero = stroke) and
`outStr1` the slot id as text (`"0"`..`"8"`, empty = immediate), parsed
here -- the parse is pure, costs ~2 nodes, and keeps strings out of the
screen's hot path.  All three default to off, so drivers that never
touch them -- like `anim.lua` -- behave exactly as before.

`outNumArr` carries colour first, then only the points the shape needs
(1-based Lua slots):

```
1..4   colour r, g, b, a
5..    points x1, y1, x2, y2, ... (at most 16 points)
5+2k   one -1 terminator in the x slot after the last point
```

A triangle is two calls: `outNumArr(1, r,g,b,a)` and
`outNumArr(5, x1,y1, x2,y2, x3,y3, -1)`.  The first x below -0.5 ends
the list, so stale slots past it (zeros from earlier shapes) can never
leak in as `(0,0)` points; a terminator straight at slot 5 is the
empty shape (paints nothing, deletes a retained slot).  The colour
elements feed a real `Color` output -- the one thing the Lua chip
cannot emit itself -- and the points are truncated to a tight array
the screen's length-based count reads directly.  Everything is
combinational except a one-tick array pass, and nothing is retained:
every output is a pure function of the current inputs.

## Running the test

```
python -u extras/cpu-screen-connector/connectortest.py   (~10 min)
```

A small Lua driver pushes a fill, a stroke (via `outNum4`), a retained
store (via `outStr1`) and the clear pulse (via `outNum3`) through all
three chips; the wall is diffed against the protocol model.
