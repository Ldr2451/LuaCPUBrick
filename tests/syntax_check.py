"""Parser stress: nesting and call positions, diffed against real Lua.

Every other check asks "does this feature work".  This one asks "does adding a
feature break the constructs around it".  The parser keeps its scratch state
in globals and hands out registers from a bump pointer, so the failures it
produces are always the same shape -- a construct that nests one level deeper,
a call in one more position, a name that collides with an encoding.  Those
show up as a parser error, a wrong value, or a silently clobbered register, and
they used to be found by running the whole suite.  This battery is the fast
net: one chip build, small programs, seconds.

Keep every case small and avoid the string/table libraries here: they prepend
library text and cost a second per program, and the suite covers their
behavior.  What matters here is shape.

  python -u tests/syntax_check.py
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from chipdiff import report
from timing import Elapsed

CASES = [
    # a call in every expression position the parser special-cases
    'local function f(a, b) return a + b end print(f(1, 2), f(f(1, 2), 3))',
    'local function f() return 1, 2 end local a, b, c = f() print(a, b, c)',
    'local function f() return 1, 2 end print((f()))',
    'local function f() return 1, 2 end local t = {f()} print(t[1], t[2])',
    'local function f() return 1, 2 end local t = {0, f()} print(#t, t[1], t[2])',
    'local function f() return 1, 2 end return_unused = f() print(return_unused)',
    'local function f(x) return x end if f(1) == 1 then print("t") end',
    'local function f(x) return x end local t = {} while f(1) < 2 do break end print("w")',
    'local function f(x) return x end for i = f(1), f(3) do print(i) end',
    'local function f(x) return x end repeat local y = f(1) print(y) until y == 1',

    # nesting: a function body inside a loop inside a function, with locals in
    # every level that share names on purpose
    'local function outer(x) local a = x + 1 local function mid(y) local a = y * 2 local function inner(z) local a = z .. "!" return a end return inner(a) end return mid(a) .. "/" .. tostring(outer(1)) end',
    'local t = {} for i = 1, 2 do local function f(x) return x + 1 end t[i] = f(i) end print(t[1], t[2])',
    'local function f(n) if n == 0 then return 0 end local t = {n} return n + f(n - 1) end print(f(3))',
    'local function outer() local a = 1 do local a = 2 do local a = 3 print(a) end print(a) end print(a) end outer()',

    # generic-for and numeric-for mixed, and nested
    'local t = {1, 2, 3} local s = 0 for i = 1, 2 do for _, v in ipairs(t) do s = s + i * v end end print(s)',
    'local a, b = {1, 2}, {10, 20} for _, x in ipairs(a) do for _, y in ipairs(b) do print(x + y) end end',
    'local t = {1, 2, 3} for i, v in ipairs(t) do if i == 2 then break end print(v) end print("done")',

    # method calls and field functions, the newest syntax, in every position
    'M = {} function M.f(x) return x + 1 end print(M.f(1))',
    'M = {} M.g = function(self, x) return x * 2 end print(M:g(3))',
    'M = {} M.h = function(self, a, b) return a - b end print(M:h(9, 4), M.h(M, 1, 1))',
    'M = {} function M:z() return 7 end print(M:z())',
    'M = {} function M.f(x) local function g(y) return y * 2 end return g(x) + g(1) end print(M.f(3))',
    'M = {n = 3} M.add = function(self, x) self.n = self.n + x return self.n end print(M:add(4), M.n)',
    'M = {} M.f = function(x) return x end print(M.f(1) + M.f(2), M.f(M.f(3)))',
    'M = {} M.f = function(x) return x end local t = {M.f(5)} print(t[1])',

    # a call as the last element of every list the parser expands
    'local function f() return 1, 2, 3 end local a, b, c, d = f() print(a, b, c, d)',
    'local function g(...) return ... end print(g(1, 2, 3))',
    'local function g(...) return select("#", ...) end print(g(1, 2, 3), g())',
    'local function f() return 1 end local t = {0, 0, f()} print(#t, t[3])',
    'local function f() return "x", "y" end local t = {f(), "z"} print(#t, t[3])',

    # table constructors, nested, with expressions in the keys
    'local t = {a = 1, ["b"] = 2, [3] = "c", {4, 5}, n = {x = 6}} print(t.a, t.b, t[3], t[4][2], t.n.x)',
    'local t = {} t[1] = {} t[1][2] = {} t[1][2][3] = "deep" print(t[1][2][3])',

    # scratch state must survive a jump into a nested block
    'local x = 1 do local y = 2 do local z = 3 print(x + y + z) end end',
    'local i = 0 while i < 3 do local j = i i = i + 1 if i == 2 then print(j) end end',
    'local n = 0 for i = 1, 3 do if i % 2 == 0 then n = n + i end end print(n)',
    'local f = function() return function(y) return y * 2 end end print(f()(3))',
]

with Elapsed('syntax_check'):
    FAILS = report(CASES, 'syntax_check')
sys.exit(1 if FAILS else 0)
