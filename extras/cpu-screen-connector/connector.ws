// cpu-screen-connector: Lua CPU -> screen bridge.  Hand-written (fixed
// logic, nothing generated).  NO CLOCK: the chip has no timer and no
// free-running pass.  It has ONE input -- the CPU's numeric array port --
// and one event: ContainerChange(outNumArr) fires on the update after the
// array's contents move.  Everything the bridge needs rides that one
// array, so the game wiring is a single wire:
//   Lua outNumArr --> outNumArr | connector | shapePoints ---> screen shapePoints
//                                             | shapeColors ---> screen shapeColors
//                                             | pushShape ------> screen pushShape
//                                             | shapeWireMode --> screen shapeWireMode
//                                             | shapeId --------> screen shapeId
//                                             | drawAllShapes --> screen drawAllShapes
//                                             | clearAllShapes -> screen clearAllShapes
//                                             | shapePosition --> screen shapePosition
//                                             | shapeRotation --> screen shapeRotation
//                                             | shapeScale -----> screen shapeScale
//                                             | parentShapeId -> screen parentShapeId
// The CPU keeps its other ports free for other work, and a driver only
// ever touches one array.
//
// The Lua protocol, 1-based slots in outNumArr (see gfx.lua):
//   1..m   point floats: x1, y1, z1, ... three per point.  m is three
//           times the point count; the terminator follows at m+1.
//   m+1    terminator: an exact integer in [-17, -1] in the x slot
//           after the last point float.  Its magnitude carries the colour
//           count: -1 means NO colours (every point defaults to white),
//           -(1+c) means c colours follow.  Any other value --
//           including a negative coordinate -- is a point like any
//           other.
//   m+2..  colours r1, g1, b1, a1, ... four per point
//   98     float count (optional): when positive, the terminator is
//           read directly at m+1 instead of scanned for, so
//           coordinates are completely unrestricted -- even exact
//           integers in the terminator window transmit as points.  It
//           counts FLOATS, not points.
//   100    animation length: -1 means FOREVER, -(1+T) animates the staged
//           shape over T ticks, and anything else (including 0.0, which
//           is what an unwritten slot reads) is INSTANT.
//   200    push pulse: 1 stages the shape on the ports, 0 ends the pulse
//   201    draw pulse: 1 repaints every retained shape, 0 ends it
//   202    clear pulse: 1 forgets every slot, 0 ends it
//   203    wire mode: nonzero strokes an outline, 0 fills
//   204    slot id: 0 immediate, 1..32 a retained slot, -1 the camera
//   205    parent slot: 0 none, 1..32 a shape, -1 the camera
//   206..208  position x, y, z
//   209..211  rotation x, y, z (radians)
//   212..214  scale x, y, z (zeroes mean identity)
// A white triangle is one call: outNumArr(1, x1,y1, x2,y2, x3,y3, -1).
// A per-point coloured one adds the count to the terminator and the
// colours: outNumArr(1, x1,y1, x2,y2, x3,y3, -4, r,g,b,a, r,g,b,a,
// r,g,b,a).  The count matters because outNumArr is a fixed 16,384-slot
// port: unwritten slots hold whatever the last shape left there, so a
// fixed-width colour read would paint stale floats as colours.
// Trailing stale slots can never leak in as (0,0) points (the
// terminator ends the scan), and forgetting the terminator just reads
// up to 16 points, all white.  A terminator straight at slot 1 is the
// empty shape (paints nothing, deletes a retained slot).  Valid
// coordinates are 0..63, so any value <= -1 is unambiguous.
//
// The point/colour slice is taken only when a pulse slot reads high: the
// shape is complete by then, and staging writes cost only the pulse
// check.  The control slots are read in the same event, so the screen
// sees the shape, its transform and its pulse together.
in outNumArr: float[]
var pts: float[]
var cfl: float[]
var cols: color[]
var tpos: vector = Vec(0.0, 0.0, 0.0)
var trot: vector = Vec(0.0, 0.0, 0.0)
var tscl: vector = Vec(1.0, 1.0, 1.0)
var ticks: float = 0.0
var pushV: bool = false
var drawV: bool = false
var clearV: bool = false
var wireV: bool = false
var idV: float = 0.0
var parentV: float = 0.0
out pushShape: bool = pushV
out drawAllShapes: bool = drawV
out clearAllShapes: bool = clearV
out shapeWireMode: bool = wireV
out shapeId: float = idV
out parentShapeId: float = parentV
out shapePoints: float[] = pts
out shapeColors: color[] = cols
out shapePosition: vector = tpos
out shapeRotation: vector = trot
out shapeScale: vector = tscl
out addToShapeInTicks: float = ticks
mod passArrays() {
  // The pulse flags are read on every change so a falling pulse reaches
  // the screen; the shape slice waits for one of them to be high.
  pushV = outNumArr[199] > 0.5
  drawV = outNumArr[200] > 0.5
  clearV = outNumArr[201] > 0.5
  if pushV || drawV || clearV {
    wireV = outNumArr[202] > 0.5
    idV = outNumArr[203]
    parentV = outNumArr[204]
    tpos = Vec(outNumArr[205], outNumArr[206], outNumArr[207])
    trot = Vec(outNumArr[208], outNumArr[209], outNumArr[210])
    tscl = Vec(outNumArr[211], outNumArr[212], outNumArr[213])
    // the point scan and the terminator's value travel together: the same
    // literal-index chain, the x slot that ends the points also says how
    // many colours follow (-1 = none, -(1+c) = c).  A slot terminates the
    // scan only when it holds an exact integer in [-17, -1]: any other
    // negative -- a centered coordinate like -16.5, or an exact integer
    // past -17 -- is a point like any other.
    let t0 = (outNumArr[0] | 0) == outNumArr[0] && outNumArr[0] >= -17.0 && outNumArr[0] <= -1.0
    let t1 = (outNumArr[3] | 0) == outNumArr[3] && outNumArr[2] >= -17.0 && outNumArr[2] <= -1.0
    let t2 = (outNumArr[9] | 0) == outNumArr[9] && outNumArr[4] >= -17.0 && outNumArr[4] <= -1.0
    let t3 = (outNumArr[12] | 0) == outNumArr[12] && outNumArr[6] >= -17.0 && outNumArr[6] <= -1.0
    let t4 = (outNumArr[18] | 0) == outNumArr[18] && outNumArr[8] >= -17.0 && outNumArr[8] <= -1.0
    let t5 = (outNumArr[21] | 0) == outNumArr[21] && outNumArr[10] >= -17.0 && outNumArr[10] <= -1.0
    let t6 = (outNumArr[27] | 0) == outNumArr[27] && outNumArr[12] >= -17.0 && outNumArr[12] <= -1.0
    let t7 = (outNumArr[30] | 0) == outNumArr[30] && outNumArr[14] >= -17.0 && outNumArr[14] <= -1.0
    let t8 = (outNumArr[36] | 0) == outNumArr[36] && outNumArr[16] >= -17.0 && outNumArr[16] <= -1.0
    let t9 = (outNumArr[39] | 0) == outNumArr[39] && outNumArr[18] >= -17.0 && outNumArr[18] <= -1.0
    let t10 = (outNumArr[45] | 0) == outNumArr[45] && outNumArr[20] >= -17.0 && outNumArr[20] <= -1.0
    let t11 = (outNumArr[48] | 0) == outNumArr[48] && outNumArr[22] >= -17.0 && outNumArr[22] <= -1.0
    let t12 = (outNumArr[54] | 0) == outNumArr[54] && outNumArr[24] >= -17.0 && outNumArr[24] <= -1.0
    let t13 = (outNumArr[57] | 0) == outNumArr[57] && outNumArr[26] >= -17.0 && outNumArr[26] <= -1.0
    let t14 = (outNumArr[63] | 0) == outNumArr[63] && outNumArr[28] >= -17.0 && outNumArr[28] <= -1.0
    let t15 = (outNumArr[66] | 0) == outNumArr[66] && outNumArr[30] >= -17.0 && outNumArr[30] <= -1.0
    // Point float count, 1-based slot 98 (0-based 97): when a driver
    // states how many floats follow, the terminator is read directly
    // instead of scanned for, so coordinates are completely unrestricted.
    // FLOATS, not points: a shape of k points states 3k, and the screen
    // reads the delivered array as triples.
    let hasCount = if outNumArr.length() > 97.0 then (if outNumArr[97] > 0.5 then 1.0 else 0.0) else 0.0
    let cnRaw = if hasCount > 0.5 then outNumArr[97] else 0.0
    let cn = if cnRaw > 48.0 then 48.0 else (cnRaw | 0)
    let rawTerm = if outNumArr.length() > 97.0 then outNumArr[cn] else -1.0
    let rawOk = ((rawTerm | 0) == rawTerm && rawTerm >= -17.0 && rawTerm <= -1.0)
    let n = if hasCount > 0.5 then cn else if t0 then 0.0 else if t1 then 1.0 else if t2 then 2.0 else if t3 then 3.0 else if t4 then 4.0 else if t5 then 5.0 else if t6 then 6.0 else if t7 then 7.0 else if t8 then 8.0 else if t9 then 9.0 else if t10 then 10.0 else if t11 then 11.0 else if t12 then 12.0 else if t13 then 13.0 else if t14 then 14.0 else if t15 then 15.0 else 16.0
    // The stated count is FLOATS, so the array is sliced at the count and
    // its length reaches the screen verbatim -- which is exactly how the
    // screen knows the points are triples, without this chip knowing what
    // a point is.  The scan path's n is a point count, so its length is 3n.
    let nf = if hasCount > 0.5 then cn else n * 3.0
    // With a stated count the terminator value still carries the colour
    // count, but nothing is scanned for: an invalid value where the
    // terminator should be means white, never stale colours.
    let term = if hasCount > 0.5 then (if rawOk then rawTerm else -1.0) else if t0 then outNumArr[0] else if t1 then outNumArr[2] else if t2 then outNumArr[4] else if t3 then outNumArr[6] else if t4 then outNumArr[8] else if t5 then outNumArr[10] else if t6 then outNumArr[12] else if t7 then outNumArr[14] else if t8 then outNumArr[16] else if t9 then outNumArr[18] else if t10 then outNumArr[20] else if t11 then outNumArr[22] else if t12 then outNumArr[24] else if t13 then outNumArr[26] else if t14 then outNumArr[28] else if t15 then outNumArr[30] else -1.0
    let kc0 = if term <= -1.0 then (0.0 - term) - 1.0 else 16.0
    let kc = if kc0 > 16.0 then 16.0 else if kc0 < 0.0 then 0.0 else kc0
    pts.slice(outNumArr, 0, (nf) | 0)
    cfl.slice(outNumArr, nf + 1.0, (kc * 4.0) | 0)
    let nc = cfl.length()
    cols.resize(16, Color(1.0, 1.0, 1.0, 1.0))
    cols[0] = if nc > 3 then Color(cfl[0], cfl[1], cfl[2], cfl[3]) else Color(1.0, 1.0, 1.0, 1.0)
    cols[1] = if nc > 7 then Color(cfl[4], cfl[5], cfl[6], cfl[7]) else Color(1.0, 1.0, 1.0, 1.0)
    cols[2] = if nc > 11 then Color(cfl[8], cfl[9], cfl[10], cfl[11]) else Color(1.0, 1.0, 1.0, 1.0)
    cols[3] = if nc > 15 then Color(cfl[12], cfl[13], cfl[14], cfl[15]) else Color(1.0, 1.0, 1.0, 1.0)
    cols[4] = if nc > 19 then Color(cfl[16], cfl[17], cfl[18], cfl[19]) else Color(1.0, 1.0, 1.0, 1.0)
    cols[5] = if nc > 23 then Color(cfl[20], cfl[21], cfl[22], cfl[23]) else Color(1.0, 1.0, 1.0, 1.0)
    cols[6] = if nc > 27 then Color(cfl[24], cfl[25], cfl[26], cfl[27]) else Color(1.0, 1.0, 1.0, 1.0)
    cols[7] = if nc > 31 then Color(cfl[28], cfl[29], cfl[30], cfl[31]) else Color(1.0, 1.0, 1.0, 1.0)
    cols[8] = if nc > 35 then Color(cfl[32], cfl[33], cfl[34], cfl[35]) else Color(1.0, 1.0, 1.0, 1.0)
    cols[9] = if nc > 39 then Color(cfl[36], cfl[37], cfl[38], cfl[39]) else Color(1.0, 1.0, 1.0, 1.0)
    cols[10] = if nc > 43 then Color(cfl[40], cfl[41], cfl[42], cfl[43]) else Color(1.0, 1.0, 1.0, 1.0)
    cols[11] = if nc > 47 then Color(cfl[44], cfl[45], cfl[46], cfl[47]) else Color(1.0, 1.0, 1.0, 1.0)
    cols[12] = if nc > 51 then Color(cfl[48], cfl[49], cfl[50], cfl[51]) else Color(1.0, 1.0, 1.0, 1.0)
    cols[13] = if nc > 55 then Color(cfl[52], cfl[53], cfl[54], cfl[55]) else Color(1.0, 1.0, 1.0, 1.0)
    cols[14] = if nc > 59 then Color(cfl[56], cfl[57], cfl[58], cfl[59]) else Color(1.0, 1.0, 1.0, 1.0)
    cols[15] = if nc > 63 then Color(cfl[60], cfl[61], cfl[62], cfl[63]) else Color(1.0, 1.0, 1.0, 1.0)
    // Exact colour count out (never padded past it): the screen defaults
    // missing colours to white when painting, and to the transparent
    // no-op when staging per-tick animation deltas -- so omitted colours
    // hold still instead of flashing white.  Capped at 16 like before.
    cols.resize(if nc > 16.0 then 16.0 else nc, Color(1.0, 1.0, 1.0, 1.0))
    ticks = if outNumArr.length() > 99.0 then (if outNumArr[99] == -1.0 then -1.0 else if outNumArr[99] < -1.0 then (0.0 - outNumArr[99]) - 1.0 else 0.0) else 0.0
  }
}
// The one event: the array's contents moved.  The CPU stages a whole
// shape and then pulses, so a pulse sees a complete shape; staging
// writes only move the pulse check.
on ContainerChange(outNumArr) {
  passArrays()
}
