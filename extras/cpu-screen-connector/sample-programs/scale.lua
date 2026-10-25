-- Scale over time: one shape grows evenly, one only sideways.
--
-- Scale is part of the transform, so the points never change: the square
-- is the same eight numbers at every frame and only shapeScale.xyz moves
-- (s, s, 1 -- even, so it stays square).  The bar proves the three
-- channels are independent: its x scale runs on its own table while y
-- stays 1, so it stretches into a plate and back without growing taller.
--
-- The small diamond is a CHILD of the square (slot 3, parent slot 1).
-- It is staged once and never sent again: the parent compose carries it,
-- so the offset is scaled with the parent and the diamond rides out and
-- back on the growing square -- scale is inherited, like position and
-- rotation.
clearScreen()
-- The square: centred on its own origin, closed, half-size 6.
local sq = {-6.0, -6.0, 6.0, -6.0, 6.0, 6.0, -6.0, 6.0, -6.0, -6.0}
-- The bar: half-size 3 by 4, so its two channels are visibly different.
local bar = {-3.0, -4.0, 3.0, -4.0, 3.0, 4.0, -3.0, 4.0, -3.0, -4.0}
-- The diamond that rides on the square, offset 3 along the parent's x
-- (inside the square's half-size 6 at every scale, so it never leaves
-- the square's outline as the square grows).
local dia = {0.0, -2.5, 2.5, 0.0, 0.0, 2.5, -2.5, 0.0, 0.0, -2.5}
-- One colour per point.
local scol = {0.25, 0.55, 1.0, 1.0, 0.25, 0.55, 1.0, 1.0,
              0.35, 0.70, 1.0, 1.0, 0.35, 0.70, 1.0, 1.0,
              0.25, 0.55, 1.0, 1.0}
local bcol = {1.0, 0.80, 0.25, 1.0, 1.0, 0.80, 0.25, 1.0,
              1.0, 0.65, 0.15, 1.0, 1.0, 0.65, 0.15, 1.0,
              1.0, 0.80, 0.25, 1.0}
local dcol = {1.0, 0.20, 0.85, 1.0, 1.0, 0.20, 0.85, 1.0,
              1.0, 0.20, 0.85, 1.0, 1.0, 0.20, 0.85, 1.0,
              1.0, 0.20, 0.85, 1.0}
-- The diamond once, offset in its parent's frame, so the square's scale
-- arrives at it through the compose.
stagePush2d(dia, dcol, {3.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0},
            "1", nil, 0, "3")
-- Two tables, one per frame: the square's even scale, the bar's x only.
local ss = {0.35, 0.60, 0.95, 1.35, 1.80, 2.20, 1.80, 1.35, 0.95, 0.60}
local xx = {0.40, 0.70, 1.10, 1.50, 1.90, 2.30, 1.90, 1.50, 1.10, 0.70}
local f = 0
while f < 10 do
  local s = ss[f + 1]
  stagePush2d(sq, scol,
              {18.0, 20.0, 0.0, 0.0, 0.0, 0.0, s, s, 1.0},
              "0", nil, 0, "1")
  stagePush2d(bar, bcol,
              {46.0, 44.0, 0.0, 0.0, 0.0, 0.0, xx[f + 1], 1.0, 1.0},
              "0", nil, 0, "2")
  draw()
  nap(420.0)
  f = f + 1
end
