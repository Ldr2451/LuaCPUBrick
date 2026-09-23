"""Phase test inventory: (name, source, inputs|None, mode[, kw]).
Modes: run (chip log must equal oracle log), reject (chip must
not compile), runtimerr (chip must fail at runtime with err
substring), synfail (both reject, optional errline), haltfail
(both fail, partial log identical), modelio (explicit port/log
expectations). Moved verbatim from the retired Python model;
"reject" was renamed "reject", "runtimerr" was renamed
"runtimerr".
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
TINYLUA = os.path.dirname(HERE)

DEMO_SRC = open(os.path.join(TINYLUA,
                             "demo.lua"), encoding="utf-8").read()
DEMO_KW = {"inarr": [10.0, 20.0, 30.0],
           "sinputs": {0: "foo", 1: "bar"},
           "vec": (1.0, 2.0, 3.0), "col": (0.5, 0.25, 0.125, 1.0)}
DEMO_LOG = ("arith\t2.25\t7.0\n"
            "str\tfoo-bar!\t8\n"
            "cmp\tfalse\ta\nb\n"
            "logic\t2\tdflt\n"
            "logic2\tfalse\tnil\tfunction\n"
            "tab\t3\t2.25\tfoo\n"
            "tab2\t1.0\tyes\t7.0\n"
            "tab3\ttrue\ttrue\n"
            "func\t120\t42\n"
            "func2\t14\t10\n"
            "shadow\tinner\n"
            "sugared\n"
            "grade\tB\n"
            "flow\t55\t2\t1\tsecond\n"
            "inputs\t6.0\t1.875\t10.0\n"
            "inputs2\t30.0\tnil\tnil\n"
            "outs\t7\t79\n"
            "outs2\tfoo-bar!|foo\t21.75/table\n"
            "\n"
            "check\t55\tfoo-bar!\t2.25\n")

TESTS = [
    ("lit-num", "print(3)", None, "run"),
    ("lit-float", "print(3.5)", None, "run"),
    ("lit-exp", "print(1e3, 1.5e-2)", None, "run"),
    ("lit-dot", "print(.5, 5.)", None, "run"),
    ("lit-exp-dot", "print(5.e3, 5.)", None, "run"),
    ("lit-hex", "print(0xff, 0X10, 0xFFFFFFFFFFFFFFFF)", None, "run"),
    ("int-arith", "print(7+8, 7-8, 7*8, -7, 2+2.0, 7/2)", None, "run"),
    ("int-mod", "print(7%3, -7%3, 7%-3, 7.5%2)", None, "run"),
    ("int-eq", "print(1 == 1.0, 1 < 1.5, 2 > 1.9, 0 == false)", None, "run"),
    ("int-wrap", "print(9223372036854775807+1, -(-9223372036854775808))",
     None, "run"),
    ("int-type", "print(type(3), type(3.0), type(3 .. ''))", None, "run"),
    ("int-key", "t = {} t[1] = 'a' print(t[1.0])", None, "run"),
    ("fmt-add", "print(0.1+0.2)", None, "run"),
    ("fmt-div3", "print(1/3)", None, "run"),
    ("fmt-big", "print(2^100, 1e20)", None, "run"),
    ("fmt-div0", "print(1/0, -1/0)", None, "modelio",
     {"expect": {"log": "0.0\t0.0\n"}}),
    ("fmt-nan0", "print(0/0)", None, "modelio",
     {"expect": {"log": "0.0\n"}}),
    ("fmt-mod0", "print(5%0)", None, "modelio",
     {"expect": {"log": "0\n"}}),
    ("fmt-intmil", "print(1000000)", None, "run"),
    ("lit-boolnil", "print(true, false, nil)", None, "run"),
    ("print-empty", "print()", None, "run"),
    ("print-str", "print('hi', \"yo\")", None, "run"),
    ("escapes", "print('a\\nb', 'x\\65y', 'q\\x41', 'e\\\\f')", None, "run"),
    ("concat-num", "print(5 .. 3)", None, "run"),
    ("concat-mixed", "print('n=' .. 42 .. '!')", None, "run"),
    ("concat-right", "print('a' .. 1 .. 2)", None, "run"),
    ("concat-prec", "print('a' .. 1 + 2)", None, "run"),
    ("arith-prec", "print(1+2*3, (2+3)*4)", None, "run"),
    ("arith-unm", "print(- -5, -(2+3))", None, "run"),
    ("arith-pow", "print(2^3^2, -2^2, 2^-2)", None, "run"),
    ("arith-mod", "print(10%3, 10.5%2, 7/2)", None, "run"),
    ("arith-nest", "print((1+2)*(3-4)/2)", None, "run"),
    ("cmp-num", "print(1<2, 2<=2, 3>4, 4>=5)", None, "run"),
    ("cmp-str", "print('a'<'b', '10'<'9')", None, "run"),
    ("cmp-eq", "print(3=='3', nil==nil, 0==false, 1~=2)", None, "run"),
    ("cmp-chain", "print(1<2<3)", None, "synfail"),
    ("logic-vals", "print(1 and 2, nil or 'x', false or 0)", None, "run"),
    ("logic-not", "print(not 0, not nil, not not 5)", None, "run"),
    ("logic-short", "print(true or nil, false and nil)", None, "run"),
    ("if-basic", "if 1<2 then print('y') else print('n') end", None, "run"),
    ("if-elseif", "local x = 5 if x<0 then print('n') "
     "elseif x<10 then print('m') else print('p') end", None, "run"),
    ("if-nested", "if true then if false then print(1) else print(2) end end",
     None, "run"),
    ("if-nilcond", "if nil then print(1) else print(0) end", None, "run"),
    ("while-sum", "local s = 0 local i = 1 while i<=10 do "
     "s = s+i i = i+1 end print(s)", None, "run"),
    ("while-break", "local i = 0 while true do i = i+1 "
     "if i>=3 then break end end print(i)", None, "run"),
    ("do-scope", "do local x = 1 print(x) end print(x)", None, "run"),
    ("shadow", "local x = 1 do local x = 2 print(x) end print(x)", None,
     "run"),
    ("local-multi", "local a,b = 1 print(a, b)", None, "run"),
    ("local-none", "local q print(q)", None, "run"),
    ("assign-multi", "a, b = 1, 2 print(a, b)", None, "run"),
    ("assign-swap", "a, b = 10, 20 a, b = b, a print(a, b)", None, "run"),
    ("assign-short", "a, b, c = 1 print(a, b, c)", None, "run"),
    ("global-write", "g = 41 g = g+1 print(g)", None, "run"),
    ("inputs-sum", "print(inNum0+inNum1+inNum2+inNum3)",
     [1, 2, 3, 4], "run"),
    ("inputs-each", "print(inNum0, inNum1, inNum2, inNum3, inStr0, inStr1, invecx, invecy, "
     "invecz, incolr, incolg, incolb, incola)",
     [8, 7, 6, 5], "run",
     {"sinputs": {0: "a", 1: "b"}, "vec": (1, 2, 3),
      "col": (0.5, 0.25, 0.125, 1)}),
    ("inputs-expr", "print(inNum0*2, inStr0 .. '!', inNum3%inNum1)",
     [10, 3, 0, 7], "run", {"sinputs": {0: "hey"}}),
    ("inputs-vec", "print(invecx+invecy+invecz)", None, "run",
     {"vec": (1.5, 2.5, 3.0)}),
    ("inputs-col", "print(incolr, incolg, incolb, incola)", None, "run",
     {"col": (1, 0.5, 0.25, 1)}),
    ("io-setvec", "setvec(1, 2, 3)", None, "modelio",
     {"expect": {"outVec": [1.0, 2.0, 3.0]}}),
    ("io-setvec-partial", "setvec(inNum0)", [9], "modelio",
     {"expect": {"outVec": [9.0, 0.0, 0.0]}}),
    ("io-setcol", "setcol(1, 0.5, 0.25, 1)", None, "modelio",
     {"expect": {"outCol": [1.0, 0.5, 0.25, 1.0]}}),
    ("io-strings", "print(inStr0 .. inStr1)", None, "run",
     {"sinputs": {0: "foo", 1: "bar"}}),
    ("io-clock", "local a = clock() local b = clock() "
     "print(type(a), b > a)", None, "modelio",
     {"expect": {"log": "number\ttrue\n"}}),
    ("func-basic", "function add(a, b) return a+b end print(add(2, 3))",
     None, "run"),
    ("func-missing", "function f(a, b) print(a, b) end f(1)", None, "run"),
    ("func-extra", "function f(a) return a end print(f(1, 2, 3))", None,
     "run"),
    ("func-bare-ret", "function f() return end print(f())", None, "run"),
    ("func-no-ret", "function f() end print(f())", None, "run"),
    ("func-fact", "function f(n) if n<=1 then return 1 else "
     "return n*f(n-1) end end print(f(10))", None, "run"),
    ("func-fib", "function f(n) if n<2 then return n else "
     "return f(n-1)+f(n-2) end end print(f(15))", None, "run"),
    ("func-localrec", "local function f(n) if n<=0 then return 0 else "
     "return 1+f(n-1) end end print(f(5))", None, "run"),
    ("func-anon", "local sq = function(x) return x*x end print(sq(9))",
     None, "run"),
    ("func-higher", "function ap(f, x) return f(x) end "
     "function inc(x) return x+1 end print(ap(inc, 41))", None, "run"),
    ("func-retfunc", "function mk() return function(x) return x+1 end end "
     "print(mk()(5))", None, "run"),
    ("func-mutual", "function f() return g() end "
     "function g() return 7 end print(f())", None, "run"),
    ("func-eq", "function f() end print(f==f)", None, "run"),
    ("func-stmt-call", "function f(a) print(a+1) end f(41)", None, "run"),
    ("ret-void-mid", "function g() end print(g(), 1)", None, "run"),
    ("ret-tail", "function g() return 41 end function f() return g() end "
     "print(f())", None, "run"),
    ("ret-tail-void", "function g() end function f() return g() end "
     "print(f())", None, "run"),
    ("void-stmt", "function v() end v() print('ok')", None, "run"),
    ("void-cond", "function v() end if v() then print(1) else print(0) end",
     None, "run"),
    ("void-arith", "function v() end print('b') print(v()+1)", None,
     "haltfail"),
    ("void-assign", "function v() end local x = v() print(x)", None, "run"),
    ("multi-args", "function id(a) return a end print(id(1), id(2))", None,
     "run"),
    ("ret-multi-reject", "function f() return 1, 2 end print(f())", None,
     "reject"),
    ("type-all", "print(type(1), type('s'), type(true), type(nil), "
     "type(print))", None, "run"),
    ("tostring-all", "print(tostring(2.5), tostring('s'), "
     "tostring(false), tostring(nil))", None, "run"),
    ("print-shadow", "print = 5 print(print)", None, "haltfail"),
    ("str-call-sugar", "print 'hi'", None, "run"),
    ("sugar-chain", "function f() return print end f()'hi'", None, "run"),
    ("group-chain", "function f() return print end (f())('hi')", None,
     "run"),
    ("anon-call", "print((function() return 41 end)())", None, "run"),
    ("semi", "local a = 1; print(a);;", None, "run"),
    ("nest-call", "print(tostring(type(1)))", None, "run"),
    ("deep-expr", "print(1+2*3-4/2%3^2)", None, "run"),
    ("or-chain", "print(nil or false or 0 or 'd')", None, "run"),
    ("and-chain", "print(true and 1 and 2)", None, "run"),
    ("not-chain", "print(not not 5, not '')", None, "run"),
    ("while-zero", "while false do print(1) end print(0)", None, "run"),
    ("if-noelse", "if false then print(1) end print(2)", None, "run"),
    ("if-ret-live", "if false then return 1 end print(10)", None, "run"),
    ("if-ret-all", "if true then return 1 else return 2 end", None, "run"),
    ("while-ret-live", "while false do return 1 end print(2)", None,
     "run"),
    ("str-esc-tab", "print('a\\tb')", None, "run"),
    ("str-empty", "print('')", None, "run"),
    ("concat-empty", "print('' .. '' .. 1)", None, "run"),
    ("cmp-func", "print(print==print, print~=type)", None, "run"),
    ("cmp-mixed", "print(1==true, 'a'==1, nil~=false)", None, "run"),
    ("neg-pow", "local x = 2 print(-x^2)", None, "run"),
    ("pow-neg-exp", "print(2^-2)", None, "run"),
    ("mod-float", "print(7.5%2)", None, "run"),
    ("long-sum", "local s = 0 local i = 1 while i<=100000 do "
     "s = s+i i = i+1 end print(s)", None, "run"),
    ("stress-instr", "STRESS", None, "run"),
    ("over-cap", "OVERCAP", None, "reject"),
    # error-class tests
    ("syn-unterm", "print('abc)", None, "synfail"),
    ("syn-end", "print(1) end", None, "synfail"),
    ("syn-numconcat", "print(5..3)", None, "synfail"),
    ("syn-locnum", "local 5 = 1", None, "synfail"),
    ("syn-anonstmt", "function() end", None, "synfail"),
    ("syn-break", "break", None, "synfail"),
    ("run-callstr", "print('before') ('x')()", None, "haltfail"),
    ("run-addstr", "print('before') print(1+'x')", None, "haltfail"),
    ("run-ltstr", "print('before') print('a'<1)", None, "haltfail"),
    ("run-tostring0", "print('before') print(tostring())", None,
     "haltfail"),
    ("run-callnil", "print('before') f()", None, "haltfail"),
    ("run-negstr", "print('before') print(-'x')", None, "haltfail"),
    ("upvalue-read", "local x = 5 function f() return x end print(f())",
     None, "reject"),
    ("callarg-temp", "local s = 'abcdef' print('x', s, #s, s .. '!')",
     None, "run"),
    ("callarg-binop", "local a = 6 local b = 7 print(a + b, a * b, -a)",
     None, "run"),
    ("func-twice", "function a() return 1 end function b() return 2 end "
     "print(a(), b(), a() + b())", None, "run"),
    ("func-inarr", "function g() return inarr(1) + inarr(2) end "
     "print(g(), g())", None, "modelio",
     {"inarr": [3.0, 4.0], "expect": {"log": "7.0\t7.0\n"}}),
    ("func-outarr", "function w(v) outarr(1, v * 2) end w(5) w(6)",
     None, "modelio",
     {"expect": {"outArr": [12.0] + [0.0] * 63, "log": ""}}),
    ("func-main-first", "print('start') function h(x) return x + 1 end "
     "print(h(41))", None, "run"),
    ("demo", "DEMO", [3, 1, 4, 1.5], "modelio",
     {"expect": {"log": DEMO_LOG,
                 "outGlobals": [7.0, 79.0, 61.875, 11.0,
                                "foo-bar!|foo", "21.75/table", 0],
                 "outArr": [55.0, 6.0] + [0.0] * 61 + [-1.0],
                 "outVec": [2.0, 4.0, 6.0],
                 "outCol": [0.5, 0.25, 0.125, 1.0],
                 "result": "done-55"}}),
    # regression: the original progOk bug (hello world must compile)
    ("hello", "print(\"Hello, World!\")", None, "run"),
    ("fmt-int", "print(7)", None, "run"),
    ("str-lt-next", "x = 5 if 'a' < 'b' then print(x+1) end print(x+2)",
     None, "run"),
    ("str-le-next", "x = 5 if 'a' <= 'a' then print(x+1) end print(x+2)",
     None, "run"),
    # tables
     ("tab-empty", "t = {} print(type(t), #t)", None, "run"),
    ("tab-array", "t = {10, 20, 30} print(t[1], t[2], t[3], #t)", None,
     "run"),
    ("tab-hash", "t = {x = 1, y = 2} print(t.x, t['y'])", None, "run"),
    ("tab-mixed", "t = {1, 'a', x = true} print(t[1], t[2], t.x, #t)",
     None, "run"),
    ("tab-trailing", "t = {1, 2,} u = {3; 4;} print(#t, u[2])", None,
     "run"),
    ("tab-nested", "t = {{1, 2}, {3}} print(t[1][2], t[2][1])", None,
     "run"),
    ("tab-index-expr", "t = {[1+1] = 'x', [10] = 'y'} print(t[2], t[10])",
     None, "run"),
    ("tab-ctor-bracket", "t = {[10]='x', [1+1]='y'} print(t[10], t[2])",
     None, "run"),
    ("tab-append", "t = {} t[#t+1] = 'a' t[#t+1] = 'b' "
     "print(#t, t[1], t[2])", None, "run"),
    ("tab-del", "t = {1,2,3} t[2] = nil print(t[1], t[2], t[3], #t)",
     None, "run"),
     ("tab-len-str", "print(#'hello', #{1,2,3})", None, "run"),
    ("tab-eq", "a = {} print(a == a, a == {})", None, "run"),
    ("tab-eq-copy", "a = {} b = a print(a == b, a ~= b)", None, "run"),
    ("tab-func", "t = {f = function(x) return x*2 end} print(t.f(21))",
     None, "run"),
    ("tab-in-func", "function s(t) return t[1]+t[2] end print(s({3,4}))",
     None, "run"),
    ("tab-mutate", "function add(t, v) t[#t+1] = v end t = {} add(t, 9) "
     "print(t[1])", None, "run"),
    ("tab-bool-key", "t = {} t[true] = 1 print(t[true], t[false])", None,
     "run"),
    ("tab-strnum", "t = {} t[1] = 'a' t['1'] = 'b' print(t[1], t['1'])",
     None, "run"),
    ("tab-swap-fields", "t = {1, 2} t[1], t[2] = t[2], t[1] "
     "print(t[1], t[2])", None, "run"),
    ("tab-dup-field-rtl", "t = {} t[1], t[1] = 1, 2 print(t[1])", None,
     "run"),
    ("tab-key-func", "t = {} k = {} t[k] = 1 print(t[k])", None, "run"),
    ("tab-nested-assign", "t = {a = {b = 1}} t.a.b = 2 print(t.a.b)",
     None, "run"),
    ("tab-chain-store", "t = {a = {}} t.a[1] = 'x' print(t.a[1])", None,
     "run"),
    ("tab-paren-index", "print(({5, 6})[2])", None, "run"),
    ("tab-tostring", "print(type({}), tostring({1}))", None, "modelio",
     {"expect": {"log": "table\ttable\n"}}),
    ("tab-missing", "t = {} print(t.nope, t[99])", None, "run"),
    ("tab-speckeys", "t = {} t['a#b'] = 1 t['a$b'] = 2 "
     "t['k@v'] = 3 t['x:y'] = 4 "
     "print(t['a#b'], t['a$b'], t['k@v'], t['x:y'])", None, "run"),
    ("tab-getnil-diff", "t = {} print(t[nil])", None, "modelio",
     {"expect": {"log": "nil\n"}}),
    ("tab-set-nonint", "t = {} t[1.5] = 1", None, "runtimerr",
     {"expect": {"err": "non-integer number keys"}}),
    ("tab-set-nil-key", "t = {} t[nil] = 1", None, "haltfail"),
    ("tab-idx-nontable", "x = 5 print(x[1])", None, "haltfail"),
    ("tab-len-nontable", "print(#5)", None, "haltfail"),
    ("tab-toomany", "t = {} i = 0 while i < 65 do t[#t+1] = {} "
     "i = i+1 end", None, "runtimerr",
     {"expect": {"err": "too many tables"}}),
    ("tab-oom", "t = {} i = 0 while i < 513 do t[#t+1] = i i = i+1 end",
     None, "runtimerr", {"expect": {"err": "out of table memory"}}),
    ("tab-bubble", "t = {5, 3, 8, 1, 9, 2, 7, 4} i = 1 "
     "while i <= 8 do j = 1 "
     "while j <= 8 - i do "
     "if t[j] > t[j+1] then t[j], t[j+1] = t[j+1], t[j] end "
     "j = j + 1 end i = i + 1 end "
     "print(t[1], t[2], t[3], t[4], t[5], t[6], t[7], t[8])", None,
     "run"),
    # right-to-left duplicate stores (real Lua order)
    ("assign-dup", "a, a = 1, 2 print(a)", None, "run"),
    ("assign-dup3", "a, b, a = 1, 2, 3 print(a, b)", None, "run"),
    ("assign-duplocal", "local a, a = 1, 2 print(a)", None, "run"),
    ("assign-mixed-reject", "a, t.x = 1, 2", None, "reject"),
    # log cap behavior
    ("log-many", "i = 1 while i <= 40 do print(i) i = i + 1 end", None,
     "run"),
    ("log-wide", "print('" + "y" * 100 + "')", None, "modelio",
     {"expect": {"log": "y" * 63 + "\n"}}),
    # array ports
    ("arr-read", "print(inarr(1), inarr(2), inarr(3))", None, "modelio",
     {"inarr": [1.5, 2.5], "expect": {"log": "1.5\t2.5\tnil\n"}}),
    ("arr-write", "outarr(1, 9) outarr(2, inarr(1))", None, "modelio",
     {"inarr": [5.0],
      "expect": {"outArr": [9.0, 5.0] + [0.0] * 62, "log": ""}}),
    ("arr-oob-read", "print(inarr(0), inarr(-1), inarr(1.5), inarr('x'))",
     None, "modelio",
     {"inarr": [7.0], "expect": {"log": "nil\tnil\tnil\tnil\n"}}),
    ("arr-oob-write", "outarr(0, 1)", None, "runtimerr",
     {"expect": {"err": "array index out of range"}}),
    ("arr-oob-write2", "outarr(65, 1)", None, "runtimerr",
     {"expect": {"err": "array index out of range"}}),
    ("arr-badval", "outarr(1, 'x')", None, "runtimerr",
     {"expect": {"err": "array element must be a number"}}),
    ("arr-badval2", "outarr(1, {})", None, "runtimerr",
     {"expect": {"err": "array element must be a number"}}),
    ("arr-nil-write", "outarr(1, nil)", None, "modelio",
     {"expect": {"outArr": [0.0] * 64}}),
    ("arr-missing", "print(inarr())", None, "modelio",
     {"expect": {"log": "nil\n"}}),
    # writable output globals
    ("out-nums", "outNum0 = 1 outNum1 = 2.5 outNum2 = true outNum3 = nil", None,
     "modelio",
     {"expect": {"outGlobals": [1.0, 2.5, 1.0, 0.0, "", "", 0]}}),
    ("out-strs", "outStr0 = 'hi' outStr1 = 3", None, "modelio",
     {"expect": {"outGlobals": [0.0, 0.0, 0.0, 0.0, "hi", "3", 0]}}),
    ("io-int", "outInt0 = inInt0 * 2 + 1 print(outInt0)", None, "modelio",
     {"inint": 5,
      "expect": {"log": "11\n",
                 "outGlobals": [0.0, 0.0, 0.0, 0.0, "", "", 11]}}),
    ("io-int-coerce", "outInt0 = 7.0 print(outInt0, type(outInt0))", None,
     "modelio", {"expect": {"log": "7\tnumber\n"}}),
    ("io-int-bad", "outInt0 = 7.5", None, "runtimerr",
     {"expect": {"err": "cannot convert"}}),
    ("inputs-int", "print(inInt0 + 1)", None, "run", {"inint": 41}),
    ("out-readback", "outNum0 = 5 print(outNum0 + 1)", None, "run"),
    ("out-badnum", "outNum0 = 'x'", None, "runtimerr",
     {"expect": {"err": "cannot convert"}}),
    ("out-badnum2", "outNum1 = {}", None, "runtimerr",
     {"expect": {"err": "cannot convert"}}),
    ("out-nil-str", "outStr0 = nil print(outStr0 == nil)", None, "run"),
    # line numbers on compile failure
    ("errline-stmt", "print(1)\nprint(2)\nend\n", None, "synfail",
     {"errline": 3}),
    ("errline-expr", "local x = 1\nprint(x + )\n", None, "synfail",
     {"errline": 2}),
    ("errline-lex", "print('a')\nprint('b)\n", None, "synfail",
     {"errline": 2}),
    ("errline-deep", "a = 1\nb = 2\nc = 3\nd = 4\nif then end\n", None,
     "synfail", {"errline": 5}),
    # numeric for loops
    ("for-int", "for i=1,3 do print(i) end", None, "run"),
    ("for-int-eq", "for i=1,1 do print(i) end", None, "run"),
    ("for-int-empty", "for i=3,1 do print(i) end", None, "run"),
    ("for-int-sum", "local s=0 for i=1,3 do s=s+i end print(s)",
     None, "run"),
    ("for-int-step", "for i=1,3,2 do print(i) end", None, "run"),
    ("for-float", "for i=1.0,2.0 do print(i) end", None, "run"),
    ("for-float-step", "for i=1,2.5,0.5 do print(i) end", None, "run"),
    ("for-zero-step", "for i=1,3,0 do print(i) end", None, "haltfail"),
    # repeat-until
    ("repeat-basic", "local i=0 repeat i=i+1 until i>=3 print(i)",
     None, "run"),
    ("repeat-count", "local s=0 repeat s=s+1 until s>=3 print(s)",
     None, "run"),
    ("repeat-true", "repeat print('a') until true", None, "run"),
    ("repeat-first", "repeat until true; print('done')", None, "run"),
    # floor division
    ("idiv-int", "print(7//2)", None, "run"),
    ("idiv-neg", "print(-7//2)", None, "run"),
    ("idiv-float", "print(7.5//2)", None, "run"),
    ("idiv-neg-float", "print(-7.5//2)", None, "run"),
    # bitwise
    ("bit-and", "print(5&3)", None, "run"),
    ("bit-or", "print(5|3)", None, "run"),
    ("bit-xor", "print(5~3)", None, "run"),
    ("bit-not", "print(~0xFF)", None, "run"),
    ("bit-shl", "print(1<<3)", None, "run"),
    ("bit-shr", "print(16>>2)", None, "run"),
    ("bit-mix", "print(5+~3)", None, "run"),
    ("bit-prec", "print(1&2|4)", None, "run"),
    ("bit-notneg", "print(~-5)", None, "run"),
    # loop break / nesting / shadowing (regression net for for-stack,
    # scope-save and break-patch fixes)
    ("for-break", "for i=1,3 do if i==2 then break end print(i) end",
     None, "run"),
    ("for-break-all", "for i=1,3 do break end print('done')", None, "run"),
    ("for-nest", "for i=1,2 do for j=1,2 do print(i*10+j) end end",
     None, "run"),
    ("for-multi", "for i=1,2 do print(i) print(i+1) end", None, "run"),
    ("for-shadow", "local i=99 for i=1,2 do print(i) end print(i)",
     None, "run"),
    ("for-expr-bounds", "local a=2 local b=4 for i=a,b do print(i) end",
     None, "run"),
    ("for-ctrl-assign", "for i=1,2 do i=3 end", None, "reject"),
    ("repeat-break", "local i=0 repeat i=i+1 if i==2 then break end "
     "until i>=5 print(i)", None, "run"),
    ("repeat-nest", "local i=0 repeat local j=0 repeat j=j+1 until j>=2 "
     "i=i+1 until i>=2 print(i)", None, "run"),
    ("until-norepeat", "until true", None, "synfail", {"errline": 1}),
]


def build_stress():
    lines = []
    for k in range(30):
        lines.append(f"v{k} = {k}*2+1")
    lines.append("print(" + ", ".join(f"v{k}" for k in range(0, 30, 10)) +
                 ")")
    return "\n".join(lines) + "\n"


def build_overcap():
    return "\n".join(
        "v0 = %s" % "+".join(str((k + j) % 9 + 1) for j in range(8))
        for k in range(40)) + "\n"
