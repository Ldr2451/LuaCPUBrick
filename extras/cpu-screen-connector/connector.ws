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
//   Lua outNum4 ----> outNum4 |           | wireMode -------> screen wireMode
//   Lua outStr1 ----> outStr1 |           | shapeId --------> screen shapeId
//   Lua outNumArr --> outNumArr|           | drawAll -------> screen drawAll
//                                          | clearAll -------> screen clearAll
//
// The Lua protocol, 1-based slots in outNumArr (see extras/screen/anim.lua):
//   1..2k   points x1, y1, x2, y2, ... as many pairs as the shape needs
//   2k+1    terminator: a value <= -1 in the x slot after the last point.
//           Its magnitude carries the colour count: -1 means NO colours
//           (every point defaults to white), -(1+c) means c colours
//           follow.  So a colourless driver keeps writing the plain -1
//           it always did, and never pays for the colour region.
//   2k+2..  colours r1, g1, b1, a1, ... four per point
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
var pts: float[]
var cfl: float[]
var cols: color[]
out pushShape: bool = outNum1 > 0.5
out drawAll: bool = outNum2 > 0.5
out clearAll: bool = outNum3 > 0.5
out wireMode: bool = outNum4 > 0.5
out shapeId: float = ParseNumber(outStr1)
out shapePoints: float[] = pts
out shapeColors: color[] = cols
mod passArrays() {
  // the point scan and the terminator's value travel together: the same
  // literal-index chain, the x slot that ends the points also says how
  // many colours follow (-1 = none, -(1+c) = c)
  let n = if outNumArr[0] < -0.5 then 0.0 else if outNumArr[2] < -0.5 then 1.0 else if outNumArr[4] < -0.5 then 2.0 else if outNumArr[6] < -0.5 then 3.0 else if outNumArr[8] < -0.5 then 4.0 else if outNumArr[10] < -0.5 then 5.0 else if outNumArr[12] < -0.5 then 6.0 else if outNumArr[14] < -0.5 then 7.0 else if outNumArr[16] < -0.5 then 8.0 else if outNumArr[18] < -0.5 then 9.0 else if outNumArr[20] < -0.5 then 10.0 else if outNumArr[22] < -0.5 then 11.0 else if outNumArr[24] < -0.5 then 12.0 else if outNumArr[26] < -0.5 then 13.0 else if outNumArr[28] < -0.5 then 14.0 else if outNumArr[30] < -0.5 then 15.0 else 16.0
  let term = if outNumArr[0] < -0.5 then outNumArr[0] else if outNumArr[2] < -0.5 then outNumArr[2] else if outNumArr[4] < -0.5 then outNumArr[4] else if outNumArr[6] < -0.5 then outNumArr[6] else if outNumArr[8] < -0.5 then outNumArr[8] else if outNumArr[10] < -0.5 then outNumArr[10] else if outNumArr[12] < -0.5 then outNumArr[12] else if outNumArr[14] < -0.5 then outNumArr[14] else if outNumArr[16] < -0.5 then outNumArr[16] else if outNumArr[18] < -0.5 then outNumArr[18] else if outNumArr[20] < -0.5 then outNumArr[20] else if outNumArr[22] < -0.5 then outNumArr[22] else if outNumArr[24] < -0.5 then outNumArr[24] else if outNumArr[26] < -0.5 then outNumArr[26] else if outNumArr[28] < -0.5 then outNumArr[28] else if outNumArr[30] < -0.5 then outNumArr[30] else -1.0
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
}
on Clock(interval = 0.01) {
  passArrays()
}
