-- Minimal repro for the call-path bug the string.format work uncovered, with
-- the bisection that narrowed it.  These are globals, not locals, because a
-- local function that reads an enclosing local is a closure and the chip has no
-- closures yet -- and because the shapes that merely confirmed a neighbour are
-- gone and only their results are kept (below).  It is 24 globals, which is
-- most of what a program has left: every gate builtin takes a slot of its own,
-- and MAX_GLOBALS is the whole table.  That is why it is 96 and not 64, since
-- this file and a new builtin did not both fit.
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
-- them as sibling arguments of one print fails, and -- the useful narrowing --
-- two of them in two separate statements fails too, so it is not the argument
-- window.  probe_s2 called twice side by side passes, and so does four mixed
-- calls in one print, so it is neither repetition nor the print.
--
-- What is left to find, and what has been ruled out:
--   - tools/dump_vm.py on the failing program: the bytecode is *correct*.  The two
--     calls are the same instruction sequence at bases 0 and 1, and the second
--     one's frame does not reach the first call's live registers.
--   - tools/trace_pc.py watching vmBase, fnDepth, retCountV and registers 0..8:
--     the second call's frame base was one too high, and inside the callee the
--     first two instructions had written the new frame while the third and
--     later ones wrote the caller's -- vmBase is a file-level var, vmStep is
--     inlined four times, and the compiler shares one Get per var across the
--     copies, so the copy that changes the base and the copy that reads it in
--     the same tick disagree.  vmHold now ends the burst at a frame change, the
--     other half of the fmtGo rule.
--   - Not a mod-local collision: a function that calls one gate builtin and then
--     uses its own parameter again is fine (x + _m(1, x) comes out right), so
--     vmStep's WireScript temporaries are not landing on the Lua frame's low
--     registers in the ordinary case.
--   - The trace's two calls enter the function at 526 and 529, which looks like
--     the giveaway but is only the burst boundary: the callee's first
--     instructions run in the tick that pushed the frame, which is the bug above.
--   - The second cause was separate and survived the first fix: _m reads a third
--     argument that a two-argument call never passed, and a mod call in a
--     conditional's *value* position is evaluated whether the arm runs or not --
--     `let y = if 2 < nargs then numArg(vTag(a + 3), ...) else 0.0` still ran
--     numArg on the slot, which held a string from the previous call, and raised
--     "bad argument (number expected)" on an argument that did not exist.  The
--     fix is the idiom outvec already used: choose the tag and the value first,
--     then hand numArg those.
--
-- So both causes are fixed and the case in tests/cases.py pins all of it: the
-- shapes that always worked and the two that used to fail.  The file stays as
-- the reproducer.
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
