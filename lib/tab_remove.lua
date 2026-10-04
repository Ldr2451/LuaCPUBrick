-- table.remove, WITHOUT table.insert.  See lib/tab_insert.lua for the split and
-- the measurement.
--
-- The bounds check is PUC's own wording and its own position out of bounds case:
-- removing the last element, or any position from 1 to n+1, is allowed, and
-- anything else raises before the table is touched.
table = table or {}
table.remove = function(t, pos)
  local n = #t
  if pos == nil then pos = n end
  if pos ~= n and (pos < 1 or n + 1 < pos) then error("bad argument #2 to 'remove' (position out of bounds)", 2) end
  local v = t[pos]
  local i = pos
  while i < n do t[i] = t[i + 1] i = i + 1 end
  t[i] = nil
  return v
end
