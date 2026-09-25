import sys, os
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from chipdiff import report
from timing import Elapsed

CASES = [
    # --- varargs ---
    'function f(...) print(...) end f(1, 2, 3)',
    'function f(...) print(...) end f()',
    'function f(...) print(select("#", ...)) end f(1, 2, 3)',
    'function f(...) local a, b = ... print(a, b) end f(7, 8)',
    'function f(...) return ... end print(f(1, 2, 3))',
    'function f(...) local t = {...} print(#t, t[1], t[3]) end f(4, 5, 6)',
    'function f(a, ...) print(a, ...) end f(1, 2, 3)',
    'function f(a, ...) print(a, select("#", ...)) end f(1, 2, 3)',
    'function f(...) print((...)) end f(9)',
    'function outer() return 1, 2 end function f(...) print(...) end f(outer())',
    'function f(...) for i = 1, select("#", ...) do io.write(tostring((select(i, ...)))) end end f(1,2,3)',
    # --- select ---
    'print(select("#", 1, 2, 3))',
    'print(select(2, "a", "b", "c"))',
    'print(select(-1, "a", "b", "c"))',
    'function f(...) return select("#", ...) end print(f(1,2,3,4,5))',
    'function f(...) return select(2, ...) end print(f("x","y","z"))',
]

with Elapsed('vararg_check'):
    FAILS = report(CASES, 'vararg_check')
sys.exit(1 if FAILS else 0)
