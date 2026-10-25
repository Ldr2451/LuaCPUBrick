-- A mesh whose POINTS breathe.
--
-- The cube's eight vertices move on their own.  Each frame the CPU sends
-- the vertices again, each pushed out or pulled in along its own line
-- from the centre, with a phase of its own: the solid swells at one
-- corner while it dips at another instead of scaling as a whole, so the
-- edges stay straight and the faces stay flat while the body works.
--
-- The move is in the POINTS, not in a transform: a vertex that moves
-- drags every face that shares it, because the faces name the same
-- points -- the very property that keeps a shared edge one colour keeps
-- it in one place.  The pivot only tilts here: a forever spin under a
-- re-pushed mesh tips the near corners toward the eye plane, and the
-- perspective divide then blows the stroke across the whole wall.
clearScreen()
-- The half-size, as the cube demo: 10 is what fits a turning cube whose
-- diagonal is the widest thing it shows.
local h = 10.0
-- The eight vertices, 1..4 near (z = +h), 5..8 far, in the order the
-- faces below name them.
local rest = {
  -h, -h, h,   h, -h, h,   h, h, h,   -h, h, h,
  -h, -h, -h,  h, -h, -h,  h, h, -h,  -h, h, -h,
}
-- One colour per vertex: the near four bright, the far four dark.
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
local faces = {
  {1, 2, 3, 4},
  {5, 8, 7, 6},
  {1, 5, 6, 2},
  {4, 3, 7, 8},
  {1, 4, 8, 5},
  {2, 6, 7, 3},
}
-- The pivot: a live slot with one point, which no fill can draw, so it
-- carries the transform and puts nothing on the wall.  Wireframe mode is
-- the program's to set: off here, or the one point would be a blob if a
-- later burst left the port on.
setWire(0)
editShape("1", {0.0, 0.0, 0.0}, nil,
          {32.0, 32.0, 0.0, 0.35, 0.0, 0.0, 1.0, 1.0, 1.0}, "0")
-- No forever spin here: re-pushing the faces under a spinning pivot tips
-- the near corners toward the eye plane and the stroke blows across the
-- whole wall (measured).  The tilt stays; the turn is the cube demo's job.
push()
-- A frame of the breath: every vertex moves along its OWN axes, not along
-- its own ray.  x stretches hard while y and z barely move, so the body
-- elongates longitudinally -- long and thin at one phase, back toward the
-- cube at the next -- instead of growing as a whole.  Vertex k's phase
-- differs from its neighbours', so the stretch is uneven and the solid
-- reads as a body, not as a scaled cube.
local f = 0
while f < 8 do
  local ph = f * 0.75
  local pts = {}
  local k = 0
  while k < 8 do
    -- One phase for the whole body, plus a small per-vertex ripple:
    -- x stretches longitudinally and y/z pinch gently, so the cube
    -- elongates and flattens as a solid instead of tearing apart.  The
    -- pinch is shallow on purpose: the tilted pivot tips z toward the
    -- eye plane, and past about z 12 the perspective divide inflates a
    -- vertex across the whole wall -- the cube demo keeps z' near 11.5,
    -- so this stays at x 12 and y/z 9, inside the same envelope.
    local w = math.sin(ph)
    local r = 0.03 * math.sin(ph + k * 1.9)
    pts[#pts + 1] = rest[k * 3 + 1] * (1.0 + 0.20 * w + r)
    pts[#pts + 2] = rest[k * 3 + 2] * (1.0 - 0.10 * w - r)
    pts[#pts + 3] = rest[k * 3 + 3] * (1.0 - 0.10 * w - r)
    k = k + 1
  end
  pushMesh(pts, cols, faces, nil, "1", nil, 1.0, 2)
  draw()
  nap(420.0)
  f = f + 1
end
