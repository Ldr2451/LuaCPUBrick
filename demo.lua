-- Tiny Lua full-feature smoke test. Paste into `program`, set `run` high.
-- Inputs:  inNum0=3 inNum1=1 inNum2=4 inNum3=1.5
--          inStr0="foo" inStr1="bar" inVec=(1,2,3)
--          inCol=(0.5,0.25,0.125,1) inArr=[10,20,30]
-- Every group below exercises a feature and the ports at the end depend on all
-- of them, so any mismatch means something broke.  The expected log is NOT here:
-- it is tests/cases.py's DEMO_LOG, checked against Lua 5.5 on every suite run.
-- Kept small on purpose (the lexer runs at 4 chars/tick, so source is boot
-- time) and it names no string./math./table./io. function, because naming one
-- makes the loader prepend that library's source in front of this file.

-- arithmetic, precedence, unary minus, power, floored % and //, concat
local a = (inNum0 + inNum1 * inNum2 - inNum3 / 2) % 4
local b = 2 ^ 3 ^ 1 + -inNum1
print("arith", a, b, -7 // 2, 7 // -2, 7.5 % -2)

-- bitwise on whole numbers: and or xor not(=-x-1) shifts
print("bits", inNum0 & 1, inNum0 | 8, inNum0 ~ 5, ~0, inNum2 << 2, 255 >> 4)

-- strings, escapes, length, lexicographic compare
local s = inStr0 .. "-" .. inStr1 .. "!"
print("str", s, #s)
print("cmp", inStr0 < inStr1, "a\nb")

-- booleans, nil, logic returns operands, type()
print("logic", 1 and 2, nil or "dflt")
print("logic2", not "", type(nil), type(print))

-- tables: mixed ctor, computed keys, nesting, len, delete, identity
local t = {10, 20, name = inStr0, [2 + 3] = a}
t[3] = inNum1
t[true] = "yes"
t.extra = "x"
t.extra = nil
t.nested = {v = b}
t.fn = function(x) return x * 2 end
print("tab", #t, t[5], t.name)
print("tab2", t[3], t[true], t.nested.v)
print("tab3", t == t, t ~= {})

-- functions: named recursion, anonymous, higher-order, extra args dropped
local function fact(n)
  if n <= 1 then return 1 else return n * fact(n - 1) end
end
local dbl = function(x) return x * 2 end
local function apply(f, x) return f(x) end
print("func", fact(5), apply(dbl, 21))
print("func2", t.fn(7), dbl(5, 99))

-- varargs: ... in a return, its count through select, a call in the last slot
local function va(...) return select('#', ...), ... end
print("vararg", va(7, 8, 9))
print("vararg2", va(1, 2, 3))

-- closures: two closures over one local share it, and n outlives mk
local function mk()
  local n = 0
  return function() n = n + 1 return n end, function() return n end
end
local tick, peek = mk()
tick() tick()
print("closure", peek(), tick(), mk())

-- errors: error raises, pcall reports, xpcall hands back the handler's value
-- only the boolean: PUC prefixes error's message with chunk:line: and the
-- chip has no run-time line, so the text is a recorded divergence
print("pcall", (pcall(function() error("boom") end)))
print("pcall2", pcall(error, "raw"), pcall(assert, false, "nope"))
print("xpcall", xpcall(function() error("x") end, function() return "handled" end))
print("assert", assert(fact(3), "unreached"))

-- loops: numeric for with a step, generic for over a hand-written iterator,
-- repeat..until, break out of a while, and the loop's own scope
local acc = 0
for i = 1, 10, 2 do acc = acc + i end
local function iter(list, i)
  i = i + 1
  local v = list[i]
  if v then return i, v end
end
local seen = ""
for i, v in iter, {"p", "q"}, 0 do seen = seen .. i .. v end
local k = 0
repeat k = k + 1 until k >= 3
print("loops", acc, seen, k, k * 10 % 7)

-- shadowing, elseif, call-sugar statement
do local tmp = "inner" print("shadow", tmp) end
local grade = "F"
if a > 3 then grade = "A" elseif a > 2 then grade = "B" else grade = "C" end
print 'sugared'
print("grade", grade)

-- while, break inside if, parallel assign, swap, right-to-left dup
local sum = 0
local i = 1
while true do
  if i > 10 then break end
  sum = sum + i
  i = i + 1
end
local p, q = 1, 2
p, q = q, p
-- NB: `local dup, dup` declares TWO locals (second shadows, prints "second");
-- assignment dups store right to left (see outNum0 below, which reads 7)
local dup, dup = "first", "second"
print("flow", sum, p, q, dup)

-- vector/color/array inputs (inarr(9) is out of range -> nil)
local vlen = invecx + invecy + invecz
local cren = incolr + incolg + incolb + incola
local mixed = (a + b) * inNum0 - 24 / 4
print("inputs", vlen, cren, inarr(1))
-- inarr(i, k) reads a run of slots in one call.  Only a call in the LAST slot
-- expands all of them, so that is where the three values appear; slot 9 is past
-- the end of the array and reads nil, and the middle call is cut to one value
-- exactly as PUC cuts it.
print("inputs2", inarr(9), type(inarr(9)), inarr(1, 3))

-- writable outputs: dup store leaves 7, strings format, array/vec/col
outNum0, outNum0 = 7, 8
outNum1 = sum + fact(4)
outNum2 = vlen * 10 + cren
outNum3 = #t + #s
outStr0 = s .. "|" .. t.name
outStr1 = tostring(mixed) .. "/" .. tostring(t)
-- one call writes a run of adjacent slots (up to 8 values); inarr(i, k) reads
-- them back the same way, but the reference has no inarr so the demo cannot
-- print that one -- tests/cases.py's arr-multi-read is where it is checked
outarr(1, sum, fact(3), #t)
outarr(62, -1, -2, -3)
setvec(invecx * 2, invecy * 2, invecz * 2)
setcol(incolr, incolg, incolb, 1)
print("outs", outNum0, outNum1)
print("outs2", outStr0, outStr1)
print()
print("check", sum, s, t[5])
return "done-" .. sum
