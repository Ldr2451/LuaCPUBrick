import sys, os
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from chipdiff import report
from timing import Elapsed

CASES = [
    'function f() return 1, 2 end print(f())',
    'function f() return 1 end print(f())',
    'function f() return 1, 2, 3 end print(f())',
    'function f() return 1, 2 end print(9, f())',
    'function f() return 1, 2 end print(f(), 9)',
    'function f() return 1, 2 end print(9, f(), 8)',
    'function f() return 1, 2 end local a = f() print(a)',
    'function f() return 1, 2 end local a, b = f() print(a, b)',
    'function f() return 1, 2 end a, b = f() print(a, b)',
    'function f() return 1, 2, 3 end local a, b, c = f() print(a, b, c)',
    'function f() return 1, 2 end local a, b, c = f() print(a, b, c)',
    'function f() return 1, 2 end print(type(f()))',
    'function f() return 1, 2 end print(#f())',
    'function f() return 1, 2 end return f()',
    'function f() return 1, 2 end print((f()))',
    'function f() return 1, 2 end print(f(), f())',
    'function f() return end print(f())',
    'function f() return 1, 2 end g = f() print(g)',
    'function f() return 1, 2 end print(f() + 0)',
    'function f() return 1, 2 end local t = {f()} print(t[1], t[2])',
    'function f() return 7, 8 end function g() return f() end print(g())',
    'function f() return 1, 2 end print(select and 1 or 2)',
]

with Elapsed('multi_check'):
    FAILS = report(CASES, 'multi_check')
sys.exit(1 if FAILS else 0)
