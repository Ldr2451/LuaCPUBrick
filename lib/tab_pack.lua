-- table.pack and table.move.  table.unpack moved to lib/tab_unpack.lua, which
-- is one line and a gate; see that file for the measurement.
--
-- This file used to carry table.unpack as well, and naming it cost 460 ticks of
-- boot to parse these two functions.
--
-- Nothing here needs another piece: table.pack is a table constructor plus select,
-- table.move is one loop.  So naming move must not parse pack, and that is the
-- only reason they are separate -- they are not, this is one piece for both.
table = table or {}
table.pack = function(...) local t = {...} t.n = select('#', ...) return t end
table.move = function(a1, f, e, t, a2)
  a2 = a2 or a1
  if e >= f then
    if t > e or t <= f or a1 ~= a2 then
      for i = 0, e - f do a2[t + i] = a1[f + i] end
    else
      for i = e - f, 0, -1 do a2[t + i] = a1[f + i] end
    end
  end
  return a2
end
