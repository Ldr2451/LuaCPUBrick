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
-- isConvex(pts): every turn the same sign, i.e. the fill's single-span
-- rule paints the outline whole.  pushMesh uses it to decide whether a
-- face needs splitting.
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
-- pushMesh(first, faces, parent): one call uploads a whole mesh.  Each
-- face is {pts = flat xy (at most 16 points -- the chip truncates past
-- that), col = {r,g,b,a} or a full per-point array or nil for white, xf
-- = 9-number transform or nil}.  A concave face would fill its hull, so
-- pushMesh splits it into convex triangles (triangulate) AUTOMATICALLY
-- -- one slot per triangle; convex faces (the cube's quads) stay one
-- slot each, so nothing changes for them.  Faces land in slots first..
-- in order with NO draw between them, so one draw() after this paints
-- the mesh atomically.  Limits, honestly: the mesh shares the 8 retained
-- slots with everything else (a 6-face cube plus its pivot fits; a
-- triangulated 20-face mesh does not), a full per-point colour array
-- needs a convex face (triangles get the uniform colour), and per-face
-- animation is out -- animate the parent pivot, or edit slots directly.
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
-- triangulate(pts): ear clipping for simple (non-self-intersecting)
-- polygons, flat xy like everything else.  Returns a list of flat
-- 3-point arrays; feeds pushMesh one triangle per face for concave
-- shapes the fill cannot paint whole (it fills convex spans, so a
-- concave outline would fill its hull).  n points give n-2 triangles
-- with identical total area.  Guarded iterations throughout: a
-- degenerate outline returns what it has instead of hanging the chip.
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
if (d1 >= 0.0 and d2 >= 0.0 and d3 >= 0.0) or (d1 <= 0.0 and d2 <= 0.0 and d3 <= 0.0) then clear = false end
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
