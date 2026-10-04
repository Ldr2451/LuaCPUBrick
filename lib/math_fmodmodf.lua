-- math.fmod and math.modf, WITHOUT max and min.
--
-- The other half of the old math_misc; see lib/math_maxmin.lua for the split and
-- the measurement.
--
-- Both coerce a string argument with `+ 0.0` first, which is the host-faithful
-- reading and comes free from the arithmetic coercion rather than from a parse.
-- fmod then has to reproduce C's sign, which is the sign of a - b for a mixed-sign
-- pair with a nonzero remainder -- `%` alone gives Lua's floored answer.
math = math or {}
math.fmod = function(a, b)
  if type(a) == "string" then a = a + 0.0 end
  if type(b) == "string" then b = b + 0.0 end
  local r = a % b
  if r ~= 0 and (a < 0) ~= (b < 0) then r = r - b end
  return r
end
math.modf = function(x) if type(x) == "string" then x = x + 0.0 end local i = (x >= 0 and _m(1, x, 0)) or _m(2, x, 0) return i, x - i end
