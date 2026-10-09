-- tonumber, WITHOUT the explicit-base walk.
--
-- The base walk is lib/tonumber_base.lua, installed as LIB_tonumber_base and gated
-- on whether any `tonumber(` call in the program carries a comma.  It used to be
-- 1,300 characters of this piece's 1,870, paid by every program that says
-- "tonumber" to answer tonumber("42").
--
-- Cost, measured: a program that NAMES tonumber pays for these characters at the
-- code rate plus two functions, plus 70 ticks per call.
--
-- The hex fallback is NOT here: lib/tonumber_hex.lua, installed as
-- LIB_tonumber_hex and gated on the program's text, plus on the character after
-- `tonumber(` not being a quote -- a computed argument could be a hex string the
-- program never wrote down.  That gate and this file's are the two ends of the same
-- question, which is what separates a literal, a computed argument and an explicit
-- base.
--
-- The conversion is a question asked of the chip, not a protected call: PUC's
-- string-to-number coercion, answering nil when the string is not a numeral.
-- That was one pcall of a converter per call until catching left the chip
-- (see fid 18 in lua.ws), and it is now _m mode 15 -- the SAME coercion the
-- arithmetic path uses, so a second copy of PUC's numeral rules is still not
-- what this piece is.
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
  local r = _m(15, v, 0)
  if r ~= nil then return r end
  if _pat(0, v, "0x", 1, 1) or _pat(0, v, "0X", 1, 1) then return _tonum_hex(v) end
  return nil
end
