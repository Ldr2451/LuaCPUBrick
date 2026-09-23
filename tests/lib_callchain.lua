-- Minimal repro for the call-path bug the string.format work uncovered.
--
-- `_fmt_roundr` then `_fmt_int` fails with "bad argument (number expected)",
-- while replacing the first call with a trivial one works, and so does dropping
-- the second.  So it is the *sequence* -- a call to a function whose own body
-- makes calls, immediately followed by a call to a function with a while loop --
-- not format, not _m, and not nesting depth on its own (four plain levels work).
--
-- These functions are here to be called by the suite's `call-chain` case; the
-- assertions are in tests/cases.py.  Nothing in lua.ws depends on this file.
string = string or {}
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

_id = function(x)
  return x
end

-- fails: roundr then _fmt_int
call_chain_bad = function(v, prec)
  local scale = 10 ^ prec
  local r = _fmt_roundr(v, scale)
  local ip = _m(1, r / scale)
  return _fmt_int(ip)
end

-- works: roundr then a trivial call
call_chain_ok1 = function(v, prec)
  local scale = 10 ^ prec
  local r = _fmt_roundr(v, scale)
  return _id(r)
end

-- works: a trivial call then _fmt_int
call_chain_ok2 = function(v, prec)
  local scale = 10 ^ prec
  local r = _id(v * scale)
  local ip = _m(1, r / scale)
  return _fmt_int(ip)
end
