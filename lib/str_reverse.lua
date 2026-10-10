-- string.reverse, split out of str_misc.lua.
--
-- Takes its string through luaL_checklstring: convert a NUMBER, refuse anything
-- else, and say "no value" for an absent argument.  string.reverse(123) is "321" in
-- PUC; without the coercion in front the loop answered "attempt to get length of
-- a number value", because the loop counts #s down.
--
-- Split out of LIB_str_misc because rep's doubling ladder and three-argument
-- checking are dead weight for a program that only reverses (and vice versa):
-- the tab insert/remove split measured the same shape.  rep is lib/str_rep.lua
-- now.
--
-- `function(...)` so an absent argument is tellable from a nil one; lib/str_upper.lua
-- says why.
--
-- This is a MASTER file, installed with
--   tools/lib/libconst.py lib/str_reverse.lua LIB_str_reverse --install
-- so the text the chip parses is generated rather than hand-typed into lua.ws.
string = string or {}
string.reverse = function(...)
local nv = select('#', ...) == 0
local s = select(1, ...)
local t = type(s)
if t == "number" then
  s = tostring(s)
elseif t ~= "string" then
  local w = t
  if nv then w = "no value" end
  error("bad argument #1 to 'string.reverse' (string expected, got " .. w .. ")", 2)
end
local r = ""
for i = #s, 1, -1 do r = r .. _s(1, s, i - 1, 1) end
return r
end
