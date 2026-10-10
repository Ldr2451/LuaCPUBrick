-- math.fmod, WITHOUT math.modf.
--
-- fmod has to reproduce C's sign, which is the sign of a - b for a mixed-sign
-- pair with a nonzero remainder -- `%` alone gives Lua's floored answer.  modf
-- is a one-liner next to it; naming one must not parse the other -- the
-- insert/remove split measured the same shape.  modf is lib/math_modf.lua now.
--
-- The string coercion (`+ 0.0`) is the host-faithful reading and comes free
-- from the arithmetic coercion rather than from a parse.
--
-- This is a MASTER file, installed with
--   tools/lib/libconst.py lib/math_fmod.lua LIB_math_fmod --install
-- so the text the chip parses is generated rather than hand-typed into lua.ws.
math = math or {}
math.fmod = function(a, b)
  if type(a) == "string" then a = a + 0.0 end
  if type(b) == "string" then b = b + 0.0 end
  local r = a % b
  if r ~= 0 and (a < 0) ~= (b < 0) then r = r - b end
  return r
end
