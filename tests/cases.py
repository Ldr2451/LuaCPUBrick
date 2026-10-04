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
DEMO_KW = {"innumarr": [10.0, 20.0, 30.0],
           "instrarr": ["alpha", "beta", "gamma"],
           "sinputs": {0: "foo", 1: "bar"}}
DEMO_LOG = (              "arith	2.25	7.0	-4	-4	-0.5\n"
              "bits	1	11	6	-1	16	15\n"
              "str	foo-bar!	8\n"
              "cmp	false	a\n"
              "b\n"
              "logic	2	dflt\n"
              "logic2	false	nil	function\n"
              "tab	3	2.25	foo\n"
              "tab2	1.0	yes	7.0\n"
              "tab3	true	true\n"
              "func	120	42\n"
              "func2	14	10\n"
              "vararg	3	7	8	9\n"
              "vararg2	3	1	2	3\n"
              "closure	2	3	function	function\n"
              "pcall	false\n"
              "pcall2	false	false	nope\n"
              "xpcall	false	handled\n"
              "assert	6	unreached\n"
              "loops	25	1p2q	3	2\n"
              "shadow	inner\n"
              "sugared\n"
              "grade	B\n"
              "dupstore	7\n"
              "flow	55	2	1	second\n"
              "inputs	60.0	10.0	20.0\n"
              "inputs2	nil	nil	10.0	20.0	30.0\n"
              "names	alpha	nil	5\n"
              "outs\n"
              "outs2\n"
              "\n"
              "check	55	foo-bar!	2.25\n")


def _locdecls(n):
    return " ".join("local v%d = %d" % (i, i) for i in range(n))


def _oldest_read(n):
    """A function with n live locals that reads the OLDEST one.

    locFind resolves a name by walking backwards down a fixed-depth ladder of
    live locals, so the ladder's depth decides how old a local can be and still
    be found.  Too shallow and the miss is indistinguishable from a global:
    `return v0` compiled to LOADGLOBAL and answered nil where PUC answers 0,
    with nothing on `err` or `progDebug` to say so.  That is a silent wrong
    answer, which is why these read the oldest local rather than the newest --
    a newest-local case passes at any depth and proves nothing.
    """
    return "local function f() %s return v0 end print(f())" % _locdecls(n)


def _global_read(n):
    """A global read with a deep live-local table behind it.

    The other half of the same rule: a ladder that reaches every live local can
    still miss, and that miss MUST keep meaning 'global'.  If a fix ever made
    an unresolved name an error instead, this stops compiling.  30 locals, not
    60: a global read costs a register of its own, and at 60 this case failed on
    the register limit instead -- passing for a reason that had nothing to do
    with the rule it is here to pin.
    """
    return ("flag = 9 local function f() %s return v0, flag end print(f())"
            % _locdecls(n))


def _outer_read(n):
    """An inner closure reading an outer local, past the old ladder depth.

    Same ladder, reached through resolveUp rather than a direct read, so it is
    the case that would survive a fix that only widened the direct path.  29, not
    31: the inner function's own locals are live at the reference too, so a
    cross-frame read costs the outer locals AND the closure's.
    """
    return ("local function f() %s local g = function() return v0 end "
            "return g() end print(f())" % _locdecls(n))



TAIL_LOOP = ("local function loop(n, a) if n == 0 then return a end "
             "return loop(n - 1, a + n) end\n")


TESTS = [
    ("lit-num", "print(3)", None, "run"),
    ("lit-float", "print(3.5)", None, "run"),
    ("lit-exp", "print(1e3, 1.5e-2)", None, "run"),
    ("lit-dot", "print(.5, 5.)", None, "run"),
    ("lit-exp-dot", "print(5.e3, 5.)", None, "run"),
    ("lit-hex", "print(0xff, 0X10, 0xFFFFFFFFFFFFFFFF)", None, "run"),
    # tonumber is a piece over the arithmetic coercion (v + 0 is PUC's
    # conversion), so these are really a second reading of the coercion rules:
    # a number is itself, the whole string has to be a number, the tag follows
    # the numeral's shape, and the inf/nan spellings are nil on both sides.
    # Each case carries a tick budget: the piece costs ~3700 ticks of boot
    # (3514 characters at the code rate, plus a second function) and 70 per
    # call, so even a case that errors needs the full boot before it can fail.
    ("tonum-num", "print(tonumber(3), tonumber(3.5), tonumber(-0.0))",
     None, "run", {"ticks": 9000}),
    ("tonum-str", "print(tonumber('10'), tonumber(' 42 '), tonumber('3.5'), "
     "tonumber('1e3'), tonumber('.5'), tonumber('5.'))", None, "run",
     {"ticks": 6000}),
    ("tonum-nil", "print(tonumber('x'), tonumber(''), tonumber('10abc'), "
     "tonumber(nil), tonumber({}), tonumber(true), tonumber('inf'), "
     "tonumber('nan'))", None, "run", {"ticks": 6000}),
    ("tonum-tag", "print(math.type(tonumber('3')), math.type(tonumber('3.0')), "
     "math.type(tonumber(3)), math.type(tonumber(3.5)))", None, "run",
     {"ticks": 6000}),
    ("tonum-arith", "print(tonumber('3') + 1, tonumber('7') // 2, "
     "-tonumber('2.5'))", None, "run", {"ticks": 9000}),
    # The loader only installs the piece for a program that names tonumber, so
    # this also proves the selection: a program that does not name it must not
    # pay for it, and one that does must not be missing it inside a function.
    ("tonum-in-fn", "local function half(s) return tonumber(s) / 2 end "
     "print(half('7'), half(7))", None, "run", {"ticks": 9000}),
    ("tonum-base10", "print(tonumber('42', 10), tonumber(' 42 ', 10))",
     None, "run", {"ticks": 9000}),
    ("tonum-noargs", "print(tonumber())", None, "runtimerr",
     {"ticks": 9000,
      "expect": {"err": "bad argument #1 to 'tonumber' (value expected)"}}),
    ("tonum-base-type", "print(tonumber(3.5, 10))", None, "runtimerr",
     {"ticks": 9000, "expect": {"err": "string expected, got number"}}),
    ("tonum-base-range", "print(tonumber('10', 99))", None, "runtimerr",
     {"ticks": 9000, "expect": {"err": "base out of range"}}),
    # A base other than 10 used to be a documented gap (loud, never a wrong
    # answer) and is now PUC's integer grammar -- see the tonum-base-* cases at
    # the end of the puc group.  There is no case here for the old error.
    # A call with no results still has to leave the callee's own register nil,
    # because that is the slot the compiler puts the local in.  select past the
    # end and an empty unpack both answer nothing, and both used to leave the
    # FUNCTION there: local c = select(2, ...) read type(c) == "function".
    ("select-none", "local function f(...) local c = select(2, ...) "
     "print(c, type(c)) end f('x')", None, "run"),
    ("select-none-flat", "local x = select(2, 'a') local y, z = select(3, 'a') "
     "print(x, type(x), y, type(y), z, type(z))", None, "run"),
    ("unpack-empty", "local y = table.unpack({1, 2}, 2, 1) "
     "print(y, type(y))", None, "run"),
    ("unpack-empty-fn", "local function g(...) local z = table.unpack({1, 2}, 2, 1) "
     "print(z, type(z)) end g('x')", None, "run"),
    ("int-arith", "print(7+8, 7-8, 7*8, -7, 2+2.0, 7/2)", None, "run"),
    # PUC coerces a string operand in arithmetic ('3' + 1 is 4) through the
    # host's ParseInt/ParseNumber gates.  The int/float split is the host's own
    # rule -- an integer numeral with no '.', 'e' or 'E' is tagged an integer --
    # so '2' + 1 is 3 and '2.0' + 1 is 3.0, and the operand register itself is
    # not rewritten (type(s) is still "string" afterwards).
    ("coerce-int", "print('3' + 1, 1 + '3', '10' - '4', '3' * '4', "
     "'7' // 2, -'7' // 2, -'3')", None, "run"),
    ("coerce-float", "print('  2.5  ' * 2, '1e3' + 0, '2' ^ '3', '2' + 1, "
     "'2.0' + 1, '2e0' + 1)", None, "run"),
    ("coerce-keep", "local s = '3' local n = s + 1 print(s, n, type(s), "
     "math.type(n))", None, "run"),
    ("coerce-var", "local function half(t) return t .. ' / 2 = ' .. (t / 2) end "
     "print(half('7'), half(7))", None, "run"),
    # A string that is not a number raises with the operator's own wording, and
    # anything else names the offending operand: PUC's two forms.  One case for
    # the whole rule, so the recorded chip log is the only place the messages are
    # spelled out.  PUC prefixes each with its chunk and line; the chip has no line.
    ("coerce-err-msgs", "print(pcall(function() return 'x' + 1 end), "
     "pcall(function() return 'x' - 1 end), "
     "pcall(function() return 1 - 'x' end), "
     "pcall(function() return 'x' * 1 end), "
     "pcall(function() return 'x' / 1 end), "
     "pcall(function() return 'x' % 1 end), "
     "pcall(function() return 'x' // 1 end), "
     "pcall(function() return 'x' ^ 1 end), "
     "pcall(function() return -'x' end), "
     "pcall(function() return {} + 1 end), "
     "pcall(function() return 1 / nil end), "
     "pcall(function() return '10abc' + 0 end))", None, "run"),
    # Comparison and the bitwise operators do NOT coerce in PUC, and the chip
    # must not start to.  The four type-error messages used to be a bare "attempt
    # to compare" / "attempt to perform 'bitwise'" / "attempt to get length" /
    # "attempt to concatenate" with no type in them; PUC names the operand (or
    # both), so the cases below assert the wording, which is why they are
    # runtimerr cases with an expected message rather than log comparisons.
    ("coerce-nocmp", "local ok, err = pcall(function() return '3' < 5 end) "
     "print(ok, type(err))", None, "run"),
    ("coerce-nobits", "local ok, err = pcall(function() return '3' & 1 end) "
     "print(ok, type(err))", None, "run"),
    ("coerce-nocmp2", "local ok = pcall(function() return '3' == 3 end) "
     "print(ok)", None, "run"),
    # PUC's four messages, read off the oracle rather than guessed: the compare
    # names both types unquoted, the other three name the offending operand, and
    # the bitwise one adds "(constant 'x')" when the operand is a literal, which
    # the chip cannot know and deliberately stops short of.
    ("err-cmp-types", "print(1 < 'x')", None, "runtimerr",
     {"expect": {"err": "attempt to compare number with string"}}),
    ("err-cmp-types2", "print('a' < 1)", None, "runtimerr",
     {"expect": {"err": "attempt to compare string with number"}}),
    ("err-bitwise", "print(1 & 'x')", None, "runtimerr",
     {"expect": {"err": "attempt to perform bitwise operation on a string "
                         "value"}}),
    ("err-length", "print(#nil)", None, "runtimerr",
     {"expect": {"err": "attempt to get length of a nil value"}}),
    ("err-length-fn", "print(#print)", None, "runtimerr",
     {"expect": {"err": "attempt to get length of a function value"}}),
    ("err-concat", "print(1 .. {})", None, "runtimerr",
     {"expect": {"err": "attempt to concatenate a table value"}}),
    # The host's parse is Rust's FromStr, which takes no "0x10", so this raises
    # where PUC says 16: a host limit, so the case asserts the chip is loud and
    # the header records the gap.
    ("coerce-hex", "print('0x10' + 0)", None,
     "runtimerr", {"expect": {"err": "attempt to add a 'string' with a 'number'"}}),

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
    ("fmt-div0", "print(1/0, -1/0)", None, "run"),
    # The value, not the spelling: the chip's tostring writes "nan" where PUC's
    # C library writes "-nan" (the x86 default QNaN has its sign bit set), and
    # a raw float never reaches a host text gate here -- see CHIP_LOG.
    ("fmt-nan0", "print(0/0 ~= 0/0, 0/0 == 0/0, 0/0 ~= 0)", None, "run"),
    ("fmt-mod0", "print(5%0)", None, "runtimerr",
     {"expect": {"err": "attempt to perform 'n%0'"}}),
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
    # a zero divisor is the host's IEEE answer, not a guard: the wire gate
    # divides to inf/nan (the wirescript compiler's own law is `x / y`), so the
    # chip has to carry those values instead of folding them to 0.0
    ("arith-div-inf", "print(1/0, -1/0, 1/0 > 1e300, -1/0 < -1e300)", None,
     "run"),
    ("arith-div-nan", "print(0/0 == 0/0, 0/0 ~= 0/0)", None, "run"),
    ("arith-div-negzero", "print(1/(0.0 * -1) < -1e300)", None, "run"),
    ("arith-pow-zero", "print(0.0^-1, 0^-1, 2^-2)", None, "run"),
    ("arith-pow-nan", "print((-8)^0.5 ~= (-8)^0.5, math.type(0.0^-1))", None,
     "run"),
    ("arith-ln-zero", "print(math.log(0), math.log(1) < 0)", None, "run"),
    ("arith-sqrt-neg", "print(math.sqrt(-1) ~= 0, math.sqrt(4))", None, "run"),
    ("arith-negzero", "print(-0.0, 1/(-0.0), 0.0 * -1)", None, "run"),
    ("arith-idiv-zero", "print(1 // 0)", None, "runtimerr",
     {"expect": {"err": "attempt to divide by zero"}}),
    ("arith-mod-zero", "print(1 % 0)", None, "runtimerr",
     {"expect": {"err": "attempt to perform 'n%0'"}}),
    ("arith-idiv-zero-float", "print(1.0 // 0.0, -1.0 // 0.0)", None, "run"),
    ("assert-noargs", "print(1) assert()", None, "runtimerr",
     {"expect": {"err": "value expected"}}),
    ("assert-noargs-pcall", "print(pcall(assert))", None, "run"),
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
    # The locFind ladder: how deep a live-local table a name reference can see.
    # 30 was the old depth, and the boundary is the whole point -- at 31 the
    # oldest local resolved as a global and the answer was nil, silently.
    # The depth is tools/chip/ladder.py's, and the two edge cases sit ON it, so
    # raising the depth means moving these two with it.
    ("locals-oldest-29", _oldest_read(29), None, "run"),
    ("locals-oldest-30", _oldest_read(30), None, "run"),
    ("locals-oldest-31", _oldest_read(31), None, "run"),
    ("locals-oldest-past-ladder", _oldest_read(32), None, "reject"),
    ("locals-past-frame", _oldest_read(64), None, "reject"),
    ("locals-global-deep", _global_read(30), None, "run"),
    ("locals-outer-29", _outer_read(29), None, "run"),
    # `function f()` is `f = function()`, and it used to store through a
    # SETGLOBAL whatever the name resolved to: `local a; function a() end` wrote
    # a GLOBAL named a and left the local nil, so the first call said "attempt
    # to call" with nothing wrong at the assignment.  One case per resolution
    # the store can land on.
    ("fndef-local", "local f function f() return 7 end print(f())", None, "run"),
    ("fndef-local-redef",
     "local f function f() return 1 end local a = f() "
     "function f() return 2 end print(a, f())", None, "run"),
    ("fndef-local-no-global-left",
     # after the block the local is out of scope, so a `function g()` that had
     # written a global would show one here
     "do local g = 1 function g() return 'local' end print(g()) end print(g)",
     None, "run"),
    ("fndef-upvalue",
     "local function o() local u = 'x' function u() return 'wrote' end return u() end "
     "print(o())", None, "run"),
    ("fndef-captured-by-body-after",
     "do local q = 1 function q() return 'def' end "
     "local function g() return q() end print(g()) end", None, "run"),
    ("fndef-captured-by-body-before",
     "do local q = 1 local function g() return q() end "
     "function q() return 'def' end print(g()) end", None, "run"),
    ("fndef-nested-still-nests",
     "function o2() function i2() return 'inner' end return i2() end print(o2())",
     None, "run"),
    ("fndef-selfrec-unaffected",
     "local function fact(n) if n <= 1 then return 1 end return n * fact(n-1) end "
     "print(fact(6))", None, "run"),
    ("fndef-method-still-works",
     "local M = {v = 41} function M:add(k) return self.v + k end print(M:add(1))",
     None, "run"),
    # in SKIP: `local function f` that a nested function captures.  Kept as a
    # case so the shape is named and turns green the day the double
    # declaration is fixed; see the entry in test_chip_suite's SKIP.
    ("localfn-captured-by-inner",
     "local function make(k)\n"
     "  local function step(n) return make(k) end\n"
     "  return step\n"
     "end\nprint(make('K')())", None, "run"),
    # Proper tail calls: `return f()` reuses the frame, so the depth does not
    # grow.  250 and not 1000, because MAX_CALLS is 200 and anything past it
    # separates TCO from "call depth exceeded" just as well -- and the suite's
    # time is its slowest case (1000 deep cost 21s, 1001 mutual 40s).
    ("tail-deep", TAIL_LOOP + " print(loop(250, 0))", None, "run"),
    ("tail-mutual",
     "local even, odd\n"
     "function even(n) if n == 0 then return true end return odd(n - 1) end\n"
     "function odd(n) if n == 0 then return false end return even(n - 1) end\n"
     "print(even(251), odd(251))", None, "run"),
    ("tail-not-parenthesised",
     "local function inner(n) return n * 2 end\n"
     "local function outer() return (inner(21)) end print(outer())", None, "run"),
    ("tail-variadic",
     "local function va(...) return select('#', ...) end\n"
     "local function fwd(...) return va(...) end print(fwd(1, 2, 3, 4, 5))",
     None, "run"),
    ("tail-multi-value",
     "local function three() return 1, 2, 3 end\n"
     "local function p() return three() end\n"
     "local function o() return p() end print(o())", None, "run"),
    ("tail-inside-for",
     "local function sumto(n, a) if n == 0 then return a end "
     "return sumto(n - 1, a + n) end local t = 0\n"
     "for i = 1, 3 do t = sumto(i * 90, t) end print(t)", None, "run"),
    ("tail-callee-wants-more-cells",
     "local function wide(a, b, c, d)\n"
     "  local x1, x2, x3 = a, b, c\n"
     "  local function use(p) if p == 0 then return x1 + x2 + x3 + d end "
     "return use(p - 1) end\n"
     "  return use(a * 100)\n"
     "end print(wide(2, 3, 4, 5))", None, "run"),
    ("tail-pcall-not-a-tail",
     "print(pcall(function(n) if n == 0 then error('boom') end "
     "return (function() return n end)() end, 3))", None, "run"),
    ("assign-multi", "a, b = 1, 2 print(a, b)", None, "run"),
    ("assign-swap", "a, b = 10, 20 a, b = b, a print(a, b)", None, "run"),
    ("assign-short", "a, b, c = 1 print(a, b, c)", None, "run"),
    ("global-write", "g = 41 g = g+1 print(g)", None, "run"),
    ("inputs-sum", "print(inNum0+inNum1+inNum2+inNum3)",
     [1, 2, 3, 4], "run"),
    ("inputs-each", "print(inNum0, inNum1, inNum2, inNum3, inStr0, inStr1, innumarr(1), innumarr(2), "
     "innumarr(3))",
     [8, 7, 6, 5], "run",
     {"sinputs": {0: "a", 1: "b"}, "vec": (1, 2, 3)}),
    ("inputs-expr", "print(inNum0*2, inStr0 .. '!', inNum3%inNum1)",
     [10, 3, 0, 7], "run", {"sinputs": {0: "hey"}}),
    ("inputs-arr3", "print(innumarr(1)+innumarr(2)+innumarr(3))", None, "run",
     {"innumarr": [1.5, 2.5, 3.0]}),
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
    # RETURNM (op 42) is `return <fixed>, <call>`: the fixed values plus
    # everything the call produced.  It had NO case here, and that gap is why a
    # TRUNCATED op == 42 arm sat in vmStepFast for a session -- outside the
    # fast-path guard, so it matched nothing and did nothing, while every
    # RETURNM paid four wasted fast dispatches.  772 cases and 400 fuzz seeds
    # all passed, because none of them emitted this opcode.  A net caught it
    # rather than a test, which is backwards, so the opcode has cases now.
    ("retm-call", "function g() return 7 end function h() return 1, g() end "
     "print(h())", None, "run"),
    ("retm-call2", "function g() return 7, 8 end function h() return 1, g() end "
     "print(h())", None, "run"),
    ("retm-call-mid", "function g() return 7 end function h() return 1, g() end "
     "print(9, h(), 8)", None, "run"),
    ("retm-call-only", "function g() return 7 end function h() return g() end "
     "print(h())", None, "run"),
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
    ("stdlib-tables", "print(type(math), type(string), type(table), type(io))",
     None, "run"),
    ("print-shadow", "print = 5 print(print)", None, "haltfail"),
    ("str-call-sugar", "print 'hi'", None, "run"),
    # iteration library (prepended Lua source over the next() primitive)
    ("iter-ipairs", "local t = {10, 20, 30} local s = 0 for i, v in ipairs(t) "
     "do s = s + v end print(s, i)", None, "run"),
    ("iter-pairs", "local t = {a=1, b=2, c=3} local s = 0 for k, v in pairs(t) "
     "do s = s + v end print(s)", None, "run"),
    ("iter-pairs-arity", "print(select('#', pairs({})))", None, "run"),
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
    # PUC takes every one of these through luaL_checklstring, which ACCEPTS A NUMBER
    # and converts it -- so string.len(999) is 3 and string.sub(12345, 2, 3) is "23".
    # Here they raised "attempt to get length of a number value", because `#s` is an
    # opcode with no coercion in front of it.
    #
    # The case that made this worth finding is str-coerce-case-upper: the _s case
    # gate did not RAISE on a number, it answered "UPPER" -- the literal never appears
    # in the program, so nothing anywhere said a value was mistyped.  A wrong answer
    # is worse than an error, and this one was silent.
    #
    # And it is NOT a missing string metatable, which is what it looked like:
    # ('A').byte(1) was the probe that suggested one, and op 29 already falls back to
    # the string table for a string receiver.  PUC does not prepend the receiver for a
    # dot call either -- ('A').byte(1) is string.byte(1) there, and that is 49 -- so
    # the whole divergence was this one coercion.
    ("str-coerce-number", "print(string.byte(1), string.len(999), "
     "string.sub(12345, 2, 3), string.reverse(123))", None, "run"),
    ("str-coerce-case", "print(string.upper(42), string.lower(42), "
     "string.upper('ab'), string.lower('AB'), string.upper(1.5))", None, "run"),
    ("str-coerce-method", "print(('abc'):upper(), ('123'):reverse(), "
     "('42'):len(), ('77'):byte(1))", None, "run"),
    # A number that does NOT convert must still raise, and with PUC's wording: the
    # coercion is a number check, not a blanket tostring.  Three of these were SILENT
    # -- string.len({}) answered 0 and string.rep({}, 2) answered nil, where PUC
    # refuses a table, and a silent nil is the shape of bug that costs a session.
    ("str-coerce-refused", "print(pcall(string.len, {})) "
     "print(pcall(string.upper, nil)) print(pcall(string.rep, {}, 2))", None,
     "run"),
    ("str-coerce-refused-more", "print(pcall(string.sub, {})) "
     "print(pcall(string.byte, {})) print(pcall(string.lower, {})) "
     "print(pcall(string.reverse, {}))", None, "run"),
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
    ("meth-multi-return", "local t = {} function t:f(a, b) return a, b end "
     "print(t:f(1, 4))", None, "run"),
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
    # string.format called from inside a function reads its arguments through
    # an index that had vmBase in it twice, so every argument but the last came
    # from two registers too high.  At top level vmBase is 0 and it worked, which
    # is what made it look like an inlining problem rather than arithmetic.
    ("fmt-in-fn", "local function f() return string.format('%d', 5) end "
     "print(f())", None, "run"),
    ("fmt-in-fn-args", "local function f() "
     "return string.format('%s%s%s %5.2f', 'a', 'b', 'c', 3.14159) end "
     "print(f())", None, "run"),
    ("fmt-in-fn-param", "local function g(x, y) "
     "return string.format('%s=%d', x, y) end print(g('k', 7))", None, "run"),
    ("fmt-in-fn-error", "local ok, e = pcall(function() "
     "return string.format('%d', 'x') end) "
     "print(ok, e:find('got string') ~= nil)", None, "run"),
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
    # it on the tie and cannot say which side.  tools/fmt/fmtsweep.py compares 3888
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
    # A gate that answers through a micro-step (_fmt, _pat, _gmatch) used to be
    # completed the tick it started, so the protected call was already over when
    # the work raised: the error ended the program instead of answering
    # false, message, and a second run of the abandoned machine finished it off.
    # The message itself names the gate by its short name where PUC names it by
    # its library path (a value passed to pcall), so these check the shape of the
    # answer and that the program carries on, not the exact wording.
    ("pcall-fmt-gate-error", "local ok, e = pcall(string.format, '%d', 'x') "
     "print(ok, e:find('number expected') ~= nil) print('after')", None, "run"),
    # ... and this one the whole message, position prefix and name included.
    ("pcall-gate-name", "print(pcall(string.format, '%d', 'x'))", None, "run"),
    ("pcall-fmt-gate-ok", "print(pcall(string.format, '%d', 5))", None, "run"),
    ("pcall-fmt-gate-ok2", "print(pcall(string.format, '%s=%d', 'a', 2))", None,
     "run"),
    ("pcall-fmt-gate-twice", "print(pcall(string.format, '%d', 1)) "
     "print(pcall(string.format, '%d', 2))", None, "run"),
    ("pcall-pat-gate-error", "print(pcall(string.find, 'abc', '[', 1))", None,
     "run"),
    ("pcall-pat-gate-ok", "print(pcall(string.find, 'abc', 'b'))", None, "run"),
    ("pcall-gate-then-more", "local ok = pcall(string.format, '%d', 'x') "
     "for i = 1, 2 do print(i) end print(ok, "
     "pcall(string.format, '%d', 3))", None, "run"),
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
    # A maximal repeat whose tail then misses AT THE END OF THE SUBJECT.  This is
    # the case that looped for ever: ("abc"):match(".*c") never finished on a
    # three-character subject, so a user program with `s:match(".*x")` hung.
    #
    # The cause was not the greedy loop, which five separate attempts blamed (and
    # four of which were rejected for breaking other cases): patTestItem's
    # end-of-subject miss returned without writing the item's extent, so patApply
    # -- which reads the quantifier off that extent, because every item here goes
    # through it -- read the `*` belonging to the `.` three pattern positions back
    # and gave the pattern zero more repetitions at the position it was already
    # at.  PUC cannot reach this shape, because a failed match() returns NULL and
    # do_match backtracks without reading a quantifier at all.
    #
    # So the rule the cases below have to hold is: a miss at the end of the subject
    # still leaves the item's extent honest.  Each shape is one of the ways a tail
    # can get there -- a plain literal, a set, a %-class, and with and without a
    # quantifier of its own -- and `a*b` is the one where the missed item's own
    # quantifier is legitimately read and still has to give nil.
    ("pat-greedy-tail-literal", "print(('abc'):match('.*c'), "
     "('abc'):find('.*c'), ('abcb'):match('.*b'), ('abc'):match('.*.*c'))",
     None, "run"),
    ("pat-greedy-tail-empty-subject", "print(('abc'):match('.*z'), "
     "(''):match('.*z'), ('abc'):match('a*b'), ('abc'):match('a*z'))", None,
     "run"),
    ("pat-greedy-tail-class", "print(('abc'):match('[a-c]*z'), "
     "('abc'):match('%a*z'), ('abc'):match('[%a]*z'), "
     "('abc'):match('[ab]*[bc]*'))", None, "run"),
    ("pat-greedy-tail-capture", "print(('abc'):match('(.*)c'), "
     "('abc'):match('(.*)(c)'), ('abc'):match('(%a.*%a)'))", None, "run"),
    # The other half of the same rule: an item that misses at the end of the
    # subject may still match EMPTY there, and its own quantifier is what says so.
    # These were nil against PUC's "" before the extent was computed from the
    # pattern, and they are the reason the fix cannot be "return a miss and guess
    # the extent": a guessed p + 1 is right for a literal and wrong for %x and for a
    # set, and the [%-class ones below are what catch it.
    ("pat-empty-at-end", "print(string.match('abc', 'b*$'), "
     "string.match('abc', 'a*$'), string.match('abc', 'abc*$'), "
     "string.match('abc', '(%d*)$'))", None, "run"),
    ("pat-empty-at-end-lazy", "print(string.match('abc', '(.-)$'), "
     "string.match('abc ', '(%a*)$'), string.match('abc ', 'a*$'))", None,
     "run"),
    ("pat-empty-at-end-set", "print(string.match('abc', '[a]*$'), "
     "string.match('abc ', '[a]*$'), string.match('abc', '[a]*z'), "
     "string.match('abc', '[a-c]*'), string.match('abc', '[abc]*$'), "
     "string.match('abc', '[%a]*$'))", None, "run"),
    # A set's extent is its closing bracket, and it has to be found even when there
    # is no subject character left -- so these pin the set machine running on an
    # exhausted subject rather than being skipped by it.
    ("pat-set-exhausted-subject", "print(string.match('abc', 'x[a]*$'), "
     "string.match('abc', 'x[a-c]*$'), string.match('abc', 'x[%a]*$'), "
     "string.match('abc', 'x[^a]*$'), string.match('abc', 'x[a]*'))", None,
     "run"),
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
    # PUC 5.5's gmatch answers ONE value (its iterator ignores the arguments the
    # generic for hands it); this one answers three, because the generic for has
    # to get the walk's state out of the call and there are no closures here to
    # hold it.  Recorded so the difference is visible rather than accidental.
    ("gmatch-arity", "print(string.gmatch('a b', '%a')) "
     "print(select('#', string.gmatch('a b', '%a')))", None, "run"),
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
    # PUC's math functions take luaL_checknumber, so they COERCE a string:
    # math.floor('3') is 3, math.sqrt('9') is 3.0, math.tointeger('10') is 10.
    # The conversion is the arithmetic one, so the numeral rules stay in one
    # place, and an ignored extra argument is still ignored: math.floor('3','x')
    # is 3, not an error.
    ("math-coerce", "print(math.floor('3'), math.floor(' 2.5 '), "
     "math.ceil('3.2'), math.sqrt('9'), math.tointeger('10'))", None, "run"),
    ("math-coerce-pieces", "print(math.abs('-3'), math.abs('2.5'), "
     "math.fmod('7', '3'))", None, "run"),
    ("math-coerce-extra", "print(math.floor('3', 'x'))", None, "run"),
    # A coerced string keeps PUC's type: math.abs(-3) is the integer 3 and
    # math.abs('-3') the float 3.0, so the pieces must not force a float.
    ("math-abs-type", "print(math.abs(-3), math.abs(-3.5), math.fmod(7, 3), "
     "math.type(math.abs(-3)))", None, "run"),
    # The gate names the function, as PUC's luaL_argerror does.  A runtimerr
    # rather than a run: PUC prefixes the message with its chunk and line, which
    # the chip has no way to name.
    ("math-coerce-bad", "print(math.floor('x'))", None, "runtimerr",
     {"expect": {"err": "bad argument #1 to 'floor' "
                         "(number expected, got string)"}}),
    # A math PIECE given a string that is not a number gets the arithmetic
    # message, not PUC's "bad argument #1 to 'abs'": the piece converts with
    # `x + 0.0` and that is the raise.  Loud, and the value is never wrong.
    ("math-coerce-bad-piece", "print(math.abs('x'))", None, "runtimerr",
     {"expect": {"err": "attempt to add a 'string' with a 'number'"}}),
    # modf returns floats, so the integral part prints with the chip's float
    # spelling, and the chip prints the shortest round-trip form of the
    # fraction where PUC prints 17 digits.
    ("math-modf", "print(math.modf(3.7))", None, "run"),
    # math.random is a Lua piece, so it is the one builtin whose NUMBERS are not
    # PUC's: PUC seeds xoshiro256** on a 64-bit state and the chip runs a 32-bit
    # LCG, so the same seed gives a different sequence and no program can tell
    # the difference except by comparing against PUC's own output.  The API, the
    # ranges and the float's interval ARE PUC's, so the property cases below
    # compare against the oracle and only the two sequences are pinned here.
    ("math-random-seed42",
     "math.randomseed(42) print(math.random(1, 6), math.random(1, 6), "
     "math.random(1, 6))", None, "run"),
    ("math-random-ten",
     "math.randomseed(7) local t = {} for i = 1, 5 do t[i] = math.random(10) "
     "end print(table.concat(t, ','))", None, "run"),
    # a draw advances the state, so two draws of a million-wide interval differ
    ("math-random-advances",
     "math.randomseed(1) print(math.random(1000000) == math.random(1000000))",
     None, "run"),
    # a one-wide interval is that value, and randomseed answers the two numbers
    # it seeded with, which is PUC's own return
    ("math-random-narrow", "print(math.random(2, 2), math.randomseed(3))", None,
     "run"),
    ("math-random-float",
     "math.randomseed(0) print(math.random() >= 0 and math.random() < 1)", None,
     "run"),
    # PUC's two range errors, wording and argument number included.  A Lua piece
    # raises without the "file:line:" prefix a C function gets, which is the same
    # divergence every other piece has, so only the prefix differs here.
    ("math-random-interval", "print(pcall(math.random, 5, 1))", None, "run"),
    ("math-random-noint", "print(pcall(math.random, 1.5))", None, "run"),
    # PUC's math.random takes 0, 1 or 2 arguments and answers "wrong number of
    # arguments" otherwise; a Lua function ignores the extras, so the piece has to
    # ask for the count itself.  Asked of the oracle, the argument INDEX in
    # math.random's own messages is #1 for the lower bound and for an empty
    # interval (not the upper bound's), and #2 for a non-integer upper bound.
    ("math-random-arity", "print(pcall(math.random, 1, 9, 1))", None, "run"),
    ("math-random-argidx",
     "print(pcall(math.random, 1, 1.5), pcall(math.random, 1.5, 3), "
     "pcall(math.random, 9, 1))", None, "run"),
    # math.type answers for a value of ANY type -- "integer"/"float" for a
    # number and nil for everything else -- so it must not go through the
    # number check the other _m modes share.  There was no case for it at all,
    # which is why it raised "bad argument (number expected)" for a string and
    # a table at every level of the call stack.
    ("math-type", "print(math.type(3), math.type(3.5), math.type(0/1))", None,
     "run"),
    ("math-type-nonnum", "print(math.type('x'), math.type({}), "
     "math.type(nil), math.type(true))", None, "run"),
    ("math-type-in-fn", "local function f(v) return math.type(v) end "
     "print(f(7), f(7.5), f('s'))", None, "run"),
    ("math-tointeger", "print(math.tointeger(3.0), math.tointeger(3.5), "
     "math.tointeger(2^70))", None, "run"),
    # table library
    ("tbl-insert", "local t = {1,2} table.insert(t, 3) table.insert(t, 1, 0) "
     "print(#t, t[1], t[2], t[3], t[4])", None, "run"),
    ("tbl-remove", "local t = {1,2,3} print(table.remove(t), "
     "table.remove(t, 1), #t, t[1])", None, "run"),
    # PUC's bound is 1..n+1 (so remove(t, n+1) is legal and answers nil), and
    # a position outside it is an error rather than a silent shift: the piece
    # used to write t[0] and leave the array shifted.
    ("tbl-remove-bounds", "table.remove({1,2,3}, 0)", None, "runtimerr",
     {"expect": {"err": "position out of bounds"}}),
    ("tbl-remove-n-plus-1", "local t = {1,2} print(table.remove(t, 3), "
     "table.remove(t, 1), #t)", None, "run"),
    ("tbl-remove-empty", "print(pcall(table.remove, {}), "
     "pcall(table.remove, {}, 1))", None, "run"),
    ("tbl-concat", "print(table.concat({'a','b','c'}), "
     "table.concat({'a','b','c'}, '-'), table.concat({1,2,3}, ',', 2, 3))",
     None, "run"),
    ("tbl-unpack", "print(table.unpack({7,8,9}))", None, "run"),
    ("tbl-unpack-range", "print(table.unpack({1,2,3,4}, 2, 3))", None, "run"),
    # A name built at RUN TIME.  The loader's gate is a text search, so this only
    # works because the gate also fires on the name as a quoted literal -- see
    # srcNames in lua.ws for the measurement and the shape it cannot see (a name
    # assembled from pieces, or arriving from a port).
    #
    # Each of these is one half of a piece that was SPLIT out of a bigger one, and
    # the case that matters is the second half of each pair: naming the sibling in
    # text used to install both, so reaching this one dynamically worked, and a
    # naive split turned that into "attempt to call".  The mixed pairs are here
    # together for that reason.
    ("lib-split-dynamic-table", "local k = 'unpack' print(table[k]({1,2})) "
     "local j = 'pack' print(table[j](1,2).n) "
     "local m = 'move' print(table[m]({1}, 1, 1, 1) ~= nil)", None, "run"),
    ("lib-split-dynamic-math", "local a = 'max' print(math[a](1, 5)) "
     "local b = 'fmod' print(math[b](7, 3))", None, "run"),
    ("lib-split-dynamic-string", "local k = 'char' print(('')[k](65)) "
     "local j = 'byte' print(string.byte('A', 1))", None, "run"),
    # THE REGRESSION THESE GATES EXIST TO PREVENT: table.insert named in text,
    # table.remove reached dynamically.  One piece installed both, so this worked;
    # split naively it raises.  Same shape for the other three pairs.
    ("lib-split-mixed-table", "local k = 'insert' local t = {} table[k](t, 7) "
     "table.remove(t, 1) print(#t) "
     "local j = 'remove' local u = {1,2} print(table[j](u), #u)", None, "run"),
    ("lib-split-mixed-math", "local a = 'max' print(math[a](1, 5)) "
     "print(math.fmod(7, 3)) "
     "local b = 'min' print(math[b](9, 2)) print(math.modf(1.5))", None, "run"),
    ("lib-split-mixed-string", "local k = 'char' print(string.char(66)) "
     "print(string.byte('A', 1))", None, "run"),
    # What the quoted spelling must NOT cost: these words as data, inside one longer
    # string, install nothing.  Measured 15 ticks against 15 for print(1).
    ("lib-split-words-are-not-names", "print('max min pack move insert remove "
     "byte char fmod modf unpack')", None, "run"),
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
    # `and`/`or` compile to a jump, so their pop has to consume the LEFT operand's
    # entry as well as the right one.  It did not, and the leftover was only read
    # by a call's `)`, which drains to the depth its `(` recorded and takes ONE
    # value: the call then read two arguments where there was one and the
    # enclosing comparison's operands came out as (the argument, the call).  Every
    # one of these answers PUC only because the pop is fixed, so if it regresses
    # they all break at once.
    ("logic-arg-cmp", "print('a' < tostring(false or false))", None, "run"),
    ("logic-arg-cmp-and", "print('a' < tostring(false and true))", None, "run"),
    ("logic-arg-cmp-noquote",
     "print(('a') < (tostring(false or false)))", None, "run"),
    ("logic-arg-cmp-local",
     "local s = 'a' print(s < tostring(false or false))", None, "run"),
    ("logic-arg-len", "print(#tostring(false or false))", None, "run"),
    ("logic-arg-add", "print(1 + (tostring(false or false) and 1 or 2))", None,
     "run"),
    ("logic-arg-nested",
     "print('a' < tostring(1 and 2 or 3) .. tostring(false or 1))", None,
     "run"),
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
     "s = s+i i = i+1 end print(s)", None, "run",
     {"expect": {"finished": True}}),
    ("life-proc", "local function spin(n) print('start') while true do "
     "n = n + 1 outnum(1, n) end end spin(0)", None, "lifecycle",
     {"expect": {"log": "start\n", "checkpoints": [300, 600, 900]}}),
    ("life-prog", "local n = 0 print('start') while true do "
     "n = n + 1 outnum(1, n) end", None, "lifecycle",
     {"expect": {"log": "start\n", "checkpoints": [300, 600, 900]}}),
    # WHEN the run edge arrives, not just that one does.  A game program is
    # pasted first and run is toggled afterwards, and the first high has to work
    # exactly like the second: the chip parsed the program while run was low, so
    # the parse is over and the edge is the only thing that starts the VM.
    ("life-run-high-after-parse", "print('hi') outnum(1, 7)", None,
     "lifecycle",
     {"phases": [{"ticks": 1200, "run": False}, {"ticks": 600, "run": True}],
      "expect": {"progress": False, "finished": True, "log": "hi\n"}}),
    # Editing the program WHILE STOPPED, then starting it, found in game: the log
    # could come back with the new line printed TWICE.  Both programs are valid, so
    # nothing here is a rejection - the shape is the order of the two edges, where
    # the program arrives while run is low and the parse may still be in flight when
    # run goes high, so the start and the parse-completion can both act.
    ("life-edit-while-stopped", "print(2)", None, "lifecycle",
     {"steps": [{"ticks": 300, "src": "print(1)"},
                {"ticks": 300, "src": "print(2)"}],
      "phases": [{"ticks": 600, "run": False}, {"ticks": 1800, "run": True}],
      "expect": {"progress": False, "finished": True, "log": "2\n"}}),
    # The same shape with the run edge landing AFTER the parse has finished, which
    # is the ordinary case and is BROKEN: the chip runs the previous program and
    # prints 1.  Swept with the suite's own harness, run high at edit+0..+10 gives
    # '2' and edit+15..+255 gives '1', so the boundary is the parse duration - the
    # run edge has to arrive while the parse is in flight for the new program to
    # take effect at all.  Found in game as an intermittent doubled/odd log line.
    ("life-edit-then-run-later", "print(2)", None, "lifecycle",
     {"steps": [{"ticks": 200, "src": "print(1)"},
                {"ticks": 200, "src": "print(2)"}],
      "phases": [{"ticks": 500, "run": False}, {"ticks": 1800, "run": True}],
      "expect": {"progress": False, "finished": True, "log": "2\n"}}),
    # THE SPEC for the deferred parse.  A stopped chip must do nothing: edit while
    # `run` is low, busy stays false through the whole stopped window, and the new
    # program is picked up at the run edge.
    ("life-edit-stopped-not-busy", "print(2)", None, "lifecycle",
     {"steps": [{"ticks": 200, "src": "print(1)"},
                {"ticks": 200, "src": "print(2)"}],
      "phases": [{"ticks": 600, "run": False}, {"ticks": 1500, "run": True}],
      "expect": {"progress": False, "finished": True, "log": "2\n",
                 "checkpoints": [300, 450, 550],
                 "idleBusy": [300, 450, 550]}}),
    # THE CONTROL for the case below, and the only thing that keeps
    # `progDirty` honest.  Skipping the parse on a restart is only correct if a
    # genuine EDIT still gets one, and the difference between the two is a string
    # comparison: `program != progText`.  Get that comparison wrong in the
    # permissive direction and the chip keeps running the program it already has
    # and never notices the new text - which no other case can see, because every
    # other case delivers its program once, from `progText = ""`, where the
    # comparison is true whatever it says.
    #
    # So this is the shape that was missing: a DIFFERENT program arriving while
    # `run` is high, with nothing about it resembling a restart.  The log is the
    # oracle and it is exact: the new program's parse calls vmReset, so the old
    # line is cleared and only "2" is left.  A chip that ignored the edit prints
    # "1", and one that ran both prints "1" then "2".
    ("life-edit-while-running", "print(2)", None, "lifecycle",
     {"steps": [{"ticks": 400, "src": "print(1)"},
                {"ticks": 400, "src": "print(2)"}],
      "phases": [{"ticks": 2400, "run": True}],
      "expect": {"progress": False, "finished": True, "log": "2\n"}}),
    # and the near miss that makes the comparison a comparison: the SAME text
    # arriving again is not an edit, so the run is not disturbed and the program
    # prints exactly once.  The log cannot tell this from a re-parse (both end
    # with one "1"), so what this holds down is the opposite error - a comparison
    # that fires on every value the host re-pushes, which is every tick of a sync.
    ("life-resend-same-text-while-running", "print(1)", None, "lifecycle",
     {"steps": [{"ticks": 400, "src": "print(1)"},
                {"ticks": 400, "src": "print(1)"}],
      "phases": [{"ticks": 2400, "run": True}],
      "expect": {"progress": False, "finished": True, "log": "1\n"}}),
    # A restart must not recompile the text it already has.  The LOG cannot see
    # this: a re-parse calls vmReset, which clears the log, so a recompiled
    # program prints exactly what a skipped parse prints.  `secondRunUnder` is the
    # bound that can - it is fitted between the two measured costs, 5 ticks for a
    # restart and 104 for the same program re-parsed, so a chip that quietly went
    # back to compiling text it already had would fail here while printing the
    # right thing.  The bound must be fitted to the program's own parse cost: a
    # one-line program re-parses in 16 ticks and any generous cap would pass it.
    ("life-no-reparse-second-run",
     "x = 0\nx = x + 1\nx = x + 2\nx = x + 3\nx = x + 4\nprint(x)", None,
     "lifecycle",
     {"phases": [{"ticks": 700, "run": True}, {"ticks": 400, "run": False},
                 {"ticks": 1200, "run": True}],
      "expect": {"progress": False, "finished": True, "log": "10\n",
                 "secondRunUnder": 20}}),
    # the control: the same program with run high from tick zero, which is what
    # every other case in the suite does and what used to be the only shape
    ("life-run-high-from-boot", "print('hi') outnum(1, 7)", None,
     "lifecycle",
     {"phases": [{"ticks": 1800, "run": True}],
      "expect": {"progress": False, "finished": True, "log": "hi\n"}}),
    # and the shape that works today, kept so the fix cannot quietly change it:
    # low, high, low, high
    ("life-run-toggle-twice", "print('hi') outnum(1, 7)", None, "lifecycle",
     {"phases": [{"ticks": 1200, "run": False}, {"ticks": 300, "run": True},
                 {"ticks": 100, "run": False}, {"ticks": 600, "run": True}],
      "expect": {"progress": False, "finished": True, "log": "hi\n"}}),
    # A scalar input that changes EVERY tick while run is high.  The header says
    # such a change restarts the program, so this shape can restart forever and
    # never print anything -- which is what an input wired to something live
    # looks like in game, and it is the shape a case could not ask about until
    # the sim re-read its ports.  The expectation is the CONTRACT, not a wish:
    # an unstable input means an unstable program.
    ("life-input-jitter-while-running", "print('hi')", None, "lifecycle",
     {"phases": [{"ticks": 1200, "run": False},
                 {"ticks": 900, "run": True, "jitter": "inNum0"}],
      "expect": {"progress": False, "finished": False, "log": ""}}),
    # the same jitter while run is low must not break the next start: the program
    # is not running, so there is nothing to restart, and the first high after it
    # has to work like any other
    ("life-input-jitter-while-stopped", "print('hi')", None, "lifecycle",
     {"phases": [{"ticks": 1800, "run": False, "jitter": "inNum0"},
                 {"ticks": 600, "run": True}],
      "expect": {"progress": False, "finished": True, "log": "hi\n"}}),
    # The program text arriving in PIECES.  The sim delivers a string in one
    # value, so this is the closest analogue of a host that fills a long string
    # port over time - and each piece is a Change(program), which asks for a
    # parse.  Two things matter and they are different tests: a FRAGMENT must be
    # rejected (a half-written program is not a program), and the chip must
    # RECOVER when the real program arrives after a rejected one - otherwise a
    # typo in game leaves the chip dead until it is power-cycled.
    ("prog-fragment-rejected", "print('", None, "reject", {"errline": 1}),
    # A `warn:` line is ADVICE, not a refusal, and that is the whole reason the
    # two channels are separate.  The program compiles, runs, and prints what it
    # printed before the call that cannot work - PUC accepts setmetatable and
    # fails at RUN time, so refusing here would be a divergence, and calling it a
    # rejection would report a running program as rejected.
    # A port builtin called with NO arguments cannot do anything.  The count is one
    # token test - the lexer emits `)` as sub 15 - and not a value-stack read,
    # which is what made the first version warn on outnum(i, i).
    ("arity-zero-outnum", "outnum()", None, "state",
     {"expect": {"progDebug": "outnum() takes an index and a value"}}),
    ("arity-zero-innumarr", "print(innumarr())", None, "state",
     {"expect": {"progDebug": "innumarr() takes an index from 1"}}),
    # A program port nobody wired, or wired and left blank.  The chip is RIGHT
    # here -- PUC runs an empty chunk and so does this one -- and the symptom is
    # what needed saying: the log stays empty, busy goes low, err is empty and
    # progOk is true, which is indistinguishable from a program that has decided
    # to print nothing.  A comment left behind by pasting is the same shape, so
    # it is the same case: all four compile to the single RETURN0.
    ("empty-program-says-so", "-- pasted nothing yet\n", None, "state",
     {"expect": {"progDebug": "nothing to run"}}),
    # ... and the half that matters, because a check that fires on every program
    # is noise: a real program says nothing about it.
    ("nonempty-program-quiet", "print('hi')", None, "state",
     {"expect": {"log": "hi\n", "noProgDebug": "nothing to run"}}),
    # ... and the near miss: real arguments must stay silent, including inside a
    # for body, which is exactly where the value-stack version cried wolf.
    # ... and the near miss: real arguments must stay silent, including inside a
    # for body, which is exactly where the value-stack version cried wolf.
    ("arity-args-ok", "for i=1,2 do outnum(i, i) outstr(i, 'x') outarr(i, i) end",
     None, "state", {"expect": {"noProgDebug": "and was given none"}}),    ("warn-metatables", "print(7) setmetatable({}, {})", None, "state",
     {"expect": {"log": "7\n", "progDebug": "warn: no metatables"}}),
    # A name the compiler had to invent is a typo far more often than a global
    # the program meant to define, and PUC cannot say so because PUC has no ports
    # to mistype.  It stays ADVICE: the read is still nil, exactly as PUC.
    # A port-list line used to be appended to every finding, as a catch-all for a
    # typo the chip could not name.  It is gone: the general rule names every
    # unresolved name exactly, so one specific finding means ONE line.  A second
    # vague line per finding answers nothing, and it was a hand-written mirror of
    # the port set besides.
    ("unknown-name-single-line", "print(in1)", None, "state",
     {"expect": {"log": "nil\n", "progDebug": "'in1' is not a port or a builtin",
                 "noProgDebug": "the ports are"}}),
    ("unknown-name-typo", "print(in0)", None, "state",
     {"expect": {"log": "nil\n", "progDebug": "'in0'"}}),
    # ... and the other direction, which is the one that would make the warning
    # noise: a global the program DEFINES is not a typo.  PUC gives it nil before
    # the assignment and the value after, so warning here would be wrong.
    ("unknown-name-assigned", "count = 0 count = count + 1 print(count)", None,
     "state", {"expect": {"log": "1\n", "noProgDebug": "count"}}),
    # A call to one of the chip's own builtins with too few arguments cannot do
    # anything, and the COUNT is known while parsing - it is already the CALL's
    # argument count.  Still advice: the call goes through as it would have.
    # A LITERAL index the chip would refuse at run time, said at parse time
    # instead - the argument has not been parsed yet at the call site, so this is
    # the actual value and not a guess from the text.  The wording is the
    # runtime's own, so the two cannot disagree.
    ("index-literal-outnum", "outnum(0, 1)", None, "state",
     {"expect": {"progDebug": "outnum index must be 1..4"}}),
    ("index-literal-outstr", "outstr(3, 'x')", None, "state",
     {"expect": {"progDebug": "outstr index must be 1..2"}}),
    # ... and a literal IN range is silent, which is the half that matters: a
    # check that fired on every outnum(1, v) in every program would be noise.
    ("index-literal-inrange-ok", "outnum(1, 1) outnum(4, 4)", None, "state",
     {"expect": {"noProgDebug": "outnum index must be"}}),
    # outarr IS bounded - 64 slots - so a literal past the end is a real failure
    # with a real runtime message, and the guard's bound is read from the array
    # rather than written as 64 so the two cannot drift.
    ("index-literal-outarr", "outarr(65, 1)", None, "state",
     {"expect": {"progDebug": "array index out of range"}}),
    ("index-literal-outarr-ok", "outarr(64, 1)", None, "state",
     {"expect": {"noProgDebug": "array index out of range"}}),
    # innumarr is bounded by the same 64 as outArr and a bad index there gives a
    # SILENT nil, which is worth warning about - but it is not implemented: an
    # input PORT cannot be read during codegen (see the note in noteIndex).  The
    # behaviour is pinned; progDebug is deliberately NOT asserted, because a case
    # that locks in a warning the chip does not emit is worse than no case.
    # innumarr is bounded by the same 64 as outArr, and a bad index there gives a
    # SILENT nil rather than a failure, so it is the one a user would never see
    # otherwise.  The bound is a chip const because the port cannot be read while
    # parsing; test_consistency ties that const to spec.OUTARR.
    ("index-innumarr-past-end", "print(innumarr(65))", None, "state",
     {"expect": {"log": "nil\n", "progDebug": "innumarr reads past the end"}}),
    # ... and in range is silent, including the last slot.
    ("index-innumarr-inrange-ok", "print(innumarr(1)) print(innumarr(64))", None, "state",
     {"expect": {"noProgDebug": "innumarr reads past the end"}}),
    # One issue per line is the port's whole contract, and a substring assertion
    # cannot see it: an earlier outarr warning ended in an escaped backslash rather
    # than a newline and its case still passed.  Two findings that really exist, so
    # the separator is load-bearing and the literal backslash cannot reappear.
    ("progdebug-one-per-line", "outarr(65, 1) print(setmetatable)", None, "state",
     {"expect": {"progDebug":
                  "array index out of range, and outarr is 1-based over the outArr slots"
                  "\nwarn: 'setmetatable' is not a port or a builtin"}}),
    ("life-program-recovers", "print('hi')", None, "lifecycle",
     {"steps": [{"ticks": 300, "src": "print('"},
                {"ticks": 300, "src": "print('hi')"}],
      "phases": [{"ticks": 2400, "run": True}],
      "expect": {"progress": False, "finished": True, "log": "hi\n"}}),
    # and the same while stopped, so the recovery does not depend on run
    ("life-program-recovers-stopped", "print('hi')", None, "lifecycle",
     {"steps": [{"ticks": 600, "src": "print('"},
                {"ticks": 600, "src": "print('hi')"}],
      "phases": [{"ticks": 600, "run": False}, {"ticks": 1800, "run": True}],
      "expect": {"progress": False, "finished": True, "log": "hi\n"}}),
    # for that asks for a PARSE.  So a second parse can start while the first is
    # still running, and the two share the parser's arrays.  grid_every=1 is the
    # worst case a sync-every-tick host would produce; 8 is a lazier one.
    ("life-grid-read-every-tick", "print('hi')", None, "lifecycle",
     {"phases": [{"ticks": 2400, "run": True, "grid_every": 1}],
      "expect": {"progress": False, "finished": True, "log": "hi\n"}}),
    ("life-grid-read-slow", "print('hi')", None, "lifecycle",
     {"phases": [{"ticks": 2400, "run": True, "grid_every": 8}],
      "expect": {"progress": False, "finished": True, "log": "hi\n"}}),
    # and a read storm while the program is stopped, then one run edge
    ("life-grid-read-then-run", "print('hi')", None, "lifecycle",
     {"phases": [{"ticks": 1200, "run": False, "grid_every": 1},
                 {"ticks": 1200, "run": True, "grid_every": 1}],
      "expect": {"progress": False, "finished": True, "log": "hi\n"}}),
    # run goes high BEFORE the program arrives, so the edge lands while there is
    # nothing to run: the paste is the start, and the log must still appear
    ("life-run-high-before-program", "print('hi') outnum(1, 7)", None,
     "lifecycle",
     {"phases": [{"ticks": 400, "run": True}, {"ticks": 1400, "run": True}],
      "expect": {"progress": False, "finished": True, "log": "hi\n"}}),
    ("long-string", "print([[hello]])", None, "run"),
    ("long-string-nest", 'print([=[a]=])', None, "run"),
    ("long-comment", "--[[this is a comment]]print(1)", None, "run"),
    ("long-comment-nest", "--[==[nested]==]print(2)", None, "run"),
    ("stress-instr", "STRESS", None, "run"),
    ("over-cap", "OVERCAP", None, "reject"),
    # One global PAST the limit, which is the other half of stress-instr: that
    # case fills the table to 96 and reads every slot back, so it says the storage
    # is big enough for the guard and nothing about what happens one past it.  The
    # LINE is not asserted, because which declaration goes over depends on how
    # many globals the chip pre-registers, which is its own number and not one
    # derived from the spec here; the message is asserted, because that is the
    # part a reader acts on.
    ("stress-globals-over", "GLOBALSOVER", None, "reject",
     {"errText": "too many globals"}),
    # The closure arena's own limit.  A function with an upvalue is a fresh
    # closure every time its expression is evaluated, and the arena is fixed, so a
    # loop that builds them has to stop somewhere.  It stopped nowhere: the guard
    # compared the cursor against a literal 1000000 while the array holds
    # MAX_FUNCS + MAX_CLO, and 400 closures wrote past the end of cloF and cloU.
    ("clo-arena-oom", "local x = 1 local t = {} local i = 1 "
     "while i <= 400 do t[i] = function() return x end i = i + 1 end "
     "print('unreachable')", None, "runtimerr",
     {"ticks": 24000,
      "expect": {"err": "too many closures (%d records)"
                        % (spec.MAX_FUNCS + spec.MAX_CLO)}}),
    # ... and the same loop under the limit, so the case above is a limit being
    # reached rather than the arena simply being small.  The captured name is one
    # the loop never writes: a captured local that the loop body DOES write is a
    # separate, still-open divergence, and a case for the arena should not lean on
    # it.
    ("clo-arena-under", "local x = 7 local t = {} local i = 1 "
     "while i <= 100 do t[i] = function() return x end i = i + 1 end "
     "print(#t, t[1](), t[100]())", None, "run", {"ticks": 24000}),
    # A cell belongs to the BLOCK that declared the local, so the loop round has
    # to leave a cell alone when the captured local is declared OUTSIDE the loop:
    # PUC closes a local's cell when its own block ends, and a local declared at
    # the top of a function does not end until the function does.  The chip
    # stamped every cell with one global loop counter, so exiting the loop body
    # replaced the cell of a local that was still in scope -- t[1]() read 3 where
    # PUC reads 5.
    ("clo-cell-outer-while", "local i = 1 local t = {} "
     "while i <= 3 do t[i] = function() return i end i = i + 1 end "
     "print(t[1](), t[2](), t[3]())", None, "run"),
    # The four loop forms, because each body block is entered from its own place
    # in the parser and a flag missed on one of them shows up as exactly one of
    # these four.  PUC closes the body's own local per round (2 3 4) and shares
    # the outer one (5 for all three).
    ("clo-cell-outer-for", "local i = 0 local t = {} "
     "for k = 1, 3 do local j = k t[k] = function() return i + j end "
     "i = i + 1 end print(t[1](), t[2](), t[3]())", None, "run"),
    ("clo-cell-outer-genfor", "local n = 0 local t = {} "
     "for k in ipairs({1, 2, 3}) do local j = k "
     "t[k] = function() return n + j end n = n + 1 end "
     "print(t[1](), t[2](), t[3]())", None, "run"),
    ("clo-cell-outer-repeat", "local n = 0 local t = {} local k = 1 "
     "repeat local j = k t[k] = function() return n + j end n = n + 1 "
     "k = k + 1 until k > 3 print(t[1](), t[2](), t[3]())", None, "run"),
    # ... and a block that is NOT a loop body, nested inside one.  The cell has
    # to follow the LOOP's round, not the inner block's, because that block is
    # re-entered once per round: j is 2, 3, 4 and not all three 4.
    ("clo-cell-outer-if", "local i = 1 local t = {} "
     "while i <= 3 do if i > 0 then local j = i t[i] = function() return j end "
     "end i = i + 1 end print(t[1](), t[2](), t[3]())", None, "run"),
    # A local declared AFTER a loop, captured inside a second one.  The count of
    # enclosing loop bodies has to be back to zero by then, and the only way to
    # see that is to capture it: x is written by the second loop, so a cell that
    # the loop wrongly replaced answers 10 and one it correctly keeps answers 20.
    ("clo-cell-after-loop", "local t = {} local i = 1 "
     "while i <= 2 do local q = function() return 1 end i = i + 1 end "
     "local x = 0 local j = 1 "
     "while j <= 2 do x = x + 10 t[j] = function() return x end j = j + 1 end "
     "print(t[1](), t[2]())", None, "run"),
    # The SAME loop body with the store and the closure swapped.  Two statements,
    # same work, same answers expected -- and the pair is the rule: a store
    # compiled before the capture is noticed is a plain register write, and one
    # compiled after is a SETUP, so the order used to decide whether the closures
    # saw the loop's own updates.  Only the second of these passed before the fix.
    ("clo-cell-before-loop", "local t = {} local x = 0 local j = 1 "
     "while j <= 2 do t[j] = function() return x end x = x + 10 j = j + 1 end "
     "print(t[1](), t[2]())", None, "run"),
    # ... and the write coming from a NESTED function, which reaches the cell by a
    # path that updates no register at all.  Copying the register in on every
    # closure creation would undo those writes, which is how this one caught that
    # half-fix; the cell has to know it was written.
    ("clo-cell-nested-write", "local s = 0 local i = 1 "
     "while i <= 4 do local f = function() s = s + i return s end f() "
     "i = i + 1 end print(s)", None, "run"),
    # Two loops deep: the outer local outlives both, the inner body's does not.
    ("clo-cell-two-loops", "local n = 0 local t = {} local i = 1 "
     "while i <= 2 do local j = i "
     "while j <= 2 do t[n + 1] = function() return n + j end n = n + 1 "
     "j = j + 1 end i = i + 1 end "
     "print(t[1](), t[2](), t[3]())", None, "run"),
    # error-class tests
    # LOCKSTEP.  Two equal chips, one program, the same start: the output has to be
    # the same AT EVERY TICK, not merely the same at the end.  The chip is a
    # network of gates that re-evaluates when an input changes, so if two copies
    # could drift, a program that read a port mid-run would be one scheduling
    # accident away from a different answer on the second copy -- and every diff
    # this suite produces would then be a diff against a coin toss.  Measured over
    # nine programs with tools/chip/lockstep.py: identical tick counts and
    # identical logs at every tick.
    ("lockstep-hello", "print('hello')", None, "lockstep",
     {"expect": {"log": "hello\n"}}),
    ("lockstep-loop", "local s = 0 for i = 1, 20 do s = s + i end print(s)",
     None, "lockstep", {"expect": {"log": "210\n"}}),
    ("lockstep-calls", "local function f(n) if n == 0 then return 0 end "
     "return f(n - 1) + 1 end print(f(12))", None, "lockstep",
     {"expect": {"log": "12\n"}}),
    ("lockstep-tables", "local t = {} for i = 1, 8 do t[i] = i * 2 end "
     "local s = 0 for _, v in pairs(t) do s = s + v end print(s)", None,
     "lockstep", {"expect": {"log": "72\n"}}),
    ("lockstep-closures", "local function c() local n = 0 return function() "
     "n = n + 1 return n end end local f = c() for i = 1, 10 do f() end "
     "print(f())", None, "lockstep", {"expect": {"log": "11\n"}}),
    # 21 is PUC's answer and was checked against the oracle, not copied off the
    # chip: this mode compares two chips with each other, so a hand-written `want`
    # can hold the chip's own wrong answer and stay green.  This one did -- it said
    # 6, because the loop-body cell bug threw away the accumulation, and it only
    # showed up when the closure fix made the chip right.
    ("lockstep-pcall", "local s = 0 for i = 1, 6 do local ok, v = "
     "pcall(function() s = s + i return s end) end print(s)", None, "lockstep",
     {"expect": {"log": "21\n"}}),
    ("lockstep-string", "print(string.format('%d/%s', 42, string.rep('ab', 3)))",
     None, "lockstep", {"expect": {"log": "42/ababab\n"}}),
    # The numeric inputs live in the tuple's THIRD slot, which is where the suite
    # reads them from; the suite copies that slot over any `inputs` in the kw, so
    # an `inputs` written in the kw is silently discarded and the case stops
    # testing what it looks like it tests.  test_consistency.py's
    # case-inputs-in-the-inputs-slot is the net.
    ("lockstep-ports", "print(inStr0, inNum0, #tostring(inNum1))", [0.0, 7.0],
     "lockstep", {"sinputs": {0: "hi"},
                  "expect": {"log": "hi\t0.0\t3\n"}}),
    ("lockstep-error", "print(1 + {})", None, "lockstep", {}),
    ("syn-unterm", "print('abc)", None, "synfail"),
    ("syn-end", "print(1) end", None, "synfail"),
    ("syn-numconcat", "print(5..3)", None, "synfail"),
    ("syn-locnum", "local 5 = 1", None, "synfail"),
    ("syn-anonstmt", "function() end", None, "synfail"),
    ("syn-break", "break", None, "synfail"),
    # A LINE NUMBER, which no case here checked.  The library is prepended to the
    # program, so the source the lexer and the parser see counts the library's
    # lines: the parser's error path never subtracted them, so any syntax error in
    # a program that pulled in a piece reported a line tens of lines too high --
    # "line 50" for an error on line 2.  The lexer's path did subtract them, and
    # did it in a `let` it then assigned, which the compiler rejected (WS007) and
    # mis-lowered: the graph gained 7 nodes when that became a `var`.  Both paths
    # now go through one userLine mod, and the number is spelled as an int because
    # a computed whole number in WireScript is a float (fmtNum would say "2.0").
    ("syn-line-nolib", "local x = = 3", None, "synfail", {"errline": 1}),
    ("syn-line-parser-lib", "print(math.random ~= nil)\nlocal x = = 3", None,
     "synfail", {"errline": 2}),
    ("syn-line-lexer-lib", "print(tonumber('1'))\nlocal s = 'abc", None,
     "synfail", {"errline": 2}),
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
    ("func-innumarr", "function g() return innumarr(1) + innumarr(2) end "
     "print(g(), g())", None, "modelio",
     {"innumarr": [3.0, 4.0], "expect": {"log": "7.0\t7.0\n"}}),
    ("func-outarr", "function w(v) outarr(1, v * 2) end w(5) w(6)",
     None, "modelio",
     {"expect": {"outArr": [12.0] + [0.0] * 63, "log": ""}}),
    ("func-main-first", "print('start') function h(x) return x + 1 end "
     "print(h(41))", None, "run"),
     ("demo", "DEMO", [3, 1, 4, 1.5], "modelio",
      {"expect": {"log": DEMO_LOG,
                  "outGlobals": [7.0, 79.0, 608.0, 11.0,
                                 "foo-bar!|foo", "21.75/table: 0x4"],
                  "outArr": [55.0, 6.0, 3.0] + [0.0] * 58 + [-1.0, -2.0, -3.0],
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
    # Both table limits are counted from spec, so raising one cannot quietly
    # turn its case into a no-op: a program that no longer reaches the ceiling
    # would stop raising, and `runtimerr` fails on the missing error.
    ("tab-toomany", "t = {} i = 0 while i < %d do t[#t+1] = {} "
     "i = i+1 end" % spec.MAX_TABLES, None, "runtimerr",
     {"expect": {"err": "too many tables (%d)" % spec.MAX_TABLES}}),
    ("tab-oom", "t = {} i = 0 while i < %d do t[i] = {} i = i+1 end"
     % (spec.MAX_TABLES + 1), None,
     "runtimerr", {"expect": {"err": "too many tables"}}),
    # The table arena is fixed (512 entries, `MAX_HEAP`) and there is no
    # collector, so the ONLY thing that keeps a program inside it is the slot
    # free list: `t[k] = nil` hands the entry back and the next new key takes
    # it.  That is the whole recycling story, and it is invisible until a
    # program allocates more entries IN TOTAL than the arena holds -- which is
    # the shape these cases are for.  60 rounds x 8 keys is 480 stores with
    # never more than 8 live, so without the free list this is an OOM at 512;
    # with it the values still have to be right, which is the other half (a
    # slot handed back must come back holding the new value).
    ("tab-recycle", "local t = {} for round = 1, 60 do for i = 1, 8 do "
     "t[i] = round * 8 + i end for i = 1, 8 do t[i] = nil end end "
     "for i = 1, 8 do t[i] = i end "
     "local s = 0 for i = 1, 8 do s = s + t[i] end print(s, #t)", None,
     "run", {"ticks": 24000}),
    # Same recycling, over the arena's whole size and with the entries coming
    # from TWO tables: a slot freed by one table and taken by another is where
    # a stale owner would show up as a key that stops existing.
    ("tab-recycle-tables", "local a = {} local b = {} for round = 1, 40 do "
     "for i = 1, 6 do a[i] = round * 6 + i end for i = 1, 6 do b[i] = i end "
     "for i = 1, 6 do a[i] = nil end for i = 1, 6 do b[i] = nil end end "
     "for i = 1, 6 do a[i] = -i end for i = 1, 6 do b[i] = i * 2 end "
     "print(a[1], a[6], b[1], b[6])", None, "run", {"ticks": 24000}),
    # A DELETED key that is then re-assigned revives its own slot, and that
    # slot is still on the free list -- so the next new key, in this table or
    # another one, takes it and the revived key stops existing.  No error, no
    # wrong value anywhere: the key just reads nil, which is why the value
    # assertions below are the whole test.  Three shapes, because the rule is
    # "a slot on the free list has one owner" and each shape broke a different
    # part of it: a new key in the same table, a new key in another table, and
    # an integer key (which also carries the `#` border).
    ("tab-revive-steal", "local t = {} t.a = 1 t.a = nil t.a = 2 t.b = 3 "
     "print(t.a, t.b)", None, "run"),
    ("tab-revive-steal-other", "local t = {} t.a = 1 t.a = nil t.a = 2 "
     "local u = {} u.b = 3 print(t.a, u.b)", None, "run"),
    ("tab-revive-steal-int", "local t = {} t[1] = 'a' t[1] = nil t[1] = 'b' "
     "local u = {} u.x = 1 print(t[1], #t, u.x)", None, "run"),
    # The same steal in a loop, which is the shape a real program has: the key
    # that disappears is one of many, so nothing in the output points at it.
    ("tab-revive-steal-loop", "local t = {} for i = 1, 6 do t[i] = i end "
     "t[3] = nil t[3] = 30 for i = 10, 15 do t[i] = i end "
     "local s = 0 for i = 1, 6 do s = s + (t[i] or 0) end "
     "print(s, #t, t[3])", None, "run"),
    # The arena's own entry limit, which `tab-oom` above does NOT reach: it runs
    # out of TABLES long before entries, so the entry path needs a program that
    # asks for more entries than the arena holds.  The message is the contract,
    # and `runtimerr` also reads the arena counters through the suite's
    # structural invariants -- an OOM that walked tHeap past its own storage
    # would fail there rather than here.
    ("tab-entries-oom", "local t = {} for i = 1, %d do t[i] = i end "
     "print('unreachable')" % (spec.MAX_HEAP + 88), None, "runtimerr",
     {"ticks": 24000,
      "expect": {"err": "out of table memory (%d entries; assign nil to a key "
                        "to free one)" % spec.MAX_HEAP}}),
    # An OOM a program can catch, and recover from, because the arena is a free
    # list rather than a wall: the failure goes to pcall as a value, the deletes
    # hand the entries back, and the table then holds what it could not a moment
    # earlier.  The allocation deliberately asks for MORE than the arena holds,
    # counted from spec -- at 512 it asked for 520, and raising the arena to 1024
    # left this case still PASSING while testing nothing: no OOM, nothing to
    # recover from.  A case that keeps its verdict after the thing it measures has
    # moved is worse than a failing one.  The refilling loop stays under the new
    # ceiling so it succeeds.  The failure itself is deliberately NOT printed:
    # PUC has no entry limit, so a line saying whether it happened could not be
    # compared against the oracle and this would stop being a differential case.
    # `tab-entries-oom` above is where the message is the contract.
    ("tab-entries-recover", "local t = {} pcall(function() "
     "for i = 1, %d do t[i] = i end end) "
     "for i = 1, %d do t[i] = nil end "
     "for i = 1, %d do t[i] = i * 2 end "
     "print(#t, t[1], t[%d])"
     % (spec.MAX_HEAP + 8, spec.MAX_HEAP + 8, spec.MAX_HEAP - 112,
        spec.MAX_HEAP - 112), None, "run", {"ticks": 60000}),
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
    ("arr-read", "print(innumarr(1), innumarr(2), innumarr(3))", None, "modelio",
     {"innumarr": [1.5, 2.5], "expect": {"log": "1.5\t2.5\tnil\n"}}),
    ("arr-write", "outarr(1, 9) outarr(2, innumarr(1))", None, "modelio",
     {"innumarr": [5.0],
      "expect": {"outArr": [9.0, 5.0] + [0.0] * 62, "log": ""}}),
    ("arr-oob-read", "print(innumarr(0), innumarr(-1), innumarr(1.5), innumarr('x'))",
     None, "modelio",
     {"innumarr": [7.0], "expect": {"log": "nil\tnil\tnil\tnil\n"}}),
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
    ("arr-missing", "print(innumarr())", None, "modelio",
     {"expect": {"log": "nil\n"}}),
    # The bounded forms: outarr(i, v, ...) writes one slot per extra value and
    # innumarr(i, k) returns k of them, so a run of adjacent slots costs one call.
    # The port was never the cost -- outArr is @right out, so the whole array
    # reaches it every tick -- so this is about the CALL, measured at 5 ticks an
    # element for a write.
    ("arr-multi-write", "outarr(1, 5, 6, 7) outarr(4, 8, 9)", None, "modelio",
     {"expect": {"outArr": [5.0, 6.0, 7.0, 8.0, 9.0] + [0.0] * 59,
                 "log": ""}}),
    ("arr-multi-mixed", "outarr(1, 1, nil, true)", None, "modelio",
     {"expect": {"outArr": [1.0, 0.0, 1.0] + [0.0] * 61, "log": ""}}),
    # a call with more values than the width writes the first 8, the way the
    # two-value form ignored whatever came after the second
    ("arr-multi-wide", "outarr(1, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10)", None,
     "modelio", {"expect": {"outArr": [float(i) for i in range(1, 9)] + [0.0] * 56,
                            "log": ""}}),
    ("arr-multi-oob", "outarr(62, 1, 2, 3, 4)", None, "runtimerr",
     {"expect": {"err": "array index out of range"}}),
    # the last run of four that fits: slots 61..64.  This is the case the
    # off-by-one in the value count broke, because it asked for one slot too many
    ("arr-multi-last4", "outarr(61, 1, 2, 3, 4) print('ok')", None, "modelio",
     {"expect": {"outArr": [0.0] * 60 + [1.0, 2.0, 3.0, 4.0], "log": "ok\n"}}),
    ("arr-multi-badval", "outarr(1, 1, 1, {})", None, "runtimerr",
     {"expect": {"err": "array element must be a number"}}),
    # These two are DIFFERENTIAL, not literal: tests/lua_oracle.py's innumarr models
    # the chip's port contract (one slot, or k of them with a slot past the end
    # reading nil), so PUC decides the answer and the chip has to agree.
    ("arr-multi-read", "local a, b, c, d = innumarr(4, 4) print(a, b, c, d)", None,
     "run", {"innumarr": [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0]}),
    ("arr-multi-expand", "print(innumarr(1, 3))", None, "run",
     {"innumarr": [1.5, 2.5, 3.5, 4.5]}),
    # a slot past the end of the array reads nil, the same rule innumarr(65) has
    ("arr-multi-read-edge", "print(innumarr(62, 4))", None, "run",
     {"innumarr": [float(i) for i in range(1, 65)]}),
    # k is capped at 8, and this is the AT the cap: every other multi-read case
    # used 3 or 4, so the widest form the chip accepts was the one thing untested
    # on both arrays.  Nine is the first rejected value (arr-multi-count9).
    ("arr-multi-read8", "print(innumarr(1, 8))", None, "run",
     {"innumarr": [float(i) for i in range(1, 13)]}),
    # the cap is on the COUNT, and a read of 8 that starts near the end still
    # answers 8: four slots and four nils, not an error and not four
    ("arr-multi-read8-edge", "print(innumarr(60, 8))", None, "run",
     {"innumarr": [float(i) for i in range(1, 65)]}),
    # the results land in consecutive registers, so a constructor is the shape
    # that would break first if it did -- and #t is PUC's, not the chip's
    ("arr-multi-into-table", "local t = {innumarr(2, 4)} print(#t, t[1], t[4])",
     None, "run", {"innumarr": [9.0, 1.0, 2.0, 3.0, 4.0, 5.0]}),
    # the count is a count, not an index: 0, 9 and 1.5 all raise.  Each case sets
    # innumarr, because the INDEX is checked first: with an empty array innumarr(1, 9)
    # answers nil and never reaches the count.
    ("arr-multi-count0", "print(innumarr(1, 0))", None, "runtimerr",
     {"innumarr": [1.0], "expect": {"err": "count out of range"}}),
    ("arr-multi-count9", "print(innumarr(1, 9))", None, "runtimerr",
     {"innumarr": [1.0], "expect": {"err": "count out of range"}}),
    ("arr-multi-countfrac", "print(innumarr(1, 1.5))", None, "runtimerr",
     {"innumarr": [1.0], "expect": {"err": "count out of range"}}),
    # inStrArr is the string array input, and instrarr(i) / instrarr(i, k) are
    # innumarr's two shapes on it.  A port carries one wire type, so this is a
    # SECOND port rather than a wider inNumArr -- the header says why, and the
    # count guard and the nil past the end are innumarr's rather than new rules.
    # Like inNumArr it is read LIVE and cannot restart the program, and that half is
    # structural rather than tested here: an array is a container and `Change`
    # watches one wire value, so no handler can exist (the compiler says WS059).
    # tests/test_consistency.py names BOTH array ports in the no-Change check, so
    # the second port cannot be added later without anyone noticing.
    ("sarr-read", "print(instrarr(1), instrarr(2))", None, "run",
     {"instrarr": ["alpha", "beta"]}),
    # past the end is nil, one slot or a whole run of them
    ("sarr-read-edge", "print(instrarr(1), instrarr(4))", None, "run",
     {"instrarr": ["alpha", "beta"]}),
    ("sarr-empty", "print(instrarr(1))", None, "run", {"instrarr": []}),
    ("sarr-multi-read", "local a, b, c = instrarr(1, 3) print(a, b, c)", None,
     "run", {"instrarr": ["one", "two", "three", "four"]}),
    ("sarr-multi-expand", "print(instrarr(2, 3))", None, "run",
     {"instrarr": ["one", "two", "three", "four"]}),
    # k = 8 is the cap and instrarr has to reach it, because the number array's
    # cap being tested is no evidence about this arm: it is a separate fid with
    # its own eight writes.
    ("sarr-multi-read8", "print(instrarr(1, 8))", None, "run",
     {"instrarr": ["s%d" % i for i in range(1, 13)]}),
    # and a wide read that runs off the end answers nils, not a short run
    ("sarr-multi-read-edge", "print(instrarr(2, 4))", None, "run",
     {"instrarr": ["one", "two", "three"]}),
    # A slot that reads as a number is still a STRING: the port's wire type is
    # what it is, and the coercion is PUC's, so this is differential on purpose.
    # It is also the case that would break first if instrarr ever answered with
    # a number, which is why it is here and not a comment.
    ("sarr-stays-string", "print(instrarr(1) + 0, type(instrarr(1)))", None, "run",
     {"instrarr": ["5"]}),
    # the count is a count, not an index, and the index is checked FIRST: an empty
    # array answers nil and never reaches the count guard, so each case sets it
    ("sarr-multi-count0", "print(instrarr(1, 0))", None, "runtimerr",
     {"instrarr": ["a"], "expect": {"err": "count out of range"}}),
    ("sarr-multi-count9", "print(instrarr(1, 9))", None, "runtimerr",
     {"instrarr": ["a"], "expect": {"err": "count out of range"}}),
    ("sarr-multi-countfrac", "print(instrarr(1, 1.5))", None, "runtimerr",
     {"instrarr": ["a"], "expect": {"err": "count out of range"}}),
    # past the end on the way IN is the silent nil, so it gets the parse-time
    # advice innumarr gets -- same bound, same const, same reason
    ("index-instrarr-past-end", "print(instrarr(65))", None, "state",
     {"instrarr": ["a"],
      "expect": {"log": "nil\n", "progDebug": "instrarr reads past the end"}}),
    ("index-instrarr-inrange-ok", "print(instrarr(1))", None, "state",
     {"instrarr": ["a"], "expect": {"noProgDebug": "instrarr reads past the end"}}),
    # PUC's # on a table with a hole is the FIRST nil minus one, so deleting an
    # array element at or below the border moves it, and a key above the border
    # does not.  The chip shrank only when the deleted key WAS the border, which
    # is why {1,2,3} with t[2] = nil read 3 here and 1 in PUC.
    ("len-hole-mid", "t = {1,2,3} t[2] = nil print(#t, t[1], t[2], t[3])", None,
     "run"),
    ("len-hole-last", "t = {1,2,3} t[3] = nil print(#t)", None, "run"),
    ("len-hole-first", "t = {1,2,3} t[1] = nil print(#t)", None, "run"),
    ("len-hole-sparse", "t = {} t[1] = 1 t[3] = 3 print(#t)", None, "run"),
    ("len-hole-append", "t = {1,2,3} t[2] = nil t[4] = 4 print(#t)", None, "run"),
    ("len-hole-two", "t = {1,2,3,4,5} t[2] = nil t[4] = nil print(#t)", None,
     "run"),
    ("len-hole-filllast",
     "t = {1,2,3} t[3] = nil t[3] = 3 print(#t)", None, "run"),
    # Emptying a table and refilling it shorter, which is the shape every
    # recycling loop has.  A nil assignment leaves the key in the map as a
    # tombstone -- PUC does the same, and next(t, k) depends on it -- so the
    # border chase has to ask whether the entry holds a VALUE, not whether the
    # key is in the map.  Answering the map question walked the chase over the
    # tombstones and handed back the length the table had before it was emptied.
    ("len-after-empty", "local t = {} for i = 1, 60 do t[i] = i end "
     "for i = 1, 70 do t[i] = nil end for i = 1, 40 do t[i] = i * 2 end "
     "print(#t, t[1], t[40], t[41])", None, "run"),
    # The same, with the refill going PAST the old length, so the chase has to
    # stop somewhere other than where it started: the answer is the new border,
    # not the old one and not the high-water mark.
    ("len-after-empty-grow", "local t = {} for i = 1, 20 do t[i] = i end "
     "for i = 1, 30 do t[i] = nil end for i = 1, 25 do t[i] = i end "
     "print(#t, t[25], t[26])", None, "run"),
    # A fill that BRIDGES a gap does not extend the border, because the chase
    # machine that would never fires.  Two cases, and the second proves it is not
    # a timing question: five ticks of slack change nothing.
    ("len-hole-bridge", "t = {} t[1] = 1 t[3] = 3 t[2] = 2 print(#t)", None,
     "run"),
    ("len-hole-bridge2", "t = {} t[1] = 1 t[3] = 3 t[2] = 2 local x = 0 "
     "for i = 1, 5 do x = x + 1 end print(#t)", None, "run"),
    # and the append pattern the border exists for still works after a delete
    ("len-hole-append2",
     "t = {1,2,3} t[2] = nil t[4] = 4 print(#t)", None, "run"),
    # Integer zero has no sign, so a value stored under an integer tag may not
    # carry one.  The chip computed -7 * 0 in f64, which is -0.0, and stored that
    # under the integer tag: `print(z)` and `math.type(z)` were both right, so the
    # leak was invisible until the value met a float -- and `-5.0 * -0.0` is
    # `+0.0` where PUC's `-5.0 * 0` is `-0.0`.  This is the fuzzer's one
    # recurring divergence, and it is a chip bug rather than a host law.
    #
    # The three spellings of integer zero reach it by three routes: a runtime
    # MUL of two folded constants, the literal `-0` (a constant load), and a
    # runtime SUB.  Only the first two leaked, and the case is in the shape the
    # fuzzer found rather than a shape chosen to be minimal.
    ("negslot-mul",
     "local z = (3-10)*(10%2) print(z, math.type(z), z*(-5.0))", None, "run"),
    ("negslot-lit", "local z = -0 print(z, math.type(z), z*(-5.0))", None,
     "run"),
    # the neighbours, so the fix cannot be "make every zero positive" -- these
    # are float zero and they KEEP the sign, which is a different rule
    ("negslot-float-ok", "local z = -5.0 * 0.0 print(z, z*(-5.0))", None, "run"),
    ("negslot-sub-ok", "local z = 1-1 print(z, math.type(z), z*(-5.0))", None,
     "run"),
    # ... and the two routes by which a negative zero reaches an arithmetic
    # operand other than a local: through a table slot and through a parameter.
    # Both were checked while looking for a third route and both were already
    # right, which is why they are cases and not a comment.
    ("negslot-table",
     "local t = {} t[1] = -0 print(t[1] * -5.0, math.type(t[1]))", None, "run"),
    ("negslot-arg", "local function f(v) return v * -5.0 end print(f(-0))",
     None, "run"),
    # Every route that MAKES a negative zero, in one program.  The bug this
    # session was found through one of them (`-(0^3)`), and the sweep that found
    # it also proved the other four agree -- so this pins the rule rather than
    # the program: a float zero's sign is IEEE's, not the chip's.
    ("negzero-make",
     "print(-(0.0), 0.0 * -1.0, 0.0 / -1.0, -0.5 * 0.0, -(0 ^ 3))", None, "run"),
    # ... and the operations on one.  `z - 1` is -1.0 and `-z` is +0.0, which is
    # the pair that makes the alternation visible: both are signs of zero decided
    # by IEEE, and both are places a "normalise zero" fix would break.
    ("negzero-arith",
     "local z = -0.0 print(z + 1, z - 1, z * 1, z / 1, z % 7, -z)", None, "run"),
    # concat and tostring keep it, so the leak is NOT in the printing path --
    # which is what first sent this looking at the host's `..` and was wrong.
    ("negzero-str",
     "local z = -0.0 print(#tostring(z), z .. 'x', 'x' .. z, tostring(z))",
     None, "run"),
    # The comparisons are the whole reason the bug stayed invisible: -0.0 is not
    # less than zero and it does equal zero, so no test on the value alone can
    # see the sign.  1/z is the one operation that exposes it, which is why it is
    # the sign oracle the pow workaround cannot afford.
    ("negzero-cmp",
     "local z = -0.0 print(z < 0, z == 0, z <= 0, 1/z, 1/0.0)", None, "run"),
    # math.abs, the other bug this sweep found.  It is written in Lua in the
    # library const as `if x < 0 then return -x end return x`, and -0.0 is not
    # less than zero, so it returned the negative zero unchanged.  abs has to
    # clear the sign of a zero, and it is the one place where that is true by
    # definition rather than by IEEE accident.
    ("negzero-abs",
     "print(math.abs(-0.0), math.abs(0.0), math.type(math.abs(-0.0)))", None,
     "run"),
    # ... and the neighbour that says how it was fixed: `x + 0.0` would have
    # turned math.abs(-5) into a FLOAT, because the fix has to normalise the
    # sign without changing the type.  abs returns an integer for an integer.
    ("negzero-abs-int",
     "print(math.abs(-5), math.type(math.abs(-5)), math.abs(0), "
     "math.type(math.abs(0)), math.abs(-5.5), math.abs(1/0))", None, "run"),
    # the rest of the math library on a negative zero, measured while sweeping
    # for further routes and all already agreeing: floor and ceil answer the
    # INTEGER 0 (so they normalise, and unlike abs that is the host gate's job),
    # fmod and sqrt keep the sign.
    ("negzero-math-rest",
     "local z = -0.0 print(math.floor(z), math.ceil(z))", None, "run"),
    ("negzero-math-rest2", "local z = -0.0 print(math.fmod(z, 3), math.sqrt(z))",
     None, "run"),
    # The pow arm is now sign-correct for a negative zero base: the gate answered the
    # right MAGNITUDE with the wrong sign, +0.0 for every positive exponent and
    # -inf for every negative one, where PUC alternates on the parity of the
    # exponent.  The whole set is here because fixing it means "flip the sign
    # sometimes" and each of these pins one side of that decision -- `^ 4` and
    # `^ -3` are the ones a parity test written the wrong way round breaks, and
    # `^ 0` and `^ 0.5` are the ones a guard written too wide breaks.
    ("negzero-pow", "local z = -0.0 print(z ^ 2, z ^ 3, z ^ -2, z ^ 0.5)", None,
     "run"),
    ("negzero-pow2",
     "local z = -0.0 print(z ^ 0, z ^ 1, z ^ -1, z ^ 4, z ^ -3)", None, "run"),
    ("negzero-pow3", "print((-0.0)^1e300, 0.0^-3, (-2.0)^3, (-0.5)^3, 2^0.5)",
     None, "run"),
    # The dispatch is written twice -- vmStep and the vmStepFast subset -- and a
    # fix that reached only one copy was invisible, so these compute the same pow
    # in PLAIN execution and inside a closure.  vmBusy() is true while cloActive,
    # so the closure call is the other dispatch path, and the two answers have to
    # be equal as well as right.  tools/chip/twopaths.py checks the same invariant
    # on the source, for every arm, which is why it exists: pow is the terminal
    # `else` of the arithmetic chain rather than an `op == 13` arm, so a tool that
    # only matched `op == N` could not see it.
    ("negzero-pow-paths",
     "local z = -0.0 local function pw(v, e) return v ^ e end "
     "print(z ^ 3, pw(z, 3)) print(z ^ -2, pw(z, -2)) "
     "print(z ^ 2, pw(z, 2)) print(z ^ 0.5, pw(z, 0.5))", None, "run"),
    ("negzero-pow-paths2",
     "local z = -0.0 local function pw(v, e) return v ^ e end "
     "local t = {} t[1] = z ^ 3 t[2] = pw(z, 3) "
     "print(t[1], t[2], t[1] == t[2])", None, "run"),
    ("arr-multi-read1", "print(innumarr(1, 1))", None, "modelio",
     {"innumarr": [3.5], "expect": {"log": "3.5\n"}}),
    # A compile limit answers on the err port with the line that asked for too
    # much, so a program that runs out of registers can be fixed rather than
    # guessed at: PUC allows 200 locals per function and the chip 64, so this is
    # a case the chip must REJECT and the reference must accept.
    ("lim-registers",
     " ".join("local v%d = %d" % (i, i) for i in range(70))
     + " print('unreached')", None, "reject", {"errline": 1}),
    # the output ports, written by CALL: writing outside the chip reads as an
    # action rather than as editing its state, so none of these are globals and a
    # program cannot read one back
    ("out-nums", "outnum(1, 1) outnum(2, 2.5) outnum(3, true) outnum(4, nil)",
     None, "modelio",
     {"expect": {"outGlobals": [1.0, 2.5, 1.0, 0.0, "", ""]}}),
    ("out-strs", "outstr(1, 'hi') outstr(2, 3)", None, "modelio",
     {"expect": {"outGlobals": [0.0, 0.0, 0.0, 0.0, "hi", "3"]}}),
    ("io-int", "outnum(4, inNum0 * 2 + 1) print('done')", [5],
     "modelio",
     {"expect": {"log": "done\n",
                 "outGlobals": [0.0, 0.0, 0.0, 11.0, "", ""]}}),
    # outInt0 is a typed int port: an integral float is stored as an integer
    # there is no int type: 7.0 and 7 are one number, so outnum(4, 7.0) puts
    # 7.0 on a float port and the program reads 7.0 back
    ("io-int-coerce", "outnum(4, 7.0) print('done')", None, "modelio",
     {"expect": {"log": "done\n",
                 "outGlobals": [0.0, 0.0, 0.0, 7.0, "", ""]}}),
    ("io-int-bad", "outnum(4, 'x')", None, "runtimerr",
     {"expect": {"err": "cannot convert"}}),
    ("inputs-int", "print(inNum3 + 1)", [0, 0, 0, 41], "run", {}),
    # an output is not readable: there is no global to read, so a program that
    # wants the value back has to keep it
    ("out-not-readable", "outnum(1, 5) print(outNum0)", None, "run"),
    ("out-badnum", "outnum(1, 'x')", None, "runtimerr",
     {"expect": {"err": "cannot convert"}}),
    ("out-badnum2", "outnum(2, {})", None, "runtimerr",
     {"expect": {"err": "cannot convert"}}),
    ("out-badindex", "outnum(5, 1)", None, "runtimerr",
     {"expect": {"err": "index must be 1..4"}}),
    ("out-badindex-str", "outstr(3, 'x')", None, "runtimerr",
     {"expect": {"err": "index must be 1..2"}}),
    ("out-nil-str", "outstr(1, nil) print('done')", None, "modelio",
     {"expect": {"log": "done\n",
                 "outGlobals": [0.0, 0.0, 0.0, 0.0, "", ""]}}),
    # STICKINESS: a value written to a port stays there until it is written
    # again, because whoever reads the chip may not be looking this tick.  The
    # loop spins real ticks after the write, and the port is read at the end.
    ("out-sticky-num",
     "outnum(1, 42) for i = 1, 30 do local x = i end print('done')", None,
     "modelio", {"expect": {"log": "done\n",
                            "outGlobals": [42.0, 0.0, 0.0, 0.0, "", ""]}}),
    ("out-sticky-str",
     "outstr(2, 'held') local s = 0 for i = 1, 30 do s = s + i end print('done')",
     None, "modelio", {"expect": {"log": "done\n",
                                  "outGlobals": [0.0, 0.0, 0.0, 0.0,
                                                 "", "held"]}}),
    ("out-sticky-int",
     "outnum(4, 7) local s = 0 for i = 1, 30 do s = s + i end print('done')", None,
     "modelio", {"expect": {"log": "done\n",
                            "outGlobals": [0.0, 0.0, 0.0, 7.0, "", ""]}}),
    # every index is 1-BASED, the same as a Lua table, so outnum(1, v) and
    # outarr(1, v) are the same slot.  Both are pinned here rather than left to
    # a comment, and a Lua program cannot tell the difference between them.
    ("out-sticky-arr",
     "outarr(60, 7, 8) local s = 0 for i = 1, 30 do s = s + i end print('done')",
     None, "modelio", {"expect": {"log": "done\n",
                                  "outArr": [0.0] * 59 + [7.0, 8.0] + [0.0] * 3}}),
    # and a restart clears them, which is the other half: sticky, not permanent
    ("out-cleared-on-restart", "outnum(1, 42) print('done')", None, "modelio",
     {"expect": {"log": "done\n",
                 "outGlobals": [42.0, 0.0, 0.0, 0.0, "", ""]}}),
    # Divergences PUC's own test suite found (tools/chip/pucsuite.py harvests
     # lua-5.5.1-tests and compares against the oracle).  Each is pinned here so
     # it is a KNOWN answer rather than a surprise: without an entry a divergence
     # is indistinguishable from a chip bug, which is the whole reason the
     # harvested cases are worth keeping.  Four entries have since been FIXED
     # and now compare against the oracle directly (no CHIP_LOG entry): hex
     # tonumber, %f at the edges, (%w*)$ at the end, and %f's # point.
    ("puc-hex-tonumber", "print(tonumber('0x10'))", None, "run"),
    ("puc-hex-sign", "print(tonumber('+0x2'))", None, "run"),
    ("puc-hex-decimal-ok", "print(tonumber('16'))", None, "run"),
    ("puc-hex-neg", "print(tonumber('-0xaA'))", None, "run"),
    ("puc-hex-spaces", "print(tonumber('  0xFF  '))", None, "run"),
    ("puc-hex-frac", "print(tonumber('0x1.8'))", None, "run"),
    ("puc-hex-pexp", "print(tonumber('0x1p4'))", None, "run"),
    ("puc-hex-nil", "print(tonumber('0x'), tonumber('0x1g'))", None, "run"),
    # Past 2^53 a hex numeral is already rounded before it can become an
    # integer: 15 hex digits need 60 bits and the registers hold 53, so this
    # stays a float where PUC answers an exact int.  Same 64-bit wall as the
    # decimal path (the host rounds "81985529216486895" the same way), which is
    # why float here is consistency, not a second rule.
    ("puc-hex-wide", "print(tonumber('0x123456789abcdef'))", None, "run"),
    # %b with identical delimiters: PUC checks the closer first
    ("puc-bsame-find", "print(string.find(\"alo 'oi' alo\", \"%b''\"))", None,
     "run"),
    ("puc-bsame-match", "print(string.match(\"alo 'oi' alo\", \"%b''\"))",
     None, "run"),
    ("puc-bsame-gsub", "print(string.gsub(\"alo 'oi' alo\", \"%b''\", '\"'))",
     None, "run"),
    # %f, the frontier pattern: \0 at the string's start edge, and the scan
    # tries position len so a final transition matches.  Sets containing %z
    # still miss: %z means NUL in PUC and the letter z here, a 49-node arm
    # through inlining, so those three stay divergences below.
    ("puc-fpct-a", "print(string.find('a', '%f[^%l]'))", None, "run"),
    ("puc-fpct-b", "print(string.find('aba', '%f[a%z]'))", None, "run"),
    ("puc-fpct-c", "print(string.find('a', '%f[^%z]'))", None, "run"),
    ("puc-fpct-d", "print(string.find('aba', '%f[%z]'))", None, "run"),
    # %z is PUC's NUL class.  The chip's strings cannot HOLD a NUL byte -- its
    # log framing cannot even carry one -- so these pin the class on a subject
    # with no NUL in it: a letter z must stop matching, which is what the old
    # `c == code` fallback did.  Both matchers are covered, the set (8255's
    # single class is the same chip body) and the plain class.
    ("pat-z-is-not-letter",
     "print(('azb'):gsub('[%z]', 'X'), ('azb'):find('%z'), "
     "('azb'):gsub('[^%z]', 'X'))", None, "run"),
    # A maximal repeat with nothing after it is fine; with a tail it loops for
    # ever.  These are the neighbours that make the distinction decidable, and
    # they are here because a hang is invisible in a log comparison -- only the
    # shape survives.  See SKIP in test_chip_suite.
    ("pat-greedy-no-tail", "print(('abc'):match('.*'), ('abc'):match('a*'), "
     "('abc'):match('.-'), ('abc'):match('a.c'), ('ab'):match('a*ab'))",
     None, "run"),
    # tonumber(s, base) for a base other than 10.  Zero chip nodes: the walk is a
    # loop in a LUA piece, so the price is characters, not gates.  PUC's rule is
    # narrower than the no-base case and the narrowness is the whole test --
    # once a base is named, PUC reads digits and stops at the first byte that is
    # not one of them, so no 0x, no 0b, no point, no exponent.
    ("tonum-base-16", "print(tonumber('ff', 16), tonumber('0xff', 16), "
     "tonumber('+ff', 16), tonumber('ff ', 16), tonumber('f', 16))",
     None, "run", {"ticks": 9000}),
    ("tonum-base-2-36", "print(tonumber('1010', 2), tonumber('zz', 36), "
     "tonumber(' -17 ', 8), tonumber('777', 8), tonumber('11111111', 2) + 0.0)",
     None, "run", {"ticks": 9000}),
    # base 10 with an explicit base is PUC's INTEGER grammar, not the decimal
    # one: no exponent, and no 0x -- the last of which the chip used to answer
    # 16 through the hex fallback.
    ("tonum-base-10-explicit",
     "print(tonumber('10', 10), tonumber(' 10 ', 10), tonumber('1e3', 10), "
     "tonumber('0x10', 10), tonumber('1.5', 16))", None, "run",
     {"ticks": 9000}),
    ("tonum-base-rejects",
     "print(tonumber('z', 10), tonumber('', 16), tonumber(' ', 2), "
     "tonumber('0b11', 2), math.type(tonumber('ff', 16)))", None, "run",
     {"ticks": 9000}),
    ("tonum-base-bounds", "print(pcall(tonumber, '11', 1), "
     "pcall(tonumber, '11', 37))", None, "run", {"ticks": 9000}),
    # A hex numeral that ARRIVES at run time.  The hex walk is a separate piece
    # gated on the program's TEXT, and inStr0 is a string the program never
    # wrote, so the gate has to look for the input ports too -- otherwise a
    # program doing the right thing (read a number, allow hex) gets "attempt to
    # call a nil value" on a value PUC converts.  The decimal half is here so
    # the case also pins that widening the gate did not make every program pay.
    ("tonum-hex-from-input", "print(tonumber(inStr0), tonumber('42'))", None,
     "run", {"ticks": 9000, "sinputs": {0: "0xff"}}),
    ("tonum-decimal-from-input", "print(tonumber(inStr1))", None, "run",
     {"ticks": 9000, "sinputs": {1: " 42 "}}),
    # (%w*)$ -- a %w* that matches empty at end of subject
    ("puc-wstar-anchor", "print(string.match('alo ', '(%w*)$') == '')", None,
     "run"),
    # %+#014.0f -- the '#' point kept apart from the sign
    ("puc-format-alt-zero", "print(string.format('%+#014.0f', 100))", None,
     "run"),
    ("puc-format-alt-neg", "print(string.format('%#.0f', -100))", None,
     "run"),
    # tostring of a function: the chip's address spelling
    ("puc-tostring-func", "print(string.find(tostring(print), 'function:') "
     "~= nil)", None, "run"),
    # tostring(f) is PUC's `function: %p` and tostring(t) its `table: %p`, so a
    # prefix is the decidable part -- the address itself cannot be (the chip's
    # registers are doubles, PUC's pointer is 64-bit).  This is the shape the
    # old CHIP_LOG entry missed: the oracle's log framing stops at the first
    # space, so PUC's pointer prints as "function" and a prefix test was the
    # only thing that could tell the two spellings apart.
    ("tostr-func-shape",
     "local s = tostring(print) print(s:sub(1, 9), s:sub(10, 11), "
     "s:sub(12, 12) ~= ' ' and s:sub(12, 12) ~= '') "
     "local t = tostring({}) print(t:sub(1, 5), t:sub(6, 7))",
     None, "run"),
    # %u needs the full 64-bit range: the registers are doubles, so ~(-1 << 64)
    # is already rounded before the formatter sees it.  Same wall as integers
    # past 2^53 and as matching PUC's math.random.
    ("puc-format-u64", "print(string.format('%u', ~(-1 << 64)))", None,
     "run"),
    # io.stderr writes to the log (one text channel); os.exit halts
    ("io-stderr-write", "io.stderr:write('e1') print('p1')", None, "modelio",
     {"expect": {"log": "e1p1\n"}}),
    ("io-stderr-flush", "io.stderr:write('e2'):flush() print('p2')", None,
     "modelio", {"expect": {"log": "e2p2\n"}}),
    ("os-exit-clean", "print('s1') os.exit() print('NEVER')", None, "run"),
    ("os-exit-zero", "print('s2') os.exit(0) print('NEVER')", None, "run"),
    ("os-exit-code", "print('s3') os.exit(3) print('NEVER')", None,
     "runtimerr", {"expect": {"err": "exit: 3"}}),
    # os.exit is error() underneath, so pcall catches it and the program prints
    # false + the message; PUC's exit terminates THROUGH pcall and prints
    # nothing (the oracle exits rc=5, so this cannot be a `run` case at all --
    # there is no oracle log to compare against).  Unavoidable without a halt
    # primitive the compiler does not have.
    ("os-exit-pcall", "local ok, e = pcall(os.exit, 5) print(ok, e)", None,
     "modelio", {"expect": {"log": "false\texit: 5\n"}}),
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
    ("for-zero-trip-depth", "local function skip() for i=1,0 do end end "
     "for k=1,20 do skip() end for j=1,1 do end print('ok')", None, "state",
     {"expect": {"log": "ok\n", "state": {"forDepth": 0}}}),
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
    ("for-break-nested", "for i=1,2 do for j=1,5 do break end print(i) end",
     None, "state", {"expect": {"log": "1\n2\n", "state": {"forDepth": 0}}}),
    ("for-return-depth", "local function f() for i=1,3 do return 1 end end "
     "for k=1,3 do print(f()) end for i=1,2 do end print('done')",
     None, "state", {"expect": {"log": "1\n1\n1\ndone\n",
                                "state": {"forDepth": 0}}}),
    ("for-error-depth", "for i=1,2 do pcall(function() "
     "for j=1,2 do error('x') end end) end for j=1,2 do end print('done')",
     None, "state", {"expect": {"log": "done\n",
                                "state": {"forDepth": 0}}}),
    ("for-nested-limit", "local function f(n) for i=1,1 do "
     "if 0 < n then f(n-1) end end end f(20)", None, "runtimerr",
     {"expect": {"err": "too many nested numeric loops"}}),
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


def build_globals_over():
    """One global past MAX_GLOBALS, as build_stress is exactly up to it.

    Derived from the spec the same way, so it is one slot over rather than a
    number typed twice.  The declaration that goes over is the FIRST one, so the
    case can name its line: what the chip has to say is which declaration asked
    for too much.
    """
    n = spec.MAX_GLOBALS - len(spec.GSLOT_ORDER) + 1
    lines = [f"w{k} = {k}" for k in range(n)]
    lines.append("print('unreachable')")
    return "\n".join(lines) + "\n"


def build_overcap():
    """A program that must not fit: 40 statements of 26 additions is just over
    MAX_INSTR instructions (see the limits in lua.ws and tests/spec.py)."""
    return "\n".join(
        "v0 = %s" % "+".join(str((k + j) % 9 + 1) for j in range(26))
        for k in range(40)) + "\n"
