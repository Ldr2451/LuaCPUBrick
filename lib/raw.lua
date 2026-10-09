-- rawequal, rawget, rawset, rawlen: the no-metamethod forms of
-- ==, t[k], t[k] = v and #t.  On this chip they are not a
-- behaviour that skips a metatable step -- there ARE no
-- metatables, so == never dispatches, a read never falls back
-- to __index, a write never to __newindex and # never to __len.
-- Each raw function is therefore the SAME operation as its plain
-- form, which is what makes these pieces over the ops the chip
-- already has (the == op, the index op, the assign op, the
-- length op) instead of new gates: a thin wrapper over an
-- existing primitive is a piece however PUC wrote it.
--
--   rawequal(a, b)   a == b; reference equality for tables, so
--                    two tables with the same contents are not
--                    equal -- the chip's == is already PUC's here
--   rawget(t, k)     t[k]; a non-table raises (PUC: "table
--                    expected"; the chip's index op says
--                    "attempt to index" -- loud either way)
--   rawset(t, k, v)  t[k] = v; returns t
--   rawlen(t)        #t for a string or table, else raises.  The
--                    raise matches PUC's, the MESSAGE is the
--                    length op's ("attempt to get length of a
--                    number value" where PUC's rawlen says
--                    "table or string expected"); `not
--                    pcall(rawlen, x)` agreed, the only form
--                    PUC's tests use -- and on the chip that
--                    call now raises "not supported", so
--                    what is pinned below is the message
--                    itself, not the catching of it.
--
-- Loaded by one "raw" prefix -- no other raw* global exists --
-- the same fold rule as math.l and os.d: one arm, four functions.
rawequal = function(a, b) return a == b end
rawget = function(t, k) return t[k] end
rawset = function(t, k, v) t[k] = v return t end
rawlen = function(t) return #t end
