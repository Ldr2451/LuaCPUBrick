-- Moving shapes: the same outlines at a new position every frame.
--
-- Position is a transform, not geometry: each frame stages the square
-- and the triangle again with a new shapePosition and pushes both in one
-- burst, so the screen applies both commits before it paints.  The
-- picture is one frame in which two shapes have moved, not two frames
-- with one shape each -- that is what the burst buys.
--
-- The pentagon in the middle never moves and is never sent again: a
-- slot the screen already holds stays live and is repainted with every
-- pass, so a static reference costs the CPU nothing after the first
-- frame (the same reason the cube's faces are sent once).
clearScreen()
-- The outlines, centred on their own origin and closed (the first point
-- repeated at the end) so the fill sees the shape the points mean.
local sq = {-5.0, -5.0, 5.0, -5.0, 5.0, 5.0, -5.0, 5.0, -5.0, -5.0}
local tri = {0.0, -6.0, 5.5, 4.0, -5.5, 4.0, 0.0, -6.0}
-- A regular pentagon, 5 points, radius 5, one point up.
local pent = {}
local i = 0
while i < 5 do
  local a = -1.5707963267948966 + i * 1.2566370614359172
  pent[#pent + 1] = 5.0 * math.cos(a)
  pent[#pent + 1] = 5.0 * math.sin(a)
  i = i + 1
end
pent[#pent + 1] = pent[1]
pent[#pent + 1] = pent[2]
-- One colour per point: the square is one flat orange, the triangle's
-- three corners differ, the pentagon is violet.
local ocol = {1.0, 0.55, 0.10, 1.0, 1.0, 0.55, 0.10, 1.0,
              1.0, 0.55, 0.10, 1.0, 1.0, 0.55, 0.10, 1.0,
              1.0, 0.55, 0.10, 1.0}
local tcol = {0.20, 1.0, 0.35, 1.0, 0.55, 1.0, 0.30, 1.0,
              0.15, 0.85, 0.60, 1.0, 0.20, 1.0, 0.35, 1.0}
local pcol = {0.75, 0.45, 1.0, 1.0, 0.75, 0.45, 1.0, 1.0,
              0.75, 0.45, 1.0, 1.0, 0.75, 0.45, 1.0, 1.0,
              0.75, 0.45, 1.0, 1.0, 0.75, 0.45, 1.0, 1.0}
-- The pentagon, once, in the middle band.  The mode is written on every
-- shape by the program: the port is sticky, so a fill that says nothing
-- would inherit the stroke of the shape before it.
stagePush2d(pent, pcol, {32.0, 31.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0},
            "0", nil, 0, "3")
-- The two movers.  Each frame: stage both, push both, then draw, so the
-- screen scans out one frame in which both shapes have moved.  The
-- square crosses the wall left to right along the top band, the
-- triangle right to left along the bottom one, so the two never hide
-- each other and the motion reads as one direction each.
local f = 0
while f < 10 do
  stagePush2d(sq, ocol,
              {8.0 + 4.0 * f, 18.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0},
              "0", nil, 0, "1")
  stagePush2d(tri, tcol,
              {56.0 - 4.0 * f, 44.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0},
              "0", nil, 0, "2")
  draw()
  nap(420.0)
  f = f + 1
end
