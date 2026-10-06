-- math.sin / cos / tan / asin / acos / atan, over the _m gate.
--
-- Six one-liners, six arms of the same gate, which is the shape that says
-- "piece": PUC has these in C, and the whole of them is a table of
-- (gate index, argument count).  atan takes the two-argument form because PUC
-- does, and `x or 1` is what makes atan(y) mean atan(y/1) -- atan2 does not
-- exist here and calling it is "attempt to call", not silence.
--
-- The trig functions are in one piece because they are always wanted together
-- (a program that plots or integrates wants all six), and splitting them was
-- measured: one function per piece means six parses of the same four lines.
math = math or {}
math.sin = function(x) return _m(4, x, 0) end
math.cos = function(x) return _m(5, x, 0) end
math.tan = function(x) return _m(6, x, 0) end
math.asin = function(x) return _m(7, x, 0) end
math.acos = function(x) return _m(8, x, 0) end
math.atan = function(y, x) return _m(9, y, x or 1) end
-- math.deg / math.rad, pure arithmetic over a pi literal.  The literal is
-- 180/pi and pi/180 to 17 digits, exactly as PUC computes them -- and it is a
-- LITERAL rather than math.pi on purpose: math.pi lives in LIB_math_const, a
-- separate piece the loader only pulls in when the PROGRAM names it, so
-- reaching across pieces for it would read nil.  A duplicated constant is
-- cheaper than a cross-piece dependency, and it cannot drift (both spell the
-- same double).
math.deg = function(x) return x * 57.295779513082323 end
math.rad = function(x) return x * 0.017453292519943295 end