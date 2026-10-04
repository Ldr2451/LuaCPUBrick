-- table.insert, WITHOUT table.remove.
--
-- All of tab_ins was one piece and naming either cost ~640 ticks of boot
-- (measured, tools/chip/libcost.py).  insert is the only one that shifts a run
-- of elements; remove is the only one that closes the gap it leaves.  They are
-- separate functions in PUC and separate here.
--
-- Nothing here needs another piece: select is a gate, and `#t` is an opcode.
table = table or {}
table.insert = function(t, ...)
  local n = #t
  local c = select('#', ...)
  if c == 1 then
    t[n + 1] = (...)
  elseif c == 2 then
    local pos, v = ...
    for i = n, pos, -1 do t[i + 1] = t[i] end
    t[pos] = v
  end
end
