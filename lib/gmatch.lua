-- string.gmatch(s, p [, init]): the iterator a generic for walks.
--
-- NOT INSTALLED.  This is the reference implementation and the measurement that
-- decided against it (tools/piececost.py runs the comparison).  As two gates
-- (_gmatch, _gmnext) plus a micro-step machine, gmatch was 1,053 nodes and 33
-- ticks a step.  This piece saves exactly those 1,053 nodes and costs 2,970
-- ticks of BOOT -- 26x -- because a piece's boot is not its own character count
-- but every piece it drags in: this file is 1,469 escaped chars (370 ticks of
-- lexing) and it needs string.find, string.sub and table.pack, which pull in
-- the pattern wrapper, the string-index piece and the table-list piece.  At 60
-- ticks/s that is 51 seconds before the first step.  Per step it is 119 ticks
-- against the gates' 33, and a capture-free fast path with no table.pack and no
-- table.unpack measured slightly WORSE, so the per-step cost is the Lua call
-- and the micro-step dispatch rather than the variadic plumbing.
--
-- The rule that came out of it: a piece is viable when everything it needs is
-- ALREADY a gate, so the only boot it adds is its own characters.  pairs and
-- ipairs qualify (they need next and nothing else).  A piece that needs another
-- PIECE does not.
--
-- The rules below are PUC 5.5.1's, from lstrlib.c, and they are what a future
-- conversion has to reproduce:
--
--   size_t init = posrelatI(luaL_optinteger(L, 3, 1), ls) - 1;   an init
--   for (src = gm->src; src <= gm->ms.src_end; src++)
--     if ((e = match(...)) != NULL && e != gm->lastmatch) {        the guard
--       gm->src = gm->lastmatch = e;  return push_captures(...);
--   return 0;                                                     NOT one nil
--
-- So the walk resumes at the END of the last match, a match that ends where the
-- last one ended is skipped, and the loop ends when the position passes the end
-- of the subject.  That guard is what makes gmatch("aaa", "a*") ONE result
-- ("aaa"): the empty match at the end would end where "aaa" ended.  The end of
-- the walk is NO values, because a for-in that gets one nil calls the iterator
-- for ever.
--
-- push_captures pushes the CAPTURES, and the whole match only when the pattern
-- has none:
--
--   int nlevels = (ms->level == 0 && s) ? ms->level : ms->level;
--   for (i = 0; i < nlevels; i++) push_onecapture(ms, i, s, e);
--
-- (both arms of that ternary are ms->level, so with captures the match itself is
-- not pushed).  Measured: gmatch('a1b2', '(%a)(%d)') yields "a" then "b", and
-- gmatch('a1b2', '%a%d') yields "a1" then "b2".  A for-in over the first takes
-- two captures as its two loop variables, which is not what readers expect.
--
-- And a leading ^ matches NOTHING in gmatch, where find and gsub take it as the
-- anchor and honour it: gmatch('aba', '^a') is empty in PUC 5.5.
string.gmatch = function(s, p, init)
  if s == nil then
    error("bad argument #1 to 'string.gmatch' (string expected, got no value)", 2)
  end
  if type(s) == "number" then s = tostring(s) end
  if type(s) ~= "string" then
    error("bad argument #1 to 'string.gmatch' (string expected, got " .. type(s) .. ")", 2)
  end
  if p == nil then
    error("bad argument #2 to 'string.gmatch' (string expected, got no value)", 2)
  end
  if type(p) == "number" then p = tostring(p) end
  if type(p) ~= "string" then
    error("bad argument #2 to 'string.gmatch' (string expected, got " .. type(p) .. ")", 2)
  end
  if string.sub(p, 1, 1) == "^" then
    return function() return end
  end
  local pos = 1
  if init ~= nil then pos = init end
  local lastend = nil
  local slen = #s
  -- Which of the two shapes this walk has does not change from step to step, so
  -- decide it ONCE, from a find at the starting position that is then thrown
  -- away (the walk re-finds from the same pos, so nothing is lost).  This is
  -- what keeps a capture-free walk off table.pack and table.unpack: those cost
  -- a table and a variadic call per step, and with them a four-word walk cost
  -- 3,359 ticks against the gates' 249.
  local probe = table.pack(string.find(s, p, pos))
  if probe.n - 2 == 0 then
    return function()
      while pos <= slen + 1 do
        local a, b = string.find(s, p, pos)
        if a ~= nil and b ~= lastend then
          lastend = b
          pos = b + 1
          return string.sub(s, a, b)
        end
        pos = pos + 1
      end
      return
    end
  end
  return function()
    while pos <= slen + 1 do
      -- table.pack answers ONE value in PUC (the count is t.n), so the count
      -- comes from the field rather than a second return value
      local caps = table.pack(string.find(s, p, pos))
      if caps[1] ~= nil and caps[2] ~= lastend then
        local a = caps[1]
        local b = caps[2]
        lastend = b
        pos = b + 1
        local n = caps.n - 2
        if n == 0 then
          return string.sub(s, a, b)
        end
        local out = {}
        for i = 1, n do out[i] = caps[i + 2] end
        return table.unpack(out, 1, n)
      end
      pos = pos + 1
    end
    return
  end
end
