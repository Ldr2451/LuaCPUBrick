// cpu-screen-connector: Lua CPU -> screen bridge.  Hand-written (fixed
// logic, nothing generated).  No state at all: five pure combinational
// scalars, one clocked array pass, and three backing vars rewritten from
// the current inputs every tick -- every output is a pure function of
// the current inputs, recomputed, nothing remembered across input
// changes.  (Outputs mirror vars, the screen's own pattern; array reads
// need the exec context, so points and colours stage through backing
// vars.  The edge ports stay pure for zero latency.)
//
// Inputs are named exactly like the Lua chip's outputs; outputs exactly
// like the screen's inputs, so the game wiring is obvious:
//   Lua outNum1 ----> outNum1 |           | shapePoints ----> screen shapePoints
//   Lua outNum2 ----> outNum2 | connector | shapeColors ---> screen shapeColors
//   Lua outNum3 ----> outNum3 |           | pushShape ------> screen pushShape
//   Lua outNum4 ----> outNum4 |           | shapeWireMode -------> screen shapeWireMode
//   Lua outStr1 ----> outStr1 |           | shapeId --------> screen shapeId
//   Lua outNumArr --> outNumArr|           | drawAllShapes -------> screen drawAllShapes
//   Lua outStr2 ----> outStr2 |           | clearAllShapes -------> screen clearAllShapes
//   Lua outStrArr --> outStrArr|           | shapePosition -------> screen shapePosition
//                                          | shapeRotation -------> screen shapeRotation
//                                          | shapeScale ----------> screen shapeScale
//                                          | parentShapeId --> screen parentShapeId
//
// The Lua protocol, 1-based slots in outNumArr (see extras/screen/anim.lua):
//   1..2k   points x1, y1, x2, y2, ... as many pairs as the shape needs
//   2k+1    terminator: an exact integer in [-17, -1] in the x slot
//           after the last point.  Its magnitude carries the colour
//           count: -1 means NO colours (every point defaults to white),
//           -(1+c) means c colours follow.  Any other value --
//           including a negative coordinate -- is a point like any
//           other.  So a colourless driver keeps writing the plain -1
//           it always did, and never pays for the colour region.
//   2k+2..  colours r1, g1, b1, a1, ... four per point
//   100     second terminator (optional): -1 means FOREVER -- the
//           animation runs until another command edits the slot --
//           -(1+T) animates the staged shape over T ticks, and anything
//           else (including 0.0, which is what an unwritten slot reads)
//           is INSTANT (no animation).  One number, one meaning: -1.0
//           used to mean instant, so instant moved to 0.0; drivers that
//           never animate already behave exactly as before, since they
//           never write this slot.  Fixed slot, so no scan: shapes never
//           reach past slot 97 (16 points + terminator + 16 colours is
//           0-based 0..96), so shape data can never collide with it.
//           Stale values CAN (a previous animated push on the same
//           port): drivers that animate write this slot on every push,
//           and write 0 to stop.
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
// Control: outNum1 pulses push, outNum2 pulses draw, outNum3 pulses
// clear, outNum4 holds wire mode (nonzero = stroke), outStr1 holds the
// slot id as text ("0".."8", empty means immediate).  Numbers stay
// geometric; the id rides the otherwise-idle string channel and is
// parsed here (ParseNumber is pure and costs ~2 nodes; keeping the
// screen's id numeric keeps strings out of its hot exec path, and an
// empty/garbage string parses to 0.0 = immediate, so old drivers that
// never touch outStr1 keep working, as do untouched outNum3/4).
// outStr2 carries the parent slot the same way ("0".."8", empty means
// no parent): pushing a shape with a parent attaches it, pushing with
// an empty outStr2 detaches it again.
// The transform rides the CPU's output string array, 1-based slots:
//   1..3   shapePosition x, y, z (only x and y are used)
//   4..6   shapeRotation x, y, z (only z, radians about the origin)
//   7..9   shapeScale x, y, z (only x and y; zeroes mean identity)
// Missing or garbage slots parse to 0.0, and the screen defaults
// those (shapeScale zeroes mean identity there too), so a driver that
// never touches outStrArr behaves exactly as before -- and a driver
// that only moves shapes writes just slots 1..2.  (outStrArr takes at
// most 8 values a call, like outNumArr, so all nine slots are two
// calls.)
// The screen receives two tight arrays -- points of length 2*k and one
// colour per point -- so its length-based count just works with no
// sentinel logic there, and a direct driver (no bridge) can wire the
// same two arrays by hand.
in outNum1: float
in outNum2: float
in outNum3: float
in outNum4: float
in outStr1: string
in outNumArr: float[]
in outStr2: string
in outStrArr: string[]
var pts: float[]
var cfl: float[]
var cols: color[]
var tpos: vector = Vec(0.0, 0.0, 0.0)
var trot: vector = Vec(0.0, 0.0, 0.0)
var tscl: vector = Vec(1.0, 1.0, 1.0)
var ticks: float = 0.0
out pushShape: bool = outNum1 > 0.5
out drawAllShapes: bool = outNum2 > 0.5
out clearAllShapes: bool = outNum3 > 0.5
out shapeWireMode: bool = outNum4 > 0.5
out shapeId: float = ParseNumber(outStr1)
out parentShapeId: float = ParseNumber(outStr2)
out shapePoints: float[] = pts
out shapeColors: color[] = cols
out shapePosition: vector = tpos
out shapeRotation: vector = trot
out shapeScale: vector = tscl
out addToShapeInTicks: float = ticks
mod passArrays() {
  // the point scan and the terminator's value travel together: the same
  // literal-index chain, the x slot that ends the points also says how
  // many colours follow (-1 = none, -(1+c) = c).  A slot terminates the
  // scan only when it holds an exact integer in [-17, -1]: any other
  // negative -- a centered coordinate like -16.5, or an exact integer
  // past -17 -- is a point like any other.  The old rule (< -0.5)
  // silently truncated every shape with a negative x, which made
  // pivot-relative geometry (points around the local origin, the only
  // way a parented shape can spin about its pivot) untransmittable;
  // no working program can depend on the truncation, because what it
  // produced was a cut shape.
  let t0 = (outNumArr[0] | 0) == outNumArr[0] && outNumArr[0] >= -17.0 && outNumArr[0] <= -1.0
  let t1 = (outNumArr[2] | 0) == outNumArr[2] && outNumArr[2] >= -17.0 && outNumArr[2] <= -1.0
  let t2 = (outNumArr[4] | 0) == outNumArr[4] && outNumArr[4] >= -17.0 && outNumArr[4] <= -1.0
  let t3 = (outNumArr[6] | 0) == outNumArr[6] && outNumArr[6] >= -17.0 && outNumArr[6] <= -1.0
  let t4 = (outNumArr[8] | 0) == outNumArr[8] && outNumArr[8] >= -17.0 && outNumArr[8] <= -1.0
  let t5 = (outNumArr[10] | 0) == outNumArr[10] && outNumArr[10] >= -17.0 && outNumArr[10] <= -1.0
  let t6 = (outNumArr[12] | 0) == outNumArr[12] && outNumArr[12] >= -17.0 && outNumArr[12] <= -1.0
  let t7 = (outNumArr[14] | 0) == outNumArr[14] && outNumArr[14] >= -17.0 && outNumArr[14] <= -1.0
  let t8 = (outNumArr[16] | 0) == outNumArr[16] && outNumArr[16] >= -17.0 && outNumArr[16] <= -1.0
  let t9 = (outNumArr[18] | 0) == outNumArr[18] && outNumArr[18] >= -17.0 && outNumArr[18] <= -1.0
  let t10 = (outNumArr[20] | 0) == outNumArr[20] && outNumArr[20] >= -17.0 && outNumArr[20] <= -1.0
  let t11 = (outNumArr[22] | 0) == outNumArr[22] && outNumArr[22] >= -17.0 && outNumArr[22] <= -1.0
  let t12 = (outNumArr[24] | 0) == outNumArr[24] && outNumArr[24] >= -17.0 && outNumArr[24] <= -1.0
  let t13 = (outNumArr[26] | 0) == outNumArr[26] && outNumArr[26] >= -17.0 && outNumArr[26] <= -1.0
  let t14 = (outNumArr[28] | 0) == outNumArr[28] && outNumArr[28] >= -17.0 && outNumArr[28] <= -1.0
  let t15 = (outNumArr[30] | 0) == outNumArr[30] && outNumArr[30] >= -17.0 && outNumArr[30] <= -1.0
  let n = if t0 then 0.0 else if t1 then 1.0 else if t2 then 2.0 else if t3 then 3.0 else if t4 then 4.0 else if t5 then 5.0 else if t6 then 6.0 else if t7 then 7.0 else if t8 then 8.0 else if t9 then 9.0 else if t10 then 10.0 else if t11 then 11.0 else if t12 then 12.0 else if t13 then 13.0 else if t14 then 14.0 else if t15 then 15.0 else 16.0
  let term = if t0 then outNumArr[0] else if t1 then outNumArr[2] else if t2 then outNumArr[4] else if t3 then outNumArr[6] else if t4 then outNumArr[8] else if t5 then outNumArr[10] else if t6 then outNumArr[12] else if t7 then outNumArr[14] else if t8 then outNumArr[16] else if t9 then outNumArr[18] else if t10 then outNumArr[20] else if t11 then outNumArr[22] else if t12 then outNumArr[24] else if t13 then outNumArr[26] else if t14 then outNumArr[28] else if t15 then outNumArr[30] else -1.0
  let kc0 = if term <= -1.0 then (0.0 - term) - 1.0 else 16.0
  let kc = if kc0 > 16.0 then 16.0 else if kc0 < 0.0 then 0.0 else kc0
  pts.slice(outNumArr, 0, (n * 2.0) | 0)
  cfl.slice(outNumArr, (n * 2.0) + 1.0, (kc * 4.0) | 0)
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
  // The transform: nine fixed slots, no scan.  Unwritten slots read ""
  // and parse to 0.0, which the screen defaults (shapeScale zeroes mean
  // identity), so these three builds are literal-index reads -- fast.
  tpos = Vec(ParseNumber(outStrArr[0]), ParseNumber(outStrArr[1]), ParseNumber(outStrArr[2]))
  trot = Vec(ParseNumber(outStrArr[3]), ParseNumber(outStrArr[4]), ParseNumber(outStrArr[5]))
  tscl = Vec(ParseNumber(outStrArr[6]), ParseNumber(outStrArr[7]), ParseNumber(outStrArr[8]))
  ticks = if outNumArr.length() > 99.0 then (if outNumArr[99] == -1.0 then -1.0 else if outNumArr[99] < -1.0 then (0.0 - outNumArr[99]) - 1.0 else 0.0) else 0.0
}
on Clock(interval = 0.01) {
  passArrays()
}
