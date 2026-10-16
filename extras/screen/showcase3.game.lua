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
if t >= 1.0 then
outNumArr(100, -(1.0 + t))
else
outNumArr(100, -1.0)
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
local cx, cy = 32.0, 32.0
clearScreen()
local q = {cx - 4.0, cy - 4.0, cx + 4.0, cy - 4.0, cx + 4.0, cy + 4.0, cx - 4.0, cy + 4.0}
local cam = {0.0, 0.0, 0.0, 0.0, 0.35, 0.0, 1.0, 1.0, 1.0}
local zs = {0.0, 4.0, 8.0}
local i = 0
while i < 3 do
local z = zs[i + 1]
local x = {0.0, 0.0, z, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0}
editShape(tostring(i + 2), q, nil, x, "1")
i = i + 1
end
local cols = {0.1, 0.9, 0.4, 0.5, 0.2, 0.7, 1.0, 0.5, 0.9, 0.3, 0.2, 0.5}
editShape("1", {0.0, 0.0, 9.0, 0.0, 4.5, 7.8}, cols,
{32.0, 32.0, 0.0, 0.0, 0.35, 0.0, 1.0, 1.0, 1.0}, "0", 600.0)
draw()
local k = 0
while k < 40 do
editShape("1", {}, nil, {0.0, 0.0, 0.0, 0.0, 0.012, 0.03, 0.0, 0.0, 0.0}, "0", 15.0)
nap(0.2)
k = k + 1
end
