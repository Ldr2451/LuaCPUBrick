-- An EXPLICIT base for tonumber: the walk, and nothing else.
--
-- This was the body of LIB_tonumber, which is 1,870 characters, and a program that
-- says `tonumber("42")` paid for every line of it to answer 42.  Only a call with a
-- SECOND argument reaches _tonum_int, so the walk is its own piece and the gate asks
-- the only question that separates the two shapes: does any `tonumber(` call carry a
-- comma?  Measured on this piece, that is 1,300 characters and about 1,950 ticks that
-- the common call cannot reach -- the same trade lib/tonumber_hex.lua made, and for
-- the same reason.
--
-- AN EXPLICIT BASE IS A DIFFERENT GRAMMAR rather than a wider one, which is why it
-- gets its own walk instead of a parameter on the hex one.  Measured against PUC 5.5:
-- spaces and a sign are allowed, and nothing else is.  No 0x/0X, no 0b, no point, no
-- exponent -- tonumber("0x10", 16) and tonumber("1e3", 10) and tonumber("1.5", 16) are
-- all nil, because once a base is named PUC's b_str2int reads digits and stops at the
-- first byte that is not one of them.  That also fixes two answers the hex fallback
-- used to give through the base-10 path: tonumber("0x10", 10) was 16 and PUC says nil.
--
-- Ten significant digits is the window, and it is the same number for every base
-- because 36^10 is 3.66e15 and 2^53 is 9.0e15: the widest base still accumulates ten
-- digits exactly.  Past the window the value is scaled rather than accumulated, so a
-- thousand-digit numeral never overflows midway, and it comes back a float -- the same
-- 64-bit wall the rest of the chip is against, and the same one PUC is past for a
-- value that fits in its integer.
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
  local iv = _m(13, m, 0)
  if iv ~= nil then return iv end
  return m
end
