-- A cube whose points are rewritten every frame: the outline breathes
-- along one axis.
--
-- Nothing is scaled.  Each frame sends its OWN eight vertices -- the same
-- x and z, a y that grows and shrinks -- so this is the sample for editing
-- a shape's points while it is on screen: pushMesh stages a face and pushes
-- it, draw() commits the six faces and the wall is recomposited from the
-- stored slots.  The chip transforms, projects and paints; the program
-- never computes a pixel.
clearScreen()
-- Half-size of the cube.  13 fills this pose without touching the wall's
-- edge; the breathing adds at most a sixth of it again.
local h = 13.0
-- The eight vertices, in the order the faces name them: 1..4 near face,
-- 5..8 far one.
local base = {
  -h, -h, h,  h, -h, h,  h, h, h,  -h, h, h,
  -h, -h, -h,  h, -h, -h,  h, h, -h,  -h, h, -h,
}
-- One colour per vertex: four bright near corners, four dark far ones, so
-- the cube reads as one solid rather than six separate squares.  Because a
-- vertex is shared, an edge between two faces is drawn in one colour.
local cols = {
  0.95, 0.95, 1.00, 1.00,
  0.95, 0.90, 0.85, 1.00,
  0.95, 0.85, 0.55, 1.00,
  0.90, 0.80, 0.50, 1.00,
  0.35, 0.30, 0.35, 1.00,
  0.40, 0.35, 0.40, 1.00,
  0.45, 0.40, 0.45, 1.00,
  0.40, 0.35, 0.40, 1.00,
}
-- The six faces, each a closed outline of four vertices.
local faces = {
  {1, 2, 3, 4},
  {5, 8, 7, 6},
  {1, 5, 6, 2},
  {4, 3, 7, 8},
  {1, 4, 8, 5},
  {2, 6, 7, 3},
}
-- The cube sits centred and still: the pivot is a plain shape carrying the
-- pose, with no animation -- the picture changes by its POINTS, not by a
-- transform.  An empty push to a slot is the delete, so the pivot carries
-- one point; wireframe mode stays off here or that point paints a dot.
pushMesh(base, cols, faces, nil, "1", nil, 1.0, 2)
editShape("1", {0.0, 0.0, 0.0}, nil,
          {30.5, 33.0, 0.0, 0.45, 0.0, 0.85, 1.0, 1.0, 1.0}, "0")

-- Six frames, one breath: y goes from rest to stretched and back.  The
-- chip's own tick budget is what sets how long a body may run, so a breath
-- is kept short.
local f = 0
while f < 6 do
  local sy = 1.0 + 0.22 * math.sin(f * 0.62)
  local pts = {}
  local k = 0
  while k < 8 do
    pts[k * 3 + 1] = base[k * 3 + 1]
    pts[k * 3 + 2] = base[k * 3 + 2] * sy
    pts[k * 3 + 3] = base[k * 3 + 3]
    k = k + 1
  end
  pushMesh(pts, cols, faces, nil, "1", nil, 1.0, 2)
  draw()
  -- Hold the frame on screen for about a pass.  cubetest replays bodies at
  -- its own pacing (CUBE_NAP), so the number here is the game's pace, not
  -- the test's.
  nap(220.0)
  f = f + 1
end
