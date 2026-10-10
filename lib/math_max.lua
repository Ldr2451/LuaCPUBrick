-- math.max, WITHOUT math.min.
--
-- max and min share a shape, but neither calls the other; naming one must not
-- parse the other -- the insert/remove split measured the same shape.  min is
-- lib/math_min.lua now.
--
-- Nothing here needs another piece: select is a gate, so the vararg walk needs
-- nothing else, and the pieces concatenate in any order.
--
-- This is a MASTER file, installed with
--   tools/lib/libconst.py lib/math_max.lua LIB_math_max --install
-- so the text the chip parses is generated rather than hand-typed into lua.ws.
math = math or {}
math.max = function(a, ...)
  local m = a
  for i = 1, select('#', ...) do local v = select(i, ...) if v > m then m = v end end
  return m
end
