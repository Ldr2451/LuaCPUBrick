-- Showcase 2: per-point colours, retained editing, and the deferred
-- clearAll -- driver for the 64x64 screen.
-- Wiring (via the cpu-screen-connector): outNum1 push, outNum2 draw,
-- outNum3 clear, outNum4 wire, outStr1 slot id, outNumArr points (1..),
-- one -1 terminator, then four floats per point as that point's colour
-- (r, g, b, a) -- the colours are optional: omit them and the screen
-- defaults every point to white (that is what anim.lua does, to keep
-- its write budget minimal).  With colours sent, the screen fills by
-- true scanline interpolation: each pixel blends its row's two crossing
-- colours, so a polygon with per-point colours fills as a gradient.
--
-- Phases (one loop):
--   1. paint the whole screen FIRST -- a retained full-wall gradient
--      background (a mostly-black wall is not nice to look at),
--   2. the morph: a square slowly becomes a circle over it, the
--      per-point colours shifting as it goes,
--   3. the mover: a half-transparent quad EDITED in place slot by
--      slot, so what is behind it shows through, then DELETED with an
--      empty push,
--   4. clearAll: which only forgets the screen's memory -- the wall
--      keeps showing the scene -- and then compose a NEW scene, whose
--      first drawAll is the pulse that actually blacks the wall, so the
--      old image never cuts to black before the new one is ready.
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

-- rainbow palette, 32 entries, built once
local pal = {}
local i = 0
while i < 32 do
  local a = i * 0.1963495
  pal[i * 3 + 1] = 0.5 + 0.5 * math.sin(a)
  pal[i * 3 + 2] = 0.5 + 0.5 * math.sin(a + 2.0943951)
  pal[i * 3 + 3] = 0.5 + 0.5 * math.sin(a + 4.1887902)
  i = i + 1
end

-- one colour (four floats) at an array slot, hue wrapped into the
-- palette
local function pcol(slot, h, a)
  h = h % 32
  outNumArr(slot, pal[h * 3 + 1], pal[h * 3 + 2], pal[h * 3 + 3], a)
end

-- the two rings the morph blends between: a square and a circle of
-- radius 10, 8 points each, whole pixels (the painter truncates)
local sx, sy, cx, cy = {}, {}, {}, {}
i = 0
while i < 8 do
  local a = i * 0.7853982
  local co, si = math.cos(a), math.sin(a)
  local r = 10.0 / math.max(math.abs(co), math.abs(si))
  sx[i] = (32.0 + r * co) // 1.0
  sy[i] = (32.0 + r * si) // 1.0
  cx[i] = (32.0 + 10.0 * co) // 1.0
  cy[i] = (32.0 + 10.0 * si) // 1.0
  i = i + 1
end

-- the full-screen gradient background: four corners, four colours,
-- and the fill interpolates between them (64 rows).  The terminator's
-- magnitude is the colour count: -(1+4) here.
local function background(h)
  outNumArr(1, 0.0, 0.0, 64.0, 0.0, 64.0, 64.0, 0.0, 64.0)
  outNumArr(9, -5.0)
  pcol(10, h, 1.0)
  pcol(14, h + 8, 1.0)
  pcol(18, h + 16, 1.0)
  pcol(22, h + 24, 1.0)
  fire(1.6)
end

-- the morph: the 8 ring points blended square -> circle by t, one hue
-- per point (~20 rows)
local function morph(t, hue)
  local x0 = (sx[0] + (cx[0] - sx[0]) * t) // 1.0
  local y0 = (sy[0] + (cy[0] - sy[0]) * t) // 1.0
  local x1 = (sx[1] + (cx[1] - sx[1]) * t) // 1.0
  local y1 = (sy[1] + (cy[1] - sy[1]) * t) // 1.0
  local x2 = (sx[2] + (cx[2] - sx[2]) * t) // 1.0
  local y2 = (sy[2] + (cy[2] - sy[2]) * t) // 1.0
  local x3 = (sx[3] + (cx[3] - sx[3]) * t) // 1.0
  local y3 = (sy[3] + (cy[3] - sy[3]) * t) // 1.0
  local x4 = (sx[4] + (cx[4] - sx[4]) * t) // 1.0
  local y4 = (sy[4] + (cy[4] - sy[4]) * t) // 1.0
  local x5 = (sx[5] + (cx[5] - sx[5]) * t) // 1.0
  local y5 = (sy[5] + (cy[5] - sy[5]) * t) // 1.0
  local x6 = (sx[6] + (cx[6] - sx[6]) * t) // 1.0
  local y6 = (sy[6] + (cy[6] - sy[6]) * t) // 1.0
  local x7 = (sx[7] + (cx[7] - sx[7]) * t) // 1.0
  local y7 = (sy[7] + (cy[7] - sy[7]) * t) // 1.0
  outNumArr(1, x0, y0, x1, y1, x2, y2, x3, y3)
  outNumArr(9, x4, y4, x5, y5, x6, y6, x7, y7)
  outNumArr(17, -9.0)
  pcol(18, hue, 1.0)
  pcol(22, hue + 4, 1.0)
  pcol(26, hue + 8, 1.0)
  pcol(30, hue + 12, 1.0)
  pcol(34, hue + 16, 1.0)
  pcol(38, hue + 20, 1.0)
  pcol(42, hue + 24, 1.0)
  pcol(46, hue + 28, 1.0)
  fire(1.75)
end

-- the mover: a small half-transparent quad (alpha 0.5, so the morph
-- and the background show through), edited in place (~6 rows)
local function mover(bx, by, hue)
  local ex, ey = bx + 8.0, by + 6.0
  outNumArr(1, bx, by, ex, by, ex, ey, bx, ey)
  outNumArr(9, -5.0)
  pcol(10, hue, 0.5)
  pcol(14, hue + 6, 0.5)
  pcol(18, hue + 12, 0.5)
  pcol(22, hue + 18, 0.5)
  fire(1.75)
end

local hue = 0
while true do
  -- 1. paint the whole screen first: the gradient background, retained
  outStr(1, "1")
  background(hue)
  hue = hue + 3
  -- 2. the morph: square -> circle, colours shifting as it goes
  outStr(1, "2")
  local f = 0
  while f < 10 do
    morph(f / 10.0, hue)
    hue = hue + 3
    f = f + 1
  end
  morph(1.0, hue)
  hue = hue + 3
  -- 3. the mover over the scene, edited slot by slot
  outStr(1, "3")
  local mx, my = 8.0, 12.0
  local vx, vy = 3.0, 2.0
  f = 0
  while f < 8 do
    mover(mx, my, hue)
    hue = hue + 3
    mx = mx + vx
    my = my + vy
    if mx < 4.0 then mx = 4.0 vx = 3.0 end
    if mx > 50.0 then mx = 50.0 vx = -3.0 end
    if my < 6.0 then my = 6.0 vy = 2.0 end
    if my > 48.0 then my = 48.0 vy = -2.0 end
    f = f + 1
  end
  -- 4. delete the mover: an empty push clears slot 3
  outStr(1, "3")
  outNumArr(1, -1.0)
  fire(1.75)
  outStr(1, "")
  nap(2.0)
  -- 5. clearAll: the screen still shows the scene (the pulse only
  -- forgets).  Compose the next one: the background's drawAll is the
  -- pulse that blacks the wall, and the rest builds on top of it.
  outNum(3, 1.0)
  tick()
  tick()
  outNum(3, 0.0)
  tick()
  tick()
  outStr(1, "1")
  background(hue + 16)
  hue = hue + 7
  outStr(1, "2")
  morph(0.5, hue)
  hue = hue + 5
  outStr(1, "3")
  mover(22.0, 22.0, hue + 10)
  outStr(1, "3")
  outNumArr(1, -1.0)
  fire(1.75)
  outStr(1, "")
  nap(2.0)
end
