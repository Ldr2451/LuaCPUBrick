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
local cr = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
local convex = (ccw and cr > 0.0) or ((not ccw) and cr < 0.0)
local clear = true
if convex then
local j = 1
while j <= nv do
local q = V[j]
if q ~= i0 and q ~= i1 and q ~= i2 then
local px = pts[(q - 1) * 2 + 1]
local py = pts[(q - 1) * 2 + 2]
local d1 = (ax - px) * (by - py) - (ay - py) * (bx - px)
local d2 = (bx - px) * (cy - py) - (by - py) * (cx - px)
local d3 = (cx - px) * (ay - py) - (cy - py) * (ax - px)
if ccw then
if d1 > 0.0 and d2 > 0.0 and d3 > 0.0 then clear = false end
else
if d1 < 0.0 and d2 < 0.0 and d3 < 0.0 then clear = false end
end
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
clearScreen()
local sets = {
  {26.0, 12.0, 16.0, 37.7},
  {24.0, 10.0, 16.0, 31.4},
  {28.0, 16.0, 18.0, 25.1},
  {22.0, 8.0, 14.0, 25.1},
  {20.0, 6.0, 14.0, 18.8},
}
local pal = {}
local i = 0
while i < 32 do
  local a = i * 0.1963495
  pal[i * 3 + 1] = 0.5 + 0.5 * math.sin(a)
  pal[i * 3 + 2] = 0.5 + 0.5 * math.sin(a + 2.0943951)
  pal[i * 3 + 3] = 0.5 + 0.5 * math.sin(a + 4.1887902)
  i = i + 1
end
local cx = 32.0
local idx = 1
local mode = 0
local t = 0.0
local hue = 0
local hcore = 0
local hold = 0
local flip = 0
local function plot(ti)
  local p = sets[idx]
  local u = (p[1] - p[2]) / p[2]
  local x = (p[1] - p[2]) * math.cos(ti) + p[3] * math.cos(u * ti)
  local y = (p[1] - p[2]) * math.sin(ti) - p[3] * math.sin(u * ti)
  return (cx + x - 4.0) // 1.0, (cx + y - 4.0) // 1.0
end
local function tracer(bx, by, h)
  local ex, ey = bx + 8.0, by + 8.0
  outNumArr(1, bx, by, ex, by, ex, ey, bx, ey)
  outNumArr(9, -1.0)
  fire()
end
local function core(r, h)
  local k = r * 0.4142136
  local x0, x1 = cx - r, cx + r
  local y0, y1 = cx - r, cx + r
  local kx0, kx1 = cx - k, cx + k
  local ky0, ky1 = cx - k, cx + k
  outNumArr(1, kx0, y0, kx1, y0, x1, ky0, x1, ky1)
  outNumArr(9, kx1, y1, kx0, y1, x0, ky1, x0, ky0)
  outNumArr(17, -1.0)
  fire()
end
while true do
  if mode == 0 then
    local tmax = sets[idx][4]
    if flip == 0 then
      local ax, ay = plot(t)
      tracer(ax, ay, hue)
      hue = hue + 1
      if hue > 31 then hue = 0 end
      t = t + 0.3
      if t >= tmax then
        mode = 1
        hold = 40
      end
      flip = 1
    else
      core(10.0, hcore)
      hcore = hcore + 1
      if hcore > 31 then hcore = 0 end
      flip = 0
    end
  elseif mode == 1 then
    core(10.0, hcore)
    hcore = hcore + 1
    if hcore > 31 then hcore = 0 end
    hold = hold - 1
    if hold <= 0 then
      mode = 2
    end
  else
    clearScreen(0.66)
    idx = idx + 1
    if idx > 5 then idx = 1 end
    t = 0.0
    flip = 0
    mode = 0
  end
end
