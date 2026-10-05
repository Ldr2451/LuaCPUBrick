-- string.format, bound to the _fmt gate.
--
-- Two lines, because the formatter IS a gate: PUC's str_format is 11,468
-- characters, which does not fit the ~4 KB source buffer and so cannot be a
-- piece whatever it would have cost (tools/chip/lexrate.py is the measurement).
-- lib/str_format.lua is PUC-verified Lua kept as the reference implementation
-- the gate is proved against, and it is deliberately NOT installed -- installing
-- it would be a piece that cannot load.
--
-- The piece exists so that NAMING string.format pulls in this two-line wrapper
-- and nothing else.  Naming math.abs or math.floor costs about 474 ticks of
-- boot for the same reason: libMathInt and libMathConst are pieces the loader
-- pulls in on the name.
string = string or {}
string.format = _fmt