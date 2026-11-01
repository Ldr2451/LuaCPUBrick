function tick()
local c = clock()
while clock() == c do end
end
function nap(c)
local t = clock()
while clock() < t + c do end
end
-- One array carries everything: shape data in slots 1..113 at most, the
-- float count and animation length at 196 and 198, control in
-- 200..214 (see connector.ws).  A pulse is 1, one tick, 0.
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
-- ids and parents are numbers now: the slot array is numeric, so a string
-- is converted once here ("" and nil mean 0 = immediate / no parent).
local function num(v)
if v == nil then return 0.0 end
if type(v) == "string" then return tonumber(v) or 0.0 end
return v
end
-- rep(t, n): n copies of t end to end -- one colour repeated per point.
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
-- stage(pts, cols, xf, parent, ticks, wire, id): put one shape on the
-- array, ready for the next push.
-- pts is a flat list of point FLOATS: two per point for a 2D shape
-- (x, y) and three for a 3D one (x, y, z).  The chip reads an odd
-- length as 3D and projects it, so a 3D outline is sent as its
-- vertices with the first one repeated at the end when the point count
-- would otherwise be even (a quad: five points, fifteen floats).  The
-- chip does the transform, the depth test and the perspective divide --
-- this library only moves numbers to the outputs.
-- cols is optional and per-point (four numbers each): one colour per
-- point, white where absent.  xf is the nine-number transform
-- (pos.xyz, rot.xyz, scl.xyz), parent the slot id ("0" none, "1".."32"
-- a shape, "-1" the camera so the shape is placed in view space), ticks
-- the animation length (0 instant, n repaints, -1 forever), wire the
-- wireframe flag: nil or 0 fills, 1 strokes an outline, and it is
-- written on every push -- id the slot to store ("0".."32", "-1" the
-- camera, "" = immediate).
-- stage2d and its triples helper are defined AFTER stage, below: the
-- shorthand calls it, so the definition order keeps the call honest.
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
-- control: wire, id, parent in one call, then the animation length.
outNumArr(203, wire or 0.0, num(id), num(parent))
local t = ticks
if t == nil then t = 0.0 end
-- one number, one meaning: -1 is FOREVER (the animation runs until
-- another command edits the slot), 0 is INSTANT, N > 0 runs N steps.
-- A step lands at a REPAINT, not at a clock tick: the screen holds its
-- animation while it scans out a pass, so N is the number of frames the
-- eye sees, which is the only rate the eye can see anyway.
if t == -1.0 then
outNumArr(198, -1.0)
elseif t >= 1.0 then
outNumArr(198, -(1.0 + t))
else
outNumArr(198, 0.0)
end
-- the point float count, 1-based slot 196: when positive the connector
-- reads the terminator directly instead of scanning, so coordinates are
-- unrestricted.  FLOATS, not points.  The count and the animation slot
-- sit above the shape data -- the biggest shape the screen takes (sixteen
-- points, each with a colour) reaches slot 113 -- so staging a full shape
-- never disturbs them and they need no special order.  Written on every
-- push: the slots are sticky.
outNumArr(196, #pts * 1.0)
end

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
-- A mesh is ONE shape: its edges are walked end to end into one
-- outline, so the solid arrives on the wall whole, in one push and one
-- commit, never built face by face.  A stroke draws a mesh's EDGES, and
-- an edge two faces share is ONE edge -- it belongs to both and is
-- stroked once for both, in the colour of the vertices it joins (which
-- is why pcols is per vertex).  A cube's twelve edges need four edges
-- walked twice to be one walk; the last of those is the walk's return
-- over paint already laid, so the walk is sixteen points: one shape,
-- one slot, one commit.
--
-- A walk can only start and stop at corners an odd number of edges
-- meet, so where the mesh has more, the library walks the shortest
-- route between two such corners a second time (the walk retraces it,
-- which paints the same pixels again and adds nothing).  That route
-- always exists, so the staging below never has to lift its pen.  A
-- mesh whose walk is longer than a shape holds (sixteen points) also
-- goes as shapes of the walk, broken where it passes the cap, the
-- joint vertex closing one shape and opening the next.
--
-- A fill is a different unit: a filled shape is one closed outline,
-- so a filled mesh's shapes are its faces, one face per slot.
--
-- firstId is the first shape's slot: a cube wireframe under a pivot
-- in slot 1 is the ONE slot 2.  A face given with its first vertex
-- repeated at the end is the same face.
--
-- The walk's four parts are separate functions: the chip resolves a
-- name through a ladder of 32 live locals per scope, counted across
-- the frames a scope reaches, and the sample's main chunk already
-- carries its own locals under this library -- one body doing edges,
-- pairing, the tour and the staging would overflow that scope and be
-- refused at parse.  These are globals like every other library step,
-- so they add nothing on top of the library either.
function meshEdges(faces, nv, ea, eb, corner)
-- the mesh's edges, each ONCE: an edge names its two corners, low
-- first, so the two faces that share it name it the same way, and
-- the pair is its key.  Each corner keeps the edge numbers that meet
-- it, which is what the walk follows; an odd corner is one an odd
-- number of them meet.
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
-- FILL: one closed outline per face, one face per slot.
function fillMesh(points, pcols, faces, xf, parent, ticks, wire, base)
-- reading the face round one vertex past its end repeats the first
-- vertex and closes it.  The copy indexes by the vertex number so the
-- lists stay tight: writing at t[#t + 1] and then t[#t + 2] re-reads
-- the length after the first write and leaves a hole in the table.
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
-- A walk can start and stop only at corners an odd number of edges meet, so
-- while the mesh has such corners left, the library walks the shortest route
-- between two of them a second time: the route's pixels are painted twice
-- and the mesh gains nothing.  The route always exists -- a mesh's corners
-- are joined by its edges -- so after this every corner is even and the walk
-- below never leaves the mesh.  One of the added edges is returned as
-- firstdup and needs no point of its own: the walk leaves it unwalked,
-- standing in for the walk's return over paint the same route laid before.
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
-- the nearest other odd corner, reached breadth first over the mesh's
-- edges; prevE says which edge brought a corner into the search, so
-- the route back from the target is the chain of those edges.
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
-- nextStart(nv, corner, used): where the next walk begins: a corner with
-- an ODD number of unwalked edges left -- so a walk that has to stop
-- does so where it cannot leave -- and any corner with an edge left if
-- none is odd; 0 when the mesh has nothing left to walk.
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
-- Hierholzer: a corner that cannot leave drops into the path as the walk
-- back passes it, so the tour reads backwards from where it stands:
-- path[pn] .. path[1].  The tour is written into path (1..pn) and pn is
-- returned.  ea/eb name an edge's corners, which is how the walk steps
-- to the far end of the edge it moves over.
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
-- Send the tour in shapes of at most sixteen points: the cap one shape
-- takes, colour and all.  Where the tour needs more than one shape, the
-- corner it splits at closes one and opens the next, so the shapes join
-- back into the tour's line.  A cube's twelve edges walk as sixteen
-- points -- four edges are walked twice so the walk can leave every
-- corner, and the last of those returns over paint already laid --
-- and go in ONE shape, one slot, one commit.  The tour and its staging
-- travel together here because the chip's call gate carries at most
-- eight parameters, and naming one shape's tour range as well as what
-- stage needs would name ten: the whole tour comes in and the shapes
-- leave it, one slot after the next from `base`, and how many shapes
-- it sent -- how many slots the mesh took -- is returned.
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
-- STROKE: walk the edges end to end and send what the walk gives.
-- One of the edges a paired route added is left for the walk's return
-- over paint the same route laid a moment before, so it needs no point
-- of its own: from any corner that still has an edge to walk -- an odd
-- one first, so a walk that has to stop does so at a corner it cannot
-- leave -- the walk steps over unwalked edges until the piece has
-- none left: every edge sits in the walk exactly once.  A mesh whose
-- pieces are apart gives one shape per piece, sharing the parent and
-- the next slots, so the whole mesh still moves as one.
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
-- editShape(id, pts, cols, xf, parent, ticks, wire): store or edit a
-- shape in slot `id` and show it.  wire nil = filled, 1 = outline.
function editShape(id, pts, cols, xf, parent, ticks, wire)
stage(pts, cols, xf, parent, ticks, wire, id)
fire()
end
-- camera(xf, ticks): move the view.  xf is the nine-number transform
-- (pos.xyz, rot.xyz, scl.xyz) -- one point travels with it, which paints
-- nothing, and the commit recomposites the scene, so no draw is needed to
-- see the move.  Shapes whose parent chain reaches "-1" ride along and
-- keep their place on screen; everything else moves with the view.
-- camera(nil) forgets the camera, which puts the view back to identity.
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
