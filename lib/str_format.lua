-- string.format, the PUC-verified Lua implementation.
--
-- This is the reference, not the shipped path.  443 lines of Lua is 10769
-- characters, and the chip lexes 4 characters per tick, so prepending it cost
-- 9.4s of sim time per program (~45s in-game) -- 20x over the few hundred
-- characters a prepended library piece can afford.  The gate version is being
-- built from this: the semantics below are settled (107 of 108 cases match PUC
-- Lua 5.5 byte for byte; the one exception is noted at the bottom), so it stays
-- as the specification the gate has to reproduce.
--
-- Only _s and _m are used, so this text is self-contained: it does not need the
-- string or math pieces to have been prepended too.  It also stays inside the
-- intersection of PUC Lua and the chip (no if-expressions, no closures, no
-- and/or value trick), so the same source runs under the oracle with an _s/_m
-- shim and the formatting rules can be settled before they go near the chip.
string = string or {}

_fmt_digits = "0123456789"
_fmt_hex = "0123456789abcdef"
_fmt_HEX = "0123456789ABCDEF"

_fmt_isdigit = function(c)
  return c >= "0" and c <= "9"
end

_fmt_findb = function(s, b)
  for i = 1, #s do
    if _s(4, s, i - 1, 0) == b then
      return i
    end
  end
  return 0
end

_fmt_num = function(s)
  local v = 0
  for i = 1, #s do
    v = v * 10 + (_s(4, s, i - 1, 0) - 48)
  end
  return v
end

_fmt_rep = function(s, n)
  local r = ""
  for i = 1, n do
    r = r .. s
  end
  return r
end

-- no error() on the chip yet: fail loudly rather than format a wrong value.
-- string.format's own argument errors arrive with error().
_fmt_bad = function()
  local bad = nil
  return bad.x
end

_fmt_int = function(v)
  local neg = false
  if v < 0 then
    neg = true
    v = -v
  end
  if v == 0 then
    return "0"
  end
  local s = ""
  while v >= 1 do
    local d = _m(1, v % 10) + 1
    s = _s(1, _fmt_digits, d - 1, 1) .. s
    v = _m(1, v / 10)
  end
  if neg then
    s = "-" .. s
  end
  return s
end

_fmt_base = function(v, digits, base)
  local neg = false
  if v < 0 then
    neg = true
    v = -v
  end
  v = _m(1, v)
  if v == 0 then
    return "0"
  end
  local s = ""
  while v >= 1 do
    local d = _m(1, v % base) + 1
    s = _s(1, digits, d - 1, 1) .. s
    v = _m(1, v / base)
  end
  if neg then
    s = "-" .. s
  end
  return s
end

_fmt_checkint = function(v)
  if type(v) ~= "number" then
    return _fmt_bad()
  end
  local f = _m(1, v)
  if v ~= f then
    return _fmt_bad()
  end
  return v
end

-- %.3d and friends: precision is a minimum digit count, not a truncation.
_fmt_padint = function(s, prec)
  local pre = ""
  local body = s
  if _s(1, s, 0, 1) == "-" then
    pre = "-"
    body = _s(1, s, 1, #s - 1)
  end
  while #body < prec do
    body = "0" .. body
  end
  return pre .. body
end

-- Dekker two-product: with p = a * b the residual e is exact, so p + e is the
-- true product.  v * 10^prec is correctly rounded on its own, which means its
-- distance from a decimal midpoint is either zero or at least half an ulp, so
-- adding e settles every rounding decision -- including the ones where the
-- product lands exactly on .5 (0.05, 2.675) and e's sign is the answer.
--
-- Its limit: once v * 10^prec is not exactly representable (>= 2^52) the product
-- has already lost the digit that decides the rounding, and matching C would
-- need the exact decimal expansion of the double.  That is the same missing
-- machinery that makes the chip's own tostring print 1/3 as 16 digits where
-- PUC prints 17, and it is where %.17g of 0.1 diverges.
_fmt_twoprod = function(a, b, p)
  local c = 134217729 * a
  local ah = c - (c - a)
  local al = a - ah
  local d = 134217729 * b
  local bh = d - (d - b)
  local bl = b - bh
  local e = (ah * bh - p) + ah * bl + al * bh
  return e + al * bl
end

_fmt_roundr = function(v, scale)
  local p = v * scale
  local e = _fmt_twoprod(v, scale, p)
  local fl = _m(1, p)
  local fr = p - fl
  if fr > 0.5 or (fr == 0.5 and e > 0) then
    fl = fl + 1
  elseif fr == 0.5 and e == 0 and fl % 2 == 1 then
    fl = fl + 1
  end
  return fl
end

_fmt_fixed = function(v, prec)
  local scale = 10 ^ prec
  local av = v
  if av < 0 then
    av = -av
  end
  local r = _fmt_roundr(av, scale)
  local ip = _m(1, r / scale)
  local fp = r - ip * scale
  local s = _fmt_int(ip)
  if prec > 0 then
    local d = ""
    local p = scale / 10
    while p >= 1 do
      local dig = _m(1, fp / p) % 10
      d = d .. _s(1, _fmt_digits, dig, 1)
      p = p / 10
    end
    s = s .. "." .. d
  end
  if v < 0 then
    s = "-" .. s
  end
  return s
end

_fmt_expon = function(v)
  local ex = 0
  local av = v
  if av < 0 then
    av = -av
  end
  if av ~= 0 then
    while av >= 10 do
      av = av / 10
      ex = ex + 1
    end
    while av < 1 do
      av = av * 10
      ex = ex - 1
    end
  end
  return ex, av
end

_fmt_expsuf = function(ex, echar)
  local es = "+"
  local ea = ex
  if ex < 0 then
    es = "-"
    ea = -ex
  end
  local ed = _fmt_int(ea)
  while #ed < 3 do
    ed = "0" .. ed
  end
  return echar .. es .. ed
end

-- %e's mantissa without its sign, so %g can reuse it
_fmt_emant = function(v, prec)
  local ex, av = _fmt_expon(v)
  local m = _fmt_fixed(av, prec)
  if av ~= 0 and _s(1, m, 0, 2) == "10" then
    av = av / 10
    ex = ex + 1
    m = _fmt_fixed(av, prec)
  end
  return m, _fmt_expsuf(ex, "e")
end

_fmt_exp = function(v, prec, echar)
  local m, suf = _fmt_emant(v, prec)
  if echar == "E" then
    m = _s(2, m, 0, 0)
    suf = _s(2, suf, 0, 0)
  end
  if v < 0 then
    m = "-" .. m
  end
  return m .. suf
end

_fmt_g = function(v, prec, echar)
  if prec == 0 then
    prec = 1
  end
  local ex, av = _fmt_expon(v)
  local av0 = v
  if av0 < 0 then
    av0 = -av0
  end
  local mant = ""
  local suf = ""
  if ex < -4 or ex >= prec then
    mant, suf = _fmt_emant(v, prec - 1)
    if echar == "G" then
      mant = _s(2, mant, 0, 0)
      suf = _s(2, suf, 0, 0)
    end
  else
    -- the original value, not av: av is the mantissa %e would print, and
    -- _fmt_fixed scales by the precision, not by the exponent
    mant = _fmt_fixed(av0, prec - 1 - ex)
  end
  -- C drops the trailing zeros of the fraction, and a dot left bare
  if prec > 1 then
    local dot = _fmt_findb(mant, 46)
    if dot ~= 0 then
      local n = #mant
      while n > dot and _s(4, mant, n - 1, 0) == 48 do
        n = n - 1
      end
      if n == dot then
        n = dot - 1
      end
      mant = _s(1, mant, 0, n)
    end
  end
  if v < 0 then
    mant = "-" .. mant
  end
  return mant .. suf
end

_fmt_quoted = function(s)
  local out = "\""
  for i = 1, #s do
    local b = _s(4, s, i - 1, 0)
    if b == 34 then
      out = out .. "\\\""
    elseif b == 92 then
      out = out .. "\\\\"
    elseif b == 10 then
      -- PUC 5.5 writes a backslash and a real newline here, not "\n", so a
      -- quoted multi-line string is still one pasteable literal
      out = out .. "\\\n"
    elseif b == 13 then
      out = out .. "\\r"
    elseif b == 0 then
      out = out .. "\\0"
    elseif b < 32 or b == 127 then
      out = out .. "\\" .. _fmt_int(b)
    else
      out = out .. _s(1, s, i - 1, 1)
    end
  end
  return out .. "\""
end

string.format = function(fmt, ...)
  local out = ""
  local i = 1
  local flen = #fmt
  local an = 0
  while i <= flen do
    if _s(1, fmt, i - 1, 1) ~= "%" then
      out = out .. _s(1, fmt, i - 1, 1)
      i = i + 1
    else
      local j = i + 1
      local minus = false
      local plus = false
      local space = false
      local hash = false
      local zero = false
      local f = _s(1, fmt, j - 1, 1)
      while f == "-" or f == "+" or f == " " or f == "#" or f == "0" do
        if f == "-" then
          minus = true
        elseif f == "+" then
          plus = true
        elseif f == " " then
          space = true
        elseif f == "#" then
          hash = true
        else
          zero = true
        end
        j = j + 1
        f = _s(1, fmt, j - 1, 1)
      end
      local ws = ""
      while _fmt_isdigit(f) do
        ws = ws .. f
        j = j + 1
        f = _s(1, fmt, j - 1, 1)
      end
      local width = 0
      if ws ~= "" then
        width = _fmt_num(ws)
      end
      local prec = -1
      if f == "." then
        j = j + 1
        f = _s(1, fmt, j - 1, 1)
        local ps = ""
        while _fmt_isdigit(f) do
          ps = ps .. f
          j = j + 1
          f = _s(1, fmt, j - 1, 1)
        end
        if ps == "" then
          prec = 0
        else
          prec = _fmt_num(ps)
        end
      end
      local conv = f
      j = j + 1
      if conv == "%" or conv == "" then
        out = out .. "%"
      else
        an = an + 1
        local v = select(an, ...)
        local body = ""
        local numeric = true
        if conv == "d" or conv == "i" or conv == "u" then
          body = _fmt_int(_fmt_checkint(v))
          if prec > 0 then
            body = _fmt_padint(body, prec)
          end
        elseif conv == "c" then
          body = _s(5, "", _fmt_checkint(v), 0)
          numeric = false
        elseif conv == "o" then
          body = _fmt_base(_fmt_checkint(v), "01234567", 8)
          if hash then
            body = "0" .. body
          end
        elseif conv == "x" then
          body = _fmt_base(_fmt_checkint(v), _fmt_hex, 16)
          if hash and _fmt_checkint(v) ~= 0 then
            body = "0x" .. body
          end
        elseif conv == "X" then
          body = _fmt_base(_fmt_checkint(v), _fmt_HEX, 16)
          if hash and _fmt_checkint(v) ~= 0 then
            body = "0X" .. body
          end
        elseif conv == "s" then
          numeric = false
          body = tostring(v)
          if prec >= 0 and prec < #body then
            body = _s(1, body, 0, prec)
          end
        elseif conv == "q" then
          numeric = false
          body = _fmt_quoted(tostring(v))
        elseif conv == "f" then
          if prec < 0 then
            prec = 6
          end
          body = _fmt_fixed(v, prec)
        elseif conv == "e" or conv == "E" then
          if prec < 0 then
            prec = 6
          end
          body = _fmt_exp(v, prec, conv)
        elseif conv == "g" or conv == "G" then
          if prec < 0 then
            prec = 6
          end
          body = _fmt_g(v, prec, conv)
        else
          out = out .. "%" .. conv
          an = an - 1
        end
        if numeric then
          local c1 = _s(1, body, 0, 1)
          local neg = c1 == "-"
          if plus and not neg then
            body = "+" .. body
          elseif space and not neg then
            body = " " .. body
          end
        end
        if width > #body then
          if zero and numeric then
            local pre = ""
            local c1 = _s(1, body, 0, 1)
            if c1 == "-" or c1 == "+" or c1 == " " then
              pre = c1
              body = _s(1, body, 1, #body - 1)
            end
            local c2 = _s(1, body, 0, 2)
            if c2 == "0x" or c2 == "0X" then
              pre = pre .. c2
              body = _s(1, body, 2, #body - 2)
            end
            body = pre .. _fmt_rep("0", width - #body - #pre) .. body
          elseif minus then
            body = body .. _fmt_rep(" ", width - #body)
          else
            body = _fmt_rep(" ", width - #body) .. body
          end
        end
        out = out .. body
      end
      i = j
    end
  end
  return out
end
