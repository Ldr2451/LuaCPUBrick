-- math.ult: unsigned comparison, split out of math_int.lua.
--
-- PUC compares in lua_Unsigned, which a double cannot hold past 2^53, and the
-- SIGNS do the rest exactly.  Both non-negative compare the same way signed; a
-- negative SECOND argument is astronomically larger unsigned (true); a negative
-- FIRST is not (false); two negatives keep their order (adding 2^64 preserves
-- it), so a < b decides that case too.  All four exact for integers inside
-- +/-2^53; past it the doubles already rounded, which is the 64-bit wall in
-- CHIP_LOG, not a wrong rule.
--
-- The argument checks are PUC's luaL_checkinteger, asked of the oracle shape by
-- shape: a missing argument is "got no value" and an explicit nil is "got nil",
-- so this is function(...) with select('#', ...) rather than declared parameters
-- (a declared parameter cannot be absent -- the str pieces say the same).  A
-- non-number non-string is a type error; a numeric string converts (spaces trim,
-- hex reads); anything else stringy is "got string", not the arithmetic error
-- v + 0 would raise -- so strings go through one pcall of a load-time converter,
-- the tonumber piece's shape for the same reason.  A number or converted string
-- without an integer is "number has no integer representation", which is _m(13).
--
-- This function once SILENTLY unparsed the whole piece -- every function in it
-- stopped answering, no message, no line -- and two suspects were cleared by
-- bisecting (`f(...) == nil`, bare `return` of a comparison).  What is here uses
-- only constructs this exact piece already runs: if/then/else, ==, ~=, <, and,
-- type, select, error, _m, string concat in messages.  Anything added to this
-- shape gets proved by RUNNING math.floor next to it, not by reading it.
--
-- Split out of LIB_math_int because it is the heavyweight there and almost no
-- program names it: a program that only ever floors was measured paying the
-- whole ult argument ladder at boot (tools/chip/libprobe.py).  The floor family
-- stays in math_int.lua; this piece loads only for math.ult (or math indexed
-- at run time, which loads every math piece).
--
-- This is a MASTER file, installed with
--   tools/lib/libconst.py lib/math_ult.lua LIB_math_ult --install
-- so the text the chip parses is generated rather than hand-typed into lua.ws.
math = math or {}
local function _ult_num(v)
  return v + 0
end
math.ult = function(...)
  local n = select("#", ...)
  if n == 0 then
    error("bad argument #1 to 'math.ult' (number expected, got no value)", 2)
  end
  local m = select(1, ...)
  local mt = type(m)
  if mt ~= "number" and mt ~= "string" then
    error("bad argument #1 to 'math.ult' (number expected, got " .. mt .. ")", 2)
  end
  if mt == "string" then
    local v = _m(15, m, 0)
    if v == nil then
      error("bad argument #1 to 'math.ult' (number expected, got string)", 2)
    end
    m = v
  end
  local a = _m(13, m, 0)
  if a == nil then
    error("bad argument #1 to 'math.ult' (number has no integer representation)", 2)
  end
  if n < 2 then
    error("bad argument #2 to 'math.ult' (number expected, got no value)", 2)
  end
  local w = select(2, ...)
  local wt = type(w)
  if wt ~= "number" and wt ~= "string" then
    error("bad argument #2 to 'math.ult' (number expected, got " .. wt .. ")", 2)
  end
  if wt == "string" then
    local v2 = _m(15, w, 0)
    if v2 == nil then
      error("bad argument #2 to 'math.ult' (number expected, got string)", 2)
    end
    w = v2
  end
  local b = _m(13, w, 0)
  if b == nil then
    error("bad argument #2 to 'math.ult' (number has no integer representation)", 2)
  end
  if a < 0 then
    if b < 0 then
      return a < b
    else
      return false
    end
  else
    if b < 0 then
      return true
    else
      return a < b
    end
  end
end
