-- A 3D scene traversed by a walking camera: the world is staged ONCE into
-- slots, and the traversal is the camera's pose re-pushed every frame.
--
-- The wall is reactive-only, so a moving view is exactly the same contract
-- as a moving shape: every picture is one the CPU sent.  camera(xf) edits
-- the view's own slot -- one point that paints nothing -- and its commit
-- recomposites the WHOLE scene at the new view: the chips transform,
-- project and depth-sort every stored slot from scratch.  The program
-- never computes a pixel and never redraws the world.
--
-- Slot ids: sky 1, sun 2, far peaks 3..4, ground 5, river 6, the four
-- pillars 7..10, the HUD 11.
clearScreen()

-- The world, far to near, so the depth test has room to sort.
-- The sky: one huge quad far behind everything.
stage({-70.0, -30.0, -80.0, 70.0, -30.0, -80.0,
       70.0, 40.0, -80.0, -70.0, 40.0, -80.0, -70.0, -30.0, -80.0},
      rep({0.25, 0.32, 0.55, 1.0}, 5), nil, "0", 0, "1")
push()
-- The sun: a ten-point disc low in the sky, behind the peaks.
local sun = {}
local k = 0
while k < 10 do
  local a = k * 0.6283
  sun[k * 3 + 1] = 42.0 + 6.0 * math.cos(a)
  sun[k * 3 + 2] = 22.0 + 6.0 * math.sin(a)
  sun[k * 3 + 3] = -70.0
  k = k + 1
end
editShape("2", sun, rep({1.0, 0.85, 0.4, 1.0}, 10), nil, "0", 0)
-- Two peaks, tinted by distance: a far one and a nearer one, triangles
-- standing on the horizon at z = -60 and -46.
editShape("3", {-30.0, 26.0, -60.0, 8.0, 26.0, -60.0,
                 -12.0, 42.0, -60.0},
          rep({0.42, 0.44, 0.60, 1.0}, 3), nil, "0", 0)
editShape("4", {-2.0, 18.0, -46.0, 30.0, 18.0, -46.0,
                 14.0, 38.0, -46.0},
          rep({0.34, 0.36, 0.52, 1.0}, 3), nil, "0", 0)
-- The ground: one big quad from behind the peaks to past the camera.
editShape("5", {-70.0, -9.0, 30.0, 70.0, -9.0, 30.0,
                 70.0, -9.0, -55.0, -70.0, -9.0, -55.0, -70.0, -9.0, 30.0},
          rep({0.20, 0.34, 0.24, 1.0}, 5), nil, "0", 0)
-- The river: a blue quad running down the middle, standing just above
-- the ground, so it paints over it and the depth test agrees.
editShape("6", {-5.0, -8.6, 30.0, 6.0, -8.6, 30.0,
                 5.0, -8.6, -50.0, -3.0, -8.6, -50.0, -5.0, -8.6, 30.0},
          rep({0.20, 0.45, 0.80, 1.0}, 5), nil, "0", 0)

-- Four pillars down the valley, alternating banks, z = 6, 12, 18, 24:
-- the camera walks the line between them.  Each is ONE mesh: eight
-- corners, top corners bright and bottom ones dark, so the lit faces
-- read as lit.  The chip fills them; the program sends geometry only.
local hw = 4.0
local ylo = -9.0
local yhi = 7.0
local s = 1
while s <= 4 do
  local cx = -16.0
  if s % 2 == 0 then cx = 15.0 end
  local cz = 6.0 * s
  local p = {cx - hw, ylo, cz - hw, cx + hw, ylo, cz - hw,
             cx + hw, yhi, cz - hw, cx - hw, yhi, cz - hw,
             cx - hw, ylo, cz + hw, cx + hw, ylo, cz + hw,
             cx + hw, yhi, cz + hw, cx - hw, yhi, cz + hw}
  local c = {0.30, 0.22, 0.18, 1.0, 0.32, 0.24, 0.18, 1.0,
             0.62, 0.46, 0.32, 1.0, 0.60, 0.44, 0.30, 1.0,
             0.30, 0.22, 0.18, 1.0, 0.32, 0.24, 0.18, 1.0,
             0.62, 0.46, 0.32, 1.0, 0.60, 0.44, 0.30, 1.0}
  local f4 = {{1, 2, 3, 4}, {5, 8, 7, 6}, {1, 5, 6, 2},
              {4, 3, 7, 8}, {1, 4, 8, 5}, {2, 6, 7, 3}}
  pushMesh(p, c, f4, nil, "0", 0, 6 + s)
  s = s + 1
end

-- The HUD: parent "-1" hangs it off the camera, so it rides along and
-- keeps its pixels through the whole walk -- the view moves, the frame
-- does not.  Two bars bottom-left, in view-space units.
editShape("11", {2.0, 2.0, 0.0, 14.0, 2.0, 0.0, 14.0, 3.2, 0.0,
                  2.0, 3.2, 0.0, 2.0, 2.0, 0.0},
          rep({0.9, 0.9, 0.9, 1.0}, 5), nil, "-1", 1)

-- The walk: the camera's pose re-pushed every frame, each call a commit
-- that recomposites the world at the new view.  The dolly travels down
-- the valley; a slow yaw swings the view across it, and the far peaks
-- slide less than the near pillars -- the chips' projection does the
-- parallax, not the program.  Every wait is the measured handshake.
print("walk: the camera travels, the world holds")
local f = 1
while f <= 6 do
  camera({0.0, 1.0 + 0.3 * math.sin(0.4 * f), 3.0 * f,
          0.0, 0.02 * math.sin(0.4 * f), 0.0, 1.0, 1.0, 1.0})
  nap(224.0)
  f = f + 1
end
-- Home again: the return leg walks the SAME poses backwards, so the
-- loop ends on the view it started from and no frame snaps.
f = 1
while f <= 6 do
  local g = 6 - f
  camera({0.0, 1.0 + 0.3 * math.sin(0.4 * g), 3.0 * g,
          0.0, 0.02 * math.sin(0.4 * g), 0.0, 1.0, 1.0, 1.0})
  nap(224.0)
  f = f + 1
end
