-- os.exit(code [, close]), PUC 5.5's shape.
--
-- PUC terminates the process with code (0 for nil/true/0, 1 otherwise) and the
-- close argument is gone in 5.5.  The chip has no exit-code channel, so the
-- code is observable only as halt-vs-message: a clean code halts with the err
-- port EMPTY (error("", 0) raises past nothing and carries no text), anything
-- else halts with "exit: <code>" on err.  That message is a chip-ism -- PUC
-- prints nothing -- and it is the more useful half in game, where err is what
-- anyone reads.
--
-- The other half is a real divergence: PUC's exit terminates THROUGH pcall,
-- this one is caught by it (it is error underneath).  Unavoidable without a
-- halt primitive the compiler does not have.  Nobody pcalls os.exit except a
-- test proving exactly this, which is why the case below does -- and on the
-- lite chip, where catching is gone, that case is a direct error assertion
-- instead of a pcall pair.
os = os or {}
os.exit = function(c)
  if c == nil or c == true or c == 0 then error("", 0) else error("exit: " .. tostring(c), 0) end
end
