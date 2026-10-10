-- math.deg / math.rad, WITHOUT the trig one-liners.
--
-- Pure arithmetic over a pi literal: 180/pi and pi/180 to 17 digits, exactly as
-- PUC computes them -- and a LITERAL rather than math.pi on purpose: math.pi
-- lives in LIB_math_const, a separate piece the loader only pulls in when the
-- PROGRAM names it, so reaching across pieces for it would read nil.  A
-- duplicated constant is cheaper than a cross-piece dependency, and it cannot
-- drift (both spell the same double).
--
-- Split out of LIB_math_trig because the six gate one-liners are dead weight
-- for a program that only converts angles (and vice versa) -- the insert/remove
-- split measured the same shape.  The trig six stay in lib/math_trig.lua.
--
-- This is a MASTER file, installed with
--   tools/lib/libconst.py lib/math_deg.lua LIB_math_deg --install
-- so the text the chip parses is generated rather than hand-typed into lua.ws.
math = math or {}
math.deg = function(x) return x * 57.295779513082323 end
math.rad = function(x) return x * 0.017453292519943295 end
