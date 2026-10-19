-- A triangular prism, as geometry.
--
-- Same contract as the cube: vertices out, chip does the rest.  It is
-- here because its faces come in BOTH 3D outline shapes -- triangles
-- (three points, nine floats) and quads sent closed (five points, fifteen
-- floats) -- so the odd-length rule is doing real work in one frame, and
-- because the depth test has to pick the right face as the prism turns.
clearScreen()
-- The prism's half-width and half-depth.  The near face is magnified by
-- the perspective divide, so the model size is not the screen size: 16
-- clipped the wall, 12 still touched it, so the prism is 10 by 8.
local h = 10.0
local d = 8.0
-- the base triangle, then the same three corners pushed to +d and -d
local ax, ay = -h, -h * 0.6
local bx, by = h, -h * 0.6
local ccx, ccy = 0.0, h * 0.85
-- tri(ax,ay,az, bx,by,bz, cx,cy,cz, r,g,bl): a 3-point 3D face (nine
-- floats -- odd, so the chip reads it as triples with nothing to close).
local function tri(ax, ay, az, bx, by, bz, cx, cy, cz, r, g, bl)
local pts = {ax, ay, az, bx, by, bz, cx, cy, cz}
local cols = {r, g, bl, 1.0, r, g, bl, 1.0, r, g, bl, 1.0}
return pts, cols
end
-- quad(...): a 4-corner 3D face sent closed (first corner repeated), so
-- its fifteen floats stay odd.
local function quad(ax, ay, az, bx, by, bz, cx, cy, cz, dx, dy, dz, r, g, bl)
local pts = {ax, ay, az, bx, by, bz, cx, cy, cz, dx, dy, dz, ax, ay, az}
local cols = {r, g, bl, 1.0, r, g, bl, 1.0, r, g, bl, 1.0, r, g, bl, 1.0, r, g, bl, 1.0}
return pts, cols
end
-- The faces are pushed as OUTLINES, so the prism reads as a wireframe
-- solid and you can see which face is which as it turns.
-- the two ends
local pts, cols = tri(ax, ay, d, bx, by, d, ccx, ccy, d, 0.9, 0.85, 0.35)
stagePush(pts, cols, nil, "1", nil, 1.0, "2")
pts, cols = tri(bx, by, -d, ax, ay, -d, ccx, ccy, -d, 0.25, 0.25, 0.32)
stagePush(pts, cols, nil, "1", nil, 1.0, "3")
-- the three sides
pts, cols = quad(ax, ay, d, bx, by, d, bx, by, -d, ax, ay, -d, 0.9, 0.3, 0.3)
stagePush(pts, cols, nil, "1", nil, 1.0, "4")
pts, cols = quad(bx, by, d, ccx, ccy, d, ccx, ccy, -d, bx, by, -d, 0.3, 0.85, 0.4)
stagePush(pts, cols, nil, "1", nil, 1.0, "5")
pts, cols = quad(ccx, ccy, d, ax, ay, d, ax, ay, -d, ccx, ccy, -d, 0.35, 0.75, 0.9)
stagePush(pts, cols, nil, "1", nil, 1.0, "6")
-- the pivot: centre, tilt, and a two-axis spin that runs forever.  One 3D
-- point: a live slot with no edge to fill, so the pivot carries the
-- transform and paints nothing (an empty push is the delete, and three
-- points showed as a notch in the middle of the solid).
editShape("1", {0.0, 0.0, 0.0}, nil, {32.0, 32.0, 0.0, 0.3, 0.0, 0.2, 1.0, 1.0, 1.0}, "0")
-- The wall repaints about ten times a second, so the spin rates are slow
-- enough that each repaint shows a visibly different angle.
stage({}, nil, {0.0, 0.0, 0.0, 0.004, 0.0, 0.010, 0.0, 0.0, 0.0}, "0", -1.0, nil, "1")
push()
