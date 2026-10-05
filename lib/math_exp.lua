-- math.exp and math.log, over the _m gate.
--
-- One call each, which is the rule for a piece rather than a gate: PUC has
-- these in C, and PUC's log is three shapes -- base e, base 10, any other base
-- as a division -- so a gate would be a new fid and a 13th gateHigh arm, while
-- this is two assignments.  The base-10 branch exists because PUC has a
-- separately-rounded path for it, and a program doing log(x, 10) in a loop is
-- common enough to be worth not paying a division for.
--
-- math.trig is a piece of its own (lib/math_trig.lua) and math.maxinteger is
-- in lib/math_const.lua: naming one must not parse the others.
math = math or {}
math.exp = function(x) return _m(10, x, 0) end
math.log = function(x, b)
  if b == nil then return _m(11, x, 0) end
  if b == 10 then return _m(12, x, 0) end
  return _m(11, x, 0) / _m(11, b, 0)
end