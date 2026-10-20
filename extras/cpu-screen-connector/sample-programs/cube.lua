-- A cube, as geometry.
--
-- The chip does the rest: it transforms each vertex through the whole
-- parent chain, keeps the world z as the depth, and projects with a
-- perspective divide.  So this program sends vertices and per-face
-- colours and never computes a pixel, a projection or a triangulation
-- -- what it sends IS the cube.
--
-- The cube is six faces, and pushMesh sends them as six shapes under
-- one parent, so the parent's spin moves the whole solid.
clearScreen()
-- The half-size of the cube.  The near face is magnified by the
-- perspective divide, and a cube that turns presents its diagonal, so
-- the model size is not the screen size: 15 clipped the right edge of
-- the wall and 12 still touched it, so the cube is 10.
local h = 10.0
local x0, x1 = -h, h
local y0, y1 = -h, h
local z0, z1 = -h, h
-- The six faces, each four corners (x, y, z).  The winding runs the
-- same way round on every face, so the near face is drawn over the far
-- one and the cube reads as a solid.
local faces = {
{x0, y0, z1, x1, y0, z1, x1, y1, z1, x0, y1, z1},
{x1, y0, z0, x0, y0, z0, x0, y1, z0, x1, y1, z0},
{x1, y0, z1, x1, y0, z0, x1, y1, z0, x1, y1, z1},
{x0, y0, z0, x1, y0, z0, x1, y0, z1, x0, y0, z1},
{x0, y1, z1, x1, y1, z1, x1, y1, z0, x0, y1, z0},
{x0, y0, z0, x0, y0, z1, x0, y1, z1, x0, y1, z0},
}
-- One colour per face.
local cols = {
{0.95, 0.95, 1.0, 1.0},
{0.22, 0.22, 0.28, 1.0},
{0.90, 0.25, 0.25, 1.0},
{0.25, 0.85, 0.35, 1.0},
{0.95, 0.85, 0.30, 1.0},
{0.30, 0.80, 0.90, 1.0},
}
-- The six faces go to the screen as six shapes, slots 2 to 7, all
-- under the pivot in slot 1.  They go as OUTLINES, so the cube reads
-- as a wireframe solid: you can see which face is which as it turns.
pushMesh(faces, cols, nil, "1", nil, 1.0, 2)
-- The pivot: where the cube sits on the wall and how it is turned.  It
-- needs a shape of its own -- an EMPTY push to a slot is the delete --
-- but it must not paint: one point is a live slot with no edge to
-- fill, so the pivot carries the transform and nothing shows.
editShape("1", {0.0, 0.0, 0.0}, nil, {32.0, 32.0, 0.0, 0.35, 0.0, 0.0, 1.0, 1.0, 1.0}, "0")
-- ... and it keeps turning, forever, with no further pushes: the slot's
-- animation deltas are the spin.  It turns about the vertical, not over:
-- a tumble passes edge-on, where a cube is a line and the picture says
-- nothing.  The wall repaints about ten times a second, so the rate is
-- slow enough that each repaint shows a different angle.
stage({}, nil, {0.0, 0.0, 0.0, 0.0, 0.0, 0.010, 0.0, 0.0, 0.0}, "0", -1.0, nil, "1")
push()
