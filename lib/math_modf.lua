-- math.modf, WITHOUT math.fmod.
--
-- fmod reproduces C's sign in seven lines next to this one-liner; naming one
-- must not parse the other -- the insert/remove split measured the same shape.
-- fmod is lib/math_fmod.lua now.
--
-- The string coercion (`+ 0.0`) is the host-faithful reading and comes free
-- from the arithmetic coercion rather than from a parse.
--
-- This is a MASTER file, installed with
--   tools/lib/libconst.py lib/math_modf.lua LIB_math_modf --install
-- so the text the chip parses is generated rather than hand-typed into lua.ws.
math = math or {}
math.modf = function(x) if type(x) == "string" then x = x + 0.0 end local i = (x >= 0 and _m(1, x, 0)) or _m(2, x, 0) return i, x - i end
