-- string.byte, WITHOUT string.char.  See lib/str_char.lua.
--
-- A run of one index returns the byte directly; a run builds a table and unpacks
-- it, because the answer is variadic and there is no variadic return in the chip.
-- `_s(4, ...)` is the byte gate.
--
-- Negative indices count from the end on both ends, then both are clamped into
-- the string, and an empty range returns nothing at all rather than a zero.
string = string or {}
string.byte = function(s, i, j)
i = i or 1
j = j or i
if i < 0 then i = #s + i + 1 end
if j < 0 then j = #s + j + 1 end
if i < 1 then i = 1 end
if j > #s then j = #s end
if i > j then return end
if i == j then return _s(4, s, i - 1, 0) end
local r = {}
for k = i, j do r[#r + 1] = _s(4, s, k - 1, 0) end
return unpack(r, 1, #r)
end
