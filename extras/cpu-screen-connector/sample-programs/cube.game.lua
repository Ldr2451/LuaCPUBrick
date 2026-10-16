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
setWire(1.0)
local Q = {-15.5, -15.5, 15.5, -15.5, 15.5, 15.5, -15.5, 15.5, -15.5, -15.5}
local function F(px, py, pz, rx, ry, col)
return {pts = Q, col = col, xf = {px, py, pz, rx, ry, 0.0, 1.0, 1.0, 1.0}}
end
pushMesh(2, {
F(0.0, 0.0, 8.0, 0.0, 0.0, nil),
F(0.0, 0.0, -8.0, 0.0, 0.0, {0.25, 0.25, 0.3, 1.0}),
F(-8.0, 0.0, 0.0, 0.0, 1.05, {0.9, 0.25, 0.25, 1.0}),
F(8.0, 0.0, 0.0, 0.0, -1.05, {0.25, 0.85, 0.35, 1.0}),
F(0.0, -8.0, 0.0, 1.05, 0.0, {0.9, 0.85, 0.3, 1.0}),
F(0.0, 8.0, 0.0, -1.05, 0.0, {0.3, 0.8, 0.9, 1.0}),
}, "1")
editShape("1", {-1.5, 0.0, 2.0, 0.0, 0.5, 3.0}, nil, {32.0, 32.0, 0.0, 0.0, 0.35, 0.0, 1.0, 1.0, 1.0}, "0")
stage({}, nil, {0.0, 0.0, 0.0, 0.0, 0.012, 0.05, 0.0, 0.0, 0.0}, "0", -1.0, nil, "1")
push()
