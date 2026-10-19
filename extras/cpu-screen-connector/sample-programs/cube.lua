-- A cube, as geometry.
--
-- The chip does the rest: it transforms each vertex through the whole
-- parent chain, keeps the world z as the depth, and projects with a
-- perspective divide (eye at z = -48).  So this program sends vertices
-- and per-point colours and never computes a pixel, a projection or a
-- triangulation -- what it sends IS the cube.
--
-- Each face is a closed outline of five 3D points (four corners plus
-- the first again), which is what makes the staged array's length odd:
-- the chip reads an odd length as (x,y,z) triples, and a 2D array is
-- always even.  The faces carry local vertices around the origin and
-- hang off the pivot slot, so the pivot's spin moves all six at once.
clearScreen()
-- The half-size of the cube.  The near face is magnified by the
-- perspective divide (a point at z = h is 48/(48-h) times further out),
-- so a cube that looks small in model space fills more of the wall than
-- it appears to: 15 clipped the right edge, 12 fits.
local h = 12.0
-- face(ax,ay,az, bx,by,bz, cx,cy,cz, dx,dy,dz, r,g,b): one closed 3D
-- outline, five points, one colour per point.
local function face(ax, ay, az, bx, by, bz, cx, cy, cz, dx, dy, dz, r, g, bl)
local pts = {ax, ay, az, bx, by, bz, cx, cy, cz, dx, dy, dz, ax, ay, az}
local cols = {r, g, bl, 1.0, r, g, bl, 1.0, r, g, bl, 1.0, r, g, bl, 1.0, r, g, bl, 1.0}
return pts, cols
end
local pts, cols = face(-h, -h, h, h, -h, h, h, h, h, -h, h, h, 0.95, 0.95, 1.0)
stagePush(pts, cols, nil, "1", nil, 0.0, "2")
pts, cols = face(h, -h, -h, -h, -h, -h, -h, h, -h, h, h, -h, 0.22, 0.22, 0.28)
stagePush(pts, cols, nil, "1", nil, 0.0, "3")
pts, cols = face(h, -h, h, h, -h, -h, h, h, -h, h, h, h, 0.9, 0.25, 0.25)
stagePush(pts, cols, nil, "1", nil, 0.0, "4")
pts, cols = face(-h, -h, -h, -h, -h, h, -h, h, h, -h, h, -h, 0.25, 0.85, 0.35)
stagePush(pts, cols, nil, "1", nil, 0.0, "5")
pts, cols = face(-h, h, h, h, h, h, h, h, -h, -h, h, -h, 0.95, 0.85, 0.3)
stagePush(pts, cols, nil, "1", nil, 0.0, "6")
pts, cols = face(-h, -h, -h, h, -h, -h, h, -h, h, -h, -h, h, 0.3, 0.8, 0.9)
stagePush(pts, cols, nil, "1", nil, 0.0, "7")
-- the pivot: where the cube sits on the wall and how it is turned.  It needs
-- a shape of its own -- an EMPTY push to a slot is the delete -- but it must
-- not paint: one 3D point is a live slot with no edge to fill, so the pivot
-- carries the transform and nothing shows.  (Three points showed as a grey
-- notch in the middle of the cube.)
editShape("1", {0.0, 0.0, 0.0}, nil, {32.0, 32.0, 0.0, 0.35, 0.0, 0.0, 1.0, 1.0, 1.0}, "0")
-- ... and it keeps turning, forever, with no further pushes: the slot's
-- animation deltas are the spin.
stage({}, nil, {0.0, 0.0, 0.0, 0.012, 0.0, 0.05, 0.0, 0.0, 0.0}, "0", -1.0, nil, "1")
push()