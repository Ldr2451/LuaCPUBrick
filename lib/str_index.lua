-- string.len and string.sub.
--
-- Both take their string through luaL_checklstring, which converts a NUMBER and
-- refuses anything else, so string.len(999) is 3 and string.sub(12345, 2, 3) is "23".
-- Neither did: `#s` is an opcode with no coercion in front of it, so both raised
-- "attempt to get length of a number value" on a number, and len({}) answered 0
-- silently where PUC refuses a table.
--
-- `function(...)` and `select('#', ...)`, not a declared parameter: PUC says "no
-- value" for an absent argument and "nil" for a nil one, and a declared parameter
-- cannot be absent -- Lua fills it with nil.  lib/str_case.lua has the whole
-- argument, including the shape that got "table" wrong.
string = string or {}
string.len = function(...)
local nv = select('#', ...) == 0
local s = select(1, ...)
local t = type(s)
if t == "number" then
  s = tostring(s)
elseif t ~= "string" then
  local w = t
  if nv then w = "no value" end
  error("bad argument #1 to 'string.len' (string expected, got " .. w .. ")", 2)
end
return #s
end
string.sub = function(...)
local nv = select('#', ...) == 0
local s, i, j = select(1, ...)
local t = type(s)
if t == "number" then
  s = tostring(s)
elseif t ~= "string" then
  local w = t
  if nv then w = "no value" end
  error("bad argument #1 to 'string.sub' (string expected, got " .. w .. ")", 2)
end
local l = #s
i = i or 1
j = j or -1
if i < 0 then i = l + i + 1 if i < 1 then i = 1 end elseif i == 0 then i = 1 end
if j < 0 then j = l + j + 1 elseif j > l then j = l end
if i > j then return "" end
return _s(1, s, i - 1, j - i + 1)
end
