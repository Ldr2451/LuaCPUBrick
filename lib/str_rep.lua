-- string.rep, split out of str_misc.lua.
--
-- rep was the slowest string function at run time, so it doubles instead of
-- appending: `for i = 2, n do r = r .. sep .. s end` copied O(n^2) characters
-- (measured 22.7s of wall time for 50 calls).  chunk holds rep(s, 2^k, sep) and
-- each set bit appends it, so the total copied is linear in the answer:
-- rep(s, n, sep) with n = 5 (101) answers chunk(1) .. sep .. chunk(4).
--
-- The doubling is exact because level k+1 IS level k, sep, level k -- the same
-- recurrence PUC's own str_rep uses -- including the empty-string edge:
-- rep("", 3, "-") doubles "" to "-" to "--" and answers "--".
--
-- n is luaL_checkinteger, asked of the oracle: an integral number or numeric
-- string converts ("3" works, 2.0 works), a float or float-string is "number has
-- no integer representation", anything else is "number expected, got T" --
-- including "3x", which never parses and is therefore a TYPE error, not a
-- representation one.  A numeric string is asked of the chip's own coercion
-- (_m mode 15), which answers nil for exactly the strings that never parse, so
-- the two errors stay apart without a protected call.  sep is luaL_optlstring:
-- absent or nil is "", a number converts, anything else is "got T".
--
-- Split out of LIB_str_misc because reverse is dead weight for a program that
-- only repeats (and vice versa): the tab insert/remove split measured the same
-- shape.  reverse is lib/str_reverse.lua now.
--
-- `function(...)` so an absent argument is tellable from a nil one; lib/str_upper.lua
-- says why.
--
-- This is a MASTER file, installed with
--   tools/lib/libconst.py lib/str_rep.lua LIB_str_rep --install
-- so the text the chip parses is generated rather than hand-typed into lua.ws.
string = string or {}
string.rep = function(...)
local nargs = select('#', ...)
if nargs == 0 then
  error("bad argument #1 to 'string.rep' (string expected, got no value)", 2)
end
local s, n, sep = select(1, ...)
local st = type(s)
if st == "number" then
  s = tostring(s)
elseif st ~= "string" then
  error("bad argument #1 to 'string.rep' (string expected, got " .. st .. ")", 2)
end
if nargs < 2 then
  error("bad argument #2 to 'string.rep' (number expected, got no value)", 2)
end
local nt = type(n)
local nn = n
if nt ~= "number" and nt ~= "string" then
  error("bad argument #2 to 'string.rep' (number expected, got " .. nt .. ")", 2)
end
if nt == "string" then
  local v = _m(15, n, 0)
  if v == nil then
    error("bad argument #2 to 'string.rep' (number expected, got string)", 2)
  end
  nn = v
end
local ni = _m(13, nn, 0)
if ni == nil then
  error("bad argument #2 to 'string.rep' (number has no integer representation)", 2)
end
n = ni
if sep == nil then
  sep = ""
else
  local spt = type(sep)
  if spt == "number" then
    sep = tostring(sep)
  elseif spt ~= "string" then
    error("bad argument #3 to 'string.rep' (string expected, got " .. spt .. ")", 2)
  end
end
if n <= 0 then return "" end
local r = ""
local chunk = s
local k = n
local started = false
while 0 < k do
  if k % 2 == 1 then
    if started then
      r = r .. sep .. chunk
    else
      r = chunk
      started = true
    end
  end
  k = (k - k % 2) / 2
  if 0 < k then chunk = chunk .. sep .. chunk end
end
return r
end
