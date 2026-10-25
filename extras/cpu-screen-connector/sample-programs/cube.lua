-- A cube, as geometry.
--
-- The chip does the rest: it transforms each vertex through the whole
-- parent chain, keeps the world z as the depth, and projects with a
-- perspective divide.  So this program sends vertices and colours and
-- never computes a pixel, a projection or a triangulation -- what it
-- sends IS the cube.
--
-- The cube is eight vertices and six faces, and pushMesh sends the
-- faces as six shapes under one parent, so the parent's turn moves the
-- whole solid.  The vertices are the cube's, and a vertex's colour is
-- the colour of the EDGES that meet there: every face shares the
-- vertices it touches, so an edge is drawn once, in one colour, and
-- the two faces that meet along it cannot show through each other.
clearScreen()
-- The half-size of the cube.  The near face is magnified by the
-- perspective divide, and a cube that turns presents its diagonal, so
-- the model size is not the screen size: 15 clipped the right edge of
-- the wall and 12 still touched it, so the cube is 10.
local h = 10.0
-- The eight vertices of the cube, in the order the faces below name
-- them: 1..4 are the near face, 5..8 the far one.
local pts = {
-h, -h, h,  h, -h, h,  h, h, h,  -h, h, h,
-h, -h, -h,  h, -h, -h,  h, h, -h,  -h, h, -h,
}
-- One colour per vertex.  A vertex is where three faces meet, so its
-- colour is the colour of the corner it makes: the four NEAR vertices
-- are bright and the four FAR ones dark, so the cube reads as one solid
-- turning rather than as six separate coloured squares.  Because a
-- vertex is shared, an edge between two faces is drawn in the same
-- colour from both sides.
local cols = {
0.95, 0.95, 1.00, 1.00,
0.95, 0.90, 0.85, 1.00,
0.95, 0.85, 0.55, 1.00,
0.90, 0.80, 0.50, 1.00,
0.35, 0.30, 0.35, 1.00,
0.40, 0.35, 0.40, 1.00,
0.45, 0.40, 0.45, 1.00,
0.40, 0.35, 0.40, 1.00,
}
-- The six faces, each naming its vertices.  Every face is a closed
-- outline of four vertices.
local faces = {
{1, 2, 3, 4},
{5, 8, 7, 6},
{1, 5, 6, 2},
{4, 3, 7, 8},
{1, 4, 8, 5},
{2, 6, 7, 3},
}
-- The six faces go to the screen as six shapes, slots 2 to 7, all
-- under the pivot in slot 1.  They go as OUTLINES, so the cube reads
-- as a wireframe solid: you can see which face is which as it turns.
pushMesh(pts, cols, faces, nil, "1", nil, 1.0, 2)
-- The pivot: where the cube sits on the wall and how it is turned.  It
-- needs a shape of its own -- an EMPTY push to a slot is the delete --
-- but it must not paint: one point is a live slot with no edge to fill,
-- so the pivot carries the transform and nothing shows.  Wireframe mode
-- is a port the screen keeps, and the faces above left it ON, so turning
-- it off here is the program's job: a bare editShape would inherit it,
-- and one point in wireframe mode is a two-pixel blob -- the white dot
-- in the middle of the solid.
setWire(0)
editShape("1", {0.0, 0.0, 0.0}, nil, {32.0, 32.0, 0.0, 0.35, 0.0, 0.0, 1.0, 1.0, 1.0}, "0")
-- ... and it keeps turning, forever, with no further pushes: the slot's
-- animation deltas are the spin.  It turns about the vertical, not over:
-- a tumble passes edge-on, where a cube is a line and the picture says
-- nothing.  One delta lands per REPAINT, not per tick: the screen holds
-- the animation while it scans out a pass (a seven-slot pass is a couple
-- of hundred ticks), so this step is what the eye sees between frames --
-- about five degrees, a turn in a minute or so.
stage({}, nil, {0.0, 0.0, 0.0, 0.0, 0.0, 0.080, 0.0, 0.0, 0.0}, "0", -1.0, nil, "1")
push()
