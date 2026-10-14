-- showcase2: per-point colours, retained editing, the deferred
-- clearAllShapes, the pending queue and per-tick animation.
-- Protocol and wiring: extras/screen/README.md (wall + chip) and
-- extras/cpu-screen-connector/README.md (connector, slot 100 = ticks).
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
local pal = {}
local i = 0
while i < 32 do
local a = i * 0.1963495
pal[i * 3 + 1] = 0.5 + 0.5 * math.sin(a)
pal[i * 3 + 2] = 0.5 + 0.5 * math.sin(a + 2.0943951)
pal[i * 3 + 3] = 0.5 + 0.5 * math.sin(a + 4.1887902)
i = i + 1
end
local function pcol(slot, h, a, k)
h = h % 32
if k == nil then k = 1.0 end
outNumArr(slot, pal[h * 3 + 1] * k, pal[h * 3 + 2] * k,
pal[h * 3 + 3] * k, a)
end
local function xf(px, py, ang, sx, sy)
outStrArr(1, tostring(px), tostring(py), "0", "0", "0",
tostring(ang), tostring(sx), tostring(sy))
outStrArr(9, "1")
end
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
local function background(h)
outNumArr(1, 0.0, 0.0, 64.0, 0.0, 64.0, 64.0, 0.0, 64.0)
outNumArr(9, -5.0)
pcol(10, h, 1.0, 0.16)
pcol(14, h + 8, 1.0, 0.16)
pcol(18, h + 16, 1.0, 0.16)
pcol(22, h + 24, 1.0, 0.16)
xf(0.0, 0.0, 0.0, 1.0, 1.0)
fire(0.8)
end
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
pcol(18, hue, 0.75)
pcol(22, hue + 1, 0.95)
pcol(26, hue + 2, 0.85)
pcol(30, hue + 3, 1.0)
pcol(34, hue + 4, 0.85)
pcol(38, hue + 5, 0.95)
pcol(42, hue + 6, 0.75)
pcol(46, hue + 7, 1.0)
xf(0.0, 0.0, 0.0, 1.0, 1.0)
fire(0.9)
end
local function mover(mx, my, ang, sc, hue)
outNumArr(1, 0.0, 0.0, 8.0, 0.0, 8.0, 6.0, 0.0, 6.0)
outNumArr(9, -5.0)
pcol(10, hue, 0.55)
pcol(14, hue + 2, 0.8)
pcol(18, hue + 4, 0.65)
pcol(22, hue + 6, 1.0)
xf(mx, my, ang, sc, sc)
fire(1.0)
end
local function satellite(hue)
outStr(1, "4")
outStr(2, "3")
outNumArr(1, 10.0, 1.0, 16.0, 1.0, 13.0, 7.0)
outNumArr(7, -4.0)
pcol(8, hue, 1.0)
pcol(12, hue + 10, 1.0)
pcol(16, hue + 20, 1.0)
xf(0.0, 0.0, 0.0, 1.0, 1.0)
fire(1.0)
outStr(2, "")
outStr(1, "3")
end
local function cols4(h, a)
local c = {}
local i = 0
while i < 4 do
local hh = (h + i * 6) % 32
c[i * 4 + 1] = pal[hh * 3 + 1]
c[i * 4 + 2] = pal[hh * 3 + 2]
c[i * 4 + 3] = pal[hh * 3 + 3]
c[i * 4 + 4] = a
i = i + 1
end
return c
end
local function stage(id, pts, cols, px, py, ang, sx, sy)
outStr(1, id)
local n = #pts // 2
local i = 0
while i < n do
outNumArr(i * 2 + 1, pts[i * 2 + 1], pts[i * 2 + 2])
i = i + 1
end
if cols then
outNumArr(n * 2 + 1, -(1 + #cols // 4))
local j = 0
while j < #cols // 4 do
outNumArr(n * 2 + 2 + j * 4, cols[j * 4 + 1], cols[j * 4 + 2],
cols[j * 4 + 3], cols[j * 4 + 4])
j = j + 1
end
else
outNumArr(n * 2 + 1, -1.0)
end
xf(px, py, ang, sx, sy)
outNum(1, 1.0)
tick()
outNum(1, 0.0)
end
local function draw()
outNum(2, 1.0)
tick()
outNum(2, 0.0)
end
local hue = 0
while true do
outStr(1, "1")
background(hue)
hue = hue + 3
outStr(1, "2")
local f = 0
while f < 3 do
morph(f / 3.0, hue)
hue = hue + 3
f = f + 1
end
morph(1.0, hue)
hue = hue + 3
outStr(1, "3")
outStr(2, "")
satellite(hue)
hue = hue + 3
local mx, my = 14.0, 14.0
local vx, vy = 3.0, 2.0
f = 0
while f < 5 do
local sc = 1.0 + 0.25 * math.sin(f * 0.8)
mover(mx, my, f * 0.35, sc, hue)
hue = hue + 3
mx = mx + vx
my = my + vy
if mx < 10.0 then mx = 10.0 vx = 3.0 end
if mx > 46.0 then mx = 46.0 vx = -3.0 end
if my < 10.0 then my = 10.0 vy = 2.0 end
if my > 44.0 then my = 44.0 vy = -2.0 end
f = f + 1
end
outStr(1, "4")
outStr(2, "")
outNumArr(1, -1.0)
fire(1.0)
outStr(1, "3")
outNumArr(1, -1.0)
fire(1.0)
outStr(1, "")
nap(1.0)
stage("2", {30.0, 8.0, 36.0, 14.0, 30.0, 20.0, 24.0, 14.0},
cols4(hue, 1.0), 0.0, 0.0, 0.0, 1.0, 1.0)
hue = hue + 5
stage("4", {40.0, 30.0, 46.0, 30.0, 46.0, 36.0, 40.0, 36.0},
cols4(hue, 1.0), 0.0, 0.0, 0.0, 1.0, 1.0)
hue = hue + 5
stage("0", {8.0, 30.0, 14.0, 30.0, 11.0, 36.0},
cols4(hue, 0.5), 0.0, 0.0, 0.0, 1.0, 1.0)
hue = hue + 5
draw()
nap(1.0)
stage("2", {26.0, 10.0, 34.0, 18.0, 18.0, 18.0, 26.0, 10.0},
cols4(hue, 1.0), 0.0, 0.0, 0.0, 1.0, 1.0)
hue = hue + 5
stage("4", {}, nil, 0.0, 0.0, 0.0, 1.0, 1.0)
draw()
nap(1.0)
outStr(1, "5")
outStr(2, "")
outNumArr(1, 8.0, 44.0, 16.0, 44.0, 12.0, 52.0)
outNumArr(7, -4.0)
pcol(8, hue, 1.0)
pcol(12, hue + 10, 1.0)
pcol(16, hue + 20, 1.0)
xf(0.0, 0.0, 0.0, 1.0, 1.0)
outNumArr(100, -1.0)
fire(0.0)
outStr(1, "")
nap(0.5)
outStr(1, "5")
outNumArr(1, 0.0, 0.0)
outNumArr(3, -1.0)
outNumArr(100, -13.0)
xf(2.0, 0.0, 0.0, 0.0, 0.0)
outNum(1, 1.0)
tick()
outNum(1, 0.0)
draw()
outStr(1, "")
outNumArr(100, -1.0)
nap(0.4)
draw()
nap(1.0)
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
mover(22.0, 22.0, 0.0, 1.0, hue + 10)
outStr(1, "3")
outNumArr(1, -1.0)
fire(1.0)
outStr(1, "")
nap(1.0)
end
