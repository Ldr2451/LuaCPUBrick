-- string.byte, WITHOUT string.char.  See lib/str_char.lua for the split and the
-- measurement (tools/chip/libcost.py).
--
-- PUC takes the string through luaL_checklstring: converts a NUMBER, refuses anything
-- else, and says "no value" for an absent argument rather than "nil".  string.byte(1)
-- is 49 there -- the byte of "1".  Here it raised "attempt to get length of a number
-- value", and that is also why ('A').byte(1) used to look like a missing string
-- metatable.  It is not one: op 29 already falls back to the string table for a
-- string receiver, and PUC does not prepend the receiver for a dot call either --
-- ('A').byte(1) is string.byte(1) there too, and that is 49 -- so the whole of that
-- divergence was this one coercion.
--
-- A run of one index returns the byte directly; a run builds a table and unpacks it,
-- because the answer is variadic and the chip has no variadic return.  `_s(4, ...)`
-- is the byte gate.  Negative indices count from the end on both ends, then both are
-- clamped into the string, and an empty range returns nothing at all.
--
-- `function(...)` so an absent argument is tellable from a nil one; lib/str_case.lua
-- says why, and why the other two shapes are wrong.  Statement forms only: a piece
-- is Lua.
string = string or {}
string.byte = function(...)
local nv = select('#', ...) == 0
local s, i, j = select(1, ...)
local t = type(s)
if t == "number" then
  s = tostring(s)
elseif t ~= "string" then
  local w = t
  if nv then w = "no value" end
  error("bad argument #1 to 'string.byte' (string expected, got " .. w .. ")", 2)
end
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
