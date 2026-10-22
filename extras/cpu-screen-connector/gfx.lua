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
-- stage2d(pts, cols, xf, parent, ticks, wire, id): a FLAT shape, written
-- as (x, y) pairs, sent as the (x, y, 0) triples the screen takes.  The
-- screen's port takes triples and only triples, so a flat shape is the
-- same shape with a zero z -- this is the shorthand for that, not a
-- second kind of shape.
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
-- stagePush2d: a flat shape (pairs) staged and pushed in one call.
function stagePush2d(pts, cols, xf, parent, ticks, wire, id)
stage(asTriples(pts), cols, xf, parent, ticks, wire, id)
push()
end
-- pushMesh(points, pcols, faces, xf, parent, ticks, wire, firstId):
-- send a whole mesh to the screen.
--
-- points -- the mesh's vertices, a flat list of (x, y, z) triples.
-- pcols  -- one colour (r, g, b, a) per vertex, in the same order.
--           A vertex's colour is ITS colour: a vertex shared by several
--           faces carries that same colour into every one of them, so a
--           shared edge is stroked once in one colour and the two faces
--           meeting there cannot show through each other.
-- faces  -- the faces, each a list of vertex indices (1-based) into
--           points: four for a quad, three for a triangle.
--
-- Every face goes to the screen as its own shape -- the screen draws one
-- outline per shape -- and all the faces share one parent, so one
-- transform moves the whole solid.  firstId is the slot of the first
-- face and the next faces take the next slots: a six-face cube under a
-- pivot in slot 1 is slots 2 to 7.  The screen remembers eight slots,
-- so a mesh has room for eight faces at the most, and one less if the
-- mesh needs a slot of its own for the parent.
--
-- A face's outline is closed here (its first vertex repeated at the
-- end), because the screen's stroke joins consecutive points and an
-- open outline would not come back round.
function pushMesh(points, pcols, faces, xf, parent, ticks, wire, firstId)
local base = firstId
if base == nil then base = 0 end
local f = 1
local nfaces = #faces
while f <= nfaces do
local face = faces[f]
local m = #face
-- the face's points, closed: the first vertex again at the end.
-- The counts are kept by hand: writing t[#t + 1] and then t[#t + 2]
-- re-reads the length after the first write, which leaves a hole in
-- the table and the shape arrives with a hole in it.
local pts = {}
local cols = {}
local np = 0
local nc = 0
local k = 1
while k <= m do
local vi = face[k]
-- The flat lists are 1-based, so the first vertex starts at 1 and
-- every vertex after it three floats on: (vi - 1) * 3 + 1, never
-- (vi - 1) * 3 -- that reads one float early, so the first vertex
-- of every face came out as a hole (nothing) and the rest of the
-- face was the wrong vertex.
local b = (vi - 1) * 3 + 1
np = np + 1
pts[np] = points[b]
np = np + 1
pts[np] = points[b + 1]
np = np + 1
pts[np] = points[b + 2]
-- the vertex's colour, the same one in every face that uses it
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
-- close the outline: the first vertex again, with its colour
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
