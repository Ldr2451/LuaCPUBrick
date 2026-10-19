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
local function face(ax, ay, az, bx, by, bz, cx, cy, cz, dx, dy, dz, r, g, bl)
local pts = {ax, ay, az, bx, by, bz, cx, cy, cz, dx, dy, dz, ax, ay, az}
local cols = {r, g, bl, 1.0, r, g, bl, 1.0, r, g, bl, 1.0, r, g, bl, 1.0, r, g, bl, 1.0}
return pts, cols
end
local pts, cols = face(-h, -h, h, h, -h, h, h, h, h, -h, h, h, 0.95, 0.95, 1.0)
stagePush(pts, cols, nil, "1", nil, 1.0, "2")
pts, cols = face(h, -h, -h, -h, -h, -h, -h, h, -h, h, h, -h, 0.22, 0.22, 0.28)
stagePush(pts, cols, nil, "1", nil, 1.0, "3")
pts, cols = face(h, -h, h, h, -h, -h, h, h, -h, h, h, h, 0.9, 0.25, 0.25)
stagePush(pts, cols, nil, "1", nil, 1.0, "4")
pts, cols = face(-h, -h, -h, h, -h, -h, h, -h, h, -h, h, -h, 0.25, 0.85, 0.35)
stagePush(pts, cols, nil, "1", nil, 1.0, "5")
pts, cols = face(-h, h, h, h, h, h, h, h, -h, -h, h, -h, 0.95, 0.85, 0.3)
stagePush(pts, cols, nil, "1", nil, 1.0, "6")
pts, cols = face(-h, -h, -h, h, -h, -h, h, -h, h, -h, -h, h, 0.3, 0.8, 0.9)
stagePush(pts, cols, nil, "1", nil, 1.0, "7")
editShape("1", {0.0, 0.0, 0.0}, nil, {32.0, 32.0, 0.0, 0.35, 0.0, 0.0, 1.0, 1.0, 1.0}, "0")
stage({}, nil, {0.0, 0.0, 0.0, 0.003, 0.0, 0.012, 0.0, 0.0, 0.0}, "0", -1.0, nil, "1")
push()
