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
local function C5(r, g, b, a)
local t = {}
local i = 0
while i < 5 do
t[i * 4 + 1] = r
t[i * 4 + 2] = g
t[i * 4 + 3] = b
t[i * 4 + 4] = a
i = i + 1
end
return t
end
stagePush(Q, nil, {0.0, 0.0, 8.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0}, "1", nil, nil, "2")
stagePush(Q, C5(0.25, 0.3, 0.45, 1.0), {0.0, 0.0, -8.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0}, "1", nil, nil, "3")
stagePush(Q, C5(0.9, 0.25, 0.25, 1.0), {-8.0, 0.0, 0.0, 0.0, 1.05, 0.0, 1.0, 1.0, 1.0}, "1", nil, nil, "4")
stagePush(Q, C5(0.25, 0.85, 0.35, 1.0), {8.0, 0.0, 0.0, 0.0, -1.05, 0.0, 1.0, 1.0, 1.0}, "1", nil, nil, "5")
stagePush(Q, C5(0.9, 0.85, 0.3, 1.0), {0.0, -8.0, 0.0, 1.05, 0.0, 0.0, 1.0, 1.0, 1.0}, "1", nil, nil, "6")
stagePush(Q, C5(0.3, 0.8, 0.9, 1.0), {0.0, 8.0, 0.0, -1.05, 0.0, 0.0, 1.0, 1.0, 1.0}, "1", nil, nil, "7")
stagePush({-1.5, 0.0, 2.0, 0.0, 0.5, 3.0}, C5(0.35, 0.35, 0.4, 1.0), {32.0, 32.0, 0.0, 0.0, 0.35, 0.0, 1.0, 1.0, 1.0}, "0", nil, nil, "1")
draw()
stage({}, nil, {0.0, 0.0, 0.0, 0.0, 0.012, 0.05, 0.0, 0.0, 0.0}, "0", -1.0, nil, "1")
push()
