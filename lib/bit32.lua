-- bit32, PUC 5.5's own reference implementation, minus the `require`.
--
-- PUC's bitwise.lua test file carries this library INSIDE ITSELF
-- (`package.preload.bit32`, "no built-in 'bit32' library: implement it using
-- bitwise operators"), because Lua 5.5 removed bit32 in favour of the
-- operators.  The chip HAS those operators, so this piece is a transcription of
-- that reference with the `require` wrapper taken off: `bit32` is a table, not
-- a module to load, because the chip has no `require` and no `package`.
--
-- The two-argument fast path in band/bor/bxor is PUC's own, not an
-- optimization added here: "avoid creating 'arg' table when there are only 2
-- (or less) parameters, as 2 parameters is the common case".
--
-- Everything here is exact inside 32 bits, which a double holds: 2^32 needs 33
-- mantissa bits and a double has 53.  The one place that matters is lrotate's
-- `a >> (32 - b)` with b == 0, which shifts by the full 32 -- and the chip's
-- `>>` answers that, because it is a scale by 2^32 and not a register move.
--
-- The other place is `<<` itself: past 2^53 the float rounds and the low word
-- comes back wrong (`(0xaaaaaaaa << 30) & mask` read 0x7FFFFFFF), so lshift
-- splits at bit 16 -- the high half shifts out past bit 32 anyway -- and
-- lrotate goes through lshift.  Counts of 32 or more (either sign) are 0,
-- which is what the operators saturate to; the chip's own `<<`/`>>` reverse
-- on a negative count, so the in-range negatives need no arm of their own.
bit32 = bit32 or {}
bit32.bnot = function(a) return ~a & 0xFFFFFFFF end
bit32.band = function(x, y, z, ...)
  if not z then
    return ((x or -1) & (y or -1)) & 0xFFFFFFFF
  else
    local arg = {...}
    local res = x & y & z
    for i = 1, #arg do res = res & arg[i] end
    return res & 0xFFFFFFFF
  end
end
bit32.bor = function(x, y, z, ...)
  if not z then
    return ((x or 0) | (y or 0)) & 0xFFFFFFFF
  else
    local arg = {...}
    local res = x | y | z
    for i = 1, #arg do res = res | arg[i] end
    return res & 0xFFFFFFFF
  end
end
bit32.bxor = function(x, y, z, ...)
  if not z then
    return ((x or 0) ~ (y or 0)) & 0xFFFFFFFF
  else
    local arg = {...}
    local res = x ~ y ~ z
    for i = 1, #arg do res = res ~ arg[i] end
    return res & 0xFFFFFFFF
  end
end
bit32.btest = function(...) return bit32.band(...) ~= 0 end
bit32.lshift = function(a, b)
  if b * b >= 1024 then return 0 end
  a = a & 0xFFFFFFFF
  if b < 16 then return (a << b) & 0xFFFFFFFF end
  return ((a % 65536) << b) & 0xFFFFFFFF
end
bit32.rshift = function(a, b)
  if b * b >= 1024 then return 0 end
  return ((a & 0xFFFFFFFF) >> b) & 0xFFFFFFFF
end
bit32.arshift = function(a, b)
  a = a & 0xFFFFFFFF
  if b <= 0 or (a & 0x80000000) == 0 then
    return (a >> b) & 0xFFFFFFFF
  else
    return ((a >> b) | ~(0xFFFFFFFF >> b)) & 0xFFFFFFFF
  end
end
bit32.lrotate = function(a, b)
  b = b & 31
  a = a & 0xFFFFFFFF
  a = bit32.lshift(a, b) | (a >> (32 - b))
  return a & 0xFFFFFFFF
end
bit32.rrotate = function(a, b) return bit32.lrotate(a, -b) end
local function checkfield(f, w)
  w = w or 1
  assert(f >= 0, "field cannot be negative")
  assert(w > 0, "width must be positive")
  assert(f + w <= 32, "trying to access non-existent bits")
  return f, ~(-1 << w)
end
bit32.extract = function(a, f, w)
  local f, mask = checkfield(f, w)
  return (a >> f) & mask
end
bit32.replace = function(a, v, f, w)
  local f, mask = checkfield(f, w)
  v = v & mask
  a = (a & ~(mask << f)) | (v << f)
  return a & 0xFFFFFFFF
end
