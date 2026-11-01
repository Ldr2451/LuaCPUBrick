function tick()
local c = clock()
while clock() == c do end
end
function nap(c)
local t = clock()
while clock() < t + c do end
end
local function pulse(slot)
outNumArr(slot, 1.0)
tick()
outNumArr(slot, 0.0)
end
function push()
pulse(200)
end
function draw()
pulse(201)
end
local function putn(slot, t)
local i = 1
while i <= #t do
outNumArr(slot + i - 1, table.unpack(t, i, math.min(i + 7, #t)))
i = i + 8
end
return slot + #t
end
local function num(v)
if v == nil then return 0.0 end
if type(v) == "string" then return tonumber(v) or 0.0 end
return v
end
function rep(t, n)
local out = {}
local i = 1
local k = 0
while k < n do
local j = 1
while j <= #t do
out[i] = t[j]
i = i + 1
j = j + 1
end
k = k + 1
end
return out
end
function setTransform(xf)
outNumArr(206, xf[1], xf[2], xf[3], xf[4], xf[5], xf[6], xf[7], xf[8])
outNumArr(214, xf[9])
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
local termAt = putn(1, pts)
if cols == nil then
outNumArr(termAt, -1.0)
else
outNumArr(termAt, -(1.0 + #cols / 4.0))
putn(termAt + 1, cols)
end
local x = xf
if x == nil then x = {0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0} end
setTransform(x)
outNumArr(203, wire or 0.0, num(id), num(parent))
local t = ticks
if t == nil then t = 0.0 end
if t == -1.0 then
outNumArr(198, -1.0)
elseif t >= 1.0 then
outNumArr(198, -(1.0 + t))
else
outNumArr(198, 0.0)
end
outNumArr(196, #pts * 1.0)
end
function fire(after)
outNumArr(200, 1.0)
tick()
outNumArr(200, 0.0)
outNumArr(201, 1.0)
tick()
outNumArr(201, 0.0)
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
function meshEdges(faces, nv, ea, eb, corner)
local seen = {}
local f = 1
while f <= #faces do
local face = faces[f]
local m = #face
if m > 1 and face[1] == face[m] then
m = m - 1
end
local k = 1
while k <= m do
local a = face[k]
local b = face[k % m + 1]
if a ~= b then
local lo = a
local hi = b
if b < a then
lo = b
hi = a
end
local key = lo * nv + hi
if seen[key] == nil then
seen[key] = 1
ea[#ea + 1] = lo
eb[#eb + 1] = hi
if corner[lo] == nil then
corner[lo] = {}
end
corner[lo][#corner[lo] + 1] = #ea
if corner[hi] == nil then
corner[hi] = {}
end
corner[hi][#corner[hi] + 1] = #ea
end
end
k = k + 1
end
f = f + 1
end
end
function fillMesh(points, pcols, faces, xf, parent, ticks, wire, base)
local f = 1
while f <= #faces do
local face = faces[f]
local m = #face
if m > 1 and face[1] == face[m] then
m = m - 1
end
local pts = {}
local cols = {}
local k = 1
while k <= m + 1 do
local vi = face[(k - 1) % m + 1]
local b = (vi - 1) * 3 + 1
pts[k * 3 - 2] = points[b]
pts[k * 3 - 1] = points[b + 1]
pts[k * 3] = points[b + 2]
if pcols ~= nil then
local c = (vi - 1) * 4 + 1
cols[k * 4 - 3] = pcols[c]
cols[k * 4 - 2] = pcols[c + 1]
cols[k * 4 - 1] = pcols[c + 2]
cols[k * 4] = pcols[c + 3]
end
k = k + 1
end
stage(pts, cols, xf, parent, ticks, wire, tostring(base + f - 1))
push()
f = f + 1
end
end
function pairOddCorners(nv, corner, ea, eb)
local odd = 0
local v = 1
while v <= nv do
if corner[v] ~= nil and #corner[v] % 2 == 1 then
odd = odd + 1
end
v = v + 1
end
local firstdup = 0
while odd >= 2 do
local u = 0
v = 1
while u == 0 and v <= nv do
if corner[v] ~= nil and #corner[v] % 2 == 1 then u = v end
v = v + 1
end
local prevE = {}
local mark = {}
mark[u] = 1
local queue = {u}
local qi = 1
local target = 0
while target == 0 and qi <= #queue do
local cur = queue[qi]
qi = qi + 1
local cs = corner[cur]
local j = 1
while cs ~= nil and j <= #cs and target == 0 do
local eid = cs[j]
local nb = eb[eid]
if nb == cur then nb = ea[eid] end
if mark[nb] == nil then
mark[nb] = 1
prevE[nb] = eid
queue[#queue + 1] = nb
if corner[nb] ~= nil and #corner[nb] % 2 == 1 then target = nb end
end
j = j + 1
end
end
local cur = target
while cur ~= u do
local eid = prevE[cur]
ea[#ea + 1] = ea[eid]
eb[#eb + 1] = eb[eid]
local x = ea[eid]
local y = eb[eid]
corner[x][#corner[x] + 1] = #ea
corner[y][#corner[y] + 1] = #ea
if firstdup == 0 then firstdup = #ea end
if x == cur then
cur = y
else
cur = x
end
end
odd = odd - 2
end
return firstdup
end
function nextStart(nv, corner, used)
local s = 0
local anyv = 0
local v = 1
while v <= nv and s == 0 do
local cs = corner[v]
local left = 0
if cs ~= nil then
local j = 1
while j <= #cs do
if used[cs[j]] == nil then
left = left + 1
end
j = j + 1
end
end
if left > 0 then
if anyv == 0 then anyv = v end
if left % 2 == 1 then s = v end
end
v = v + 1
end
if s == 0 then s = anyv end
return s
end
function tourMesh(s, corner, used, ea, eb, path)
local stack = {s}
local top = 1
local pn = 0
while top > 0 do
local cur = stack[top]
local moved = 0
local cs = corner[cur]
if cs ~= nil then
local j = 1
while j <= #cs and moved == 0 do
local e = cs[j]
if used[e] == nil then
used[e] = 1
local w = eb[e]
if w == cur then w = ea[e] end
top = top + 1
stack[top] = w
moved = 1
end
j = j + 1
end
end
if moved == 0 then
pn = pn + 1
path[pn] = cur
top = top - 1
end
end
return pn
end
function sendWalk(points, pcols, path, xf, parent, ticks, wire, base)
local nsh = 0
local at = #path
while at >= 1 do
local from = at - 15
if from < 1 then from = 1 end
local pts = {}
local cols = {}
local np = 0
local i = at
while i >= from do
local vi = path[i]
local b = (vi - 1) * 3 + 1
np = np + 1
pts[np * 3 - 2] = points[b]
pts[np * 3 - 1] = points[b + 1]
pts[np * 3] = points[b + 2]
if pcols ~= nil then
local c = (vi - 1) * 4 + 1
cols[np * 4 - 3] = pcols[c]
cols[np * 4 - 2] = pcols[c + 1]
cols[np * 4 - 1] = pcols[c + 2]
cols[np * 4] = pcols[c + 3]
end
i = i - 1
end
stage(pts, cols, xf, parent, ticks, wire, tostring(base + nsh))
push()
nsh = nsh + 1
if from > 1 then
at = from
else
at = 0
end
end
return nsh
end
function pushMesh(points, pcols, faces, xf, parent, ticks, wire, firstId)
local base = firstId
if base == nil then base = 0 end
local nv = (#points / 3) | 0
local ea = {}
local eb = {}
local corner = {}
meshEdges(faces, nv, ea, eb, corner)
if wire == nil or wire == 0 or wire == false then
fillMesh(points, pcols, faces, xf, parent, ticks, wire, base)
return
end
local firstdup = pairOddCorners(nv, corner, ea, eb)
local used = {}
if firstdup ~= 0 then
used[firstdup] = 1
end
local nsh = 0
while true do
local s = nextStart(nv, corner, used)
if s == 0 then
break
end
local path = {}
tourMesh(s, corner, used, ea, eb, path)
nsh = nsh + sendWalk(points, pcols, path, xf, parent, ticks, wire,
base + nsh)
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
outNumArr(202, 1.0)
tick()
outNumArr(202, 0.0)
draw()
if after ~= nil then
if after > 0.0 then nap(after) end
end
end
clearScreen()
local sq = {-6.0, -6.0, 6.0, -6.0, 6.0, 6.0, -6.0, 6.0, -6.0, -6.0}
local bar = {-3.0, -4.0, 3.0, -4.0, 3.0, 4.0, -3.0, 4.0, -3.0, -4.0}
local dia = {0.0, -2.5, 2.5, 0.0, 0.0, 2.5, -2.5, 0.0, 0.0, -2.5}
local scol = {0.25, 0.55, 1.0, 1.0, 0.25, 0.55, 1.0, 1.0,
              0.35, 0.70, 1.0, 1.0, 0.35, 0.70, 1.0, 1.0,
              0.25, 0.55, 1.0, 1.0}
local bcol = {1.0, 0.80, 0.25, 1.0, 1.0, 0.80, 0.25, 1.0,
              1.0, 0.65, 0.15, 1.0, 1.0, 0.65, 0.15, 1.0,
              1.0, 0.80, 0.25, 1.0}
local dcol = {1.0, 0.20, 0.85, 1.0, 1.0, 0.20, 0.85, 1.0,
              1.0, 0.20, 0.85, 1.0, 1.0, 0.20, 0.85, 1.0,
              1.0, 0.20, 0.85, 1.0}
stagePush2d(dia, dcol, {3.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0},
            "1", nil, 0, "3")
local ss = {0.35, 0.60, 0.95, 1.35, 1.80, 2.20, 1.80, 1.35, 0.95, 0.60}
local xx = {0.40, 0.70, 1.10, 1.50, 1.90, 2.30, 1.90, 1.50, 1.10, 0.70}
local f = 0
while f < 10 do
  local s = ss[f + 1]
  stagePush2d(sq, scol,
              {18.0, 20.0, 0.0, 0.0, 0.0, 0.0, s, s, 1.0},
              "0", nil, 0, "1")
  stagePush2d(bar, bcol,
              {46.0, 44.0, 0.0, 0.0, 0.0, 0.0, xx[f + 1], 1.0, 1.0},
              "0", nil, 0, "2")
  draw()
  nap(224.0)
  f = f + 1
end
