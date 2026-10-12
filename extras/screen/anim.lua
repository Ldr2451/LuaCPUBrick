-- Rainbow spirograph, polygon edition -- driver for the 64x64 screen.
-- Wires: outNum1 -> pushFill, outNum2 -> redrawAll,
-- outNumArr -> shapePoints (1..32, short shapes repeat the last point)
-- and shapeColor (33..36: r,g,b,a).  One shape per frame, bursts hidden
-- under the next frame's compute.  Terse: the lexer runs ~1 char/tick.

local sets = {
  {26.0, 12.0, 16.0, 37.7},
  {24.0, 10.0, 16.0, 31.4},
  {28.0, 16.0, 18.0, 25.1},
  {22.0, 8.0, 14.0, 25.1},
  {20.0, 6.0, 14.0, 18.8},
}

-- rainbow palette, 32 entries: built once (~800 ticks), then 2 lookups
-- a frame instead of 6 trig calls
local pal = {}
local i = 0
while i < 32 do
  local a = i * 0.1963495
  pal[i * 3 + 1] = 0.5 + 0.5 * math.sin(a)
  pal[i * 3 + 2] = 0.5 + 0.5 * math.sin(a + 2.0943951)
  pal[i * 3 + 3] = 0.5 + 0.5 * math.sin(a + 4.1887902)
  i = i + 1
end

local cx = 32.0
local idx = 1
local mode = 0
local t = 0.0
local hue = 0
local hcore = 0
local hold = 0
local flip = 0

-- one hypotrochoid point, snapped to whole pixels (the painter truncates
-- ly*64+lx once as a sum, so fractional bounds bleed across the row)
local function plot(ti)
  local p = sets[idx]
  local u = (p[1] - p[2]) / p[2]
  local x = (p[1] - p[2]) * math.cos(ti) + p[3] * math.cos(u * ti)
  local y = (p[1] - p[2]) * math.sin(ti) - p[3] * math.sin(u * ti)
  return (cx + x - 4.0) // 1.0, (cx + y - 4.0) // 1.0
end

-- fire one shape: array is staged, pulse push then redraw with one tick
-- holds (push-L and redraw-H share a tick: different ports, both edges
-- land cleanly), no post wait -- the next frame's compute outlasts the
-- burst, so a redrawAll can never catch one mid-flight
local function fire(push)
  outNum(push, 1.0)
  local c = clock()
  while clock() == c do end
  outNum(push, 0.0)
  outNum(2, 1.0)
  c = clock()
  while clock() == c do end
  outNum(2, 0.0)
end

-- an 8x8 filled square tracer at (bx,by), palette entry h
local function tracer(bx, by, h)
  local ex, ey = bx + 8.0, by + 8.0
  outNumArr(1, bx, by, ex, by, ex, ey, bx, ey)
  outNumArr(9, bx, ey, bx, ey, bx, ey, bx, ey)
  outNumArr(17, bx, ey, bx, ey, bx, ey, bx, ey)
  outNumArr(25, bx, ey, bx, ey, bx, ey, bx, ey)
  outNumArr(33, pal[h * 3 + 1], pal[h * 3 + 2], pal[h * 3 + 3], 1.0)
  fire(1)
end

-- the core: an octagon of radius r around center, no trig (k = r*tan22.5)
local function core(r, h)
  local k = r * 0.4142136
  local x0, x1 = cx - r, cx + r
  local y0, y1 = cx - r, cx + r
  local kx0, kx1 = cx - k, cx + k
  local ky0, ky1 = cx - k, cx + k
  outNumArr(1, kx0, y0, kx1, y0, x1, ky0, x1, ky1)
  outNumArr(9, kx1, y1, kx0, y1, x0, ky1, x0, ky0)
  outNumArr(17, x0, ky0, x0, ky0, x0, ky0, x0, ky0)
  outNumArr(25, x0, ky0, x0, ky0, x0, ky0, x0, ky0)
  outNumArr(33, pal[h * 3 + 1], pal[h * 3 + 2], pal[h * 3 + 3], 0.5)
  fire(1)
end

local function clearAll()
  outNumArr(1, 0.0, 0.0, 64.0, 0.0, 64.0, 64.0, 0.0, 64.0)
  outNumArr(9, 0.0, 64.0, 0.0, 64.0, 0.0, 64.0, 0.0, 64.0)
  outNumArr(17, 0.0, 64.0, 0.0, 64.0, 0.0, 64.0, 0.0, 64.0)
  outNumArr(25, 0.0, 64.0, 0.0, 64.0, 0.0, 64.0, 0.0, 64.0)
  outNumArr(33, 0.0, 0.0, 0.0, 1.0)
  fire(1)
  -- the clear is 64 rows; the next frame's compute (~50 ticks) would
  -- abandon its burst, so wait it out exactly (normal bursts stay
  -- hidden under the compute and need no wait)
  local target = clock() + 0.66
  while clock() < target do end
end

while true do
  if mode == 0 then
    local tmax = sets[idx][4]
    if flip == 0 then
      local ax, ay = plot(t)
      tracer(ax, ay, hue)
      hue = hue + 1
      if hue > 31 then hue = 0 end
      t = t + 0.3
      if t >= tmax then
        mode = 1
        hold = 40
      end
      flip = 1
    else
      core(10.0, hcore)
      hcore = hcore + 1
      if hcore > 31 then hcore = 0 end
      flip = 0
    end
  elseif mode == 1 then
    core(10.0, hcore)
    hcore = hcore + 1
    if hcore > 31 then hcore = 0 end
    hold = hold - 1
    if hold <= 0 then
      mode = 2
    end
  else
    clearAll()
    idx = idx + 1
    if idx > 5 then idx = 1 end
    t = 0.0
    flip = 0
    mode = 0
  end
end
