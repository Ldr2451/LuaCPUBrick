function tick()
local c = clock()
while clock() == c do end
end
function nap(c)
local t = clock()
while clock() < t + c do end
end
local function pulse(n)
outNum(n, 1.0)
tick()
outNum(n, 0.0)
end
function push()
pulse(1)
end
function draw()
pulse(2)
end
local function putn(slot, t)
local i = 1
while i <= #t do
outNumArr(slot + i - 1, table.unpack(t, i, math.min(i + 7, #t)))
i = i + 8
end
return slot + #t
end
function setWire(on)
outNum(4, on)
end
function setTransform(xf)
local i = 1
while i <= 9 do
outStrArr(i, tostring(xf[i]))
i = i + 1
end
end
function stage(pts, cols, xf, parent, ticks, wire, id)
local n = #pts // 2
outNumArr(98, n * 1.0)
local termAt = putn(1, pts)
if cols == nil then
outNumArr(termAt, -1.0)
else
outNumArr(termAt, -(1.0 + #cols / 4.0))
putn(termAt + 1, cols)
end
local x = xf
if x == nil then x = {0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0} end
local j = 1
while j <= 9 do
outStrArr(j, tostring(x[j]))
j = j + 1
end
local p = parent
if p == nil then p = "0" end
outStr(2, tostring(p))
local s = id
if s == nil then s = "" end
outStr(1, tostring(s))
if wire ~= nil then outNum(4, wire) end
local t = ticks
if t == nil then t = 0.0 end
if t == -1.0 then
outNumArr(100, -1.0)
elseif t >= 1.0 then
outNumArr(100, -(1.0 + t))
else
outNumArr(100, 0.0)
end
end
function fire(after)
outNum(1, 1.0)
tick()
outNum(1, 0.0)
outNum(2, 1.0)
tick()
outNum(2, 0.0)
if after ~= nil then
if after > 0.0 then nap(after) end
end
end
function stagePush(pts, cols, xf, parent, ticks, wire, id)
stage(pts, cols, xf, parent, ticks, wire, id)
push()
end
function triangulate(pts)
local n = #pts // 2
local tris = {}
if n < 3 then return tris end
local V = {}
local i = 1
while i <= n do V[i] = i i = i + 1 end
local nv = n
local area = 0.0
local k = 1
while k <= n do
local x1 = pts[(k - 1) * 2 + 1]
local y1 = pts[(k - 1) * 2 + 2]
local m = k + 1
if m > n then m = 1 end
area = area + (pts[(m - 1) * 2 + 1] - x1) * (pts[(m - 1) * 2 + 2] + y1)
k = k + 1
end
local ccw = area < 0.0
local guard = 0
while nv > 3 and guard < n * n do
guard = guard + 1
local v = 1
local done = false
while v <= nv and not done do
local i0 = V[v - 1] or V[nv]
local i1 = V[v]
local i2 = V[v + 1] or V[1]
local ax = pts[(i0 - 1) * 2 + 1]
local ay = pts[(i0 - 1) * 2 + 2]
local bx = pts[(i1 - 1) * 2 + 1]
local by = pts[(i1 - 1) * 2 + 2]
local cx = pts[(i2 - 1) * 2 + 1]
local cy = pts[(i2 - 1) * 2 + 2]
local convex = (ccw and (bx - ax) * (cy - ay) - (by - ay) * (cx - ax) > 0.0) or ((not ccw) and (bx - ax) * (cy - ay) - (by - ay) * (cx - ax) < 0.0)
local clear = true
if convex then
local j = 1
while j <= nv do
local q = V[j]
if q ~= i0 and q ~= i1 and q ~= i2 then
local d1 = (ax - pts[(q - 1) * 2 + 1]) * (by - pts[(q - 1) * 2 + 2]) - (ay - pts[(q - 1) * 2 + 2]) * (bx - pts[(q - 1) * 2 + 1])
local d2 = (bx - pts[(q - 1) * 2 + 1]) * (cy - pts[(q - 1) * 2 + 2]) - (by - pts[(q - 1) * 2 + 2]) * (cx - pts[(q - 1) * 2 + 1])
local d3 = (cx - pts[(q - 1) * 2 + 1]) * (ay - pts[(q - 1) * 2 + 2]) - (cy - pts[(q - 1) * 2 + 2]) * (ax - pts[(q - 1) * 2 + 1])
if (d1 >= 0.0 and d2 >= 0.0 and d3 >= 0.0) or (d1 <= 0.0 and d2 <= 0.0 and d3 <= 0.0) then clear = false end
end
j = j + 1
end
end
if convex and clear then
tris[#tris + 1] = {ax, ay, bx, by, cx, cy}
while v < nv do V[v] = V[v + 1] v = v + 1 end
V[nv] = nil
nv = nv - 1
done = true
end
v = v + 1
end
if not done then break end
end
if nv == 3 then
tris[#tris + 1] = {pts[(V[1] - 1) * 2 + 1], pts[(V[1] - 1) * 2 + 2], pts[(V[2] - 1) * 2 + 1], pts[(V[2] - 1) * 2 + 2], pts[(V[3] - 1) * 2 + 1], pts[(V[3] - 1) * 2 + 2]}
end
return tris
end
local function isConvex(pts)
local n = #pts // 2
if n < 3 then return true end
local sgn = 0.0
local i = 1
while i <= n do
local i0 = i - 1
if i0 < 1 then i0 = n end
local i2 = i + 1
if i2 > n then i2 = 1 end
local ax = pts[(i0 - 1) * 2 + 1]
local ay = pts[(i0 - 1) * 2 + 2]
local bx = pts[(i - 1) * 2 + 1]
local by = pts[(i - 1) * 2 + 2]
local cx = pts[(i2 - 1) * 2 + 1]
local cy = pts[(i2 - 1) * 2 + 2]
local cr = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
if cr > 0.0 then
if sgn < 0.0 then return false end
sgn = 1.0
elseif cr < 0.0 then
if sgn > 0.0 then return false end
sgn = -1.0
end
i = i + 1
end
return true
end
function pushMesh(first, faces, parent)
local id = first
local k = 1
while k <= #faces do
local fc = faces[k]
local polys = {fc.pts}
if not isConvex(fc.pts) then polys = triangulate(fc.pts) end
local p = 1
while p <= #polys do
if id > 8.0 then error("pushMesh: slots 1..8 hold " .. #faces .. " faces", 0) end
local poly = polys[p]
local cc = fc.col
if cc ~= nil and #cc == 4 then
local ex = {}
local m = 0
while m < #poly // 2 do
ex[m * 4 + 1] = cc[1]
ex[m * 4 + 2] = cc[2]
ex[m * 4 + 3] = cc[3]
ex[m * 4 + 4] = cc[4]
m = m + 1
end
cc = ex
end
stagePush(poly, cc, fc.xf, parent, nil, nil, tostring(id))
id = id + 1.0
p = p + 1
end
k = k + 1
end
end
function pushShape(pts, cols, xf, parent)
stage(pts, cols, xf, parent, nil, nil, "")
fire()
end
function editShape(id, pts, cols, xf, parent, ticks)
stage(pts, cols, xf, parent, ticks, nil, id)
fire()
end
function deleteShape(id)
stage({}, nil, nil, "0", nil, nil, id)
fire()
end
function clearScreen(after)
outNum(3, 1.0)
tick()
outNum(3, 0.0)
draw()
if after ~= nil then
if after > 0.0 then nap(after) end
end
end
clearScreen()
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
setTransform({0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0})
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
setTransform({0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0})
fire(0.9)
end
local function mover(mx, my, ang, sc, hue)
outNumArr(1, 0.0, 0.0, 8.0, 0.0, 8.0, 6.0, 0.0, 6.0)
outNumArr(9, -5.0)
pcol(10, hue, 0.55)
pcol(14, hue + 2, 0.8)
pcol(18, hue + 4, 0.65)
pcol(22, hue + 6, 1.0)
setTransform({mx, my, 0.0, 0.0, 0.0, ang, sc, sc, 1.0})
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
setTransform({0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0})
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
deleteShape("4")
nap(1.0)
outStr(1, "3")
deleteShape("3")
nap(1.0)
outStr(1, "")
nap(1.0)
stagePush({30.0, 8.0, 36.0, 14.0, 30.0, 20.0, 24.0, 14.0},
cols4(hue, 1.0), {0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0},
nil, nil, nil, "2")
hue = hue + 5
stagePush({40.0, 30.0, 46.0, 30.0, 46.0, 36.0, 40.0, 36.0},
cols4(hue, 1.0), {0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0},
nil, nil, nil, "4")
hue = hue + 5
stagePush({8.0, 30.0, 14.0, 30.0, 11.0, 36.0},
cols4(hue, 0.5), {0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0},
nil, nil, nil, "0")
hue = hue + 5
draw()
nap(1.0)
stagePush({26.0, 10.0, 34.0, 18.0, 18.0, 18.0, 26.0, 10.0},
cols4(hue, 1.0), {0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0},
nil, nil, nil, "2")
hue = hue + 5
stagePush({}, nil, {0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0},
nil, nil, nil, "4")
draw()
nap(1.0)
outStr(1, "5")
outStr(2, "")
outNumArr(1, 8.0, 44.0, 16.0, 44.0, 12.0, 52.0)
outNumArr(7, -4.0)
pcol(8, hue, 1.0)
pcol(12, hue + 10, 1.0)
pcol(16, hue + 20, 1.0)
setTransform({0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0})
outNumArr(100, 0.0)
fire(0.0)
outStr(1, "")
nap(0.5)
outStr(1, "5")
stagePush({0.0, 0.0}, nil, {2.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0},
nil, 12.0, nil, "5")
draw()
outStr(1, "")
outNumArr(100, 0.0)
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
