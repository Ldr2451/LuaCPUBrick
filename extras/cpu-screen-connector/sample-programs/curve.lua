-- Open curves: wireframe outlines that stop at their ends.
--
-- The screen joins consecutive points of a wireframe shape and never
-- closes the outline itself: a face goes round because pushMesh repeats
-- its first vertex, not because the screen adds an edge.  So an open
-- polyline stays open here -- the wave ends where its last point is,
-- the arc shows the gap under it, and the chevron is two segments, not
-- a triangle.  The three shapes together are the point: a wireframe
-- follows the points it was given, no more.
--
-- Only the wave moves.  Each frame it is staged again with its phase
-- advanced, so the crests travel along the wall while every point keeps
-- its own colour slot and the wireframe keeps its own path: the wave
-- flows instead of the whole picture sliding.  The arc and the chevron
-- are staged once; the screen keeps them and repaints them every frame.
clearScreen()
-- The wave: 11 points across the wall, one sine period sampled.  Eleven
-- keeps the CPU's per-frame cost low enough that a frame fits in a run.
local n = 11
-- One colour per point, left to right: red to green, so the direction of
-- travel reads from the picture even between two frames.
local wcols = {}
local i = 0
while i < n do
  local t = i / (n - 1)
  wcols[#wcols + 1] = 1.0 - 0.85 * t
  wcols[#wcols + 1] = 0.25 + 0.70 * t
  wcols[#wcols + 1] = 0.35
  wcols[#wcols + 1] = 1.0
  i = i + 1
end
-- One frame of the wave: the same 17 points, a new phase.  The height
-- fits the upper band (rows 11..29) so the arc below stays clear.
local function wave(ph)
  local pts = {}
  local k = 0
  while k < n do
    local t = k / (n - 1)
    pts[#pts + 1] = 5.0 + 54.0 * t
    pts[#pts + 1] = 20.0 + 9.0 * math.sin(ph + 6.2 * t)
    k = k + 1
  end
  stagePush2d(pts, wcols, nil, "0", nil, 1, "1")
end
-- An open arc: half a circle, 9 points, the two ends 22 apart.  Nothing
-- joins them.
local arc = {}
i = 0
while i < 9 do
  local a = 3.141592653589793 * i / 8.0
  arc[#arc + 1] = 18.0 + 11.0 * math.cos(a)
  arc[#arc + 1] = 46.0 - 9.0 * math.sin(a)
  i = i + 1
end
local acols = {}
i = 0
while i < 9 do
  acols[#acols + 1] = 0.95
  acols[#acols + 1] = 0.80
  acols[#acols + 1] = 0.25
  acols[#acols + 1] = 1.0
  i = i + 1
end
stagePush2d(arc, acols, nil, "0", nil, 1, "2")
-- A chevron: three points, two segments.  A triangle would need a third
-- segment back to the start, which this stroke does not have.
local chev = {40.0, 52.0, 49.0, 40.0, 58.0, 52.0}
local ccols = {0.3, 0.8, 1.0, 1.0, 0.3, 0.8, 1.0, 1.0,
               0.3, 0.8, 1.0, 1.0}
stagePush2d(chev, ccols, nil, "0", nil, 1, "3")
-- Frames: one push per frame, then a draw so the screen scans out the
-- new wave.  A nap long enough for the screen to finish the pass before
-- the next push is queued -- a push that lands while a pass is running
-- would overwrite the frame being painted.
local f = 0
while f < 10 do
  wave(f * 0.55)
  draw()
  nap(420.0)
  f = f + 1
end
