-- math.max and math.min, WITHOUT fmod and modf.
--
-- All four were one piece, and naming any one of them cost 740 ticks of boot
-- (measured, tools/chip/libcost.py).  max and min are a pair that share a shape;
-- fmod and modf are a different pair that share arithmetic coercion.  Naming max
-- should not parse fmod.
--
-- Nothing here needs another piece: select is a gate, so the vararg walk needs
-- nothing else, and the pieces concatenate in any order.
math = math or {}
math.max = function(a, ...)
  local m = a
  for i = 1, select('#', ...) do local v = select(i, ...) if v > m then m = v end end
  return m
end
math.min = function(a, ...)
  local m = a
  for i = 1, select('#', ...) do local v = select(i, ...) if v < m then m = v end end
  return m
end
