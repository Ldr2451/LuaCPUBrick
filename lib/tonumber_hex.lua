-- tonumber's hex fallback: the ONE shape the host's coercion refuses.
--
-- Split out of lib/tonumber.lua, and this file is the master for
-- LIB_tonumber_hex.  The reason is size, and size is boot: a piece is charged
-- for its CHARACTERS (the lexer and parser walk every one of them before the
-- program runs an instruction), so a program that only ever calls
-- tonumber("42") was paying ~2,700 characters -- about 2,900 ticks, 48 seconds
-- at 60 ticks/s -- for a code path it cannot reach.
--
-- The split is safe because the piece is only ever REACHED through a numeral
-- that spells itself in hex, which means the program has "0x" or "0X" in its
-- text: a hex literal the lexer handles, or a hex string it hands to
-- tonumber.  libTonumberHex gates on exactly that.  The one shape that changes
-- is a program that builds the "0x" at RUN time out of pieces
-- (tonumber("0" .. "xff")); it now raises "attempt to call a nil value"
-- instead of answering a number.  That is loud rather than wrong, which is the
-- bargain the repo already makes for a piece the loader does not install, and
-- the alternative -- always paying 2,900 ticks -- is the thing being fixed.
--
-- Everything below is the walk itself and is unchanged by the split: optional
-- spaces, an optional sign, 0x, hex digits, an optional fraction, an optional
-- p exponent.  It runs only on the coercion's FAILURE, so it and the coercion
-- cannot disagree about any shape both of them accept.
--
-- Cost, measured: 2,654 escaped characters, paid only by a program whose text
-- contains 0x.  See lib/tonumber.lua for the rest, and for the per-call 70
-- ticks (the pcall that turns the coercion's raise into PUC's nil).
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