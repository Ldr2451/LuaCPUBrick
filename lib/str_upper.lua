-- string.upper, split out of str_case.lua.
--
-- `_s(2, s)` is the case gate and it reads a STRING.  Without this file PUC's
-- luaL_checklstring step is missing: handed a NUMBER the gate did not raise --
-- it answered "UPPER", a literal that appears nowhere in the program -- and
-- handed a TABLE it answered "UPPER" again.  PUC says "got no value" for an
-- ABSENT argument and "got nil" for a nil one, because luaL_typename answers
-- for the absence of a value.  ('abc').upper() is string.upper() with an empty
-- argument list, so the two must be told apart.
--
-- THE ARGV DOES IT, AND IT IS THE WHOLE ARGUMENT LIST: declared `function(...)`
-- with `s` taken out of it, because a DECLARED parameter cannot be absent --
-- Lua fills it with nil, which is indistinguishable from a passed nil.
--
-- Split out of LIB_str_case because lower is dead weight for a program that
-- only uppers (and vice versa): the tab insert/remove split measured the same
-- shape.  lower is lib/str_lower.lua now.
--
-- Statement forms only: a parenthesised if-expression is a WireScript extension
-- and a piece is LUA -- real PUC answers "unexpected symbol near 'if'".  The
-- gate is mode 2 for upper.
--
-- ONE DIVERGENCE LEFT, and it is not fixable from a piece: PUC names the function in
-- this message by its CALL SITE, so ('abc').upper() is string.upper() with no
-- argument and PUC says "to '?'" -- it cannot see a name -- while string.upper()
-- says "to 'string.upper'".  The name here is the constant, so a call that arrived
-- through op 29's string fallback reports the spelled name where PUC reports '?'.
-- Nothing in a Lua piece can observe how it was called.
--
-- This is a MASTER file, installed with
--   tools/lib/libconst.py lib/str_upper.lua LIB_str_upper --install
-- so the text the chip parses is generated rather than hand-typed into lua.ws.
string = string or {}
string.upper = function(...)
local nv = select('#', ...) == 0
local s = select(1, ...)
local t = type(s)
if t == "number" then
  s = tostring(s)
elseif t ~= "string" then
  local w = t
  if nv then w = "no value" end
  error("bad argument #1 to 'string.upper' (string expected, got " .. w .. ")", 2)
end
return _s(2, s)
end
