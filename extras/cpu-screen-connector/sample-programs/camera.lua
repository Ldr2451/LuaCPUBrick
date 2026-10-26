-- The camera: the view, not a parent.
--
-- Four shapes are pushed with parent "0" -- no parent at all, so they sit in
-- world space.  Pushing id -1 moves the camera, and every shape in the world
-- moves on screen with it: its place, its apparent size (the distance from
-- the eye), and which face is nearer.  A fifth shape is pushed with parent
-- "-1": it hangs off the camera itself, so it is placed in view space and
-- keeps the same pixels on screen while the camera moves -- that is what a
-- child of the camera means.
--
-- A camera move is a transform-only push: one point, which paints nothing.
-- The wall recomposites from the live slots, so the scene lands in the new
-- place with no second shape sent anywhere.
--
-- Slot ids: camera -1, background 2, disc 3, triangle 4, outline 5,
-- HUD 6 (child of the camera).
clearScreen()

-- The camera starts at the origin, identity: world coordinates and screen
-- positions are the same thing until it moves.
local home = {0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0}
setWire(0)
editShape("-1", {0.0, 0.0, 0.0}, nil, home, "0")

-- Background: one quad, four corner colours, far behind everything.
local bg = {-30.0, -30.0, -40.0, 95.0, -30.0, -40.0,
            95.0, 95.0, -40.0, -30.0, 95.0, -40.0}
local bgc = {0.10, 0.10, 0.32, 1.0, 0.55, 0.12, 0.40, 1.0,
             0.95, 0.55, 0.18, 1.0, 0.08, 0.50, 0.55, 1.0}
setWire(0)
editShape("2", bg, bgc, nil, "0")

-- A blue disc: thirteen points, so the length is odd and reads as 3D.
local disc = {}
local dcol = {}
local k = 0
while k < 12 do
  local a = k * 0.5236
  disc[k * 3 + 1] = math.cos(a) * 7.0 + 15.0
  disc[k * 3 + 2] = math.sin(a) * 7.0 + 26.0
  disc[k * 3 + 3] = 0.0
  dcol[k * 4 + 1] = 0.35
  dcol[k * 4 + 2] = 0.60
  dcol[k * 4 + 3] = 0.95
  dcol[k * 4 + 4] = 1.0
  k = k + 1
end
disc[37] = disc[1]
disc[38] = disc[2]
disc[39] = disc[3]
setWire(0)
editShape("3", disc, dcol, nil, "0")

-- A green triangle, and a wire outline: two more shapes, unrelated to the
-- disc and to each other.
local tri = {44.0, 46.0, 4.0, 58.0, 34.0, 4.0, 38.0, 30.0, 4.0}
local triCol = {0.30, 0.85, 0.45, 1.0, 0.30, 0.85, 0.45, 1.0,
                0.30, 0.85, 0.45, 1.0}
setWire(0)
editShape("4", tri, triCol, nil, "0")

local outline = {20.0, 10.0, -6.0, 42.0, 10.0, -6.0, 42.0, 20.0, -6.0,
                 20.0, 20.0, -6.0, 20.0, 10.0, -6.0}
setWire(1)
editShape("5", outline, nil, nil, "0")

-- The HUD: parent "-1", so it hangs off the camera.  It moves WITH the
-- camera, which means it stays exactly where it is on screen.
setWire(1)
editShape("6", {3.0, 3.0, 0.0, 13.0, 3.0, 0.0, 13.0, 11.0, 0.0,
                3.0, 11.0, 0.0, 3.0, 3.0, 0.0}, nil, nil, "-1")
nap(460.0)

-- Move the camera back and forth: pan left, come home, pan right, come
-- home, then push it forwards so perspective takes over and the world
-- shapes grow.  The HUD holds its pixels through all of it.
local step = 1
while step <= 8 do
  local px = 0.0
  local pz = 0.0
  if step == 1 then px = -8.0
  elseif step == 2 then px = -16.0
  elseif step == 3 then px = -8.0
  elseif step == 5 then px = 8.0
  elseif step == 7 then pz = 12.0
  end
  local xf = {px, 0.0, pz, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0}
  setWire(0)
  editShape("-1", {0.0, 0.0, 0.0}, nil, xf, "0")
  nap(460.0)
  step = step + 1
end
