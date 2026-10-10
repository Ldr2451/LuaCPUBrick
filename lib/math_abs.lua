-- math.abs, split out of math_int.lua.
--
-- PUC reaches it through luaL_checknumber, which ACCEPTS A NUMERIC STRING, so
-- math.abs("-5") is 5: the `+ 0.0` is the host-faithful coercion, not a parse.
-- `-x` of 0 is -0.0 in IEEE, and PUC prints that "-0.0", so a zero coming back
-- is `x - x` (+0.0) instead -- asked of the oracle, not reasoned out.
--
-- Split out of LIB_math_int because the check outweighs the other one-liners
-- several to one, and a program that only ever floors paid all of it at boot
-- (tools/chip/libprobe.py).  The floor family stays in math_int.lua; this
-- piece loads only for math.abs (or math indexed at run time, which loads
-- every math piece).
--
-- This is a MASTER file, installed with
--   tools/lib/libconst.py lib/math_abs.lua LIB_math_abs --install
-- so the text the chip parses is generated rather than hand-typed into lua.ws.
math = math or {}
math.abs = function(x) if type(x) == "string" then x = x + 0.0 end if x < 0 then return -x end if x == 0 then return x - x end return x end
