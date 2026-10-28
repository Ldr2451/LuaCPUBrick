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
function setTransform(xf)
local i = 1
while i <= 9 do
outStrArr(i, tostring(xf[i]))
i = i + 1
end
end
local function asTriples(pts)
local out = {}
local i = 1
while i <= #pts do
out[#out + 1] = pts[i]
out[#out + 1] = pts[i + 1]
out[#out + 1] = 0.0
i = i + 2
end
return out
end
function stage2d(pts, cols, xf, parent, ticks, wire, id)
stage(asTriples(pts), cols, xf, parent, ticks, wire, id)
end
function stage(pts, cols, xf, parent, ticks, wire, id)
outNumArr(98, #pts * 1.0)
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
outNum(4, wire or 0.0)
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
function stagePush2d(pts, cols, xf, parent, ticks, wire, id)
stage(asTriples(pts), cols, xf, parent, ticks, wire, id)
push()
end
function pushMesh(points, pcols, faces, xf, parent, ticks, wire, firstId)
local base = firstId
if base == nil then base = 0 end
local f = 1
local nfaces = #faces
while f <= nfaces do
local face = faces[f]
local m = #face
local pts = {}
local cols = {}
local np = 0
local nc = 0
local k = 1
while k <= m do
local vi = face[k]
local b = (vi - 1) * 3 + 1
np = np + 1
pts[np] = points[b]
np = np + 1
pts[np] = points[b + 1]
np = np + 1
pts[np] = points[b + 2]
if pcols ~= nil then
local c = (vi - 1) * 4 + 1
nc = nc + 1
cols[nc] = pcols[c]
nc = nc + 1
cols[nc] = pcols[c + 1]
nc = nc + 1
cols[nc] = pcols[c + 2]
nc = nc + 1
cols[nc] = pcols[c + 3]
end
k = k + 1
end
np = np + 1
pts[np] = pts[1]
np = np + 1
pts[np] = pts[2]
np = np + 1
pts[np] = pts[3]
if pcols ~= nil then
nc = nc + 1
cols[nc] = cols[1]
nc = nc + 1
cols[nc] = cols[2]
nc = nc + 1
cols[nc] = cols[3]
nc = nc + 1
cols[nc] = cols[4]
end
stage(pts, cols, xf, parent, ticks, wire, tostring(base + f - 1))
push()
f = f + 1
end
end
function pushShape(pts, cols, xf, parent, wire)
stage(pts, cols, xf, parent, nil, wire, "")
fire()
end
function editShape(id, pts, cols, xf, parent, ticks, wire)
stage(pts, cols, xf, parent, ticks, wire, id)
fire()
end
function camera(xf, ticks)
if xf == nil then
editShape("-1", {}, nil, nil, "0", nil, 0.0)
else
editShape("-1", {0.0, 0.0, 0.0}, nil, xf, "0", ticks, 0.0)
end
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
local n = 11
local wcols = {}
local i = 0
while i < n do
  local t = i / (n - 1)
  wcols[#wcols + 1] = 1.0 - 0.85 * t
  wcols[#wcols + 1] = 0.25 + 0.70 * t
  wcols[#wcols + 1] = 0.35
  wcols[#wcols + 1] = 1.0
  i = i + 1
end
local function wave(ph)
  local pts = {}
  local k = 0
  while k < n do
    local t = k / (n - 1)
    pts[#pts + 1] = 5.0 + 54.0 * t
    pts[#pts + 1] = 20.0 + 9.0 * math.sin(ph + 6.2 * t)
    k = k + 1
  end
  stagePush2d(pts, wcols, nil, "0", nil, 1, "1")
end
local arc = {}
i = 0
while i < 9 do
  local a = 3.141592653589793 * i / 8.0
  arc[#arc + 1] = 18.0 + 11.0 * math.cos(a)
  arc[#arc + 1] = 46.0 - 9.0 * math.sin(a)
  i = i + 1
end
local acols = {}
i = 0
while i < 9 do
  acols[#acols + 1] = 0.95
  acols[#acols + 1] = 0.80
  acols[#acols + 1] = 0.25
  acols[#acols + 1] = 1.0
  i = i + 1
end
stagePush2d(arc, acols, nil, "0", nil, 1, "2")
local chev = {40.0, 52.0, 49.0, 40.0, 58.0, 52.0}
local ccols = {0.3, 0.8, 1.0, 1.0, 0.3, 0.8, 1.0, 1.0,
               0.3, 0.8, 1.0, 1.0}
stagePush2d(chev, ccols, nil, "0", nil, 1, "3")
local f = 0
while f < 10 do
  wave(f * 0.55)
  draw()
  nap(420.0)
  f = f + 1
end
