-- math.floor / ceil / tointeger / type / abs / sqrt: one-liners over the _m gate.
--
-- A CHIP would be the wrong shape for these: each is a single call, and PUC
-- having them in C is what puts them in a piece rather than behind six gates.
--
-- This is a MASTER file, installed with
--   tools/lib/libconst.py lib/math_int.lua LIB_math_int --install
-- so the text the chip parses is generated rather than hand-typed into lua.ws.
--
-- math.ult is here now (below), after a session of failing silently: a piece that
-- does not PARSE is not an error the program can see -- every function in it stops
-- answering, silently, with no message and no line.  The lesson kept: a piece is a
-- single unit of failure, so anything added to one is tested by RUNNING the piece
-- (math.floor is the canary next to it), not by reading it.
math = math or {}
-- math.ult belongs here now: PUC compares in lua_Unsigned, which a double cannot
-- hold past 2^53, and the SIGNS do the rest exactly.  Both non-negative compare
-- the same way signed; a negative SECOND argument is astronomically larger
-- unsigned (true); a negative FIRST is not (false); two negatives keep their
-- order (adding 2^64 preserves it), so a < b decides that case too.  All four
-- exact for integers inside +/-2^53; past it the doubles already rounded, which
-- is the 64-bit wall in CHIP_LOG, not a wrong rule.
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
    local ok, v = pcall(_ult_num, m)
    if ok then
      m = v
    else
      error("bad argument #1 to 'math.ult' (number expected, got string)", 2)
    end
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
    local ok2, v2 = pcall(_ult_num, w)
    if ok2 then
      w = v2
    else
      error("bad argument #2 to 'math.ult' (number expected, got string)", 2)
    end
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
math.floor = function(x) return _m(1, x, 0) end
math.ceil = function(x) return _m(2, x, 0) end
math.tointeger = function(x) return _m(13, x, 0) end
math.type = function(x) return _m(14, x, 0) end
math.abs = function(x) if type(x) == "string" then x = x + 0.0 end if x < 0 then return -x end if x == 0 then return x - x end return x end
math.sqrt = function(x) return _m(3, x, 0) end