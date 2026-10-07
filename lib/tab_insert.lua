-- table.insert, WITHOUT table.remove.
--
-- All of tab_ins was one piece and naming either cost ~640 ticks of boot
-- (measured, tools/chip/libcost.py).  insert is the only one that shifts a run
-- of elements; remove is the only one that closes the gap it leaves.  They are
-- separate functions in PUC and separate here.
--
-- Nothing here needs another piece: select is a gate, `_m` is a gate, and
-- `#t` is an opcode.  The position check is PUC's, in PUC's order: an integer
-- first (1.5 is "no integer representation", and so is a missing one), then
-- 1..n+1 ("position out of bounds").  A missing or extra argument is "wrong
-- number of arguments", also PUC's words.  nextvar.lua:548/555/556 are the
-- asserts that caught the missing checks.
table = table or {}
table.insert = function(t, ...)
  local n = #t
  local c = select('#', ...)
  if c == 1 then
    t[n + 1] = (...)
  elseif c == 2 then
    local pos, v = ...
    local ip = _m(13, pos, 0)
    if ip == nil then
      error("bad argument #2 to 'table.insert' (number has no integer representation)", 2)
    end
    if ip < 1 or ip > n + 1 then
      error("bad argument #2 to 'table.insert' (position out of bounds)", 2)
    end
    for i = n, ip, -1 do t[i + 1] = t[i] end
    t[ip] = v
  else
    error("wrong number of arguments to 'insert'", 2)
  end
end
