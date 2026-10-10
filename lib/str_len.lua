-- string.len, split out of str_index.lua.
--
-- Takes its string through luaL_checklstring, which converts a NUMBER and
-- refuses anything else, so string.len(999) is 3.  It did not: `#s` is an
-- opcode with no coercion in front of it, so it raised "attempt to get length
-- of a number value" on a number, and len({}) answered 0 silently where PUC
-- refuses a table.
--
-- Split out of LIB_str_index because sub's index arithmetic is dead weight for
-- a program that only takes lengths (and vice versa): the tab insert/remove
-- split measured the same shape.  sub is lib/str_sub.lua now.
--
-- `function(...)` and `select('#', ...)`, not a declared parameter: PUC says "no
-- value" for an absent argument and "nil" for a nil one, and a declared parameter
-- cannot be absent -- Lua fills it with nil.  lib/str_upper.lua has the whole
-- argument, including the shape that got "table" wrong.
--
-- This is a MASTER file, installed with
--   tools/lib/libconst.py lib/str_len.lua LIB_str_len --install
-- so the text the chip parses is generated rather than hand-typed into lua.ws.
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
