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