-- table.remove, WITHOUT table.insert.  See lib/tab_insert.lua for the split and
-- the measurement.
--
-- The bounds check is PUC's own wording and its own position out of bounds case:
-- removing the last element, or any position from 1 to n+1, is allowed, and
-- anything else raises before the table is touched.  The position is an
-- integer first, exactly like insert's: 1.5 is "no integer representation"
-- and a numeric string works.
table = table or {}
table.remove = function(t, pos)
  local n = #t
  if pos == nil then pos = n end
  local ip = _m(13, pos, 0)
  if ip == nil then
    error("bad argument #2 to 'table.remove' (number has no integer representation)", 2)
  end
  if ip ~= n and (ip < 1 or n + 1 < ip) then error("bad argument #2 to 'table.remove' (position out of bounds)", 2) end
  local v = t[ip]
  local i = ip
  while i < n do t[i] = t[i + 1] i = i + 1 end
  t[i] = nil
  return v
end
