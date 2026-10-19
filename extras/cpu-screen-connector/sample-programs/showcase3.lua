-- showcase3: 3D depth, off-axis tilt, and a rotation that drives itself.
-- Slots 2..4 are three plates stacked in depth (shapePosition.z 0/4/8),
-- each parented to the pivot in slot 1.  The pivot carries
-- addToShapeInTicks: its rotation advances every tick, the chip
-- recomposites the whole scene on its own, and the plates follow
-- through the parent compose -- no drawAllShapes anywhere after the
-- frame is committed.  Off-axis tilt (rotation.y) foreshortens the
-- plates, so the stack reads as depth rather than as flat overlap.
local cx, cy = 32.0, 32.0
clearScreen()
local q = {cx - 4.0, cy - 4.0, 0.0, cx + 4.0, cy - 4.0, 0.0, cx + 4.0, cy + 4.0, 0.0, cx - 4.0, cy + 4.0, 0.0}
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
editShape("1", {0.0, 0.0, 9.0, 0.0, 0.0, 4.5, 7.8, 0.0}, cols,
{32.0, 32.0, 0.0, 0.0, 0.35, 0.0, 1.0, 1.0, 1.0}, "0", 600.0)
draw()
local k = 0
while k < 40 do
editShape("1", {}, nil, {0.0, 0.0, 0.0, 0.0, 0.012, 0.03, 0.0, 0.0, 0.0}, "0", 15.0)
nap(0.2)
k = k + 1
end
