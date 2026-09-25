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
--   tonumber('ff', 16)        255          NOT SUPPORTED, see below
--
-- The base form is 10 only.  Reading a base-b numeral is a walk over the digits,
-- and the only walk WireScript has is a hand-unrolled ladder, which would have
-- to be fixed-width and would then answer wrongly for a longer numeral -- the
-- identifier ladder's lesson.  An out-of-range base is PUC's own error, so that
-- much is exact; another base is loud rather than wrong.
--
-- The hex case is a host limit, not a choice: the host's parse is Rust's
-- FromStr, which takes no "0x10", so '0x10' + 0 raises as well.  PUC answers 16
-- there and the chip cannot.
--
-- Cost, measured: 760 escaped characters, and a program that NAMES tonumber
-- pays 565 ticks of boot before its first instruction (the characters are 190
-- of that at 4 chars a tick; the rest is parsing these 27 lines) plus 70 ticks
-- per call.  Both are in line with the other pieces (string.gsub is 696) and
-- only a program that says "tonumber" pays either.  The per-call 70 is the
-- pcall: PUC answers nil where the coercion raises, and the only way to catch a
-- raise is a protected call.  Checking the string's shape first would be
-- cheaper per call and would be a SECOND copy of PUC's numeral rules to keep in
-- step with the coercion's -- the one thing this piece exists to avoid.
-- The conversion itself, as its own function, so the pcall below has something
-- to call that is not a fresh closure: a closure is filled one cell per tick, so
-- building one per call cost more than the parse.  Defined once, at load.
local function _tonum_conv(v)
  return v + 0
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
  if not ok then return nil end
  return r
end
