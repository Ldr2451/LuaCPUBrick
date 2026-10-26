-- Parenting, moving the parent, and unlinking -- with a mesh cylinder.
--
-- A cylinder (two filled caps and three side edges, sent as a mesh) and a
-- semi-transparent red disc, both children of one pivot.  A multi-coloured
-- quad sits far behind them, so the disc's alpha has something to blend
-- with.  Moving the pivot moves the whole assembly; pushing the disc with no
-- parent relinks it, and from then on the pivot's moves leave it where it is.
--
-- Slot ids: background 1, pivot 2, caps 3..4, side edges 5..7, disc 8.
clearScreen()
-- The pivot's pose: centred, scaled to sit inside the wall.
local pose = {30.5, 33.0, 0.0, 0.45, 0.0, 0.85, 1.0, 1.0, 1.0}

-- The background: ONE quad, four corner colours, far behind everything.
-- A quad is a shape like any other, so the chip knows nothing about it --
-- it is simply painted first, and the disc blends over it later.
local bgPts = {-30.0, -30.0, -40.0,
                95.0, -30.0, -40.0,
                95.0,  95.0, -40.0,
               -30.0,  95.0, -40.0}
local bgCols = {0.10, 0.10, 0.32, 1.0,
                0.55, 0.12, 0.40, 1.0,
                0.95, 0.55, 0.18, 1.0,
                0.08, 0.50, 0.55, 1.0}
setWire(0)
editShape("1", bgPts, bgCols, nil, "0")

-- The cylinder as a mesh: two rings of twelve vertices, one ring per cap,
-- and three vertical edges joining them.  pushMesh turns each face into one
-- shape (closed for us) under the pivot, so the caps are filled and the
-- edges are strokes.
local R = 8.0
local HY = 9.0
local pts = {}
local cols = {}
local k = 0
while k < 12 do
  local a = k * 0.5236
  local cx = math.cos(a) * R
  local cz = math.sin(a) * R
  pts[k * 3 + 1] = cx
  pts[k * 3 + 2] = HY
  pts[k * 3 + 3] = cz
  pts[36 + k * 3 + 1] = cx
  pts[36 + k * 3 + 2] = -HY
  pts[36 + k * 3 + 3] = cz
  -- The top cap is warm, the bottom cool, so the solid reads as a solid.
  cols[k * 4 + 1] = 0.95
  cols[k * 4 + 2] = 0.82
  cols[k * 4 + 3] = 0.35
  cols[k * 4 + 4] = 1.0
  cols[48 + k * 4 + 1] = 0.35
  cols[48 + k * 4 + 2] = 0.55
  cols[48 + k * 4 + 3] = 0.95
  cols[48 + k * 4 + 4] = 1.0
  k = k + 1
end
local top = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12}
local low = {13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24}
local sides = {{1, 13}, {5, 17}, {9, 21}}

-- The pivot first: a child must have something to hang from.  It carries one
-- point in fill mode, which paints nothing.
setWire(0)
editShape("2", {0.0, 0.0, 0.0}, nil, pose, "0")
-- Caps filled (ids 3 and 4), then the side edges as strokes (ids 5..7).
pushMesh(pts, cols, {top, low}, nil, "2", nil, 0, 3)
pushMesh(pts, cols, sides, nil, "2", nil, 1, 5)

-- The disc: a twelve-gon in front of the cylinder, red with alpha 0.55.
-- It is the last slot (8) and a child of the pivot like the cylinder.
local disc = {}
local dcol = {}
k = 0
while k < 12 do
  local a = k * 0.5236
  disc[k * 3 + 1] = math.cos(a) * 5.0 + 9.0
  disc[k * 3 + 2] = 0.0
  disc[k * 3 + 3] = math.sin(a) * 5.0 + 11.0
  dcol[k * 4 + 1] = 0.90
  dcol[k * 4 + 2] = 0.10
  dcol[k * 4 + 3] = 0.10
  dcol[k * 4 + 4] = 0.55
  k = k + 1
end
setWire(0)
editShape("8", disc, dcol, nil, "2")
nap(460.0)

-- Move the pivot: every child rides with it.
local step = 1
while step < 3 do
  local xf = {pose[1] + step * 6.0, pose[2], pose[3], pose[4], pose[5], pose[6],
              pose[7], pose[8], pose[9]}
  editShape("2", {0.0, 0.0, 0.0}, nil, xf, "0")
  nap(460.0)
  step = step + 1
end

-- Unlink the disc.  With no parent its own transform must carry the pose it
-- had, so its points go out already in world space -- the same place the
-- pivot was putting them.
local tx = pose[1] + 2 * 6.0
local world = {}
k = 0
while k < 12 do
  world[k * 3 + 1] = tx + disc[k * 3 + 1] * pose[4]
  world[k * 3 + 2] = pose[2] + disc[k * 3 + 2] * pose[5]
  world[k * 3 + 3] = disc[k * 3 + 3] * pose[6]
  k = k + 1
end
setWire(0)
editShape("8", world, dcol, nil, "0")
nap(460.0)

-- Move the pivot again: the cylinder slides, the disc stays.
local step2 = 3
while step2 < 5 do
  local xf = {pose[1] + step2 * 6.0, pose[2], pose[3], pose[4], pose[5], pose[6],
              pose[7], pose[8], pose[9]}
  editShape("2", {0.0, 0.0, 0.0}, nil, xf, "0")
  nap(460.0)
  step2 = step2 + 1
end
