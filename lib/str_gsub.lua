-- The PUC-verified source of LIB_str_gsub in lua.ws, kept here the way
-- lib/str_format.lua is: lua.ws carries the escaped copy the chip runs, and this
-- is the readable one the oracle checks run against.  `tools/check.py @file`
-- proves the chip's copy; the piece itself is proved with an _s/_m/_pat shim
-- against PUC's gsub on a set of shapes (55/55 when this was installed).
--
-- Three of the rules below are lstrlib's loop and not the matcher's, and they
-- are the ones a transcription gets wrong:
--   * the unmatched text between one match and the next is copied when the
--     match lands, so a find's start can be past the loop's cursor, and a step
--     that does not match copies exactly one character without counting as a
--     replacement;
--   * a match that ends where the last one ended is not a replacement, which is
--     what ends "aaa" on "a*" after one -- the matcher itself does match at the
--     end of the subject, so find("abc", "a*", 4) is 4 3;
--   * a leading ^ gives one match and no more, whatever the limit.
-- And two are lstrlib's push_captures and add_table: a function replacement is
-- given the captures, or the whole match when there are none (not the match and
-- then the captures), and a nil or false value from a table or a function keeps
-- the matched text instead of dropping it.
--
-- The cost is in AGENTS.md: 3109 characters, so naming gsub costs ~2.9s of boot
-- and the loop itself ~0.1s a match.  A gate would not pay that, but it cannot
-- call the replacement function, so the piece stays until the VM can suspend a
-- machine for a call.
string = string or {}
string.gsub = function(s, p, r, n)
  if type(s) == "number" then s = tostring(s) end
  local sl, out, pos, cnt, last = #s, "", 1, 0, -1
  local anch = _s(1, p, 0, 1) == "^"
  local rt = type(r)
  if r == nil then error("bad argument #3 to 'string.gsub' (string/function/table expected, got no value)", 2) end
  if rt == "number" then r = tostring(r) rt = "string" end
  local add = function(v)
    local tv = type(v)
    if tv == "string" then return v end
    if tv == "number" then return tostring(v) end
    if tv == "boolean" then error("invalid replacement value (a boolean)", 2) end
    error("invalid replacement value (a " .. tv .. ")", 2)
  end
  local rep = function(kt, kr, add, res, m)
    if kt == "function" then
      local v, w
      if res[3] == 0 then v, w = kr(m) else v, w = kr(unpack(res, 4, 3 + res[3])) end
      if v == nil or v == false then return m end
      if w == nil or w == false then return add(v) end
      return add(v) .. add(w)
    elseif kt == "table" then
      local k = m
      if res[3] > 0 then k = res[4] end
      local v = kr[k]
      if v == nil or v == false then return m end
      return add(v)
    else
      local o, i, rl = "", 1, #kr
      while i <= rl do
        local j = string.find(kr, "%", i, true)
        if j == nil then o = o .. _s(1, kr, i - 1, rl - i + 1) break end
        if i < j then o = o .. _s(1, kr, i - 1, j - i) end
        if j == rl then error("invalid use of '%' in replacement string", 2) end
        local d = _s(1, kr, j, 1)
        if d == "%" then o = o .. "%"
        elseif d == "0" then o = o .. m
        else
          local q = _s(4, d, 0, 0) - 48
          if q < 1 or 9 < q then error("invalid use of '%' in replacement string", 2) end
          if 1 < q and res[3] < q then error("invalid capture index %" .. d, 2) end
          if q == 1 and res[3] == 0 then o = o .. m else o = o .. add(res[q + 3]) end
        end
        i = j + 2
      end
      return o
    end
  end
  if rt ~= "string" and rt ~= "table" and rt ~= "function" then error("bad argument #3 to 'string.gsub' (string/function/table expected, got " .. rt .. ")", 2) end
  if n == nil then n = sl + 1 end
  if type(n) ~= "number" then error("bad argument #4 to 'string.gsub' (number expected, got " .. type(n) .. ")", 2) end
  n = _m(13, n, 0)
  if n == nil then error("bad argument #4 to 'string.gsub' (number has no integer representation)", 2) end
  if n < 1 then return s, 0 end
  while cnt < n do
    local res = {_pat(2, s, p, pos)}
    if res[1] == nil then break end
    local a, b = res[1], res[2]
    if b == last then
      if pos <= sl then out = out .. _s(1, s, pos - 1, 1) pos = pos + 1 else break end
    else
      if pos < a then out = out .. _s(1, s, pos - 1, a - pos) end
      out = out .. rep(rt, r, add, res, _s(1, s, a - 1, b - a + 1))
      cnt = cnt + 1
      pos = b + 1
    end
    last = b
    if anch then break end
  end
  return out .. _s(1, s, pos - 1, sl - pos + 1), cnt
end
