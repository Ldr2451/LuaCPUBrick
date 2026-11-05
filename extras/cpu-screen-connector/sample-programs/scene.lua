-- A 3D scene traversed by an orbiting camera: the world is staged ONCE
-- into slots and appears in ONE go -- a single draw commits the whole
-- picture -- and the traversal is the camera's pose re-pushed every
-- frame, yawing around the scene so the parallax shows it is really
-- 3D.
--
-- The wall is reactive-only, so a moving view is exactly the same
-- contract as a moving shape: every picture is one the CPU sent.
-- camera(xf) edits the view's own slot -- one point that paints
-- nothing -- and its commit recomposites the WHOLE scene at the new
-- view.  The camera pose is (pos, rot.yaw about the vertical, scale):
-- the view COMPOSES outside every shape, x' = cos t x + sin t z + px,
-- z' = -sin t x + cos t z + pz, so an orbit about the scene centre
-- (32, ., 0) is px = 32 - 32 cos t, pz = 32 sin t with yaw t.
--
-- Slot ids: sky 1, ground 2, sun 3, peaks 4..6, river 7, the four
-- pillars 8..11, the HUD 12.
clearScreen()

-- The world is only STAGED until the final draw(): a push stores a
-- slot, and the one commit at the end paints everything at once, in
-- depth order -- nothing ever shows up half-built.
--
-- The sky: one huge quad, wide and tall enough that a yaw of +/- 45
-- degrees still leaves it covering everything above the horizon, so
-- the background is never black.
stage({-160.0, 40.0, -170.0, 220.0, 40.0, -170.0,
       220.0, -170.0, -170.0, -160.0, -170.0, -170.0, -160.0, 40.0, -170.0},
      rep({0.25, 0.32, 0.55, 1.0}, 5), nil, "0", 0, "1")
push()
-- The west wing of the sky box, same colour: catches the view as the
-- camera swings east.
stage({-160.0, 40.0, 210.0, -160.0, -170.0, 210.0,
       -160.0, -170.0, -170.0, -160.0, 40.0, -170.0, -160.0, 40.0, 210.0},
      rep({0.25, 0.32, 0.55, 1.0}, 5), nil, "0", 0, "2")
push()
-- The east wing, same colour: catches the view swinging west.
stage({220.0, 40.0, -170.0, 220.0, -170.0, -170.0,
       220.0, -170.0, 210.0, 220.0, 40.0, 210.0, 220.0, 40.0, -170.0},
      rep({0.25, 0.32, 0.55, 1.0}, 5), nil, "0", 0, "3")
push()
-- The ground: a plane from far behind the peaks to far past the
-- camera, so below the horizon is always green at every yaw.
stage({-160.0, 40.0, 200.0, 220.0, 40.0, 200.0,
       220.0, 40.0, -180.0, -160.0, 40.0, -180.0, -160.0, 40.0, 200.0},
      rep({0.18, 0.32, 0.22, 1.0}, 5), nil, "0", 0, "4")
push()
-- The sun: a ten-point disc high in the sky, behind the peaks.
local sun = {}
local k = 0
while k < 10 do
  local a = k * 0.6283
  sun[k * 3 + 1] = 46.0 + 8.0 * math.cos(a)
  sun[k * 3 + 2] = 2.0 + 8.0 * math.sin(a)
  sun[k * 3 + 3] = -150.0
  k = k + 1
end
stage(sun, rep({1.0, 0.85, 0.4, 1.0}, 10), nil, "0", 0, "5")
push()
-- Three peaks standing on the horizon, tinted by distance, spread
-- wide so one is always in view while the camera swings.
stage({4.0, 36.0, -150.0, 34.0, 36.0, -150.0, 18.0, -8.0, -150.0},
      rep({0.42, 0.44, 0.60, 1.0}, 3), nil, "0", 0, "6")
push()
stage({52.0, 36.0, -120.0, 84.0, 36.0, -120.0, 68.0, -2.0, -120.0},
      rep({0.34, 0.36, 0.52, 1.0}, 3), nil, "0", 0, "7")
push()
stage({-26.0, 36.0, -135.0, 2.0, 36.0, -135.0, -12.0, 6.0, -135.0},
      rep({0.38, 0.40, 0.56, 1.0}, 3), nil, "0", 0, "8")
push()
-- The river: a blue band running from the far horizon up past the
-- camera, standing just above the ground plane.
stage({-8.0, 38.0, 190.0, 6.0, 38.0, 190.0,
       5.0, 38.0, -160.0, -6.0, 38.0, -160.0, -8.0, 38.0, 190.0},
      rep({0.20, 0.45, 0.80, 1.0}, 5), nil, "0", 0, "9")
push()

-- Four pillars around the middle, standing on the ground (y = 40 is
-- the plane, tops at y = 18 so they rise 22 units), each ONE mesh of
-- eight corners -- top corners bright, bottom dark, so the lit faces
-- read as lit.  They bracket the orbit radius (32 units about the
-- scene centre), so swinging past them is what shows the depth.
local hw = 5.0
local ylo = 40.0
local yhi = 18.0
local s = 1
while s <= 4 do
  local cx = -14.0
  if s % 2 == 0 then cx = 52.0 end
  local cz = 6.0 + 9.0 * s
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
  pushMesh(p, c, f4, nil, "0", 0, 7 + s)
  s = s + 1
end

-- The HUD: parent "-1" hangs it off the camera, so it rides along and
-- keeps its pixels through the whole orbit -- the view swings, the
-- frame does not.
stage({2.0, 2.0, 0.0, 14.0, 2.0, 0.0, 14.0, 3.2, 0.0,
       2.0, 3.2, 0.0, 2.0, 2.0, 0.0},
      rep({0.9, 0.9, 0.9, 1.0}, 5), nil, "-1", 1, "12")
push()

-- The whole world in one go: one commit paints every stored slot.
print("1 world: one draw commits everything")
draw()
nap(224.0)

-- The orbit: yaw about the scene centre, re-pushed every frame.  The
-- far peaks slide less than the near pillars, the river sweeps under
-- all of it: the chips' projection does the parallax, not the
-- program.  Nine steps of 5 degrees each way.
print("orbit: the camera swings, the world holds")
local f = 1
while f <= 9 do
  local t = 0.0872 * f
  camera({32.0 - 32.0 * math.cos(t), 2.0 + 0.5 * math.sin(0.7 * f),
          32.0 * math.sin(t), 0.0, t, 0.0, 1.0, 1.0, 1.0})
  nap(224.0)
  f = f + 1
end
-- Back to the front view the SAME poses in reverse, so the loop ends
-- where it started and no frame snaps.
f = 1
while f <= 9 do
  local g = 9 - f
  local t = 0.0872 * g
  camera({32.0 - 32.0 * math.cos(t), 2.0 + 0.5 * math.sin(0.7 * g),
          32.0 * math.sin(t), 0.0, t, 0.0, 1.0, 1.0, 1.0})
  nap(224.0)
  f = f + 1
end
