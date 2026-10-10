-- string.lower, split out of str_case.lua.
--
-- `_s(3, s)` is the case gate and it reads a STRING.  Without this file PUC's
-- luaL_checklstring step is missing: handed a NUMBER the gate did not raise,
-- and handed a TABLE it did not raise either.  PUC says "got no value" for an
-- ABSENT argument and "got nil" for a nil one, because luaL_typename answers
-- for the absence of a value.
--
-- THE ARGV DOES IT, AND IT IS THE WHOLE ARGUMENT LIST: declared `function(...)`
-- with `s` taken out of it, because a DECLARED parameter cannot be absent --
-- Lua fills it with nil, which is indistinguishable from a passed nil.
--
-- Split out of LIB_str_case because upper is dead weight for a program that
-- only lowers (and vice versa): the tab insert/remove split measured the same
-- shape.  upper is lib/str_upper.lua now.
--
-- Statement forms only: a parenthesised if-expression is a WireScript extension
-- and a piece is LUA -- real PUC answers "unexpected symbol near 'if'".  The
-- gate is mode 3 for lower.
--
-- Same call-site divergence as upper (see str_upper.lua): PUC says "to '?'"
-- for a method call where the piece says "to 'string.lower'".
--
-- This is a MASTER file, installed with
--   tools/lib/libconst.py lib/str_lower.lua LIB_str_lower --install
-- so the text the chip parses is generated rather than hand-typed into lua.ws.
string = string or {}
string.lower = function(...)
local nv = select('#', ...) == 0
local s = select(1, ...)
local t = type(s)
if t == "number" then
  s = tostring(s)
elseif t ~= "string" then
  local w = t
  if nv then w = "no value" end
  error("bad argument #1 to 'string.lower' (string expected, got " .. w .. ")", 2)
end
return _s(3, s)
end
