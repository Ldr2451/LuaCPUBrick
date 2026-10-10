-- math.sin / cos / tan / asin / acos / atan, over the _m gate.
--
-- Six one-liners, six arms of the same gate, which is the shape that says
-- "piece": PUC has these in C, and the whole of them is a table of
-- (gate index, argument count).  atan takes the two-argument form because PUC
-- does, and `x or 1` is what makes atan(y) mean atan(y/1) -- atan2 does not
-- exist here and calling it is "attempt to call", not silence.
--
-- math.deg / math.rad were the tail of this piece and are not anymore: pure
-- arithmetic over pi literals, dead weight for a program that only takes a
-- sine (and vice versa).  They are lib/math_deg.lua now.
--
-- This is a MASTER file, installed with
--   tools/lib/libconst.py lib/math_trig.lua LIB_math_trig --install
-- so the text the chip parses is generated rather than hand-typed into lua.ws.
math = math or {}
math.sin = function(x) return _m(4, x, 0) end
math.cos = function(x) return _m(5, x, 0) end
math.tan = function(x) return _m(6, x, 0) end
math.asin = function(x) return _m(7, x, 0) end
math.acos = function(x) return _m(8, x, 0) end
math.atan = function(y, x) return _m(9, y, x or 1) end