-- string.upper and string.lower.
--
-- `_s(2, s)` is the case gate and it reads a STRING.  Two things went wrong before
-- this file existed, and both are here now:
--
-- 1. PUC reaches the gate through luaL_checklstring, which ACCEPTS A NUMBER and
--    converts it, so string.upper(42) is "42".  Handed a number the gate did not
--    raise -- it answered "UPPER", a literal that appears nowhere in the program, so
--    nothing anywhere said a value was mistyped.
-- 2. Handed a TABLE it also did not raise, and answered "UPPER" again.
--
-- So the piece does what luaL_checklstring does: convert a number, refuse anything
-- else, and say so in PUC's wording.  It is here rather than in the gate because
-- piece text is a string constant -- this costs boot ticks and no chip nodes -- and
-- because the gate is shared with callers that already hold a string.
--
-- One `type` call per invocation, and only the number path pays for the tostring.
-- The message is built only on the failing path.
--
-- The gate is mode 2 for upper and 3 for lower, and neither takes a length.
string = string or {}
string.upper = function(s)
local t = type(s)
if t == "number" then s = tostring(s)
elseif t ~= "string" then error("bad argument #1 to 'string.upper' (string expected, got " .. t .. ")", 2) end
return _s(2, s)
end
string.lower = function(s)
local t = type(s)
if t == "number" then s = tostring(s)
elseif t ~= "string" then error("bad argument #1 to 'string.lower' (string expected, got " .. t .. ")", 2) end
return _s(3, s)
end
