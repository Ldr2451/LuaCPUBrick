-- table.sort, as an insertion sort.
--
-- PUC's sort is a quicksort with an introsort fallback; this is insertion
-- sort, and that is a deliberate trade rather than an oversight.  Measured, the
-- loop costs about 20 ticks per element per pass here against PUC's O(n log n),
-- so a 10,000-element sort is slow -- but it is O(n^2) in TICKS on a machine
-- that executes one instruction per tick, it needs no recursion (WireScript has
-- no recursion and no loop, so a quicksort would be a hand-unrolled ladder of
-- unbounded depth), and it is correct for every input including the ones that
-- make a naive quicksort quadratic.
--
-- `_lt` is a GLOBAL, not a local, on purpose: it must not be renamed, and a
-- global is how a name says so.  It is also why a program can pass its own
-- comparator -- `lt = cmp or _lt` -- which is the only reason this is one
-- piece rather than a gate with the comparison inlined.
table = table or {}
_lt = function(a, b) return a < b end
table.sort = function(t, cmp)
  local lt = cmp or _lt
  for i = 2, #t do
    local v = t[i]
    local j = i - 1
    while j >= 1 and lt(v, t[j]) do t[j + 1] = t[j] j = j - 1 end
    t[j + 1] = v
  end
end