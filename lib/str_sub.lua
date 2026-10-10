-- string.sub, split out of str_index.lua.
--
-- Takes its string through luaL_checklstring, which converts a NUMBER and
-- refuses anything else, so string.sub(12345, 2, 3) is "234".  It did not: `#s`
-- is an opcode with no coercion in front of it, so it raised "attempt to get
-- length of a number value" on a number.
--
-- Split out of LIB_str_index because len is dead weight for a program that only
-- takes substrings (and vice versa): the tab insert/remove split measured the
-- same shape.  len is lib/str_len.lua now.
--
-- `function(...)` and `select('#', ...)`, not a declared parameter: PUC says "no
-- value" for an absent argument and "nil" for a nil one, and a declared parameter
-- cannot be absent -- Lua fills it with nil.  lib/str_upper.lua has the whole
-- argument, including the shape that got "table" wrong.
--
-- This is a MASTER file, installed with
--   tools/lib/libconst.py lib/str_sub.lua LIB_str_sub --install
-- so the text the chip parses is generated rather than hand-typed into lua.ws.
string = string or {}
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
