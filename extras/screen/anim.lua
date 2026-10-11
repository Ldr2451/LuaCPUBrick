-- Rainbow spirograph -- driver for the 64x64 rect-fill screen.
-- Paste into the Lua chip's `program` and hold `run` high.
--
-- Wires (all numbers, so a plain 1->1 wiring works):
--   outNum1   -> pushRect    (pulse: 1 then 0)
--   outNum2   -> redrawAll   (pulse: 1 then 0, after each push)
--   outNumArr -> the screen's 8 params:
--                1 x0  2 y0  3 x1  4 y1  5 r  6 g  7 b  8 a
--
-- Two hypotrochoid tracers (8x8 rainbow blocks) sweep opposite halves
-- of one curve, so the whole spirograph closes in half the frames.
-- The screen keeps colors until rewritten, so the orbit paints itself
-- into a full web across the wall.  On close the core breathes for a
-- while, the wall is repainted black in one 64-tick burst, and the
-- next curve starts.  Five curves, then repeat.
--
-- Chip facts this program is built around (see extras/screen/README):
--  - calls are capped at 8 parameters, so the 8 rect params go out as
--    two outNumArr writes: bounds at slot 1, color at slot 5
--  - clock() advances 0.01 per tick, so a pulse held across one clock
--    change is high for a full tick: the screen's on-Change ports see
--    a real edge, and every burst is waited out so the next redrawAll
--    can never catch a burst mid-flight (a re-arm would repaint the
--    half-done rect with the new colour -- torn pixels)
--  - the painter forms its pixel index as ly*64 + lx and truncates
--    the SUM once, so bounds are snapped to whole pixels (a fractional
--    y bleeds 64ths of a tile into x)
--  - the lexer runs 2 chars/tick: source size is boot time

-- {R, r, d, tmax}: extent (R-r)+d <= 31 sweeps the wall edge to edge;
-- tmax = 2*pi*r/gcd(R,r) is when the curve closes; two tracers half a
-- curve apart close it in tmax/2 ticks of t, and a 0.25 rad step puts
-- 8px between dots -- exactly one 8x8 block, the biggest that still
-- burns in a single paint tick (64 px).
local sets = {
  {26.0, 12.0, 16.0, 37.7},
  {24.0, 10.0, 16.0, 31.4},
  {28.0, 16.0, 18.0, 25.1},
  {22.0, 8.0, 14.0, 25.1},
  {20.0, 6.0, 14.0, 18.8},
}

-- A rainbow angle: three sines a third of a turn apart, halved and
-- lifted into 0..1.  Cheap where each trig call is a gate.
local function rainbow(h)
  return 0.5 + 0.5 * math.sin(h),
         0.5 + 0.5 * math.sin(h + 2.0943951),
         0.5 + 0.5 * math.sin(h + 4.1887902)
end

local cx = 32.0
local idx = 1
local mode = 0
local t = 0.0
local hue = 0.0
local hcore = 0.0
local hold = 0

-- One whole-pixel hypotrochoid point.  //1.0 is a third of a
-- math.floor call, and the painter needs whole pixels.
local function plot(ti)
  local p = sets[idx]
  local u = (p[1] - p[2]) / p[2]
  local x = (p[1] - p[2]) * math.cos(ti) + p[3] * math.cos(u * ti)
  local y = (p[1] - p[2]) * math.sin(ti) - p[3] * math.sin(u * ti)
  return (cx + x - 4.0) // 1.0, (cx + y - 4.0) // 1.0
end

-- Stage one rect and fire its burst, with the barriers inlined: a
-- call frame per pulse was a third of the sync cost.
local function rect(x0, y0, x1, y1, rr, gg, bb, aa)
  outNumArr(1, x0, y0, x1, y1)
  outNumArr(5, rr, gg, bb, aa)
  local c = clock()
  outNum(1, 1.0)
  while clock() == c do end
  c = clock()
  outNum(1, 0.0)
  outNum(2, 1.0)
  while clock() == c do end
  c = clock()
  outNum(2, 0.0)
  while clock() == c do end
end

local function clearAll()
  outNumArr(1, 0.0, 0.0, 63.0, 63.0)
  outNumArr(5, 0.0, 0.0, 0.0, 1.0)
  local c = clock()
  outNum(1, 1.0)
  while clock() == c do end
  c = clock()
  outNum(1, 0.0)
  outNum(2, 1.0)
  while clock() == c do end
  c = clock()
  outNum(2, 0.0)
  while clock() == c do end
  local n = 66
  while n > 0 do
    c = clock()
    while clock() == c do end
    n = n - 1
  end
end

while true do
  if mode == 0 then
    local half = sets[idx][4] * 0.5
    local rr, rg, rb = rainbow(hue)
    local br, bg, bb = rainbow(hue + 3.141592653589793)
    -- tracer A at t, tracer B half a curve behind
    local ax, ay = plot(t)
    local bx, by = plot(t + half)
    rect(ax, ay, ax + 7.0, ay + 7.0, rr, rg, rb, 1.0)
    rect(bx, by, bx + 7.0, by + 7.0, br, bg, bb, 1.0)
    t = t + 0.25
    hue = hue + 0.21
    if t >= half then
      mode = 1
      hold = 60
    end
  elseif mode == 1 then
    local cr, cg, cb = rainbow(hcore)
    local q = (cx - 4.0) // 1.0
    rect(q, q, q + 7.0, q + 7.0, cr, cg, cb, 0.5)
    hcore = hcore + 0.09
    hold = hold - 1
    if hold <= 0 then
      mode = 2
    end
  else
    clearAll()
    idx = idx + 1
    if idx > 5 then
      idx = 1
    end
    t = 0.0
    hue = 0.0
    mode = 0
  end
end
