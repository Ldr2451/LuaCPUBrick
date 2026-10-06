-- string.pack/packsize/unpack for INTEGER formats and strings.
--
-- REFERENCE ONLY -- NOT INSTALLED.  At 9,317 escaped characters this cannot
-- load (2.5x the ~4KB source buffer), and it is mostly format parser, which
-- any split would duplicate.  Kept the way lib/str_format.lua and lib/gmatch.lua
-- are: the semantics are all verified (every line read off lua55), so when a
-- host primitive or a bigger buffer makes this shippable, the transcription
-- is already proved.  Install with tools/lib/libconst.py ONLY after proving
-- it fits; constcheck will say otherwise.
--
-- PUC's tpack.lua is the spec, and every semantic below was read off lua55:
-- `i`/`l` default to 4 bytes HERE (Windows x64); B/b/H/h/L/l/J/j/T take NO size;
-- c REQUIRES one; s/z take none; i/I sizes live in [1,16] ("integral size (N)
-- out of limits [1,16]") and must be powers of 2; `!n` needs [1,16] and power
-- of 2; `!option` validates the option and resets to native 8; X takes only
-- fixed-size numerics and touches its option; spaces part units; endianness
-- never aligns, only orders bytes.
--
-- Alignment, decoded by probing: NOTHING pads without `!`, and after it every
-- item self-aligns to min(natural, maxalign) while Xop pads to min(op, maxalign)
-- -- consuming no value and writing nothing either way.
--
-- The error SUBSTRINGS are asserted (checkerror is string.find).  Floats (f/d/n)
-- are REFUSED: IEEE754 assembly is a second piece, and a clean error SKIPs
-- those asserts rather than DIFFing them.  j/J/T are 8 bytes with natural
-- double semantics -- the int64 wall, not a pack bug.  Unpack past 8 bytes
-- checks the high bytes exactly (all-0 unsigned, sign-extension signed) and
-- says "N-byte integer does not fit into Lua Integer" -- one message shape for
-- lines 89, 90 and 129, which look like three rules and are one.
--
-- Bytes go through _s(4, ...)/_s(5, ...) via mod-progression (`t % 256`, never
-- `v + 2^bits`, which is inf past 64 bits), and results build with
-- concatenation.  No other piece is needed.  Never index a table constructor
-- directly -- `({b = 1})["b"]` hangs the chip -- so sizes live in a named local.
string = string or {}
local _sz = {b = 1, B = 1, h = 2, H = 2, l = 4, L = 4, i = 4, I = 4, j = 8,
             J = 8, T = 8}
local function intbytes(v, size, signed, little, argn)
  local bits = 8 * size
  if signed then
    local half = 2 ^ (bits - 1)
    if v < -half or v > half - 1 then
      error("bad argument #" .. argn .. " to 'string.pack' "
            .. "(integer overflow)", 3)
    end
  else
    if v < 0 or v > 2 ^ bits - 1 then
      error("bad argument #" .. argn .. " to 'string.pack' "
            .. "(unsigned overflow)", 3)
    end
  end
  -- low to high by mod-progression: exact for |v| < 2^53 at every step, and no
  -- 2^bits anywhere, so a 16-byte write of a small value cannot inf.  Negative
  -- v yields two's complement bytes directly because the chip's % floors.
  local bs = {}
  local t = v
  for _ = 1, size do
    local byte = t % 256
    bs[#bs + 1] = byte
    t = (t - byte) / 256
  end
  local r = ""
  if little then
    for k = 1, size do r = r .. _s(5, "", bs[k], 0) end
  else
    for k = size, 1, -1 do r = r .. _s(5, "", bs[k], 0) end
  end
  return r
end
local function intread(s, p, size, signed, little)
  if p < 1 or p + size - 1 > #s then
    error("bad argument #2 to 'string.unpack' (data string too short)", 3)
  end
  -- nextpos counts the WHOLE unit, so it is fixed before size is truncated
  -- below for the 8-byte read.
  local nextp = p + size
  local hisign = nil
  if size > 8 then
    -- the high bytes decide exactly (byte comparisons, always right); the low
    -- 8 ride doubles and round past 2^53, which is the wall.  lobase is where
    -- those low 8 live: the start for little-endian, the end minus 8 for big.
    local lobase = p
    local hi0, hi1 = p + 8, p + size - 1
    local msb = p + size - 1
    if not little then
      lobase = p + size - 8
      hi0, hi1 = p, p + size - 9
      msb = p
    end
    local ref = _s(4, s, msb - 1, 0)
    for k = hi0, hi1 do
      local b = _s(4, s, k - 1, 0)
      if signed then
        local want = 0
        if ref >= 0x80 then want = 0xFF end
        if b ~= want then
          error("bad argument #1 to 'string.unpack' (" .. size
                .. "-byte integer does not fit into Lua Integer)", 3)
        end
      elseif b ~= 0 then
        error("bad argument #1 to 'string.unpack' (" .. size
              .. "-byte integer does not fit into Lua Integer)", 3)
      end
    end
    if signed and ref < 0x80 then hisign = 0 end
    p, size = lobase, 8
  end
  local v = 0
  if little then
    for k = size - 1, 0, -1 do
      v = v * 256 + _s(4, s, p + k - 1, 0)
    end
  else
    for k = 0, size - 1 do
      v = v * 256 + _s(4, s, p + k - 1, 0)
    end
  end
  if signed then
    if hisign == 0 and v >= 2 ^ 63 then
      -- wide positive past maxinteger: the high was all zero, so this is a
      -- genuine positive that fits no Lua integer -- not a wrap.
      error("bad argument #1 to 'string.unpack' (does not fit)", 3)
    end
    local half = 2 ^ (8 * size - 1)
    if v >= half then v = v - 2 * half end
  elseif v >= 2 ^ 63 then
    -- unsigned patterns that reach bit 63 wrap to signed: J max is -1, and an
    -- I9 with zero high and 2^63 low is mininteger.  Probed, not assumed.
    v = v - 2 ^ 64
  end
  return v, nextp
end
-- digits at fmt[q:]: (value, nextq).  Refuses a count the chip cannot hold as
-- an exact total -- c1 followed by 40 zeros is "invalid format" -- while
-- c{maxsize-9} (near 2^63) still parses, because the TOTALS past it are what
-- "too large"/"too long" refuse, not the spelling.
local function digits(fmt, q)
  local n, r = 0, q
  while fmt:sub(r, r):match("%d") do
    n = n * 10 + (fmt:sub(r, r) - 0)
    if n >= 2 ^ 64 then
      error("bad argument #1 to 'string.pack' (invalid format)", 4)
    end
    r = r + 1
  end
  return n, r
end
local function ispow2(n)
  return n == 1 or n == 2 or n == 4 or n == 8 or n == 16
end
-- one format unit at fmt[pos]: (kind, size, newpos, extra).  kind is int, c,
-- s, z, x, X, float (refused) or end.  Spaces part units; X must touch its
-- option ("X i" is invalid, as is Xc1 -- X takes only fixed-size numerics).
-- Fixed-size codes take NO size ("invalid format option '2'"); c REQUIRES one
-- ("missing size"); i/I take 1-16 powers of 2.
local function unit(fmt, pos, what)
  while fmt:sub(pos, pos) == " " do pos = pos + 1 end
  local c = fmt:sub(pos, pos)
  if c == "" then return "end", 0, pos end
  if c == "X" then
    local d = fmt:sub(pos + 1, pos + 1)
    local sz = _sz[d]
    if sz == nil then
      if d == "f" then sz = 4 elseif d == "d" or d == "n" then sz = 8 end
    end
    if sz == nil then
      error("bad argument #1 to '" .. what .. "' (invalid next option)", 3)
    end
    return "X", sz, pos + 2
  end
  if c == "x" then return "x", 1, pos + 1 end
  if c == "c" or c == "s" or c == "z" then
    local n, q = digits(fmt, pos + 1)
    if c == "c" and q == pos + 1 then
      error("bad argument #1 to '" .. what .. "' (missing size for format "
            .. "option 'c')", 3)
    end
    return c, n, q
  end
  if c == "i" or c == "I" then
    local n, q = digits(fmt, pos + 1)
    if q == pos + 1 then n = 4 end
    if n < 1 or n > 16 then
      error("bad argument #1 to '" .. what .. "' (integral size (" .. n
            .. ") out of limits [1,16])", 3)
    end
    if not ispow2(n) then
      error("bad argument #1 to '" .. what .. "' (integral size (" .. n
            .. ") not power of 2)", 3)
    end
    return "int", n, q, c == "i"
  end
  if _sz[c] then return "int", _sz[c], pos + 1, c == c:lower() end
  if c == "f" or c == "d" or c == "n" then
    error("bad argument #1 to '" .. what .. "' (float formats not "
          .. "supported)", 3)
  end
  error("bad argument #1 to '" .. what .. "' (invalid format option '"
        .. c .. "')", 3)
end
-- pad the string to a multiple of `to`, counting from zero: under `!` every
-- item self-aligns and X pads, and without it both are no-ops (maxalign 1).
-- A loop, not string.rep: this piece calls no other piece.
local function pad(r, to)
  while #r % to ~= 0 do r = r .. "\0" end
  return r
end
-- `!` at fmt[pos]: (maxalign, newpos).  Digits set it outright ([1,16] and a
-- power of 2); an option letter validates (sizes required) and resets to
-- native 8.  Probed, not assumed -- `!h` is 8, `!1` is 1, `!c` needs a size.
-- unit() is reached THROUGH here, so its level-3 errors would point at pack
-- rather than the user; pcall re-raises position-free (checkerror is substring
-- matching, so the position prefix is load-bearing for nobody).
local function bang(fmt, pos, what)
  local c = fmt:sub(pos, pos)
  if c:match("%d") then
    local n, q = digits(fmt, pos)
    if n < 1 or n > 16 then
      error("bad argument #1 to '" .. what .. "' (integral size (" .. n
            .. ") out of limits [1,16])", 3)
    end
    if not ispow2(n) then
      error("bad argument #1 to '" .. what .. "' (format asks for "
            .. "alignment not power of 2)", 3)
    end
    return n, q
  end
  local ok, kind, size, q = pcall(unit, fmt, pos, what)
  if not ok then error(kind, 0) end
  if kind == "end" or kind == "float" or kind == "s" or kind == "z" then
    error("bad argument #1 to '" .. what .. "' (invalid next option)", 3)
  end
  return 8, q
end
local function alignto(natural, maxalign)
  if natural > maxalign then return maxalign end
  return natural
end
string.packsize = function(fmt)
  local little, maxalign, pos, total = true, 1, 1, 0
  while true do
    while fmt:sub(pos, pos) == " " do pos = pos + 1 end
    local c = fmt:sub(pos, pos)
    if c == "" then break end
    if c == "<" then little, pos = true, pos + 1
    elseif c == ">" then little, pos = false, pos + 1
    elseif c == "=" then little, pos = true, pos + 1
    elseif c == "!" then maxalign, pos = bang(fmt, pos + 1, "string.packsize")
    else
      local kind, size, q = unit(fmt, pos, "string.packsize")
      pos = q
      if kind == "end" then break end
      if kind == "s" or kind == "z" then
        error("bad argument #1 to 'string.packsize' (variable-length "
              .. "format)", 2)
      end
      if kind == "X" then
        -- X pads but packs nothing: align the RUNNING total, not a string
        local m = total % alignto(size, maxalign)
        if m ~= 0 then total = total + alignto(size, maxalign) - m end
      elseif kind == "x" then
        total = total + 1
      elseif kind == "c" then
        total = total + size
      else
        local m = total % alignto(size, maxalign)
        if m ~= 0 then total = total + alignto(size, maxalign) - m end
        total = total + size
      end
      if total >= 2 ^ 63 then
        error("bad argument #1 to 'string.packsize' (too large)", 2)
      end
    end
  end
  return total
end
string.pack = function(fmt, ...)
  local little, maxalign, pos = true, 1, 1
  local r, ai = "", 1
  -- "too long" is pre-checked, because building gigabytes to discover it is
  -- not a check: line 143's shape is 10 x's and a c{maxsize-9}.
  local function need(n)
    if #r + n >= 2 ^ 63 then
      error("bad argument #1 to 'string.pack' (too long)", 3)
    end
  end
  while true do
    while fmt:sub(pos, pos) == " " do pos = pos + 1 end
    local c = fmt:sub(pos, pos)
    if c == "" then break end
    if c == "<" then little, pos = true, pos + 1
    elseif c == ">" then little, pos = false, pos + 1
    elseif c == "=" then little, pos = true, pos + 1
    elseif c == "!" then maxalign, pos = bang(fmt, pos + 1, "string.pack")
    else
      local kind, size, q, extra = unit(fmt, pos, "string.pack")
      pos = q
      if kind == "end" then break end
      if kind == "X" then
        r = pad(r, alignto(size, maxalign))
      elseif kind == "x" then
        need(1)
        r = r .. "\0"
      elseif kind == "c" then
        local v = select(ai, ...)
        if type(v) ~= "string" then
          error("bad argument #" .. (ai + 1) .. " to 'string.pack' "
                .. "(string expected)", 2)
        end
        if #v > size then
          error("bad argument #" .. (ai + 1) .. " to 'string.pack' "
                .. "(string longer than given size)", 2)
        end
        need(size)
        r = r .. v
        for _ = #v + 1, size do r = r .. "\0" end
        ai = ai + 1
      elseif kind == "s" then
        local v = select(ai, ...)
        if type(v) ~= "string" then
          error("bad argument #" .. (ai + 1) .. " to 'string.pack' "
                .. "(string expected)", 2)
        end
        need(8 + #v)
        r = r .. intbytes(#v, 8, false, little, ai + 1) .. v
        ai = ai + 1
      elseif kind == "z" then
        local v = select(ai, ...)
        if type(v) ~= "string" then
          error("bad argument #" .. (ai + 1) .. " to 'string.pack' "
                .. "(string expected)", 2)
        end
        need(#v + 1)
        r = r .. v .. "\0"
        ai = ai + 1
      else
        r = pad(r, alignto(size, maxalign))
        local v = select(ai, ...)
        if v == nil then
          error("bad argument #" .. (ai + 1) .. " to 'string.pack' "
                .. "(value expected)", 2)
        end
        if type(v) == "string" then v = v + 0 end
        need(size)
        r = r .. intbytes(v, size, extra, little, ai + 1)
        ai = ai + 1
      end
    end
  end
  return r
end
string.unpack = function(fmt, s, p)
  p = p or 1
  local little, maxalign, pos = true, 1, 1
  local r, n = {}, 0
  while true do
    while fmt:sub(pos, pos) == " " do pos = pos + 1 end
    local c = fmt:sub(pos, pos)
    if c == "" then break end
    if c == "<" then little, pos = true, pos + 1
    elseif c == ">" then little, pos = false, pos + 1
    elseif c == "=" then little, pos = true, pos + 1
    elseif c == "!" then maxalign, pos = bang(fmt, pos + 1, "string.unpack")
    else
      local kind, size, q, extra = unit(fmt, pos, "string.unpack")
      pos = q
      if kind == "end" then break end
      if kind == "X" then
        local to = alignto(size, maxalign)
        while p % to ~= 1 and to > 1 do p = p + 1 end
      elseif kind == "x" then
        if p < 1 or p > #s then
          error("bad argument #2 to 'string.unpack' (data string too short)",
                2)
        end
        p = p + 1
      elseif kind == "c" then
        if p < 1 or p + size - 1 > #s then
          error("bad argument #2 to 'string.unpack' (data string too short)",
                2)
        end
        n = n + 1
        r[n] = s:sub(p, p + size - 1)
        p = p + size
      elseif kind == "s" then
        local len, q2 = intread(s, p, 8, false, little)
        if q2 + len - 1 > #s then
          error("bad argument #2 to 'string.unpack' (data string too short)",
                2)
        end
        n = n + 1
        r[n] = s:sub(q2, q2 + len - 1)
        p = q2 + len
      elseif kind == "z" then
        local q2 = p
        while q2 <= #s and s:sub(q2, q2) ~= "\0" do q2 = q2 + 1 end
        if q2 > #s then
          error("bad argument #2 to 'string.unpack' (unfinished string for "
                .. "format 'z')", 2)
        end
        n = n + 1
        r[n] = s:sub(p, q2 - 1)
        p = q2 + 1
      else
        local to = alignto(size, maxalign)
        while p % to ~= 1 and to > 1 do p = p + 1 end
        local v, q2 = intread(s, p, size, extra, little)
        n = n + 1
        r[n] = v
        p = q2
      end
    end
  end
  r[n + 1] = p
  return unpack(r, 1, n + 1)
end


