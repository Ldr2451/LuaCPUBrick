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
local h = 10.0
local rest = {
  -h, -h, h,   h, -h, h,   h, h, h,   -h, h, h,
  -h, -h, -h,  h, -h, -h,  h, h, -h,  -h, h, -h,
}
local cols = {
  0.95, 0.95, 1.00, 1.00,
  0.95, 0.90, 0.85, 1.00,
  0.95, 0.85, 0.55, 1.00,
  0.90, 0.80, 0.50, 1.00,
  0.35, 0.30, 0.35, 1.00,
  0.40, 0.35, 0.40, 1.00,
  0.45, 0.40, 0.45, 1.00,
  0.40, 0.35, 0.40, 1.00,
}
local faces = {
  {1, 2, 3, 4},
  {5, 8, 7, 6},
  {1, 5, 6, 2},
  {4, 3, 7, 8},
  {1, 4, 8, 5},
  {2, 6, 7, 3},
}
setWire(0)
editShape("1", {0.0, 0.0, 0.0}, nil,
          {32.0, 32.0, 0.0, 0.35, 0.0, 0.0, 1.0, 1.0, 1.0}, "0")
-- No forever spin here: re-pushing the faces under a spinning pivot
-- tips the near corners toward the eye plane and the perspective
-- divide blows the stroke across the whole wall (measured).  The tilt
-- stays; the turn is the cube demo's job.
push()
local f = 0
while f < 8 do
  local ph = f * 0.75
  local pts = {}
  local k = 0
  while k < 8 do
    -- One phase for the whole body, plus a small per-vertex ripple:
    -- x stretches longitudinally and y/z pinch gently, so the cube
    -- elongates and flattens as a solid instead of tearing apart.  The
    -- pinch is shallow on purpose: the tilted pivot tips z toward the
    -- eye plane, and past about z 12 the perspective divide inflates a
    -- vertex across the whole wall -- the cube demo keeps z' near 11.5,
    -- so this stays at x 12 and y/z 9, inside the same envelope.
    local w = math.sin(ph)
    local r = 0.03 * math.sin(ph + k * 1.9)
    pts[#pts + 1] = rest[k * 3 + 1] * (1.0 + 0.20 * w + r)
    pts[#pts + 2] = rest[k * 3 + 2] * (1.0 - 0.10 * w - r)
    pts[#pts + 3] = rest[k * 3 + 3] * (1.0 - 0.10 * w - r)
    k = k + 1
  end
  pushMesh(pts, cols, faces, nil, "1", nil, 1.0, 2)
  draw()
  nap(420.0)
  f = f + 1
end
