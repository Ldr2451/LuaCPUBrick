-- The screen tour: eight beats, looping -- one showcase of the whole
-- chain, speaking the gfx library (no port touches, no v1 hand-staging).
--
-- Every wait is nap(224.0): the measured handshake wait (README table --
-- the worst draw settles in 224 ticks), so the wall holds a whole
-- picture at every print.
clearScreen()

-- 1 slots: a push stores, an edit replaces in place, zero points delete.
print("1 slots: push, edit, delete")
local sq = {4.0, 4.0, 30.0, 4.0, 30.0, 24.0, 4.0, 24.0}
local sqc = {1.0, 0.2, 0.2, 1.0, 0.2, 1.0, 0.2, 1.0,
             0.2, 0.4, 1.0, 1.0, 1.0, 1.0, 0.2, 1.0}
stagePush2d(sq, sqc, nil, "0", 0, "1")
local tri = {38.0, 4.0, 60.0, 4.0, 49.0, 24.0}
stagePush2d(tri, rep({0.2, 0.9, 0.9, 1.0}, 3), nil, "0", 0, "2")
-- A regular pentagon, 5 points, radius 9, one point up.
local pent = {}
local k = 0
while k < 5 do
  local a = -1.5708 + k * 1.2566
  pent[k * 2 + 1] = 16.0 + 9.0 * math.cos(a)
  pent[k * 2 + 2] = 44.0 + 9.0 * math.sin(a)
  k = k + 1
end
stagePush2d(pent, rep({0.8, 0.5, 1.0, 1.0}, 5), nil, "0", 0, "3")
-- The edit of slot 2: a new colour and a new place, same slot.
stage2d(tri, rep({1.0, 0.6, 0.1, 1.0}, 3),
        {-4.0, 6.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0}, "0", 0, "2")
push()
print("1 slots: slot 2 edited in place")
deleteShape("3")
print("1 slots: slot 3 deleted")
clearScreen()

-- 2 strokes: wireframe, open curve, a one-point dot, a graded line.
print("2 strokes: wireframe, open curve, dot, gradient")
stagePush2d({4.0, 6.0, 24.0, 6.0, 24.0, 26.0, 4.0, 26.0, 4.0, 6.0},
            nil, nil, "0", 1, "4")
local nw = 9
local wav = {}
local wc = {}
k = 0
while k < nw do
  local t = k / (nw - 1)
  wav[k * 2 + 1] = 30.0 + 30.0 * t
  wav[k * 2 + 2] = 16.0 + 9.0 * math.sin(t * 6.2)
  wc[k * 4 + 1] = 1.0 - 0.8 * t
  wc[k * 4 + 2] = 0.2 + 0.8 * t
  wc[k * 4 + 3] = 0.3
  wc[k * 4 + 4] = 1.0
  k = k + 1
end
stagePush2d(wav, wc, nil, "0", 1, "5")
stagePush2d({48.0, 44.0}, rep({1.0, 1.0, 0.3, 1.0}, 1), nil, "0", 1, "6")
stagePush2d({8.0, 40.0, 24.0, 58.0},
            {1.0, 0.15, 0.15, 1.0, 0.15, 0.3, 1.0, 1.0}, nil, "0", 1, "7")
clearScreen()

-- 3 transparency: alpha blends over whatever is under it.
print("3 transparency: alpha blends over what is under it")
-- The back wall: four points of (x,y,z), z = -40 behind everything.
local wall = {-6.0, -6.0, -40.0, 70.0, -6.0, -40.0,
              70.0, 70.0, -40.0, -6.0, 70.0, -40.0}
local wallc = {0.10, 0.10, 0.35, 1.0, 0.60, 0.10, 0.35, 1.0,
               1.00, 0.55, 0.15, 1.0, 0.05, 0.45, 0.55, 1.0}
editShape("1", wall, wallc, nil, "0")
-- A red disc, ten points, half alpha, flat: pairs and the library's
-- triples carry the same shape.
local disc = {}
k = 0
while k < 10 do
  local a = k * 0.6283
  disc[k * 2 + 1] = 24.0 + 11.0 * math.cos(a)
  disc[k * 2 + 2] = 34.0 + 11.0 * math.sin(a)
  k = k + 1
end
stage2d(disc, rep({0.95, 0.10, 0.10, 0.5}, 10), nil, "0", 0, "2")
push()
-- A blue quad at z = 1 over both: three floats per point, and the
-- outline closes so the point count stays odd.
stage({30.0, 20.0, 1.0, 52.0, 20.0, 1.0, 52.0, 46.0, 1.0,
       30.0, 46.0, 1.0, 30.0, 20.0, 1.0},
      rep({0.10, 0.25, 0.95, 0.5}, 5), nil, "0", 0, "3")
push()
clearScreen()

-- 4 immediate: id 0 paints and is forgotten -- a later bare draw brings
-- back ONLY the last one, because nothing retains the rest to repaint.
print("4 immediate: id '' paints and is forgotten")
pushShape({2.0, 2.0, 0.0, 12.0, 2.0, 0.0, 12.0, 12.0, 0.0,
           2.0, 12.0, 0.0, 2.0, 2.0, 0.0}, nil, nil, "0", 1)
pushShape({18.0, 18.0, 0.0, 30.0, 18.0, 0.0, 30.0, 30.0, 0.0,
           18.0, 30.0, 0.0}, rep({1.0, 0.85, 0.15, 1.0}, 4), nil, "0", 0)
pushShape({32.0, 30.0, 0.0, 44.0, 30.0, 0.0, 44.0, 42.0, 0.0,
           32.0, 42.0, 0.0}, rep({0.2, 0.9, 0.4, 1.0}, 4), nil, "0", 0)
print("4 immediate: a bare draw replays the last one")
draw()
nap(224.0)
clearScreen()

-- 5 3D: a cube under a pivot, depth, and a HUD riding the camera.
print("5 3D: one walked cube under one pivot, one draw")
camera({0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0})
editShape("1", wall, {-0.08, -0.08, -0.30, 1.0, 0.45, 0.10, 0.30, 1.0,
                      0.90, 0.45, 0.15, 1.0, 0.05, 0.35, 0.45, 1.0},
          nil, "0")
-- The pivot carries the place and the tilt; its one point paints
-- nothing.  The faces share it, so one transform turns the solid.
editShape("2", {0.0, 0.0, 0.0}, nil,
          {32.0, 33.0, 0.0, 0.5, 0.0, 0.85, 1.0, 1.0, 1.0}, "0")
-- The cube: eight vertices, one colour each -- near corners bright, far
-- ones dark -- and a shared vertex carries one colour into every face,
-- so a shared edge is stroked once.  The whole mesh walks into ONE
-- shape, slot 3, under the pivot.
local h = 11.0
local pts = {-h, -h, h, h, -h, h, h, h, h, -h, h, h,
             -h, -h, -h, h, -h, -h, h, h, -h, -h, h, -h}
-- One colour per VERTEX, eight of them: near corners bright, far ones
-- dark, so the solid reads as one turning cube and every shared edge
-- takes one colour from both sides.
local cols = {1.0, 0.9, 0.7, 1.0, 1.0, 0.85, 0.5, 1.0, 0.9, 0.9, 0.8, 1.0,
              0.7, 0.9, 0.95, 1.0, 0.45, 0.4, 0.5, 1.0, 0.5, 0.4, 0.45, 1.0,
              0.35, 0.55, 0.75, 1.0, 0.4, 0.5, 0.9, 1.0}
local faces = {{1, 2, 3, 4}, {5, 8, 7, 6}, {1, 5, 6, 2},
               {4, 3, 7, 8}, {1, 4, 8, 5}, {2, 6, 7, 3}}
pushMesh(pts, cols, faces, nil, "2", 1.0, 3)
draw()
nap(224.0)
-- A red disc floating in FRONT of the cube's near face (z = 16): the
-- depth test, not paint order, decides what covers what.
local dd = {}
k = 0
while k < 10 do
  local a = k * 0.6283
  dd[k * 3 + 1] = 32.0 + 10.0 * math.cos(a)
  dd[k * 3 + 2] = 33.0 + 10.0 * math.sin(a)
  dd[k * 3 + 3] = 16.0
  k = k + 1
end
editShape("9", dd, rep({0.95, 0.12, 0.12, 0.5}, 10), nil, "0")
-- A curve at z = 24, nearer still.
local cv = {}
local cc = {}
local nc = 9
k = 0
while k < nc do
  local t = k / (nc - 1)
  cv[k * 3 + 1] = 4.0 + 56.0 * t
  cv[k * 3 + 2] = 54.0 + 6.0 * math.sin(t * 6.2)
  cv[k * 3 + 3] = 24.0
  cc[k * 4 + 1] = 0.2
  cc[k * 4 + 2] = 0.8 + 0.2 * t
  cc[k * 4 + 3] = 1.0 - 0.6 * t
  cc[k * 4 + 4] = 1.0
  k = k + 1
end
stage(cv, cc, nil, "0", 1, "10")
push()
-- The HUD: parent "-1", hung off the camera, placed in view space --
-- it keeps its pixels while the world moves.
editShape("11", {2.0, 2.0, 0.0, 14.0, 2.0, 0.0, 14.0, 10.0, 0.0,
                 2.0, 10.0, 0.0, 2.0, 2.0, 0.0}, nil, nil, "-1", 1)
nap(224.0)
print("6 camera: the world moves, the HUD holds")
camera({-9.0, 4.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0})
nap(224.0)
camera({0.0, 0.0, 12.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0})
nap(224.0)
camera({0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0})
nap(224.0)

-- 7 motion: the wall is reactive-only, so a move is a RE-PUSH.  The disc's
-- whole shape goes out again eight times, +2 x further each frame -- the
-- transform, not a delta, carries the new pose -- and the cube's pivot
-- turns the same way, pose by re-pushed pose, about five degrees a frame.
print("7 motion: the disc slides, +2 x a frame")
local f = 1
while f <= 8 do
  editShape("9", dd, rep({0.95, 0.12, 0.12, 0.5}, 10),
            {2.0 * f, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0}, "0")
  nap(224.0)
  f = f + 1
end
print("7 motion: the cube turns, pose by re-pushed pose")
f = 1
while f <= 14 do
  editShape("2", {0.0, 0.0, 0.0}, nil,
            {32.0, 33.0, 0.0, 0.5, 0.0, 0.85 + 0.04 * f, 1.0, 1.0, 1.0},
            "0")
  nap(224.0)
  f = f + 1
end

-- 8 wave: an OPEN curve stroked in colour, re-pushed frame by frame --
-- the curve is restaged with its phase advanced each frame, so the
-- crests travel while the colours keep their point slots: the wave
-- flows, the picture does not slide.
print("8 wave: an open curve, running")
clearScreen()
local nw = 11
local wav = {}
local wc = {}
local i = 0
while i < nw do
  local t = i / (nw - 1)
  wav[i * 2 + 1] = 4.0 + 56.0 * t
  wc[i * 4 + 1] = 1.0 - 0.8 * t
  wc[i * 4 + 2] = 0.2 + 0.8 * t
  wc[i * 4 + 3] = 0.3
  wc[i * 4 + 4] = 1.0
  i = i + 1
end
local f = 0
while f < 6 do
  i = 0
  while i < nw do
    local t = i / (nw - 1)
    wav[i * 2 + 2] = 32.0 + 9.0 * math.sin(f * 0.55 + 6.2 * t)
    i = i + 1
  end
  stagePush2d(wav, wc, nil, "0", 1, "20")
  draw()
  nap(224.0)
  f = f + 1
end
