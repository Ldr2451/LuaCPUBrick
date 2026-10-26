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
local pose = {30.5, 33.0, 0.0, 0.45, 0.0, 0.85, 1.0, 1.0, 1.0}
local bgPts = {-30.0, -30.0, -40.0,
                95.0, -30.0, -40.0,
                95.0,  95.0, -40.0,
               -30.0,  95.0, -40.0}
local bgCols = {0.10, 0.10, 0.32, 1.0,
                0.55, 0.12, 0.40, 1.0,
                0.95, 0.55, 0.18, 1.0,
                0.08, 0.50, 0.55, 1.0}
setWire(0)
editShape("1", bgPts, bgCols, nil, "0")
local R = 8.0
local HY = 9.0
local pts = {}
local cols = {}
local k = 0
while k < 12 do
  local a = k * 0.5236
  local cx = math.cos(a) * R
  local cz = math.sin(a) * R
  pts[k * 3 + 1] = cx
  pts[k * 3 + 2] = HY
  pts[k * 3 + 3] = cz
  pts[36 + k * 3 + 1] = cx
  pts[36 + k * 3 + 2] = -HY
  pts[36 + k * 3 + 3] = cz
  cols[k * 4 + 1] = 0.95
  cols[k * 4 + 2] = 0.82
  cols[k * 4 + 3] = 0.35
  cols[k * 4 + 4] = 1.0
  cols[48 + k * 4 + 1] = 0.35
  cols[48 + k * 4 + 2] = 0.55
  cols[48 + k * 4 + 3] = 0.95
  cols[48 + k * 4 + 4] = 1.0
  k = k + 1
end
local top = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12}
local low = {13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24}
local sides = {{1, 13}, {5, 17}, {9, 21}}
setWire(0)
editShape("2", {0.0, 0.0, 0.0}, nil, pose, "0")
pushMesh(pts, cols, {top, low}, nil, "2", nil, 0, 3)
pushMesh(pts, cols, sides, nil, "2", nil, 1, 5)
local disc = {}
local dcol = {}
k = 0
while k < 12 do
  local a = k * 0.5236
  disc[k * 3 + 1] = math.cos(a) * 5.0 + 9.0
  disc[k * 3 + 2] = 0.0
  disc[k * 3 + 3] = math.sin(a) * 5.0 + 11.0
  dcol[k * 4 + 1] = 0.90
  dcol[k * 4 + 2] = 0.10
  dcol[k * 4 + 3] = 0.10
  dcol[k * 4 + 4] = 0.55
  k = k + 1
end
setWire(0)
editShape("8", disc, dcol, nil, "2")
nap(460.0)
local step = 1
while step < 3 do
  local xf = {pose[1] + step * 6.0, pose[2], pose[3], pose[4], pose[5], pose[6],
              pose[7], pose[8], pose[9]}
  editShape("2", {0.0, 0.0, 0.0}, nil, xf, "0")
  nap(460.0)
  step = step + 1
end
local xf = {pose[1] + 2 * 6.0, pose[2], pose[3], pose[4], pose[5], pose[6],
            pose[7], pose[8], pose[9]}
setWire(0)
editShape("8", disc, dcol, xf, "0")
nap(460.0)
local step2 = 3
while step2 < 5 do
  local xf = {pose[1] + step2 * 6.0, pose[2], pose[3], pose[4], pose[5], pose[6],
              pose[7], pose[8], pose[9]}
  editShape("2", {0.0, 0.0, 0.0}, nil, xf, "0")
  nap(460.0)
  step2 = step2 + 1
end
