-- math.floor / ceil / tointeger / type / abs / sqrt: one-liners over the _m gate.
--
-- A CHIP would be the wrong shape for these: each is a single call, and PUC
-- having them in C is what puts them in a piece rather than behind six gates.
--
-- math.ult used to live here and does not anymore: it is an argument-ladder
-- outweighing these six one-liners ten to one, and a program that only ever
-- floors paid all of it at boot (tools/chip/libprobe.py).  It is lib/math_ult.lua
-- now, loading only for math.ult; the canary next to it is still math.floor.
--
-- This is a MASTER file, installed with
--   tools/lib/libconst.py lib/math_int.lua LIB_math_int --install
-- so the text the chip parses is generated rather than hand-typed into lua.ws.
math = math or {}
math.floor = function(x) return _m(1, x, 0) end
math.ceil = function(x) return _m(2, x, 0) end
math.tointeger = function(x) return _m(13, x, 0) end
math.type = function(x) return _m(14, x, 0) end
math.abs = function(x) if type(x) == "string" then x = x + 0.0 end if x < 0 then return -x end if x == 0 then return x - x end return x end
math.sqrt = function(x) return _m(3, x, 0) end
