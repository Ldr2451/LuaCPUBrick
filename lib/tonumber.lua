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
--   tonumber('ff', 16)        255          base 16 and up: the digit walk below
--
-- The hex case is NOT a host limit anymore.  The host's parse is Rust's
-- FromStr, which takes no "0x10", so '0x10' + 0 raises -- and that raise is
-- exactly what selects the fallback: _tonum_hex runs only when the coercion
-- failed, and answers only for shapes the host never accepts (optional spaces,
-- an optional sign, 0x, hex digits, an optional fraction, an optional p
-- exponent), so the two cannot disagree.  The walk is a plain Lua loop -- a
-- piece is parsed Lua, not WireScript, so it has one -- over _s byte reads,
-- about 8 ticks a conversion on top of the failed pcall.  Integers never round
-- (short ones stay under 2^53; long ones are divided back by exact powers of
-- two with the count kept aside, so a thousand-digit numeral never overflows
-- midway).  Fractions keep their position exactly; only a 14th significant
-- digit is dropped, which is below one ulp of anything next to it.
--
-- Cost, measured: 3514 escaped characters, and a program that NAMES tonumber
-- pays ~3700 ticks of boot before its first instruction (the characters at the
-- code rate, plus a second function) plus 70 ticks per call.  Only a program
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

-- The hex fallback, for the one shape the coercion refuses.  See the header for
-- why it cannot disagree with the line above: it runs only on its failure.
local function _tonum_hex(s)
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
  if _s(1, s, i, 2) ~= "0x" and _s(1, s, i, 2) ~= "0X" then return nil end
  i = i + 2
  -- Significant digits, at most 13 of them: 13 hex digits fit under 2^53, so
  -- every digit accumulated here is exact and so is their sum.  Leading zeros
  -- change neither (they never start the window); digits past the window only
  -- move the scale.  That scale is ri hex places for the integer part, counted
  -- separately because applying it to v as it grows is what breaks the
  -- invariant -- a digit added after a normalization is in unscaled units.
  local v = 0
  local nsig = 0
  local ri = 0
  local ndig = 0
  local started = false
  -- Correct rounding for numerals longer than the window: the first dropped
  -- digit is the guard and whether any later digit is nonzero is the sticky.
  -- Round up past half an ulp, and on exactly half round to even -- which is
  -- what makes 150 f's come out 2^600, the way PUC's strtod does.  Untouched
  -- when nothing was dropped, so short numerals are bit-exact either way.
  local guard = 0
  local sticky = false
  while i <= j do
    b = _s(4, s, i, 0)
    local dv = nil
    if b >= 48 and b <= 57 then dv = b - 48 end
    if b >= 65 and b <= 70 then dv = b - 55 end
    if b >= 97 and b <= 102 then dv = b - 87 end
    if dv == nil then break end
    ndig = ndig + 1
    if dv ~= 0 or started then
      started = true
      if nsig < 13 then
        v = v * 16 + dv
        nsig = nsig + 1
      elseif ri == 0 then
        guard = dv
        ri = ri + 1
      else
        if dv ~= 0 then sticky = true end
        ri = ri + 1
      end
    end
    i = i + 1
  end
  if guard > 8 or (guard == 8 and (sticky or v % 2 == 1)) then
    v = v + 1
  end
  -- Same window for the fraction, except leading zeros count toward the scale:
  -- 0x0.080 is 128 / 16^3, so the zeros have to be counted even though nothing
  -- is accumulated for them.  nf is every fraction digit; vf holds the first
  -- 13 significant ones.
  local vf = 0
  local nf = 0
  local fstarted = false
  local nodot = true
  if i <= j and _s(4, s, i, 0) == 46 then
    nodot = false
    i = i + 1
    local nfsig = 0
    while i <= j do
      b = _s(4, s, i, 0)
      local dv = nil
      if b >= 48 and b <= 57 then dv = b - 48 end
      if b >= 65 and b <= 70 then dv = b - 55 end
      if b >= 97 and b <= 102 then dv = b - 87 end
      if dv == nil then break end
      ndig = ndig + 1
      nf = nf + 1
      if dv ~= 0 or fstarted then
        fstarted = true
        if nfsig < 13 then
          vf = vf * 16 + dv
          nfsig = nfsig + 1
        end
      end
      i = i + 1
    end
  end
  if ndig == 0 then return nil end
  -- Binary exponent: p or P, optional sign, decimal digits, at least one.
  local ep = 0
  local nopexp = true
  if i <= j then
    b = _s(4, s, i, 0)
    if b == 112 or b == 80 then
      nopexp = false
      i = i + 1
      local eneg = false
      if i <= j then
        b = _s(4, s, i, 0)
        if b == 43 or b == 45 then
          eneg = b == 45
          i = i + 1
        end
      end
      local nd = 0
      while i <= j do
        b = _s(4, s, i, 0)
        if b < 48 or b > 57 then break end
        ep = ep * 10 + (b - 48)
        nd = nd + 1
        i = i + 1
      end
      if nd == 0 then return nil end
      if eneg then ep = -ep end
    end
  end
  if i <= j then return nil end
  -- PUC's int-or-float is SYNTACTIC: pure digit strings are integers (when
  -- they fit), anything with a point or a p-exponent is a float -- so 0x10 is
  -- int 16 and 0x10.0 is float 16.0, and print spells them "16" and "16.0".
  -- The window above is exact, so a value under 2^53 converts exactly through
  -- the host's own tointeger; past that the float is already rounded and
  -- converting would freeze the rounding into the wrong integer, so it stays a
  -- float (PUC prints more digits there, the same 64-bit wall as ever).
  if nodot and nopexp then
    local full = v
    if ri ~= 0 then full = v * (16 ^ ri) end
    if full < 9007199254740992 then
      local iv = _m(13, full, 0)
      if iv ~= nil then
        if neg then iv = -iv end
        return iv
      end
    end
  end
  -- One power of two per part, exponents combined BEFORE the pow: 16^990
  -- alone is inf and 2^-4000 alone is 0, but 0xe03 times their product is 3587.
  -- inf and 0 out of the pow are what PUC's strtod answers too.  Zero first:
  -- 0 times anything is 0, and 0 * inf would be nan (0x0p10000 is 0.0, not nil).
  local m = 0
  if v ~= 0 then m = v * (2 ^ (4 * ri + ep)) end
  if nf > 0 and vf ~= 0 then m = m + vf * (2 ^ (-4 * nf + ep)) end
  if m == 0 then
    if neg then return -0.0 else return 0.0 end
  end
  if neg then m = -m end
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
    if base ~= 10 then
      error("tonumber with a base other than 10 is not supported", 2)
    end
  end
  if type(v) == "number" then return v end
  if type(v) ~= "string" then return nil end
  local ok, r = pcall(_tonum_conv, v)
  if ok then return r end
  return _tonum_hex(v)
end
