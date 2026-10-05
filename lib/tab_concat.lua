-- table.concat, in PUC's order.
--
-- The argument order is the whole of it and it is easy to get backwards:
-- concat(t, sep, i, j), so the SEPARATOR is second and the range is third and
-- fourth.  All four are optional in PUC, and each is defaulted the same way --
-- an explicit nil means "not given", which is why these are `or` and not a
-- count check: `sep or ""` is false for false as well, and PUC's is false for
-- false too, because PUC's luaL_optlstring rejects a non-string rather than
-- treating it as absent.  `#t` as the default end is PUC's own.
table = table or {}
table.concat = function(t, sep, i, j)
  sep = sep or ""
  i = i or 1
  j = j or #t
  local r = ""
  for k = i, j do
    local v = t[k]
    if k > i then r = r .. sep end
    r = r .. v
  end
  return r
end