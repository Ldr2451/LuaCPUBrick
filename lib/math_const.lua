-- math.pi, math.huge and the two integer limits.
--
-- This is a piece rather than four chip constants because naming any of them
-- has to cost the same: measured, naming math.maxinteger cost 923 ticks of
-- boot, and a constant that lives in the chip is a constant every program
-- carries whether it uses it or not.  A program that names one of these parses
-- four assignments and nothing else.
--
-- maxinteger/mininteger are the Lua 5.5 64-bit bounds.  The chip's numbers are
-- doubles, so these are the literals PUC spells and the chip rounds -- which is
-- the documented int64 wall, not a transcription slip: everything that depends
-- on 2^63 exactly is in it (see the CHIP_LOG entry for integer precision).
math = math or {}
math.pi = 3.141592653589793
math.huge = 1.7976931348623157e308
math.maxinteger = 9223372036854775807
math.mininteger = -9223372036854775808