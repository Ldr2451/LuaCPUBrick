-- string.rep and string.reverse.
--
-- Both take their string through luaL_checklstring: convert a NUMBER, refuse anything
-- else, and say "no value" for an absent argument.  string.reverse(123) is "321" in
-- PUC; here it raised "attempt to get length of a number value", because the loop
-- counts #s down and there is no coercion in front of that opcode.
--
-- rep's check earns its place on correctness rather than on the message: `r .. s`
-- already CONVERTS a number, so rep(7, 3) was "777" and agreed with PUC by accident.
-- But rep({}, 2) answered NIL silently where PUC refuses a table, and a silent nil
-- is the shape of bug that costs a session.  The asymmetry between the two halves of
-- this piece was an accident of the concatenation, not a decision.
--
-- rep is also the slowest string function at run time, and for a reason no gate can
-- remove: `for i = 2, n do r = r .. sep .. s end` is n-1 concatenations of a growing
-- string, so O(n^2) in the characters.  Measured 22.7s of wall time for 50 calls.
--
-- `function(...)` so an absent argument is tellable from a nil one; lib/str_case.lua
-- says why.
string = string or {}
string.rep = function(...)
local nv = select('#', ...) == 0
local s, n, sep = select(1, ...)
local t = type(s)
if t == "number" then
  s = tostring(s)
elseif t ~= "string" then
  local w = t
  if nv then w = "no value" end
  error("bad argument #1 to 'string.rep' (string expected, got " .. w .. ")", 2)
end
if n <= 0 then return "" end
sep = sep or ""
local r = s
for i = 2, n do r = r .. sep .. s end
return r
end
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
