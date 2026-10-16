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
-- the point count, 1-based slot 98: the connector reads the
-- terminator directly instead of scanning for it, so coordinates are
-- unrestricted (any float, including negatives).  Written on every
-- push like slot 100: the slots are sticky, so a stale count would
-- ghost-parse the next shape.
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
-- pushMesh(first, faces, parent): one call uploads a whole mesh.  Each
-- face is {pts = flat xy (convex, at most 16 points -- the chip
-- truncates past that), col = {r,g,b,a} or a full per-point array or
-- nil for white, xf = 9-number transform or nil}.  Faces land in slots
-- first.. in order with NO draw between them, so one draw() after this
-- paints the mesh atomically.  Limits, honestly: the mesh shares the
-- 8 retained slots with everything else (a 6-face cube plus its pivot
-- fits; a 20-face icosahedron does not), and per-face animation is out
-- -- animate the parent pivot, or edit slots directly.  Concave faces
-- are the driver's job to decompose, same as single shapes.
function pushMesh(first, faces, parent)
local id = first
local k = 1
while k <= #faces do
if id > 8.0 then error("pushMesh: slots 1..8 hold " .. #faces .. " faces", 0) end
local fc = faces[k]
local cc = fc.col
if cc ~= nil and #cc == 4 then
local ex = {}
local m = 0
while m < #fc.pts // 2 do
ex[m * 4 + 1] = cc[1]
ex[m * 4 + 2] = cc[2]
ex[m * 4 + 3] = cc[3]
ex[m * 4 + 4] = cc[4]
m = m + 1
end
cc = ex
end
stagePush(fc.pts, cc, fc.xf, parent, nil, nil, tostring(id))
id = id + 1.0
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
