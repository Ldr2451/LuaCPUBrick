-- string.upper and string.lower.
--
-- `_s(2, s)` is the case gate and it reads a STRING.  Three things go wrong without
-- this file, and all three are here:
--
-- 1. PUC reaches the gate through luaL_checklstring, which ACCEPTS A NUMBER and
--    converts it, so string.upper(42) is "42".  Handed a number the gate did not
--    raise -- it answered "UPPER", a literal that appears nowhere in the program, so
--    nothing anywhere said a value was mistyped.
-- 2. Handed a TABLE it also did not raise, and answered "UPPER" again.
-- 3. PUC says "got no value" for an ABSENT argument and "got nil" for a nil one,
--    because luaL_typename answers for the absence of a value.  ('abc').upper() is
--    string.upper() with an empty argument list, so the two must be told apart.
--
-- THE ARGV DOES IT, AND IT IS THE WHOLE ARGUMENT LIST: these are declared
-- `function(...)` and take `s` out of it, because a DECLARED parameter cannot be
-- absent -- Lua fills it with nil, which is indistinguishable from a passed nil.
-- Two shapes were wrong here before this one was right:
--
--   select('#', s)          always 1: it passes s itself, so a nil counts
--   select('#', ...)        with `function(s, ...)` counts only the EXTRA args, so
--                           pcall(string.len, {}) read as absent and said "no value"
--                           where PUC says "table"
--   select('#', ...)        with `function(...)` counts argument 1 as well, which is
--                           the only one of the three that is right
--
-- Two more things this file is not allowed to do, both of which cost a run:
--
--   a PARENTHESISED IF-EXPRESSION.  `(if select('#', ...) == 0 then "no value" else
--   t)` is a WireScript extension and a piece is LUA: real PUC answers "unexpected
--   symbol near 'if'" and the chip answers "unexpected token in expression" -- and
--   because a parse failure leaves an empty log rather than a message, the chip's
--   version prints nothing and reports nothing.  Statement forms only.
--
--   type(t) ANYWHERE ELSE.  lib/str_index.lua has the same rule in one line.
--
-- All of it is here rather than in the gate because piece text is a string constant:
-- it costs boot ticks and no chip nodes.  The message is built only on the failure.
--
-- The gate is mode 2 for upper and 3 for lower, and neither takes a length.
--
-- ONE DIVERGENCE LEFT, and it is not fixable from a piece: PUC names the function in
-- this message by its CALL SITE, so ('abc').upper() is string.upper() with no
-- argument and PUC says "to '?'" -- it cannot see a name -- while string.upper()
-- says "to 'string.upper'".  The name here is the constant, so a call that arrived
-- through op 29's string fallback reports the spelled name where PUC reports '?'.
-- Nothing in a Lua piece can observe how it was called.
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
