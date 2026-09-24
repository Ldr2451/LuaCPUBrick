-- Minimal repro for the call-path bug the string.format work uncovered, with
-- the bisection that narrowed it.  These are globals, not locals, because a
-- local function that reads an enclosing local is a closure and the chip has no
-- closures yet -- and because the chip has room for only 29 program globals, so
-- the shapes that merely confirmed a neighbour are gone and only their results
-- are kept (below).
--
-- The failure is "bad argument (number expected)", which numArg raises, so some
-- builtin is being handed a non-number.  Replacing the first call with a trivial
-- one works; so does dropping the second.  The bisection, smallest first:
--
--   a  a call to a function that calls a function, then _m          works
--   b  a call to a function that calls _m, then _m                 works
--   c  a call to a function that calls both, then _m               works
--   d  a call to a function that calls a function, then a
--      while-loop function that makes no calls in the loop           works
--   e  as d, but the first call returns nothing                     works
--   f  a call to a function that calls a function, then r + 1       works
--   g  the real first call, then _m, then return the value          works
--   h  the real first call, then _m, then the no-call while loop    works
--   j  a cheap first call, then _m, then the real fmt_int           works
--   l  a call to a function with no calls, then a while loop
--      that calls _m                                                 works
--   n  the real first call, then a while loop calling _m not _s     FAILS
--   p  the real first call with its conditional removed, then
--      fmt_int                                                        works
--   o  a first function with *no calls at all* whose body is an
--      if/elseif chain assigning a local, then fmt_int               FAILS
--   s2 two locals and the compound condition, then fmt_int           works
--   s3 three locals and a simple condition, then fmt_int             works
--
-- and the failure is not only about the pair: one call_chain_ok2 works, two of
-- them as sibling arguments of one print fails, and a print of four mixed calls
-- fails where any two of them pass.  So it is cumulative state around the call
-- windows rather than one bad pair.
--
-- So the shape is: a call to a function whose body has a conditional that
-- assigns one of its locals, immediately followed by a call to a function with a
-- while loop that calls a builtin.  Neither half is wrong on its own -- fmt_int
-- called first is fine, and the conditional function called first into anything
-- else is fine.  probe_o is the smallest failing pair found: `_chain_cond` makes
-- no calls whatsoever.
--
-- What is left to find: the interaction is between the callee's frame (which
-- aliases the caller's registers above the call's base -- fRegs records the size
-- but nothing reads it) and the next call's base register.  `_fmt_int` compiles
-- to nine registers because its condition temporaries go up to r8, and
-- call_chain_ok2's frame is six; the sibling-argument failures are where the
-- second call's base lands inside the first call's frame.  tools/dump_vm.py on
-- the failing program and tools/trace_pc.py watching the registers both show
-- correct values right up to the failing call, so the corruption is in a
-- register the trace is not watching.
--
-- The suite's `call-chain` case pins the shapes that work, so a fix cannot land
-- as a change to those; nothing in lua.ws depends on this file.
string = string or {}

-- The chip's two gate builtins, as Lua, so the oracle can run this file too: on
-- the chip both are already declared as globals and this is skipped.  Only the
-- modes this file uses are here -- _m(1, x) is math.floor and _s(1, s, i, n) is
-- a substring with a 0-based start and a length.
if _m == nil then
  _m = function(mode, x) return math.floor(x) end
end
if _s == nil then
  _s = function(mode, s, i, n) return string.sub(s, i + 1, i + n) end
end

_fmt_digits = "0123456789"

_fmt_int = function(v)
  local neg = false
  if v < 0 then
    neg = true
    v = -v
  end
  if v == 0 then
    return "0"
  end
  local s = ""
  while v >= 1 do
    local d = _m(1, v % 10) + 1
    s = _s(1, _fmt_digits, d - 1, 1) .. s
    v = _m(1, v / 10)
  end
  if neg then
    s = "-" .. s
  end
  return s
end

_fmt_twoprod = function(a, b, p)
  local c = 134217729 * a
  local ah = c - (c - a)
  local al = a - ah
  local d = 134217729 * b
  local bh = d - (d - b)
  local bl = b - bh
  local e = (ah * bh - p) + ah * bl + al * bh
  return e + al * bl
end

_fmt_roundr = function(v, scale)
  local p = v * scale
  local e = _fmt_twoprod(v, scale, p)
  local fl = _m(1, p)
  local fr = p - fl
  if fr > 0.5 or (fr == 0.5 and e > 0) then
    fl = fl + 1
  elseif fr == 0.5 and e == 0 and fl % 2 == 1 then
    fl = fl + 1
  end
  return fl
end

-- the first function of the original report
_chain_cond = function(a, b)
  local p = a * b
  local q = p - b
  local r = a + b
  local s = q
  if s > 0.5 or (s == 0.5 and r > 0) then
    s = s + 1
  elseif s == 0.5 and r == 0 and a % 2 == 1 then
    s = s + 1
  end
  return s
end

-- the same with the real roundr, and the original three
call_chain_bad = function(v, prec)
  local scale = 10 ^ prec
  local r = _fmt_roundr(v, scale)
  local ip = _m(1, r / scale)
  return _fmt_int(ip)
end
call_chain_ok1 = function(v, prec)
  local scale = 10 ^ prec
  local r = _fmt_roundr(v, scale)
  return r
end
call_chain_ok2 = function(v, prec)
  local scale = 10 ^ prec
  local r = v * scale
  local ip = _m(1, r / scale)
  return _fmt_int(ip)
end

-- the conditional alone, one feature at a time
_c1 = function(a)
  local s = a
  if s > 0.5 then
    s = s + 1
  end
  return s
end
_c2 = function(a)
  local s = a
  if s > 0.5 or (s == 0.5 and a > 0) then
    s = s + 1
  end
  return s
end
_c3 = function(a)
  local s = a
  if s > 0.5 then
    s = s + 1
  elseif s < 0 then
    s = s - 1
  end
  return s
end
_c4 = function(a)
  local s = a
  if s > 0.5 then
    local t = 1
  end
  return s
end

-- s1 fails: three locals and a parenthesised sub-expression in the condition.
-- Two features, so one at a time: an extra local, and the parens.
_c5 = function(a)
  local p = a
  local q = p
  local s = q
  if s > 0.5 or (s == 0.5 and a > 0) then
    s = s + 1
  elseif s < 0 then
    s = s - 1
  end
  return s
end
_c6 = function(a)
  local q = a
  local s = q
  if s > 0.5 or (s == 0.5 and a > 0) then
    s = s + 1
  end
  return s
end
_c7 = function(a)
  local p = a
  local q = p
  local s = q
  if s > 0.5 then
    s = s + 1
  end
  return s
end
_c8 = function(a)
  local s = a
  if (s > 0.5) or (s == 0.5 and a > 0) then
    s = s + 1
  end
  return s
end
_c9 = function(a)
  local s = a
  if s > 0.5 and (a > 0) then
    s = s + 1
  end
  return s
end
probe_o = function(x) return _fmt_int(_chain_cond(x, 2)) end
probe_s1 = function(x) return _fmt_int(_c5(x)) end
probe_s2 = function(x) return _fmt_int(_c6(x)) end
probe_s3 = function(x) return _fmt_int(_c7(x)) end
probe_s4 = function(x) return _fmt_int(_c8(x)) end
probe_s5 = function(x) return _fmt_int(_c9(x)) end
