// cpu-screen-connector: Lua CPU -> screen bridge.  Hand-written (fixed
// logic, nothing generated).  No state at all: five pure combinational
// scalars, one clocked array pass, and two backing vars rewritten from
// the current inputs every tick -- every output is a pure function of
// the current inputs, recomputed, nothing remembered across input
// changes.  (Outputs mirror vars, the screen's own pattern; array reads
// need the exec context, so colour and points stage through backing
// vars.  The edge ports stay pure for zero latency.)
//
// Inputs are named exactly like the Lua chip's outputs; outputs exactly
// like the screen's inputs, so the game wiring is obvious:
//   Lua outNum1 ----> outNum1 |           | shapePoints ----> screen shapePoints
//   Lua outNum2 ----> outNum2 | connector | shapeColor -----> screen shapeColor
//   Lua outNum3 ----> outNum3 |           | pushShape ------> screen pushShape
//   Lua outNum4 ----> outNum4 |           | wireMode -------> screen wireMode
//   Lua outStr1 ----> outStr1 |           | shapeId --------> screen shapeId
//   Lua outNumArr --> outNumArr|           | redrawAll ------> screen redrawAll
//                                          | clearAll -------> screen clearAll
//
// The Lua protocol, 1-based slots in outNumArr (see extras/screen/anim.lua):
//   1..4  colour r, g, b, a (fixed count, so first -- easy to find)
//   5..   points x1, y1, x2, y2, ... as many pairs as the shape needs
//   5+2k  terminator: one -1 in the x slot after the last point
// A triangle is two calls: outNumArr(1, r,g,b,a) and
// outNumArr(5, x1,y1, x2,y2, x3,y3, -1).  An x of -1 ends the list, so
// trailing slots (stale zeros from earlier shapes) can never leak in as
// (0,0) points; forgetting the terminator just reads up to 16 points.
// A terminator straight at slot 5 is the empty shape (paints nothing,
// deletes a retained slot).  Valid coordinates are 0..63, so -1 (read
// as < -0.5) is unambiguous.
//
// Control: outNum1 pulses push, outNum2 pulses redraw, outNum3 pulses
// clear, outNum4 holds wire mode (nonzero = stroke), outStr1 holds the
// slot id as text ("0".."8", empty means immediate).  Numbers stay
// geometric; the id rides the otherwise-idle string channel and is
// parsed here (ParseNumber is pure and costs ~2 nodes; keeping the
// screen's id numeric keeps strings out of its hot exec path, and an
// empty/garbage string parses to 0.0 = immediate, so old drivers that
// never touch outStr1 keep working, as do untouched outNum3/4).
// The screen receives tight point arrays (length 2*k), so its
// length-based count just works with no sentinel logic there.
in outNum1: float
in outNum2: float
in outNum3: float
in outNum4: float
in outStr1: string
in outNumArr: float[]
var cCol: color = Color(0.0, 0.0, 0.0, 1.0)
var pts: float[]
out pushShape: bool = outNum1 > 0.5
out redrawAll: bool = outNum2 > 0.5
out clearAll: bool = outNum3 > 0.5
out wireMode: bool = outNum4 > 0.5
out shapeId: float = ParseNumber(outStr1)
out shapeColor: color = cCol
out shapePoints: float[] = pts
mod passArrays() {
  cCol = Color(outNumArr[0], outNumArr[1], outNumArr[2], outNumArr[3])
  let n = if outNumArr[4] < -0.5 then 0.0 else if outNumArr[6] < -0.5 then 1.0 else if outNumArr[8] < -0.5 then 2.0 else if outNumArr[10] < -0.5 then 3.0 else if outNumArr[12] < -0.5 then 4.0 else if outNumArr[14] < -0.5 then 5.0 else if outNumArr[16] < -0.5 then 6.0 else if outNumArr[18] < -0.5 then 7.0 else if outNumArr[20] < -0.5 then 8.0 else if outNumArr[22] < -0.5 then 9.0 else if outNumArr[24] < -0.5 then 10.0 else if outNumArr[26] < -0.5 then 11.0 else if outNumArr[28] < -0.5 then 12.0 else if outNumArr[30] < -0.5 then 13.0 else if outNumArr[32] < -0.5 then 14.0 else if outNumArr[34] < -0.5 then 15.0 else 16.0
  pts.slice(outNumArr, 4, (n * 2.0) | 0)
}
on Clock(interval = 0.01) {
  passArrays()
}
