-- math.floor / ceil / tointeger / type / abs / sqrt: one-liners over the _m gate.
--
-- A CHIP would be the wrong shape for these: each is a single call, and PUC
-- having them in C is what puts them in a piece rather than behind six gates.
--
-- This is a MASTER file, installed with
--   tools/lib/libconst.py lib/math_int.lua LIB_math_int --install
-- so the text the chip parses is generated rather than hand-typed into lua.ws.
--
-- math.ult belongs here and does not yet: PUC's C does the unsigned comparison
-- in lua_Unsigned, which a double cannot hold, and doing it with the SIGNS is
-- exact in three of the four cases (both non-negative compare the same way; a
-- negative second argument is astronomically larger unsigned; a negative first
-- argument is not).  It is not here because a piece that does not PARSE is not
-- an error the program can see: every function in the piece stops answering,
-- silently, with no message and no line.  Two candidate constructs were ruled out
-- by bisecting the piece -- a call compared directly to nil (`_m(13, m, 0) ==
-- nil`) and a bare `return` of a comparison (`return m < n`) -- and the cause is
-- still open.  The lesson is the one worth keeping: a piece is a single unit of
-- failure, so anything added to one has to be tested by RUNNING the piece, not by
-- reading it.
math = math or {}
math.floor = function(x) return _m(1, x, 0) end
math.ceil = function(x) return _m(2, x, 0) end
math.tointeger = function(x) return _m(13, x, 0) end
math.type = function(x) return _m(14, x, 0) end
math.abs = function(x) if type(x) == "string" then x = x + 0.0 end if x < 0 then return -x end if x == 0 then return x - x end return x end
math.sqrt = function(x) return _m(3, x, 0) end