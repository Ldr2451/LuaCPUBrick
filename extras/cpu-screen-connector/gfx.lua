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
-- stage(pts, cols, xf, parent, ticks, wire, id): put one shape on the
-- ports, ready for the next push.
-- pts is a flat list of point FLOATS: two per point for a 2D shape
-- (x, y) and three for a 3D one (x, y, z).  The chip reads an odd
-- length as 3D and projects it, so a 3D outline is sent as its
-- vertices with the first one repeated at the end when the point count
-- would otherwise be even (a quad: five points, fifteen floats).  The
-- chip does the transform, the depth test and the perspective divide --
-- this library only moves numbers to the outputs.
-- cols is optional and per-point (four numbers each): one colour per
-- point, white where absent.  xf is the nine-number transform
-- (pos.xyz, rot.xyz, scl.xyz), parent the slot id as text, ticks the
-- animation length (0 instant, n ticks, -1 forever), wire true for a
-- stroke, id the slot to store ("0".."8", "" = immediate).
function stage(pts, cols, xf, parent, ticks, wire, id)
-- the point float count, 1-based slot 98: the connector reads the
-- terminator directly instead of scanning for it, so coordinates are
-- unrestricted (any float, including negatives).  FLOATS, not points:
-- two per point for a 2D shape, three (x, y, z) for a 3D one, and the
-- screen reads an odd delivered length as triples.  Written on every
-- push like slot 100: the slots are sticky, so a stale count would
-- ghost-parse the next shape.
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
-- one number, one meaning: -1 is FOREVER (the animation runs until
-- another command edits the slot), 0 is INSTANT, N > 0 runs N ticks.
-- -1.0 at slot 100 used to mean instant, so it now means forever;
-- instant moved to 0.0 (which is also what an unwritten slot reads).
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