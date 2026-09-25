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
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TINYLUA = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import spec

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
            "outs2\tfoo-bar!|foo\t21.75/table: 0x0\n"
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
    ("int-wrap", "print(math.maxinteger + 1 == math.mininteger, "
     "math.mininteger // -1 == math.mininteger, "
     "-math.mininteger == math.mininteger, math.type(math.maxinteger + 1))",
     None, "run"),
    ("int-for-wrap", "local a = 0 for i = math.maxinteger, math.maxinteger "
     "do a = a + 1 end local b = 0 for i = math.mininteger, "
     "math.mininteger, -1 do b = b + 1 end print(a, b)", None, "run"),
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
    # clock() is the server uptime, which the sim models as tick * 0.01 -- it
    # advances, but not between two calls that sit next to each other in one
    # statement.  The two calls are therefore a tick apart: a small spin loop
    # between them is what makes b > a true, and that is also the only way this
    # case can say anything about the gate at all (a single clock() read is
    # checked by type below).
    ("io-clock", "local a = clock() local i = 0 while i < 4 do i = i + 1 end "
     "local b = clock() print(type(a), b > a)", None, "modelio",
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
     "return f(n-1)+f(n-2) end end print(f(12))", None, "run"),
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
    ("ret-multi", "function f() return 1, 2 end print(f())", None, "run"),
    ("ret-multi3", "function f() return 1, 2, 3 end print(f())", None, "run"),
    ("ret-multi-mid", "function f() return 1, 2 end print(9, f(), 8)", None,
     "run"),
    ("ret-multi-last", "function f() return 1, 2 end print(f(), 9)", None,
     "run"),
    ("ret-multi-local", "function f() return 1, 2 end local a, b = f() "
     "print(a, b)", None, "run"),
    ("ret-multi-local3", "function f() return 1, 2 end local a, b, c = f() "
     "print(a, b, c)", None, "run"),
    ("ret-multi-assign", "function f() return 1, 2 end a, b = f() "
     "print(a, b)", None, "run"),
    ("ret-multi-fwd", "function f() return 7, 8 end function g() return f() "
     "end print(g())", None, "run"),
    ("ret-multi-table", "function f() return 1, 2 end local t = {f()} "
     "print(t[1], t[2])", None, "run"),
    ("ret-multi-paren", "function f() return 1, 2 end print((f()))", None,
     "run"),
    ("ret-multi-binop", "function f() return 1, 2 end print(f() + 0)", None,
     "run"),
    ("ret-multi-trunc", "function f() return 1, 2 end local a = f() "
     "print(a)", None, "run"),
    # varargs
    ("va-print", "function f(...) print(...) end f(1, 2, 3)", None, "run"),
    ("va-empty", "function f(...) print(...) end f()", None, "run"),
    ("va-count", "function f(...) print(select('#', ...)) end f(1, 2, 3)",
     None, "run"),
    ("va-local", "function f(...) local a, b = ... print(a, b) end f(7, 8)",
     None, "run"),
    ("va-return", "function f(...) return ... end print(f(1, 2, 3))", None,
     "run"),
    ("va-table", "function f(...) local t = {...} print(#t, t[1], t[3]) end "
     "f(4, 5, 6)", None, "run"),
    ("va-named", "function f(a, ...) print(a, ...) end f(1, 2, 3)", None,
     "run"),
    ("va-paren", "function f(...) print((...)) end f(9)", None, "run"),
    ("va-nested", "function outer() return 1, 2 end function f(...) "
     "print(...) end f(outer())", None, "run"),
    ("va-reject", "print(...)", None, "reject"),
    # select
    ("sel-count", "print(select('#', 1, 2, 3))", None, "run"),
    ("sel-index", "print(select(2, 'a', 'b', 'c'))", None, "run"),
    ("sel-neg", "print(select(-1, 'a', 'b', 'c'))", None, "run"),
    ("sel-va", "function f(...) return select(2, ...) end "
     "print(f('x', 'y', 'z'))", None, "run"),
    ("sel-oob", "print(select(0, 1, 2))", None, "runtimerr",
     {"expect": {"err": "index out of range"}}),
    ("type-all", "print(type(1), type('s'), type(true), type(nil), "
     "type(print))", None, "run"),    ("tostring-all", "print(tostring(2.5), tostring('s'), "
     "tostring(false), tostring(nil))", None, "run"),
    ("print-shadow", "print = 5 print(print)", None, "haltfail"),
    ("str-call-sugar", "print 'hi'", None, "run"),
    # iteration library (prepended Lua source over the next() primitive)
    ("iter-ipairs", "local t = {10, 20, 30} local s = 0 for i, v in ipairs(t) "
     "do s = s + v end print(s, i)", None, "run"),
    ("iter-pairs", "local t = {a=1, b=2, c=3} local s = 0 for k, v in pairs(t) "
     "do s = s + v end print(s)", None, "run"),
    # PUC walks the array part in index order, but string keys come out in hash
    # order, which is unspecified -- compare those as a set instead.
    ("iter-order", "local t = {30, 10, 20} local o = '' for i, v in ipairs(t) "
     "do o = o .. i .. ':' .. v .. ' ' end print(o)", None, "run"),
    ("iter-keys-set", "local t = {} t.z = 1 t.a = 2 t.m = 3 local k = {} "
     "for x in next, t do k[#k+1] = x end table.sort(k) local s = '' "
     "for i = 1, #k do s = s .. k[i] end print(s)", None, "run"),
    ("iter-holes", "local t = {1, 2, nil, 4} local n = 0 for _ in ipairs(t) do "
     "n = n + 1 end print(n)", None, "run"),
    ("iter-delete", "local t = {1,2,3} for k in next, t do t[k] = nil end "
     "local n = 0 for _ in next, t do n = n + 1 end print(n)", None, "run"),
    ("iter-nested", "local s = '' for i, v in ipairs({1,2}) do for j, w in "
     "ipairs({10,20}) do s = s .. (i*j) .. ':' .. (v+w) .. ' ' end end print(s)",
     None, "run"),
    ("iter-break", "local t = {1,2,3} for _, v in ipairs(t) do if v == 2 then "
     "break end print(v) end print('done')", None, "run"),
    # string library
    ("str-len", "print(#'hello', string.len('hello'))", None, "run"),
    ("str-upper", "print(string.upper('aBc1'), string.lower('AbC1'))", None,
     "run"),
    ("str-sub", "local s = 'hello' print(string.sub(s, 2, 3), string.sub(s, -3), "
     "string.sub(s, 2), string.sub(s, 0), string.sub(s, 4, 2))", None, "run"),
    ("str-byte", "print(string.byte('A'), string.byte('ABC', 2), "
     "string.byte('ABC', 1, 3))", None, "run"),
    ("str-char", "print(string.char(72, 105, 33))", None, "run"),
    ("str-rep", "print(string.rep('ab', 3), string.rep('ab', 3, '-'), "
     "string.rep('ab', 0), string.rep('x', 1))", None, "run"),
    ("str-rev", "print(string.reverse('abc'), string.reverse(''))", None,
     "run"),
    ("str-empty-sub", "print('[' .. string.sub('abc', 9) .. ']')", None, "run"),
    # method syntax: a call on a string reaches the string library the way
    # PUC's string metatable does, and on a table it is obj.m(obj, args)
    ("str-method", "local s = 'hello' print(s:upper(), s:sub(2, 3), s:len(), "
     "s:byte(1), s:rep(2), s:reverse())", None, "run"),
    ("str-method-lit", "print(('ab'):upper(), ('ab'):rep(3), ('abc'):sub(2))",
     None, "run"),
    ("meth-call", "M = {} M.g = function(self, a, b) return a * b end "
     "print(M:g(3, 4), M.g(M, 3, 4))", None, "run"),
    ("meth-def", "M = {} function M:f(x) return x + 1 end "
     "function M:g(a, b) return a - b end print(M:f(1), M:g(9, 4), M.f(M, 1))",
     None, "run"),
    ("meth-self", "M = {n = 1} function M:add(x) self.n = self.n + x return "
     "self.n end print(M:add(4), M:add(1), M.n)", None, "run"),
    ("meth-nested", "M = {} function M:outer() local t = 0 function M:inner(v) "
     "return v * 2 end return M end print(M:outer())", None, "run"),
    ("meth-recv-expr", "M = {f = function(self, x) return x end} "
     "print(({f = M.f}):f(1), M.f(M, 2))", None, "run"),
    ("meth-two-calls", "local s = 'ab' print(s:upper(), s:upper(), s:len())",
     None, "run"),
    # string.format is a gate builtin (_fmt), a micro-step like next(); these are
    # the shapes that were each wrong at least once while it was built
    ("fmt-int", "print(string.format('%d', 42), string.format('%d', -42), "
     "string.format('%i %u', 7, 8))", None, "run"),
    ("fmt-int-zero", "print(string.format('%d', 0), string.format('%.3d', 5), "
     "string.format('%.0d', 0))", None, "run"),
    ("fmt-str", "print(string.format('%s|%s', 'a', 2), string.format('%s', 1.5), "
     "string.format('%s %s', true, nil))", None, "run"),
    ("fmt-str-prec", "print(string.format('%.2s', 'abcdef'), "
     "string.format('[%.0s]', 'abc'))", None, "run"),
    ("fmt-pct", "print(string.format('%%'), string.format('%d%%', 50), "
     "string.format('a%%b%sc', 'X'))", None, "run"),
    ("fmt-width", "print(string.format('[%5d]', 42), string.format('%-5d|', 42), "
     "string.format('%05d', 42))", None, "run"),
    ("fmt-width-neg", "print(string.format('%6d|', -42), "
     "string.format('%-06d|', -42), string.format('%+d % d', 7, 7))", None, "run"),
    ("fmt-q", "print(string.format('%q', 'a' .. string.char(34) .. 'b'), "
     "string.format('%q', ''), string.format('%q %q', 'x', true))", None, "run"),
    ("fmt-q-ctl", "local c = string.char print(string.format('%q', "
     "c(9) .. c(10) .. c(0) .. c(127)))", None, "run"),
    ("fmt-many", "print(string.format('%s=%d (%s)', 'n', 12, 'x'), "
     "string.format('%d %s %d', 1, 'two', 3))", None, "run"),
    ("fmt-num-fmt", "print(string.format(5), string.format('%d', 3.0), "
     "string.format('%s', print))", None, "run"),
    # %x %X %o: a negative value is its 64-bit two's complement, and 64 bits is
    # 16 hex digits but 21-and-a-bit in octal
    ("fmt-hex", "print(string.format('%x', 255), string.format('%X', 26), "
     "string.format('%o', 8), string.format('%x', 0))", None, "run"),
    ("fmt-hex-neg", "print(string.format('%x', -1), string.format('%o', -1), "
     "string.format('%o', -2), string.format('%X', -255))", None, "run"),
    ("fmt-hash", "print(string.format('%#x', 255), string.format('%#o', 8), "
     "string.format('%#X', 26), string.format('%#x', 0))", None, "run"),
    ("fmt-radix-flags", "print(string.format('%08x|', 255), "
     "string.format('%-8x|', 255), string.format('%5.2o|', 8), "
     "string.format('%#.3x', 255))", None, "run"),
    # %c takes the low byte, as C's sprintf does: 256 is a NUL and -1 is 0xFF
    ("fmt-char", "print(string.format('%c', 65), string.format('%5c|', 65), "
     "string.format('%-c|', 65), string.byte(string.format('%c', 256)), "
     "string.byte(string.format('%c', -1)))", None, "run"),
    ("fmt-spec-hash-d", "print(string.format('%#d', 5))", None, "runtimerr",
     {"expect": {"err": "invalid conversion specification: '%#d'"}}),
    ("fmt-spec-prec-c", "print(string.format('%.2c', 65))", None, "runtimerr",
     {"expect": {"err": "invalid conversion specification: '%.2c'"}}),
    ("fmt-spec-plus-x", "print(string.format('%+x', 15))", None, "runtimerr",
     {"expect": {"err": "invalid conversion specification: '%+x'"}}),
    ("fmt-spec-space-s", "print(string.format('% s', 'x'))", None, "runtimerr",
     {"expect": {"err": "invalid conversion specification: '% s'"}}),
    ("fmt-spec-q-mod", "print(string.format('%5q', 'x'))", None, "runtimerr",
     {"expect": {"err": "specifier '%q' cannot have modifiers"}}),
    ("fmt-err-noarg", "print(string.format('%d'))", None, "runtimerr",
     {"expect": {"err": "bad argument #2 to 'format' (no value)"}}),
    ("fmt-err-notnum", "print(string.format('%d', 'x'))", None, "runtimerr",
     {"expect": {"err": "bad argument #2 to 'format' (number expected, got "
                          "string)"}}),
    ("fmt-err-noint", "print(string.format('%d', 1.5))", None, "runtimerr",
     {"expect": {"err": "number has no integer representation"}}),
    ("fmt-err-nofmt", "print(string.format())", None, "runtimerr",
     {"expect": {"err": "bad argument #1 to 'format' (string expected, got no "
                          "value)"}}),
    # io: the text in inStr0 is the program's standard input, and io.write appends
    # raw text to the log -- no tab, no newline -- through the same 32-append cap
    # as print.  PUC's "*n" is not here: it needs a string-to-number scan.
    ("io-write", "io.write('x') print('y') io.write('z')", None, "run"),
    ("io-write-args", "io.write(1, true, nil)", None, "run"),
    ("io-read-line", "print(io.read())", None, "run",
     {"sinputs": {"0": "alpha\nbeta\n"}}),
    ("io-read-lines", "print(io.read('*l'), io.read('*l')) print(io.read('*l'))",
     None, "run", {"sinputs": {"0": "a\nb\nc\n"}}),
    ("io-read-count", "print(io.read(3), io.read(2))", None, "run",
     {"sinputs": {"0": "abcdefgh"}}),
    ("io-read-all", "print('[' .. io.read('*a') .. ']')", None, "run",
     {"sinputs": {"0": "one\ntwo\n"}}),
    ("io-read-eof", "print(io.read('*l')) print(io.read('*l'))", None, "run",
     {"sinputs": {"0": "only\n"}}),
    ("io-lines", "for l in io.lines() do io.write(l) end", None, "run",
     {"sinputs": {"0": "x\ny\nz\n"}}),
    ("io-lines-empty", "local n = 0 for l in io.lines() do n = n + 1 end "
     "print(n)", None, "run", {"sinputs": {"0": ""}}),
    ("io-lines-then-read", "for l in io.lines() do io.write(l) end "
     "print(io.read('*l'))", None, "run", {"sinputs": {"0": "p\nq\n"}}),
    ("io-read-bad", "print(io.read('*x'))", None, "runtimerr",
     {"expect": {"err": "bad argument to 'read' (invalid format)"}}),
    # %f: the digits have to be the value's own, which is the whole difficulty.
    # 0.15 at one place is 0.1 and not 0.2, and 344.95 is 344.9 and not 345.0,
    # because the exact double sits just below the tie -- a single rounding puts
    # it on the tie and cannot say which side.  tools/fmtsweep.py compares 3888
    # values at precisions 0..15 against the oracle; these are the cases that
    # made the algorithm what it is.
    ("fmt-f-default", "print(string.format('%f', 1.5), "
     "string.format('%.3f', 0))", None, "run"),
    ("fmt-f-ties", "print(string.format('%.1f', 0.05), string.format('%.1f', "
     "0.15), string.format('%.1f', 344.95), string.format('%.1f', 302.05))",
     None, "run"),
    ("fmt-f-half-even", "print(string.format('%.0f', 0.5), "
     "string.format('%.0f', 1.5), string.format('%.0f', 2.5), "
     "string.format('%.0f', -1.5), string.format('%.0f', -2.5))", None, "run"),
    ("fmt-f-carry", "print(string.format('%.2f', 9.999), string.format('%.2f', "
     "0.999), string.format('%.2f', 99.995))", None, "run"),
    ("fmt-f-flags", "print(string.format('%010.2f', -1.5), "
     "string.format('%+08.2f', 1.5), string.format('%-8.2f|', 1.5), "
     "string.format('% .2f', 1.5))", None, "run"),
    ("fmt-f-wide", "print(string.format('%.2f', 12345678901.5), "
     "string.format('%.15f', 0.1), string.format('%.2f', 1e15))", None, "run"),
    # the two limits are errors, not approximations: past 15 places the scale
    # would not be exact, and past 2^53 the integer part is not this chip's
    ("fmt-f-prec-limit", "print(string.format('%.16f', 0.1))", None, "runtimerr",
     {"expect": {"err": "precision above 15 cannot be formatted exactly on "
      "this chip"}}),
    ("fmt-f-range", "print(string.format('%.2f', 1e16))", None, "runtimerr",
     {"expect": {"err": "number too large to format exactly on this chip"}}),
    # %e: a digit stream, because the mantissa is the value divided by 10^k and
    # no division by ten is exact.  The exponent is three digits, which is PUC
    # 5.5 and not C's two -- %.3e of zero measures ten characters.  The sticky
    # bit has to come from the digits as well as the double-double, because
    # when the round digit is still inside the integer part the walk has not
    # started the fraction and the leftover says nothing.
    ("fmt-e-default", "print(string.format('%e', 1.5), "
     "string.format('%.1e', -2.25))", None, "run"),
    ("fmt-e-small", "print(string.format('%.2e', 0.000123), "
     "string.format('%.0e', 1234.5))", None, "run"),
    ("fmt-e-upper", "print(string.format('%E', 12345.6789), "
     "string.format('%.3E', -0.0004567))", None, "run"),
    # -0.0 is not here: the chip's lexer loses the sign of a negative zero
    # (tostring(-0.0) is 0.0, where PUC has -0.0), which is its own divergence
    # and not a %e one
    ("fmt-e-zero", "print(string.format('%.3e', 0), string.format('%.0e', 0))",
     None, "run"),
    ("fmt-e-round", "print(string.format('%.0e', 25.5), "
     "string.format('%.2e', 916506699492), string.format('%.1e', "
     "-225090321657))", None, "run"),
    ("fmt-e-flags", "print(string.format('%012.2e', 1.5), "
     "string.format('%+.1e', 1.5), string.format('%-12.1e|', 1.5))",
     None, "run"),
    # the mantissa is p+1 digits read as one integer, and ten of them is past
    # 2^53 -- so 15 places is a range error and not an approximation
    ("fmt-e-prec-limit", "print(string.format('%.15e', 1.5))", None, "runtimerr",
     {"expect": {"err": "precision above 14 cannot be formatted exactly on "
      "this chip"}}),
    ("fmt-e-range", "print(string.format('%.2e', 1e16))", None, "runtimerr",
     {"expect": {"err": "number too large to format exactly on this chip"}}),
    # pcall, which PUC has in C.  The interesting cases are the ones that are not
    # just "does it catch an error": a gate builtin has no frame, so its
    # arguments move down a register and the call instruction runs again as the
    # gate (pcall(error, ...) and pcall(print, ...)); a non-function is the pair
    # and not a failure of pcall, because PUC raises the attempt at the call and
    # pcall catches it; and a caught error has to leave the program able to
    # carry on, which is the whole point of it.
    ("pcall-ok", "function f() return 7, 8 end print(pcall(f))", None, "run"),
    ("pcall-targets",
     "function f() return 7, 8 end local ok, a, b = pcall(f) "
     "print(ok, a, b)", None, "run"),
    ("pcall-catch", "function f() error('boom') end print(pcall(f))", None,
     "run"),
    ("pcall-gate", "print(pcall(print, 'hi'))", None, "run"),
    ("pcall-gate-error", "local ok, e = pcall(error, 'bang') print(ok, e)",
     None, "run"),
    ("pcall-gate-value", "print(pcall(tostring, 42), pcall(type, nil))", None,
     "run"),
    ("pcall-not-a-function", "local ok, e = pcall(42) print(ok, e)", None,
     "run"),
    ("pcall-not-a-function-nil", "local ok, e = pcall(nil) print(ok, e)",
     None, "run"),
    ("pcall-no-argument", "pcall()", None, "runtimerr",
     {"expect": {"err": "bad argument #1 to 'pcall' (value expected)"}}),
    ("pcall-nested",
     "function f() return pcall(error, 'inner') end print(pcall(f))", None,
     "run"),
    ("pcall-deep-error",
     "function d(n) if n == 0 then error('bottom') end return d(n - 1) end "
     "print(pcall(d, 5))", None, "run"),
    ("pcall-varargs",
     "function f(...) print(select('#', ...), ...) end "
     "pcall(f, 'ab', 'b', 1)", None, "run"),
    ("pcall-varargs-fixed",
     "function f(a, ...) return a, select('#', ...), ... end "
     "print(pcall(f, 'ab', 'b', 1))", None, "run"),
    ("pcall-varargs-return",
     "function f(...) return select('#', ...), ... end "
     "print(pcall(f, 'ab', 'b', 1))", None, "run"),
    ("pcall-gate-args-init", "print(pcall(string.find, 'ab', 'b', 1))", None,
     "run"),
    ("pcall-statement", "function f() return 1 end pcall(f) print('after')",
     None, "run"),
    # The one thing pcall cannot do here: pcall of pcall.  pcall is the only
    # gate that pushes a frame, and the in-place dispatch has one result slot,
    # so it is a loud error rather than a wrong answer.
    ("pcall-of-pcall", "function f() return 1 end print(pcall(pcall, f))",
     None, "runtimerr",
     {"expect": {"err": "pcall of pcall is not supported on this chip"}}),
    # xpcall, which PUC also has in C.  PUC 5.5 returns false *plus* whatever
    # the handler returned, not the handler's results alone -- the false is
    # there even when the handler returns a truthy thing of its own.  The
    # handler is kept in pcallH/pcallHT because the protected call's frame is
    # written over the register the handler was in, and it gets the error object
    # as its first argument even when the frame it starts in overlaps that slot.
    ("xpcall-ok", "function f() return 1, 2 end function h() end "
     "print(xpcall(f, h))", None, "run"),
    ("xpcall-targets", "function f() return 1, 2 end function h() end "
     "local ok, a, b = xpcall(f, h) print(ok, a, b)", None, "run"),
    ("xpcall-catch", "function f() error('boom') end "
     "print(xpcall(f, function(e) return 'H:' .. e end))", None, "run"),
    ("xpcall-catch-targets", "function f() error('b') end "
     "function h(e) return 'H' end local ok, e = xpcall(f, h) print(ok, e)",
     None, "run"),
    ("xpcall-two-results", "function f() error('z') end function h(e) "
     "return 7, 8 end print(xpcall(f, h))", None, "run"),
    ("xpcall-handler-args", "function f(a, b) return a + b end function h() end "
     "print(xpcall(f, h, 10, 3))", None, "run"),
    ("xpcall-no-handler", "function f() error('n') end xpcall(f, 42)", None,
     "runtimerr",
     {"expect": {"err": "bad argument #2 to 'xpcall' (function expected, "
                        "got number)"}}),
    ("xpcall-not-a-function", "function h() end print(xpcall(42, h))", None,
     "run"),
    ("xpcall-handler-message",
     "function f() error(7) end print(xpcall(f, function(e) return e end))",
     None, "run"),
    ("xpcall-handler-varargs",
     "function f() error(7) end "
     "print(xpcall(f, function(...) return select('#', ...), ... end))", None,
     "run"),
    # A function literal as a call argument, in the shapes where the enclosing
    # call's marker is still open: these are what the two comma-scope bugs in
    # closeAction looked like from the outside.
    ("arg-fn-returns", "print(pcall(function() return 1, 2 end))", None, "run"),
    ("arg-fn-count", "print(select('#', pcall(function() return 1, 2, 3 end)))",
     None, "run"),
    ("arg-fn-paren-call", "print((function() return 1, 2 end)())", None, "run"),
    ("arg-fn-table", "local t = {function() return 1, 2 end} print(t[1]())", None,
     "run"),
    # A gate as xpcall's message handler, and a gate handler that returns no
    # value.  The number keeps PUC's error object free of a source position, so
    # this measures the handler and the substitution rather than error()'s
    # documented divergence.
    ("xpcall-gate-handler", "function f() error(7) end "
     "print(xpcall(f, tostring))", None, "run"),
    ("xpcall-gate-handler-nil", "function f() error(7) end "
     "local ok, v = xpcall(f, print) print(ok, v)", None, "run"),
    # string.find and string.match, which PUC also has in C: a backtracking
    # matcher wants a stack and a loop, so it is a gate machine here and the
    # library piece around it is three lines of Lua.  The cases below are the
    # shapes whose answers are not obvious: an empty match ends one position
    # before it starts, a greedy quantifier is tried longest first and gives
    # characters back one at a time, a lazy one the other way round, and %b is
    # never backtracked at all (PUC's matchbalance counts to the first return
    # to zero and either has its match or has not).
    ("pat-find", "print(string.find('hello world', 'o'))", None, "run"),
    ("pat-find-init", "print(string.find('hello world', 'o', 6))", None,
     "run"),
    ("pat-find-negative-init",
     "print(string.find('hello', 'l', -2))", None, "run"),
    ("pat-find-past-end", "print(string.find('hello', 'l', 9))", None, "run"),
    ("pat-find-empty", "print(string.find('abc', ''))", None, "run"),
    ("pat-find-empty-init", "print(string.find('hello', '', 4))", None, "run"),
    ("pat-find-empty-past-end", "print(string.find('hello', '', 7))", None,
     "run"),
    ("pat-find-none", "print(string.find('hello', 'xyz'))", None, "run"),
    ("pat-find-anchor", "print(string.find('hello', '^h'), "
     "string.find('hello', '^e'))", None, "run"),
    ("pat-find-end-anchor", "print(string.find('hello', 'o$'), "
     "string.find('hello', 'x$'))", None, "run"),
    ("pat-find-plain", "print(string.find('a.b', '.', 1, true), "
     "string.find('a.b', '.'), string.find('a.b', 'a$', 1, true))", None,
     "run"),
    # The gate reads only the arguments that were passed: a find with no init
    # follows a find that had one, and the register past its own arguments still
    # holds the earlier call's plain flag.  Reading it made the boolean an init.
    ("pat-find-no-init-after-four", "print(string.find('a.b', '.', 1, true), "
     "string.find('a.b', '.'), string.find('a.b', 'b', 1, true))", None, "run"),
    ("pat-find-class", "print(string.match('abc123', '%d+'))", None, "run"),
    ("pat-match-quantifier", "print(string.match('hello', 'l+'), "
     "string.match('hello', 'l*'), string.match('hello', 'l-'), "
     "string.match('hello', 'l?'))", None, "run"),
    ("pat-match-greedy-backtrack",
     "print(string.find('hello', 'l*l'), string.match('hello', 'l*l'))",
     None, "run"),
    ("pat-match-lazy", "print(string.find('hello', 'h-e'), "
     "string.match('aaab', 'a-b'))", None, "run"),
    ("pat-match-optional", "print(string.match('aab', 'a?b'), "
     "string.match('color colour', 'colou?r'))", None, "run"),
    ("pat-match-set", "print(string.match('abc', '[a-c]+'), "
     "string.match('abc', '[^b]'), string.match('hello', '[el]+'))", None,
     "run"),
    ("pat-match-set-dashes", "print(string.match('abc', '[-a]'), "
     "string.match('abc', '[a-]'), string.match('a-b', '[%-]'))", None, "run"),
    ("pat-match-set-class", "print(string.match('  x', '%s*%a'), "
     "string.match('5 apples', '%x+'))", None, "run"),
    ("pat-match-dot", "print(string.match('abc', 'a.c'), "
     "string.match('aXb', 'a%db'))", None, "run"),
    # A set's own ] has to be escaped, and the scan that finds the end of the set
    # has to see the escape: PUC's classend skips a %x pair, so [%]] is the set
    # holding ] and not an unterminated one.
    ("pat-match-set-escaped", "print(string.match('a]b', '[%]]'), "
     "string.find('abc', '[%]]'))", None, "run"),
    # The machine runs from the top of vmStep with absolute registers, so a find
    # inside a function, off a table, or in a loop is the same find; and a
    # malformed pattern raised three ticks into one is a value pcall can catch.
    ("pat-in-function", "local function f(s) return string.find(s, 'b') end "
     "print(f('abc'))", None, "run"),
    ("pat-in-table", "local t = {s = 'hello'} "
     "print(string.find(t.s, 'l+'))", None, "run"),
    ("pat-in-pcall", "print(pcall(string.find, 'abc', '%'))", None, "run"),
    ("pat-in-loop", "local out = '' for i = 1, 3 do out = out .. "
     "string.match('ab', 'a') end print(out)", None, "run"),
    ("pat-float-init", "print(string.find('abc', 'b', 1.0))", None, "run"),
    ("pat-match-balance", "print(string.find('a(b)c', '%b()'), "
     "string.find('a(b)c(d)e', '%b()d'))", None, "run"),
    ("pat-match-frontier", "print(string.match('THE (quick) fox', "
     "'%f[%a]%a+%f[%A]'))", None, "run"),
    ("pat-malformed-set", "print(string.find('hello', '['))", None,
     "runtimerr", {"expect": {"err": "malformed pattern (missing ']')"}}),
    ("pat-malformed-percent", "print(string.find('hello', '%'))", None,
     "runtimerr",
     {"expect": {"err": "malformed pattern (ends with '%')"}}),
    ("pat-malformed-b", "print(string.find('hello', '%b'))", None,
     "runtimerr",
     {"expect": {"err": "malformed pattern (missing arguments to '%b')"}}),
    ("pat-malformed-f", "print(string.find('hello', '%f'))", None,
     "runtimerr",
     {"expect": {"err": "missing '[' after '%f' in pattern"}}),
    ("pat-leading-quantifier", "print(string.find('hello', '*l'))", None,
     "run"),
    ("pat-unmatched-close", "print(string.find('hello', ')'), "
     "string.find('hello', 'a)'))", None, "run"),
    ("pat-backref", "print(string.find('abc', '%1'))", None, "runtimerr",
     {"expect": {"err": "invalid capture index %1"}}),
    # Captures.  PUC 5.5's () is a position capture, not an empty one: it
    # answers where it stands, as a number, and %1 to %9 compare the subject
    # against a capture and move both on by its length.  A capture's number is
    # how many the attempt has opened and its depth is how many are open now,
    # which is why "(a)(b)" numbers those one and two and "((a))" nests.  A
    # quantifier inside a capture gives a character back and runs the ) again,
    # so the ) has to be able to open what it closed.
    ("pat-capture", "print(string.find('abc', '(a)'))", None, "run"),
    ("pat-capture-two", "print(string.find('abc', '(a)(b)'))", None, "run"),
    ("pat-capture-match", "print(string.match('abc', '(a)(b)'))", None, "run"),
    ("pat-capture-nested", "print(string.find('abc', '((a))'), "
     "string.find('abc', '(a(b))'))", None, "run"),
    ("pat-position-capture", "print(string.find('abc', '()'), "
     "string.match('abc', '()'), string.find('abc', '()b'), "
     "string.find('abc', '()()a'))", None, "run"),
    ("pat-capture-greedy", "print(string.find('2026-09-24', "
     "'(%d+)-(%d+)-(%d+)'))", None, "run"),
    ("pat-capture-classes", "print(string.match('hello world', "
     "'(%w+) (%w+)'), string.find('a1b2', '(%a)(%d)'))", None, "run"),
    ("pat-backref", "print(string.find('aa', '(a)%1'), "
     "string.find('abab', '(ab)%1'), string.find('aa', '(%a+)%1'))", None,
     "run"),
    ("pat-backref-miss", "print(string.find('abc', '()%1'), "
     "string.find('ab', '(a)(b)%1'))", None, "run"),
    ("pat-backref-quantified", "print(string.find('abc', '(a)%1*'))", None,
     "run"),
    ("pat-backref-invalid", "print(string.find('abc', '(%1)'))", None,
     "runtimerr",
     {"expect": {"err": "invalid capture index %1"}}),
    ("pat-backref-missing", "print(string.find('abc', '(a)%2'))", None,
     "runtimerr",
     {"expect": {"err": "invalid capture index %2"}}),
    ("pat-capture-unfinished", "print(string.find('abc', '(a'))", None,
     "runtimerr", {"expect": {"err": "unfinished capture"}}),
    ("pat-capture-unfinished-nested", "print(string.find('abc', '((a)'))",
     None, "runtimerr", {"expect": {"err": "unfinished capture"}}),
    ("pat-capture-close-unopened", "print(string.find('abc', 'a(b)c)'))", None,
     "runtimerr", {"expect": {"err": "invalid pattern capture"}}),
    # The one thing here the chip cannot do: a find answers two positions and one
    # value per capture, and an expression has MAXVALS registers to answer in.
    # Fifteen captures is seventeen values, so it is refused rather than written
    # over whatever follows.
    ("pat-too-many-to-return", "print(string.find('abc', '" +
     "()()()()()()()()()()()()()()()" + "'))", None, "runtimerr",
     {"expect": {"err": "too many captures to return"}}),
    ("pat-no-subject", "print(string.find('hello'))", None, "runtimerr",
     {"expect": {"err": "bad argument #2 to 'string.find' (string expected, got no "
                        "value)"}}),
    ("pat-no-pattern-match", "print(string.match('hello'))", None, "runtimerr",
     {"expect": {"err": "bad argument #2 to 'string.match' (string expected, got no "
                        "value)"}}),
    ("pat-nil-pattern", "print(string.find('hello', nil))", None, "runtimerr",
     {"expect": {"err": "bad argument #2 to 'string.find' (string expected, got nil)"}}),
    ("pat-bad-subject", "print(string.find({}, 'l'))", None, "runtimerr",
     {"expect": {"err": "bad argument #1 to 'string.find' (string expected, got "
                        "table)"}}),
    ("pat-number-subject", "print(string.find(5, 'l'), string.find('a1b', "
     "'%d'))", None, "run"),
    ("pat-bad-init", "print(string.find('hello', 'l', 'x'))", None,
     "runtimerr",
     {"expect": {"err": "bad argument #3 to 'string.find' (number expected, got "
                         "string)"}}),
    # gsub is a library loop over the matcher: the gate answers one match at a
    # time and the loop is PUC's own.  Three things in that loop are the whole
    # reason the piece is not a straight transcription: the unmatched text
    # between one match and the next is copied when the match lands (a no-match
    # step copies exactly one character and does not count as a replacement),
    # the loop stops when a match ends where the last one ended -- that is what
    # ends "aaa" on "a*" after one replacement, not the matcher, which does
    # match at the end of the subject -- and a leading ^ gives one match and no
    # more, because PUC's loop breaks after it.
    ("gsub-plain", "print(string.gsub('hello world', 'o', '0'), "
     "string.gsub('abc', 'x', 'y'), string.gsub('', 'a', 'b'))", None, "run"),
    ("gsub-empty-pattern", "print(string.gsub('hello', '', '-'), "
     "string.gsub('a', '', '-'), string.gsub('ab', '', '-'), "
     "string.gsub('', '', '-'))", None, "run"),
    ("gsub-limit", "print(string.gsub('hello', 'l', 'L', 1), "
     "string.gsub('hello', 'l', 'L', 10), string.gsub('hello', 'l', 'L', 0), "
     "string.gsub('hello', 'l', 'L', -1), string.gsub('abc', 'a', 'x', 1.0))",
     None, "run"),
    ("gsub-anchor", "print(string.gsub('hello', '^h', 'H'), "
     "string.gsub('hello', '^e', 'E'), string.gsub('abc', '^', '-'), "
     "string.gsub('hello', '^h', 'H', 2), string.gsub('hello', '^', '-', 3))",
     None, "run"),
    ("gsub-whole-match", "print(string.gsub('abc', '%w', '%0%0'), "
     "string.gsub('abc', 'a', '%0%%'), string.gsub('abc', '[abc]', '%0%0'), "
     "string.gsub('abc', 'a', '%1'))", None, "run"),
    ("gsub-captures", "print(string.gsub('abc', '(%w)', '[%1]'), "
     "string.gsub('abc', '(a)(b)', '%2%1'), string.gsub('2026-09-24', "
     "'(%d+)', '<%1>'), string.gsub('x=1, y=2', '(%w+)=(%w+)', '%2=%1'))",
     None, "run"),
    ("gsub-position-capture", "print(string.gsub('abc', '()', '%1'))", None,
     "run"),
    ("gsub-star-empty", "print(string.gsub('aaa', 'a*', '-'), "
     "string.gsub('abc', 'b*', '-'), string.gsub('abc', '.-', 'X'), "
     "string.gsub('abc', '', '%0', 2))", None, "run"),
    # A table replacement is keyed by the first capture, or by the whole match
    # when the pattern has none, and a value that is nil or false keeps the
    # matched text instead of dropping it.
    ("gsub-table", "print(string.gsub('abc', '(a)', {a='X'}), "
     "string.gsub('abc', '(a)', {b='X'}), string.gsub('abc', 'a', {X='Y'}))",
     None, "run"),
    # A function replacement gets the captures, or the whole match when there
    # are none -- not the match and then the captures.
    ("gsub-function", "print(string.gsub('abc', '.', function(m) return '[' "
     ".. m .. ']' end), string.gsub('abc', 'a', string.upper), "
     "string.gsub('a1b2', '%d', function(d) return '[' .. d .. ']' end))",
     None, "run"),
    ("gsub-function-args", "local function f(...) return select('#', ...) end "
     "print(string.gsub('abc', 'a', f), string.gsub('abc', '(a)', f), "
     "string.gsub('abc', '(a)(b)', f), string.gsub('abc', '()', f))", None,
     "run"),
    ("gsub-function-nil", "print(string.gsub('abc', '(a)', function(m, c) "
     "return nil end), string.gsub('abc', '(a)', function(m, c) return false "
     "end))", None, "run"),
    ("gsub-number-replacement", "print(string.gsub('abc', 'a', 5), "
     "string.gsub(42, '%d', 'x'), string.gsub('abc', 'a', 'x', 2.0))", None,
     "run"),
    # Both the missing and wrong-type replacement errors use PUC's qualified
    # function name.
    ("gsub-no-replacement", "print(string.gsub('abc', 'a'))", None, "runtimerr",
     {"expect": {"err": "bad argument #3 to 'string.gsub' (string/function/table "
                        "expected, got no value)"}}),
    ("gsub-bad-replacement", "print(string.gsub('abc', 'a', true))", None,
     "runtimerr",
     {"expect": {"err": "bad argument #3 to 'string.gsub' (string/function/"
                        "table expected, got boolean)"}}),
    ("gsub-bad-limit", "print(string.gsub('abc', 'a', 'b', 'x'))", None,
     "runtimerr",
     {"expect": {"err": "bad argument #4 to 'string.gsub' (number expected, "
                        "got string)"}}),
    ("gsub-fractional-limit", "print(string.gsub('abc', 'a', 'b', 1.9))", None,
     "runtimerr",
     {"expect": {"err": "bad argument #4 to 'string.gsub' (number has no integer "
                        "representation)"}}),
    ("gsub-bad-percent", "print(string.gsub('abc', 'a', '%'))", None,
     "runtimerr",
     {"expect": {"err": "invalid use of '%' in replacement string"}}),
    ("gsub-bad-escape", "print(string.gsub('abc', 'a', '%z'))", None,
     "runtimerr",
     {"expect": {"err": "invalid use of '%' in replacement string"}}),
    ("gsub-bad-capture-index", "print(string.gsub('abc', '(%w)', '%2'))", None,
     "runtimerr", {"expect": {"err": "invalid capture index %2"}}),
    ("gsub-boolean-value", "print(string.gsub('abc', '(a)', {a=true}))", None,
     "runtimerr", {"expect": {"err": "invalid replacement value (a boolean)"}}),
    ("gsub-table-value", "print(string.gsub('abc', '(a)', {a={}}))", None,
     "runtimerr", {"expect": {"err": "invalid replacement value (a table)"}}),
    # gmatch is a stateful iterator and the state is three arrays, not a closure:
    # _gmatch makes the walk and _gmnext takes one step of it, which is two gates
    # because PUC's iterator is a different value from string.gmatch (a call with
    # one string is a gmatch missing its pattern, and the iterator is handed
    # whatever the loop has and ignores it).  The walk's cursor is PUC's rule with
    # the part that is not the matcher's: a non-empty match that ends at the end
    # of the subject finishes the walk, which is why "aaa" on "a*" is one result
    # while "aaa" on "b*" is four and "abc" on "" is four -- the empty matches at
    # the end are real.  A leading ^ matches nothing at all here, measured.
    ("gmatch-words", "for k in string.gmatch('hello world', '%a+') do "
     "io.write(k, '|') end print()", None, "run"),
    ("gmatch-captures", "for k, v in string.gmatch('a=1, b=2', "
     "'(%a+)=(%d)') do io.write(k, v, '|') end print()", None, "run"),
    ("gmatch-empty-pattern", "for k in string.gmatch('abc', '') do io.write('[', "
     "k, ']') end print()", None, "run"),
    ("gmatch-star-empty", "for k in string.gmatch('aaa', 'a*') do io.write('[', "
     "k, ']') end print()", None, "run"),
    ("gmatch-lazy-empty", "for k in string.gmatch('abc', '.-') do io.write('[', "
     "k, ']') end print()", None, "run"),
    ("gmatch-optional-end", "for k in string.gmatch('abc', 'c?') do io.write('[', "
     "k, ']') end print()", None, "run"),
    ("gmatch-star-miss", "for k in string.gmatch('aaa', 'b*') do io.write('[', k, "
     "']') end print()", None, "run"),
    ("gmatch-dot", "for k in string.gmatch('abc', '.') do io.write('[', k, ']') "
     "end print()", None, "run"),
    ("gmatch-dollars", "for k in string.gmatch('abc', 'b$') do io.write('[', k, "
     "']') end print() for k in string.gmatch('abc', 'c$') do io.write('[', k, "
     "']') end print()", None, "run"),
    # a leading ^ is the anchor for find and gsub and never matches in gmatch
    ("gmatch-anchor-a", "for k in string.gmatch('aba', '^a') do io.write('[', "
     "k, ']') end print()", None, "run"),
    ("gmatch-anchor-b", "for k in string.gmatch('abcabc', '^b') do io.write('[', "
     "k, ']') end print()", None, "run"),
    ("gmatch-anchor-whole", "for k in string.gmatch('abc', '^abc$') do "
     "io.write('[', k, ']') end print()", None, "run"),
    ("gmatch-position-capture", "local f, s, c = string.gmatch('abc', '()') "
     "print(f(s, c)) print(f(s, c)) print(f(s, c))", None, "run"),
    ("gmatch-init", "for k in string.gmatch('aab', 'a', 2) do io.write(k, '|') "
     "end print()", None, "run"),
    ("gmatch-number-subject", "for k in string.gmatch(42, '%d') do io.write(k, "
     "'|') end print()", None, "run"),
    ("gmatch-empty-subject", "for k in string.gmatch('', 'a') do io.write(k) end "
     "print('empty')", None, "run"),
    ("gmatch-count", "local n = 0 for k in string.gmatch('abcabc', 'a') do n = "
     "n + 1 end print(n)", None, "run"),
    ("gmatch-collect", "local t = {} for k in string.gmatch('a,b,c', '[^,]+') "
     "do t[#t + 1] = k end print(#t, t[1], t[3])", None, "run"),
    # the second value is the walk (a number here, nil in PUC) and the loop never
    # shows it; three values come back and the third is the control
    ("gmatch-three-values", "local f, s, c = string.gmatch('a1b2', '(%a)(%d)') "
     "print(select('#', f, s, c)) print(f(s, c)) print(f(s, c)) print(f(s, c))",
     None, "run"),
    # PUC's iterator ignores its arguments; this one falls back to the last walk
    ("gmatch-junk-argument", "local f, s, c = string.gmatch('a1b2', '(%a)(%d)') "
     "print(f('junk'))", None, "run"),
    ("gmatch-malformed-set", "for k in string.gmatch('abc', '[') do io.write(k) "
     "end print('done')", None, "runtimerr",
     {"expect": {"err": "malformed pattern (missing ']')"}}),
    ("gmatch-malformed-percent", "for k in string.gmatch('abc', '%') do "
     "io.write(k) end print('done')", None, "runtimerr",
     {"expect": {"err": "malformed pattern (ends with '%')"}}),
    ("gmatch-no-subject", "string.gmatch()", None, "runtimerr",
     {"expect": {"err": "bad argument #1 to 'string.gmatch' (string expected, "
                        "got no value)"}}),
    ("gmatch-bad-subject", "string.gmatch({}, 'a')", None, "runtimerr",
     {"expect": {"err": "bad argument #1 to 'string.gmatch' (string expected, "
                        "got table)"}}),
    ("gmatch-bad-pattern", "string.gmatch('a', {})", None, "runtimerr",
     {"expect": {"err": "bad argument #2 to 'string.gmatch' (string expected, "
                        "got table)"}}),
    ("gmatch-no-pattern", "string.gmatch('a')", None, "runtimerr",
     {"expect": {"err": "bad argument #2 to 'string.gmatch' (string expected, "
                        "got no value)"}}),

    # error and assert, both C in PUC and gates here.  assert returns *all* of
    # its arguments on success, which is a shift down by one register on a
    # register VM.  PUC prefixes error's message with the chunk and line of
    # whatever called error; the chip has no line at run time, so the text a
    # program asked for is what it gets -- the case below pins that.
    ("err-error", "error('boom')", None, "runtimerr",
     {"expect": {"err": "boom"}}),
    ("err-error-value", "error(42)", None, "runtimerr",
     {"expect": {"err": "42"}}),
    ("err-error-level", "local ok, e = 1 error('x', 2)", None, "runtimerr",
     {"expect": {"err": "x"}}),
    ("assert-args", "print(assert(1, 'a', 'b'))", None, "run"),
    ("assert-count", "print(select('#', assert(1, 2, 3)))", None, "run"),
    ("assert-nil", "assert(nil, 'nope')", None, "runtimerr",
     {"expect": {"err": "nope"}}),
    ("assert-false", "assert(false)", None, "runtimerr",
     {"expect": {"err": "assertion failed!"}}),
    # 0 and "" are truthy in Lua, so only nil and false reach the error
    ("assert-zero-truthy", "print(assert(0, 'zero'), assert(''))", None, "run"),
    # wrong. The exponent is the one the value has *after* rounding to the
    # precision -- 9.5 at one digit is 10, so its exponent is 1 and the answer is
    # 1e+001, not 10. And a precision of zero means one.
    ("fmt-g-default", "print(string.format('%g', 1.5), "
     "string.format('%g', 123456789), string.format('%g', 0.00001234))",
     None, "run"),
    ("fmt-g-style", "print(string.format('%.3g', 1), string.format('%.2g', 100), "
     "string.format('%.0g', 9.5), string.format('%.3g', 123.4))", None, "run"),
    ("fmt-g-small", "print(string.format('%.2g', 0.0001), "
     "string.format('%.2g', 0.00001), string.format('%.6g', 33483122.829051971))",
     None, "run"),
    # # keeps the trailing zeros and the point, on both arms
    ("fmt-g-hash", "print(string.format('%#.0e', 1.5), string.format('%#.1g', "
     "1.5), string.format('%#.0g', 1234.5), string.format('%#5.1f', 1.5))",
     None, "run"),
    ("fmt-g-zero", "print(string.format('%g', 0), string.format('%.0g', 0))",
     None, "run"),
    # the walk needs the fraction's leading zeros, the mantissa's places and two
    # more, and the double-double carries sixteen exactly: below 10^(p-14) there
    # is no exact conversion and saying so beats a digit that is not the value's
    ("fmt-g-small-limit", "print(string.format('%.2g', 1e-300))", None, "runtimerr",
     {"expect": {"err": "value too small to format exactly on this chip"}}),
    # suite passes case sources on the command line: two of them in a batch is
    # already most of the way to Windows' 32 KB limit.  The first line pins the
    # shapes that always worked, the rest the two that used to fail -- one per
    # cause: a CALL that landed mid-burst read the caller's frame base, and _m's
    # third argument slot held a string the program never passed.
    ("call-chain", "PRE:tests/lib_callchain.lua\nprint(call_chain_ok1(1.5, 2), "
     "call_chain_ok1(1.5, 2)) print(probe_s2(12), probe_s2(12))\n"
     "print(call_chain_ok2(1.5, 2), call_chain_ok2(1.5, 2))\n"
     "print(call_chain_ok2(1.5, 2)) print(call_chain_ok2(1.5, 2))\n"
     "print(probe_o(1.5), probe_s1(1.5), probe_s3(1.5), probe_s4(1.5), "
     "probe_s5(1.5))", None, "run"),
    # math library
    ("math-floor", "print(math.floor(2.7), math.floor(-2.7), math.ceil(2.1), "
     "math.ceil(-2.1))", None, "run"),
    ("math-sqrt", "print(math.sqrt(16), math.sqrt(2))", None, "run"),
    ("math-abs", "print(math.abs(-3), math.abs(3), math.abs(-2.5))", None,
     "run"),
    ("math-minmax", "print(math.max(1, 9, 4), math.min(1, 9, 4), "
     "math.max(1.5, 1))", None, "run"),
    ("math-trig", "print(math.sin(0), math.cos(0), math.tan(0))", None, "run"),
    ("math-pi", "print(math.pi)", None, "run"),
    ("math-logexp", "print(math.exp(0), math.log(1), math.log(8, 2))", None,
     "run"),
    ("math-log", "print(math.log(100))", None, "run"),
    ("math-maxinteger", "print(math.maxinteger)", None, "run"),
    ("math-fmod", "print(math.fmod(7, 3), math.fmod(-7, 3), math.fmod(7, -3))",
     None, "run"),
    # modf returns floats, so the integral part prints with the chip's float
    # spelling, and the chip prints the shortest round-trip form of the
    # fraction where PUC prints 17 digits.
    ("math-modf", "print(math.modf(3.7))", None, "run"),
    # table library
    ("tbl-insert", "local t = {1,2} table.insert(t, 3) table.insert(t, 1, 0) "
     "print(#t, t[1], t[2], t[3], t[4])", None, "run"),
    ("tbl-remove", "local t = {1,2,3} print(table.remove(t), "
     "table.remove(t, 1), #t, t[1])", None, "run"),
    ("tbl-concat", "print(table.concat({'a','b','c'}), "
     "table.concat({'a','b','c'}, '-'), table.concat({1,2,3}, ',', 2, 3))",
     None, "run"),
    ("tbl-unpack", "print(table.unpack({7,8,9}))", None, "run"),
    ("tbl-unpack-range", "print(table.unpack({1,2,3,4}, 2, 3))", None, "run"),
    ("tbl-pack", "local t = table.pack(1, nil, 3) print(t.n, t[1], t[3])",
     None, "run"),
    ("tbl-move", "local a = {1,2,3,4} local b = table.move(a, 2, 3, 1) "
     "print(b[1], b[2], b[3])", None, "run"),
    ("tbl-sort", "local t = {5,3,8,1} table.sort(t) print(t[1], t[2], t[3], t[4])",
     None, "run"),
    ("tbl-sort-cmp", "local t = {5,3,8,1} table.sort(t, function(a, b) "
     "return a > b end) print(t[1], t[2], t[3], t[4])", None, "run"),
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
    # A long loop, for loop-carried register integrity: a register wrongly reused
    # or a vararg stack that stopped growing corrupts the accumulator or the
    # control variable, and that shows up here and nowhere else.  2000 iterations
    # is the size that fits the suite's per-case budget -- the rule it protects is
    # about the loop running at all, not about how many times, and `over-cap` and
    # `func-fib` are the cases that buy scale when someone wants to pay for it.
    ("long-sum", "local s = 0 local i = 1 while i<=2000 do "
     "s = s+i i = i+1 end print(s)", None, "run"),
    ("long-string", "print([[hello]])", None, "run"),
    ("long-string-nest", 'print([=[a]=])', None, "run"),
    ("long-comment", "--[[this is a comment]]print(1)", None, "run"),
    ("long-comment-nest", "--[==[nested]==]print(2)", None, "run"),
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
    # Closures.  A function value is a closure, not a prototype: below the
    # closure records a function is its own closure, so two evaluations of one
    # literal compare equal when nothing was captured, and a function that does
    # capture gets a cell per evaluation.
    ("upvalue-read", "local x = 5 function f() return x end print(f())",
     None, "run"),
    # a write through a closure is visible to the function that declares the
    # local, which is the whole point of sharing one cell
    ("upvalue-write", "local x = 1 local function bump() x = x + 1 end "
     "bump() bump() print(x)", None, "run"),
    # two closures over one local share the cell, so the second sees the first's
    # write
    ("upvalue-shared", "local x = 1 local g = function() x = x + 1 return x end "
     "local h = function() return x end print(g(), h(), h())", None, "run"),
    # the counter shape: the cell outlives the frame that made it
    ("upvalue-counter", "local function counter() local n = 0 return function() "
     "n = n + 1 return n end end local c = counter() print(c(), c(), c())",
     None, "run"),
    # a parameter is a local like any other
    ("upvalue-param", "local function mk(tag) return function(v) "
     "return tag .. v end end local hi = mk('x') print(hi('y'), hi('z'))",
     None, "run"),
    # two cells in one frame, written independently
    ("upvalue-two-cells", "local function pair() local a, b = 0, 0 "
     "return function() a = a + 1 b = b + 2 return a, b end, "
     "function() return a + b end end local inc, sum = pair() print(inc()) "
     "print(sum())", None, "run"),
    # each round of a loop gets its own cell, which is what closing the cell at
    # the end of the block buys in PUC
    ("upvalue-loop-body", "local out = {} for i = 1, 3 do local y = i "
     "out[i] = function() return y end end print(out[1](), out[2](), out[3]())",
     None, "run"),
    # so does the loop's own control variable, declared outside the body
    ("upvalue-loop-var", "local t = {} for i = 1, 3 do t[i] = function() "
     "return i end end print(t[1](), t[2](), t[3]())", None, "run"),
    # a local declared outside the loop and mutated inside it: every round
    # captures the value it had at the start of that round
    ("upvalue-loop-outer", "local n = 0 for i = 1, 3 do "
     "local f = function() return n end n = n + 1 end print(n)", None, "run"),
    # three deep: the middle function's cell is what the innermost reads
    ("upvalue-transitive", "local function outer() local a = 1 return function() "
     "return function() return a end end end print(outer()()())", None, "run"),
    # a recursive local function is the closure it is running, so a function
    # with upvalues still recurses into itself
    ("upvalue-selfrec", "local function f(n) if n == 0 then return 0 end "
     "return n + f(n - 1) end print(f(5))", None, "run"),
    # and so does one whose cell it also reads
    ("upvalue-selfrec-cell", "local function fib(n) if n < 2 then return n end "
     "return fib(n - 1) + fib(n - 2) end print(fib(10))", None, "run"),
    # two evaluations of one literal with nothing captured are the same value
    ("upvalue-same-value", "local function f() return 1 end "
     "print(f == f, f == f)", None, "run"),
    # a closure as a table value, and two different closures are different
    ("upvalue-distinct", "local function mk() local x = 0 return function() "
     "return x end end print(mk() == mk())", None, "run"),
    # a captured local that shadows an outer one of the same name: two cells
    ("upvalue-shadow", "local x = 'outer' local function f() local x = 'inner' "
     "return function() return x end end print(f()(), x)", None, "run"),
    # a closure over a while-body local
    ("upvalue-while", "local out = {} local i = 0 while i < 3 do i = i + 1 "
     "local y = i out[i] = function() return y end end print(out[1](), out[3]())",
     None, "run"),
    # pcall of a closure: the protected frame carries the closure with it
    ("upvalue-pcall", "local x = 7 local f = function() return x end "
     "print(pcall(f))", None, "run"),
    # xpcall's handler is a closure too.  The handler returns a fixed string:
    # PUC prefixes an error message with the chunk and line and the chip has no
    # line at run time, so the text itself is not comparable.
    ("upvalue-xpcall", "local msg = 'boom' local function bad() error(msg) end "
     "print(xpcall(bad, function(e) return 'caught' end))", None, "run"),
    # method sugar on a closure stored in a table
    ("upvalue-method", "local t = {} local n = 5 function t:get() return n end "
     "print(t:get())", None, "run"),
    # a closure built inside a generic-for body
    ("upvalue-generic-for", "local out = {} for _, v in ipairs({'a', 'b'}) do "
     "out[#out + 1] = function() return v end end print(out[1](), out[2]())",
     None, "run"),
    # a captured local in a repeat body
    ("upvalue-repeat", "local out = {} local i = 0 repeat i = i + 1 "
     "local y = i out[i] = function() return y end until i == 3 "
     "print(out[1](), out[3]())", None, "run"),
    # closures in the standard library's own idiom: pairs/ipairs are functions
    # that return an iterator, which is a closure over the state
    ("upvalue-iter-state", "local function range(n) local i = 0 "
     "return function() i = i + 1 if i <= n then return i end end end "
     "local s = 0 for v in range(4) do s = s + v end print(s)", None, "run"),
    # A `local function` nested in a function literal that is assigned to a
    # *field*: the literal's saved parser state was popped by the inner head on
    # its way out, so the field store never ran and t.f read back nil.  The other
    # three shapes are here because the bug was the save/restore pairing on every
    # named head, not this one arrangement.
    ("nested-local-function", "local t = {} t.f = function() local function g() "
     "return 1 end return g() end print(t.f())", None, "run"),
    ("nested-local-function-field", "local t = {} function t.f() local function g() "
     "return 1 end return g() end print(t.f())", None, "run"),
    ("nested-local-function-anon", "local t = {} t.f = function() local g = "
     "function() return 1 end return g() end print(t.f())", None, "run"),
    ("nested-local-function-plain", "local function outer() local function g() "
     "return 1 end return g() end print(outer())", None, "run"),
    # pcall of a library wrapper that calls a gate: the wrapper is variadic, so
    # this covers both the argument the gate names in an error and the last one
    # it reads as the init.
    ("pcall-gate-args", "print(pcall(string.find, 'abc'))", None, "run"),
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
                                "foo-bar!|foo", "21.75/table: 0x0", 0],
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
    ("tab-tostring", "print(type({}), tostring({1}))", None, "run"),
    ("tab-tostring-shape", "local t = {} local s = tostring(t) "
     "print(s:match('^table: ') ~= nil, s ~= 'table')", None, "run"),
    ("tab-missing", "t = {} print(t.nope, t[99])", None, "run"),
    ("tab-speckeys", "t = {} t['a#b'] = 1 t['a$b'] = 2 "
     "t['k@v'] = 3 t['x:y'] = 4 "
     "print(t['a#b'], t['a$b'], t['k@v'], t['x:y'])", None, "run"),
    ("tab-getnil-diff", "t = {} print(t[nil])", None, "runtimerr",
     {"expect": {"err": "table index is nil"}}),
    ("tab-set-nonint", "t = {} t[1.5] = 1", None, "runtimerr",
     {"expect": {"err": "non-integer number keys"}}),
    ("tab-set-nil-key", "t = {} t[nil] = 1", None, "runtimerr",
     {"expect": {"err": "table index is nil"}}),
    ("tab-idx-nontable", "x = 5 print(x[1])", None, "haltfail"),
    ("tab-len-nontable", "print(#5)", None, "haltfail"),
    ("tab-toomany", "t = {} i = 0 while i < 65 do t[#t+1] = {} "
     "i = i+1 end", None, "runtimerr",
     {"expect": {"err": "too many tables"}}),
    ("tab-oom", "t = {} i = 0 while i < 70 do t[i] = {} i = i+1 end", None,
     "runtimerr", {"expect": {"err": "too many tables"}}),
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
    # outInt0 is a typed int port: an integral float is stored as an integer,
    # so the program reads back 7 where plain Lua would keep 7.0.
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
    """As many globals as the chip has room for: MAX_GLOBALS less the slots it
    pre-declares (outputs, inputs, builtins, the two int globals).  Derived from
    the spec rather than counted by hand, because a hardcoded 30 is one builtin
    away from being one too many -- which is how adding _fmt broke this case."""
    n = spec.MAX_GLOBALS - len(spec.GSLOT_ORDER)
    lines = []
    for k in range(n):
        lines.append(f"v{k} = {k}*2+1")
    lines.append("print(" + ", ".join(f"v{k}" for k in range(0, n, 10)) + ")")
    return "\n".join(lines) + "\n"


def build_overcap():
    """A program that must not fit: 40 statements of 26 additions is just over
    MAX_INSTR instructions (see the limits in lua.ws and tests/spec.py)."""
    return "\n".join(
        "v0 = %s" % "+".join(str((k + j) % 9 + 1) for j in range(26))
        for k in range(40)) + "\n"
