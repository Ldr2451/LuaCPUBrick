-- Temporary probe (delete after measuring): the tallest stroke the
-- protocol can send: 13 colored points (colours must stay under slot 98)
-- zigzagging rows 2..60, pushed and redrawn like curve.lua's wave.
local pts = {}
local i = 0
while i < 13 do
  pts[#pts + 1] = 2.0 + 60.0 * i / 12.0
  pts[#pts + 1] = (i % 2) * 58.0 + 2.0
  i = i + 1
end
local cols = {}
i = 0
while i < 13 do
  cols[#cols + 1] = 1.0
  cols[#cols + 1] = 1.0
  cols[#cols + 1] = 1.0
  cols[#cols + 1] = 1.0
  i = i + 1
end
local f = 0
while f < 3 do
  stagePush2d(pts, cols, nil, "0", nil, 1, "1")
  draw()
  nap(2.0)
  f = f + 1
end

