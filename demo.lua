-- Tiny Lua full-feature smoke test. Paste into `program`, set `run` high.
-- Inputs:  inNum0=3 inNum1=1 inNum2=4 inNum3=1.5
--          inStr0="foo" inStr1="bar" inVec=(1,2,3)
--          inCol=(0.5,0.25,0.125,1) inArr=[10,20,30]
-- Every line below exercises a feature; the ports at the end depend on all
-- of them, so any mismatch means something broke. Expected values are in
-- the DEMO_EXPECT comment block at the bottom (verified against Lua 5.5).

-- arithmetic, precedence, unary minus, power, modulo, concat
local a = (inNum0 + inNum1 * inNum2 - inNum3 / 2) % 4
local b = 2 ^ 3 ^ 1 + -inNum1
print("arith", a, b)

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

-- functions: named recursion, anonymous, higher-order, extra args
local function fact(n)
  if n <= 1 then return 1 else return n * fact(n - 1) end
end
local dbl = function(x) return x * 2 end
local function apply(f, x) return f(x) end
print("func", fact(5), apply(dbl, 21))
print("func2", t.fn(7), dbl(5, 99))

-- shadowing, elseif, call-sugar statement
do local tmp = "inner" print("shadow", tmp) end
local grade = "F"
if a > 3 then grade = "A" elseif a > 2 then grade = "B" else grade = "C" end
print 'sugared'
print("grade", grade)

-- loops, break inside if, parallel assign, swap, right-to-left dup
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
print("inputs2", inarr(3), inarr(9), type(inarr(9)))

-- writable outputs: dup store leaves 7, strings format, array/vec/col
outNum0, outNum0 = 7, 8
outNum1 = sum + fact(4)
outNum2 = vlen * 10 + cren
outNum3 = #t + #s
outStr0 = s .. "|" .. t.name
outStr1 = tostring(mixed) .. "/" .. tostring(t)
outarr(1, sum)
outarr(2, fact(3))
outarr(64, -1)
setvec(invecx * 2, invecy * 2, invecz * 2)
setcol(incolr, incolg, incolb, 1)
print("outs", outNum0, outNum1)
print("outs2", outStr0, outStr1)
print()
print("check", sum, s, t[5])
return "done-" .. sum

-- DEMO_EXPECT (model log + ports for the inputs above; `log` port shows
-- the log, `result` shows the return, everything else as labelled):
-- log:
--   arith  2.25  7.0
--   str  foo-bar!  8.0
--   cmp  false  a
--   b
--   logic  2.0  dflt
--   logic2  false  nil  function
--   tab  3.0  2.25  foo
--   tab2  1.0  yes  7.0
--   tab3  true  true
--   func  120.0  42.0
--   func2  14.0  10.0
--   shadow  inner
--   sugared
--   grade  B
--   flow  55.0  2.0  1.0  second
--   inputs  6.0  1.875  10.0
--   inputs2  30.0  nil  nil
--   outs  7.0  79.0
--   outs2  foo-bar!|foo  21.75/table
--   (empty line from print())
--   check  55.0  foo-bar!  2.25
--   (values in one line are tab-separated; outNum0 reads 7.0: the duplicate
--   store kept the FIRST value, i.e. right-to-left assignment works)
-- outNum0..3 = 7.0, 79.0, 61.875, 11.0
-- outStr0 = "foo-bar!|foo", outStr1 = "21.75/table"
-- outArr[1] = 55.0, outArr[2] = 6.0, outArr[64] = -1.0, rest 0.0
-- outVec = (2, 4, 6), outCol = (0.5, 0.25, 0.125, 1)
-- result = "done-55", err = "", progOk = true, busy = false (when done)
