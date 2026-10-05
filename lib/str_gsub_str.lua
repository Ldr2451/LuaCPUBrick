-- string.gsub with a STRING replacement literal, WITHOUT the function/table arms.
--
-- REVERTED, kept as the reference: installing this cost +99 nodes of gate (two
-- comma Finds plus a class test per call, unrolled twice) for -647 boot ticks,
-- 6.5 ticks per node against the tonumber split's 31.  The numbers and the shape
-- are in lua.ws at libStrGsub so it is not retried blind.  Verified correct while
-- installed (gsub- 22/22); the logic below is byte-identical to the same lines in
-- lib/str_gsub.lua.
--
-- This is the common shape -- `string.gsub(s, p, "x")` -- and a literal third
-- argument IS a string, so the function branch and the table branch of `rep` are
-- unreachable here, and so is the replacement validation: PUC raises those errors
-- for a value this gate has already proven cannot arrive.  What stays is byte-
-- identical to the same lines in lib/str_gsub.lua: the entry coercion, the loop,
-- `add`, and the string arm of `rep` with its `%` walk.
--
-- The gate (libStrGsubStr) fires only when a `gsub(` call's third argument starts
-- with a quote, a digit, or a sign -- the literal shapes.  Anything else, including
-- a program with no parseable `gsub(` at all (an alias like `local g = string.gsub`
-- names it without calling it), installs the FULL piece.  A miss installs
-- everything, so the fast path is purely optional: under-triggering costs boot
-- ticks and nothing else.
--
-- The three lstrlib loop rules from lib/str_gsub.lua apply unchanged: unmatched
-- text copied when the match lands, an end-where-the-last-ended match is not a
-- replacement, one match for a leading ^.
string = string or {}
string.gsub = function(s, p, r, n)
  if type(s) == "number" then s = tostring(s) end
  local sl, out, pos, cnt, last = #s, "", 1, 0, -1
  local anch = _s(1, p, 0, 1) == "^"
  local add = function(v)
    local tv = type(v)
    if tv == "string" then return v end
    if tv == "number" then return tostring(v) end
    if tv == "boolean" then error("invalid replacement value (a boolean)", 2) end
    error("invalid replacement value (a " .. tv .. ")", 2)
  end
  local rep = function(kr, add, res, m)
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
      out = out .. rep(r, add, res, _s(1, s, a - 1, b - a + 1))
      cnt = cnt + 1
      pos = b + 1
    end
    last = b
    if anch then break end
  end
  return out .. _s(1, s, pos - 1, sl - pos + 1), cnt
end
