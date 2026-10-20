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
function pushMesh(faces, cols, xf, parent, ticks, wire, firstId)
local base = firstId
if base == nil then base = 0 end
local i = 1
local n = #faces
while i <= n do
local f = faces[i]
local m = #f
local np = m / 3
local closed = m >= 6 and f[m - 2] == f[1] and f[m - 1] == f[2]
and f[m] == f[3]
local pts = f
if not closed and np > 1 then
pts = {}
local k = 1
while k <= m do
pts[k] = f[k]
k = k + 1
end
pts[m + 1] = f[1]
pts[m + 2] = f[2]
pts[m + 3] = f[3]
np = np + 1
end
local c = nil
if cols ~= nil then
local e = cols[i]
if e ~= nil then
if #e == 4 and np > 1 then
c = {}
local q = 0
while q < np do
c[q * 4 + 1] = e[1]
c[q * 4 + 2] = e[2]
c[q * 4 + 3] = e[3]
c[q * 4 + 4] = e[4]
q = q + 1
end
elseif not closed and #e == np * 4 - 4 then
c = {}
local k = 1
while k <= #e do
c[k] = e[k]
k = k + 1
end
c[#e + 1] = e[1]
c[#e + 2] = e[2]
c[#e + 3] = e[3]
c[#e + 4] = e[4]
else
c = e
end
end
end
stage(pts, c, xf, parent, ticks, wire, tostring(base + i - 1))
push()
i = i + 1
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
  outNumArr(1, bx, by, 0.0, ex, by, 0.0, ex, ey, 0.0, bx, ey, 0.0)
  outNumArr(9, -1.0)
  fire()
end
local function core(r, h)
  local k = r * 0.4142136
  local x0, x1 = cx - r, cx + r
  local y0, y1 = cx - r, cx + r
  local kx0, kx1 = cx - k, cx + k
  local ky0, ky1 = cx - k, cx + k
  outNumArr(1, kx0, y0, 0.0, kx1, y0, 0.0, x1, ky0, 0.0, x1, ky1, 0.0)
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
