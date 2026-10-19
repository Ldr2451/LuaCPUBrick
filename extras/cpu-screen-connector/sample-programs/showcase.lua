clearScreen()
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
local function square(bx, by)
local ex, ey = bx + 10.0, by + 10.0
outNumArr(1, bx, by, 0.0, ex, by, 0.0, ex, ey, 0.0, bx, ey, 0.0)
outNumArr(9, -1.0)
fire(0.16)
end
local function tri(tx)
outNumArr(1, 22.0, 10.0, 0.0, 42.0, 10.0, 0.0, tx, 30.0, 0.0)
outNumArr(7, -1.0)
fire(0.26)
end
local function wire(k)
local x0 = 32.0 + cs[k + 1]
local y0 = 32.0 + rs[k + 1]
local x1 = 32.0 - rs[k + 1]
local y1 = 32.0 + cs[k + 1]
local x2 = 32.0 - cs[k + 1]
local y2 = 32.0 - rs[k + 1]
local x3 = 32.0 + rs[k + 1]
local y3 = 32.0 - cs[k + 1]
outNumArr(1, x0, y0, 0.0, x1, y1, 0.0, x2, y2, 0.0, x3, y3, 0.0)
outNumArr(9, x0, y0, -1.0)
fire(0.36)
end
local function wave(f)
outNumArr(1, 0.0, 32.0 + sn[(f % 32) + 1], 0.0, 4.0, 32.0 + sn[((f + 2) % 32) + 1], 0.0, 8.0, 32.0 + sn[((f + 4) % 32) + 1], 0.0, 12.0, 32.0 + sn[((f + 6) % 32) + 1], 0.0)
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
local function octagon(cx, cy, r)
local k = r * 0.4142136
local x0, x1 = cx - r, cx + r
local y0, y1 = cy - r, cy + r
outNumArr(1, cx - k, y0, 0.0, cx + k, y0, 0.0, x1, cy - k, 0.0, x1, cy + k, 0.0)
outNumArr(9, cx + k, y1, cx - k, y1, x0, cy + k, x0, cy - k)
outNumArr(17, -1.0)
fire(1.2)
end
local function ring()
outNumArr(1, 32.0 + cs[1] * 18.0 / 14.0 // 1.0, 32.0 + rs[1] * 18.0 / 14.0 // 1.0, 0.0, 32.0 + cs[2] * 18.0 / 14.0 // 1.0, 32.0 + rs[2] * 18.0 / 14.0 // 1.0, 0.0, 32.0 + cs[3] * 18.0 / 14.0 // 1.0, 32.0 + rs[3] * 18.0 / 14.0 // 1.0, 0.0, 32.0 + cs[4] * 18.0 / 14.0 // 1.0, 32.0 + rs[4] * 18.0 / 14.0 // 1.0, 0.0)
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
local n = 0
while n < 24 do
square(bx, by)
bx = bx + vx
by = by + vy
if bx < 2.0 then bx = 2.0 vx = 2.0 end
if bx > 52.0 then bx = 52.0 vx = -2.0 end
if by < 2.0 then by = 2.0 vy = 1.0 end
if by > 52.0 then by = 52.0 vy = -1.0 end
n = n + 1
end
n = 0
while n < 24 do
local d = (f * 3) % 88
if d > 44.0 then d = 88.0 - d end
tri(10.0 + d)
f = f + 1
n = n + 1
end
setWire(1.0)
n = 0
while n < 16 do
wire(f % 16)
f = f + 1
n = n + 1
end
n = 0
while n < 8 do
wave(f)
f = f + 1
n = n + 1
end
setWire(0.0)
setWire(1.0)
outStr(1, "1")
outNumArr(1, 2.0, 2.0, 0.0, 62.0, 2.0, 0.0, 62.0, 62.0, 0.0, 2.0, 62.0, 0.0)
outNumArr(9, 2.0, 2.0, -1.0)
fire(1.2)
setWire(0.0)
outStr(1, "2")
octagon(16.0, 44.0, 7.0)
outStr(1, "3")
octagon(48.0, 44.0, 7.0)
octagon(40.0, 30.0, 7.0)
outStr(1, "2")
outNumArr(1, -1.0)
fire(1.2)
outStr(1, "")
bx, by = 8.0, 8.0
vx, vy = 3.0, 2.0
n = 0
while n < 18 do
local ex, ey = bx + 6.0, by + 6.0
outNumArr(1, bx, by, 0.0, ex, by, 0.0, ex, ey, 0.0, bx, ey, 0.0)
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
outNum(3, 1.0)
tick()
tick()
outNum(3, 0.0)
nap(0.6)
ring()
nap(1.0)
end
