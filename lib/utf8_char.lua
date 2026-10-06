-- utf8.char: one codepoint to bytes, over the _s(5, ...) gate.
--
-- Split from lib/utf8.lua, which is why it is here and not there: char needs
-- ONLY the encoder, while len/offset/codepoint need the decoder, and a program
-- that emits UTF-8 should not parse the decoder.  Measured like every split in
-- this repo (the piece is ~600 escaped characters against utf8's ~3.5KB).
-- Lua 5.5 accepts 0..0x7FFFFFFF and rejects above with "value out of range".
utf8 = utf8 or {}
local _lim = {0x80, 0x800, 0x10000, 0x200000, 0x4000000}
local _lead = {0, 0xC0, 0xE0, 0xF0, 0xF8, 0xFC}
utf8.char = function(...)
  local r = ""
  for i = 1, select('#', ...) do
    local v = select(i, ...)
    if v < 0 or v >= 0x80000000 then
      error("bad argument #1 to 'utf8.char' (value out of range)", 2)
    end
    if v < 0x80 then
      r = r .. _s(5, "", v, 0)
    else
      local n = 2
      while n < 6 and v >= _lim[n] do n = n + 1 end
      r = r .. _s(5, "", _lead[n] + (v >> (6 * (n - 1))), 0)
      for k = n - 2, 0, -1 do
        r = r .. _s(5, "", 0x80 + ((v >> (6 * k)) & 0x3F), 0)
      end
    end
  end
  return r
end
