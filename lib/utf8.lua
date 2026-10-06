-- utf8.len/offset/codepoint over the _s(4, ...) gate and bare `unpack`.
--
-- utf8.char is NOT here: it needs only the encoder and lives in
-- lib/utf8_char.lua, so a program that emits UTF-8 does not parse the decoder.
-- What remains shares ONE decoder, which is why these three are one piece and
-- not three: splitting them would duplicate dec in each.
--
-- Like lib/utf8_char.lua this calls NO other piece: `_s(4, s, i - 1, 0)` is
-- the byte at 0-based i, and bare `unpack` is a chip global.  A piece that
-- needs another piece does not pay, because the loader only installs what the
-- program's own text names.
--
-- Strict codepoint rejects surrogates and anything above 0x10FFFF ("invalid
-- UTF-8 code"); lax accepts to 0x7FFFFFFF.  Overlongs ALWAYS fail, lax or not.
-- The bounds are the contract: len/codepoint ERROR when i/j leave [1, #s+1] /
-- [0, #s], offset ERRORS when its position leaves [1, #s+1] but answers nil
-- when the walk runs off either end, and offset returns TWO values -- 5.5
-- widened it.  Every bound read off lua55, not the manual.
utf8 = utf8 or {}
local _floor = {0, 0x80, 0x800, 0x10000, 0x200000, 0x4000000}
local function dec(s, i, lax)
  local c = _s(4, s, i - 1, 0)
  if c == nil then return nil end
  if c < 0x80 then return c, 1 end
  local n, v
  if c < 0xC2 then return nil end
  if c < 0xE0 then n, v = 2, c & 0x1F
  elseif c < 0xF0 then n, v = 3, c & 0x0F
  elseif c < 0xF8 then n, v = 4, c & 0x07
  elseif c < 0xFC then n, v = 5, c & 0x03
  elseif c < 0xFE then n, v = 6, c & 0x01
  else return nil end
  for k = 1, n - 1 do
    local d = _s(4, s, i + k - 1, 0)
    if d == nil or d < 0x80 or d > 0xBF then return nil end
    v = v * 64 + (d & 0x3F)
  end
  if v < _floor[n] then return nil end
  if lax then
    if v >= 0x80000000 then return nil end
  elseif v > 0x10FFFF or (v >= 0xD800 and v <= 0xDFFF) then
    return nil
  end
  return v, n
end
-- step back over continuations from k: the start of the character at or before
-- k.  Bytes 0xC0/0xC1 are never continuations, so the walk stops at them and
-- dec refuses them after.
local function back(s, k)
  while k > 1 do
    local c = _s(4, s, k - 1, 0)
    if c == nil or c < 0x80 or c >= 0xC0 then break end
    k = k - 1
  end
  return k
end
-- one position argument, converted and checked: every function takes it, and
-- two copies of the check is one waiting to disagree.
local function pos(s, i, what)
  local len = #s
  if i == nil then return nil end
  if i < 0 then i = len + i + 1 end
  if i < 1 or i > len + 1 then
    error("bad argument #3 to '" .. what .. "' (position out of bounds)", 3)
  end
  return i, len
end
utf8.len = function(s, i, j, lax)
  local n = #s
  i = i or 1
  j = j or n
  if i < 0 then i = n + i + 1 end
  if j < 0 then j = n + j + 1 end
  if i < 1 or i > n + 1 then
    error("bad argument #2 to 'utf8.len' (initial position out of bounds)", 2)
  end
  if j < 0 or j > n then
    error("bad argument #3 to 'utf8.len' (final position out of bounds)", 2)
  end
  local k, r = i, 0
  while k <= j do
    local _, w = dec(s, k, lax)
    if w == nil then return nil, k end
    k, r = k + w, r + 1
  end
  return r
end
utf8.offset = function(s, n, i)
  local len = #s
  if n == 0 then
    i, len = pos(s, i or 1, "utf8.offset")
    i = back(s, i)
    local _, w = dec(s, i, true)
    if w == nil then return nil end
    return i, i + w - 1
  end
  if n > 0 then
    i, len = pos(s, i or 1, "utf8.offset")
    local k, w = i, 1
    for j = 1, n do
      if k > len + 1 then return nil end
      if k == len + 1 then
        -- one past the end is a position, but only as the FINAL step: landing
        -- here mid-walk means more characters were asked for than exist, which
        -- is why offset("alo", 5) is nil and offset("abc", 4) is (4, 4).
        if j == n then return k, k end
        return nil
      end
      local _, w2 = dec(s, k, true)
      if w2 == nil then return nil end
      k, w = k + w2, w2
    end
    return k - w, k - 1
  end
  i, len = pos(s, i or len + 1, "utf8.offset")
  local k, w = i, 1
  for _ = 1, -n do
    if k <= 1 then return nil end
    k = back(s, k - 1)
    local _, w2 = dec(s, k, true)
    if w2 == nil then return nil end
    w = w2
  end
  return k, k + w - 1
end
utf8.codepoint = function(s, i, j, lax)
  local n = #s
  i = i or 1
  j = j or i
  if i < 0 then i = n + i + 1 end
  if j < 0 then j = n + j + 1 end
  if i < 1 or i > n + 1 then
    error("bad argument #2 to 'utf8.codepoint' (out of bounds)", 2)
  end
  if j > n then
    error("bad argument #3 to 'utf8.codepoint' (out of bounds)", 2)
  end
  if j < i then return end
  local r = {}
  local k = i
  while k <= j do
    local v, w = dec(s, k, lax)
    if w == nil then error("invalid UTF-8 code", 2) end
    r[#r + 1] = v
    k = k + w
  end
  return unpack(r, 1, #r)
end
