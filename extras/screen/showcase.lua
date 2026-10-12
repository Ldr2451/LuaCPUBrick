-- Showcase: every screen primitive in one fast looping demo.
-- Wiring (via the cpu-screen-connector): outNum1 push, outNum2 draw,
-- outNum3 clear, outNum4 wire, outStr1 slot id, outNumArr points
-- (1..) plus one -1 terminator.  No colours are sent: the screen
-- defaults every point to white, which keeps this driver's write
-- budget the smallest it can be -- the protocol's colours cost four
-- array slots per point, and this program's job is to exercise every
-- primitive and the retained slots at the physical floor.  The colour
-- feature (per-point gradients, translucency, the deferred clearAll)
-- gets its own program: showcase2.lua.  Each fire naps just past its
-- burst (fill 1 tick/row, stroke +1/segment, retained ~64+rows), so
-- nothing is ever abandoned.
local function tick()
  local c = clock()
  while clock() == c do end
end
local function nap(c)
  local t = clock()
  while clock() < t + c do end
end
local function fire(after)
  outNum(1, 1.0)
  tick()
  outNum(1, 0.0)
  outNum(2, 1.0)
  tick()
  outNum(2, 0.0)
  if after > 0.0 then nap(after) end
end

-- boot tables: wave sine and rotation cos/sin (whole pixels: the
-- painter truncates, so fractional bounds would bleed across rows)
local sn = {}
local cs = {}
local rs = {}
local i = 0
while i < 32 do
  local a = i * 0.1963495
  sn[i + 1] = (12.0 * math.sin(a)) // 1.0
  i = i + 1
end
i = 0
while i < 16 do
  local a = i * 0.3926991
  cs[i + 1] = (14.0 * math.cos(a)) // 1.0
  rs[i + 1] = (14.0 * math.sin(a)) // 1.0
  i = i + 1
end

-- 10x10 filled square (10 rows)
local function square(bx, by)
  local ex, ey = bx + 10.0, by + 10.0
  outNumArr(1, bx, by, ex, by, ex, ey, bx, ey)
  outNumArr(9, -1.0)
  fire(0.16)
end

-- triangle, two corners fixed, apex sweeping (20 rows)
local function tri(tx)
  outNumArr(1, 22.0, 10.0, 42.0, 10.0, tx, 30.0)
  outNumArr(7, -1.0)
  fire(0.26)
end

-- rotating wire square, closed by repeating the first point (28 rows)
local function wire(k)
  local x0 = 32.0 + cs[k + 1]
  local y0 = 32.0 + rs[k + 1]
  local x1 = 32.0 - rs[k + 1]
  local y1 = 32.0 + cs[k + 1]
  local x2 = 32.0 - cs[k + 1]
  local y2 = 32.0 - rs[k + 1]
  local x3 = 32.0 + rs[k + 1]
  local y3 = 32.0 - cs[k + 1]
  outNumArr(1, x0, y0, x1, y1, x2, y2, x3, y3)
  outNumArr(9, x0, y0, -1.0)
  fire(0.36)
end

-- scrolling open sine wave, 16 points (24 rows + 15 segments)
local function wave(f)
  outNumArr(1, 0.0, 32.0 + sn[(f % 32) + 1], 4.0,
    32.0 + sn[((f + 2) % 32) + 1], 8.0, 32.0 + sn[((f + 4) % 32) + 1],
    12.0, 32.0 + sn[((f + 6) % 32) + 1])
  outNumArr(9, 16.0, 32.0 + sn[((f + 8) % 32) + 1], 20.0,
    32.0 + sn[((f + 10) % 32) + 1], 24.0, 32.0 + sn[((f + 12) % 32) + 1],
    28.0, 32.0 + sn[((f + 14) % 32) + 1])
  outNumArr(17, 32.0, 32.0 + sn[((f + 16) % 32) + 1], 36.0,
    32.0 + sn[((f + 18) % 32) + 1], 40.0, 32.0 + sn[((f + 20) % 32) + 1],
    44.0, 32.0 + sn[((f + 22) % 32) + 1])
  outNumArr(25, 48.0, 32.0 + sn[((f + 24) % 32) + 1], 52.0,
    32.0 + sn[((f + 26) % 32) + 1], 56.0, 32.0 + sn[((f + 28) % 32) + 1],
    60.0, 32.0 + sn[((f + 30) % 32) + 1])
  outNumArr(33, -1.0)
  fire(0.45)
end

-- filled octagon of radius r (2r rows)
local function octagon(cx, cy, r)
  local k = r * 0.4142136
  local x0, x1 = cx - r, cx + r
  local y0, y1 = cy - r, cy + r
  outNumArr(1, cx - k, y0, cx + k, y0, x1, cy - k, x1, cy + k)
  outNumArr(9, cx + k, y1, cx - k, y1, x0, cy + k, x0, cy - k)
  outNumArr(17, -1.0)
  fire(2.2)
end

-- 16-gon finale ring (36 rows)
local function ring()
  outNumArr(1, 32.0 + cs[1] * 18.0 / 14.0 // 1.0,
    32.0 + rs[1] * 18.0 / 14.0 // 1.0, 32.0 + cs[2] * 18.0 / 14.0 // 1.0,
    32.0 + rs[2] * 18.0 / 14.0 // 1.0, 32.0 + cs[3] * 18.0 / 14.0 // 1.0,
    32.0 + rs[3] * 18.0 / 14.0 // 1.0, 32.0 + cs[4] * 18.0 / 14.0 // 1.0,
    32.0 + rs[4] * 18.0 / 14.0 // 1.0)
  outNumArr(9, 32.0 + cs[5] * 18.0 / 14.0 // 1.0,
    32.0 + rs[5] * 18.0 / 14.0 // 1.0, 32.0 + cs[6] * 18.0 / 14.0 // 1.0,
    32.0 + rs[6] * 18.0 / 14.0 // 1.0, 32.0 + cs[7] * 18.0 / 14.0 // 1.0,
    32.0 + rs[7] * 18.0 / 14.0 // 1.0, 32.0 + cs[8] * 18.0 / 14.0 // 1.0,
    32.0 + rs[8] * 18.0 / 14.0 // 1.0)
  outNumArr(17, 32.0 + cs[9] * 18.0 / 14.0 // 1.0,
    32.0 + rs[9] * 18.0 / 14.0 // 1.0, 32.0 + cs[10] * 18.0 / 14.0 // 1.0,
    32.0 + rs[10] * 18.0 / 14.0 // 1.0, 32.0 + cs[11] * 18.0 / 14.0 // 1.0,
    32.0 + rs[11] * 18.0 / 14.0 // 1.0, 32.0 + cs[12] * 18.0 / 14.0 // 1.0,
    32.0 + rs[12] * 18.0 / 14.0 // 1.0)
  outNumArr(25, 32.0 + cs[13] * 18.0 / 14.0 // 1.0,
    32.0 + rs[13] * 18.0 / 14.0 // 1.0, 32.0 + cs[14] * 18.0 / 14.0 // 1.0,
    32.0 + rs[14] * 18.0 / 14.0 // 1.0, 32.0 + cs[15] * 18.0 / 14.0 // 1.0,
    32.0 + rs[15] * 18.0 / 14.0 // 1.0, 32.0 + cs[16] * 18.0 / 14.0 // 1.0,
    32.0 + rs[16] * 18.0 / 14.0 // 1.0)
  outNumArr(33, -1.0)
  fire(0.45)
end

local bx, by = 4.0, 20.0
local vx, vy = 2.0, 1.0
local f = 0
while true do
  -- 1. bouncing squares: fills overlapping into blends
  local n = 0
  while n < 48 do
    square(bx, by)
    bx = bx + vx
    by = by + vy
    if bx < 2.0 then bx = 2.0 vx = 2.0 end
    if bx > 52.0 then bx = 52.0 vx = -2.0 end
    if by < 2.0 then by = 2.0 vy = 1.0 end
    if by > 52.0 then by = 52.0 vy = -1.0 end
    n = n + 1
  end
  -- 2. morphing triangle: apex sweeping over the trail
  n = 0
  while n < 48 do
    local d = (f * 3) % 88
    if d > 44.0 then d = 88.0 - d end
    tri(10.0 + d)
    f = f + 1
    n = n + 1
  end
  -- 3. rotating wire square: strokes, closed outline
  outNum(4, 1.0)
  n = 0
  while n < 32 do
    wire(f % 16)
    f = f + 1
    n = n + 1
  end
  -- 4. scrolling sine wave: open stroke, 16 points (heaviest compute)
  n = 0
  while n < 24 do
    wave(f)
    f = f + 1
    n = n + 1
  end
  outNum(4, 0.0)
  -- 5. retained scene: frame, sun, moon; move the moon; delete the sun
  outNum(4, 1.0)
  outStr(1, "1")
  outNumArr(1, 2.0, 2.0, 62.0, 2.0, 62.0, 62.0, 2.0, 62.0)
  outNumArr(9, 2.0, 2.0, -1.0)
  fire(2.2)
  outNum(4, 0.0)
  outStr(1, "2")
  octagon(16.0, 44.0, 7.0)
  outStr(1, "3")
  octagon(48.0, 44.0, 7.0)
  octagon(40.0, 30.0, 7.0)
  outStr(1, "2")
  outNumArr(1, -1.0)
  fire(2.2)
  outStr(1, "")
  -- 6. trail ball over the retained scene: immediate accumulation
  bx, by = 8.0, 8.0
  vx, vy = 3.0, 2.0
  n = 0
  while n < 36 do
    local ex, ey = bx + 6.0, by + 6.0
    outNumArr(1, bx, by, ex, by, ex, ey, bx, ey)
    outNumArr(9, -1.0)
    fire(0.12)
    bx = bx + vx
    by = by + vy
    if bx < 4.0 then bx = 4.0 vx = 3.0 end
    if bx > 54.0 then bx = 54.0 vx = -3.0 end
    if by < 4.0 then by = 4.0 vy = 2.0 end
    if by > 54.0 then by = 54.0 vy = -2.0 end
    n = n + 1
  end
  -- 7. clearAll forgets everything; the ring's drawAll is the pulse
  -- that blacks the wall (the deferred clear), then the finale holds
  outNum(3, 1.0)
  tick()
  tick()
  outNum(3, 0.0)
  nap(0.85)
  ring()
  nap(2.0)
end
