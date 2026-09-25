-- math.random / math.randomseed.
--
-- The host HAS a random gate: BrickComponentType_WireGraph_Exec_Random,
-- `Random(min, max) -> int` (the catalogue gives it Min/Max/Output), and it
-- DOES fire from inside a mod -- three compiled probes agree, including one
-- where a mod calls it and the enclosing handler's exec context drives its Exec
-- (`W[BrickGrid -> Random:Exec]`), so "an exec gate cannot be used here" is
-- false.  What does not work is CONSUMING it: the compiler orders a consumer
-- that is itself an exec gate along the gate's ExecOut chain, and the chip's
-- register writes are plain array writes with no Exec port, so a value produced
-- by an exec gate cannot be read into a register in the same instruction.  An
-- `_rnd` arm written the documented way (`let r = Random(lo, hi)` then
-- `vSetInt(a, r)`) re-ran the instruction until the tick cap.  Using it would
-- need a second phase: fire the gate on one tick, read a captured output on the
-- next, which is the micro-step pattern `_fmt` and `_pat` already use.  Not
-- worth it for a function no program calls in a loop -- and a free-running
-- stream would have to fire every tick for every program.
--
-- So this is a 32-bit LCG in Lua: 0 nodes, and the cost is ticks.  The
-- generator is Numerical Recipes' constants with the HIGH bits used for the
-- value, because an LCG's low bits are poor:
--
--   s = (s * 1664525 + 1013904223) & 0xFFFFFFFF
--
-- The chip's `*` is exact to 2^53 and `&` is 32-bit, so the product needs no
-- splitting and the mask is the truncation.  The state is a local in this
-- closure, which is the chip's version of PUC's userdata upvalue.
--
-- It is NOT bit-compatible with PUC: PUC uses xoshiro256** on a 64-bit state, so
-- the same seed gives a different sequence and randomseed answers something
-- else.  The API, the ranges and the float's interval are PUC's; the numbers are
-- not, and no program can tell the difference except by comparing PUC's own
-- output.  Ticks: a Lua loop iteration, so about 40 a call -- fine for the
-- occasional draw, and the reason a loop of a thousand draws is slow.
--
-- floor and the integer test go through `_m` (math.floor and math.tointeger) and
-- NOT through `math.floor`: a bare `floor` is not a global in Lua -- it is
-- `math.floor` -- and a piece may not lean on another piece, because the loader
-- selects those from the PROGRAM's text and a program that only says
-- "math.random" would not get math's pieces.  `_m` is a declared builtin, so it
-- is always there.
math = math or {}
local _rs = 12345

local _rand = function(m, n)
  -- Compute the draw into a LOCAL and only then write the upvalue.  Read the
  -- upvalue again in this same body and the chip answers the value from before
  -- the write (measured: a piece-level closure that writes a captured local and
  -- reads it later in the same body re-reads the seed, so the LCG never
  -- advances).  The same shape in a program's own chunk is correct, so this is
  -- about the library chunk's cells, not about closures in general.
  local v = (_rs * 1664525 + 1013904223) & 0xFFFFFFFF
  _rs = v
  if m == nil then
    return v / 4294967296.0
  end
  local lo, hi
  local argn = "1"
  if n == nil then
    lo, hi = 1, m
  else
    lo, hi = m, n
    argn = "2"
  end
  if hi < lo then
    error("bad argument #" .. argn .. " to 'random' (interval is empty)", 2)
  end
  -- _m(1, x, 0) is math.floor, and x is never negative here, so the high bits
  -- of the draw are what scale it
  return lo + _m(1, v / 4294967296.0 * (hi - lo + 1), 0)
end

math.random = function(m, n)
  if m == nil then
    return _rand()
  end
  if type(m) == "string" then m = m + 0 end
  if _m(13, m, 0) == nil then
    error("bad argument #1 to 'random' (number has no integer representation)", 2)
  end
  if n == nil then
    return _rand(m)
  end
  if type(n) == "string" then n = n + 0 end
  if _m(13, n, 0) == nil then
    error("bad argument #2 to 'random' (number has no integer representation)", 2)
  end
  return _rand(m, n)
end

math.randomseed = function(x, y)
  local a = 0
  local b = 0
  if x ~= nil then a = _m(1, x, 0) end
  if y ~= nil then b = _m(1, y, 0) end
  local st = (a * 1013904223 + b) & 0xFFFFFFFF
  if st == 0 then st = 1 end
  _rs = st
  return a, b
end
