-- tonumber(v [, base]), PUC 5.5's spelling.
--
-- PUC's tonumber is a thin C wrapper over luaO_str2num, and the chip's
-- string-to-number primitive is the arithmetic coercion (the ALU's arithValL,
-- which runs the host's ParseInt/ParseNumber gates).  So this piece is a thin
-- wrapper over the coercion: `v + 0` already is PUC's conversion -- leading and
-- trailing spaces, a full-string requirement, the host's integer-or-float tag,
-- and the host's refusal of the "inf"/"infinity"/"nan" spellings, which is also
-- what PUC's tonumber does.  Writing the parse a second time here would have
-- been a second rule to keep in step with the first; reusing it means
-- tonumber(s) + 1 and s + 1 cannot disagree.
--
-- Measured against real Lua 5.5:
--   tonumber(3) 3.5 -0.0      themselves
--   tonumber('10') ' 42 '     10, 42      tonumber('3.5') 3.5
--   tonumber('1e3') '.5' '5.' 1000.0, 0.5, 5.0
--   tonumber('x') '' '10abc'  nil (the whole string must be a number)
--   tonumber('inf') 'nan'     nil         (the host refuses them, PUC agrees)
--   tonumber(nil) {} true     nil
--   tonumber()                bad argument #1 to 'tonumber' (value expected)
--   tonumber(3.5, 10)         bad argument #1 (string expected, got number)
--   tonumber('10', 99)        bad argument #2 (base out of range)
--   tonumber('ff', 16)        255      tonumber('1010', 2) 10
--   tonumber(' -17 ', 8)      -15      tonumber('zz', 36) 1295
--   tonumber('10', 10)        10       tonumber(' 10 ', 10) 10
--   tonumber('1e3', 10)       nil      (no exponent with an explicit base)
--   tonumber('1.5', 16)       nil      (no point either)
--   tonumber('0x10', 16)      nil      (no prefix either -- PUC's b_str2int
--                             only takes digits once a base is named)
--   tonumber('0b11', 2)       nil
--   tonumber('', 16) '  ', 2  nil
--   tonumber('11', 1)         bad argument #2 (base out of range)
--
-- The hex case is NOT a host limit anymore: the host's parse takes no "0x10",
-- so '0x10' + 0 raises, and that raise is what selects the fallback in
-- lib/tonumber_hex.lua -- which runs only on the coercion's failure and so
-- cannot disagree with it about any shape both accept.  The walk is a plain Lua loop -- a
-- piece is parsed Lua, not WireScript, so it has one -- over _s byte reads,
-- about 8 ticks a conversion on top of the failed pcall.  Integers never round
-- (short ones stay under 2^53; long ones are divided back by exact powers of
-- two with the count kept aside, so a thousand-digit numeral never overflows
-- midway).  Fractions keep their position exactly; only a 14th significant
-- digit is dropped, which is below one ulp of anything next to it.
--
-- Cost, measured: 1,832 escaped characters, and a program that NAMES tonumber
-- pays ~2,150 ticks of boot before its first instruction (the characters at the
-- code rate, plus the two functions) plus 70 ticks per call.
--
-- The hex fallback is NOT here any more: it is lib/tonumber_hex.lua, installed
-- as LIB_tonumber_hex and gated on the program's text containing 0x.  It used to
-- be 2,654 of this piece's 4,645 characters -- about 2,900 ticks that a program
-- calling only tonumber("42") could never reach.  That file carries the split
-- and the one shape it changes.  Only a program
-- that says "tonumber" pays either.  The per-call 70 is the pcall: PUC answers
-- nil where the coercion raises, and the only way to catch a raise is a
-- protected call.  Checking the string's shape first would be
-- cheaper per call and would be a SECOND copy of PUC's numeral rules to keep in
-- step with the coercion's -- the one thing this piece exists to avoid.
-- The conversion itself, as its own function, so the pcall below has something
-- to call that is not a fresh closure: a closure is filled one cell per tick, so
-- building one per call cost more than the parse.  Defined once, at load.
local function _tonum_conv(v)
  return v + 0
end

-- An EXPLICIT base, which is a different grammar rather than a wider one, so it
-- gets its own walk instead of a parameter on the hex one.  Measured
-- against PUC 5.5: spaces and a sign are allowed, and nothing else is.  No
-- 0x/0X, no 0b, no point, no exponent -- tonumber("0x10", 16) and
-- tonumber("1e3", 10) and tonumber("1.5", 16) are all nil, because once a base
-- is named PUC's b_str2int reads digits and stops at the first byte that is not
-- one of them.  That also fixes two answers the hex fallback used to give
-- through the base-10 path: tonumber("0x10", 10) was 16 and PUC says nil.
--
-- Ten significant digits is the window, and it is the same number for every
-- base because 36^10 is 3.66e15 and 2^53 is 9.0e15: the widest base still
-- accumulates ten digits exactly.  Past the window the value is scaled rather
-- than accumulated, so a thousand-digit numeral never overflows midway, and it
-- comes back a float -- the same 64-bit wall the rest of the chip is against,
-- and the same one PUC is past for a value that fits in its integer.
local function _tonum_int(s, base)
  local n = #s
  local i = 0
  local b = 0
  while i < n do
    b = _s(4, s, i, 0)
    if b ~= 32 and b ~= 9 and b ~= 10 and b ~= 13 and b ~= 12 and b ~= 11 then break end
    i = i + 1
  end
  local j = n - 1
  while j >= i do
    b = _s(4, s, j, 0)
    if b ~= 32 and b ~= 9 and b ~= 10 and b ~= 13 and b ~= 12 and b ~= 11 then break end
    j = j - 1
  end
  if i > j then return nil end
  local neg = false
  b = _s(4, s, i, 0)
  if b == 43 or b == 45 then
    neg = b == 45
    i = i + 1
  end
  local v = 0
  local nsig = 0
  local extra = 0
  local started = false
  local nd = 0
  while i <= j do
    b = _s(4, s, i, 0)
    local d = nil
    if b >= 48 and b <= 57 then d = b - 48 end
    if b >= 65 and b <= 90 then d = b - 55 end
    if b >= 97 and b <= 122 then d = b - 87 end
    if d == nil or d >= base then break end
    nd = nd + 1
    if d ~= 0 or started then
      started = true
      if nsig < 10 then
        v = v * base + d
        nsig = nsig + 1
      else
        extra = extra + 1
      end
    end
    i = i + 1
  end
  if nd == 0 or i <= j then return nil end
  -- Zero first: 0 times an overflowed power is 0, and 0 * inf would be nan.
  local m = v
  if v == 0 then
    m = 0
  elseif extra > 0 then
    m = v * (base ^ extra)
  end
  if neg then m = -m end
  -- PUC's int-or-float is by VALUE here, not by syntax (the syntax rule belongs
  -- to the no-base case, where a point or an exponent forces a float): a
  -- numeral that fits comes back an integer whatever the base.
  local iv = _m(13, m, 0)
  if iv ~= nil then return iv end
  return m
end

tonumber = function(...)
  -- A vararg signature because the argument COUNT is what separates
  -- tonumber() (an error) from tonumber(nil) (nil), and `...` is only readable
  -- in a variadic function -- PUC says the same.
  local n = select("#", ...)
  local v = select(1, ...)
  local base = select(2, ...)
  if n == 0 then
    error("bad argument #1 to 'tonumber' (value expected)", 2)
  end
  if base ~= nil then
    if type(v) ~= "string" then
      error("bad argument #1 to 'tonumber' (string expected, got " .. type(v) .. ")", 2)
    end
    if base < 2 or base > 36 then
      error("bad argument #2 to 'tonumber' (base out of range)", 2)
    end
    -- Every explicit base goes to the integer walk, base 10 included: PUC
    -- reads digits only once a base is named, so base 10 does NOT get the
    -- decimal path's points and exponents.
    return _tonum_int(v, base)
  end
  if type(v) == "number" then return v end
  if type(v) ~= "string" then return nil end
  local ok, r = pcall(_tonum_conv, v)
  if ok then return r end
  -- The hex walk is its own piece (lib/tonumber_hex.lua), loaded only when the
  -- PROGRAM's text contains 0x -- and this is the line that would call it, for
  -- EVERY string the coercion rejects, not just the hex ones.  So the loader's
  -- test is repeated here, on the string: only one that spells 0x can reach the
  -- walk, and _tonum_hex answers nil to everything else anyway, so one search
  -- buys the same answer.  Without it tonumber('x') is "attempt to call".
  --
  -- The shape that still differs is the one the split documents: a program that
  -- assembles "0x" at RUN time finds it here, calls, and finds no piece.
  if _pat(0, v, "0x", 1, 1) or _pat(0, v, "0X", 1, 1) then return _tonum_hex(v) end
  return nil
end
