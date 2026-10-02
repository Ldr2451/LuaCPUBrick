/// Lua 5.5 in WireScript: a parser, a register VM, and the standard library,
/// on one chip.
///
/// Wire a Lua program into `program` (a string variable gate) and drive `run` high.
/// The program is lexed, parsed to flat bytecode, then executed on a register VM.
/// Numbers go in through inNum0..inNum3, strings through inStr0..inStr1, whole arrays
/// through inNumArr and inStrArr, and the program itself in the log; outNum0..outNum3, outStr0..outStr1,
/// outArr comes back out
/// are writable from Lua.
///
/// Ports
///   in  program: string   Lua source, newlines and all. Changing it re-parses.
///   in  run: bool         level input. High: the program executes. Low: execution
///                         stops immediately (outputs keep their values). A rising
///                         edge restarts the program from the top. Left unwired it
///                         is low, so nothing runs: wire a constant true to auto-run.
///   in  inNum0..inNum3: float   sticky numeric inputs, readable as globals inNum0..inNum3
///   in  inStr0..inStr1: string  sticky string inputs, readable as globals inStr0..inStr1
///   in  inNumArr: float[]    Lua reads it 1-based via innumarr(i); out-of-range reads nil.
///                         innumarr(i, k) reads k of them into k results (k is 1..8, and
///                         a slot past the end reads nil), so a run of adjacent slots
///                         costs one call instead of k
///   in  inStrArr: string[]  the same two shapes for strings, via instrarr(i) and
///                         instrarr(i, k).  A port carries one wire type, so this is
///                         a second port rather than a wider inNumArr: a program
///                         that needs both reads both, and one that has only
///                         numbers keeps paying nothing for the string half
///
///   Naming: a PORT is camelCase and the function that reads or writes it is the
///   lowercase of that name -- outNum0/outStr0/outArr are written by outnum,
///   outstr and outarr, and inNumArr/inStrArr are read by innumarr/instrarr.  The
///   camelCase names a program sees as VALUES (inNum0, inStr0) are the port
///   mirrors, which are values and not calls, so they keep the port's spelling.
///   out log: string       print and io.write output: a print call is one line (args
///                         tab-separated plus a newline, capped at 64 chars), an
///                         io.write is its raw text with no tab and no newline; the
///                         last 32 appends are kept, cleared on restart
///   out outNum0..outNum4: float  written by outnum(i, v), i 1..5 (nil writes 0.0;
///                         writing a string/table/function is a runtime error)
///   out outStr0..outStr1: string  written by outstr(i, v), i 1..2, Lua-formatted
///                                (nil writes "")
///   out outArr: float[] 64 slots, written 1-based via outarr(i, v) (nil writes 0.0).
///                         outarr(i, v, ...) writes one slot per extra value, up to 8,
///                         so a run of adjacent slots costs one call instead of k; a
///                         call with more values than that writes the first 8
///   out result: string    top-level return value, "" when none
///   out err: string       runtime error text, "" when none; compile failures read
///                         "line N: message"
///   out progDebug: string  one line per static finding, `err: ` fatal or
///                        `warn: ` advisory; empty when there were none
///   out busy: bool        true while lexing, parsing, or executing with run high
///   A change on any scalar input while `run` is high restarts the program with the new
///   value. The two array ports are the exception and are read live by innumarr() and
///   instrarr() (no restart): an array is a container and a change detector watches one
///   wire value, so there is nothing for `on Change` to observe (the compiler says so,
///   WS059). Changing an input while
///   `run` is low leaves the outputs alone.
///
/// Language (what is here)
///   types      numbers (one double type), strings, booleans, nil, functions, tables
///   vars       globals (the inputs, the writable outputs, the library tables) and
///              locals; shadowing works
///   stmts      local (single or multi), assignment (single or parallel, to names or
///              table fields; stores run right to left like PUC Lua), if / elseif / else,
///              while, repeat, numeric for, generic for, break, do / end,
///              function f(), function M.f(), function M:f(), local function f(),
///              return (any number of values), calls, f"str", f{...}, chained f()()
///   exprs      + - * / % ^ (power, right assoc), unary -, # (length of a table or
///              string), .. (concat), < > <= >= == ~= (non-associative, like Lua),
///              and, or, not
///   tables     constructors {}, {1, 2, 3}, {x = 1, y = 2}, {[k] = v}, mixed, with ,
///              or ; separators and a trailing separator; t[k], t.name, t[k] = v,
///              t.name = v, nesting (m[i][j], t.a.b), t[i], t[j] = t[j], t[i]; #t;
///              assigning nil deletes a key. Tables are references and compare by
///              identity. Keys may be integers, strings, booleans, tables or functions.
///              #t returns a border like Lua: it follows t[#t + 1] = v appends and
///              fills in out-of-order assignments. Reading a missing key gives nil.
///   functions  stored in fields and called as t.f(x) or t:f(x); function M.f() and
///              function M:f() define them; multiple returns, varargs (...) and
///              select; a call in the last slot of an argument list, return, table
///              constructor or assignment expands all of its results
///   closures   a function reads and writes the locals of the scopes around it, and
///              two closures over one local share it. A function value is a
///              *closure*, not a prototype: below the closure records (cloF) a
///              function is its own closure, so two evaluations of one literal
///              compare equal when nothing was captured, and one that does capture
///              gets a cell per evaluation. Each round of a loop that contains a
///              capture gets its own cells, which is what PUC gets by closing the
///              cells at the end of the block. The cells come from a fixed arena
///              and are never reclaimed -- the table heap makes the same bargain --
///              so a loop that builds a closure per iteration spends a cell per
///              iteration, and a program that runs out gets "too many upvalues"
///   library    the source of pairs, ipairs, next, select, io.*, string.*, math.* and
///              table.* is Lua text prepended to the program when the program mentions
///              it, so it is ordinary Lua running on this chip; the only gates are
///              what Lua cannot express (string byte/char/upper/lower/sub, the math
///              functions, table.unpack, next, _fmt, _rd, _wr)
///   io         io.write(...) appends the Lua-formatted arguments to the log with no
///              tab and no newline; io.read() and io.read('*l') read one line, io.read(n)
///              n bytes and io.read('*a') the rest, all from inStr0, the program's
///              standard input; io.lines() iterates its lines. Each returns nil at end
///              of input. io.write returns nothing: the chip has no file objects, so
///              there is no io.stdout to hand back the way PUC's does
///   numbers    integers (exact on-chip inside +/-2^53; Lua wraps 64-bit beyond that)
///              and floats: 0.5 .5 5. 1e3 1E-3, hex ints 0xFF. / and ^ always return
///              floats. Ints print bare (3), floats print Lua-style (3.0); 'x' .. 1
///              gives "x1", #t prints like 3
///   strings    "..." and '...' with \n \r \t \\ \" \' \<newline>, \z, \ddd and \xXX
///              for printable ASCII (32..126); other escapes are a compile error
///   formats    string.format's %d %i %u %x %X %o %c %s %q %% are exact, and so
///              are %f %e and %g: the value is scaled in a double-double, so the
///              digits are the value's own -- %f of 0.15 is 0.1 at one place and
///              344.95 is 344.9, which a single rounding cannot get right, and
///              %e and %g read the digits as a stream because a mantissa is a
///              division by 10^k and no division by ten is exact. A precision
///              above 15 for %f or 14 for %e and %g, a magnitude at 2^53 or above,
///              or a %e or %g of a value below 10^(p-14), is an error rather
///              than an approximation
///   compare    == and ~= work on all types without coercion (tables by identity);
///              < > <= >= work on numbers or lexicographically on strings, and a
///              string against a number is an error
///   coercion   arithmetic coerces a string operand the way PUC does, through
///              the host's ParseInt/ParseNumber gates: '3' + 1 is 4, '  2.5  ' * 2
///              is 5.0, '1e3' + 0 is 1000.0, -'3' is -3, and a string that is not
///              a number raises the operator's own message ("attempt to add a
///              'string' with a 'number'"), while a table or a nil says
///              "attempt to perform arithmetic on a <type> value"
///   divzero    IEEE, like PUC: 1/0 is inf, -1/0 is -inf, 0/0 is nan, and the host's
///              divide gate is a plain divide on a 64-bit float, so this is what the
///              gate does in game.  x%0 and x//0 RAISE for two integers and are nan/inf
///              with a float operand (math.fmod and the divide)
///   errors     error(msg [, level]) raises with msg as the message, assert is its
///              conditional form (a truthy first argument returns *all* of them, a
///              falsey one raises), and pcall(f, ...) / xpcall(f, handler, ...)
///              are the protected calls: true plus f's values, or false plus the
///              message -- and for xpcall, false plus the handler's *first* result
///
/// Not implemented yet (each is a loud error, never a wrong answer)
///   metatables               no setmetatable, no __index, no operator metamethods
///   goto and labels          a compile error
///   coroutines, modules
///   pcall of pcall/xpcall    those are the builtins that push a frame and the
///                             in-place dispatch has one result slot
///   integers as a type       one number type: math.type reports "integer" for a
///                             whole number, 1 == 1.0, and 64-bit wraparound is
///                             absent beyond 2^53
///   non-integer number keys  a runtime error on write, nil on read
///   tonumber with a base     the one-argument form is PUC's (a piece over the
///                             coercion above, so tonumber(s) + 1 and s + 1
///                             cannot disagree), but a base other than 10 raises
///                             "not supported": reading a base-b numeral is a
///                             walk over the digits, and WireScript has no loop,
///                             so a ladder would be fixed-width and would answer
///                             wrongly for a longer numeral.  A base outside
///                             2..36 is PUC's own error, so that much is exact
///   hex numerals in text     the host's parse is Rust's f64/i64 FromStr, which
///                             takes no "0x10", so '0x10' + 0 raises where PUC
///                             says 16.  The gates are the host's only
///                             string-to-number, so this is a host limit, and it
///                             is loud rather than a wrong answer
///
/// Other differences from PUC-Lua 5.5
///   error's message has no "chunk:line:" prefix: the chip has no line at run
///   time, so the text goes through as it is, and a protected call hands that
///   text on as a value.
///   a math PIECE given a string that is not a number raises the arithmetic
///   message ("attempt to add a 'string' with a 'number'") where PUC names the
///   function ("bad argument #1 to 'abs' (number expected, got string)").  The
///   pieces convert with `x + 0.0`, and that is the raise; the _m gate gets the
///   PUC wording right because it does the conversion itself.  Loud, never wrong
///   a builtin passed to pcall as a VALUE names itself by its short name where
///   PUC names it by its library path: pcall(string.format, '%d', 'x') says
///   "to 'format'", PUC says "to 'string.format'".  A named call agrees with
///   PUC, and the chip cannot tell which form it was reached through.
///   tostring of a nan is "nan" where PUC's C library writes "-nan" (the x86
///   default QNaN has its sign bit set).  The sign of an invalid operation's
///   result is not reachable from arithmetic, and the oracle harness normalises
///   the two spellings to one, so the value is what is being compared.
///   string.gmatch answers three values where PUC answers one (its iterator
///   ignores the arguments the generic for hands it); the chip's generic for
///   reads the walk's state out of the call.  See CHIP_LOG gmatch-arity.
///   #t is the FIRST nil minus one, and the cached border agrees with it on all
///   three of the ways a border can move: an append, a delete at or below it
///   (t[2] = nil on {1,2,3} is 1, t[1] = nil is 0, a key above it changes
///   nothing), and a fill that bridges a gap ({} t[1]=1 t[3]=3 t[2]=2 is 3).
///   a float PRINTS with the host's shortest round trip (the `..` gate's
///   format!("{f}"), so where PUC writes 17 significant digits the chip writes
///   the shortest string that reads back the same: 1/3 is 0.3333333333333333 here
///   and 0.33333333333333331 in PUC, and math.modf(3.7) answers 0.7000000000000002
///   against 0.70000000000000018.  The value is the same, the spelling is the
///   host's, and there is no precision knob to ask for.  CHIP_LOG fmt-div3,
///   math-modf.
///   so math.maxinteger PRINTS 9223372036854775808 -- 2^63, the nearest float --
///   where PUC writes 9223372036854775807.  This is the 2^53 rule above seen from
///   the other side: the literal is exact, the register is not.  CHIP_LOG
///   math-maxinteger.
///   math.random's NUMBERS are not PUC's.  PUC seeds xoshiro256** on a 64-bit
///   state and the chip runs a 32-bit LCG, so the same seed gives a different
///   sequence: math.randomseed(42) then three draws of math.random(1, 6) is
///   1, 6, 3 here and 6, 2, 4 in PUC, and math.randomseed(7) then five draws of
///   math.random(10) is 6, 1, 8, 7, 1 here against 8, 10, 10, 8, 6.  Everything
///   else about it is PUC's -- ranges, intervals, the arity, the argument
///   indexes, the error text -- so a program that uses the numbers gets
///   different ones and a program that uses the API does not notice.  The host's
///   Random gate would give a stream, but an
///   exec gate's value cannot land in a register in the same instruction (see
///   AGENTS.md), so the piece is the honest way to have both.  CHIP_LOG
///   math-random-seed42, math-random-ten.  Its two long error messages are cut at
///   the 64-character log cap, and PUC's text is three characters longer before
///   the cut, so the chip's line ends "...integer repres" where PUC's ends
///   "...r".  That is the cap, not the message.
///   tostring of a table is address-shaped (PUC's exact address is unstable).
///   t[nil] reads and writes raise "table index is nil". The output ports only
///   take numbers/booleans/nil and outArr only numbers (PUC tables take
///   anything; fixed-size float storage is a gate limitation). The log keeps
///   the last 32 lines at 64 chars each (about 2 KB).
///
/// Limits (a compile error past them, reported as an `err: ` line)
///   4096 tokens, 1024 bytecode instructions, 64 registers per function, 96 functions,
///   96 globals (34 pre-registered), 256 numeric and 256 string constants, 16 values
///   per expanded call/return/statement, 32 nested calls, 16 upvalues per function.
///   At run time: 64 program tables plus four library tables, 512 table entries,
///   352 closure records and 1024 upvalue cells.  The records are shared with the
///   program's own prototypes, which take the low end of the array, so a program
///   with N functions can make 352 - N closures; and a cell is three words of the
///   256-word vararg stack, so that stack is what runs out first and 1024 is a
///   ceiling rather than the limit a program meets.
///   A table entry is handed back when its key is assigned nil, and that is the
///   whole of the arena's reuse: there is no collector, so a table that grows
///   without deleting keys stops at 512 entries with "out of table memory".
///
/// Speed and gate count
///   Everything is unrolled per tick, so gates buy speed. Approximate cost of one extra
///   copy: vmStep 2.5k gates, parseStep 6k, lexStep 1k.
///   Execution   vmBurst() = 1 vmStep() call, fired by the Clock at STEP_INTERVAL
///               (0.01 s, so at most once per tick): up to about 60 VM instructions per
///               second at 60 ticks per second. Whether the game really fires the Clock
///               that fast has not been measured; time a loop with clock() to check.
///               Rough sizes: an 8 element bubble sort is ~740 instructions, 16 elements
///               ~2600, 32 elements ~9400.
///   Parsing     lexChunk() scans 2 characters per tick, and real source costs
///               1.3 to 1.75 ticks a character once it is parsed as well, so
///               parseChunk() = 1 parser step per
///               tick. A few hundred characters take a few seconds. Add or remove calls in
///               lexChunk / parseChunk / vmBurst to trade gates for speed.
///               Six chains are past the ~16 arm edge and the suite runs every one
///               of them, so arm count on its own is not the hazard; what the one
///               measured failure had was a write at the bottom of a deep else
///               branch.  tools/chip/chainmap.py lists them, and
///               tools/chip/lexrate.py measures the rates above.
///
/// Verification: differential tests against real Lua 5.5, structural model<->chip
/// consistency checks (builtin ids, global slots, limits, ports, opcode and keyword
/// coverage, re-parse/restart clearing), and simulated handler tests for run, the log,
/// innumarr/outarr, outnum/outstr and error reporting.
/// It has not been run inside Brickadia.

@layout("cube")

// ---------------------------------------------------------------- ports

@left in program: string
@left in run: bool
@left in inNum0: float
@left in inNum1: float
@left in inNum2: float
@left in inNum3: float
@left in inStr0: string
@left in inStr1: string
@left in inNumArr: float[]
@left in inStrArr: string[]

@right out log: string = logV.Value
@right out outNum0: float = oF0.Value
@right out outNum1: float = oF1.Value
@right out outNum2: float = oF2.Value
@right out outNum3: float = oF3.Value
@right out outNum4: float = oF4.Value
@right out outStr0: string = oS4.Value
@right out outStr1: string = oS5.Value
@right out outArr: float[] = outArrV
@right out result: string = resultV.Value
@right out err: string = errV.Value
@right out progDebug: string = progDebugV.Value
@right out busy: bool = jobBusy || (run && progOkV && !vmHalted)

// ---------------------------------------------------------------- tunables

const STEP_INTERVAL = 0.01
const MAX_INSTR = 1024
// the prepended library plus a full program; the token arrays are sized from
// this, so raising it costs gates (see tools/chip/audit.py)
const MAX_TOKENS = 4096
// Entries in the inNumArr, inStrArr and outArr ports.  A const rather than
// inNumArr.length() because an input PORT cannot be read during codegen - it
// empties every program's log - and the width is needed while parsing.
// test_consistency
// checks this against spec.OUTARR, which is what actually sizes the array, so
// the two cannot drift without the suite going red.
const ARR_SLOTS = 64
const MAX_REGS = 64
// function slots: the reserved builtins, the prepended library, and the
// program's own functions.  The arrays grow on demand, so this is a bound, not
// a size.
const MAX_FUNCS = 96
// A bound, not a size, like MAX_FUNCS: gtag/gnum/gstr grow on demand, so this
// costs no gates at all (measured: 64 -> 96 left the audit at the same node
// count).  It was 64 and every gate builtin takes a global slot of its own, so
// a program that used the whole library plus a large reproducer ran out of
// names -- tests/lib_callchain.lua needs 24 of them and hit the ceiling the
// moment pcall took slot 39.  The number that matters is MAX_GLOBALS minus the
// builtin slots, and it should stay well clear of what a real program declares.
const MAX_GLOBALS = 96
const MAX_CALLS = 32
const MAX_TABLES = 68
const MAX_HEAP = 512
// live vararg values across all active frames
const MAX_VA = 256
// Upvalue descriptors per function, and the stride of fUpSrc/cloU: one per
// captured local of the frame plus one per upvalue inherited from the
// enclosing function.  PUC's limit is 60,255; a frame has 64 registers, so 16
// is well past anything a program can express here and it keeps the runtime's
// slot table small.
const MAX_UP = 16
// Closure records.  A function with upvalues gets one per evaluation; a
// function without them is its own closure (cloF[c] = c below the range), so
// nothing is allocated for the common case.
const MAX_CLO = 256
// Upvalue cells, and the same bargain the table heap makes: there is no
// garbage collector, so a cell lives until the program ends and a loop that
// creates a closure per iteration spends one cell per iteration.  PUC
// reclaims them; here the arena is the ceiling and a program that runs out
// gets "too many upvalues", never a wrong answer.
const MAX_CELL = 1024
// most values one call/return/statement can carry (matches MAX_INSTR-style
// unrolling in retAdjust and the return paths)
const MAXVALS = 16

// Gate builtins live in function slots 0..NB-1; a program's own functions start
// at NB.  Each one is a case in the vmStep call dispatch, so adding a builtin
// means: extend this, declare its global, extend GTAG_INIT/GNUM_INIT, and add
// the dispatch case.  test_ws_consistency.py checks all four line up.
const NB = 26

// Library sources, prepended on demand (see libIter and friends).  These are
// ordinary Lua: the parser sees them exactly like the user's program.  They are
// split per family because lexing them is the cost -- a program that names one
// string function pays for one family, not for all eight.
// Library functions are written as field assignments, not `function string.f`:
// the parser does not take a dotted name on `function` yet.
const LIB_iter = "function _ipairs_iter(t, i) i = i + 1 local v = t[i] if v ~= nil then return i, v end end\nfunction ipairs(t) return _ipairs_iter, t, 0 end\nfunction pairs(t) return next, t, nil, nil end\n"
const LIB_str_index = "string = string or {}\nstring.len = function(s) return #s end\nstring.sub = function(s, i, j)\n  local l = #s\n  i = i or 1\n  j = j or -1\n  if i < 0 then i = l + i + 1 if i < 1 then i = 1 end elseif i == 0 then i = 1 end\n  if j < 0 then j = l + j + 1 elseif j > l then j = l end\n  if i > j then return \"\" end\n  return _s(1, s, i - 1, j - i + 1)\nend\nstring.byte = function(s, i, j)\n  i = i or 1\n  j = j or i\n  if i < 0 then i = #s + i + 1 end\n  if j < 0 then j = #s + j + 1 end\n  if i < 1 then i = 1 end\n  if j > #s then j = #s end\n  if i > j then return end\n  if i == j then return _s(4, s, i - 1, 0) end\n  local r = {}\n  for k = i, j do r[#r + 1] = _s(4, s, k - 1, 0) end\n  return unpack(r, 1, #r)\nend\nstring.char = function(...)\n  local r = \"\"\n  for i = 1, select('#', ...) do r = r .. _s(5, \"\", select(i, ...), 0) end\n  return r\nend\n"
const LIB_str_fmt = "string = string or {}\nstring.format = _fmt\n"
// The wrappers pass their arguments straight through rather than naming them:
// a named parameter pads a missing one with nil, and PUC's "got no value" and
// "got nil" are different messages.  A vararg call keeps the real count.
const LIB_str_pat = "string = string or {}\nstring.find = function(...) return _pat(0, ...) end\nstring.match = function(...) return _pat(1, ...) end\n"
// gmatch is a gate that answers all three values itself, so the piece is the
// binding and nothing else: 25 characters, where the gsub piece is 3109.
const LIB_str_gmatch = "string = string or {}\nstring.gmatch = _gmatch\n"
const LIB_str_case = "string = string or {}\nstring.upper = function(s) return _s(2, s) end\nstring.lower = function(s) return _s(3, s) end\n"
const LIB_str_misc = "string = string or {}\nstring.rep = function(s, n, sep)\n  if n <= 0 then return \"\" end\n  sep = sep or \"\"\n  local r = s\n  for i = 2, n do r = r .. sep .. s end\n  return r\nend\nstring.reverse = function(s)\n  local r = \"\"\n  for i = #s, 1, -1 do r = r .. _s(1, s, i - 1, 1) end\n  return r\nend\n"
const LIB_math_const = "math = math or {}\nmath.pi = 3.141592653589793\nmath.huge = 1.7976931348623157e308\nmath.maxinteger = 9223372036854775807\nmath.mininteger = -9223372036854775808\n"
const LIB_math_int = "math = math or {}\nmath.floor = function(x) return _m(1, x, 0) end\nmath.ceil = function(x) return _m(2, x, 0) end\nmath.tointeger = function(x) return _m(13, x, 0) end\nmath.type = function(x) return _m(14, x, 0) end\nmath.abs = function(x) if type(x) == \"string\" then x = x + 0.0 end if x < 0 then return -x end return x end\nmath.sqrt = function(x) return _m(3, x, 0) end\n"
const LIB_math_trig = "math = math or {}\nmath.sin = function(x) return _m(4, x, 0) end\nmath.cos = function(x) return _m(5, x, 0) end\nmath.tan = function(x) return _m(6, x, 0) end\nmath.asin = function(x) return _m(7, x, 0) end\nmath.acos = function(x) return _m(8, x, 0) end\nmath.atan = function(y, x) return _m(9, y, x or 1) end\n"
const LIB_math_exp = "math = math or {}\nmath.exp = function(x) return _m(10, x, 0) end\nmath.log = function(x, b)\n  if b == nil then return _m(11, x, 0) end\n  if b == 10 then return _m(12, x, 0) end\n  return _m(11, x, 0) / _m(11, b, 0)\nend\n"
const LIB_math_misc = "math = math or {}\nmath.max = function(a, ...)\n  local m = a\n  for i = 1, select('#', ...) do local v = select(i, ...) if v > m then m = v end end\n  return m\nend\nmath.min = function(a, ...)\n  local m = a\n  for i = 1, select('#', ...) do local v = select(i, ...) if v < m then m = v end end\n  return m\nend\nmath.fmod = function(a, b)\n  if type(a) == \"string\" then a = a + 0.0 end\n  if type(b) == \"string\" then b = b + 0.0 end\n  local r = a % b\n  if r ~= 0 and (a < 0) ~= (b < 0) then r = r - b end\n  return r\nend\nmath.modf = function(x) if type(x) == \"string\" then x = x + 0.0 end local i = (x >= 0 and _m(1, x, 0)) or _m(2, x, 0) return i, x - i end\n"
const LIB_tab_ins = "table = table or {}\ntable.insert = function(t, ...)\n  local n = #t\n  local c = select('#', ...)\n  if c == 1 then\n    t[n + 1] = (...)\n  elseif c == 2 then\n    local pos, v = ...\n    for i = n, pos, -1 do t[i + 1] = t[i] end\n    t[pos] = v\n  end\nend\ntable.remove = function(t, pos)\n  local n = #t\n  if pos == nil then pos = n end\n  if pos ~= n and (pos < 1 or n + 1 < pos) then error(\"bad argument #2 to 'remove' (position out of bounds)\", 2) end\n  local v = t[pos]\n  local i = pos\n  while i < n do t[i] = t[i + 1] i = i + 1 end\n  t[i] = nil\n  return v\nend\n"
const LIB_tab_list = "table = table or {}\ntable.unpack = unpack\ntable.pack = function(...) local t = {...} t.n = select('#', ...) return t end\ntable.move = function(a1, f, e, t, a2)\n  a2 = a2 or a1\n  if e >= f then\n    if t > e or t <= f or a1 ~= a2 then\n      for i = 0, e - f do a2[t + i] = a1[f + i] end\n    else\n      for i = e - f, 0, -1 do a2[t + i] = a1[f + i] end\n    end\n  end\n  return a2\nend\n"
const LIB_tab_concat = "table = table or {}\ntable.concat = function(t, sep, i, j)\n  sep = sep or \"\"\n  i = i or 1\n  j = j or #t\n  local r = \"\"\n  for k = i, j do\n    local v = t[k]\n    if k > i then r = r .. sep end\n    r = r .. v\n  end\n  return r\nend\n"
const LIB_tab_sort = "table = table or {}\n_lt = function(a, b) return a < b end\ntable.sort = function(t, cmp)\n  local lt = cmp or _lt\n  for i = 2, #t do\n    local v = t[i]\n    local j = i - 1\n    while j >= 1 and lt(v, t[j]) do t[j + 1] = t[j] j = j - 1 end\n    t[j + 1] = v\n  end\nend\n"
const LIB_io = "io = io or {}\nio.read = function(...) if select('#', ...) == 0 then return _rd('*l') end return _rd((...)) end\nio.write = function(...) for i = 1, select('#', ...) do _wr(tostring((select(i, ...)))) end end\n_io_next = function() local l = _rd('*l') if l == nil then return nil end return l end\nio.lines = function() _rd('*r') return _io_next end\n"
const LIB_str_gsub = "string = string or {}\nstring.gsub = function(s, p, r, n)\nif type(s) == \"number\" then s = tostring(s) end\nlocal sl, out, pos, cnt, last = #s, \"\", 1, 0, -1\nlocal anch = _s(1, p, 0, 1) == \"^\"\nlocal rt = type(r)\nif r == nil then error(\"bad argument #3 to 'string.gsub' (string/function/table expected, got no value)\", 2) end\nif rt == \"number\" then r = tostring(r) rt = \"string\" end\nlocal add = function(v)\nlocal tv = type(v)\nif tv == \"string\" then return v end\nif tv == \"number\" then return tostring(v) end\nif tv == \"boolean\" then error(\"invalid replacement value (a boolean)\", 2) end\nerror(\"invalid replacement value (a \" .. tv .. \")\", 2)\nend\nlocal rep = function(kt, kr, add, res, m)\nif kt == \"function\" then\nlocal v, w\nif res[3] == 0 then v, w = kr(m) else v, w = kr(unpack(res, 4, 3 + res[3])) end\nif v == nil or v == false then return m end\nif w == nil or w == false then return add(v) end\nreturn add(v) .. add(w)\nelseif kt == \"table\" then\nlocal k = m\nif res[3] > 0 then k = res[4] end\nlocal v = kr[k]\nif v == nil or v == false then return m end\nreturn add(v)\nelse\nlocal o, i, rl = \"\", 1, #kr\nwhile i <= rl do\nlocal j = string.find(kr, \"%\", i, true)\nif j == nil then o = o .. _s(1, kr, i - 1, rl - i + 1) break end\nif i < j then o = o .. _s(1, kr, i - 1, j - i) end\nif j == rl then error(\"invalid use of '%' in replacement string\", 2) end\nlocal d = _s(1, kr, j, 1)\nif d == \"%\" then o = o .. \"%\"\nelseif d == \"0\" then o = o .. m\nelse\nlocal q = _s(4, d, 0, 0) - 48\nif q < 1 or 9 < q then error(\"invalid use of '%' in replacement string\", 2) end\nif 1 < q and res[3] < q then error(\"invalid capture index %\" .. d, 2) end\nif q == 1 and res[3] == 0 then o = o .. m else o = o .. add(res[q + 3]) end\nend\ni = j + 2\nend\nreturn o\nend\nend\nif rt ~= \"string\" and rt ~= \"table\" and rt ~= \"function\" then error(\"bad argument #3 to 'string.gsub' (string/function/table expected, got \" .. rt .. \")\", 2) end\nif n == nil then n = sl + 1 end\nif type(n) ~= \"number\" then error(\"bad argument #4 to 'string.gsub' (number expected, got \" .. type(n) .. \")\", 2) end\nn = _m(13, n, 0)\nif n == nil then error(\"bad argument #4 to 'string.gsub' (number has no integer representation)\", 2) end\nif n < 1 then return s, 0 end\nwhile cnt < n do\nlocal res = {_pat(2, s, p, pos)}\nif res[1] == nil then break end\nlocal a, b = res[1], res[2]\nif b == last then\nif pos <= sl then out = out .. _s(1, s, pos - 1, 1) pos = pos + 1 else break end\nelse\nif pos < a then out = out .. _s(1, s, pos - 1, a - pos) end\nout = out .. rep(rt, r, add, res, _s(1, s, a - 1, b - a + 1))\ncnt = cnt + 1\npos = b + 1\nend\nlast = b\nif anch then break end\nend\nreturn out .. _s(1, s, pos - 1, sl - pos + 1), cnt\nend\n"
const LIB_tonumber = "local function _tonum_conv(v)\nreturn v + 0\nend\ntonumber = function(...)\nlocal n = select(\"#\", ...)\nlocal v = select(1, ...)\nlocal base = select(2, ...)\nif n == 0 then\nerror(\"bad argument #1 to 'tonumber' (value expected)\", 2)\nend\nif base ~= nil then\nif type(v) ~= \"string\" then\nerror(\"bad argument #1 to 'tonumber' (string expected, got \" .. type(v) .. \")\", 2)\nend\nif base < 2 or base > 36 then\nerror(\"bad argument #2 to 'tonumber' (base out of range)\", 2)\nend\nif base ~= 10 then\nerror(\"tonumber with a base other than 10 is not supported\", 2)\nend\nend\nif type(v) == \"number\" then return v end\nif type(v) ~= \"string\" then return nil end\nlocal ok, r = pcall(_tonum_conv, v)\nif not ok then return nil end\nreturn r\nend\n"
const LIB_math_random = "math = math or {}\nlocal _rs = 12345\nmath.random = function(m, n, ...)\nif select(\"#\", m, n, ...) > 2 then\nerror(\"wrong number of arguments\", 2)\nend\nlocal v = (_rs * 1664525 + 1013904223) & 0xFFFFFFFF\n_rs = v\nif m == nil then\nreturn v / 4294967296.0\nend\nif type(m) == \"string\" then m = m + 0 end\nif _m(13, m, 0) == nil then\nerror(\"bad argument #1 to 'random' (number has no integer representation)\", 2)\nend\nlocal lo, hi\nif n == nil then\nlo, hi = 1, m\nelse\nif type(n) == \"string\" then n = n + 0 end\nif _m(13, n, 0) == nil then\nerror(\"bad argument #2 to 'random' (number has no integer representation)\", 2)\nend\nlo, hi = m, n\nargn = \"2\"\nend\nif hi < lo then\nerror(\"bad argument #1 to 'random' (interval is empty)\", 2)\nend\nreturn lo + _m(1, v / 4294967296.0 * (hi - lo + 1), 0)\nend\nmath.randomseed = function(x, y)\nlocal a = 0\nlocal b = 0\nif x ~= nil then a = _m(1, x, 0) end\nif y ~= nil then b = _m(1, y, 0) end\nlocal st = (a * 1013904223 + b) & 0xFFFFFFFF\nif st == 0 then st = 1 end\n_rs = st\nreturn a, b\nend\n"

// ---------------------------------------------------------------- state: outputs + status

var logV: string = ""
var logLen: int = 0
var logLines: string[]
var oF0: float = 0.0
var oF1: float = 0.0
var oF2: float = 0.0
var oF3: float = 0.0
var oF4: float = 0.0
var oS4: string = ""
var oS5: string = ""
var outArrV: float[]
var resultV: string = ""
var errV: string = ""
var progOkV: bool = false
// What the static passes found in the program text, for the person holding
// the Brick.  One issue per line, each prefixed `err: ` (fatal, the program
// will not run) or `warn: ` (it runs, and will misbehave), because those two
// have opposite consequences and must not be told apart by guessing.
//
// `err` is the runtime channel and keeps PUC's exact words.  This is
// deliberately NOT cleared by vmReset: the program has not changed, so its
// findings have not either.  It is a report, NOT the gate - progOkV is the
// gate, because a warning does not stop a program and a non-empty string
// therefore cannot mean "rejected".
var progDebugV: string = ""

// The two `info: ` lines a parse writes, and WHY they exist: see parseInfoStart
// beside parseJobStart.
var dbgStartV: string = ""
var dbgTick0: float = 0.0

// ---------------------------------------------------------------- value helpers
// value tags: 0 nil, 1 number, 2 string, 3 boolean, 4 function, 5 table, 6 integer

mod truthyOf(tag: int, num: float) -> bool {
  return if tag == 0 then false
    else if tag == 3 && num == 0.0 then false
    else true
}

mod fmtNum(v: float) -> string {
  return if v != v then "nan"
    else if v != 0.0 && 2.0 * v == v then if v > 0.0 then "inf" else "-inf"
    else if v == 0.0 then if 1.0 / v < 0.0 then "-0.0" else "0.0"
    else if v == floor(v) && abs(v) < 1e15 then ("" .. (v | 0)) .. ".0"
    else "" .. v
}

// ---------------------------------------------------------------- lexer state
// token kinds: 1 NUM, 2 STR, 3 NAME, 4 KW, 5 SYM, 6 EOF
 // KW ids: and1 break2 do3 else4 elseif5 end6 false7 function8 if9 local10
//   nil11 not12 or13 return14 then15 true16 while17 for18 in19 repeat20 until21
// SYM ids: +1 -2 *3 /4 %5 ^6 <7 >8 <=9 >=10 ==11 ~=12 =13 (14 )15 ,16 ;17 ..18 &25 |26 ~27 <<28 >>29 //30 :31
// Lexer stages: 0 dispatch, 1 number int, 2 number frac, 3 number exp,
//   4 string body, 5 escape, 6 name, 7 decimal escape, 8 hex escape,
//   9 z-skip, 10 comment, 99 done.

var lsrc: string = ""
// One `warn: ` line per name the compiler had to invent, built while parsing and
// handed to staticAdvice, which prefixes the rest.  Cleared with the program.
var nameWarn: string = ""
// True when the program port holds text that has NOT been parsed yet.  The
// text itself is the port, so this is all the chip needs to know.
var progDirty: bool = true
/// The text currently loaded, so a re-push of the SAME text is not an edit.  The
/// program port is a value and a host syncs the chip every tick, so without this
/// every sync recompiled the program.
var progText: string = ""
var llen: int = 0
var lpos: int = 0
var lstage: int = 0
var lline: int = 1
var lerr: bool = false
var lerrLine: int = 1
var lerrMsg: string = ""
var lstrDelim: string = ""
// lines the prepended library added, so error line numbers match the program
var libLines: int = 0
var lnumInt: float = 0.0
var lnumFrac: float = 0.0
var lnumDiv: float = 1.0
var lnumDot: bool = false
var lnumIsInt: bool = false
var lnumHexN: int = 0
var lnumExp: int = 0
var lnumExpNeg: bool = false
var lnumExpSeen: bool = false
var lidBuf: string = ""
var lescDec: int = 0
var lescCount: int = 0

var tk: int[]
var ts: int[]
var tn: float[]
var tt: string[]
var tl: int[]

// printable ASCII table for \ddd / \xXX escapes (32..126 only)
const PRINTABLES = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"

mod hexVal(cp: int) -> int {
  return if cp >= 48 && cp <= 57 then cp - 48
    else if cp >= 97 && cp <= 102 then cp - 87
    else if cp >= 65 && cp <= 70 then cp - 55
    else -1
}

mod closerFor(level: int) -> string {
  return if level == 0 then "]]" else if level == 1 then "]=]" else if level == 2 then "]==]"
    else if level == 3 then "]===]" else if level == 4 then "]====]" else "]=====]"
}
var perr: bool = false
var perrMsg: string = ""
var presReg: int = 0
var presIsCall: bool = false

var bop: int[]
var bpa: int[]
var bpb: int[]
var bpc: int[]
var constNum: float[]
var constStr: string[]
var fStart: int[]
var fParams: int[]
var fRegs: int[]
var fVar: bool[]
var mainFid: int = 0
var gmap: Map<string, int>
var gslotNext: int = 0
// global slots the runtime wires directly, resolved by name in parseInit
var slotInLatch: int = 0
var fnDepth: int = 0
var cfNext: int[]
var cfMax: int[]
var cfBase: int[]
var cfMaxLoc: int[]
var locName: string[]
var locReg: int[]
var locDepth: int[]
// has anything captured this local?  Then the function that declares it reads
// and writes the *cell* from the capture on, not the register: the cell is
// what closures see, and the register only holds the value the cell was
// seeded from.  A statement between the declaration and the first closure
// over it still goes through the register, which is right because in those
// instructions no closure exists yet.
var locCap: bool[]
// was this local declared inside a loop body?  That is the question a cell's
// lifetime turns on, because PUC closes a local's cell when the block that
// DECLARED it ends, and a block inside a loop ends once per round.  A local
// declared outside every loop outlives them all, so its cell must not be replaced
// when a loop body round ends -- which is what one global loop counter used to do.
var locInLoop: bool[]
var locLen: int = 0
// Upvalues.  fUpN[fid] is how many descriptors the prototype has, and the two
// arrays strided by MAX_UP say what each one is: fUpSrc >= 0 is the captured
// local's register in that frame (instack), < 0 is -(1 + the same local's
// index in the *enclosing* function), which is how a local two levels out
// becomes a one-level read of the enclosing closure's cell; fUpSlot is where
// that frame keeps the cell for an instack one.
// upIdx interns (prototype, local entry) -> descriptor index.  Keying on the
// entry and not the name is what makes shadowing right: a function may
// capture its own `x` and an enclosing `x` in one body, and they are
// different cells.
var fUpN: int[]
var fUpSrc: int[]
var fUpSlot: int[]
var fUpSlotN: int[]
// does the local behind this descriptor live in a block that a loop re-enters?
// Strided with fUpSlot, and the reason cellAt's generation test is conditional:
// without it, one loop body's round-end replaced the cell of every captured local
// in the function, including the ones declared outside the loop and still in
// scope.
var fUpInLoop: bool[]
var upIdx: Map<string, int>
// the prototype each compile depth is on, so a capture can be walked up the
// chain of enclosing functions
var fidAt: int[]
// A loop whose body contains a capture has to bump the generation once per
// iteration, so each round gets its own cells the way PUC's close-at-block-end
// does.  capGen counts captures; a block stamps it on the way in and compares
// on the way out, which is how "this body contains a capture" is answered
// without walking the block tree: a capture inside a nested function still
// leaves the outer loop's body stamped, which is right, because the captured
// local's block is the outer body and PUC re-opens it every round.
var capGen: int = 0
var blkCapGen: int[]
// How many loop bodies enclose the point being compiled, restored by the same
// blkEnter/blkExit pair that restores locLen and the block chain, so a body that
// leaves early cannot leave the count behind.  blkEnter takes whether the block
// it is opening IS a loop body; a block nested inside one sees the larger count
// and is still re-entered every round.
var loopNesting: int = 0
var blkLoop: int[]
// A repeat's block ends *after* its until condition, so its one-per-round bump
// is emitted in front of the condition and this says so, or the block exit
// would add a second one outside the loop.
var blkGenDone: bool = false
var selfName: string[]
var selfClean: bool[]
var selfFid: int[]
// is the function being compiled variadic?  `...` outside one is an error, and
// the VM keeps the same flag per function id in fVar
var fnVar: bool[]
// `function M:f(...)` compiles as `M.f = function(M, ...)`: the receiver name
// is not written, so the parameter list has to be told to declare it first.
// Per depth, because a function head and its parameter list are parsed at
// different times and a global would not survive a nested head.
var fnSelfArg: bool[]
var valStk: int[]
var valCall: bool[]
var valPrefix: bool[]
var opKind: int[]
var opPrec: int[]
var opA: int[]
var opB: int[]
var ctlKind: int[]
var ctlA: int[]
var ctlB: int[]
var ctlC: int[]
var plNext: int[]
var lkKind: int = 0
var lkReg: int = -1
var lkFid: int = -1
var lkDone: bool = false
var lkRaw: bool = false
// which live local the name matched, so the one test after the ladder can tell
// a local of this function from a capture without each of the 32 arms asking
var lkIx: int = -1
var blkLen: int[]
var blkNext: int[]
var opBase: int[]

// ---------------------------------------------------------------- expression machine state
// Shunting-yard, direct-emit. expectOperand tracks prefix/infix position.
// popMode 0 none, 1 precedence pops, 2 drain to marker. closeMode records a
// pending `)`/`,`/terminator close to finish once pops drain.
// opKind: 0 binop (opA=bytecode op, opB=1 left-assoc), 1 unary (opA 0=UNM
//   1=NOT), 2 call (opA=fr, opB=nargs, opC=valDepth), 3 group (opA=valDepth),
//   4 and / 5 or (opA=result reg, opB=patch pos).

var expectOperand: bool = true
var popMode: int = 0
var popPrec: int = 0
var pendKind: int = -1
var pendPrec: int = 0
var pendSub: int = 0
var pendAux: int = 0
var closeMode: int = 0
var exprDone: bool = false
var closeTrig: int = 0
var opC: int[]
var openCtor: int = 0
var ctorStk: int[]
var itBase: int[]
var itKey: int[]

var lastPatchTarget: int = -1
// Position of the most recently emitted CALL whose result count is still
// undecided.  Lua only expands a call's results when the call sits in the LAST
// argument position of an enclosing call (or feeds a fixed-arity target list),
// and that is not known when the call itself closes: `f()` ends before the
// enclosing `print(...)` does.  So record the call, then patch its C operand to
// 1 once we learn it was in tail position.
var lastCallPos: int = -1

// ---------------------------------------------------------------- statement machine state
// parseStep runs one micro-step: expression micro-ops while inExpr, else one
// statement action. contKind resumes after a unit: 1 expr-stmt, 2 if-cond,
// 3 elif-cond, 4 while-cond, 5 return, 6 local-values, 7 assign-values,
// 10 for-init, 11 for-limit, 12 for-step, 13 repeat-until-cond.
// stState tracks multi-step constructs. Control frames: 1 if (A=fpos,
// B=ends), 2 while (A=top, B=false, C=breaks, D=savedLoop), 3 func
// (A=fid, B=skip, C=resume, D=savedLoop, E=extra), 4 do,
// 5 for (A=body, B=entry-jmp, C=breaks, D=savedLoop, E=limit, F=step),
// 6 repeat (A=body-top, C=breaks, D=savedLoop).

var inExpr: bool = false
var contKind: int = 0
var stState: int = 0
var tmpA: int = 0
var tmpB: int = 0
var tmpC: int = 0
var tmpS: string = ""
var forName: string = ""
var forInit: int = -1
var forLimit: int = -1
var forStep: int = -1
var forNames: string[]
var tmpNames: string[]
var tmpRegs: int[]
// saveTmp's parking lot: counts and values of the scratch arrays
var svC: int[]
var svI: int[]
var svS: string[]
var ctlD: int[]
var ctlE: int[]
var ctlF: int[]
var ctlG: int[]
var ctlLoop: int = -1
var pdHead: int = -1
var pdThen: int = 0
// where a pending patch list points, when the target is not simply "wherever the
// code ends by the time the list is drained" (a numeric loop's break list points
// at the FOREND it has to run, which is one instruction before that)
var pdTarget: int = -1
var tmpSStk: string[]
// field name of a `function M.f()` definition, popped when its body closes
var fnKey: string[]
var funcEntryLoc: int[]
var pDone: bool = false

// ---------------------------------------------------------------- VM state
// Flat register file (pre-sized; frames share it by base offsets) and
// parallel frame stacks. Value tags match fmtVal: 0 nil, 1 num, 2 str,
// 3 bool, 4 func.

var vtag: int[]
var vnum: float[]
var vstr: string[]
var fFunc: int[]
var fBase: int[]
var fRetA: int[]
var fRetBase: int[]
var fRetPC: int[]
var fRetN: int[]
var fVaB: int[]
var fForDepth: int[]
// vararg values as one flat stack; each frame records its base in fVaB and
// vaTop is the number of live entries
var vaTag: int[]
var vaNum: float[]
var vaStr: string[]
var vaTop: int = 0
var gtag: int[]
var gnum: float[]
var gstr: string[]
var vmPc: int = 0
var vmBase: int = 0
var vmHalted: bool = true
var vmFailed: bool = false
var retCountV: int = -1
var cmpActive: bool = false
var cmpAA: int = 0
var cmpBB: int = 0
var cmpDst: int = 0
var cmpI: int = 0
var cmpOp: int = 0
var tmap: Map<string, int>
var tvTag: int[]
var tvNum: float[]
var tvStr: string[]
var tLen: int[]
var tFree: int[]
var tHeap: int = 0
var tCount: int = 0
// per-slot insertion-order chain: tOwner/tKey* describe the entry, tPrev/tNext
// link it, and tFirst/tLast are each table's ends (so pairs/next can walk in
// insertion order).  -2 marks a free (unlinked) slot, -1 the end of a chain.
var tOwner: int[]
var tKeyTag: int[]
var tKeyNum: float[]
var tKeyStr: string[]
var tPrev: int[]
var tNext: int[]
var tFirst: int[]
var tLast: int[]
// pending next() walk: nxSlot is the candidate entry, nxDst the absolute
// destination register, nxPc the call's pc (advanced when the walk finishes)
var nxActive: bool = false
var nxSlot: int = 0
var nxDst: int = 0
var nxPc: int = 0
var nxMode: int = 0
// One micro-step per burst. vmBurst raises this and the first step consumes it.
var fmtGo: bool = false
var lenChase: bool = false
var lenTid: int = 0
var latchN0: float = 0.0
var latchN1: float = 0.0
var latchN2: float = 0.0
var latchN3: float = 0.0
var latchS0: string = ""
var latchS1: string = ""
var forDepth: int = 0
var forCtrl: int[]
var forRem: float[]

// ---------------------------------------------------------------- closures
// A function value (tag 4) holds a *closure* number, not a prototype.  Below
// cloBase a closure is its own prototype -- cloF is only written for the
// records above it -- so every builtin and every function with no upvalues
// works exactly as it did, and PUC's rule that two evaluations of one literal
// are the same value when nothing was captured falls out of that.  A function
// *with* upvalues gets a record per evaluation, and cloU is its cell list,
// strided by MAX_UP.
var cloBase: int = 0
var cloTop: int = 0
var cloF: int[]
var cloU: int[]
// Upvalue cells: one value each, out of a fixed arena, never reclaimed.  That
// is the same bargain the table heap makes and it is what a collector would
// fix -- a loop that makes a closure per iteration spends a cell per iteration.
// Cell 0 is the "none" marker, so a slot needs no clearing to start empty.
var uTag: int[]
var uNum: float[]
var uStr: string[]
var uTop: int = 1
// A frame's slot table -- three words per captured local: the cell, the frame
// that made it, the loop round it was made in -- sits in the vararg stack just
// below that frame's varargs, and the word below *it* is the frame's own
// sequence number.  The stamps are what stop a new frame adopting the last
// one's cells (the table is scratch space) and what give each round of a loop
// its own, which is what PUC gets by closing the cells at the end of the block.
var frameSeq: int = 0
var iterGen: int = 0
// cloStep's state: one cell per tick, driven from vmBurst.
var cloCur: int = 0
var cloCid: int = 0
var cloK: int = 0
var cloN: int = 0
var cloDst: int = 0
var cloActive: bool = false

// Pre-registered globals, in the gDeclare order in parseInit: the six INPUTS are
// slots 0..5 (inNum0..inNum3 then inStr0..inStr1) and are filled from the latches;
// after them come the callables, the four library tables, and instrarr last.  The
// writable outputs are deliberately NOT globals -- they are written by
// outnum/outstr/outarr and read on their own ports, so there is no slot for them
// at all.
// The two arrays below carry the seed for every slot, and that pair plus the
// gDeclare list are the authority.  This comment used to spell the whole slot map
// out in prose, and was wrong twice over: it listed outNum0..outNum4, invec and
// outvec as globals, and none of the three exists -- the outputs are calls and the
// vector ports are gone (RESERVED_FIDS keeps the ids).  That is a hand-kept mirror
// of numbers the chip computes, which is how a doc ends up confidently disagreeing
// with the build, so it now repeats only the two facts worth having.
var GTAG_INIT: int[] = [1, 1, 1, 1, 2, 2, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 5, 5, 5, 5, 4]
var GNUM_INIT: float[] = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 23.0, 24.0, 0.0, 1.0, 2.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0, 16.0, 17.0, 18.0, 19.0, 20.0, 21.0, 22.0, 0.0, 1.0, 2.0, 3.0, 25.0]

// pcall, which PUC has in C and is a gate here for the same reason.
//
// The shape is a marker frame: a sentinel fid on the same fFunc stack the calls
// use, carrying the pcall's own return.  pcall pushes the marker and then makes
// the call to f itself with that call's results one register past the pcall's
// own, so `true` has a register of its own and the values land beside it.  The
// marker is what makes nesting work: a pcall inside a pcall has its own, and
// the innermost one is what an error unwinds to.
const PCALL_MARK = 99
var pcallH: float = 0.0         // xpcall's message handler, as a value: it has
var pcallHT: int = 0            // to be a variable, because the protected call's
                               // own frame is written over its register
var pcallMsg: string = ""      // the error a protected call caught
var pcallUnwind: bool = false  // and that there is one to unwind
var pcallDepth: int = 0        // markers on the stack: above zero, an error is a value
var pcallIsX: bool = false     // and the call is xpcall, so an error goes to a handler
var pcallMode: int = 0         // 0 the protected call itself, 1 its message handler
var pcallBase: int = 0         // the frame the call was made from: a caught error
                               // leaves vmBase wherever it got to
var pcallGate: bool = false    // a gate is waiting to run at pcallGatePc
var pcallGatePc: int = 0       // which is the protected call's own instruction
var pcallGateArgs: int = 0     // and how many arguments it should be given
var pcallRan: bool = false     // and the dispatch now under way is that gate
var pcallBad: int[]            // whether that dispatch raised: an array, because
                               // a mod's write to a file variable is not read
                               // back reliably inside the same step
var pcallGo: bool = false      // and pcallEnter has a frame to push
var pcallFid: int = 0          // which function
var pcallA: int = 0            // the pcall's own register
var pcallNArgs: int = 0        // how many arguments it was given

// PUC's string-to-number coercion, which the chip did not have at all: '3' + 1
// is 4, ' 2.5 ' * 2 is 5.0, '0x10' + 0 is 16, '1e3' + 0 is 1000.0, -'3' is -3,
// and a string that is not a number raises with the operator's own wording.
// The host's ParseInt/ParseNumber gates are the primitive: each answers a value
// and a Success flag, and the simulator models them with int(s)/float(s) and
// that flag, so '10abc' fails (PUC wants the whole string) while '  2.5  '
// parses.  ParseInt is tried first, which is also PUC's order and is what makes
// '2' an integer and '2.0' a float: a fraction or an exponent in the numeral
// makes ParseInt fail, so the answer takes the float path.
//
// It is two mods with one latch each, not one mod with one latch, and not an
// if-expression.  A mod call in a VALUE position runs whether the arm runs or
// not -- the trap that made math.type('x') raise through numArg -- and a `let`
// taken from a var the same mod writes is re-derived at its next use, so a
// shared latch would answer with the RIGHT operand's kind.  A latch per operand
// side-steps that: nothing overwrites it after its call, so a re-derivation
// reads the same value.
//
// The kind is what the caller needs for PUC's integer/float split: 0 the
// operand was not a string, 1 a string that converted to an integer, 2 one that
// converted to a float, 3 a string that is not a number at all.
var coerceL: int = 0
var coerceR: int = 0

mod toInt(v: float) -> int {
  return v | 0
}

const INT64_LIMIT = 9223372036854775808.0
const INT64_WRAP = 18446744073709551616.0

// One VM instruction (ISA in spec.py).
// Composite map key for table `tid`: kt is the key's value tag.
mod tkey(tid: int, kt: int, kn: float, ks: string) -> string {
  return if kt == 1 || kt == 6 then tid .. "#" .. (kn | 0)
    else if kt == 2 then tid .. "$" .. ks
    else tid .. "@" .. kt .. ":" .. (kn | 0)
}

mod keyTag(t: int, v: float) -> int {
  return if t == 1 && v == floor(v) then 6 else t
}
var fmtBase: int = 0          // the call's register base (absolute)
var fmtArgs: int = 0
var fmtArgI: int = 0
var fmtPos: int = 0
var fmtOut: string = ""
var fmtBody: string = ""
var fmtPre: string = ""       // the sign or 0x prefix, kept ahead of zero padding
var fmtPadAcc: string = ""
var fmtArg: string = ""
var fmtNum_: float = 0.0
var fmtWidth: int = 0
var fmtPrec: int = 0
// one int per flag rather than a bitmask: WireScript has no bitwise and, and
// fmtMinus / fmtZero / ... say what they are
var fmtMinus: int = 0
var fmtPlus: int = 0
var fmtSpace: int = 0
var fmtHash: int = 0
var fmtZero: int = 0
var fmtState: int = 0
var fmtPad: int = 0
var fmtNeg: bool = false
// the padding side and fill are bools, not the 0/1 ints the flags are: an int
// flag var read in a condition compares through a placeholder that reads 0, and
// %-6d silently came out right-justified
var fmtPadLeft: bool = false
var fmtPadZero: bool = false
var fmtCh: string = ""
var fmtEof: bool = false
var fmtTo: int = 0
// the quoted walk has its own cursor: it used to share fmtPos with the spec walk
// and reset it to 0, so after %q the spec was read from the start again and the
// conversion ran twice ("%q" of "" asked for argument #3)
var fmtQPos: int = 0
var fmtBase_: float = 10.0
var fmtBaseI: int = 10
var fmtQ_: int = 0
var fmtD_: int = 0
var fmtUpper: bool = false
var fmtDigits: int = 0
var fmtDigitsMax: int = 0
var fmtSpec: string = ""
const HEXDIG = "0123456789abcdef"
const HEXDIG_U = "0123456789ABCDEF"
const ZEROS16 = "0000000000000000"

// The name of a value tag, for error messages: PUC says "got string" for a
// wrong argument and "got no value" for a missing one, so the caller passes the
// tag it would have read and says "no value" itself when there is none.
mod typeName(t: int) -> string {
  return if t == 0 then "nil" else if t == 1 || t == 6 then "number" else if t == 2 then "string" else if t == 3 then "boolean" else if t == 4 then "function" else if t == 5 then "table" else "userdata"
}

// The quoted form of one byte: PUC 5.5 writes a backslash and a real newline
// for a newline, not "\n", so a quoted multi-line string stays one pasteable
// literal; a tab is a numeric escape.  The digits are written without a loop:
// anything below 32 is one or two digits, and 127 is the only three-digit one.
mod fmtQuoteByte(b: int) -> string {
  if b == 34 {
    return "\\\""
  } else if b == 92 {
    return "\\\\"
  } else if b == 10 {
    return "\\\n"
  } else if b == 13 {
    return "\\r"
  } else if b == 0 {
    return "\\0"
  } else if b == 127 {
    return "\\127"
  } else if b < 10 {
    let one = b
    let ch1 = FromCharCode(48 + one).Character
    return "\\" .. ch1
  } else if b < 32 {
    // no `%` operator in WireScript, so the tens digit is a floor division
    let tens = floor(b / 10.0)
    let ones = b - tens * 10.0
    let ch2 = FromCharCode(48 + tens).Character
    let ch3 = FromCharCode(48 + ones).Character
    return "\\" .. ch2 .. ch3
  } else {
    return FromCharCode(b).Character
  }
}

// %e.  The mantissa is the value divided by 10^k, and no division by ten is
// exact -- 1/10 is not representable -- so this cannot be %f with a different
// exponent bolted on.  It is a digit stream instead: the integer part's digits
// come off one division at a time, the fraction's off a double-double multiplied
// by ten per digit, and the exponent is where the first nonzero digit sits
// relative to the point.  The mantissa is those p+1 digits read as one integer,
// so a carry out of them is +1 on the exponent rather than a walk back through
// the digits.  See the note above fmtConvFloat for why this is its own shape.
var fmtAll: string = ""      // the integer's and the fraction's together
var fmtK: int = 0            // the decimal exponent
var fmtS: int = 0            // the index of the first significant digit
var fmtPt: int = 0           // how many digits sit before the point
var fmtM: float = 0.0        // the mantissa's p+1 digits, as one integer
var fmtMI: int = 0           // the cursor while they are read
var fmtNz: int = 0           // the fraction digits taken so far
var fmtLz: int = -1          // where the first nonzero one is, -1 until it is
var fmtLead: int = 0         // the mantissa's first digit, once they are read
var fmtExp: string = ""      // the exponent's digits, separate from the value's
var fmtUpperE: bool = false  // %E, which is the same number with an E
var fmtSticky: bool = false // something nonzero follows the round digit
var fmtSI: int = 0           // the cursor for that scan
var fmtENum: int = 0         // the exponent while it is written out

// %g, which is %e or %f chosen by the exponent, and then has its trailing zeros
// taken off.  The choice needs the exponent first, so it runs %e's digit walk
// to get it and then goes back through one arm or the other: %e's, with the
// precision one lower, or %f's, with p-1-k places and no exponent at all.  The
// digits are already in fmtAll either way, so the %f arm is string surgery on
// them rather than a second conversion.
var fmtIsG: bool = false     // this conversion is %g, not %e
var fmtG0: int = 0           // %g's own precision, before either arm changes it
var fmtStrip: bool = false   // and it drops trailing zeros (# says keep them)
var fmtGToExp: bool = false  // and its stripped form wants the exponent after

// %f: the value scaled by its precision and rounded to an integer, which is
// then read out one digit per tick with the point put back.  The scale is the
// whole difficulty: a double times a power of ten is not the exact product
// (0.15 * 10 is 1.5, and the exact product is 1.4999999999999999944..., so the
// one-rounding version prints 0.2 where PUC prints 0.1), and a rounded product
// cannot say which side of a .5 it landed on.  So the product is carried in a
// double-double: two doubles holding 106 bits, and the tie is read off the sign
// of the half the single multiply dropped.  tools/fmt/fmtdiff.py measures what the
// cheap version costs: 0.17% of the values that fit come out with the wrong
// last digit, and they are 0.05, 0.15, 344.95 -- the values programs format.
var fmtV: float = 0.0         // |the argument|
var fmtDd: float[]           // the double-double: [0] the high half, [1] the low
var fmtIP: float = 0.0        // the integer part, exact while it is below 2^53
var fmtF: float = 0.0         // the fraction scaled by the precision
var fmtInt: string = ""       // its digits, least significant first
var fmtFr: string = ""        // and the fraction's
var fmtP: int = 0             // the precision in force, %f's 6 when none given
var fmtNxt: int = 17          // where the integer digit walk goes when it ends

// ==================================================================== patterns
//
// string.find, string.match and string.gmatch are C in PUC (lstrlib.c) and are
// gates here for the same reason: a backtracking matcher wants a stack and a
// loop, and a Lua program gets neither without a coroutine per match.  gsub's
// *matcher* is the same gate, called one match at a time by mode 2, but gsub's
// loop is a library piece (LIB_str_gsub): its replacement can be a Lua function
// and a gate cannot call one, so the part that has to call back into Lua stays
// in Lua.  The library piece around find and match is ordinary Lua too (see
// libStrPat), which is the split PUC itself makes.
//
// The shape is the _fmt machine: the gate arm sets the subject, the pattern and
// where the answers go, raises patGo, and the steps below run one piece per
// tick until the registers hold PUC's answer.  What is PUC's is the algorithm:
// lstrlib's match() is recursive, and the recursion here is an explicit stack
// of continuations (patSl, four ints per entry -- kind, pattern position,
// subject position, and one spare for %b's depth).
//
// The stack holds only what a flat pattern needs:
//
//   1  a class item under + or *: the subject position before the item, so a
//      failed rest can consume one more character and try again
//   2  a ?: the pattern position past the ?, to carry on with the item skipped
//   3  %b: the balance depth, to keep counting from where it was
//
// Captures work the way PUC's do_match recursion does, with a flat machine
// keeping what the recursion gets for free.  A capture's number is how many the
// attempt has opened, and its depth is how many are open now: "(a)(b)" closes the
// first before it opens the second, so the number is not the depth, and the
// number of the innermost *open* capture is neither -- that one is a stack,
// patCapIx.  A quantifier inside a capture gives a character back and runs the
// ) again, so the ) records that it closed and the rewind opens it again.  A (
// followed by ) is PUC 5.5's position capture, whose value is where it stands,
// as a number.
//
// Four traps this part paid for, all general enough to be here:
//   - An int[] does not keep a negative value.  The capture ends were sentinels
//     of -1 for "open" and -2 for a position capture, and every one of them read
//     back as 0, so every capture looked like an empty match.  The ends are
//     stored plus one, with the position case in a flag of its own.
//   - A local computed from a var the same mod writes is re-derived at its next
//     use, so patOpen's n = patCapN + 1 became n + 1 when it reached the push
//     and the first capture's entry pointed at the second one's slot.  Compute
//     it, use it, and write the var last.
//   - A quantifier with no item in front of it is PUC's own dead end rather than
//     an error: max_expand wants at least one match of the character it names.
//     That is why "(%d+)-" still finds its minus and "a??b" finds nothing.
//   - A capture's answer does not fit an expression's registers past MAXVALS, so
//     a find with more captures than that is refused rather than written over
//     the values after it.
//
// The cost is ticks, not gates, and it is worth knowing which is which before
// making this faster.  The library piece is 130 characters, so a program that
// names find or match pays about 33 ticks of lexing on every run (4 chars a
// tick) and two function literals to parse; a find that matches near the front
// is then five or six states, one tick each.  What costs is the retry: a find
// that fails tries every start position, and a quantifier that gives characters
// back walks the pattern again for each one, so a failing find over a long
// subject is O(n) states and a subject of a few hundred characters is a
// program's worth of ticks.  The fix when that matters is more states per tick
// -- call patStep several times in the arm at the top of vmStep, the way
// lexChunk calls lexStep four times -- not fewer gates.
//
// Two more from the first pass, also general:
//   - A gate may read only the arguments it was given.  A register past nargs
//     still holds whatever the caller's previous call left in it, so reading
//     a+4 for an init that was never passed gave a find a boolean init and an
//     error about argument #3.  Every argument read is guarded by its count.
//   - An array read that FOLLOWS a var write inside a nested arm loses its Exec
//     chain when the mod is inlined this many times, and the writes fed by it
//     quietly never happen: patBack popped an entry and then read its four slots
//     into patI, patItemP and patQEnd, and only the pop landed.  The slots are
//     read into locals at the top of the mod now, before anything is written.
//
// Mode 2 is the gsub shape: the same answer find gives, plus the capture count
// in the third register so the loop knows how many of the next nine it must
// read, and plus the whole match in the first when the pattern captured
// nothing.  gsub's own loop is PUC's and three of its rules are not the
// matcher's, which is where the time went when this was ported:
//   - The unmatched text between one match and the next is copied when the
//     match lands, not before it, so a find's a can be past the loop's cursor.
//     A step that does not match copies exactly one character and does not count
//     as a replacement.
//   - The loop stops when a match ends where the last one ended, which is
//     because lstrlib compares e with lastmatch and not because the matcher
//     refuses the end of the subject: find("abc", "a*", 4) is 4 3, and "aaa" on
//     "a*" is one replacement for the same reason.
//   - A leading ^ gives one match: the loop breaks after it, whatever the limit.
// A function replacement gets the captures, or the whole match when there are
// none, and not the match and then the captures; a table replacement is keyed
// by the first capture or by the whole match, and a nil or false value from
// either keeps the matched text rather than dropping it.  Those last two are
// lstrlib's push_captures and add_table, measured, not remembered.

const PAT_STACK = 200
// How many gmatch walks can be live at once: each is a slot in three arrays, and
// the nesting a program can write is the nesting a chip can afford.  The list
// resets between programs, so this is not a total-iterations budget.
const PAT_WALKS = 16

var patGo: bool = false      // one pattern step per burst, like fmtGo
var patMode: int = 0         // 0 find, 1 match, 2 gsub's one match at a time
var patSrc: string = ""      // the subject
var patPat: string = ""      // the pattern, with a leading ^ already skipped
var patPEnd: int = 0         // and its length
var patLen: int = 0
var patI: int = 0            // subject cursor, 0-based
var patP: int = 0            // pattern cursor, 0-based
var patStart: int = 0        // where this attempt began
var patR: int = 0            // the start to try after this one fails
var patAnchor: bool = false  // the pattern began with ^
var patPSkip: int = 0        // and the ^ is not part of the pattern proper
var patPlain: bool = false   // the pattern is a literal
var patQ: int = 0            // the item's quantifier: 0 none, 1 *, 2 +, 3 -, 4 ?
var patItemP: int = 0        // where the item under test starts
var patItemE: int = 0        // and just past it
var patQEnd: int = 0         // just past the quantifier
var patQS: int = 0           // the subject position before the item
var patHit: bool = false     // the last item's verdict
var patSetP: int = 0         // the set scan's cursor, just past its [
var patSetC: int = 0         // the character it is testing
var patSetAny: bool = false  // whether that character is in the set so far
var patSetSeen: bool = false // whether the set has any text yet
var patSetPrev: int = 0      // the previous character, for a range
var patSetHasPrev: bool = false
var patSetNeg: bool = false  // [^...]
var patBOpen: string = ""    // %b's two delimiters
var patBClose: string = ""
var patBC: int = 0           // and its balance
var patBFirst: bool = false  // and whether the opening delimiter is still ahead
var patFPrev: bool = false   // %f's previous-character test
var patCapS: int[]           // a capture's start, by number
var patCapE: int[]           // its end plus one, so a zero means "no end yet"
var patCapP: int[]           // and 1 for a position capture, whose value is where
                             // it stands rather than what it covers.  None of
                             // these hold a negative: an int[] does not keep one,
                             // which is what sentinels of -1 and -2 turned into
                             // plain zeroes and left every capture reading as an
                             // empty match.  Zero-plus-one is the encoding that
                             // works.
var patCapIx: int[]          // the numbers of the captures open right now, as a
                             // stack: the innermost one is not a counter, since
                             // "(a)(b)" closes the first before it opens the
                             // second, and "((a))" does not
var patNCap: int = 0         // how many captures this attempt has opened
var patCapN: int = 0         // and how many are open at this point
var patAOff: int = 0         // where the answer's captures start
var patAn: int = 0           // and which one is being written
var patAdv: int = 1          // how far the item under test moved the cursor:
                             // one character for everything but a backreference
var patSp: int = 0           // the backtrack stack's pointer, in ints
var patSl: int[]
var patErr: string = ""      // a malformed pattern's message
var patTid: int = 0          // gmatch's state slot, and how far the walk is
var patLastTid: int = 0      // the last one made, for an iterator called with
                             // something that is not a number: PUC's gmatch
                             // ignores its arguments entirely, so this is the
                             // closest answer to "f(junk)" when one walk is live
var patGmS: string[]         // each walk's subject, pattern and cursor
var patGmP: string[]
var patGmPos: int[]
var patGmId: int = 0          // the walk this call is about
var patGmPhase: int = 0       // 0 make the walk, 1 take a step
var patGmIni: int = 1         // where the walk starts: gmatch takes an init
var patAfter: int = 0        // where a finished set scan goes on a match
var patFailTo: int = 0       // and on a miss
var patSt: int = 0

// The classes PUC's %a %c %d %g %l %p %s %u %w %x mean, on the codes
// themselves: the host's isalpha is not a gate, and the lexer spells digit and
// letter out the same way.  A letter that names no class is the character
// itself, which is how %. and %b and %q work, and an uppercase letter negates.
mod patClassHit(c: int, code: int, neg: bool) -> bool {
  if code == 97 {
    let hit = (65 <= c && c <= 90) || (97 <= c && c <= 122)
    return if neg then !hit else hit
  } else if code == 99 {
    let hit = c < 32 || c == 127
    return if neg then !hit else hit
  } else if code == 100 {
    let hit = 48 <= c && c <= 57
    return if neg then !hit else hit
  } else if code == 103 {
    let hit = 33 <= c && c <= 126
    return if neg then !hit else hit
  } else if code == 108 {
    let hit = 97 <= c && c <= 122
    return if neg then !hit else hit
  } else if code == 112 {
    let hit = 33 <= c && c <= 126 && !(48 <= c && c <= 57) && !(65 <= c && c <= 90)
      && !(97 <= c && c <= 122)
    return if neg then !hit else hit
  } else if code == 115 {
    let hit = c == 32 || (9 <= c && c <= 13)
    return if neg then !hit else hit
  } else if code == 117 {
    let hit = 65 <= c && c <= 90
    return if neg then !hit else hit
  } else if code == 119 {
    let hit = (48 <= c && c <= 57) || (65 <= c && c <= 90) || (97 <= c && c <= 122)
    return if neg then !hit else hit
  } else if code == 120 {
    let hit = (48 <= c && c <= 57) || (97 <= c && c <= 102) || (65 <= c && c <= 70)
    return if neg then !hit else hit
  }
  let lit = c == code
  return if neg then !lit else lit
}

// ==================================================================== io: stdin
//
// The text in the inStr0 port is the program's standard input, and two gate
// builtins plus a library piece give it PUC's io.read / io.write / io.lines.
// inStr0 rather than a port of its own: it is already a string input, the
// harness already sets it, and a ninth input port is API surface for nothing.
//
//   _rd(fmt)  fmt is a byte count, "*a" (the rest), "*l" (a line, the newline
//            eaten, a trailing CR not part of the line) or "*r" (rewind, which is
//            what io.lines() needs to start at the beginning).  PUC's "*n" is not
//            here: it needs a string-to-number scan and the chip has no such
//            primitive, so a program that wants a number cannot get one yet.
//   _wr(s)    append to the log with no tab and no newline, which is the whole
//            point of io.write; print's line handling is not what a program
//            writing a report wants.  The order with print is kept because both
//            go through logPush, and the 32-append cap is the same one.
var rdText: string = ""
var rdPos: int = 0
var rdBuf: string = ""
var rdGot: bool = false

// ---------------------------------------------------------------- jobs + events

let sched: exec
let goParse: exec
let goParse2: exec

var jobBusy: bool = false

// ---------------------------------------------------------------- stdlib
//
// The library is plain Lua source, prepended to the program before it is
// lexed, and only the pieces a program actually names are included: parsing is
// a tick-bounded job, so an unused library would cost every run.  Only the
// handful of operations Lua cannot express at all (next, select, the _s/_m
// string and math primitives) live in the VM; everything else is Lua.

// Does p name this library entry?  A plain substring test, like the reference
// chip: it never misses a word the program actually uses, and the worst a
// needless match can do is parse a little more library.
mod srcUses(p: string, name: string) -> bool {
  return p.Find(name, true, 0) >= 0
}

// ---------------------------------------------------------------- parser/codegen state
// Bytecode: parallel bop/bpa/bpb/bpc (opcodes in spec.py;
// JMPF/JMPT carry target in pa and test reg in pb; CALL carries nargs in pb
// and multi-tail bit in pc). Functions: fStart/fParams/fRegs. Constants:
// constNum/constStr. Globals: gmap name->slot plus gslotNext. Compile frames
// (one per nested function, depth-indexed): cfNext/cfMax/cfBase/cfMaxLoc.
// Locals: locName/locReg/locDepth with locLen (truncate to exit scopes).
// Self-recursion per depth: selfName/selfClean/selfFid. Shunting-yard:
// valStk/valCall, opKind/opPrec/opA/opB. Control stack: ctlKind/ctlA/B/C.
// Patch lists thread through plNext. Parse cursor cpos, error perr/perrMsg.

var cpos: int = 0
// Position of the CALL that produced the value currently in presReg, or -1 if
// that value is not a call.  It outlives lastCallPos (which only tracks the
// most recent emission) so the consumers of a finished value â€” `return f()`,
// a target list, a constructor's last element â€” can still mark the call as
// returning all of its results.
var presCallPos: int = -1

// ================================================================= _fmt
//
// string.format as a WireScript micro-step: one character of the spec, or one
// digit, per tick, stepped from nxStep like next() is.  This hunk is installed
// and the suite covers it; lib/fmt_gate_draft.txt is the extracted copy of it,
// with the findings that took the builds to get:
//
//   python -u tools/fmt/fmtdraft.py --check      what lua.ws has
//   python -u tools/fmt/fmtdraft.py --extract    save this hunk back to the draft
//
// Why a gate and not the library: the PUC-verified Lua implementation of this
// function is lib/str_format.lua, 11468 characters and 19 functions.  Priced at
// the measured rates -- 1.3 to 1.75 ticks a character of real source, 24 to 62 a
// function (tools/chip/lexrate.py) -- prepending it models at 15,400 to 21,300
// ticks of boot per program.  That is an UPPER bound and cannot be measured at
// all: 11,478 characters does not fit the ~4 KB source buffer, so a piece this
// size could not be delivered whatever it cost.  It used to be quoted here as
// 10769 characters at four characters a tick, 2692 ticks, which applied the raw
// scan rate to source that also has to be parsed, and the scan floor is 2
// characters a tick rather than 4.  As a gate it costs +3,308 nodes and +6,026 wires
// (68,134 -> 71,442) and 0 boot ticks, and a "%d" format call runs in 0.2s of
// sim time where the Lua version took 9.4s.
//
// State: %d %i %u %s %q %x %X %o %c %%, every flag (- + space # 0), width,
// precision, the per-conversion flag table and the error messages all match
// lua5.5, case by case, in the fmt-* suite cases.  Not yet: %f %e %g (and %a),
// for which lib/str_format.lua has the algorithm and the notes on why the
// rounding needs a Dekker two-product.
//
// The rules this shape follows, each one learned by getting it wrong:
//
//   - fetch a character in a state of its own, consume it in the next.  A value
//     gate fed by a variable the same mod writes reads the NEW value, so a state
//     that read the character at fmtPos and then advanced fmtPos walked one
//     character ahead of the spec: every conversion came out as its own
//     conversion character ("%d" -> "d", "%s|%s" -> "s|s").
//   - the walk enters at the fetch state, never at the literal state, or the
//     first character is skipped.
//   - a state that hands back to the walk goes through the fetch, because
//     fmtCh still holds the character the previous state consumed: going straight
//     to the literal state appended it ("%d" -> "42d").
//   - a condition on a file-level var, NESTED inside another if, is unreliable
//     where the mod around it is inlined more than once: fmtPadStep's
//     `if fmtPadLeft` chose the else arm whatever the var held, and swapping the
//     two arms changed nothing.  The old four-step burst inlined vmStep four
//     times and the compiler shared one Get per var across the copies; the lexer's chain has the same
//     shape and works, because lexChunk inlines it once.  So the rule of thumb
//     is to hoist the test to the top of the mod or take the flag as a
//     parameter, and tools/chip/wswarn.py flags the shape as a candidate.
//   - one micro-step per burst.  The old four-step burst inlined and entered this
//     machine up to four times in one tick; fmtGo kept one write per tick.
//   - a mod call in a conditional's VALUE position is evaluated whether the arm
//     runs or not; only exec statements (a mod call that writes a var) are
//     guarded.  So `let y = if 2 < nargs then numArg(vTag(a + 3), ...) else 0.0`
//     still ran numArg on an argument the call never passed, on whatever the
//     register held from an earlier call, and died on "bad argument (number
//     expected)".  Choose the tag and the value first, then hand numArg those:
//     `numArg(if 2 < nargs then vTag(a + 3) else 0, if 2 < nargs then vNum(a + 3)
//     else 0.0)`, which is what outvec already did.
//   - a write at the top of a mod, followed by an else-if chain that deep with
//     mod calls in it, is silently dropped: fmtPos = fmtPos + 1 at the top of
//     fmtConv never happened, so the conversion was re-read as a literal.  The
//     advance is repeated in every arm instead.
//   - an int flag var read in a condition compares through a placeholder that
//     reads 0, so fmtPadLeft/fmtPadZero are bools and every assignment that
//     depends on a comparison is written as an if/else.
//   - `floor()` TRUNCATES toward zero, it is not a floor: `floor(-1.0 / 16.0)`
//     is 0, so a digit loop that divides with it never goes negative and %x of -1
//     came out as fifteen zeros.  Floor division is done by hand in fmtRadixDigit
//     (truncate, then carry a negative remainder into the digit and off the
//     quotient).  Lua's math.floor is a different code path -- the _m gate -- and
//     does floor, which is why math.floor(-2.7) is -3 and this is not.
//
// WireScript traps measured while building this, all of them in tools/chip/wswarn.py
// now, and all of them worth knowing before writing any more WireScript:
//   - `%`, `for`, and a mod call on the right of `..` all leave a placeholder
//     that reads 0, or fail as "attempt to call"
//   - a string `+`, and a chain mixing `..` with `+` -> placeholder
//   - `x = a == b` -> placeholder (assign a constant and set it in an if)
//   - a mod and a var sharing a name (fmtNum, fmtZero) -> placeholder
//   - `c >= "0"` on strings -> compiles, reads false; compare codepoints
//   - a string returned from a mod: equal by ==, but ToCharCode() reads 0, so
//     read characters into a var and test the var in a later state
//   - an assignment at the bottom of a deep else-if chain silently does not take
//     effect: fmtState = 7 in the %d branch never ran.  One mod per state is
//     the fix, and the reason fmtLit/fmtFlag/fmtWidthStep/... exist separately.
//   - tools/chip/vargraph.py is what settled the rest: it lists the var nodes behind
//     a name, how many write it, and what fires each write.
//
// ---------------------------------------------------------------- _fmt
//
// string.format as a micro-step: one character of the spec, or one digit, per
// tick.  The library is prepended Lua source, which the lexer and parser together
// charge at 1.3 to 1.75 ticks a character (measured, tools/chip/lexrate.py), so the
// PUC-verified Lua implementation of this function (kept as lib/str_format.lua,
// 11468 characters and 19 functions) models at 15,400 to 21,300 ticks of boot --
// and could not be delivered at all, since 11,478 characters does not fit the
// ~4 KB source buffer.  A gate pays
// nothing for the source and one state machine covers the loops, so this is the
// cheaper host by two orders of magnitude.  The semantics are settled by that
// reference: 107 of 108 cases match lua5.5 byte for byte.
// The argument register of the call being formatted, absolute: fmtBase + 1 +
// fmtArgI.  A mod because a write at the top of a mod is dropped, and an
// expression in the middle of fmtConv's chain would be too deep for the same
// reason.
//
// ABSOLUTE, and that is the whole point: vTag/vNum/vStr take a register relative
// to the current frame and add vmBase themselves, so passing them an index built
// from fmtBase counted vmBase twice.  At top level vmBase is 0 and it worked; in
// a function every argument but the last read from two registers too high, which
// is why `return string.format('%s%s%s', 'a', 'b', 'c')` printed `cnilnil` and
// `%d` of a number answered "number expected, got nil".  The conversions read
// vtag[]/vnum[]/vstr[] at this index for that reason, and it is also the smaller
// shape: no vmBase to add.
var fmtSrc: string = ""

mod lexFail(msg: string) {
  lerr = true
  lerrMsg = msg
  lerrLine = lline
}

// level of a long bracket ([[, [=[, ...) starting at pos, or -1
mod longLevel(pos: int) -> int {
  let seg = lsrc.Substring(pos, 8)
  return if seg.StartsWith("[[", true) then 0
    else if seg.StartsWith("[=[", true) then 1
    else if seg.StartsWith("[==[", true) then 2
    else if seg.StartsWith("[===[", true) then 3
    else if seg.StartsWith("[====[", true) then 4
    else if seg.StartsWith("[=====[", true) then 5
    else -1
}

mod curKind() -> int {
  return if cpos >= tk.length() then 6 else tk[cpos]
}

mod curSub() -> int {
  return if cpos >= tk.length() then 0 else ts[cpos]
}

mod curNum() -> float {
  return if cpos >= tk.length() then 0.0 else tn[cpos]
}

mod curStr() -> string {
  return if cpos >= tk.length() then "" else tt[cpos]
}

mod pushVal(r: int, isCall: bool, isPrefix: bool) {
  valStk.push(r)
  valCall.push(isCall)
  valPrefix.push(isPrefix)
}

mod popVal() -> int {
  if valStk.length() == 0 {
    perr = true
    perrMsg = "operand stack underflow"
  }
  valCall.pop()
  valPrefix.pop()
  return valStk.pop()
}

mod topFlag() -> bool {
  return if valCall.length() == 0 then false else valCall[valCall.length() - 1]
}

mod topPrefix() -> bool {
  return if valPrefix.length() == 0 then false else valPrefix[valPrefix.length() - 1]
}

mod setTopFlag(v: bool) {
  if valCall.length() > 0 {
    valCall[valCall.length() - 1] = v
  }
}

mod setTopPrefix(v: bool) {
  if valPrefix.length() > 0 {
    valPrefix[valPrefix.length() - 1] = v
  }
}

// ---------------------------------------------------------------- expression machine
// One micro-op per call: pops, closes, or a single token action. Operands
// push (reg, isCall); calls close with multi-tail from the last arg flag.

mod bEmit(op: int, a: int, b: int, c: int) -> int {
  bop.push(op)
  bpa.push(a)
  bpb.push(b)
  bpc.push(c)
  if bop.length() > MAX_INSTR {
    perr = true
    // The message names the cap but not the distance: a program 200 over
    // reads the same as one 3 over.  Measured and REJECTED - saying so
    // costs 1,535 nodes and 2,462 wires, 3.4% of the chip, because a concat
    // with a computed int pulls in a heavier formatting path than the const
    // concat used above.  Not worth it for a line that only appears when the
    // program is already too big to run.
    perrMsg = "program too long"
  }
  return bop.length() - 1
}


mod bPatch(pos: int, target: int) {
  bpa[pos] = target
  if bop[pos] == 21 && 0 < pos && bop[pos - 1] == 19
     && bpc[pos - 1] < 0 && bpa[pos - 1] == bpb[pos] {
    bpa[pos - 1] = -1 - target
  }
  lastPatchTarget = target
}

mod cNum(v: float) -> int {
  let r = constNum.find(v)
  if !r.Found {
    if constNum.length() >= 256 {
      perr = true
      perrMsg = "too many numeric constants"
    } else {
      constNum.push(v)
    }
  }
  return if r.Found then r.Index else constNum.length() - 1
}

mod cStr(s: string) -> int {
  let r = constStr.find(s)
  if !r.Found {
    if constStr.length() >= 256 {
      perr = true
      perrMsg = "too many string constants"
    } else {
      constStr.push(s)
    }
  }
  return if r.Found then r.Index else constStr.length() - 1
}

mod gDeclare(name: string) -> int {
  let r = gmap.get(name)
  if !r.Found {
    if gslotNext >= MAX_GLOBALS {
      perr = true
      perrMsg = "too many globals"
    } else {
      gmap.set(name, gslotNext)
      gslotNext = gslotNext + 1
    }
  }
  return if r.Found then r.Value else gslotNext - 1
}

// A global the program only READS and that nothing has declared.  The chip makes
// a slot and the read yields nil, which is exactly what PUC does, so this is NOT
// an error and must never stop the program.  But a name that resolves to nothing
// is nearly always a typo - `in0` for `inNum0` - and PUC cannot say so because
// PUC has no ports to mistype.  Recorded once per name while compiling and
// reported on progDebug as advice, which is the only thing that catches a typo
// the chip cannot enumerate.
//
// A name the source ASSIGNS is not a typo, it is a global the program defines,
// and PUC is right to give it nil before the assignment and the value after.  So
// an assignment anywhere in the source suppresses the warning, which is why this
// cannot be a text scan of the whole program up front: only the name the
// compiler actually had to invent says anything.
// A call to one of the chip's own builtins with too few arguments to do
// anything.  Advice, not a refusal: the call still goes through exactly as it
// would have, because deciding what an absent argument reads as is the runtime's
// job and this chip is not going to disagree with it at parse time.
// The index argument of a port call, when it is a literal.  Value-based, like
// the runtime check it mirrors, so outnum(2.5, v) is caught too.
// A port builtin called with NO arguments.  The count comes from the token, not
// from valStk: at the call site this call's arguments have not been pushed yet,
// so valStk counts the enclosing expression and an earlier version warned on
// outnum(i, i).
//
// The lexer emits `)` as sub 15 (`(` 14, `,` 16, `;` 17), so after cpos moves past
// the paren and the callee, the current token is `)` exactly when the call had no
// arguments at all.  That is the realistic typo and it is one comparison.
//
// The general count - outnum(2), one argument where two are needed - needs a scan
// to the MATCHING paren, and this language has no loop, so it would have to be a
// hand-unrolled ladder.  Left for later rather than guessed at.
mod noteArity(name: string) {
  if curKind() == 5 && curSub() == 15 {
    if name == "outnum" {
      nameWarn = nameWarn .. "warn: outnum() takes an index and a value, i in 1..5, and was given none\n"
    }
    if name == "outstr" {
      nameWarn = nameWarn .. "warn: outstr() takes an index and a value, i in 1..2, and was given none\n"
    }
    if name == "outarr" {
      nameWarn = nameWarn .. "warn: outarr() takes an index and at least one value, and was given none\n"
    }
    if name == "innumarr" {
      nameWarn = nameWarn .. "warn: innumarr() takes an index from 1, and was given none\n"
    }
    if name == "instrarr" {
      nameWarn = nameWarn .. "warn: instrarr() takes an index from 1, and was given none\n"
    }
  }
}

mod noteIndex(name: string) {
  if curKind() == 1 {
    let v = curNum()
    if name == "outnum" && !(1.0 <= v && v <= 5.0) {
      nameWarn = nameWarn .. "warn: outnum index must be 1..5, and this call is out of range\n"
    }
    if name == "outstr" && !(1.0 <= v && v <= 2.0) {
      nameWarn = nameWarn .. "warn: outstr index must be 1..2, and this call is out of range\n"
    }
    // outArr raises on a bad index.  innumarr is bounded by the same length but
    // substitutes nil and carries on, and saying THAT is worth having - a silent
    // nil is the worse failure - but it is NOT here, and the reason is worth more
    // than the check: reading an input PORT during codegen empties every program,
    // including ones that never mention innumarr, because all of noteIndex is inlined
    // into exprPushName so the read is in the graph whether or not the branch is
    // taken.  outArrV.length() is safe because that is a chip-side array var.  The
    // width has to come from a constant, and no such constant exists yet.
    if name == "outarr" {
      if v != floor(v) || v < 1.0 || v > ARR_SLOTS {
        nameWarn = nameWarn
          .. "warn: array index out of range, and outarr is 1-based over the outArr slots\n"
      }
    }
    // Same bound, different consequence: a bad innumarr index substitutes nil and the
    // program carries on, so there is no crash - which is exactly why it is worth
    // saying, because a silent nil is the worse of the two failures.  PUC agrees
    // (t[65] over 64 slots is nil), so this is advice and not a divergence.
    if name == "innumarr" {
      if v != floor(v) || v < 1.0 || v > ARR_SLOTS {
        nameWarn = nameWarn
          .. "warn: innumarr reads past the end of inNumArr and gives nil, silently, as in PUC\n"
      }
    }
    // instrarr's bound and its consequence are innumarr's, and they are the same
    // ARR_SLOTS const: the host sizes both array ports alike, and reading either
    // port while parsing is what emptied every program's log (see above).
    if name == "instrarr" {
      if v != floor(v) || v < 1.0 || v > ARR_SLOTS {
        nameWarn = nameWarn
          .. "warn: instrarr reads past the end of inStrArr and gives nil, silently, as in PUC\n"
      }
    }
  }
}

mod noteUnknown(name: string) {
  if !srcUses(lsrc, name .. " =") && !srcUses(lsrc, name .. "=")
    && !srcUses(nameWarn, name) {
    nameWarn = nameWarn .. "warn: '" .. name
      .. "' is not a port or a builtin, and the program never assigns it, so it reads as nil"
      .. "\n"
  }
}

mod gLookup(name: string) -> int {
  let r = gmap.get(name)
  return if r.Found then r.Value else -1
}

mod gRef(name: string) -> int {
  if gLookup(name) < 0 {
    noteUnknown(name)
  }
  return gDeclare(name)
}

// ---------------------------------------------------------------- registers + scope

mod regAlloc() -> int {
  let r = cfNext[fnDepth]
  if r >= MAX_REGS {
    perr = true
    perrMsg = "too many registers"
  }
  cfNext[fnDepth] = r + 1
  if r + 1 > cfMax[fnDepth] {
    cfMax[fnDepth] = r + 1
  }
  return r
}

mod regFree(r: int) {
  if r > cfMaxLoc[fnDepth] && r == cfNext[fnDepth] - 1 {
    cfNext[fnDepth] = r
  }
}

mod dirtySelf(name: string) {
  if selfName[fnDepth] == name {
    selfClean[fnDepth] = false
  }
}

mod locBind(name: string, r: int) {
  if locLen < locName.length() {
    locName[locLen] = name
    locReg[locLen] = r
    locDepth[locLen] = fnDepth
    locCap[locLen] = false
    locInLoop[locLen] = 0 < loopNesting
  } else {
    locName.push(name)
    locReg.push(r)
    locDepth.push(fnDepth)
    locCap.push(false)
    locInLoop.push(0 < loopNesting)
  }
  locLen = locLen + 1
  if r > cfMaxLoc[fnDepth] {
    cfMaxLoc[fnDepth] = r
  }
}

mod blkEnter(isLoopBody: bool) {
  blkLen.push(locLen)
  blkNext.push(cfNext[fnDepth])
  blkCapGen.push(capGen)
  // the count as it was BEFORE this block, because blkExit has to put it back
  // exactly where it found it: a local declared after a loop is not in one, and
  // pushing the post-increment value left the count stuck at 1 for the rest of
  // the function
  blkLoop.push(loopNesting)
  if isLoopBody {
    loopNesting = loopNesting + 1
  }
}

mod regSync() {
  let top = cfBase[fnDepth]
  let m = cfMaxLoc[fnDepth] + 1
  if m > top {
    cfNext[fnDepth] = m
  } else {
    cfNext[fnDepth] = top
  }
}

// The descriptor this function already has for one of its own locals, or -1.
// A local that something captured is read and written through the cell from
// then on: the cell is the value closures see, so a write from a nested
// function has to be visible here without going through the register.
mod upSelf(ix: int) -> int {
  let r = upIdx.get(fidAt[fnDepth] .. "#" .. ix)
  return if r.Found then r.Value else -1
}

// One link of a capture chain: the prototype at compile depth d gets a
// descriptor for local entry ix, or finds the one it already has -- two
// closures over one local must share its cell.  src >= 0 is the local's
// register in that frame; src < 0 is -(1 + the same local's index in d's own
// upvalues).  Keyed on the local *entry* and not the name because a function
// can capture its own x and an enclosing x in one body, and those are two
// different cells with one name.
mod upStep(d: int, ix: int, src: int) -> int {
  let p = fidAt[d]
  let key = p .. "#" .. ix
  let r = upIdx.get(key)
  if r.Found {
    return r.Value
  }
  let k = fUpN[p]
  if MAX_UP <= k {
    perr = true
    perrMsg = "too many upvalues"
    return 0
  }
  fUpN[p] = k + 1
  fUpSrc[p * MAX_UP + k] = src
  if 0 <= src {
    fUpSlot[p * MAX_UP + k] = fUpSlotN[p]
    fUpSlotN[p] = fUpSlotN[p] + 1
    // taken from the DECLARING local, not from the block this capture is written
    // in: the same loop body can capture a local of the function above it, and
    // that one's cell outlives the loop
    fUpInLoop[p * MAX_UP + k] = locInLoop[ix]
    // the declaring function's own reads and writes go through this cell from
    // here on, so a write from a nested function is visible to it
    locCap[ix] = true
  }
  upIdx.set(key, k)
  return k
}

mod pushOp(kind: int, prec: int, a: int, b: int, c: int) {
  opKind.push(kind)
  opPrec.push(prec)
  opA.push(a)
  opB.push(b)
  opC.push(c)
}

mod opTopKind() -> int {
  return if opKind.length() == 0 then -1 else opKind[opKind.length() - 1]
}

mod popIsLeft(k: int) -> bool {
  return if k == 0 then (opB[opB.length() - 1] & 1) == 1
    else if k == 1 then false
    else true
}

mod nextKind() -> int {
  return if cpos + 1 >= tk.length() then 6 else tk[cpos + 1]
}

mod nextSub() -> int {
  return if cpos + 1 >= tk.length() then 0 else ts[cpos + 1]
}

// Apply one pending operator pop. Only binop/unary/and/or frames pop;
// call and group markers stop all pops.
mod curStrAhead() -> string {
  return if cpos + 1 >= tk.length() then "" else tt[cpos + 1]
}

// and/or arrival: pops drain first, then the frame goes up with its jump.
mod andOrArrive(isOr: bool) {
  pendKind = if isOr then 5 else 4
  pendPrec = if isOr then 0 else 1
  pendSub = 0
  pendAux = 0
  popMode = 1
  popPrec = if isOr then 0 else 1
}

// ---------------------------------------------------------------- codegen helpers

// GETUP's c operand: 0 reads this frame's own cell for the local, 1 reads the
// enclosing closure's cell.  Which one is a property of the descriptor, so it
// is settled here rather than in the VM.
mod upKind() -> int {
  let src = fUpSrc[fidAt[fnDepth] * MAX_UP + lkReg]
  return if 0 <= src then 0 else 1
}

// A function body runs its own statements, which reuse the statement-level
// scratch arrays.  Park the outer statement's copy of them, or the body's first
// `local` wipes the names the outer one still has to assign (the assignment then
// silently vanished, taking `local f = function() local x ... end` with it).
mod saveTmp() {
  svC.push(tmpRegs.length())
  svC.push(itBase.length())
  svC.push(itKey.length())
  svC.push(tmpNames.length())
  svC.push(tmpA)
  svI.append(tmpRegs)
  svI.append(itBase)
  svI.append(itKey)
  svS.append(tmpNames)
  tmpRegs.clear()
  itBase.clear()
  itKey.clear()
  tmpNames.clear()
}

mod restoreTmp() {
  tmpA = svC.pop().Value
  let nN = svC.pop().Value
  let nK = svC.pop().Value
  let nB = svC.pop().Value
  let nR = svC.pop().Value
  tmpNames.slice(svS, svS.length() - nN, nN)
  svS.resize(svS.length() - nN, "")
  itKey.slice(svI, svI.length() - nK, nK)
  svI.resize(svI.length() - nK, 0)
  itBase.slice(svI, svI.length() - nB, nB)
  svI.resize(svI.length() - nB, 0)
  tmpRegs.slice(svI, svI.length() - nR, nR)
  svI.resize(svI.length() - nR, 0)
}

mod newFunc() -> int {
  fStart.push(-1)
  fParams.push(0)
  fRegs.push(-1)
  fVar.push(false)
  fUpN.push(0)
  fUpSlotN.push(0)
  let bad = fStart.length() > MAX_FUNCS
  if bad {
    perr = true
    perrMsg = "too many functions"
  }
  return if bad then 0 else fStart.length() - 1
}

mod funcDepthInit(islocal: bool) {
  cfNext[fnDepth] = 0
  cfMax[fnDepth] = 0
  cfBase[fnDepth] = 0
  cfMaxLoc[fnDepth] = -1
  selfClean[fnDepth] = true
  selfFid[fnDepth] = -1
  fnVar[fnDepth] = false
  if islocal {
    selfName[fnDepth] = tmpS
    selfFid[fnDepth] = tmpB
  } else {
    selfName[fnDepth] = ""
  }
  funcEntryLoc[fnDepth] = locLen
  fnSelfArg[fnDepth] = false
  fidAt[fnDepth] = tmpB
}

// Shared function head: fid already created in tmpB, name in tmpS.
// islocal: self-recursion enabled. resume: 0 statement, 1 expression.
mod pushCtl(kind: int, a: int, b: int, c: int, d: int, e: int, f: int) {
  ctlKind.push(kind)
  ctlA.push(a)
  ctlB.push(b)
  ctlC.push(c)
  ctlD.push(d)
  ctlE.push(e)
  ctlF.push(f)
  ctlG.push(0)
}

mod popCtl() {
  ctlKind.pop()
  ctlA.pop()
  ctlB.pop()
  ctlC.pop()
  ctlD.pop()
  ctlE.pop()
  ctlF.pop()
  ctlG.pop()
}

mod ctlTop() -> int {
  return if ctlKind.length() == 0 then -1 else ctlKind[ctlKind.length() - 1]
}

// Append a patch position to a control frame's patch list (kept in B/C).
mod lstAppendB(pos: int) {
  plNext[pos] = ctlB[ctlB.length() - 1]
  ctlB[ctlB.length() - 1] = pos
}

// Start an expression unit ending in the given continuation.
mod startUnit(cont: int) {
  inExpr = true
  contKind = cont
  expectOperand = true
  exprDone = false
}

// The prototype the running frame is executing, and the closure number it is
// running as.  The main chunk is the one frame not on the stack (an empty
// fFunc is how it halts), so it answers for itself.
mod curFid() -> int {
  if fFunc.length() == 0 {
    return mainFid
  }
  let cid = fFunc[fFunc.length() - 1]
  if cid < cloBase {
    return cid
  }
  return cloF[cid]
}

mod curClo() -> int {
  if fFunc.length() == 0 {
    return mainFid
  }
  return fFunc[fFunc.length() - 1]
}

mod vNum(r: int) -> float {
  return vnum[vmBase + r]
}

mod vStr(r: int) -> string {
  return vstr[vmBase + r]
}

// Move a call's results across the frame boundary: copy k values from the
// callee's frame (absolute src) into the caller's (absolute dst), then nil-fill
// up to n so a fixed-arity caller sees nil for values the callee did not return.
// k values are the ones actually produced; n is what the caller asked for.
mod retAdjust(src: int, dst: int, k: int, n: int) {
  if 1 <= k { vtag[dst] = vtag[src] vnum[dst] = vnum[src] vstr[dst] = vstr[src] } else if 1 <= n { vtag[dst] = 0 vnum[dst] = 0.0 vstr[dst] = "" }
  if 2 <= k { vtag[dst+1] = vtag[src+1] vnum[dst+1] = vnum[src+1] vstr[dst+1] = vstr[src+1] } else if 2 <= n { vtag[dst+1] = 0 vnum[dst+1] = 0.0 vstr[dst+1] = "" }
  if 3 <= k { vtag[dst+2] = vtag[src+2] vnum[dst+2] = vnum[src+2] vstr[dst+2] = vstr[src+2] } else if 3 <= n { vtag[dst+2] = 0 vnum[dst+2] = 0.0 vstr[dst+2] = "" }
  if 4 <= k { vtag[dst+3] = vtag[src+3] vnum[dst+3] = vnum[src+3] vstr[dst+3] = vstr[src+3] } else if 4 <= n { vtag[dst+3] = 0 vnum[dst+3] = 0.0 vstr[dst+3] = "" }
  if 5 <= k { vtag[dst+4] = vtag[src+4] vnum[dst+4] = vnum[src+4] vstr[dst+4] = vstr[src+4] } else if 5 <= n { vtag[dst+4] = 0 vnum[dst+4] = 0.0 vstr[dst+4] = "" }
  if 6 <= k { vtag[dst+5] = vtag[src+5] vnum[dst+5] = vnum[src+5] vstr[dst+5] = vstr[src+5] } else if 6 <= n { vtag[dst+5] = 0 vnum[dst+5] = 0.0 vstr[dst+5] = "" }
  if 7 <= k { vtag[dst+6] = vtag[src+6] vnum[dst+6] = vnum[src+6] vstr[dst+6] = vstr[src+6] } else if 7 <= n { vtag[dst+6] = 0 vnum[dst+6] = 0.0 vstr[dst+6] = "" }
  if 8 <= k { vtag[dst+7] = vtag[src+7] vnum[dst+7] = vnum[src+7] vstr[dst+7] = vstr[src+7] } else if 8 <= n { vtag[dst+7] = 0 vnum[dst+7] = 0.0 vstr[dst+7] = "" }
  if 9 <= k { vtag[dst+8] = vtag[src+8] vnum[dst+8] = vnum[src+8] vstr[dst+8] = vstr[src+8] } else if 9 <= n { vtag[dst+8] = 0 vnum[dst+8] = 0.0 vstr[dst+8] = "" }
  if 10 <= k { vtag[dst+9] = vtag[src+9] vnum[dst+9] = vnum[src+9] vstr[dst+9] = vstr[src+9] } else if 10 <= n { vtag[dst+9] = 0 vnum[dst+9] = 0.0 vstr[dst+9] = "" }
  if 11 <= k { vtag[dst+10] = vtag[src+10] vnum[dst+10] = vnum[src+10] vstr[dst+10] = vstr[src+10] } else if 11 <= n { vtag[dst+10] = 0 vnum[dst+10] = 0.0 vstr[dst+10] = "" }
  if 12 <= k { vtag[dst+11] = vtag[src+11] vnum[dst+11] = vnum[src+11] vstr[dst+11] = vstr[src+11] } else if 12 <= n { vtag[dst+11] = 0 vnum[dst+11] = 0.0 vstr[dst+11] = "" }
  if 13 <= k { vtag[dst+12] = vtag[src+12] vnum[dst+12] = vnum[src+12] vstr[dst+12] = vstr[src+12] } else if 13 <= n { vtag[dst+12] = 0 vnum[dst+12] = 0.0 vstr[dst+12] = "" }
  if 14 <= k { vtag[dst+13] = vtag[src+13] vnum[dst+13] = vnum[src+13] vstr[dst+13] = vstr[src+13] } else if 14 <= n { vtag[dst+13] = 0 vnum[dst+13] = 0.0 vstr[dst+13] = "" }
  if 15 <= k { vtag[dst+14] = vtag[src+14] vnum[dst+14] = vnum[src+14] vstr[dst+14] = vstr[src+14] } else if 15 <= n { vtag[dst+14] = 0 vnum[dst+14] = 0.0 vstr[dst+14] = "" }
  if 16 <= k { vtag[dst+15] = vtag[src+15] vnum[dst+15] = vnum[src+15] vstr[dst+15] = vstr[src+15] } else if 16 <= n { vtag[dst+15] = 0 vnum[dst+15] = 0.0 vstr[dst+15] = "" }
}

mod retCopy(src: int, dst: int, n: int) {
  if 1 <= n { vtag[dst] = vtag[src] vnum[dst] = vnum[src] vstr[dst] = vstr[src] }
  if 2 <= n { vtag[dst+1] = vtag[src+1] vnum[dst+1] = vnum[src+1] vstr[dst+1] = vstr[src+1] }
  if 3 <= n { vtag[dst+2] = vtag[src+2] vnum[dst+2] = vnum[src+2] vstr[dst+2] = vstr[src+2] }
  if 4 <= n { vtag[dst+3] = vtag[src+3] vnum[dst+3] = vnum[src+3] vstr[dst+3] = vstr[src+3] }
  if 5 <= n { vtag[dst+4] = vtag[src+4] vnum[dst+4] = vnum[src+4] vstr[dst+4] = vstr[src+4] }
  if 6 <= n { vtag[dst+5] = vtag[src+5] vnum[dst+5] = vnum[src+5] vstr[dst+5] = vstr[src+5] }
  if 7 <= n { vtag[dst+6] = vtag[src+6] vnum[dst+6] = vnum[src+6] vstr[dst+6] = vstr[src+6] }
  if 8 <= n { vtag[dst+7] = vtag[src+7] vnum[dst+7] = vnum[src+7] vstr[dst+7] = vstr[src+7] }
  if 9 <= n { vtag[dst+8] = vtag[src+8] vnum[dst+8] = vnum[src+8] vstr[dst+8] = vstr[src+8] }
  if 10 <= n { vtag[dst+9] = vtag[src+9] vnum[dst+9] = vnum[src+9] vstr[dst+9] = vstr[src+9] }
  if 11 <= n { vtag[dst+10] = vtag[src+10] vnum[dst+10] = vnum[src+10] vstr[dst+10] = vstr[src+10] }
  if 12 <= n { vtag[dst+11] = vtag[src+11] vnum[dst+11] = vnum[src+11] vstr[dst+11] = vstr[src+11] }
  if 13 <= n { vtag[dst+12] = vtag[src+12] vnum[dst+12] = vnum[src+12] vstr[dst+12] = vstr[src+12] }
  if 14 <= n { vtag[dst+13] = vtag[src+13] vnum[dst+13] = vnum[src+13] vstr[dst+13] = vstr[src+13] }
  if 15 <= n { vtag[dst+14] = vtag[src+14] vnum[dst+14] = vnum[src+14] vstr[dst+14] = vstr[src+14] }
  if 16 <= n { vtag[dst+15] = vtag[src+15] vnum[dst+15] = vnum[src+15] vstr[dst+15] = vstr[src+15] }
}

mod vSet(r: int, tag: int, num: float, s: string) {
  vtag[vmBase + r] = tag
  vnum[vmBase + r] = num
  vstr[vmBase + r] = s
}

mod vSetNum(r: int, v: float) {
  vtag[vmBase + r] = 1
  vnum[vmBase + r] = v
}

mod gTag(gi: int) -> int {
  return gtag[gi]
}

mod gNum(gi: int) -> float {
  return gnum[gi]
}

mod gStr(gi: int) -> string {
  return gstr[gi]
}

mod gSet(gi: int, tag: int, num: float, s: string) {
  gtag[gi] = tag
  gnum[gi] = num
  gstr[gi] = s
}

// One-time setup when a parsed program starts running: closure numbering, and
// the main chunk's slot table.  The main chunk runs with no frame on the stack
// (an empty fFunc is how it halts), so its vararg base and sequence number are
// seeded here; every other frame gets both when it is entered.
mod vmClosures() {
  let base = fStart.length()
  cloBase = base
  cloTop = base
  frameSeq = 1
  let n = 3 * fUpSlotN[mainFid] + 1
  vaNum[0] = 1.0
  fVaB[0] = n
  vaTop = n
}

mod vmReset() {  tmap.clear()
  tvTag.clear()
  tvNum.clear()
  tvStr.clear()
  tvTag.resize(MAX_HEAP, 0)
  tvNum.resize(MAX_HEAP, 0.0)
  tvStr.resize(MAX_HEAP, "")
  tLen.clear()
  tLen.resize(MAX_TABLES, 0)
  tFree.clear()
  tHeap = 0
  tCount = 4
  tOwner.clear()
  tOwner.resize(MAX_HEAP, -1)
  tKeyTag.clear()
  tKeyTag.resize(MAX_HEAP, 0)
  tKeyNum.clear()
  tKeyNum.resize(MAX_HEAP, 0.0)
  tKeyStr.clear()
  tKeyStr.resize(MAX_HEAP, "")
  tPrev.clear()
  tPrev.resize(MAX_HEAP, -2)
  tNext.clear()
  tNext.resize(MAX_HEAP, -2)
  tFirst.clear()
  tFirst.resize(MAX_TABLES, -1)
  tLast.clear()
  tLast.resize(MAX_TABLES, -1)
  nxActive = false
  lenChase = false
  vtag.clear()
  vnum.clear()
  vstr.clear()
  vtag.resize(2048, 0)
  vnum.resize(2048, 0.0)
  vstr.resize(2048, "")
  forCtrl.resize(16, 0)
  forRem.resize(16, 0.0)
  forDepth = 0
  fFunc.clear()
  fBase.clear()
  fRetA.clear()
  fRetBase.clear()
  fRetPC.clear()
  fRetN.clear()
  fVaB.clear()
  fForDepth.clear()
  vaTag.clear()
  vaNum.clear()
  vaStr.clear()
  vaTag.resize(MAX_VA, 0)
  vaNum.resize(MAX_VA, 0.0)
  vaStr.resize(MAX_VA, "")
  vaTop = 0
  cloF.clear()
  cloF.resize(MAX_FUNCS + MAX_CLO, 0)
  cloU.clear()
  cloU.resize((MAX_FUNCS + MAX_CLO) * MAX_UP, 0)
  uTag.clear()
  uTag.resize(MAX_CELL, 0)
  uNum.clear()
  uNum.resize(MAX_CELL, 0.0)
  uStr.clear()
  uStr.resize(MAX_CELL, "")
  uTop = 1
  frameSeq = 0
  iterGen = 0
  gtag.clear()
  gnum.clear()
  gstr.clear()
  // MAX_GLOBALS and not a literal, because gDeclare refuses past that const: an
  // array smaller than the guard turned "too many globals" into a write past the
  // end of the storage, and stress-instr -- the case that fills the globals table
  // to the documented 96 -- wrote 32 entries past it while staying green.
  gtag.resize(MAX_GLOBALS, 0)
  gnum.resize(MAX_GLOBALS, 0.0)
  gstr.resize(MAX_GLOBALS, "")
  gtag.copyFrom(GTAG_INIT)
  gnum.copyFrom(GNUM_INIT)
  // CopyFrom REPLACES the array, so it leaves gtag and gnum at GTAG_INIT's 34
  // entries and the length has to be set again here.  Dropping this pair as a
  // no-op on a 64-long array left the two at 34, and every read of a global the
  // program never assigned came back out of bounds -- three cases answering 1,
  // false and 1 where PUC says nil, false and nil.
  gtag.resize(MAX_GLOBALS, 0)
  gnum.resize(MAX_GLOBALS, 0.0)
  gnum[slotInLatch + 0] = latchN0
  gnum[slotInLatch + 1] = latchN1
  gnum[slotInLatch + 2] = latchN2
  gnum[slotInLatch + 3] = latchN3
  gstr[slotInLatch + 4] = latchS0
  gstr[slotInLatch + 5] = latchS1
  vmPc = 0
  vmBase = 0
  vmHalted = bop.length() == 0
  vmFailed = false
  retCountV = -1
  cmpActive = false
  logV = ""
  logLen = 0
  logLines.clear()
  fmtDd.clear()
  pcallBad.clear()
  patSl.clear()
  patCapS.clear()
  patCapE.clear()
  patCapP.clear()
  patCapIx.clear()
  patGmS.clear()
  patGmP.clear()
  patGmPos.clear()
  patTid = 0
  patLastTid = 0
  // the text in inStr0 is the program's standard input, and a run starts at its
  // beginning; the cursors are state, so they go with everything else
  rdText = inStr0
  rdPos = 0
  rdBuf = ""
  rdGot = false
  oF0 = 0.0
  oF1 = 0.0
  oF2 = 0.0
  oF3 = 0.0
  oF4 = 0.0
  oS4 = ""
  oS5 = ""
  outArrV.clear()
  outArrV.resize(64, 0.0)
  resultV = ""
  errV = ""
  fFunc.push(mainFid)
  fBase.push(0)
  fRetA.push(-1)
  fRetBase.push(0)
  fRetPC.push(-1)
  fRetN.push(-1)
  fVaB.push(0)
  fForDepth.push(0)
}

mod arithValL(t: int, v: float, s: string) -> float {
  coerceL = 0
  if t == 2 {
    let i = s.ParseInt()
    if i.Success {
      coerceL = 1
      return i
    }
    let p = s.ParseNumber()
    if p.Success {
      coerceL = 2
      return p
    }
    coerceL = 3
  }
  return v
}

mod arithValR(t: int, v: float, s: string) -> float {
  coerceR = 0
  if t == 2 {
    let i = s.ParseInt()
    if i.Success {
      coerceR = 1
      return i
    }
    let p = s.ParseNumber()
    if p.Success {
      coerceR = 2
      return p
    }
    coerceR = 3
  }
  return v
}

mod logDrop(n: int) {
  logV = logV.Substring(n, logLen - n)
  logLen = logLen - n
}

mod intWrap(v: float) -> float {
  var w = v
  if w + INT64_LIMIT < 0.0 {
    w = w + INT64_WRAP
  } else if INT64_LIMIT <= w {
    w = w - INT64_WRAP
  }
  return w
}

mod cmpFinish(v: bool) {
  vtag[cmpDst] = 3
  if v {
    vnum[cmpDst] = 1.0
  } else {
    vnum[cmpDst] = 0.0
  }
  cmpActive = false
  vmPc = vmPc + 1
  if vmPc >= bop.length() {
    vmHalted = true
  }
}

// Does t[idx] hold a VALUE?  Not merely whether the key is in the map: a nil
// assignment leaves a tombstone there (see tblSetKey), so a key can be in the map
// and still read nil, and PUC's # is the first nil minus one.  Answering the map
// question made the border chase walk straight over the tombstones, so a program
// that emptied a table and refilled it got the old length back -- delete 60 keys,
// refill 40, and #t said 60 where PUC says 40.
mod tblHas(tid: int, idx: int) -> bool {
  let r = tmap.get(tkey(tid, 6, idx + 0.0, ""))
  if r.Found {
    return tvTag[r.Value] != 0
  }
  return false
}

// After t[len+1] was filled, keep extending the border while t[len+1] exists.
mod lenStep() {
  if tblHas(lenTid, tLen[lenTid] + 1) {
    tLen[lenTid] = tLen[lenTid] + 1
  } else {
    lenChase = false
  }
}

// next()'s walk: the candidate is a tombstone or a nil value, so skip it and
// look again -- that costs ticks but needs no loop.  Finishing writes key+value
// (or a lone nil) and advances past the call.
mod nxStep() {
  if 0 <= nxSlot && (tvTag[nxSlot] == 0 || tNext[nxSlot] == -2) {
    nxSlot = tNext[nxSlot]
  } else {
    if nxSlot < 0 {
      vtag[nxDst] = 0
      vnum[nxDst] = 0.0
      vstr[nxDst] = ""
      retCountV = 1
    } else {
      let kt = tKeyTag[nxSlot]
      let kn = tKeyNum[nxSlot]
      let ks = tKeyStr[nxSlot]
      if kt == 6 || kt == 1 {
        vtag[nxDst] = kt
        vnum[nxDst] = kn
        vstr[nxDst] = ""
      } else if kt == 2 {
        vtag[nxDst] = 2
        vnum[nxDst] = 0.0
        vstr[nxDst] = ks
      } else if kt == 3 {
        vtag[nxDst] = 3
        vnum[nxDst] = kn
        vstr[nxDst] = ""
      } else if kt == 5 {
        vtag[nxDst] = 5
        vnum[nxDst] = kn
        vstr[nxDst] = ks
      } else {
        vtag[nxDst] = 0
        vnum[nxDst] = 0.0
        vstr[nxDst] = ""
      }
      vtag[nxDst + 1] = tvTag[nxSlot]
      vnum[nxDst + 1] = tvNum[nxSlot]
      vstr[nxDst + 1] = tvStr[nxSlot]
      retCountV = 2
    }
    nxActive = false
    vmPc = nxPc + 1
  }
}

// states: 0 literal, 1 flags, 2 width, 3 precision, 4 conversion, 5 padding,
// 6 finish a conversion, 7 one integer digit, 8 one quoted byte, 9 one
// precision zero
// The character at a 1-based position is read inline at each use rather than
// from a mod: a string returned from a mod compares equal to the right text but
// its ToCharCode() reads 0, so a digit test on it never fires.
mod fmtArgAt() -> int {
  return fmtBase + 1 + fmtArgI
}

// The argument number for an error message.  Concatenating an int prints it as
// a float, so "bad argument #5.0" would come out; the digits are spelled out.
mod fmtArgName() -> string {
  let n = 1 + fmtArgI
  let tens = floor(n / 10.0)
  let ones = n - tens * 10.0
  let a = FromCharCode(48 + tens).Character
  let b = FromCharCode(48 + ones).Character
  return if n < 10 then b else a .. b
}

// The same fetch for the argument %q walks, which is not the spec.  fmtEof is a
// flag rather than an empty fmtCh because %q of a string with a NUL in it must
// escape it, not stop there.
mod fmtQFetch() {
  if fmtQPos < fmtArg.Length() {
    fmtCh = fmtArg.Substring(fmtQPos, 1)
    fmtEof = false
  } else {
    fmtCh = ""
    fmtEof = true
  }
  fmtState = 8
}

mod fmtFlag() {
  if fmtCh == "-" {
    fmtMinus = 1
    fmtSpec = fmtSpec .. fmtCh
    fmtPos = fmtPos + 1
    fmtTo = 1
    fmtState = 10
  } else if fmtCh == "+" {
    fmtPlus = 1
    fmtSpec = fmtSpec .. fmtCh
    fmtPos = fmtPos + 1
    fmtTo = 1
    fmtState = 10
  } else if fmtCh == " " {
    fmtSpace = 1
    fmtSpec = fmtSpec .. fmtCh
    fmtPos = fmtPos + 1
    fmtTo = 1
    fmtState = 10
  } else if fmtCh == "#" {
    fmtHash = 1
    fmtSpec = fmtSpec .. fmtCh
    fmtPos = fmtPos + 1
    fmtTo = 1
    fmtState = 10
  } else if fmtCh == "0" {
    fmtZero = 1
    fmtSpec = fmtSpec .. fmtCh
    fmtPos = fmtPos + 1
    fmtTo = 1
    fmtState = 10
  } else {
    fmtTo = 2
    fmtState = 10
  }
}

mod fmtWidthStep() {
  let cp = if 0 < fmtCh.Length() then fmtCh.ToCharCode().Codepoint else -1
  if 48 <= cp && cp <= 57 {
    fmtWidth = fmtWidth * 10 + (cp - 48)
    fmtSpec = fmtSpec .. fmtCh
    fmtPos = fmtPos + 1
    fmtTo = 2
    fmtState = 10
  } else if fmtCh == "." {
    fmtSpec = fmtSpec .. fmtCh
    fmtPos = fmtPos + 1
    fmtPrec = 0
    fmtTo = 3
    fmtState = 10
  } else {
    fmtTo = 4
    fmtState = 10
  }
}

mod fmtPrecStep() {
  let cp = if 0 < fmtCh.Length() then fmtCh.ToCharCode().Codepoint else -1
  if 48 <= cp && cp <= 57 {
    fmtPrec = fmtPrec * 10 + (cp - 48)
    fmtSpec = fmtSpec .. fmtCh
    fmtPos = fmtPos + 1
    fmtTo = 3
    fmtState = 10
  } else {
    fmtState = 4
  }
}

// Which of the two forms, once the exponent is known: %e when it is below -4 or
// at least the precision, %f otherwise.  Either way the precision the chosen
// form runs at is one lower than %g's, because both forms spend one of the
// digits on a leading zero or a point.
// Which of the two forms, and this is after the rounding on purpose.  The
// exponent C compares against the precision is the one the value has *after*
// being rounded to that many digits, and 9.5 at one digit is 10, so its exponent
// is 1, 1 is at the precision, and %g gives 1e+001 and not 10.  Deciding before
// the rounding, with the exponent the digits had going in, gave 10.
mod fmtGStyle() {
  if fmtK < -4 || fmtG0 <= fmtK {
    fmtGToExp = true
    if fmtStrip {
      fmtState = 36
    } else {
      fmtState = 29
    }
  } else {
    fmtP = fmtG0 - 1 - fmtK
    fmtGToExp = false
    fmtInt = ""
    fmtState = 15
  }
}


// Trailing zeros off the fraction, and the point with them when nothing is left
// after it: 1.2300 is 1.23 and 1.000 is 1.  Not the integer part -- %g of 100 is
// 100, not 1 -- so the zeros stop at the point.
mod fmtGStrip() {
  let n = fmtBody.Length()
  let last = fmtBody.Substring(n - 1, 1)
  let dot = fmtBody.Find(".", true, 0)
  if last == "0" && 0 <= dot && dot < n - 1 {
    fmtBody = fmtBody.Substring(0, n - 1)
  } else {
    if last == "." {
      fmtBody = fmtBody.Substring(0, n - 1)
    }
    fmtPre = ""
    fmtState = if fmtGToExp then 29 else 6
  }
}

// The exponent, and the string the digits are read from.  The first significant
// digit is the integer part's first when there is one -- an integer part has no
// leading zeros -- and otherwise the first nonzero fraction digit, which the
// walk already counted, so nothing here has to scan.
mod fmtEJoin() {
  fmtAll = fmtInt .. fmtFr
  fmtPt = fmtInt.Length()
  if fmtInt == "" {
    fmtS = fmtLz
  } else {
    fmtS = 0
  }
  fmtK = fmtPt - 1 - fmtS
  if fmtLz < 0 {
    fmtLz = fmtS
  }
  fmtMI = 0
  fmtM = 0.0
  // %g reads the same mantissa %e does, at one place fewer, and chooses its form
  // once the rounding has given the exponent it compares against the precision
  fmtState = 24
}

// One digit of the mantissa per state, the character in one and the number in
// the next: a string returned from a mod compares equal to the right text and
// its ToCharCode reads 0, so the code has to travel through a variable and a
// tick.  The cursor counts from the first significant digit, and p+1 of them
// make the mantissa.
mod fmtEFetch() {
  fmtD_ = fmtAll.Substring(fmtS + fmtMI, 1).ToCharCode().Codepoint - 48
  fmtState = 25
}

mod fmtEBuild() {
  fmtM = fmtM * 10.0 + fmtD_
  fmtMI = fmtMI + 1
  if fmtMI <= fmtP {
    fmtState = 24
  } else {
    fmtSI = 0
    fmtState = 32
  }
}

// Whether anything nonzero follows the round digit, one character per state.
// The double-double's leftover is not the whole answer: when the round digit is
// still inside the integer part -- 916506699492 at two places rounds on the 5
// and the 066 behind it are what say it is above the tie -- the walk stopped
// before the fraction and the leftover is zero.  So the digits after the round
// digit are read from the string as well, and either source is enough.
mod fmtESticky() {
  if fmtS + fmtP + 2 + fmtSI < fmtAll.Length() {
    if fmtAll.Substring(fmtS + fmtP + 2 + fmtSI, 1) != "0" {
      fmtSticky = true
      fmtState = 26
    } else {
      fmtSI = fmtSI + 1
    }
  } else {
    fmtState = 26
  }
}

// The round digit is the one after the mantissa, and whether anything nonzero
// follows it decides a tie.  A carry out of the mantissa is 10^p with the
// exponent up by one, which is 9.999e5 becoming 1.000e6.
mod fmtERound() {
  let rd = fmtAll.Substring(fmtS + fmtP + 1, 1).ToCharCode().Codepoint - 48
  let last = fmtM - floor(fmtM / 10.0) * 10.0
  let odd = last - floor(last / 2.0) * 2.0
  let sticky = fmtSticky || fmtDd[0] != 0.0 || fmtDd[1] != 0.0
  if rd > 5 || (rd == 5 && (sticky || odd == 1.0)) {
    fmtM = fmtM + 1.0
    if 10.0 ** (fmtP + 1.0) <= fmtM {
      fmtM = 10.0 ** (fmtP + 0.0)
      fmtK = fmtK + 1
    }
  }
  fmtNz = 0
  // the mantissa's digits go into the same string the fraction's came out in,
  // so it has to be emptied: left alone, %e of 1.5 printed thirteen zeros
  fmtFr = ""
  fmtState = 27
}

// The mantissa, the point and the sign.  The point goes after the leading
// digit, which is what %e and %g's %e arm both want; %g's other arm is the %f
// conversion with a precision of its own, not a different way of spelling this
// one.  # keeps the point even with no places after it, so %#.0e of 1.5 is
// 2.e+000 and not 2e+000.
mod fmtEMantEnd() {
  if fmtNeg {
    fmtBody = "-" .. FromCharCode(48 + fmtLead).Character
  } else if fmtPlus == 1 {
    fmtBody = "+" .. FromCharCode(48 + fmtLead).Character
  } else if fmtSpace == 1 {
    fmtBody = " " .. FromCharCode(48 + fmtLead).Character
  } else {
    fmtBody = FromCharCode(48 + fmtLead).Character
  }
  if 0 < fmtP {
    fmtBody = fmtBody .. "." .. fmtFr
  } else if fmtHash == 1 {
    fmtBody = fmtBody .. "."
  }
  fmtENum = if fmtK < 0 then 0 - fmtK else fmtK
  fmtNz = 0
  if fmtIsG {
    fmtState = 34
  } else {
    fmtState = 29
  }
}

mod fmtEExpEnd() {
  // three digits, whatever the exponent: one is 00, two is 0N.  Two pads, since
  // no double's exponent passes 308, and each pad is its own write so the second
  // sees the first's result.
  if fmtExp.Length() < 3 {
    fmtExp = "0" .. fmtExp
  }
  if fmtExp.Length() < 3 {
    fmtExp = "0" .. fmtExp
  }
  if fmtK < 0 {
    fmtBody = fmtBody .. (if fmtUpperE then "E-" else "e-") .. fmtExp
  } else {
    fmtBody = fmtBody .. (if fmtUpperE then "E+" else "e+") .. fmtExp
  }
  fmtPre = ""
  fmtState = 6
}

// Pad the fraction out to the precision, so %.2f of 0.4 is 0.40 and not 0.4.  The
// zeros come from a constant with a Substring rather than a state: there are at
// most sixteen of them and a state each would cost a tick apiece.
mod fmtFPad() {
  let n = fmtFr.Length()
  if n < fmtP {
    fmtFr = ZEROS16.Substring(0, fmtP - n) .. fmtFr
  }
  fmtState = 18
}

// The point between the two halves, the leading zero, and the sign.  A state of
// its own because the lengths it reads are the ones the pad and the digit loops
// have just written: a value gate fed by a variable the same mod writes reads
// the new one, so doing this with them would splice the strings at the wrong
// offsets.
mod fmtFPoint() {
  if fmtInt == "" {
    fmtInt = "0"
  }
  if 0 < fmtP {
    fmtBody = fmtInt .. "." .. fmtFr
  } else {
    fmtBody = fmtInt
  }
  if fmtNeg {
    fmtBody = "-" .. fmtBody
  } else if fmtPlus == 1 {
    fmtBody = "+" .. fmtBody
  } else if fmtSpace == 1 {
    fmtBody = " " .. fmtBody
  } else if fmtHash == 1 && fmtP == 0 {
    // # keeps the point even with no places, on this arm as on %e's: %#.1g of
    // 1.5 is 2. and not 2
    fmtBody = fmtBody .. "."
  }
  fmtPre = ""
  // %g's %f arm strips its trailing zeros on the way out
  if fmtIsG && fmtStrip {
    fmtState = 36
  } else {
    fmtState = 6
  }
}

// Which flags each conversion takes, as PUC's table has it.  Returns 0 when the
// spec is good, 1 for a flag the conversion does not take, 2 for a %q with any
// modifier at all -- which PUC words differently, and without the spec text.
//   - + space # 0  width  prec
//   d i u           y y y   n y  y     y
//   f e g           y y y   y y  y     y
//   x X o           y n n   y y  y     y
//   c               y n n   n n  y     n
//   s               y n n   n y  y     y
//   q               n n n   n n  n     n
mod fmtSpecBad() -> int {
  if fmtCh == "q" {
    if fmtMinus == 1 || fmtPlus == 1 || fmtSpace == 1 || fmtHash == 1
        || fmtZero == 1 || 0 < fmtWidth || 0 <= fmtPrec {
      return 2
    }
  } else if fmtCh == "c" {
    if fmtHash == 1 || fmtPlus == 1 || fmtSpace == 1 || fmtZero == 1 || 0 <= fmtPrec {
      return 1
    }
  } else if fmtCh == "s" {
    if fmtHash == 1 || fmtPlus == 1 || fmtSpace == 1 {
      return 1
    }
  } else if fmtCh == "x" || fmtCh == "X" || fmtCh == "o" {
    if fmtPlus == 1 || fmtSpace == 1 {
      return 1
    }
  } else if fmtCh == "f" || fmtCh == "e" || fmtCh == "E" || fmtCh == "g"
      || fmtCh == "G" {
    // the three float conversions take every flag, and only the integer ones
    // refuse #: this arm is why %#.0g was an invalid specification
    return 0
  } else if fmtHash == 1 {
    return 1
  }
  return 0
}

// Prepend the digit the state before worked out.  A state of its own because the
// digit and the quotient both come from one var, and a mod that writes that var
// has its own expressions re-evaluated against the new value: with the character
// built in the same state, %d of 42 came out 00, because the digit and the
// quotient were both recomputed after fmtNum_ had become 4.  Nothing here is
// derived from the var this writes.
mod fmtDigitPut() {
  let ch = if fmtBase_ == 16.0 then if fmtUpper then HEXDIG_U.Substring(fmtQ_, 1)
    else HEXDIG.Substring(fmtQ_, 1) else FromCharCode(48 + fmtQ_).Character
  fmtBody = ch .. fmtBody
  fmtState = 7
}

// The top octal digit of a negative value, and the 0x / 0X / 0 prefix the # flag
// asks for.  # adds nothing for a zero, in either base.
mod fmtRadixPrefix() {
  if fmtNeg && fmtCh == "o" {
    fmtBody = "1" .. fmtBody
  }
  if fmtHash == 1 && fmtBody != "" && fmtBody != "0" {
    if fmtCh == "o" {
      fmtBody = "0" .. fmtBody
    } else if fmtUpper {
      fmtBody = "0X" .. fmtBody
    } else {
      fmtBody = "0x" .. fmtBody
    }
  }
}

// Split the sign or 0x prefix off the body, since zero padding goes after it,
// and decide how the width is filled.
mod fmtFinish() {
  let c1 = if 0 < fmtBody.Length() then fmtBody.Substring(0, 1) else ""
  if c1 == "-" || c1 == "+" || c1 == " " {
    fmtPre = c1
    fmtBody = fmtBody.Substring(1, fmtBody.Length() - 1)
  } else {
    fmtPre = ""
  }
  if fmtBody.Length() >= 2 {
    let c2 = fmtBody.Substring(0, 2)
    if c2 == "0x" || c2 == "0X" {
      fmtPre = fmtPre .. c2
      fmtBody = fmtBody.Substring(2, fmtBody.Length() - 2)
    }
  }
  // the - flag wins over the 0 flag: %-06d pads with spaces on the right
  if fmtMinus == 1 {
    fmtPadLeft = true
  } else {
    fmtPadLeft = false
  }
  if fmtZero == 1 {
    fmtPadZero = true
  } else {
    fmtPadZero = false
  }
  if fmtPadLeft {
    fmtPadZero = false
  }
  fmtPadAcc = ""
  fmtPad = fmtWidth - fmtPre.Length() - fmtBody.Length()
  if fmtPad <= 0 {
    fmtOut = fmtOut .. fmtPre .. fmtBody
    // back to the walk through the fetch: fmtCh still holds the conversion
    // character, and entering the literal state directly appended it
    fmtTo = 0
    fmtState = 10
  } else {
    fmtState = 5
  }
}

// One padding character per tick.  Three sides, because the sign goes in a
// different place in each: right-justified spaces go before it (%6d of -42 is
// "   -42"), zero padding after it ("%06d" is "-00042"), and left justification
// after the number.  The side is read at the top level of the mod and each arm
// carries its own end-of-loop test, because a nested condition on a file-level
// var is unreliable in a mod this inlined (see the header).
mod fmtPadStep() {
  fmtPad = fmtPad - 1
  if fmtPadLeft {
    fmtPadAcc = fmtPadAcc .. " "
    if fmtPad <= 0 {
      fmtOut = fmtOut .. fmtPre .. fmtBody .. fmtPadAcc
      fmtTo = 0
      fmtState = 10
    }
  } else if fmtPadZero {
    fmtPadAcc = fmtPadAcc .. "0"
    if fmtPad <= 0 {
      fmtOut = fmtOut .. fmtPre .. fmtPadAcc .. fmtBody
      fmtTo = 0
      fmtState = 10
    }
  } else {
    fmtPadAcc = fmtPadAcc .. " "
    if fmtPad <= 0 {
      fmtOut = fmtOut .. fmtPadAcc .. fmtPre .. fmtBody
      fmtTo = 0
      fmtState = 10
    }
  }
}


// Unlink a slot from its table's insertion chain, and mark it unchained (-2),
// which is what the -2 in the declaration above has always meant.  The mark is
// load-bearing: a slot on the free list is a key that was assigned nil, and it
// stays on the list after the table it died in stops pointing at it, so the
// free list reads -2 to tell "dead and nobody owns it any more" from "dead but
// still chained, unhook it and drop its stale map entry".
mod tblUnlink(tid: int, sl: int) {
  let pv = tPrev[sl]
  let nx = tNext[sl]
  if pv != -1 {
    tNext[pv] = nx
  } else {
    tFirst[tid] = nx
  }
  if nx != -1 {
    tPrev[nx] = pv
  } else {
    tLast[tid] = pv
  }
  tPrev[sl] = -2
  tNext[sl] = -2
}

// A new attempt at patStart: an empty backtrack stack, the pattern back at its
// first item, and no captures.  The captures go with the attempt, not with the
// call: PUC's level is per match() and a second start begins with none, which
// is why "()b" finds its one position capture on the second try and not two.
mod patStartStep() {
  patSp = 0
  patP = patPSkip
  patI = patStart
  patNCap = 0
  patCapN = 0
  patSt = 1
}

// One continuation onto the backtrack stack, or false when it is full.  kind 1
// is a greedy + or * that has taken at least one character: slot 1 is the
// item, slot 2 the subject position the rest would resume from, slot 3 the
// pattern position past the quantifier.  kind 2 is a ?'s matched item, kind 4 a
// lazy - that has taken one.  A kind 1 entry is re-pushed as it is used, one
// position further back, which is what makes the rest of the pattern try the
// longer match first and the shorter ones after it.
mod patPush(kind: int, p: int, s: int, x: int) -> bool {
  if patSp + 4 > PAT_STACK {
    return false
  }
  patSl[patSp] = kind
  patSl[patSp + 1] = p
  patSl[patSp + 2] = s
  patSl[patSp + 3] = x
  patSp = patSp + 4
  return true
}

// %1 to %9: the subject has to carry the same text the capture did, and both
// move on by the capture's length.  A position capture has no text to compare --
// PUC's CAP_POSITION is not a length -- so it never matches, and PUC agrees that
// "()%1" finds nothing.  A capture the pattern has not opened yet, or has not
// closed, is PUC's "invalid capture index".
mod patBackref(p: int, s: int, ci: int) -> int {
  let ce = patCapE[ci]
  let cp = patCapP[ci]
  let cs = patCapS[ci]
  if patNCap < ci || ce == 0 && cp == 0 {
    patErr = "invalid capture index %" .. FromCharCode(48 + ci).Character
    return 3
  }
  if cp == 1 {
    return 0
  }
  // A quantifier on a backreference is PUC's own dead end: max_expand counts one
  // subject character a repetition while the pattern steps over %N, so it never
  // matches -- "aa" with "(a)%1*" finds nothing.
  if p + 2 < patPEnd {
    let q = patPat.Substring(p + 2, 1)
    if q == "*" || q == "+" || q == "-" || q == "?" {
      return 0
    }
  }
  let len = ce - 1 - cs
  if s + len > patLen {
    return 0
  }
  if patSrc.Substring(s, len) != patSrc.Substring(cs, len) {
    return 0
  }
  patItemE = p + 2
  patAdv = len
  return 1
}

// %bxy: the opening delimiter, the closing one, and the subject's balance.  PUC
// does not backtrack this one -- matchbalance counts to the first return to zero
// and either has its match or has not -- so nothing goes on the stack.  Returns
// the state to run next: the scan, or the error.
mod patBS() -> int {
  if patP + 3 >= patPEnd {
    patErr = "malformed pattern (missing arguments to '%b')"
    return 8
  }
  patBOpen = patPat.Substring(patP + 2, 1)
  patBClose = patPat.Substring(patP + 3, 1)
  patQEnd = patP + 4
  patBC = 0
  patBFirst = true
  return 3
}

mod patGreedyEnd() {
  patP = patQEnd
  patSt = 1
}

// %b's walk.  The opening delimiter has to be the character under the cursor --
// PUC's matchbalance compares the subject with the pattern's first delimiter
// before it counts anything -- and then one character per tick, counting up on
// the opening delimiter and down on the closing one until the balance is back
// where it started.  A subject that runs out is a miss, which is all
// matchbalance can answer too.
mod patBStep() {
  if patBFirst {
    patBFirst = false
    if patI < patLen && patSrc.Substring(patI, 1) == patBOpen {
      patBC = 1
      patI = patI + 1
      patSt = 3
    } else {
      patSt = 4
    }
  } else if patI >= patLen {
    patSt = 4
  } else {
    let c = patSrc.Substring(patI, 1)
    if c == patBOpen {
      patBC = patBC + 1
      patI = patI + 1
      patSt = 3
    } else if c == patBClose {
      if patBC == 1 {
        patI = patI + 1
        patP = patQEnd
        patSt = 1
      } else {
        patBC = patBC - 1
        patI = patI + 1
        patSt = 3
      }
    } else {
      patI = patI + 1
      patSt = 3
    }
  }
}

// %f's second test is done: a match is the transition from outside the set to
// inside it, and it consumes nothing.
mod patFCurStep() {
  if !patFPrev && patHit {
    patP = patItemE
    patSt = 1
  } else {
    patSt = 4
  }
}

// A set matched where the greedy quantifier is taking characters: one more,
// and the entry's resume point moves with it.
mod patSetHit() {
  patSl[patSp - 2] = patI
  patI = patI + 1
  patSt = 11
}

// n bytes from the cursor, or whatever is left of them.
mod rdTake(n: int) {
  let avail = rdText.Length() - rdPos
  let k = if n < avail then n else avail
  rdBuf = if k <= 0 then "" else rdText.Substring(rdPos, k)
  rdPos = rdPos + k
  rdGot = rdBuf != ""
}

// One line, as PUC's "*l" gives it: no newline, and a trailing CR is not part of
// the line.  rdGot is false at the end of the text, so io.lines terminates --
// and a blank line in the middle is a line, not the end.
mod rdLine() {
  let nl = rdText.Find("\n", true, rdPos)
  if rdPos >= rdText.Length() {
    rdGot = false
    rdBuf = ""
  } else if nl < 0 {
    rdBuf = rdText.Substring(rdPos, rdText.Length() - rdPos)
    rdPos = rdText.Length()
    rdGot = true
  } else {
    rdBuf = rdText.Substring(rdPos, nl - rdPos)
    if rdBuf.Length() > 0 {
      if rdBuf.Substring(rdBuf.Length() - 1, 1) == "\r" {
        rdBuf = rdBuf.Substring(0, rdBuf.Length() - 1)
      }
    }
    rdPos = nl + 1
    rdGot = true
  }
}

// Put a slot between two chain entries, which is the whole of what an insertion
// chain is; pv == -1 means the head and nx == -1 the tail.  tblLink is the
// append-at-the-tail case, and a revived key is the replace-in-place case.
mod tblSplice(tid: int, sl: int, pv: int, nx: int) {
  tPrev[sl] = pv
  tNext[sl] = nx
  if pv != -1 {
    tNext[pv] = sl
  } else {
    tFirst[tid] = sl
  }
  if nx != -1 {
    tPrev[nx] = sl
  } else {
    tLast[tid] = sl
  }
}

// Link a slot at the tail of its table's chain, so pairs/next walk entries in
// insertion order (the order PUC-Lua uses, which the tests compare against).
mod tblLink(tid: int, sl: int) {
  tblSplice(tid, sl, tLast[tid], -1)
}

// Copy up to MAXVALS values from the register file into the vararg stack.
mod vaSpill(src: int, dst: int, n: int) {
  if 1 <= n { vaTag[dst] = vtag[src] vaNum[dst] = vnum[src] vaStr[dst] = vstr[src] }
  if 2 <= n { vaTag[dst+1] = vtag[src+1] vaNum[dst+1] = vnum[src+1] vaStr[dst+1] = vstr[src+1] }
  if 3 <= n { vaTag[dst+2] = vtag[src+2] vaNum[dst+2] = vnum[src+2] vaStr[dst+2] = vstr[src+2] }
  if 4 <= n { vaTag[dst+3] = vtag[src+3] vaNum[dst+3] = vnum[src+3] vaStr[dst+3] = vstr[src+3] }
  if 5 <= n { vaTag[dst+4] = vtag[src+4] vaNum[dst+4] = vnum[src+4] vaStr[dst+4] = vstr[src+4] }
  if 6 <= n { vaTag[dst+5] = vtag[src+5] vaNum[dst+5] = vnum[src+5] vaStr[dst+5] = vstr[src+5] }
  if 7 <= n { vaTag[dst+6] = vtag[src+6] vaNum[dst+6] = vnum[src+6] vaStr[dst+6] = vstr[src+6] }
  if 8 <= n { vaTag[dst+7] = vtag[src+7] vaNum[dst+7] = vnum[src+7] vaStr[dst+7] = vstr[src+7] }
  if 9 <= n { vaTag[dst+8] = vtag[src+8] vaNum[dst+8] = vnum[src+8] vaStr[dst+8] = vstr[src+8] }
  if 10 <= n { vaTag[dst+9] = vtag[src+9] vaNum[dst+9] = vnum[src+9] vaStr[dst+9] = vstr[src+9] }
  if 11 <= n { vaTag[dst+10] = vtag[src+10] vaNum[dst+10] = vnum[src+10] vaStr[dst+10] = vstr[src+10] }
  if 12 <= n { vaTag[dst+11] = vtag[src+11] vaNum[dst+11] = vnum[src+11] vaStr[dst+11] = vstr[src+11] }
  if 13 <= n { vaTag[dst+12] = vtag[src+12] vaNum[dst+12] = vnum[src+12] vaStr[dst+12] = vstr[src+12] }
  if 14 <= n { vaTag[dst+13] = vtag[src+13] vaNum[dst+13] = vnum[src+13] vaStr[dst+13] = vstr[src+13] }
  if 15 <= n { vaTag[dst+14] = vtag[src+14] vaNum[dst+14] = vnum[src+14] vaStr[dst+14] = vstr[src+14] }
  if 16 <= n { vaTag[dst+15] = vtag[src+15] vaNum[dst+15] = vnum[src+15] vaStr[dst+15] = vstr[src+15] }
}

// Copy up to MAXVALS values from the vararg stack into registers (VARARG).
mod vaFill(base: int, dst: int, n: int) {
  if 1 <= n { vtag[dst] = vaTag[base] vnum[dst] = vaNum[base] vstr[dst] = vaStr[base] }
  if 2 <= n { vtag[dst+1] = vaTag[base+1] vnum[dst+1] = vaNum[base+1] vstr[dst+1] = vaStr[base+1] }
  if 3 <= n { vtag[dst+2] = vaTag[base+2] vnum[dst+2] = vaNum[base+2] vstr[dst+2] = vaStr[base+2] }
  if 4 <= n { vtag[dst+3] = vaTag[base+3] vnum[dst+3] = vaNum[base+3] vstr[dst+3] = vaStr[base+3] }
  if 5 <= n { vtag[dst+4] = vaTag[base+4] vnum[dst+4] = vaNum[base+4] vstr[dst+4] = vaStr[base+4] }
  if 6 <= n { vtag[dst+5] = vaTag[base+5] vnum[dst+5] = vaNum[base+5] vstr[dst+5] = vaStr[base+5] }
  if 7 <= n { vtag[dst+6] = vaTag[base+6] vnum[dst+6] = vaNum[base+6] vstr[dst+6] = vaStr[base+6] }
  if 8 <= n { vtag[dst+7] = vaTag[base+7] vnum[dst+7] = vaNum[base+7] vstr[dst+7] = vaStr[base+7] }
  if 9 <= n { vtag[dst+8] = vaTag[base+8] vnum[dst+8] = vaNum[base+8] vstr[dst+8] = vaStr[base+8] }
  if 10 <= n { vtag[dst+9] = vaTag[base+9] vnum[dst+9] = vaNum[base+9] vstr[dst+9] = vaStr[base+9] }
  if 11 <= n { vtag[dst+10] = vaTag[base+10] vnum[dst+10] = vaNum[base+10] vstr[dst+10] = vaStr[base+10] }
  if 12 <= n { vtag[dst+11] = vaTag[base+11] vnum[dst+11] = vaNum[base+11] vstr[dst+11] = vaStr[base+11] }
  if 13 <= n { vtag[dst+12] = vaTag[base+12] vnum[dst+12] = vaNum[base+12] vstr[dst+12] = vaStr[base+12] }
  if 14 <= n { vtag[dst+13] = vaTag[base+13] vnum[dst+13] = vaNum[base+13] vstr[dst+13] = vaStr[base+13] }
  if 15 <= n { vtag[dst+14] = vaTag[base+14] vnum[dst+14] = vaNum[base+14] vstr[dst+14] = vaStr[base+14] }
  if 16 <= n { vtag[dst+15] = vaTag[base+15] vnum[dst+15] = vaNum[base+15] vstr[dst+15] = vaStr[base+15] }
}

mod fmtVal(tag: int, num: float, s: string) -> string {
  return if tag == 0 then "nil"
    else if tag == 3 then if num == 0.0 then "false" else "true"
    else if tag == 2 then s
    else if tag == 4 then "function"
    else if tag == 5 then "table: 0x" .. (num | 0)
    else if tag == 6 then "" .. (num | 0)
    else fmtNum(num)
}

// The mantissa's trailing p digits, least significant first as everywhere else,
// then the point and the leading digit in the state after.
mod fmtEMant() {
  if fmtNz < fmtP {
    let q = floor(fmtM / 10.0)
    let d = toInt(fmtM - q * 10.0)
    let ch = FromCharCode(48 + d).Character
    fmtFr = ch .. fmtFr
    fmtM = q
    fmtNz = fmtNz + 1
  } else {
    fmtLead = toInt(fmtM)
    fmtState = 28
  }
}

// The exponent, three digits with a sign.  Three, not C's two: PUC 5.5 formats
// the floats itself rather than through the platform's printf, and measures
// %.3e of zero at ten characters, which is 0.000e+000.  Every double's exponent
// fits in three digits -- the largest is 308 -- so the width is fixed and there
// is no loop for it.
// The exponent's digits, one per state, most significant first.  Each arm says
// where to go before it does its work: a state write after a mod call in the
// deepest arm of a chain this deep is dropped, and the walk then wrote its zero
// over and over -- an exponent of zero came out as e+00000.  Two at a time
// would be fewer states, but FromCharCode(48 + d) is one character, so an
// exponent past 99 came out as e-1< and e-2w.
mod fmtEExpDig() {
  if fmtENum >= 10 {
    fmtState = 29
    let q = floor(fmtENum / 10.0)
    let ch = FromCharCode(48 + toInt(fmtENum - q * 10.0)).Character
    fmtExp = ch .. fmtExp
    fmtENum = q
  } else {
    fmtState = 30
    let ch1 = FromCharCode(48 + fmtENum).Character
    fmtExp = ch1 .. fmtExp
  }
}

// One fraction digit per tick, least significant first, as %d does.
mod fmtFFDigits() {
  if fmtF < 1.0 {
    fmtState = 20
  } else {
    let q = floor(fmtF / 10.0)
    let d = toInt(fmtF - q * 10.0)
    fmtFr = FromCharCode(48 + d).Character .. fmtFr
    fmtF = q
  }
}

// One integer digit per tick.  The integer part of a double below 2^53 is exact
// and each division by ten is exact too -- the quotient is at least 0.1 away
// from a whole number, which is far more than the division's own rounding -- so
// these are the value's digits and not approximations of them.  fmtNxt says
// where to go when they run out: %f pads the fraction next, %e walks the
// fraction's.  It cannot be a parameter, because a mod cannot write one to a
// var -- four placeholders and a refusal to lower.
mod fmtFNDigits() {
  if fmtIP < 1.0 {
    fmtState = fmtNxt
  } else {
    let q = floor(fmtIP / 10.0)
    let d = toInt(fmtIP - q * 10.0)
    fmtInt = FromCharCode(48 + d).Character .. fmtInt
    fmtIP = q
  }
}

// One pass through a set's text: a literal character, a %class, a range, or the
// closing bracket.  The alternatives accumulate in patSetAny and patSetNeg
// flips the answer at the end, so [^a-z] is one rule rather than a special
// case per character.  A '-' with a character before it and one after it is a
// range, which is why a leading or trailing '-' stays a literal.
mod patSetStep() {
  patAdv = 1
  if patSetP >= patPEnd {
    patErr = "malformed pattern (missing ']')"
    patSt = 8
  } else {
    let sc = patPat.Substring(patSetP, 1)
    if sc == "]" {
      if patSetSeen {
        patItemE = patSetP + 1
        patHit = if patSetNeg then !patSetAny else patSetAny
        patSetP = patSetP + 1
        patSt = if patHit then patAfter else patFailTo
      } else {
        patErr = "malformed pattern (missing ']')"
        patSt = 8
      }
    } else if sc == "%" && patSetP + 1 < patPEnd {
      let code = patPat.Substring(patSetP + 1, 1).ToCharCode().Codepoint
      let neg = 65 <= code && code <= 90
      if (97 <= code && code <= 122) || (65 <= code && code <= 90) {
        patSetAny = patSetAny || patClassHit(patSetC, if neg then code + 32 else code, neg)
        patSetSeen = true
        patSetP = patSetP + 2
        patSt = 7
      } else {
        patSetAny = patSetAny || patSetC == code
        patSetSeen = true
        patSetP = patSetP + 2
        patSt = 7
      }
    } else if sc == "-" && patSetHasPrev && patSetP + 1 < patPEnd
        && patPat.Substring(patSetP + 1, 1) != "]" {
      let hi = patPat.Substring(patSetP + 1, 1).ToCharCode().Codepoint
      patSetAny = patSetAny || (patSetPrev <= patSetC && patSetC <= hi)
      patSetSeen = true
      patSetP = patSetP + 2
      patSt = 7
    } else {
      patSetAny = patSetAny || patSetC == sc.ToCharCode().Codepoint
      patSetSeen = true
      patSetHasPrev = true
      patSetPrev = sc.ToCharCode().Codepoint
      patSetP = patSetP + 1
      patSt = 7
    }
  }
}

// Library selection keys on the FIELD name, not on how the program spells it:
// `s:upper()` never writes "string.upper", so matching the dotted form alone
// left the string table unbuilt and the method call nil.  A colon is the
// method-call signal; a match inside a string or comment only costs a piece
// that goes unused.
mod srcUsesField(p: string, name: string) -> bool {
  let dotted = "string." .. name
  let colon = ":" .. name
  return srcUses(p, dotted) || srcUses(p, colon)
}

mod libIter(p: string) -> string {
  return if srcUses(p, "ipairs") || srcUses(p, "pairs") then LIB_iter else ""
}

mod libMathConst(p: string) -> string {
  return if srcUses(p, "math.pi") || srcUses(p, "math.huge")
      || srcUses(p, "math.maxinteger") || srcUses(p, "math.mininteger")
      then LIB_math_const else ""
}

mod libTabIns(p: string) -> string {
  return if srcUses(p, "table.insert") || srcUses(p, "table.remove")
      || srcUses(p, ":insert") || srcUses(p, ":remove")
      then LIB_tab_ins else ""
}

mod libTabList(p: string) -> string {
  return if srcUses(p, "table.unpack") || srcUses(p, "table.pack")
      || srcUses(p, "table.move") then LIB_tab_list else ""
}

mod libTabConcat(p: string) -> string {
  return if srcUses(p, "table.concat") then LIB_tab_concat else ""
}

mod libTabSort(p: string) -> string {
  return if srcUses(p, "table.sort") then LIB_tab_sort else ""
}

mod libIo(p: string) -> string {
  return if srcUses(p, "io.read") || srcUses(p, "io.write")
      || srcUses(p, "io.lines") then LIB_io else ""
}

mod libTonumber(p: string) -> string {
  return if srcUses(p, "tonumber") then LIB_tonumber else ""
}

mod libMathRandom(p: string) -> string {
  return if srcUses(p, "math.random") then LIB_math_random else ""
}

// Register access, two ways, and mixing them is the bug this pair of comments
// exists to stop.  vTag/vNum/vStr/vSet take a register RELATIVE to the current
// frame and add vmBase themselves; anything that already holds an absolute index
// (fmtBase, nxDst, a retAdjust src) reads vtag[]/vnum[]/vstr[] directly.  The
// mistake is invisible at top level, where vmBase is 0, and wrong by exactly
// vmBase inside a function -- which is how the formatter answered "number
// expected, got nil" for `return string.format('%d', 5)`.
mod vTag(r: int) -> int {
  return vtag[vmBase + r]
}

// The one place the log grows, and the one place it shrinks.  logLen travels
// with logV because a cap that computes a substring start from logV.Length() in
// the same mod reads the NEW length -- the value gates are evaluated in a
// fixpoint, not in source order -- so the start lands in the wrong place and the
// log comes out empty.  Nothing writes logV except these two and vmReset.
mod logAdd(s: string) {
  logV = logV .. s
  logLen = logLen + s.Length()
}

// Set up a set scan for the set whose text starts at p, testing the character
// code.  The scan is one character of the set per tick and finishes in
// patSetStep, so this only writes; the caller picks the states it ends in.
mod patSetBegin(p: int, code: int) {
  patSetP = p
  patSetC = code
  patSetAny = false
  patSetSeen = false
  patSetHasPrev = false
  patSetPrev = 0
  patSetNeg = false
  if p < patPEnd && patPat.Substring(p, 1) == "^" {
    patSetNeg = true
    patSetP = p + 1
  }
}

mod emitTok(kind: int, sub: int, num: float, text: string) {
  tk.push(kind)
  ts.push(sub)
  tn.push(num)
  tt.push(text)
  tl.push(lline)
  if tk.length() > MAX_TOKENS {
    lexFail("too many tokens (max " .. (MAX_TOKENS | 0) .. ")")
  }
}

mod emitEscByte(v: int) {
  if v >= 32 && v <= 126 {
    lidBuf = lidBuf .. PRINTABLES.Substring(v - 32, 1)
  } else {
    lexFail("bad escape")
  }
}

mod parseInit() {
  tk.clear()
  ts.clear()
  tn.clear()
  tt.clear()
  tl.clear()
  lerr = false
  lerrMsg = ""
  lerrLine = 1
  lline = 1
  lastPatchTarget = -1
  lastCallPos = -1
  presCallPos = -1
  bop.clear()
  bpa.clear()
  bpb.clear()
  bpc.clear()
  constNum.clear()
  constStr.clear()
  fStart.clear()
  fParams.clear()
  fRegs.clear()
  fVar.clear()
  gmap.clear()
  locName.clear()
  locReg.clear()
  locDepth.clear()
  locCap.clear()
  locInLoop.clear()
  fUpN.clear()
  fUpSlotN.clear()
  valStk.clear()
  valCall.clear()
  valPrefix.clear()
  opKind.clear()
  opPrec.clear()
  opA.clear()
  opB.clear()
  opC.clear()
  forCtrl.clear()
  forRem.clear()
  ctorStk.clear()
  itBase.clear()
  itKey.clear()
  openCtor = 0
  ctlKind.clear()
  ctlA.clear()
  ctlB.clear()
  ctlC.clear()
  ctlD.clear()
  ctlE.clear()
  ctlF.clear()
  ctlG.clear()
  plNext.clear()
  plNext.resize(MAX_INSTR, -1)
  tmpNames.clear()
  tmpRegs.clear()
  svC.clear()
  svI.clear()
  svS.clear()
  forNames.clear()
  tmpSStk.clear()
  blkLen.clear()
  blkNext.clear()
  blkCapGen.clear()
  capGen = 0
  blkLoop.clear()
  loopNesting = 0
  upIdx.clear()
  fUpSrc.clear()
  fUpSrc.resize(MAX_FUNCS * MAX_UP, -1)
  fUpSlot.clear()
  fUpSlot.resize(MAX_FUNCS * MAX_UP, 0)
  fUpInLoop.clear()
  fUpInLoop.resize(MAX_FUNCS * MAX_UP, false)
  fidAt.clear()
  fidAt.resize(33, -1)
  cfNext.clear()
  cfMax.clear()
  cfBase.clear()
  cfMaxLoc.clear()
  selfName.clear()
  selfClean.clear()
  selfFid.clear()
  funcEntryLoc.clear()
  opBase.clear()
  cfNext.resize(33, 0)
  cfMax.resize(33, 0)
  cfBase.resize(33, 0)
  cfMaxLoc.resize(33, -1)
  selfName.resize(33, "")
  selfClean.resize(33, true)
  fnVar.clear()
  fnVar.resize(33, false)
  fnSelfArg.clear()
  fnSelfArg.resize(33, false)
  selfFid.resize(33, -1)
  funcEntryLoc.resize(33, 0)
  opBase.resize(33, 0)
  fnKey.clear()
  gslotNext = 0
  fnDepth = 0
  locLen = 0
  cpos = 0
  perr = false
  perrMsg = ""
  inExpr = false
  contKind = 0
  stState = 0
  tmpA = 0
  tmpB = 0
  tmpC = 0
  tmpS = ""
  forName = ""
  forInit = -1
  forLimit = -1
  forStep = -1
  ctlLoop = -1
  lkRaw = false
  pdHead = -1
  pdThen = 0
  pdTarget = -1
  pDone = false
  expectOperand = true
  popMode = 0
  closeMode = 0
  exprDone = false
  pendKind = -1
  mainFid = 0
  closeTrig = 0
  gDeclare("inNum0")
  gDeclare("inNum1")
  gDeclare("inNum2")
  gDeclare("inNum3")
  gDeclare("inStr0")
  gDeclare("inStr1")
  gDeclare("outnum")
  gDeclare("outstr")
  gDeclare("print")
  gDeclare("type")
  gDeclare("tostring")
  gDeclare("clock")
  gDeclare("innumarr")
  gDeclare("outarr")
  gDeclare("select")
  gDeclare("next")
  gDeclare("_s")
  gDeclare("_m")
  gDeclare("unpack")
  gDeclare("_fmt")
  gDeclare("_rd")
  gDeclare("_wr")
  gDeclare("error")
  gDeclare("assert")
  gDeclare("pcall")
  gDeclare("xpcall")
  gDeclare("_pat")
  gDeclare("_gmatch")
  gDeclare("_gmnext")
  gDeclare("math")
  gDeclare("string")
  gDeclare("table")
  gDeclare("io")
  gDeclare("instrarr")
  // The runtime wires the latches and outputs straight into these slots, so
  // take the numbers from the declarations instead of repeating them: adding a
  // builtin used to leave a stale literal behind and overwrite its id.
  slotInLatch = gLookup("inNum0")
}

// Claim register slots up to n.  Both the frame size and the allocator move:
// code that writes a block of registers outside regAlloc (call argument and
// result windows, an expanded call's copies) must claim them here, or a later
// regAlloc hands out a slot that is still live.
mod bumpMax(n: int) {
  if n > cfMax[fnDepth] {
    cfMax[fnDepth] = n
  }
  if n > cfNext[fnDepth] {
    cfNext[fnDepth] = n
  }
}

mod locDeclare(name: string) -> int {
  let r = regAlloc()
  locBind(name, r)
  return r
}

// A block that contains a capture ends with one GEN: a loop has to give each
// round its own cells, and PUC gets that by closing them at the end of the
// block, so a cell whose stamp is stale is simply replaced when the next
// closure is made.  Emitted here rather than at each loop's back edge because
// blkExit already knows the answer, and a `do` block that captures pays one
// wasted tick -- harmless, since a bump only ever invalidates slots, and a
// closure that outlived the block already holds the cell itself.
mod blkExit() {
  locLen = blkLen.pop().Value
  cfNext[fnDepth] = blkNext.pop().Value
  loopNesting = blkLoop.pop().Value
  let had = blkCapGen.pop().Value != capGen
  if blkGenDone {
    blkGenDone = false
  } else if had {
    bEmit(49, 0, 0, 0)
  }
}

// A local of an enclosing function is used here.  Every function from the one
// that declares it up to this one gets a descriptor for it: the declaring
// function's is instack (the local is in its own frame) and each one above
// that is an upvalue of the closure below it.  So a capture two levels out is
// two descriptors deep -- this function reads the enclosing closure's cell,
// and that closure reads the cell in the frame the local lives in.  The chain
// is a ladder because WireScript has no loop, and four links is the ceiling --
// deeper is a loud error, never a wrong answer.
mod resolveUp(ix: int) {
  let ld = locDepth[ix]
  let hops = fnDepth - ld
  if 4 < hops {
    perr = true
    perrMsg = "too many nested functions to capture through"
  } else {
    let k0 = upStep(ld, ix, locReg[ix])
    var k = k0
    if 1 <= hops && !perr {
      k = upStep(ld + 1, ix, -1 - k0)
    }
    if 2 <= hops && !perr {
      k = upStep(ld + 2, ix, -1 - k)
    }
    if 3 <= hops && !perr {
      k = upStep(ld + 3, ix, -1 - k)
    }
    if 4 <= hops && !perr {
      k = upStep(ld + 4, ix, -1 - k)
    }
    if !perr {
      lkKind = 3
      lkReg = k
      capGen = capGen + 1
    }
  }
}

// One expression token in operand position.
mod applyPop() {
  let k = opTopKind()
  if k == 0 {
    let rr = popVal()
    let ll = popVal()
    let opc = opA[opA.length() - 1]
    let fl = opB[opB.length() - 1]
    opKind.pop()
    opPrec.pop()
    opA.pop()
    opB.pop()
    opC.pop()
    regFree(rr)
    regFree(ll)
    let res = regAlloc()
    let sw = (fl & 2) != 0
    let L = if sw then rr else ll
    let R = if sw then ll else rr
    if (opc == 17 || opc == 18 || opc == 19 || (opc >= 8 && opc <= 13))
       && 0 < bop.length() && bop[bop.length() - 1] == 2
       && bpa[bop.length() - 1] == R && bpa[bop.length() - 1] > cfMaxLoc[fnDepth] {
      let constIx = bpb[bop.length() - 1]
      let intBit = if bpc[bop.length() - 1] == 1 then 1 else 0
      bop.pop()
      bpa.pop()
      bpb.pop()
      bpc.pop()
      if opc >= 17 {
        bEmit(opc, res, L, -1 - constIx)
      } else {
        bEmit(opc, res, L, -1 - 2 * constIx - intBit)
      }
    } else {
      bEmit(opc, res, L, R)
    }
    if (fl & 4) != 0 {
      bEmit(15, res, res, 0)
    }
    pushVal(res, false, false)
  } else if k == 1 {
    let vv = popVal()
    let pendOpA = opA[opA.length() - 1]
    let isNot = pendOpA == 1
    let isLen = pendOpA == 2
    let isBnot = pendOpA == 38
    opKind.pop()
    opPrec.pop()
    opA.pop()
    opB.pop()
    opC.pop()
    regFree(vv)
    let res = regAlloc()
    if isNot {
      bEmit(15, res, vv, 0)
    } else if isLen {
      bEmit(31, res, vv, 0)
    } else if isBnot {
      bEmit(38, res, vv, 0)
    } else {
      bEmit(14, res, vv, 0)
    }
    pushVal(res, false, false)
  } else if k == 4 || k == 5 {
    // `and`/`or` are a branch, not an opcode, so the LEFT operand's register is
    // already on the value stack (pushPending put it there) and the result lands
    // in that same register.  The old code popped the right operand and pushed the
    // result, which left the left operand's entry underneath: the stack went
    // [5 4 1] -> [4 4 1] instead of [5 4 1] -> [4 1].  A call's `)` drains to the
    // depth its `(` recorded and takes ONE value, so the leftover made it read
    // two arguments where there was one, and the enclosing comparison's operands
    // came out as (4, 2) -- the argument and the call -- instead of (2, 1).
    let rr = popVal()
    let R = opA[opA.length() - 1]
    let pp = opB[opB.length() - 1]
    popVal()
    opKind.pop()
    opPrec.pop()
    opA.pop()
    opB.pop()
    opC.pop()
    regFree(rr)
    bEmit(7, R, rr, 0)
    bPatch(pp, bop.length())
    pushVal(R, false, false)
  } else {
    perr = true
    perrMsg = "bad pop"
  }
}

// Push the pending operator frame once precedence pops have drained.
mod pushPending() {
  if pendKind == 0 {
    pushOp(0, pendPrec, pendSub, pendAux, valStk.length())
  } else {
    let ll = popVal()
    let R = regAlloc()
    bEmit(7, R, ll, 0)
    if pendKind == 5 {
      let pp = bEmit(22, 0, R, 0)
      pushOp(5, pendPrec, R, pp, valStk.length() + 1)
    } else {
      let pp = bEmit(21, 0, R, 0)
      pushOp(4, pendPrec, R, pp, valStk.length() + 1)
    }
    pushVal(R, false, false)
  }
  pendKind = -1
}

mod funcHeadAnon(fr: int) {
  let skip = bEmit(20, 0, 0, 0)
  pushCtl(3, tmpB, skip, 1, ctlLoop, fr, contKind)
  ctlG[ctlG.length() - 1] = stState
  tmpSStk.push("")
  ctorStk.push(openCtor)
  openCtor = 0
  ctlLoop = -1
  saveTmp()
  fnDepth = fnDepth + 1
  opBase[fnDepth] = opKind.length()
  funcDepthInit(false)
  if curKind() == 5 && curSub() == 14 {
    cpos = cpos + 1
    stState = 20
    inExpr = false
  } else {
    perr = true
    perrMsg = "expected ( after function"
  }
}

// Post-unit continuations: 1 expr-stmt, 2 if-cond, 3 elif-cond,
// 4 while-cond, 5 return, 6 local-values, 7 assign-values,
// 10 for-init, 11 for-limit, 12 for-step, 13 repeat-until-cond.
mod atStmtEnd() -> bool {
  let k = curKind()
  let s = curSub()
  return if k == 6 then true
    else if k == 5 && s == 17 then true
    else if k == 4 && (s == 6 || s == 4 || s == 5 || s == 21) then true
    else false
}

// ---------------------------------------------------------------- function definitions

mod funcHead(islocal: bool, resume: int, fr: int) {
  let fid = newFunc()
  tmpB = fid
  let skip = bEmit(20, 0, 0, 0)
  if resume == 1 {
    pushCtl(3, fid, skip, 1, ctlLoop, fr, contKind)
  } else if islocal {
    pushCtl(3, fid, skip, 0, ctlLoop, 1, 0)
  } else {
    // fr is 0 for a plain global function, or table-register+1 for `function M.f`
    pushCtl(3, fid, skip, 0, ctlLoop, fr, 0)
  }
  ctlG[ctlG.length() - 1] = stState
  tmpSStk.push(tmpS)
  ctorStk.push(openCtor)
  openCtor = 0
  ctlLoop = -1
  // Every kind-3 frame is closed by one restoreTmp(), so every kind-3 entry has
  // to save.  Only the anonymous head did, which made a `local function` (or a
  // named `function M.f`) inside a function literal pop the *literal's* saved
  // state on its way out and leave the outer close popping an empty stack -- so
  // `t.f = function() local function g() ... end end` lost the field store and
  // read back nil.  The save is per-body state: the values a body pushes on
  // tmpNames/tmpRegs belong to that body and must not leak outwards.
  saveTmp()
  fnDepth = fnDepth + 1
  opBase[fnDepth] = opKind.length()
  funcDepthInit(islocal)
  if curKind() == 5 && curSub() == 14 {
    cpos = cpos + 1
    stState = 20
  } else {
    perr = true
    perrMsg = "expected ( after function name"
  }
}

// stState 10/11: gathering local/assign target names after a comma.
mod stmtNameList(isLocal: bool) {
  if curKind() == 3 {
    tmpNames.push(curStr())
    cpos = cpos + 1
    if curKind() == 5 && curSub() == 16 {
      cpos = cpos + 1
    } else if curKind() == 5 && curSub() == 13 {
      cpos = cpos + 1
      startUnit(if isLocal then 6 else 7)
    } else if isLocal {
      // no values: nil-fill; the next token is validated by dispatch
      tmpA = 0
      stState = 12
    } else {
      perr = true
      perrMsg = "expected , = or end of statement"
    }
  } else {
    perr = true
    perrMsg = "expected name"
  }
}

mod pdDrain() {
  if pdHead == -1 {
    if pdThen == 1 {
      ctlLoop = tmpC
    }
    pdThen = 0
    pdTarget = -1
  } else {
    bPatch(pdHead, if pdTarget == -1 then bop.length() else pdTarget)
    pdHead = plNext[pdHead]
  }
}

// Where this frame's slot table starts, and the sequence number of the frame
// that owns it (the word just below the table).
mod slotBase() -> int {
  return fVaB[fVaB.length() - 1] - 3 * fUpSlotN[curFid()]
}

// The protected call has come back and the marker is on top, so the pcall's
// values are its own: the call's k results move up past the pcall's register,
// `true` goes there, and the pcall's caller carries on with the count it asked
// for.
//
// One mod, and one call site per return variant plus one for a gate, because
// these are mods this size and a test in the middle of one is the trap the
// header warns about.  Every call site passes the same thing -- the results are
// at vmBase + a -- because a frame starts at the very register its results go
// to, so that is where they are in all four return forms and in a gate.
mod pcallEnd(src: int, k: int, extra: int) {
  let ra = fRetA[fRetA.length() - 1]
  let rb = fRetBase[fRetBase.length() - 1]
  let rpc = fRetPC[fRetPC.length() - 1]
  let want = fRetN[fRetN.length() - 1]
  fFunc.pop()
  fBase.pop()
  fRetA.pop()
  fRetBase.pop()
  fRetPC.pop()
  fRetN.pop()
  vaTop = fVaB.pop().Value
  forDepth = fForDepth.pop()
  pcallDepth = pcallDepth - 1
  // The values move up one register, into the space after the call's own, and
  // the call's own register gets true or false: true for the protected call
  // itself (mode 0), false for a message handler's results (modes 1 and 2 --
  // PUC 5.5 returns false plus the handler's results, measured not assumed).
  // A handler contributes one value even when it returns more: a handler
  // returning 7, 8 gives false 7 and not false 7 8.  Copying up cannot overwrite
  // anything, which copying down would.
  var m = 1
  if pcallMode == 0 {
    retCopy(src, rb + ra + 1, k)
    vtag[rb + ra] = 3
    vnum[rb + ra] = 1.0
    vstr[rb + ra] = "true"
    m = (if 1 <= k then k else 0) + extra + 1
  } else {
    let one = rb + ra + 1
    if 1 <= k {
      vtag[one] = vtag[src]
      vnum[one] = vnum[src]
      vstr[one] = vstr[src]
    } else {
      vtag[one] = 2
      vnum[one] = 0.0
      vstr[one] = "<no error object>"
    }
    vtag[rb + ra] = 3
    vnum[rb + ra] = 0.0
    vstr[rb + ra] = "false"
    m = 2
  }
  let cnt = if want == -2 then m else if want < m then want else m
  vmBase = rb
  vmPc = rpc
  retCountV = cnt
}

// outarr's value test, in one place because eight call sites have to agree: a
// number (1), a float (6), nil (0) and a boolean (3) may be stored, and nil
// stores 0.0.  Anything else is a table, a string or a function.
mod arrNumOk(tag: int) -> bool {
  return tag == 1 || tag == 6 || tag == 0 || tag == 3
}

mod vSetInt(a: int, v: float) {
  let w = intWrap(v)
  if w == floor(w) && 0.0 <= w + INT64_LIMIT && w < INT64_LIMIT {
    vSet(a, 6, w, "")
  } else {
    vSetNum(a, w)
  }
}

mod vSetIntSat(a: int, v: float) {
  var w = v
  if w + INT64_LIMIT < 0.0 {
    w = 0.0 - INT64_LIMIT
  } else if INT64_LIMIT <= w {
    w = INT64_LIMIT
  }
  vSet(a, 6, w, "")
}

// One codepoint per call; prefix rules match Lua, order is by codepoint
// (identical to byte order for ASCII).
mod cmpStep() {
  let sa = vstr[cmpAA]
  let sb = vstr[cmpBB]
  let la = sa.Length()
  let lb = sb.Length()
  if cmpI >= la && cmpI >= lb {
    cmpFinish(cmpOp == 1)
  } else if cmpI >= la {
    cmpFinish(true)
  } else if cmpI >= lb {
    cmpFinish(false)
  } else {
    let ca = sa.Substring(cmpI, 1).ToCharCode().Codepoint
    let cb = sb.Substring(cmpI, 1).ToCharCode().Codepoint
    if ca != cb {
      cmpFinish(ca < cb)
    } else {
      cmpI = cmpI + 1
    }
  }
}

mod tblFill(dst: int, tid: int, idx: int) {
  let r = tmap.get(tkey(tid, 1, idx, ""))
  if r.Found {
    vSet(dst, tvTag[r.Value], tvNum[r.Value], tvStr[r.Value])
  } else {
    vSet(dst, 0, 0.0, "")
  }
}

// One digit of a radix conversion, with the division done by hand: the host's
// floor truncates toward zero, so a negative quotient never goes negative and
// %x of -1 came out as fifteen zeros.  The quotient is a truncating cast and a
// negative remainder is carried into the digit and taken off the quotient, which
// is floor division; the quotient then settles at -1 and the digit count is what
// stops the loop, which is where the 64-bit two's complement comes from.
// One digit of a radix conversion, with the division done by hand: the host's
// floor truncates toward zero, so a negative quotient never goes negative and
// %x of -1 came out as fifteen zeros.  The quotient is a truncating cast and a
// negative remainder is carried into the digit and taken off the quotient, which
// is floor division; the quotient then settles at -1 and the digit count is what
// stops the loop, which is where the 64-bit two's complement comes from.  It
// leaves the digit in fmtQ_ and fmtDigitPut turns it into a character.
mod fmtRadixDigit() {
  let q = toInt(fmtNum_ / fmtBase_)
  let r = toInt(fmtNum_ - q * fmtBase_)
  if r < 0 {
    fmtQ_ = r + fmtBaseI
    fmtNum_ = q - 1.0
  } else {
    fmtQ_ = r
    fmtNum_ = q
  }
  fmtState = 33
}

// The sign for %d %i %u, and the 0x / 0X / 0 prefix for %x %X %o.  The radix
// conversions have no sign -- they print the two's complement -- and # adds
// nothing for a zero, in either base.
mod fmtSign() {
  if fmtBase_ == 10.0 {
    if fmtNeg {
      fmtBody = "-" .. fmtBody
    } else if fmtPlus == 1 {
      fmtBody = "+" .. fmtBody
    } else if fmtSpace == 1 {
      fmtBody = " " .. fmtBody
    }
  } else {
    fmtRadixPrefix()
  }
  fmtPre = ""
  fmtState = 6
}

// ( starts a capture, and a ( followed by ) is PUC's position capture: its value
// is where it stands rather than what it covers, which is why find answers a
// number there and not a string.  A capture's number is how many the attempt has
// opened, and patCapN is how many are open *now*: the two are not the same, since
// "(a)(b)" closes the first before it opens the second, and PUC numbers those one
// and two.  Each records the start it had, so a rewind puts that back.  Returns
// the state to run next.
//
// The two counters are written last, and n is read from patNCap first: a local
// computed from a var the same mod writes is re-derived at its next use, so
// patPush was handed n + 1 and the first capture's entry pointed at the second
// one's slot.
mod patOpen() -> int {
  let n = patNCap + 1
  let old = patCapS[n]
  if 32 < n {
    patErr = "too many captures"
    return 8
  }
  if patP + 1 < patPEnd && patPat.Substring(patP + 1, 1) == ")" {
    // the ) is part of the item, so it is consumed here and the capture is
    // already closed: patCapN does not count it
    if !patPush(6, n, old, 0) {
      patErr = "pattern too complex"
      return 8
    }
    patCapS[n] = patI
    patCapE[n] = 0
    patCapP[n] = 1
    patP = patP + 2
    patNCap = n
  } else {
    if !patPush(5, n, old, 0) {
      patErr = "pattern too complex"
      return 8
    }
    patCapS[n] = patI
    patCapE[n] = 0
    patCapP[n] = 0
    patCapIx[patCapN] = n
    patP = patP + 1
    patNCap = n
    patCapN = patCapN + 1
  }
  return 1
}

// ) closes the innermost open capture -- the one on top of patCapIx, whose
// number is neither the depth nor the count in general -- and records that it
// did: a quantifier inside the capture gives a character back and runs the )
// again, which has to find the capture open the second time.  PUC's
// start_capture is a recursive call and gets that from the recursion; a flat
// machine has to write it down, and the entry carries the depth to put back.  A
// ) reached once a capture has been opened is PUC's "invalid pattern capture",
// and before any has, it is a character that matches nothing, which is where
// PUC's answers for "a)" and ")" come from.
mod patClose() -> int {
  let d = patCapN - 1
  let c = patCapIx[d]
  let old = patCapE[c]
  if !patPush(7, c, old, d + 1) {
    patErr = "pattern too complex"
    return 8
  }
  patCapE[c] = patI + 1
  patCapN = d
  patP = patP + 1
  return 1
}

// The item's verdict is in patHit and its extent in patItemE, so this is where
// the quantifier is read and where every alternative is recorded.  The order
// matters: a greedy quantifier records the position the rest would resume from
// and then consumes as many characters as it can, so the rest of the pattern
// sees the longest match first; a lazy one records the position before the item
// and tries the rest there first; ? records how to skip the item it matched, and
// a quantifier whose item did not match records nothing, because there is no
// longer alternative to come back to.
mod patApply() {
  let q = if patPlain then "" else if patItemE < patPEnd then patPat.Substring(patItemE, 1) else ""
  patQ = if q == "*" then 1 else if q == "+" then 2 else if q == "-" then 3 else if q == "?" then 4 else 0
  patQEnd = if patQ == 0 then patItemE else patItemE + 1
  if patQ == 0 {
    if patHit {
      patI = patI + patAdv
      patP = patQEnd
      patSt = 1
    } else {
      patSt = 4
    }
  } else if patQ == 1 || patQ == 2 {
    if !patHit {
      // zero repetitions: + is the one quantifier that cannot have none
      if patQ == 2 {
        patSt = 4
      } else {
        patP = patQEnd
        patSt = 1
      }
    } else if !patPush(1, patItemP, patI, patQEnd) {
      patErr = "pattern too complex"
      patSt = 8
    } else {
      patSt = 11
    }
  } else if patQ == 3 {
    if patHit {
      if !patPush(4, patItemP, patI, patQEnd) {
        patErr = "pattern too complex"
        patSt = 8
      } else {
        patP = patQEnd
        patSt = 1
      }
    } else {
      patP = patQEnd
      patSt = 1
    }
  } else {
    if patHit {
      if patPush(2, patQEnd, 0, 0) {
        patI = patI + 1
        patP = patQEnd
        patSt = 1
      } else {
        patErr = "pattern too complex"
        patSt = 8
      }
    } else {
      patP = patQEnd
      patSt = 1
    }
  }
}

// A set matched on the way back up the stack: the lazy item takes one more
// character and records where to take the next one from.
mod patSetRetry() {
  patI = patI + 1
  if 0 <= patI {
    patPush(4, patItemP, patI, patQEnd)
  }
  patP = patQEnd
  patSt = 1
}

// The library is prepended to the program, so a line in the source the lexer
// and the parser see counts the library's lines as well.  Both error paths undo
// that here, because two copies of one subtraction is one copy waiting to be
// wrong -- and the parser's was missing, so every syntax error in a program that
// pulled in a piece reported a line number tens of lines too high.
//
// It answers a STRING, not a number, because the int/float distinction lives in
// the register's tag and a line number is an int: fmtNum is the FLOAT formatter
// and always spells a whole number "2.0" (which is right for 2.0 and wrong for a
// line).  The int spelling is the one fmtVal uses for the integer tag.
mod userLine(raw: float) -> string {
  let l = toInt(raw)
  var u = l
  if libLines < l { u = l - libLines } else { u = 1 }
  return "" .. (u | 0)
}

// Writable output globals live in gtag/gnum/gstr (slots 0..5); the ports
// mirror them once per tick. Numeric outs read as numbers (nil -> 0.0),
// string outs Lua-formatted (nil -> "").
mod syncOuts() {
}

// The integer part's digits, then the fraction's.  One state to hand the digit
// walk its next state, so the walk itself stays the one %f uses.
mod fmtIntStart() {
  fmtFNDigits()
}

mod libStrIndex(p: string) -> string {
  return if srcUses(p, "string.len") || srcUses(p, "string.sub")
      || srcUsesField(p, "len") || srcUsesField(p, "sub")
      || srcUsesField(p, "byte") || srcUsesField(p, "char")
      then LIB_str_index else ""
}

mod libStrCase(p: string) -> string {
  return if srcUses(p, "string.upper") || srcUses(p, "string.lower")
      || srcUsesField(p, "upper") || srcUsesField(p, "lower")
      then LIB_str_case else ""
}

mod libStrFmt(p: string) -> string {
  return if srcUses(p, "string.format") || srcUsesField(p, "format")
      then LIB_str_fmt else ""
}

mod libStrGmatch(p: string) -> string {
  return if srcUses(p, "string.gmatch") || srcUsesField(p, "gmatch")
      then LIB_str_gmatch else ""
}

// gsub's replacement walk scans for '%' with string.find, so it brings the pat
// piece with it; libStrPat then stands down so the program pays for it once.
mod libStrPat(p: string) -> string {
  return if (srcUses(p, "string.find") || srcUses(p, "string.match")
      || srcUsesField(p, "find") || srcUsesField(p, "match"))
      && !(srcUses(p, "string.gsub") || srcUsesField(p, "gsub"))
      then LIB_str_pat else ""
}

mod libStrGsub(p: string) -> string {
  return if srcUses(p, "string.gsub") || srcUsesField(p, "gsub")
      then LIB_str_pat .. LIB_str_gsub else ""
}

mod libStrMisc(p: string) -> string {
  return if srcUses(p, "string.rep") || srcUses(p, "string.reverse")
      || srcUsesField(p, "rep") || srcUsesField(p, "reverse")
      then LIB_str_misc else ""
}

mod libMathInt(p: string) -> string {
  return if srcUses(p, "math.floor") || srcUses(p, "math.ceil")
      || srcUses(p, "math.tointeger") || srcUses(p, "math.type")
      || srcUses(p, "math.abs") || srcUses(p, "math.sqrt")
      || srcUsesField(p, "floor") || srcUsesField(p, "ceil")
      || srcUsesField(p, "abs") || srcUsesField(p, "sqrt")
      || srcUsesField(p, "tointeger") || srcUsesField(p, "type")
      then LIB_math_int else ""
}

mod libMathTrig(p: string) -> string {
  return if srcUses(p, "math.sin") || srcUses(p, "math.cos")
      || srcUses(p, "math.tan") || srcUses(p, "math.asin")
      || srcUses(p, "math.acos") || srcUses(p, "math.atan")
      || srcUsesField(p, "sin") || srcUsesField(p, "cos")
      || srcUsesField(p, "tan") || srcUsesField(p, "asin")
      || srcUsesField(p, "acos") || srcUsesField(p, "atan")
      then LIB_math_trig else ""
}

mod libMathExp(p: string) -> string {
  return if srcUses(p, "math.exp") || srcUses(p, "math.log")
      || srcUsesField(p, "exp") || srcUsesField(p, "log")
      then LIB_math_exp else ""
}

mod libMathMisc(p: string) -> string {
  return if srcUses(p, "math.max") || srcUses(p, "math.min")
      || srcUses(p, "math.fmod") || srcUses(p, "math.modf")
      || srcUsesField(p, "max") || srcUsesField(p, "min")
      || srcUsesField(p, "fmod") || srcUsesField(p, "modf")
      then LIB_math_misc else ""
}

// Put the allocator back inside a window bumpMax already claimed.  A call's
// arguments are parsed after its callee register is allocated, and they belong
// in that window, so allocation resumes at reg+1 rather than past its end.
mod rewindTo(r: int) {
  if regAlloc() >= cfNext[fnDepth] {
    perr = true
    perrMsg = "too many registers"
  }
  cfNext[fnDepth] = r
}

// Record a binary operator arrival: pops run first, the frame is pushed
// once they drain (see pushPending). fl packs assoc bit + swap/negate bits.
mod binArrive(opc: int, prec: int, fl: int) {
  let t = opTopKind()
  if (opc == 17 || opc == 18 || opc == 19) && t == 0 {
    let ta = opA[opA.length() - 1]
    if ta == 17 || ta == 18 || ta == 19 {
      perr = true
      perrMsg = "chained comparison (like Lua)"
      return
    }
  }
  pendKind = 0
  pendPrec = prec
  pendSub = opc
  pendAux = fl
  popMode = 1
  popPrec = prec
}

// One append to the log, by print or by io.write.  The caller has already made
// the text what it wants -- print's line and its 64-character cap, or io.write's
// raw chunk -- and the log keeps the last 32 appends, so the port stays a plain
// string read and cannot grow without bound.  The 64-character cap is the
// *caller's* because it is print's rule, not the log's: a write of 500 bytes is
// one append here and 500 bytes of text, not eight dropped ones.
mod logPush(line: string) {
  logLines.push(line)
  logAdd(line)
  if logLines.length() > 32 {
    let drop = logLines[0]
    logDrop(drop.Length())
    logLines.remove(0)
  }
}

// Normalize integral floats to the int tag so 1 and 1.0 share one key.
// Copy cnt values from src down to a.  The two ranges overlap, so fill from the
// LOW end: writing a high slot first would overwrite a source value that a
// lower slot still has to read.
mod shiftDown(a: int, src: int, cnt: int) {
  if 1 <= cnt { vSet(a, vTag(src), vNum(src), vStr(src)) }
  if 2 <= cnt { vSet(a + 1, vTag(src + 1), vNum(src + 1), vStr(src + 1)) }
  if 3 <= cnt { vSet(a + 2, vTag(src + 2), vNum(src + 2), vStr(src + 2)) }
  if 4 <= cnt { vSet(a + 3, vTag(src + 3), vNum(src + 3), vStr(src + 3)) }
  if 5 <= cnt { vSet(a + 4, vTag(src + 4), vNum(src + 4), vStr(src + 4)) }
  if 6 <= cnt { vSet(a + 5, vTag(src + 5), vNum(src + 5), vStr(src + 5)) }
  if 7 <= cnt { vSet(a + 6, vTag(src + 6), vNum(src + 6), vStr(src + 6)) }
  if 8 <= cnt { vSet(a + 7, vTag(src + 7), vNum(src + 7), vStr(src + 7)) }
  if 9 <= cnt { vSet(a + 8, vTag(src + 8), vNum(src + 8), vStr(src + 8)) }
  if 10 <= cnt { vSet(a + 9, vTag(src + 9), vNum(src + 9), vStr(src + 9)) }
  if 11 <= cnt { vSet(a + 10, vTag(src + 10), vNum(src + 10), vStr(src + 10)) }
  if 12 <= cnt { vSet(a + 11, vTag(src + 11), vNum(src + 11), vStr(src + 11)) }
  if 13 <= cnt { vSet(a + 12, vTag(src + 12), vNum(src + 12), vStr(src + 12)) }
  if 14 <= cnt { vSet(a + 13, vTag(src + 13), vNum(src + 13), vStr(src + 13)) }
  if 15 <= cnt { vSet(a + 14, vTag(src + 14), vNum(src + 14), vStr(src + 14)) }
  if 16 <= cnt { vSet(a + 15, vTag(src + 15), vNum(src + 15), vStr(src + 15)) }
}

// %f[set]: the frontier, a transition into the set.  It needs two set tests, the
// character before the cursor and the one at it, and patItemP is what brings the
// second scan back to the set's text.  Returns the state to run next.
mod patF() -> int {
  if patP + 2 >= patPEnd || patPat.Substring(patP + 2, 1) != "[" {
    patErr = "missing '[' after '%f' in pattern"
    return 8
  }
  patItemP = patP
  if patI == 0 {
    // there is no character before the first one, so that test is vacuously
    // true and only the one at the cursor is worth making
    patFPrev = false
    patAfter = 10
    patFailTo = 4
    patSetBegin(patP + 3, patSrc.Substring(patI, 1).ToCharCode().Codepoint)
    return 7
  }
  patAfter = 9
  patFailTo = 9
  patSetBegin(patP + 3, patSrc.Substring(patI - 1, 1).ToCharCode().Codepoint)
  return 7
}

// %f's previous-character test is done, whether it was in the set or not: the
// frontier needs to know, so the test at the cursor runs either way.
mod patFPrevStep() {
  patFPrev = patHit
  patAfter = 10
  patFailTo = 4
  patSetBegin(patItemP + 3, patSrc.Substring(patI, 1).ToCharCode().Codepoint)
  patSt = 7
}

mod emitNum() {
  let mant = lnumInt + lnumFrac / lnumDiv
  let ev = if lnumExpNeg then -lnumExp else lnumExp
  let isInt = lnumIsInt && !lnumDot && !lnumExpSeen
  let v = if isInt then lnumInt else mant * (10.0 ** ev)
  emitTok(1, if isInt then 1 else 0, v, "")
}

mod resolveKw() {
  let n = lidBuf
  let id = if n == "and" then 1
    else if n == "break" then 2
    else if n == "do" then 3
    else if n == "else" then 4
    else if n == "elseif" then 5
    else if n == "end" then 6
    else if n == "false" then 7
    else if n == "function" then 8
    else if n == "if" then 9
    else if n == "local" then 10
    else if n == "nil" then 11
    else if n == "not" then 12
    else if n == "or" then 13
    else if n == "return" then 14
    else if n == "then" then 15
    else if n == "true" then 16
    else if n == "for" then 18
    else if n == "in" then 19
    else if n == "repeat" then 20
    else if n == "until" then 21
    else if n == "goto" then 22
    else if n == "while" then 17
    else 0
  if id == 0 {
    emitTok(3, 0, 0.0, lidBuf)
  } else {
    emitTok(4, id, 0.0, "")
  }
  lidBuf = ""
}

// A long string or long comment starting at pos (its opening bracket has `level` equals equals signs).
mod lexLong(pos: int, level: int, isComment: bool) {
  let closer = closerFor(level)
  let cstart = pos + level + 2
  let e = lsrc.Find(closer, true, cstart)
  if e < 0 {
    lexFail("unfinished long string/comment")
  } else {
    let skip = if lsrc.Substring(cstart, 2) == "\r\n" then 2 else if lsrc.Substring(cstart, 1) == "\n" then 1 else 0
    let span = lsrc.Substring(pos, e + closer.Length() - pos)
    if !isComment {
      emitTok(2, 0, 0.0, lsrc.Substring(cstart + skip, e - cstart - skip))
    }
    lline = lline + span.Length() - span.Replace("\n", "").Length()
    lpos = e + closer.Length()
  }
}

// Mark the instruction at `pos` as returning all of its values (a CALL's C
// operand bit 1, or VARARG's B = 0), and reserve the result registers it may
// write so a later regAlloc cannot land on a live result.
mod patchAt(pos: int) {
  if pos >= 0 && pos < bpc.length() {
    if bop[pos] == 45 {
      bpb[pos] = 0
    } else {
      bpc[pos] = bpc[pos] + 2
    }
    let fr = bpa[pos]
    bumpMax(fr + MAXVALS)
  }
}

// lkKind: 0 none, 1 local reg, 2 self-recursion (GETCLO of the running
// frame), 3 upvalue (lkReg = this function's descriptor index).  The ladder
// only answers *which* live local the name is; one test after it decides
// local or capture, because a mod call inside the arms would be inlined 32
// times.  32 is the window, as before: a name with more live locals than that
// in front of it reads as a global, which is the same hole the old ladder had.
mod locFind(name: string) {
  lkKind = 0
  lkReg = -1
  lkFid = -1
  lkDone = false
  lkIx = -1
  if !lkRaw && selfName[fnDepth] == name && selfClean[fnDepth] {
    lkKind = 2
    lkFid = selfFid[fnDepth]
    lkDone = true
  }
  var ix = locLen - 1
  if !lkDone && 0 <= ix && locName[ix] == name {
    lkIx = ix
    lkDone = true
  }
  ix = ix - 1
  if !lkDone && 0 <= ix && locName[ix] == name {
    lkIx = ix
    lkDone = true
  }
  ix = ix - 1
  if !lkDone && 0 <= ix && locName[ix] == name {
    lkIx = ix
    lkDone = true
  }
  ix = ix - 1
  if !lkDone && 0 <= ix && locName[ix] == name {
    lkIx = ix
    lkDone = true
  }
  ix = ix - 1
  if !lkDone && 0 <= ix && locName[ix] == name {
    lkIx = ix
    lkDone = true
  }
  ix = ix - 1
  if !lkDone && 0 <= ix && locName[ix] == name {
    lkIx = ix
    lkDone = true
  }
  ix = ix - 1
  if !lkDone && 0 <= ix && locName[ix] == name {
    lkIx = ix
    lkDone = true
  }
  ix = ix - 1
  if !lkDone && 0 <= ix && locName[ix] == name {
    lkIx = ix
    lkDone = true
  }
  ix = ix - 1
  if !lkDone && 0 <= ix && locName[ix] == name {
    lkIx = ix
    lkDone = true
  }
  ix = ix - 1
  if !lkDone && 0 <= ix && locName[ix] == name {
    lkIx = ix
    lkDone = true
  }
  ix = ix - 1
  if !lkDone && 0 <= ix && locName[ix] == name {
    lkIx = ix
    lkDone = true
  }
  ix = ix - 1
  if !lkDone && 0 <= ix && locName[ix] == name {
    lkIx = ix
    lkDone = true
  }
  ix = ix - 1
  if !lkDone && 0 <= ix && locName[ix] == name {
    lkIx = ix
    lkDone = true
  }
  ix = ix - 1
  if !lkDone && 0 <= ix && locName[ix] == name {
    lkIx = ix
    lkDone = true
  }
  ix = ix - 1
  if !lkDone && 0 <= ix && locName[ix] == name {
    lkIx = ix
    lkDone = true
  }
  ix = ix - 1
  if !lkDone && 0 <= ix && locName[ix] == name {
    lkIx = ix
    lkDone = true
  }
  ix = ix - 1
  if !lkDone && 0 <= ix && locName[ix] == name {
    lkIx = ix
    lkDone = true
  }
  ix = ix - 1
  if !lkDone && 0 <= ix && locName[ix] == name {
    lkIx = ix
    lkDone = true
  }
  ix = ix - 1
  if !lkDone && 0 <= ix && locName[ix] == name {
    lkIx = ix
    lkDone = true
  }
  ix = ix - 1
  if !lkDone && 0 <= ix && locName[ix] == name {
    lkIx = ix
    lkDone = true
  }
  ix = ix - 1
  if !lkDone && 0 <= ix && locName[ix] == name {
    lkIx = ix
    lkDone = true
  }
  ix = ix - 1
  if !lkDone && 0 <= ix && locName[ix] == name {
    lkIx = ix
    lkDone = true
  }
  ix = ix - 1
  if !lkDone && 0 <= ix && locName[ix] == name {
    lkIx = ix
    lkDone = true
  }
  ix = ix - 1
  if !lkDone && 0 <= ix && locName[ix] == name {
    lkIx = ix
    lkDone = true
  }
  ix = ix - 1
  if !lkDone && 0 <= ix && locName[ix] == name {
    lkIx = ix
    lkDone = true
  }
  ix = ix - 1
  if !lkDone && 0 <= ix && locName[ix] == name {
    lkIx = ix
    lkDone = true
  }
  ix = ix - 1
  if !lkDone && 0 <= ix && locName[ix] == name {
    lkIx = ix
    lkDone = true
  }
  ix = ix - 1
  if !lkDone && 0 <= ix && locName[ix] == name {
    lkIx = ix
    lkDone = true
  }
  ix = ix - 1
  if !lkDone && 0 <= ix && locName[ix] == name {
    lkIx = ix
    lkDone = true
  }
  ix = ix - 1
  if !lkDone && 0 <= ix && locName[ix] == name {
    lkIx = ix
    lkDone = true
  }
  if lkDone && lkKind == 0 {
    if locDepth[lkIx] != fnDepth {
      resolveUp(lkIx)
    } else if locCap[lkIx] {
      // this local of ours is captured, so from here on it lives in its cell
      let k = upSelf(lkIx)
      if 0 <= k {
        lkKind = 3
        lkReg = k
      } else {
        lkKind = 1
        lkReg = locReg[lkIx]
      }
    } else {
      lkKind = 1
      lkReg = locReg[lkIx]
    }
  }
}

mod forDoHead() {
  cpos = cpos + 1
  blkEnter(true)
  let ctrl = locDeclare(forName)
  dirtySelf(forName)
  if forInit != ctrl {
    bEmit(7, ctrl, forInit, 0)
    regFree(forInit)
  }
  if forStep == -1 {
    forStep = regAlloc()
    bEmit(2, forStep, cNum(1.0), 1)
  }
  // limit/step stay live across the whole body but are never locals;
  // pin them under maxLoc so regSync cannot hand them to body temps.
  if forLimit > cfMaxLoc[fnDepth] {
    cfMaxLoc[fnDepth] = forLimit
  }
  if forStep > cfMaxLoc[fnDepth] {
    cfMaxLoc[fnDepth] = forStep
  }
  bEmit(32, ctrl, forLimit, forStep)
  let jp = bEmit(20, 0, 0, 0)
  let bs = bop.length()
  pushCtl(5, bs, jp, -1, ctlLoop, forLimit, forStep)
  ctlLoop = ctlKind.length() - 1
  forNames.push(forName)
}

// stState 20: parameter list.  `...` may appear last and makes the function
// variadic: extra arguments land in the vararg stack (fVar marks the fid).
mod funcParams() {
  // `function M:f(a)` puts M in the first parameter slot, so `self` has to be
  // the first local or every parameter shifts by one
  if fnSelfArg[fnDepth] {
    fnSelfArg[fnDepth] = false
    locDeclare("self")
  }
  if curKind() == 5 && curSub() == 32 {
    cpos = cpos + 1
    fVar[tmpB] = true
    if curKind() == 5 && curSub() == 15 {
      cpos = cpos + 1
      fParams[tmpB] = cfNext[fnDepth]
      cfBase[fnDepth] = cfNext[fnDepth]
      if selfName[fnDepth] != "" {
        locDeclare(selfName[fnDepth])
      }
      fStart[tmpB] = bop.length()
      fnVar[fnDepth] = true
      stState = 0
    } else {
      perr = true
      perrMsg = "expected ) after ..."
    }
  } else if curKind() == 3 {
    locDeclare(curStr())
    dirtySelf(curStr())
    cpos = cpos + 1
    if curKind() == 5 && curSub() == 16 {
      cpos = cpos + 1
    } else if curKind() == 5 && curSub() == 15 {
      cpos = cpos + 1
      fParams[tmpB] = cfNext[fnDepth]
      cfBase[fnDepth] = cfNext[fnDepth]
      if cfNext[fnDepth] > 8 {
        perr = true
        perrMsg = "too many parameters (max 8 in-gate)"
      }
      if selfName[fnDepth] != "" {
        locDeclare(selfName[fnDepth])
      }
      fStart[tmpB] = bop.length()
      stState = 0
    } else {
      perr = true
      perrMsg = "expected , or ) in parameter list"
    }
  } else if curKind() == 5 && curSub() == 15 {
    cpos = cpos + 1
    fParams[tmpB] = cfNext[fnDepth]
    cfBase[fnDepth] = cfNext[fnDepth]
    if cfNext[fnDepth] > 8 {
      perr = true
      perrMsg = "too many parameters (max 8 in-gate)"
    }
    if selfName[fnDepth] != "" {
      locDeclare(selfName[fnDepth])
    }
    fStart[tmpB] = bop.length()
    stState = 0
  } else {
    perr = true
    perrMsg = "expected parameter name"
  }
}

// end / else / elseif handling against the control stack top.
mod doBlockClose() {
  let s = curSub()
  if ctlKind.length() == 0 {
    perr = true
    perrMsg = "end without block"
    return
  }
  let n = ctlKind.length() - 1
  let kind = ctlKind[n]
  if s == 6 {
    if kind == 1 {
      blkExit()
      if ctlA[n] != -1 {
        bPatch(ctlA[n], bop.length())
      }
      pdHead = ctlB[n]
      pdThen = 2
      popCtl()
    } else if kind == 2 {
      blkExit()
      tmpC = ctlD[n]
      let jtop = ctlA[n]
      bEmit(20, jtop, 0, 0)
      bPatch(ctlB[n], bop.length())
      pdHead = ctlC[n]
      pdThen = 1
      popCtl()
    } else if kind == 7 {
      // generic-for tail: the control variable becomes this step's first
      // result, then jump back to the loop head
      blkExit()
      bEmit(7, ctlE[n], ctlF[n], 0)
      let back = bEmit(20, 0, 0, 0)
      bPatch(back, ctlA[n])
      bPatch(ctlB[n], bop.length())
      pdHead = ctlC[n]
      pdThen = 1
      popCtl()
      forNames.pop()
    } else if kind == 5 {
      blkExit()
      tmpC = ctlD[n]
      bEmit(33, ctlA[n], ctlE[n], ctlF[n])
      bEmit(50, 0, 0, 0)
      pdTarget = bop.length() - 1
      bPatch(ctlB[n], bop.length())
      pdHead = ctlC[n]
      pdThen = 1
      popCtl()
      forNames.pop()
    } else if kind == 3 {
      let fid = ctlA[n]
      let skip = ctlB[n]
      let resume = ctlC[n]
      let extra = ctlE[n]
      let savedCont = ctlF[n]
      let savedSt = ctlG[n]
      bEmit(26, 0, 0, 0)
      fRegs[fid] = cfMax[fnDepth]
      locLen = funcEntryLoc[fnDepth]
      fnDepth = fnDepth - 1
      bPatch(skip, bop.length())
      ctlLoop = ctlD[n]
      tmpS = tmpSStk.pop().Value
      restoreTmp()
      openCtor = ctorStk.pop().Value
      popCtl()
      if resume == 1 {
        // a function literal is a value, not a call: marking it as a call made
        // the enclosing call treat it as an expanding tail argument
        pushVal(extra, false, true)
        expectOperand = false
        inExpr = true
        exprDone = false
        contKind = savedCont
        stState = savedSt
      } else if extra == 1 {
        let outer = locDeclare(tmpS)
        bEmit(25, outer, fid, 0)
      } else if extra >= 2 {
        // function M.f(): the table register is extra-2, the field name the
        // one the header pushed
        let fr = regAlloc()
        bEmit(25, fr, fid, 0)
        // fnKey holds the field NAME, so it still needs interning: passing the
        // name itself loaded whichever string const came first, which is how
        // `function M.f` worked only until the program had another string
        let nm = cStr(fnKey.pop().Value)
        let kr = regAlloc()
        bEmit(3, kr, nm, 0)
        bEmit(30, extra - 2, kr, fr)
        bumpMax(fr + 2)
      } else {
        let fr = regAlloc()
        bEmit(25, fr, fid, 0)
        bEmit(6, gDeclare(tmpS), fr, 0)
      }
    } else {
      blkExit()
      popCtl()
    }
    cpos = cpos + 1
  } else if s == 4 {
    if kind != 1 {
      perr = true
      perrMsg = "else without if"
      return
    }
    blkExit()
    let pos = bEmit(20, 0, 0, 0)
    lstAppendB(pos)
    bPatch(ctlA[n], bop.length())
    ctlA[n] = -1
    blkEnter(false)
    cpos = cpos + 1
  } else {
    if kind != 1 {
      perr = true
      perrMsg = "elseif without if"
      return
    }
    blkExit()
    let pos = bEmit(20, 0, 0, 0)
    lstAppendB(pos)
    bPatch(ctlA[n], bop.length())
    ctlA[n] = -1
    cpos = cpos + 1
    startUnit(3)
  }
}

mod frameStamp() -> float {
  return vaNum[slotBase() - 1]
}

// The cell a descriptor names.  GETUP and SETUP only look: the closure that
// captured the local made the cell, so by the time either runs it is there,
// and a parent descriptor's cell belongs to the enclosing closure.
mod cellRead(fid: int, k: int, parent: bool) -> int {
  if parent {
    return cloU[curClo() * MAX_UP + k]
  }
  return toInt(vaNum[slotBase() + 3 * fUpSlot[fid * MAX_UP + k]])
}

mod pcallEndJoin(src: int, fixed: int, tailSrc: int, tail: int) {
  let dst = fRetBase[fRetBase.length() - 1] + fRetA[fRetA.length() - 1] + 1
  let want = fRetN[fRetN.length() - 1]
  let have = fixed + tail
  let keep = if want == -2 then have else if want < have then want else have
  let fixedKeep = if fixed < keep then fixed else keep
  let tailKeep = keep - fixedKeep
  let save = vaTop
  if 0 < tail {
    vaSpill(tailSrc, save, tail)
  }
  if 0 < tailKeep {
    vaFill(save, dst + fixedKeep, tailKeep)
  }
  pcallEnd(src, fixed, tailKeep)
}

// One digit per tick.  Digits come out least significant first and are
// prepended, so no array is needed to reverse them.  Base 10 divides a
// non-negative value; the radix bases divide the signed one.
mod fmtDigit() {
  if fmtBase_ == 10.0 {
    if fmtNum_ < 1.0 {
      fmtState = 13
    } else {
      let q = floor(fmtNum_ / 10.0)
      fmtQ_ = toInt(fmtNum_ - q * 10.0)
      fmtNum_ = q
      fmtState = 33
    }
  } else if fmtNum_ > 0.0 || fmtDigits < fmtDigitsMax {
    fmtDigits = fmtDigits + 1
    fmtRadixDigit()
  } else {
    fmtState = 13
  }
}

// The last digit: the zero a bare zero formats to (not with %.0), then the
// precision zeros.  The # prefix and the sign are fmtSign's business, because the
// prefix goes in front of the precision padding: %#.3x of 255 is 0x0ff, not 0xff.
mod fmtDigitEnd() {
  if fmtBody == "" && fmtPrec != 0 {
    fmtBody = "0"
  }
  if 0 < fmtPrec && fmtPrec > fmtBody.Length() {
    fmtPad = fmtPrec - fmtBody.Length()
    fmtPadAcc = ""
    fmtState = 9
  } else {
    fmtSign()
  }
}

// One precision zero per tick: WireScript has no loop to unroll for it.  Named
// for the state, not fmtZero: a mod and a var sharing a name silently
// miscompiles, so this must not be called fmtZero.
mod fmtPrecZero() {
  fmtPad = fmtPad - 1
  fmtPadAcc = fmtPadAcc .. "0"
  if fmtPad <= 0 {
    fmtBody = fmtPadAcc .. fmtBody
    fmtSign()
  }
}

// A chip that is lexing and parsing prints nothing, because the log belongs to
// the program and the program has not started.  A few hundred characters is a
// four-figure tick count -- a 615-char program measured 1113 -- so from the
// outside that is a chip that looks stuck, and the log, the outputs and the
// error port all read the same way while it happens.  Two `info: ` lines say so:
// the first goes on the port BEFORE the work begins, which is the only moment it
// can be read from, and the second says what the wait cost.  They are prepended
// to whatever the parse finds, because progDebug is written once when the job
// lands and that is exactly too late to announce the start.
//
// The character count is what the user handed over, not what gets lexed: a
// program that names a library has that piece's characters prepended, and the
// tick count is where that shows up.
mod parseInfoStart(chars: int) {
  dbgTick0 = ServerUptime()
  dbgStartV = "info: parse start: " .. ("" .. chars) .. " chars\n"
  progDebugV = dbgStartV
}

// Uptime is ticks * 0.01, so a span of it is a span of ticks * 100.  This is
// what turns "it is busy" into "it will be done in this many ticks", and it is
// the only place the chip reports its own cost.
//
// REBUILDS both lines from the current tick rather than appending to what is on
// the port, and that is the whole design.  Two jobs can be in flight in one tick
// -- a stale parse finishing while a new one starts -- so an append-and-latch
// keeps the FIRST end line forever, which is how this read "parse end: 0 ticks"
// on a 72-tick parse: the stale job's end arrived after the real job's start and
// the latch then blocked the real one.  Recomputing means a stale call writes a
// wrong line that the real call overwrites, so the port ends up right without
// anything having to know how many times it was written.
mod parseInfoEnd() -> string {
  let t = toInt((ServerUptime() - dbgTick0) * 100.0)
  return dbgStartV .. ("info: parse end: " .. ("" .. t) .. " ticks\n")
}

mod parseJobStart() {
  parseInit()
  // One reserved function slot per gate builtin (ids 0..NB-1), so a program's
  // own functions start at NB and can never collide with one.  The rest of the
  // standard library is Lua source prepended to the program (see libIter etc).
  pcallBad.resize(1, 0)
  patSl.resize(PAT_STACK, 0)
  patCapS.resize(33, 0)
  patCapE.resize(33, 0)
  patCapP.resize(33, 0)
  patCapIx.resize(33, 0)
  patGmS.resize(PAT_WALKS, "")
  patGmP.resize(PAT_WALKS, "")
  patGmPos.resize(PAT_WALKS, 1)
  fStart.resize(NB, -1)
  fParams.resize(NB, -1)
  fRegs.resize(NB, -1)
  fUpN.resize(NB, 0)
  fUpSlotN.resize(NB, 0)
  mainFid = newFunc()
  fStart[mainFid] = 0
  fParams[mainFid] = 0
  // the main chunk is the outermost function, so a capture of one of its locals
  // is a descriptor on it
  fidAt[0] = mainFid
}

mod fmtEFracDig() {
  let d = floor(fmtDd[0])
  // the character is its own let, as fmtDigit does it: the right-hand side of an
  // assignment is a value gate, and it sees the value the same mod has just
  // written, so an inline FromCharCode(48 + d) re-read floor(fmtDd[0]) after
  // fmtDd[0] had been reduced and every digit came out 0
  let ch = FromCharCode(48 + d).Character
  fmtDd[0] = fmtDd[0] - d
  fmtFr = fmtFr .. ch
  if fmtLz < 0 && d != 0 {
    fmtLz = fmtNz
  }
  fmtNz = fmtNz + 1
  fmtState = 31
}

mod lexStep() {
  if lstage != 99 && !lerr {
    let cp = if lpos < llen then lsrc.Substring(lpos, 1).ToCharCode().Codepoint else 0
    let ch = lsrc.Substring(lpos, 1)
    // cp2 and cp3 are two more Substring calls, and only the first three stages
    // read them: a name, a string body, an escape, a comment and a hex digit all
    // look at cp alone.  Most of a library piece's characters are inside one of
    // those, so putting the lookahead behind this test costs no nodes at all
    // and skips two string allocations for them.
    let look = lstage <= 2
    let cp2 = if look && lpos + 1 < llen then lsrc.Substring(lpos + 1, 1).ToCharCode().Codepoint else 0
    let cp3 = if look && lpos + 2 < llen then lsrc.Substring(lpos + 2, 1).ToCharCode().Codepoint else 0
    let isDigit = cp >= 48 && cp <= 57
    let isAlpha = (cp >= 65 && cp <= 90) || (cp >= 97 && cp <= 122) || cp == 95
    let isAlNum = isAlpha || isDigit
    if lstage == 10 {
      // A line comment is the largest region in this codebase's own Lua -- 53%
      // of demo.lua and 66% of lib/gmatch.lua -- and walking it one character per
      // lexStep IS the 0.500 ticks/char floor the lexer is measured at, so a
      // commented line costs what its prose costs.  One search finds the newline,
      // and a host search is a gate: it costs the same for a 4-character comment
      // and a 400-character one, which is the whole trade -- ticks for gates.
      //
      // Long comments never arrive here: `--[[` goes to lexLong, which already
      // searches for its closer, so this arm is only the `--` that is not one.
      //
      // lpos lands ON the newline instead of past it, so stage 0 consumes it and
      // counts the line.  That is also what keeps a CRLF file counting once per
      // line: the CR is inside the jumped-over region and the LF is the single
      // character stage 0 gets to see.
      let nl = lsrc.Find("\n", true, lpos)
      if 0 <= nl {
        lpos = nl
        lstage = 0
      } else {
        // a comment that runs to the end of the source with no newline is the
        // end of the lex, which is what walking off the end used to arrive at
        lpos = llen
        lstage = 99
      }
    } else if lpos >= llen {
      if lstage == 1 || lstage == 2 || (lstage == 11 && lnumHexN > 0) {
        emitNum()
        lstage = 99
      } else if lstage == 11 {
        lexFail("malformed number")
      } else if lstage == 3 {
        if lnumExpSeen {
          emitNum()
          lstage = 99
        } else {
          lexFail("malformed number")
        }
      } else if lstage == 6 {
        resolveKw()
        lstage = 99
      } else if lstage == 0 {
        lstage = 99
      } else {
        lexFail("unterminated string")
      }
    } else if lstage == 0 {
      if cp == 32 || cp == 9 || cp == 10 || cp == 13 {
        if cp == 10 {
          lline = lline + 1
        }
        lpos = lpos + 1
      } else if isDigit {
        if cp == 48 && (cp2 == 120 || cp2 == 88) {
          lnumInt = 0.0
          lnumFrac = 0.0
          lnumDiv = 1.0
          lnumDot = false
          lnumExp = 0
          lnumExpNeg = false
          lnumExpSeen = false
          lnumIsInt = true
          lnumHexN = 0
          lstage = 11
          lpos = lpos + 2
        } else {
          lnumInt = cp - 48.0
          lnumFrac = 0.0
          lnumDiv = 1.0
          lnumDot = false
          lnumExp = 0
          lnumExpNeg = false
          lnumExpSeen = false
          lnumIsInt = true
          lnumHexN = 0
          lstage = 1
          lpos = lpos + 1
        }
      } else if cp == 46 {
        if cp2 >= 48 && cp2 <= 57 {
          lnumInt = 0.0
          lnumFrac = 0.0
          lnumDiv = 1.0
          lnumDot = true
          lnumExp = 0
          lnumExpNeg = false
          lnumExpSeen = false
          lstage = 2
          lpos = lpos + 1
        } else if cp2 == 46 {
          if cp3 == 46 {
            emitTok(5, 32, 0.0, "")
            lpos = lpos + 3
          } else {
            emitTok(5, 18, 0.0, "")
            lpos = lpos + 2
          }
        } else {
          emitTok(5, 23, 0.0, "")
          lpos = lpos + 1
        }
      } else if cp == 34 || cp == 39 {
        // A literal with no escape in it is the common case, and one string
        // search finds where it ends: the closing delimiter, unless a backslash
        // or a newline comes first, which means the per-character path below
        // (an escape, or the unterminated-string error).  PUC's lexer is C and
        // scans the same way, and a library piece is mostly string literals --
        // this is the cheap half of the boot cost, with no ladder in it.
        let e = lsrc.Find(ch, true, lpos + 1)
        if 0 <= e {
          let bs = lsrc.Find("\\", true, lpos + 1)
          let nl = lsrc.Find("\n", true, lpos + 1)
          if (bs < 0 || e < bs) && (nl < 0 || e < nl) {
            emitTok(2, 0, 0.0, lsrc.Substring(lpos + 1, e - lpos - 1))
            lpos = e + 1
          } else {
            lstrDelim = ch
            lidBuf = ""
            lstage = 4
            lpos = lpos + 1
          }
        } else {
          lstrDelim = ch
          lidBuf = ""
          lstage = 4
          lpos = lpos + 1
        }
      } else if isAlpha {
        lidBuf = ch
        lstage = 6
        lpos = lpos + 1
      } else if cp == 43 {
        emitTok(5, 1, 0.0, "")
        lpos = lpos + 1
      } else if cp == 45 {
        if cp2 == 45 {
          let lv = longLevel(lpos + 2)
          if lv >= 0 {
            lexLong(lpos + 2, lv, true)
          } else {
            lstage = 10
            lpos = lpos + 2
          }
        } else {
          emitTok(5, 2, 0.0, "")
          lpos = lpos + 1
        }
      } else if cp == 42 {
        emitTok(5, 3, 0.0, "")
        lpos = lpos + 1
      } else if cp == 47 {
        if cp2 == 47 {
          emitTok(5, 30, 0.0, "")
          lpos = lpos + 2
        } else {
          emitTok(5, 4, 0.0, "")
          lpos = lpos + 1
        }
      } else if cp == 37 {
        emitTok(5, 5, 0.0, "")
        lpos = lpos + 1
      } else if cp == 94 {
        emitTok(5, 6, 0.0, "")
        lpos = lpos + 1
      } else if cp == 60 {
        if cp2 == 60 {
          emitTok(5, 28, 0.0, "")
          lpos = lpos + 2
        } else if cp2 == 61 {
          emitTok(5, 9, 0.0, "")
          lpos = lpos + 2
        } else {
          emitTok(5, 7, 0.0, "")
          lpos = lpos + 1
        }
      } else if cp == 62 {
        if cp2 == 62 {
          emitTok(5, 29, 0.0, "")
          lpos = lpos + 2
        } else if cp2 == 61 {
          emitTok(5, 10, 0.0, "")
          lpos = lpos + 2
        } else {
          emitTok(5, 8, 0.0, "")
          lpos = lpos + 1
        }
      } else if cp == 61 {
        if cp2 == 61 {
          emitTok(5, 11, 0.0, "")
          lpos = lpos + 2
        } else {
          emitTok(5, 13, 0.0, "")
          lpos = lpos + 1
        }
      } else if cp == 126 {
        if cp2 == 61 {
          emitTok(5, 12, 0.0, "")
          lpos = lpos + 2
        } else if cp2 == 126 {
          lexFail("deprecated '~~', use '~'")
        } else {
          emitTok(5, 27, 0.0, "")
          lpos = lpos + 1
        }
      } else if cp == 40 {
        emitTok(5, 14, 0.0, "")
        lpos = lpos + 1
      } else if cp == 41 {
        emitTok(5, 15, 0.0, "")
        lpos = lpos + 1
      } else if cp == 44 {
        emitTok(5, 16, 0.0, "")
        lpos = lpos + 1
      } else if cp == 59 {
        emitTok(5, 17, 0.0, "")
        lpos = lpos + 1
      } else if cp == 38 {
        emitTok(5, 25, 0.0, "")
        lpos = lpos + 1
      } else if cp == 124 {
        emitTok(5, 26, 0.0, "")
        lpos = lpos + 1
      } else if cp == 123 {
        emitTok(5, 19, 0.0, "")
        lpos = lpos + 1
      } else if cp == 125 {
        emitTok(5, 20, 0.0, "")
        lpos = lpos + 1
      } else if cp == 91 {
        let lv = longLevel(lpos)
        if lv >= 0 {
          lexLong(lpos, lv, false)
        } else {
          emitTok(5, 21, 0.0, "")
          lpos = lpos + 1
        }
      } else if cp == 93 {
        emitTok(5, 22, 0.0, "")
        lpos = lpos + 1
      } else if cp == 35 {
        emitTok(5, 24, 0.0, "")
        lpos = lpos + 1
      } else if cp == 58 {
        emitTok(5, 31, 0.0, "")
        lpos = lpos + 1
      } else {
        lexFail("unexpected character")
      }
    } else if lstage == 1 {
      // number integer part
      if isDigit {
        lnumInt = lnumInt * 10.0 + (cp - 48.0)
        lpos = lpos + 1
      } else if cp == 46 {
        if cp2 >= 48 && cp2 <= 57 {
          lnumDot = true
          lstage = 2
          lpos = lpos + 1
        } else if cp2 == 46 {
          lexFail("malformed number (like Lua '5..3')")
        } else if cp2 == 101 || cp2 == 69 {
          lnumDot = true
          lstage = 3
          lpos = lpos + 2
        } else {
          // trailing dot with no fraction (like Lua '5.'): float
          lnumDot = true
          emitNum()
          lstage = 0
          lpos = lpos + 1
        }
      } else if cp == 101 || cp == 69 {
        if (cp2 >= 48 && cp2 <= 57) || ((cp2 == 43 || cp2 == 45) && cp3 >= 48 && cp3 <= 57) {
          lstage = 3
          lpos = lpos + 1
        } else {
          emitNum()
          lstage = 0
        }
      } else {
        emitNum()
        lstage = 0
      }
    } else if lstage == 2 {
      // number fraction part
      if isDigit {
        lnumFrac = lnumFrac * 10.0 + (cp - 48.0)
        lnumDiv = lnumDiv * 10.0
        lpos = lpos + 1
      } else if cp == 101 || cp == 69 {
        if (cp2 >= 48 && cp2 <= 57) || ((cp2 == 43 || cp2 == 45) && cp3 >= 48 && cp3 <= 57) {
          lstage = 3
          lpos = lpos + 1
        } else {
          emitNum()
          lstage = 0
        }
      } else {
        emitNum()
        lstage = 0
      }
    } else if lstage == 3 {
      // number exponent part
      if (cp == 43 || cp == 45) && !lnumExpSeen && lnumExp == 0 {
        lnumExpNeg = cp == 45
        lnumExpSeen = true
        lpos = lpos + 1
      } else if isDigit {
        lnumExp = lnumExp * 10 + (cp - 48)
        lnumExpSeen = true
        lpos = lpos + 1
      } else if lnumExpSeen {
        emitNum()
        lstage = 0
      } else {
        lexFail("malformed number")
      }
    } else if lstage == 11 {
      // hex integer digits (0x prefix already consumed)
      let hv = hexVal(cp)
      if hv >= 0 {
        lnumInt = lnumInt * 16.0 + (hv + 0.0)
        lnumHexN = lnumHexN + 1
        lpos = lpos + 1
      } else if lnumHexN == 0 {
        lexFail("malformed number")
      } else {
        emitNum()
        lstage = 0
      }
    } else if lstage == 4 {
      // string body
      if ch == lstrDelim {
        emitTok(2, 0, 0.0, lidBuf)
        lidBuf = ""
        lstage = 0
        lpos = lpos + 1
      } else if cp == 92 {
        lstage = 5
        lpos = lpos + 1
      } else if cp == 10 || cp == 13 {
        lexFail("unterminated string")
      } else {
        lidBuf = lidBuf .. ch
        lpos = lpos + 1
      }
    } else if lstage == 5 {
      // first escape char
      if cp == 110 {
        lidBuf = lidBuf .. "\n"
        lstage = 4
        lpos = lpos + 1
      } else if cp == 116 {
        lidBuf = lidBuf .. "\t"
        lstage = 4
        lpos = lpos + 1
      } else if cp == 114 {
        lidBuf = lidBuf .. "\r"
        lstage = 4
        lpos = lpos + 1
      } else if cp == 97 || cp == 98 || cp == 102 || cp == 118 {
        // Lua \a \b \f \v are control chars the gate cannot spell:
        // use decimal escapes of printable chars instead (or avoid them)
        lexFail("bad escape")
      } else if cp == 92 || cp == 34 || cp == 39 {
        lidBuf = lidBuf .. ch
        lstage = 4
        lpos = lpos + 1
      } else if cp == 10 || cp == 13 {
        if cp == 10 {
          lline = lline + 1
        }
        lidBuf = lidBuf .. "\n"
        lstage = 4
        lpos = lpos + 1
      } else if isDigit {
        lescDec = cp - 48
        lescCount = 1
        lstage = 7
        lpos = lpos + 1
      } else if cp == 120 {
        lescDec = 0
        lescCount = 0
        lstage = 8
        lpos = lpos + 1
      } else if cp == 122 {
        lstage = 9
        lpos = lpos + 1
      } else {
        lexFail("bad escape")
      }
    } else if lstage == 6 {
      // name / keyword
      if isAlNum {
        lidBuf = lidBuf .. ch
        lpos = lpos + 1
      } else {
        resolveKw()
        lstage = 0
      }
    } else if lstage == 7 {
      // decimal escape digits (2nd-3rd)
      if isDigit && lescCount < 3 {
        lescDec = lescDec * 10 + (cp - 48)
        lescCount = lescCount + 1
        lpos = lpos + 1
      } else {
        emitEscByte(lescDec)
        lstage = 4
      }
    } else if lstage == 8 {
      // hex escape (exactly 2 digits)
      let hv = hexVal(cp)
      if hv >= 0 && lescCount == 0 {
        lescDec = hv
        lescCount = 1
        lpos = lpos + 1
      } else if hv >= 0 && lescCount == 1 {
        emitEscByte(lescDec * 16 + hv)
        lstage = 4
        lpos = lpos + 1
      } else {
        lexFail("bad hex escape")
      }
    } else if lstage == 9 {
      // \z skip whitespace
      if cp == 32 || cp == 9 || cp == 10 || cp == 13 {
        if cp == 10 {
          lline = lline + 1
        }
        lpos = lpos + 1
      } else {
        lstage = 4
      }
    }
  }
}

mod patchMultiTail() {
  patchAt(lastCallPos)
  lastCallPos = -1
}

// A call in the LAST value position of a target list expands into the targets
// that list still has unfilled: `local a, b = f()` binds b to f's second value
// (nil when f returned only one).  Mark the call to return everything, then
// normalise however many values came back into `extra` consecutive registers so
// the ordinary store machinery can treat them like any other value registers.
// A call in the LAST value position of a target list expands into the targets
// that list still has unfilled: `local a, b = f()` binds b to f's second value
// (nil when f returned only one).  Mark the call to return everything, then
// normalise however many values came back into `extra` consecutive registers so
// the ordinary store machinery can treat them like any other value registers.
mod expandTailCall() {
  var extra = tmpNames.length() - tmpRegs.length()
  if presIsCall && 0 < extra && !perr {
    if extra > MAXVALS {
      extra = MAXVALS
    }
    let callBase = presReg
    patchAt(presCallPos)
    let sc = regAlloc()
    bEmit(43, callBase + 1, sc, extra)
    bumpMax(sc + extra)
    if 1 <= extra { tmpRegs.push(sc) }
    if 2 <= extra { tmpRegs.push(sc + 1) }
    if 3 <= extra { tmpRegs.push(sc + 2) }
    if 4 <= extra { tmpRegs.push(sc + 3) }
    if 5 <= extra { tmpRegs.push(sc + 4) }
    if 6 <= extra { tmpRegs.push(sc + 5) }
    if 7 <= extra { tmpRegs.push(sc + 6) }
    if 8 <= extra { tmpRegs.push(sc + 7) }
    if 9 <= extra { tmpRegs.push(sc + 8) }
    if 10 <= extra { tmpRegs.push(sc + 9) }
    if 11 <= extra { tmpRegs.push(sc + 10) }
    if 12 <= extra { tmpRegs.push(sc + 11) }
    if 13 <= extra { tmpRegs.push(sc + 12) }
    if 14 <= extra { tmpRegs.push(sc + 13) }
    if 15 <= extra { tmpRegs.push(sc + 14) }
    if 16 <= extra { tmpRegs.push(sc + 15) }
  }
}

// Finish one constructor element: the value sits on valStk above the frame.
// isLast marks the element closed by '}' â€” a call there expands, so its results
// all land in the table (Lua expands a call only in the final list position).
mod finishCtorElem(isLast: bool) {
  let wasCall = topFlag()
  let v = popVal()
  let tr = opA[opA.length() - 1]
  let kr = opB[opB.length() - 1]
  if kr == -1 {
    if isLast && wasCall {
      patchAt(lastCallPos)
      bEmit(44, tr, v, MAXVALS)
      opPrec[opPrec.length() - 1] = opPrec[opPrec.length() - 1] + MAXVALS
    } else {
      let idx = opPrec[opPrec.length() - 1] + 1
      opPrec[opPrec.length() - 1] = idx
      let kk = regAlloc()
      bEmit(2, kk, cNum(idx + 0.0), 1)
      bEmit(30, tr, kk, v)
    }
  } else {
    bEmit(30, tr, kr, v)
    opB[opB.length() - 1] = -1
  }
  lastCallPos = -1
  cfNext[fnDepth] = tr + 1
}

mod exprPushName(callParen: bool, callSugar: bool) {
  let name = curStr()
  locFind(name)
  if callParen || callSugar {
    // the callee goes into a fresh call-frame register
    let fr = regAlloc()
    if lkKind == 2 {
      bEmit(48, fr, 0, 0)
    } else if lkKind == 3 {
      bEmit(46, fr, lkReg, upKind())
    } else if lkKind == 1 {
      bEmit(7, fr, lkReg, 0)
    } else {
      bEmit(5, fr, gRef(name), 0)
    }
    if callParen {
      pushOp(2, -1, fr, 0, valStk.length())
      cpos = cpos + 2
      // The peek reads the CURRENT TOKEN, which is the first argument, so it is not
      // affected by the value stack.  valStk.length() cannot be used for an arity
      // count here: this call's arguments are not pushed yet at this point, which
      // is what made an earlier arity check warn on outnum(i, i).
      //
      if lkKind == 0 {
        noteArity(name)
        noteIndex(name)
      }
      expectOperand = true
    } else {
      let ar = regAlloc()
      bEmit(3, ar, cStr(curStrAhead()), 0)
      bEmit(7, fr + 1, ar, 0)
      bEmit(23, fr, 1, 0)
      bumpMax(fr + 3)
      rewindTo(fr + 1)
      pushVal(fr, true, true)
      cpos = cpos + 2
      expectOperand = false
    }
  } else {
    if lkKind == 1 {
      pushVal(lkReg, false, true)
    } else {
      let r = regAlloc()
      if lkKind == 2 {
        // the recursive name is the closure this frame is running, not the
        // prototype: a local function with upvalues has one per call
        bEmit(48, r, 0, 0)
      } else if lkKind == 3 {
        bEmit(46, r, lkReg, upKind())
      } else {
        bEmit(5, r, gRef(name), 0)
      }
      pushVal(r, false, true)
    }
    cpos = cpos + 1
    expectOperand = false
  }
}

// Emit a numeric-for header after `do`: bind the control var (locals parsed
// in the header still see outer scope), default a missing step to 1,
// then FORPREP + entry JMP and open the body block (ctl kind 5).
// Generic for: `for v1 [, v2] in explist do`.
// The explist gives (f, s, ctrl); each step calls f(s, ctrl), stops when the
// first result is nil, and feeds the results to the loop variables.  Only the
// control variable moves on: it becomes the first result of each step, while
// the state stays what the explist put there (verified against the oracle).
// The header emits the loop head and the variable bindings; doBlockClose(kind
// 7) appends the control update and the jump back.  Everything the close needs
// lives in the control frame, so generic-fors nest.
mod genForHead() {
  if !(curKind() == 4 && curSub() == 3) {
    perr = true
    perrMsg = "expected do in for"
    return
  }
  cpos = cpos + 1
  blkEnter(true)
  if tmpRegs.length() < 1 {
    perr = true
    perrMsg = "for iterator is missing"
    return
  }
  let freg = regAlloc()
  let sreg = regAlloc()
  let creg = regAlloc()
  bEmit(7, freg, tmpRegs[0], 0)
  if 1 < tmpRegs.length() {
    bEmit(7, sreg, tmpRegs[1], 0)
  } else {
    bEmit(1, sreg, 0, 0)
  }
  if 2 < tmpRegs.length() {
    bEmit(7, creg, tmpRegs[2], 0)
  } else {
    bEmit(1, creg, 0, 0)
  }
  // the iterator, its state and the control value stay live across the body
  if freg > cfMaxLoc[fnDepth] { cfMaxLoc[fnDepth] = freg }
  if sreg > cfMaxLoc[fnDepth] { cfMaxLoc[fnDepth] = sreg }
  if creg > cfMaxLoc[fnDepth] { cfMaxLoc[fnDepth] = creg }
  let v1 = locDeclare(tmpNames[0])
  dirtySelf(tmpNames[0])
  var v2 = -1
  if 1 < tmpNames.length() {
    v2 = locDeclare(tmpNames[1])
    dirtySelf(tmpNames[1])
  }
  // The call gets its own base, allocated *after* the loop variables: a call
  // leaves its results in the base register and the one above it, so a base
  // below them would overwrite a variable with the iterator's own first result.
  let cb = regAlloc()
  if cb > cfMaxLoc[fnDepth] { cfMaxLoc[fnDepth] = cb }
  // loop head: f(s, ctrl) with its two arguments in place
  let top = bop.length()
  bEmit(7, cb, freg, 0)
  bEmit(7, cb + 1, sreg, 0)
  bEmit(7, cb + 2, creg, 0)
  bEmit(23, cb, 2, 2)
  let done = bEmit(21, 0, cb, 0)
  // bind the results to the loop variables (runs once per entry)
  bEmit(7, v1, cb, 0)
  if 0 <= v2 {
    bEmit(7, v2, cb + 1, 0)
  }
  // kind 7: A=loop top, B=exit jump, C=break list, D=ctrl reg, E=first var
  pushCtl(7, top, done, -1, ctlLoop, creg, v1)
  ctlLoop = ctlKind.length() - 1
  forNames.push(tmpNames[0])
}

mod stmtDispatch() {
  regSync()
  let k = curKind()
  let s = curSub()
  if k == 5 && s == 17 {
    cpos = cpos + 1
  } else if k == 6 {
    if ctlKind.length() == 0 {
      bEmit(26, 0, 0, 0)
      fRegs[mainFid] = cfMax[0]
      pDone = true
    } else {
      perr = true
      perrMsg = "unclosed block at end"
    }
  } else if k == 4 && s == 10 {
    cpos = cpos + 1
    if curKind() == 4 && curSub() == 8 {
      cpos = cpos + 1
      if curKind() == 3 {
        tmpS = curStr()
        cpos = cpos + 1
        funcHead(true, 0, 0)
      } else {
        perr = true
        perrMsg = "expected name after local function"
      }
    } else if curKind() == 3 {
      tmpNames.clear()
      tmpRegs.clear()
      tmpNames.push(curStr())
      cpos = cpos + 1
      if curKind() == 5 && curSub() == 16 {
        cpos = cpos + 1
        stState = 10
      } else if curKind() == 5 && curSub() == 13 {
        cpos = cpos + 1
        startUnit(6)
      } else {
        // no values: nil-fill; the next token is validated by dispatch
        tmpA = 0
        stState = 12
      }
    } else {
      perr = true
      perrMsg = "expected name after local"
    }
  } else if k == 4 && s == 8 {
    cpos = cpos + 1
    if curKind() == 3 {
      tmpS = curStr()
      cpos = cpos + 1
      if curKind() == 5 && (curSub() == 23 || curSub() == 31) && nextKind() == 3 {
        // function M.f(...) is M.f = function(...): keep the table in a
        // register and store the function into the field when the body ends.
        // With ':' the field name is a method, so the receiver is parameter one.
        let isMethod = curSub() == 31
        let tr = regAlloc()
        locFind(tmpS)
        if lkKind == 3 {
          bEmit(46, tr, lkReg, upKind())
        } else if lkKind == 1 {
          bEmit(7, tr, lkReg, 0)
        } else {
          bEmit(5, tr, gDeclare(tmpS), 0)
        }
        let field = curStrAhead()
        fnKey.push(field)
        cpos = cpos + 2
        funcHead(false, 0, tr + 2)
        if isMethod {
          fnSelfArg[fnDepth] = true
        }
      } else {
        funcHead(false, 0, 0)
      }
    } else {
      perr = true
      perrMsg = "expected name after function"
    }
  } else if k == 4 && s == 9 {
    cpos = cpos + 1
    startUnit(2)
  } else if k == 4 && s == 17 {
    cpos = cpos + 1
    tmpA = bop.length()
    startUnit(4)
  } else if k == 4 && s == 18 {
    cpos = cpos + 1
    if curKind() == 3 {
      forName = curStr()
      forInit = -1
      forLimit = -1
      forStep = -1
      cpos = cpos + 1
      if curKind() == 4 && curSub() == 19 {
        // generic for with a single variable
        tmpNames.clear()
        tmpRegs.clear()
        tmpNames.push(forName)
        cpos = cpos + 1
        startUnit(15)
      } else if curKind() == 5 && curSub() == 16 {
        // more names follow: gather them one per step, then expect `in`
        tmpNames.clear()
        tmpRegs.clear()
        tmpNames.push(forName)
        cpos = cpos + 1
        stState = 21
      } else if curKind() == 5 && curSub() == 13 {
        cpos = cpos + 1
        startUnit(10)
      } else {
        perr = true
        perrMsg = "expected = or in for"
      }
    } else {
      perr = true
      perrMsg = "expected name after for"
    }
  } else if k == 4 && s == 20 {
    cpos = cpos + 1
    pushCtl(6, bop.length(), -1, -1, ctlLoop, 0, 0)
    ctlLoop = ctlKind.length() - 1
    blkEnter(true)
  } else if k == 4 && s == 3 {
    cpos = cpos + 1
    blkEnter(false)
    pushCtl(4, 0, 0, 0, 0, 0, 0)
  } else if k == 4 && s == 2 {
    cpos = cpos + 1
    if ctlLoop == -1 {
      perr = true
      perrMsg = "break outside loop"
    } else {
      let pos = bEmit(20, 0, 0, 0)
      plNext[pos] = ctlC[ctlLoop]
      ctlC[ctlLoop] = pos
    }
  } else if k == 4 && s == 14 {
    cpos = cpos + 1
    if atStmtEnd() {
      bEmit(26, 0, 0, 0)
    } else {
      startUnit(5)
    }
  } else if k == 3 {
    let nk = nextKind()
    let ns = nextSub()
    if nk == 5 && ns == 14 {
      startUnit(1)
    } else if nk == 2 {
      startUnit(1)
    } else if nk == 5 && (ns == 21 || ns == 23) {
      itBase.clear()
      itKey.clear()
      tmpRegs.clear()
      startUnit(8)
    } else if nk == 5 && (ns == 13 || ns == 16) {
      tmpNames.clear()
      tmpRegs.clear()
      tmpNames.push(curStr())
      cpos = cpos + 1
      if ns == 16 {
        cpos = cpos + 1
        stState = 11
      } else {
        cpos = cpos + 1
        startUnit(7)
      }
    } else {
      perr = true
      perrMsg = "not a call statement"
    }
  } else if k == 5 && s == 14 {
    startUnit(1)
  } else if k == 2 {
    startUnit(1)
  } else if k == 4 && s == 21 {
    if ctlTop() != 6 {
      perr = true
      perrMsg = "until without repeat"
    } else {
      cpos = cpos + 1
      // A repeat's body block is closed after this condition, so the bump that
      // gives each round its own cells goes here, in front of it: at the block
      // exit it would land outside the loop and run once.
      if blkCapGen[blkCapGen.length() - 1] != capGen {
        blkGenDone = true
        bEmit(49, 0, 0, 0)
      }
      startUnit(13)
    }
  } else if k == 4 && (s == 6 || s == 4 || s == 5) {
    doBlockClose()
  } else {
    perr = true
    perrMsg = "unexpected token at statement start"
  }
}

// One expression token in operator position. Returns true when the token
// was fully handled (no MicroOp follow-up needed beyond pops/closes).
mod exprPrefix() {
  let k = curKind()
  let s = curSub()
  if k == 5 && s == 32 {
    // '...': one value by default, all of them when the expression turns out to
    // be in tail position (patchAt rewrites B to 0).  In an argument list the
    // destination is the callee's argument slot, so the values land exactly
    // where the call expects them.
    if fnVar[fnDepth] {
      var dest = -1
      if opKind.length() > opBase[fnDepth] && opTopKind() == 2 {
        dest = opA[opA.length() - 1] + 1 + opB[opB.length() - 1]
      }
      if dest < 0 {
        dest = regAlloc()
      }
      let p = bEmit(45, dest, 1, 0)
      lastCallPos = p
      bumpMax(dest + 2)
      pushVal(dest, true, false)
      cpos = cpos + 1
      expectOperand = false
    } else {
      perr = true
      perrMsg = "cannot use '...' outside a variadic function"
    }
  } else if k == 1 {
    let r = regAlloc()
    bEmit(2, r, cNum(curNum()), s)
    pushVal(r, false, false)
    cpos = cpos + 1
    expectOperand = false
  } else if k == 2 {
    let r = regAlloc()
    bEmit(3, r, cStr(curStr()), 0)
    pushVal(r, false, false)
    cpos = cpos + 1
    expectOperand = false
  } else if k == 4 && s == 16 {
    let r = regAlloc()
    bEmit(4, r, 1, 0)
    pushVal(r, false, false)
    cpos = cpos + 1
    expectOperand = false
  } else if k == 4 && s == 7 {
    let r = regAlloc()
    bEmit(4, r, 0, 0)
    pushVal(r, false, false)
    cpos = cpos + 1
    expectOperand = false
  } else if k == 4 && s == 11 {
    let r = regAlloc()
    bEmit(1, r, 0, 0)
    pushVal(r, false, false)
    cpos = cpos + 1
    expectOperand = false
  } else if k == 3 && opTopKind() == 6 && opB[opB.length() - 1] == -1 && valStk.length() == opC[opC.length() - 1] && nextKind() == 5 && nextSub() == 13 {
    // name = value inside a table constructor
    let kr = regAlloc()
    bEmit(3, kr, cStr(curStr()), 0)
    opB[opB.length() - 1] = kr
    cpos = cpos + 2
  } else if k == 3 {
    let callParen = nextKind() == 5 && nextSub() == 14
    let callSugar = nextKind() == 2
    exprPushName(callParen, callSugar)
  } else if k == 5 && s == 14 {
    pushOp(3, -1, valStk.length(), 0, 0)
    cpos = cpos + 1
    expectOperand = true
  } else if k == 5 && s == 19 {
    let tr = regAlloc()
    bEmit(28, tr, 0, 0)
    pushOp(6, 0, tr, -1, valStk.length())
    openCtor = openCtor + 1
    cpos = cpos + 1
    expectOperand = true
  } else if k == 5 && s == 20 {
    closeMode = 4
    popMode = 2
  } else if k == 5 && s == 24 {
    pushOp(1, 6, 2, 0, valStk.length())
    cpos = cpos + 1
  } else if k == 5 && s == 15 {
    // ')' in prefix (empty call/group, trailing comma, or drain first)
    closeMode = 1
    popMode = 2
  } else if k == 5 && s == 2 {
    pushOp(1, 6, 0, 0, valStk.length())
    cpos = cpos + 1
  } else if k == 4 && s == 12 {
    pushOp(1, 6, 1, 0, valStk.length())
    cpos = cpos + 1
  } else if k == 5 && s == 27 {
    pushOp(1, 6, 38, 0, valStk.length())
    cpos = cpos + 1
    expectOperand = true
  } else if k == 4 && s == 8 {
    // anonymous function: suspend the expression, compile the body
    tmpS = ""
    let fid = newFunc()
    tmpB = fid
    let fr = regAlloc()
    bEmit(25, fr, fid, 0)
    cpos = cpos + 1
    funcHeadAnon(fr)
  } else if k == 5 && s == 21 && opTopKind() == 6 && opB[opB.length() - 1] == -1 && valStk.length() == opC[opC.length() - 1] {
    // [k] = v key inside a table constructor: parse the key expression,
    // the ']' close below stores it as this element's pending key
    pushOp(7, -1, 0, 0, valStk.length())
    cpos = cpos + 1
    expectOperand = true
  } else {
    perr = true
    perrMsg = "unexpected token in expression"
  }
}

mod doCont() {
  if contKind == 1 {
    if !presIsCall {
      perr = true
      perrMsg = "not a call statement"
    }
    regSync()
    inExpr = false
    contKind = 0
  } else if contKind == 2 {
    if curKind() != 4 || curSub() != 15 {
      perr = true
      perrMsg = "expected then"
    } else {
      cpos = cpos + 1
      let fp = bEmit(21, 0, presReg, 0)
      pushCtl(1, fp, -1, 0, 0, 0, 0)
      blkEnter(false)
    }
    inExpr = false
    contKind = 0
  } else if contKind == 3 {
    if curKind() != 4 || curSub() != 15 {
      perr = true
      perrMsg = "expected then"
    } else {
      cpos = cpos + 1
      let fp = bEmit(21, 0, presReg, 0)
      ctlA[ctlA.length() - 1] = fp
      blkEnter(false)
    }
    inExpr = false
    contKind = 0
  } else if contKind == 4 {
    if curKind() != 4 || curSub() != 3 {
      perr = true
      perrMsg = "expected do"
    } else {
      cpos = cpos + 1
      let fp = bEmit(21, 0, presReg, 0)
      pushCtl(2, tmpA, fp, -1, ctlLoop, 0, 0)
      ctlLoop = ctlKind.length() - 1
      blkEnter(true)
    }
    inExpr = false
    contKind = 0
  } else if contKind == 5 {
    if curKind() == 5 && curSub() == 16 {
      cpos = cpos + 1
      tmpRegs.clear()
      tmpRegs.push(presReg)
      startUnit(14)
    } else if presIsCall {
      // `return f()` forwards all of f's values, so let the call expand
      patchAt(presCallPos)
      bEmit(27, presReg, 0, 0)
      inExpr = false
      contKind = 0
    } else {
      bEmit(24, presReg, 0, 0)
      inExpr = false
      contKind = 0
    }
  } else if contKind == 14 {
    tmpRegs.push(presReg)
    if curKind() == 5 && curSub() == 16 {
      cpos = cpos + 1
      startUnit(14)
    } else {
      if tmpRegs.length() > 16 {
        perr = true
        perrMsg = "too many values"
      } else {
        // `return a, f()` returns f's values too, and how many there are is
        // only known at run time: RETURNM with a negative count returns that
        // many fixed values and then everything the call produced.  The call's
        // own register is left out of the copy below -- its result block can
        // overlap the block being built here.
        let n = if presIsCall then tmpRegs.length() - 1 else tmpRegs.length()
        // reserve the call's result window before allocating the return block,
        // or regAlloc can hand out a register the call is about to write
        if presIsCall { patchAt(presCallPos) }
        let br = regAlloc()
        if 1 < n {
          let r2 = regAlloc()
          if 2 < n {
            let r3 = regAlloc()
            if 3 < n {
              let r4 = regAlloc()
              if 4 < n {
                let r5 = regAlloc()
                if 5 < n {
                  let r6 = regAlloc()
                  if 6 < n {
                    let r7 = regAlloc()
                    if 7 < n {
                      let r8 = regAlloc()
                      if 8 < n {
                        let r9 = regAlloc()
                        if 9 < n {
                          let r10 = regAlloc()
                          if 10 < n {
                            let r11 = regAlloc()
                            if 11 < n {
                              let r12 = regAlloc()
                              if 12 < n {
                                let r13 = regAlloc()
                                if 13 < n {
                                  let r14 = regAlloc()
                                  if 14 < n {
                                    let r15 = regAlloc()
                                    if 15 < n {
                                      bEmit(7, br + 15, tmpRegs[15], 0)
                                    }
                                    bEmit(7, br + 14, tmpRegs[14], 0)
                                  }
                                  bEmit(7, br + 13, tmpRegs[13], 0)
                                }
                                bEmit(7, br + 12, tmpRegs[12], 0)
                              }
                              bEmit(7, br + 11, tmpRegs[11], 0)
                            }
                            bEmit(7, br + 10, tmpRegs[10], 0)
                          }
                          bEmit(7, br + 9, tmpRegs[9], 0)
                        }
                        bEmit(7, br + 8, tmpRegs[8], 0)
                      }
                      bEmit(7, br + 7, tmpRegs[7], 0)
                    }
                    bEmit(7, br + 6, tmpRegs[6], 0)
                  }
                  bEmit(7, br + 5, tmpRegs[5], 0)
                }
                bEmit(7, br + 4, tmpRegs[4], 0)
              }
              bEmit(7, br + 3, tmpRegs[3], 0)
            }
            bEmit(7, br + 2, tmpRegs[2], 0)
          }
          bEmit(7, br + 1, tmpRegs[1], 0)
        }
        if 1 <= n { bEmit(7, br, tmpRegs[0], 0) }
        if presIsCall {
          bEmit(42, br, 0 - n, presReg)
        } else {
          bEmit(42, br, n, 0)
        }
        inExpr = false
        contKind = 0
      }
    }
  } else if contKind == 6 {
    tmpRegs.push(presReg)
    if curKind() == 5 && curSub() == 16 {
      cpos = cpos + 1
      startUnit(6)
    } else {
      expandTailCall()
      tmpA = 0
      stState = 12
      inExpr = false
      contKind = 0
    }
  } else if contKind == 8 {
    // left-hand side unit of `t[k] = v` / `t.k = v`, or a call statement like t.f(x)
    if curKind() == 5 && (curSub() == 13 || curSub() == 16) {
      let li = bop.length() - 1
      if li >= 0 && bop[li] == 29 && bpa[li] == presReg && !presIsCall {
        let hiA = if bpb[li] > bpc[li] then bpb[li] else bpc[li]
        let hi = (if hiA > bpa[li] then hiA else bpa[li]) + 1
        if hi > cfNext[fnDepth] {
          cfNext[fnDepth] = hi
        }
        itBase.push(bpb[li])
        itKey.push(bpc[li])
        bop.pop()
        bpa.pop()
        bpb.pop()
        bpc.pop()
        if curSub() == 16 {
          cpos = cpos + 1
          if curKind() == 3 && nextKind() == 5 && (nextSub() == 21 || nextSub() == 23) {
            startUnit(8)
          } else {
            perr = true
            perrMsg = "assignment targets must all be table fields"
          }
        } else {
          cpos = cpos + 1
          startUnit(9)
        }
      } else {
        perr = true
        perrMsg = "cannot assign to this expression"
      }
    } else if presIsCall {
      inExpr = false
      contKind = 0
    } else {
      perr = true
      perrMsg = "not a call statement"
    }
  } else if contKind == 9 {
    tmpRegs.push(presReg)
    if curKind() == 5 && curSub() == 16 {
      cpos = cpos + 1
      startUnit(9)
    } else {
      // stores run right to left (like PUC Lua), so the last target wins
      tmpA = itBase.length() - 1
      stState = 15
      inExpr = false
      contKind = 0
    }
  } else if contKind == 15 {
    // Generic-for explist.  A trailing call supplies the whole triple
    // (ipairs(t) -> f, s, 0), so mark it to return everything and pad its own
    // result registers to three -- Lua fills a short explist with nil.  The
    // call's result window is already claimed by patchAt, so nothing else has
    // to be allocated here.
    tmpRegs.push(presReg)
    if curKind() == 5 && curSub() == 16 && tmpRegs.length() < 3 {
      cpos = cpos + 1
      startUnit(15)
    } else {
      if presIsCall {
        patchAt(presCallPos)
        bEmit(43, presReg + 1, presReg + 1, 2)
        tmpRegs.push(presReg + 1)
        tmpRegs.push(presReg + 2)
      }
      genForHead()
      inExpr = false
      contKind = 0
    }
  } else if contKind == 7 {
    if tmpNames.length() > 1 && !presIsCall {
      // right-to-left stores can overwrite a value register, so keep a copy.
      // A call needs no copy: expandTailCall relocates the extra results into
      // fresh registers before any store runs.
      let z = regAlloc()
      bEmit(7, z, presReg, 0)
      tmpRegs.push(z)
    } else {
      tmpRegs.push(presReg)
    }
    if curKind() == 5 && curSub() == 16 {
      cpos = cpos + 1
      startUnit(7)
    } else {
      expandTailCall()
      // stores run right to left (like PUC Lua), so the last target wins
      tmpA = tmpNames.length() - 1
      stState = 13
      inExpr = false
      contKind = 0
    }
  } else if contKind == 10 {
    // for-init value done: expect ',' then parse the limit
    forInit = presReg
    if curKind() == 5 && curSub() == 16 {
      cpos = cpos + 1
      startUnit(11)
    } else {
      perr = true
      perrMsg = "expected , in for"
      inExpr = false
      contKind = 0
    }
  } else if contKind == 11 {
    // for-limit value done: ',' + step, or 'do' with default step
    forLimit = presReg
    if curKind() == 5 && curSub() == 16 {
      cpos = cpos + 1
      startUnit(12)
    } else if curKind() == 4 && curSub() == 3 {
      forStep = -1
      forDoHead()
      inExpr = false
      contKind = 0
    } else {
      perr = true
      perrMsg = "expected , or do in for"
      inExpr = false
      contKind = 0
    }
  } else if contKind == 12 {
    // for-step value done: expect 'do'
    forStep = presReg
    if curKind() == 4 && curSub() == 3 {
      forDoHead()
    } else {
      perr = true
      perrMsg = "expected do in for"
    }
    inExpr = false
    contKind = 0
  } else if contKind == 13 {
    // repeat-until condition done: jump back while falsy, then leave scope
    let n = ctlKind.length() - 1
    if n < 0 || ctlKind[n] != 6 {
      perr = true
      perrMsg = "until without repeat"
    } else {
      bEmit(21, ctlA[n], presReg, 0)
      blkExit()
      tmpC = ctlD[n]
      pdHead = ctlC[n]
      pdThen = 1
      popCtl()
    }
    inExpr = false
    contKind = 0
  } else {
    inExpr = false
    contKind = 0
  }
  exprDone = false
}

// Shared anon head (fr already loaded above): skip, frame, depth, params.
mod exprInfix() {
  let k = curKind()
  let s = curSub()
  if k == 5 && s >= 1 && s <= 6 {
    let opc = if s == 1 then 8 else if s == 2 then 9 else if s == 3 then 10 else if s == 4 then 11 else if s == 5 then 12 else 13
    let prc = if s == 6 then 7 else if s <= 2 then 4 else 5
    let fl = if s == 6 then 0 else 1
    binArrive(opc, prc, fl)
    cpos = cpos + 1
    expectOperand = true
  } else if k == 5 && s == 18 {
    binArrive(16, 3, 0)
    cpos = cpos + 1
    expectOperand = true
  } else if k == 5 && s >= 7 && s <= 12 {
    let opc = if s == 7 || s == 8 then 18 else if s == 9 || s == 10 then 19 else 17
    let fl = if s == 8 || s == 10 then 3 else if s == 12 then 4 else if s == 7 || s == 9 then 1 else 0
    binArrive(opc, 2, fl)
    cpos = cpos + 1
    expectOperand = true
  } else if k == 5 && s == 30 {
    binArrive(34, 5, 1)
    cpos = cpos + 1
    expectOperand = true
  } else if k == 5 && s == 28 {
    binArrive(39, 6, 1)
    cpos = cpos + 1
    expectOperand = true
  } else if k == 5 && s == 29 {
    binArrive(40, 6, 1)
    cpos = cpos + 1
    expectOperand = true
  } else if k == 5 && s == 25 {
    binArrive(35, 5, 1)
    cpos = cpos + 1
    expectOperand = true
  } else if k == 5 && s == 27 {
    binArrive(37, 4, 1)
    cpos = cpos + 1
    expectOperand = true
  } else if k == 5 && s == 26 {
    binArrive(36, 3, 1)
    cpos = cpos + 1
    expectOperand = true
  } else if k == 4 && s == 1 {
    andOrArrive(false)
    cpos = cpos + 1
    expectOperand = true
  } else if k == 4 && s == 13 {
    andOrArrive(true)
    cpos = cpos + 1
    expectOperand = true
  } else if k == 5 && s == 14 {
    let fnr = popVal()
    regFree(fnr)
    let fr = regAlloc()
    bEmit(7, fr, fnr, 0)
    pushOp(2, -1, fr, 0, valStk.length())
    cpos = cpos + 1
    expectOperand = true
  } else if k == 2 {
    if !topPrefix() {
      perr = true
      perrMsg = "string call needs a prefix"
      return
    }
    let fnr = popVal()
    regFree(fnr)
    let fr = regAlloc()
    bEmit(7, fr, fnr, 0)
    let ar = regAlloc()
    bEmit(3, ar, cStr(curStr()), 0)
    bEmit(7, fr + 1, ar, 0)
    bEmit(23, fr, 1, 0)
    bumpMax(fr + 3)
    rewindTo(fr + 1)
    pushVal(fr, true, true)
    cpos = cpos + 1
    expectOperand = false
  } else if k == 5 && s == 15 {
    closeMode = 1
    popMode = 2
  } else if k == 5 && s == 16 {
    // ',' : arg boundary inside calls, else unit terminator (multi-value
    // RHS and juxtaposed statements are sequenced by the next level)
    closeMode = 2
    closeTrig = 1
    popMode = 2
  } else if k == 5 && s == 17 && openCtor > 0 {
    closeMode = 2
    closeTrig = 1
    popMode = 2
  } else if k == 5 && s == 21 {
    if topPrefix() {
      pushOp(7, -1, 0, 0, valStk.length())
      cpos = cpos + 1
      expectOperand = true
    } else {
      perr = true
      perrMsg = "unexpected ["
    }
  } else if k == 5 && s == 22 {
    closeMode = 5
    popMode = 2
  } else if k == 5 && s == 20 {
    closeMode = 4
    popMode = 2
  } else if k == 5 && s == 23 {
    if topPrefix() && nextKind() == 3 {
      let base = popVal()
      let kr = regAlloc()
      bEmit(3, kr, cStr(curStrAhead()), 0)
      regFree(kr)
      regFree(base)
      let res = regAlloc()
      bEmit(29, res, base, kr)
      pushVal(res, false, true)
      cpos = cpos + 2
    } else {
      perr = true
      perrMsg = "bad field access"
    }
  } else if k == 5 && s == 31 {
    // obj:m(args) is obj.m(obj, args): the receiver is already evaluated, so
    // it goes into the call's first argument slot and the arguments follow it
    if !topPrefix() || nextKind() != 3 {
      perr = true
      perrMsg = "bad method call"
      return
    }
    let recv = popVal()
    let kr = regAlloc()
    bEmit(3, kr, cStr(curStrAhead()), 0)
    cpos = cpos + 2
    if !(curKind() == 5 && curSub() == 14) {
      perr = true
      perrMsg = "expected ( after method name"
      return
    }
    let fr = regAlloc()
    bEmit(29, fr, recv, kr)
    bEmit(7, fr + 1, recv, 0)
    regFree(kr)
    // The receiver sits in the first argument slot, so that slot is live from
    // here: claim it before parsing the arguments, or an argument expression
    // gets the slot as a temporary and overwrites the receiver.
    bumpMax(fr + 2)
    pushOp(9, -1, fr, 1, valStk.length())
    cpos = cpos + 1
    expectOperand = true
  } else if k == 6 || (k == 5 && s == 17) || (k == 4 && (s == 6 || s == 4 || s == 5 || s == 21)) || (k == 5 && s == 13) || (k == 4 && (s == 3 || s == 15)) {
    closeMode = 3
    popMode = 2
  } else if k == 3 || (k == 4 && (s == 10 || s == 8 || s == 9 || s == 17 || s == 18 || s == 20 || s == 3 || s == 2 || s == 14)) {
    // NAME or statement-start keyword: drain, then terminate the unit;
    // validity (call-statement vs stored value) is checked by doCont
    closeMode = 2
    closeTrig = 0
    popMode = 2
  } else {
    perr = true
    perrMsg = "unexpected token in expression"
  }
}

// One expression micro-op: a pop, a close, or a token action.
mod closeAction() {
  if closeMode == 1 {
    // ')' close: top must be a call or group marker
    let mk = opTopKind()
    if mk == 2 || mk == 9 {
      // kind 9 is a method call: obj:m(a) is obj.m(obj, a), so the receiver
      // already sits in the first argument slot and nargs counts from there
      let isMethod = mk == 9
      let fr = opA[opA.length() - 1]
      // a method call starts its count at one: the receiver is argument one
      let nargs = opB[opB.length() - 1]
      let depth = opC[opC.length() - 1]
      opKind.pop()
      opPrec.pop()
      opA.pop()
      opB.pop()
      opC.pop()
      if valStk.length() == depth {
        if nargs == 0 && !isMethod {
          let p = bEmit(23, fr, 0, 0)
          lastCallPos = p
          bumpMax(fr + 2)
          rewindTo(fr + 1)
        } else if isMethod && nargs == 1 {
          // obj:m() with no arguments: the receiver is already the first one
          let p = bEmit(23, fr, 1, 0)
          lastCallPos = p
          bumpMax(fr + 3)
          rewindTo(fr + 1)
        } else {
          perr = true
          perrMsg = "trailing comma"
        }
      } else {
        // TEMP DEBUG: what is on the value stack at a call's close
        let wasCall = topFlag()
        let arg = popVal()
        let dst = fr + 1 + nargs
        if wasCall {
          bEmit(7, dst, arg, 0)
          bEmit(43, arg + 1, dst + 1, MAXVALS - 1)
          bumpMax(dst + MAXVALS)
          patchMultiTail()
        } else {
          bEmit(7, dst, arg, 0)
        }
        cfNext[fnDepth] = dst + 1
        let p = bEmit(23, fr, nargs + 1, if wasCall then 1 else 0)
        lastCallPos = p
        bumpMax(fr + nargs + 3)
        rewindTo(fr + 1)
      }
      pushVal(fr, true, true)
      cpos = cpos + 1
      expectOperand = false
      closeMode = 0
    } else if mk == 3 {
      let depth = opA[opA.length() - 1]
      opKind.pop()
      opPrec.pop()
      opA.pop()
      opB.pop()
      opC.pop()
      if valStk.length() == depth {
        perr = true
        perrMsg = "empty parentheses"
      } else {
        setTopFlag(false)
        setTopPrefix(true)
      }
      cpos = cpos + 1
      expectOperand = false
      closeMode = 0
    } else {
      perr = true
      perrMsg = "unbalanced )"
    }
  } else if closeMode == 2 {
    // ',' arg boundary (with call marker) or plain unit terminator.
    // Terminated units are validated by doCont / the statement level.
    let mk = opTopKind()
    // A comma is an argument boundary or a table element only for a marker that
    // this function opened: inside a function body the enclosing call's marker is
    // still on the stack, and a comma there belongs to the body's own return
    // list.  Both tests were on the bare kind, so `pcall(function() return 1, 2
    // end)` spent the body's comma as pcall's second argument.
    if closeTrig == 1 && (mk == 2 || mk == 9) && opKind.length() > opBase[fnDepth] {
      let fr = opA[opA.length() - 1]
      let nargs = opB[opB.length() - 1]
      let depth = opC[opC.length() - 1]
      if valStk.length() == depth {
        perr = true
        perrMsg = "expected argument"
      } else {
        let arg = popVal()
        bEmit(7, fr + 1 + nargs, arg, 0)
        cfNext[fnDepth] = fr + nargs + 2
        opB[opB.length() - 1] = nargs + 1
        // another argument follows, so a call just consumed here is not in
        // tail position and yields exactly one value
        lastCallPos = -1
      }
      cpos = cpos + 1
      expectOperand = true
      closeMode = 0
    } else if closeTrig == 1 && mk == 6 && opKind.length() > opBase[fnDepth] {
      if valStk.length() == opC[opC.length() - 1] {
        perr = true
        perrMsg = "expected table element"
      } else {
        finishCtorElem(false)
      }
      cpos = cpos + 1
      expectOperand = true
      closeMode = 0
    } else if opKind.length() > opBase[fnDepth] {
      // A separator is misplaced when a marker opened *in this expression* is
      // still open.  The base matters: inside a function body the call and
      // group markers of the expression that holds the literal are still on the
      // stack, and they are not this comma's business.  The check was the bare
      // length, so `(function() return 1, 2 end)()` reported the body's comma.
      perr = true
      perrMsg = "misplaced separator"
    } else if valStk.length() == 0 {
      perr = true
      perrMsg = "missing expression"
    } else {
      presIsCall = topFlag()
      presCallPos = if presIsCall then lastCallPos else -1
      presReg = popVal()
      exprDone = true
      closeMode = 0
    }
  } else if closeMode == 3 {
    // expression terminator: drain must be complete, no markers left
    // above this function's entry depth (outer suspended frames are fine)
    if opKind.length() > opBase[fnDepth] {
      perr = true
      perrMsg = "unbalanced ("
    } else if valStk.length() == 0 {
      perr = true
      perrMsg = "missing expression"
    } else {
      presIsCall = topFlag()
      presCallPos = if presIsCall then lastCallPos else -1
      presReg = popVal()
      lastCallPos = -1
      exprDone = true
      closeMode = 0
    }
  } else if closeMode == 4 {
    // '}' close: finish the last element, then leave the table as the value
    if opTopKind() == 6 {
      if valStk.length() > opC[opC.length() - 1] {
        finishCtorElem(true)
      } else if opB[opB.length() - 1] != -1 {
        perr = true
        perrMsg = "expected value after ="
      }
      let tr = opA[opA.length() - 1]
      opKind.pop()
      opPrec.pop()
      opA.pop()
      opB.pop()
      opC.pop()
      pushVal(tr, false, false)
      openCtor = openCtor - 1
      cpos = cpos + 1
      expectOperand = false
      closeMode = 0
    } else {
      perr = true
      perrMsg = "unbalanced }"
    }
  } else if closeMode == 5 {
    // ']' close: base and key are on valStk, or (directly under a table
    // constructor with no pending key) just the [k] = v key
    if opTopKind() == 7 {
      let depth = opC[opC.length() - 1]
      let belowCtor = opKind.length() >= 2 && opKind[opKind.length() - 2] == 6
      let ctorKey = belowCtor && opB[opB.length() - 2] == -1 && valStk.length() == opC[opC.length() - 2] + 1
      if ctorKey {
        let key = popVal()
        opKind.pop()
        opPrec.pop()
        opA.pop()
        opB.pop()
        opC.pop()
        opB[opB.length() - 1] = key
        cpos = cpos + 1
        if curKind() == 5 && curSub() == 13 {
          cpos = cpos + 1
          expectOperand = true
        } else {
          perr = true
          perrMsg = "expected = after [key]"
        }
        closeMode = 0
      } else {
        opKind.pop()
        opPrec.pop()
        opA.pop()
        opB.pop()
        opC.pop()
        if valStk.length() != depth + 1 {
          perr = true
          perrMsg = "bad index expression"
        } else {
          let key = popVal()
          let base = popVal()
          regFree(key)
          regFree(base)
          let res = regAlloc()
          bEmit(29, res, base, key)
          pushVal(res, false, true)
        }
        cpos = cpos + 1
        expectOperand = false
        closeMode = 0
      }
    } else {
      perr = true
      perrMsg = "unbalanced ]"
    }
  }
}

mod exprMicro() {
  if !perr {
    if popMode != 0 {
      let tk0 = opTopKind()
      var poppable = false
      var popValid = true
      if tk0 == 0 || tk0 == 1 || tk0 == 4 || tk0 == 5 {
        if valStk.length() <= opC[opC.length() - 1] {
          popValid = false
        } else if popMode == 2 {
          poppable = true
        } else {
          let tp = opPrec[opPrec.length() - 1]
          if tp > popPrec {
            poppable = true
          } else if tp == popPrec && popIsLeft(tk0) {
            poppable = true
          }
        }
      }
      if !popValid {
        perr = true
        perrMsg = "missing operand"
      } else if poppable {
        applyPop()
      } else {
        popMode = 0
        if pendKind != -1 {
          pushPending()
        } else if closeMode != 0 {
          closeAction()
        }
      }
    } else if closeMode != 0 {
      closeAction()
    } else if expectOperand {
      exprPrefix()
    } else {
      exprInfix()
    }
  }
}

// An error inside a pcall is a value, not the end of the program.  vmFailed is
// set either way, because the arms that check it after a possible failure must
// not go on to do the work that failed -- pcallStep clears it when it hands the
// message over.
mod vmFail(msg: string) {
  vmFailed = true
  pcallBad[0] = 1
  if pcallDepth > 0 {
    pcallMsg = msg
    pcallUnwind = true
  } else {
    errV = msg
    vmHalted = true
  }
}

// PUC's bitwise message names the FIRST operand that is not an integer -- the
// left one when that is the bad one, the right otherwise -- and the five checks
// that used to raise a bare "attempt to perform 'bitwise'" all want that one
// answer, so it is built here.  It is called for every bitwise op, so with two
// good operands it does nothing.  PUC adds "(constant 'x')" when the operand is
// a literal; the chip knows the register but not that it came from a literal, so
// that note is the one part of these messages that stays.
mod bitFail(lt: int, lv: float, rt: int, rv: float) {
  if lt != 6 && !(lt == 1 && lv == floor(lv)) {
    vmFail("attempt to perform bitwise operation on a " .. typeName(lt)
      .. " value")
  } else if rt != 6 && !(rt == 1 && rv == floor(rv)) {
    vmFail("attempt to perform bitwise operation on a " .. typeName(rt)
      .. " value")
  }
}

mod pcallEnter() {
  let cid = pcallFid
  let inner = if cid < cloBase then cid else cloF[cid]
  let a = pcallA
  let a1 = if 1 < pcallNArgs then pcallNArgs - 1 else 0
  let base = pcallBase
  // A protected call's frame starts one past its own register, so the true
  // survives under it.  A message handler's starts *at* its register: the
  // false is there already and its results belong there.
  let nbase = if pcallMode == 0 then base + a + 1 else base + a
  let np = fParams[inner]
  let nslots = 3 * fUpSlotN[inner] + 1
  let argSrc = if pcallMode != 0 then nbase else if pcallIsX then base + a + 3 else base + a + 2
  if 8 < np {
    vmFail("too many parameters")
  } else if vaTop + nslots > MAX_VA {
    // The vararg stack is what runs out, not the cell arena: a cell is three
    // words of it, so MAX_VA/3 binds long before MAX_CELL (1024) does.  Saying
    // which one is the difference between a message a reader can act on and one
    // that points at the wrong arena.
    vmFail("too many captured locals live at once")
  } else if vaTop + nslots + (if fVar[inner] && np < a1 then a1 - np else 0) > MAX_VA {
    vmFail("too many varargs")
  } else {
    // the parameters land in the new frame from one past the pcall's own
    // register, and retAdjust's nil-fill is what a missing argument is
    retAdjust(argSrc, nbase, a1, np)
    let nva = if fVar[inner] && np < a1 then a1 - np else 0
    frameSeq = frameSeq + 1
    let slotB = vaTop
    vaNum[slotB] = frameSeq
    vaSpill(nbase + np, slotB + nslots, nva)
    fVaB.push(slotB + nslots)
    vaTop = slotB + nslots + nva
    fFunc.push(cid)
    fBase.push(nbase)
    if pcallMode == 0 {
      fRetA.push(a + 1)
    } else {
      // a message handler's results go where its own register is: the false is
      // already there and there is no true to step over
      fRetA.push(a)
    }
    fRetBase.push(base)
    fRetPC.push(vmPc + 1)
    fRetN.push(-2)
    fForDepth.push(forDepth)
    vmBase = nbase
    vmPc = fStart[inner]
  }
}

mod numArg(t: int, v: float) -> float {
  if t != 1 && t != 6 && t != 0 {
    vmFail("bad argument (number expected)")
  }
  return if t == 0 then 0.0 else v
}

mod fmtConvInt() {
  fmtArgI = fmtArgI + 1
  let ab = fmtArgAt()
  if fmtArgI > fmtArgs {
    vmFail("bad argument #" .. fmtArgName() .. " to 'format' (no value)")
  } else {
    let t = vtag[ab]
    if t != 1 && t != 6 {
      vmFail("bad argument #" .. fmtArgName() .. " to 'format' (number expected, got "
             .. typeName(t) .. ")")
    } else if vnum[ab] != floor(vnum[ab]) {
      vmFail("number has no integer representation")
    } else {
      fmtNeg = vnum[ab] < 0.0
      fmtNum_ = if fmtNeg then 0.0 - vnum[ab] else vnum[ab]
      fmtBody = ""
      fmtState = 7
    }
  }
}

// %x %X %o.  A negative value is converted as its 64-bit two's complement, so
// the digit loop divides with floor and is bounded by a digit count instead of
// running until the quotient reaches zero -- the floor of a negative never does.
// 16 digits for hex, 22 for octal, which is what makes %x of -1 come out as
// ffffffffffffffff and %o of -1 as 1777777777777777777777.
mod fmtConvRadix() {
  fmtArgI = fmtArgI + 1
  let ab = fmtArgAt()
  if fmtArgI > fmtArgs {
    vmFail("bad argument #" .. fmtArgName() .. " to 'format' (no value)")
  } else {
    let t = vtag[ab]
    if t != 1 && t != 6 {
      vmFail("bad argument #" .. fmtArgName() .. " to 'format' (number expected, got "
             .. typeName(t) .. ")")
    } else if vnum[ab] != floor(vnum[ab]) {
      vmFail("number has no integer representation")
    } else {
      if fmtCh == "o" {
        fmtBase_ = 8.0
        fmtBaseI = 8
      } else {
        fmtBase_ = 16.0
        fmtBaseI = 16
      }
      if fmtCh == "X" {
        fmtUpper = true
      } else {
        fmtUpper = false
      }
      fmtNeg = vnum[ab] < 0.0
      fmtNum_ = vnum[ab]
      fmtDigits = 0
      fmtBody = ""
      if fmtNeg {
        // 64 bits is 16 hex digits exactly but 21 and a bit in octal, and the
        // top octal digit is bit 63: %o of -1 is 1 followed by 21 sevens, not 22
        // sevens.  Hex needs no leading digit; 16 divisions cover all 64 bits,
        // and the octal one goes in front of the digits at the end (they are
        // prepended as they come, so a leading 1 written here would end up last).
        if fmtCh == "o" {
          fmtDigitsMax = 21
        } else {
          fmtDigitsMax = 16
        }
      } else {
        fmtDigitsMax = 0
      }
      fmtState = 7
    }
  }
}

// %c: the low byte of the argument, because C's sprintf("%c", n) takes the low
// byte of an int -- 256 is a NUL and -1 is 0xFF.  Width and - are allowed (the
// spec check handles the rest).
mod fmtConvChar() {
  fmtArgI = fmtArgI + 1
  let ab = fmtArgAt()
  if fmtArgI > fmtArgs {
    vmFail("bad argument #" .. fmtArgName() .. " to 'format' (no value)")
  } else {
    let t = vtag[ab]
    if t != 1 && t != 6 {
      vmFail("bad argument #" .. fmtArgName() .. " to 'format' (number expected, got "
             .. typeName(t) .. ")")
    } else if vnum[ab] != floor(vnum[ab]) {
      vmFail("number has no integer representation")
    } else {
      fmtQ_ = toInt(vnum[ab] / 256.0)
      let r = toInt(vnum[ab] - fmtQ_ * 256.0)
      if r < 0 {
        fmtD_ = r + 256
      } else {
        fmtD_ = r
      }
      fmtBody = FromCharCode(fmtD_).Character
      fmtPre = ""
      fmtState = 6
    }
  }
}

mod fmtConvG() {
  fmtArgI = fmtArgI + 1
  let ab = fmtArgAt()
  if fmtArgI > fmtArgs {
    vmFail("bad argument #" .. fmtArgName() .. " to 'format' (no value)")
  } else {
    let t = vtag[ab]
    if t != 1 && t != 6 {
      vmFail("bad argument #" .. fmtArgName() .. " to 'format' (number expected, got "
             .. typeName(t) .. ")")
    } else {
      fmtNeg = vnum[ab] < 0.0
      if fmtNeg {
        fmtV = 0.0 - vnum[ab]
      } else {
        fmtV = vnum[ab]
      }
      // a precision of zero means one, which is C's rule and PUC's
      fmtP = if fmtPrec < 0 then 6 else if fmtPrec == 0 then 1 else fmtPrec
      fmtG0 = fmtP
      // and the mantissa is read at one place fewer, whichever arm it ends up
      // in: both spend a digit on a leading zero or a point
      fmtP = fmtG0 - 1
      fmtInt = ""
      fmtFr = ""
      fmtExp = ""
      fmtSticky = false
      fmtIsG = true
      fmtStrip = if fmtHash == 1 then false else true
      fmtGToExp = false
      if fmtV == 0.0 {
        fmtBody = if fmtNeg then "-0" else "0"
        fmtPre = ""
        fmtState = 6
      } else if 14 < fmtP {
        vmFail("precision above 14 cannot be formatted exactly on this chip")
      } else if 9007199254740992.0 <= fmtV {
        vmFail("number too large to format exactly on this chip")
      } else {
        fmtIP = floor(fmtV)
        fmtNz = 0
        fmtLz = -1
        fmtDd[0] = fmtV - floor(fmtV)
        fmtDd[1] = 0.0
        fmtNxt = 21
        fmtState = 20
      }
    }
  }
}

// The entry, as %f's: the argument, the sign, the precision.  14 is the ceiling
// and not an arbitrary one -- the mantissa is p+1 digits read as one integer,
// and ten of them is past 2^53.
mod fmtConvExp() {
  fmtArgI = fmtArgI + 1
  let ab = fmtArgAt()
  if fmtArgI > fmtArgs {
    vmFail("bad argument #" .. fmtArgName() .. " to 'format' (no value)")
  } else {
    let t = vtag[ab]
    if t != 1 && t != 6 {
      vmFail("bad argument #" .. fmtArgName() .. " to 'format' (number expected, got "
             .. typeName(t) .. ")")
    } else {
      fmtNeg = vnum[ab] < 0.0
      if fmtNeg {
        fmtV = 0.0 - vnum[ab]
      } else {
        fmtV = vnum[ab]
      }
      fmtP = if fmtPrec < 0 then 6 else fmtPrec
      fmtInt = ""
      fmtFr = ""
      // every one of these is per conversion, not per program: fmtExp left over
      // from the last one is why two %e in a print gave e+00000
      fmtExp = ""
      fmtSticky = false
      fmtIsG = false
      fmtUpperE = fmtCh == "E"
      if fmtV == 0.0 {
        // 0 is 0.000000e+00 whatever the precision, and the exponent is a
        // positive zero however the value was signed
        fmtBody = (if fmtNeg then "-0" else "0")
        if 0 < fmtP {
          fmtBody = fmtBody .. "." .. ZEROS16.Substring(0, fmtP)
        }
        fmtBody = fmtBody .. (if fmtUpperE then "E+000" else "e+000")
        fmtPre = ""
        fmtState = 6
      } else if 14 < fmtP {
        vmFail("precision above 14 cannot be formatted exactly on this chip")
      } else if 9007199254740992.0 <= fmtV {
        vmFail("number too large to format exactly on this chip")
      } else {
        fmtIP = floor(fmtV)
        fmtNz = 0
        fmtLz = -1
        // The walk below multiplies whatever pair it finds, so the fraction has
        // to be in it before the first state, and it has to be written into
        // fmtDd directly: a var this state writes is not what a later line of
        // the same state reads, so every fraction digit of 1.5 came out 0.
        fmtDd[0] = fmtV - floor(fmtV)
        fmtDd[1] = 0.0
        fmtNxt = 21
        fmtState = 20
      }
    }
  }
}

// Whether the walk goes on, in a state of its own.  A value of a hundred or
// more has all its significant digits in the integer part, so it only has to
// reach the round digit: p+2 digits less the ones already there.  Below one it
// has to get past the leading zeros first, which it cannot know until the first
// nonzero turns up.  The test cannot live at the end of the walk's own chain:
// there it is a nested if under a mod call, and the state write in it is
// dropped, so the walk never stopped and %.2e of 0.000123 ran until the ticks
// ran out.
mod fmtEFracMore() {
  if 16 <= fmtNz {
    // The double-double carries about sixteen fraction digits exactly and the
    // walk has not found a nonzero one in that many, so the value's first
    // significant digit is further down than the digits are the value's own.
    // Without this the walk never ends: %.2e of 1e-300 ran until the ticks ran
    // out, and a value that cannot be converted should say so.
    vmFail("value too small to format exactly on this chip")
  } else if fmtInt == "" {
    if fmtLz < 0 || fmtNz < fmtLz + fmtP + 2 {
      fmtState = 21
    } else {
      fmtState = 23
    }
  } else {
    if fmtNz < fmtP + 2 - fmtInt.Length() {
      fmtState = 21
    } else {
      fmtState = 23
    }
  }
}

// The entry: the argument, the sign, and the precision.  15 is the ceiling and
// not an arbitrary one -- 10^15 is the last power of ten a double holds
// exactly, and the double-double carries 53 bits of guard beyond it, so a
// precision past that would be rounding a number that is not the value.
// %e and %g, and why they are not here yet.  %f needed a double-double because
// it scales by the precision; %e cannot do that at all, because the mantissa is
// the value divided by 10^k and no division by ten is exact -- 1/10 is not even
// representable.  So the work is a digit stream instead, and the shape it takes
// is settled:
//
//   - the integer part's digits come off fmtFNDigits as they do here, and the
//     fraction's come off a dd multiplied by ten per digit, which is exact for
//     about fifteen of them and not the sixteenth -- so a value whose first
//     significant digit is further down than that is a range error, the same
//     kind as the two limits above.
//   - the two digit runs join into one string with the point's index beside
//     them, the first nonzero digit gives the exponent (index - (index of the
//     point) + 1), and the mantissa is the p+1 digits from there read as one
//     integer, so a carry out of them is +1 on the exponent rather than a walk
//     back through the digits.
//   - the rounding is the same two-half test as %f's, on the digit after the
//     mantissa, with the dd's leftover as the sticky bit.  That leftover is why
//     the fraction is extracted to exactly one digit past the round position:
//     one more and the sticky needs a scan of the string, one fewer and the last
//     digit read is a rounded one.
//   - the multiply and the digit read cannot share a state, for the reason above,
//     so it is two states and about thirty ticks per conversion's fraction.
//   - %g is %e and %f chosen by the exponent (e when it is below -4 or at least
//     the precision, f otherwise, at p-1-k places), with trailing zeros dropped
//     unless # is given and a precision of 0 read as 1.  The trailing-zero strip
//     is one more one-character-per-tick state.
//
// tools/fmt/fmtsweep.py takes the conversion letter as its second argument, so
// `python -u tools/fmt/fmtsweep.py 64 e` is the same check for %e when it lands.
mod fmtConvFloat() {
  fmtArgI = fmtArgI + 1
  let ab = fmtArgAt()
  if fmtArgI > fmtArgs {
    vmFail("bad argument #" .. fmtArgName() .. " to 'format' (no value)")
  } else {
    let t = vtag[ab]
    if t != 1 && t != 6 {
      vmFail("bad argument #" .. fmtArgName() .. " to 'format' (number expected, got "
             .. typeName(t) .. ")")
    } else {
      fmtNeg = vnum[ab] < 0.0
      if fmtNeg {
        fmtV = 0.0 - vnum[ab]
      } else {
        fmtV = vnum[ab]
      }
      fmtP = if fmtPrec < 0 then 6 else fmtPrec
      fmtInt = ""
      fmtFr = ""
      fmtIsG = false
      if fmtV == 0.0 {
        fmtState = 17
      } else if 15 < fmtP {
        vmFail("precision above 15 cannot be formatted exactly on this chip")
      } else if 9007199254740992.0 <= fmtV {
        vmFail("number too large to format exactly on this chip")
      } else {
        fmtState = 15
      }    }
  }
}

// Round the scaled fraction to its p digits, ties to even, and let a carry out
// of the fraction bump the integer part.  The decision reads the two halves
// separately, because that is the only way to see the difference: hi - fl is
// exact, so `rh == 0.5` says the high half is exactly a half and the low half
// says which side of it the value is on.  0.05 at one place is the case that
// needs it -- the high half is 0.5 and the low half is 2.8e-17, so it is a hair
// above the tie and PUC prints 0.1, not 0.0.
mod fmtFRound() {
  let fl = floor(fmtDd[0])
  let rh = fmtDd[0] - fl
  // Which digit the tie looks at is the last one the conversion keeps, and with
  // no precision there are no fraction digits to keep: it is the units digit of
  // the integer part.  Taking the fraction's instead made every %.0f tie round
  // down, so 1.5 came out 1 where PUC has 2.
  let last = if 0 < fmtP then fl else fmtIP - floor(fmtIP / 10.0) * 10.0
  let odd = last - floor(last / 2.0) * 2.0
  fmtF = if rh > 0.5 then fl + 1.0 else if rh < 0.5 then fl
    else if fmtDd[1] > 0.0 then fl + 1.0 else if fmtDd[1] < 0.0 then fl
    else if odd == 1.0 then fl + 1.0 else fl
  // 9.999 at three places rounds to 10.000: the fraction carries into the
  // integer part, which is an exact add while it is below 2^53.  The limit is
  // the precision's own 10^p -- fixed at 10^15 it never fired, and %.2f of 9.999
  // came out 9.999 with a point in it.
  if 10.0 ** (fmtP + 0.0) <= fmtF {
    fmtF = 0.0
    fmtIP = fmtIP + 1.0
  }
  if 9007199254740992.0 <= fmtIP {
    vmFail("number too large to format exactly on this chip")
  } else {
    fmtFr = ""
    fmtNxt = 17
    fmtState = 16
  }
}

mod patError() {
  nxActive = false
  vmFail(patErr)
}

// One table store from raw values; false means the store failed (error already
// raised).  Shared by SETFIELD and by TAPPEND's unrolled ladder, so it is
// inlined seventeen times and anything added here is added seventeen times.
//
// A nil value leaves the key's slot in place as a tombstone, which is PUC's own
// shape: PUC keeps a nil-valued key in the node, so next(t, k) still finds k
// after t[k] = nil and pairs() still walks past it.  Re-assigning the key then
// revives that same slot, at the same place in the chain.
//
// What the tombstone cannot do is stay on the free list, because the delete put
// it there: the list's next pop would hand the slot to an unrelated new key and
// unhook it from here, and the key would stop existing with no error and no
// wrong value anywhere -- it would just read nil.  So a revive takes its entry
// OFF the list: either the list hands this very slot back (off the list, in its
// own place, nothing else to do) or the value goes into the entry the list does
// hand back and the tombstone is left dead, unlinked, and still on the list
// where a dead slot belongs.
mod tblSetKey(tid: int, kt: int, kn: float, ks: string, vt: int, vn: float, vs: string) -> bool {
  let key = tkey(tid, kt, kn, ks)
  let r = tmap.get(key)
  let kint = toInt(kn)
  // sl is the entry to write into, or -1 for one that has to be allocated.  A
  // revive leaves the tombstone behind and takes a fresh entry for it.
  var sl = -1
  var revived = false
  var old = -1
  if r.Found {
    if vt == 0 {
      if tvTag[r.Value] != 0 {
        tvTag[r.Value] = 0
        tFree.push(r.Value)
        // Deleting an array element moves the border to just before it, for ANY
        // key at or below the border and not only for the border itself: PUC's
        // # is the first nil minus one, so {1,2,3} with t[2] = nil is 1 and
        // t[1] = nil is 0.  A key ABOVE the border leaves it alone, which is why
        // filling the hole afterwards grows it again.
        if kt == 6 && kint <= tLen[tid] {
          tLen[tid] = kint - 1
        }
      }
      // A delete is finished here.  It must NOT fall through to the allocation
      // below: that would pop the slot this line just pushed and re-link it,
      // which leaves the key in the table and the free list empty, so the table
      // never shrinks and nothing is ever recycled.
      return true
    } else if tvTag[r.Value] == 0 {
      old = r.Value
      revived = true
    } else {
      sl = r.Value
    }
  } else if vt != 0 {
    // a key the table does not have yet
  } else {
    // assigning nil to a missing key does nothing
    return true
  }
  if sl < 0 {
    if tFree.length() > 0 {
      sl = tFree.pop().Value
      if tNext[sl] != -2 {
        // a dead slot still chained in the table it died in: unhook it and drop
        // the stale map entry, because the map is what a read goes through
        let ot = tOwner[sl]
        tblUnlink(ot, sl)
        tmap.remove(tkey(ot, tKeyTag[sl], tKeyNum[sl], tKeyStr[sl]))
      }
    } else if tHeap < MAX_HEAP {
      sl = tHeap
      tHeap = tHeap + 1
    } else {
      // toInt for the same reason as the tables message: the folder turns the
      // bare const into a float literal and the message reads "512.0"
      let cap = toInt(MAX_HEAP + 0.0)
      vmFail("out of table memory (" .. (cap | 0) .. " entries; "
        .. "assign nil to a key to free one)")
      return false
    }
    tOwner[sl] = tid
    tKeyTag[sl] = kt
    tKeyNum[sl] = kn
    tKeyStr[sl] = ks
    if revived {
      // sl == old is the easy case, the list handing back the very tombstone;
      // otherwise the new entry takes the tombstone's place in the chain, so
      // pairs() still walks the key where PUC walks it.  Unlink first and
      // splice into the gap it leaves: splicing across a neighbour that IS the
      // new entry would point a chain entry at itself.
      if sl != old {
        let pv = tPrev[old]
        let nx = tNext[old]
        tblUnlink(tid, old)
        tblSplice(tid, sl, pv, nx)
      }
    } else {
      tblLink(tid, sl)
    }
    tmap.set(key, sl)
  }
  tvTag[sl] = vt
  tvNum[sl] = vn
  tvStr[sl] = vs
  if kt == 6 && kint == tLen[tid] + 1 {
    tLen[tid] = kint
    if tblHas(tid, kint + 1) {
      lenChase = true
      lenTid = tid
    }
  }
  return true
}

// %s and %q.  %q quotes a string and leaves everything else as %s does, which
// is why the tag is tested here rather than in the walk.
mod fmtConvStr(c: string) {
  fmtArgI = fmtArgI + 1
  let ab = fmtArgAt()
  if fmtArgI > fmtArgs {
    vmFail("bad argument #" .. fmtArgName() .. " to 'format' (no value)")
  } else {
    let t = vtag[ab]
    fmtArg = fmtVal(t, vnum[ab], vstr[ab])
    if c == "q" && t == 2 {
      fmtBody = "\""
      fmtQPos = 0
      fmtState = 11
    } else {
      fmtBody = fmtArg
      if 0 <= fmtPrec && fmtPrec < fmtBody.Length() {
        fmtBody = fmtBody.Substring(0, fmtPrec)
      }
      fmtPre = ""
      fmtState = 6
    }
  }
}

// The subject and the pattern out of a call's own registers, with find's two
// argument checks, shared by the matcher's gate and by gmatch's constructor so
// the two cannot drift apart.  off is where the subject sits: _pat takes a mode
// first, so its subject is the second argument, while _gmatch's is the first.
// Only the arguments actually passed are read: a register past nargs still
// holds the caller's previous call, and a find whose init came from there is a
// find with a boolean init.
mod patCheck(a: int, nargs: int, nm: string, off: int) -> bool {
  let st = if nargs < off then 0 else vTag(a + off)
  let pt = if nargs < off + 1 then 0 else vTag(a + off + 1)
  if nargs < off {
    vmFail("bad argument #1 to '" .. nm .. "' (string expected, got no value)")
    return false
  } else if st == 2 {
    patSrc = vStr(a + off)
  } else if st == 1 || st == 6 {
    patSrc = fmtVal(st, vNum(a + off), vStr(a + off))
  } else {
    vmFail("bad argument #1 to '" .. nm .. "' (string expected, got " .. typeName(st) .. ")")
    return false
  }
  if nargs < off + 1 {
    vmFail("bad argument #2 to '" .. nm .. "' (string expected, got no value)")
    return false
  } else if pt == 2 {
    patPat = vStr(a + off + 1)
  } else if pt == 1 || pt == 6 {
    patPat = fmtVal(pt, vNum(a + off + 1), vStr(a + off + 1))
  } else {
    vmFail("bad argument #2 to '" .. nm .. "' (string expected, got " .. typeName(pt) .. ")")
    return false
  }
  return true
}

// The cell, made if this frame and this round have not made it yet, then
// filled from the local's own register.  The register is the local's home --
// code compiled before the capture was noticed still reads and writes it --
// and SETUP writes both, so copying here is what makes a capture from inside a
// loop, and one that comes after a write, read the value PUC would.
mod cellAt(fid: int, k: int) -> int {
  let s = slotBase() + 3 * fUpSlot[fid * MAX_UP + k]
  var cell = toInt(vaNum[s])
  // The round stamp is checked ONLY for a local declared inside a loop body.  A
  // cell lives as long as the block that declared its local, and a local declared
  // outside every loop is still in scope after a body round ends -- so testing it
  // here for that local replaced a live cell with a fresh one and every closure
  // made in a later round saw the loop counter's value at ITS round instead of
  // the shared one.
  if cell <= 0 || vaNum[s + 1] != frameStamp()
      || (fUpInLoop[fid * MAX_UP + k] && vaNum[s + 2] != iterGen) {
    if MAX_CELL <= uTop {
      // the cell pool itself, which the vararg stack's 256 words normally
      // exhaust first -- so this is the rarer of the two and says so
      vmFail("too many captured locals (the chip's cell pool is full)")
      return 0
    }
    cell = uTop
    uTop = uTop + 1
    vaNum[s] = cell
    vaNum[s + 1] = frameStamp()
    vaNum[s + 2] = iterGen
    // seeded from the register, once: the register is where the value is until
    // the cell exists, and after that the cell is the value and the register
    // only gets written alongside it (SETUP), so re-copying here would undo a
    // write that came from a nested function
    let reg = fUpSrc[fid * MAX_UP + k]
    uTag[cell] = vtag[vmBase + reg]
    uNum[cell] = vnum[vmBase + reg]
    uStr[cell] = vstr[vmBase + reg]
  }
  return cell
}

// The double-double lives in an array, fmtDd[0] and fmtDd[1], and not in two
// scalars.  As scalars it did not survive being read back: with fmtConvExp
// seeding the pair and the walk reducing it, the compiler's shared Get per var
// handed the digit state the seeded value instead of the multiplied one, and
// every fraction digit came out 0.  Arrays are how the rest of the chip passes a
// value a mod wrote to a state that runs later.
mod fmtDdMul(hi: float, lo: float, c: float) {
  let ph = hi * c
  // 2^27 + 1 splits each operand into halves a multiply cannot mix, so the
  // low half of the product comes out of four small products
  let ca = 134217729.0 * hi
  let ahi = ca - (ca - hi)
  let alo = hi - ahi
  let cb = 134217729.0 * c
  let bhi = cb - (cb - c)
  let blo = c - bhi
  let pe = ((ahi * bhi - ph) + ahi * blo + alo * bhi) + alo * blo
  let t = pe + lo * c
  // two-sum, so s is the rounded sum and the rest of it exactly
  let s = ph + t
  let bb = s - ph
  fmtDd[0] = s
  fmtDd[1] = (ph - (s - bb)) + (t - bb)
}

// One frame per tick off a caught error, until the frame it pops is the marker:
// then the pair is (false, message) where the pcall's results go and the pcall's
// caller carries on.  A loop is a state machine here, like everything else on
// the chip -- but this one is a tick of its own per frame, so a deep stack costs
// a deep stack in ticks and nothing else.
mod pcallStep() {
  // A caught error abandons whatever machine raised it.  A gate that answers
  // through a micro-step (_fmt, _pat, _gmatch) leaves that machine running with
  // its state mid-conversion, and the unwind does not stop it: the next tick
  // carried on from there, failed again -- this time with pcallDepth back at
  // zero, so the second failure ended the program and lost the false, message
  // the first one had already produced.  The pcall latches go with it, or the
  // gate would be dispatched again after the unwind finished.
  nxActive = false
  fmtGo = false
  patGo = false
  pcallGate = false
  pcallGo = false
  pcallRan = false
  let popped = fFunc[fFunc.length() - 1]
  // the marker's own return, read before the pops take it off the stack: these
  // are where the false and the message (or the handler's results) go
  var ra = 0
  var rb = 0
  var rpc = 0
  var want = 0
  if popped == PCALL_MARK {
    ra = fRetA[fRetA.length() - 1]
    rb = fRetBase[fRetBase.length() - 1]
    rpc = fRetPC[fRetPC.length() - 1]
    want = fRetN[fRetN.length() - 1]
  }
  fFunc.pop()
  fBase.pop()
  fRetA.pop()
  fRetBase.pop()
  fRetPC.pop()
  fRetN.pop()
  vaTop = fVaB.pop().Value
  forDepth = fForDepth.pop()
  if popped == PCALL_MARK {
    pcallUnwind = false
    vmFailed = false
    // false is in the pcall's own register either way: pcall puts the message
    // beside it, xpcall puts the handler's results there and calls the handler
    // to get them.  PUC 5.5 returns false plus whatever the handler returned --
    // measured, not assumed: the false is there even when the handler returns a
    // truthy thing of its own.
    vtag[rb + ra] = 3
    vnum[rb + ra] = 0.0
    vstr[rb + ra] = "false"
    pcallMode = if pcallIsX then 1 else 0
    if pcallIsX {
      // the frames above the marker are gone, so the base is the pcall's own
      // again: a gate handler is dispatched with the instruction's register
      // read against it, and pcallEnter sets it again for a function handler
      vmBase = rb
      // the marker stays: the handler's results are its pcallEnd's to place, and
      // pcallEnd pops it
      fFunc.push(PCALL_MARK)
      fBase.push(rb)
      fRetA.push(ra)
      fRetBase.push(rb)
      fRetPC.push(rpc)
      fRetN.push(want)
      fVaB.push(vaTop)
      fForDepth.push(forDepth)
      let ht = pcallHT
      let hn = pcallH
      let hid = toInt(hn)
      pcallBad[0] = 0
      if ht == 4 && hid < NB {
        // A gate handler: the function and the message go where the dispatch
        // reads them -- the instruction's own register and the one above it --
        // and the dispatch runs at the xpcall instruction.  The false is
        // rewritten by pcallEnd when the gate is done with the slot.
        vtag[rb + ra] = 4
        vnum[rb + ra] = hn
        vstr[rb + ra] = ""
        vtag[rb + ra + 1] = 2
        vnum[rb + ra + 1] = 0.0
        vstr[rb + ra + 1] = pcallMsg
        pcallGateArgs = 1
        pcallRan = true
        pcallGate = true
        pcallMode = 2
      } else {
        // a Lua handler, called with the message as its only argument, and its
        // results landing where the false's partner goes
        vtag[rb + ra + 1] = 2
        vnum[rb + ra + 1] = 0.0
        vstr[rb + ra + 1] = pcallMsg
        pcallFid = hid
        pcallBase = rb
        pcallA = ra + 1
        pcallNArgs = 2
        pcallGo = true
      }
    } else {
      pcallDepth = pcallDepth - 1
      vtag[rb + ra + 1] = 2
      vnum[rb + ra + 1] = 0.0
      vstr[rb + ra + 1] = pcallMsg
      vmBase = rb
      vmPc = rpc
      retCountV = 2
    }
  } else if fFunc.length() == 0 {
    // The error outran the protection, which pcallDepth > 0 says cannot happen.
    // The stack is the chip's only record of where the program was, so the
    // alternative is a pop of nothing.
    pcallUnwind = false
    errV = pcallMsg
    vmHalted = true
  }
}

// next(): one chain hop per tick, so a run of tombstones (keys assigned nil)
// Fill one cell of a closure per tick, then publish the value.  nxActive
// short-circuits the instruction dispatch, so nothing can read the half-built
// closure: the value lands in cloDst before the instruction after LOADFUNC
// runs.  One tick per cell is the price of keeping the array stores out of
// the op-25 arm.
mod cloStep() {
  if cloK < cloN {
    let fid = cloCur
    let cfid = curFid()
    let src = fUpSrc[fid * MAX_UP + cloK]
    if 0 <= src {
      // the local is in the frame this closure is being made in
      cloU[cloCid * MAX_UP + cloK] = cellAt(cfid, cloK)
    } else {
      // it is one link further out: that link is a cell of the frame this
      // closure is being made in, or -- two links out -- of the closure that
      // frame is running, which filled its own list when it was made
      let kp = -1 - src
      let psrc = fUpSrc[cfid * MAX_UP + kp]
      if 0 <= psrc {
        cloU[cloCid * MAX_UP + cloK] = cellAt(cfid, kp)
      } else {
        cloU[cloCid * MAX_UP + cloK] = cloU[curClo() * MAX_UP + (-1 - psrc)]
      }
    }
    cloK = cloK + 1
  } else if !vmFailed {
    vtag[cloDst] = 4
    vnum[cloDst] = cloCid
    vstr[cloDst] = ""
    cloActive = false
  }
}

// The integer part's digits, then the fraction's.  The fraction is exact for
// about fifteen digits and not the sixteenth, so the walk stops at the round
// digit and what is left in the double-double is the sticky bit -- which is why
// it takes one more digit than the mantissa needs: the last one it reads is the
// one it rounds on.
mod fmtEFracMul() {
  fmtDdMul(fmtDd[0], fmtDd[1], 10.0)
  fmtState = 22
}

// Scale the *fraction* by the precision.  Scaling the whole value instead -- one
// number, round it, read it out -- is simpler and wrong past 2^53: %f of 1e10
// at the default six places is 1e16 scaled, which no double holds, so the digits
// are gone.  The integer part of a value below 2^53 is exact and its digits come
// off one division at a time, and it is the fraction that needs the care, so
// that is the only thing scaled here.
mod fmtFScale() {
  let ip = floor(fmtV)
  fmtDdMul(fmtV - ip, 0.0, 10.0 ** (fmtP + 0.0))
  fmtIP = ip
  fmtState = 19
}

// A micro-step gate is finished: its results are at nxDst and retCountV counts
// them.  Normally the instruction steps past itself.  A gate a pcall dispatched
// in place hands them to pcallEnd instead, which moves them up one and writes
// the pcall's own true (or its handler's false) below -- so the protected call
// is only completed here, once the work is actually done.  The other outcome
// never arrives: a machine that raises goes to the unwind with pcallBad set, and
// pcallStep answers false, message.
mod nxDone() {
  if pcallRan {
    pcallRan = false
    pcallEnd(nxDst, if 0 <= retCountV then retCountV else 0, 0)
  } else {
    vmPc = nxPc + 1
  }
}

mod fmtDone() {
  vtag[nxDst] = 2
  vnum[nxDst] = 0.0
  vstr[nxDst] = fmtOut
  retCountV = 1
  nxActive = false
  nxDone()
}

mod fmtStepB() {
  if fmtState == 16 {
    fmtFFDigits()
  } else if fmtState == 17 {
    fmtFPad()
  } else if fmtState == 18 {
    fmtFPoint()
  } else if fmtState == 19 {
    fmtFRound()
  } else if fmtState == 20 {
    fmtIntStart()
  } else if fmtState == 21 {
    fmtEFracMul()
  } else if fmtState == 22 {
    fmtEFracDig()
  } else if fmtState == 23 {
    fmtEJoin()
  } else if fmtState == 24 {
    fmtEFetch()
  } else if fmtState == 25 {
    fmtEBuild()
  } else if fmtState == 26 {
    fmtERound()
  } else if fmtState == 27 {
    fmtEMant()
  } else if fmtState == 28 {
    fmtEMantEnd()
  } else if fmtState == 29 {
    fmtEExpDig()
  } else if fmtState == 30 {
    fmtEExpEnd()
  } else if fmtState == 31 {
    fmtEFracMore()
  } else if fmtState == 33 {
    fmtDigitPut()
  } else if fmtState == 34 {
    fmtGStyle()
  } else if fmtState == 36 {
    fmtGStrip()
  } else {
    fmtESticky()
  }
}

// The whole pattern matched at patStart.  find reports the two positions, an
// empty match ending one before it starts, and then one value per capture; match
// reports the captures, or the match itself when the pattern has none.  Mode 2
// is one step of string.gsub's loop, and answers the two positions, how many
// captures there are, and then the captures, so the piece above can index them
// without counting nils.  A capture still open here is PUC's "unfinished
// capture", and an answer that will not fit the expression's register window is
// refused rather than written over the values after it.
mod patDone() {
  if patMode == 3 {
    // gmatch's cursor, measured rather than derived: the next attempt starts at
    // the end of this match, an empty match steps one past where it stands, and
    // a NON-empty match that ends at the end of the subject finishes the walk.
    // That last rule is what makes "aaa" on "a*" one result and "abc" on "c?"
    // three, while "aaa" on "b*" is four and "abc" on "" is four -- the empty
    // matches at the end are real and the walk does take them.
    let np = if patI == patStart then patStart + 2
             else if patI == patLen then patLen + 2
             else patI + 1
    patGmPos[patTid] = np
  }
  if patCapN > 0 {
    patErr = "unfinished capture"
    patSt = 8
  } else if patMode == 0 || patMode == 2 {
    vtag[nxDst] = 6
    vnum[nxDst] = patStart + 1.0
    vstr[nxDst] = ""
    vtag[nxDst + 1] = 6
    vnum[nxDst + 1] = patI * 1.0
    vstr[nxDst + 1] = ""
    if patMode == 2 {
      vtag[nxDst + 2] = 6
      vnum[nxDst + 2] = patNCap * 1.0
      vstr[nxDst + 2] = ""
      if 3 + patNCap > MAXVALS {
        patErr = "too many captures to return"
        patSt = 8
      } else {
        patAOff = 3
        patAn = 1
        patSt = 16
      }
    } else if 2 + patNCap > MAXVALS {
      patErr = "too many captures to return"
      patSt = 8
    } else {
      patAOff = 2
      patAn = 1
      patSt = 16
    }
  } else if patNCap == 0 {
    vtag[nxDst] = 2
    vnum[nxDst] = 0.0
    vstr[nxDst] = patSrc.Substring(patStart, patI - patStart)
    retCountV = 1
    nxActive = false
    nxDone()
  } else if MAXVALS < patNCap {
    patErr = "too many captures to return"
    patSt = 8
  } else {
    patAOff = 0
    patAn = 1
    patSt = 16
  }
}

// One capture per tick, and one value each: find answers the two positions and
// then the captures, match the captures alone.  A loop is not available here,
// and the slots are read into locals at the top: an array read that follows a
// var write inside a nested arm loses its Exec chain.
mod patAnswer() {
  let cs = patCapS[patAn]
  let ce = patCapE[patAn]
  let cp = patCapP[patAn]
  let d = nxDst + patAOff + patAn - 1
  if cp == 1 {
    // a position capture answers where it stands, as a number
    vtag[d] = 6
    vnum[d] = cs + 1.0
    vstr[d] = ""
  } else if ce == 0 {
    vtag[d] = 0
    vnum[d] = 0.0
    vstr[d] = ""
  } else {
    vtag[d] = 2
    vnum[d] = 0.0
    vstr[d] = patSrc.Substring(cs, ce - 1 - cs)
  }
  patAn = patAn + 1
  if patNCap < patAn {
    retCountV = patAOff + patNCap
    nxActive = false
    nxDone()
  } else {
    patSt = 16
  }
}

// No match anywhere: both find and match answer nil.
mod patNone() {
  vtag[nxDst] = 0
  vnum[nxDst] = 0.0
  vstr[nxDst] = ""
  // a gmatch step with no match is the end of the walk, and that is *no* values:
  // one nil is a value, and a for-in that gets one calls the iterator for ever
  retCountV = if patMode == 3 then 0 else 1
  nxActive = false
  nxDone()
}

mod fmtLit() {
  if fmtEof {
    fmtDone()
  } else if fmtCh == "%" {
    fmtMinus = 0
    fmtPlus = 0
    fmtSpace = 0
    fmtHash = 0
    fmtZero = 0
    fmtWidth = 0
    fmtPrec = -1
    fmtPos = fmtPos + 1
    fmtTo = 1
    fmtSpec = "%"
    fmtState = 10
  } else {
    fmtOut = fmtOut .. fmtCh
    fmtPos = fmtPos + 1
    fmtTo = 0
    fmtState = 10
  }
}

// This attempt failed, so the next start position, unless the pattern is
// anchored or the subject has run out.  PUC's loop stops at the last character
// rather than at the end, which is why an empty pattern's match past it comes
// only from the first attempt.
mod patNextStart() {
  if patAnchor || patR + 1 >= patLen {
    patNone()
  } else {
    patR = patR + 1
    patStart = patR
    patSt = 0
  }
}

// Start the machine: mode 0 find, 1 match, 2 one gsub step, 3 one gmatch step.
// dst is the absolute register the answers go in and tid is gmatch's state table
// (0 when there is none).  A start past the subject's end answers a single nil,
// which is how a walk that is over ends and how a find past the end has always
// answered here.
mod patArm(iniArg: int, mode: int, dst: int, tid: int) {
  // a parameter is not a writable target, so the clamp gets a local of its own
  // and every later use of `ini` below reads that
  var ini = iniArg
  patAnchor = false
  patPSkip = 0
  // a leading ^ is the anchor, but not on the plain path, which is a literal
  // search and never looks at the pattern's meaning.  Mode 3 strips it and does
  // not anchor: PUC's gmatch is not the anchored find, it re-enters the matcher
  // at a new position every step.
  if !patPlain && 0 < patPat.Length() && patPat.Substring(0, 1) == "^" {
    if mode == 3 {
      patPSkip = 1
    } else {
      patAnchor = true
      patPSkip = 1
    }
  }
  patPEnd = patPat.Length()
  patLen = patSrc.Length()
  if ini < 1 {
    ini = 1
  }
  if patLen + 1 < ini {
    vtag[dst] = 0
    vnum[dst] = 0.0
    vstr[dst] = ""
    // the end of a gmatch walk answers *no* values, which is what ends the loop:
    // a single nil is a value, and a for-in that gets one runs for ever
    retCountV = if mode == 3 then 0 else 1
  } else if mode == 3 && patPSkip == 1 {
    // measured: a pattern that starts with ^ matches nothing at all in gmatch,
    // while find and gsub both take it as the anchor and honour it
    vtag[dst] = 0
    vnum[dst] = 0.0
    vstr[dst] = ""
    retCountV = 0
  } else {
    patMode = mode
    patTid = tid
    // one local for both cursors: patR = patStart would read the value patStart
    // had *before* the line above wrote it, and the walk then never advances
    // its right edge, so patNextStart takes the "there is another start" arm for
    // ever and the machine cycles 0 1 2 4 6 until the tick budget runs out
    let start = ini - 1
    patStart = start
    patR = start
    patSt = 0
    patSp = 0
    patNCap = 0
    patCapN = 0
    patErr = ""
    nxDst = dst
    nxPc = vmPc
    nxMode = 2
    nxActive = true
  }
}

// One byte per tick, escaped the way PUC escapes it.  The byte comes from
// fmtQFetch, a state earlier, for the same reason fmtLit does not read the
// cursor itself.
mod fmtQuoted() {
  if fmtEof {
    fmtBody = fmtBody .. "\""
    fmtPre = ""
    fmtState = 6
  } else {
    let b = fmtCh.ToCharCode().Codepoint
    let piece = fmtQuoteByte(b)
    fmtQPos = fmtQPos + 1
    fmtBody = fmtBody .. piece
    fmtState = 11
  }
}

// One mod per state.  A single fmtStep with the states in one long else-if chain
// nested three deep lost the assignment at the bottom: `fmtState = 7` in the %d
// branch never took effect, so the state machine ran the conversion twice and
// read past the end of the spec.  The %s branch, one level shallower, worked --
// which is exactly the kind of neighbour-is-fine trap that says the whole chain
// should be flat.  One state per mod also gives each step a name that says what
// it does, which a numbered branch cannot.
// The character at the cursor, fetched in a state of its own, then handed to
// whichever state asked for it (fmtTo).  A value gate fed by a variable that the
// same mod writes reads the *new* value, so a state that both read the character
// at fmtPos and advanced fmtPos walked one character ahead of the spec: %d came
// out as "d" and %s|%s as "s|a".  Fetching in one state and consuming in the
// next means the cursor is written in one tick and read in the next, which no
// evaluation order in the graph can get wrong.  It costs one tick per spec
// character, against the lexer's four.
mod fmtFetch() {
  if fmtPos < fmtSrc.Length() {
    fmtCh = fmtSrc.Substring(fmtPos, 1)
    fmtEof = false
  } else {
    fmtCh = ""
    fmtEof = true
  }
  fmtState = fmtTo
}

// The item at pattern position p against the character at subject position s.
// 0 does not match, 1 does, 2 a set has to be scanned first, 3 the pattern is
// malformed and patErr says how.  Only the items that can carry a quantifier
// answer here; %b and %f are patNextItem's business.  patItemE is where the
// quantifier is read from, which is why a set reports its end when its scan
// finishes rather than here.
mod patTestItem(p: int, s: int) -> int {
  patAdv = 1
  if s >= patLen || p >= patPEnd {
    return 0
  }
  let sc = patSrc.Substring(s, 1)
  if patPlain {
    patItemE = p + 1
    return if patPat.Substring(p, 1) == sc then 1 else 0
  }
  let k = patPat.Substring(p, 1)
  if k == "[" {
    patSetBegin(p + 1, sc.ToCharCode().Codepoint)
    return 2
  }
  if k == "%" {
    if p + 1 >= patPEnd {
      patErr = "malformed pattern (ends with '%')"
      return 3
    }
    let code = patPat.Substring(p + 1, 1).ToCharCode().Codepoint
    if 49 <= code && code <= 57 {
      return patBackref(p, s, code - 48)
    }
    let neg = 65 <= code && code <= 90
    patItemE = p + 2
    return if patClassHit(sc.ToCharCode().Codepoint, if neg then code + 32 else code, neg) then 1 else 0
  }
  patItemE = if k == "." then p + 1 else p + 1
  if k == "." {
    return 1
  }
  return if k == sc then 1 else 0
}

// The next item in the pattern.  $ at the very end is the end anchor, %b and %f
// are the two items that walk the subject themselves, ( and ) are the captures,
// and a quantifier with no item in front of it is PUC's own dead end, not an
// error: max_expand wants at least one match of the character it names, so "*l"
// and "a??b" are patterns that do not match, while "(%d+)-" still finds its
// minus.  (PUC's lazy branch starts the rest one character early, and "l???" is
// the one shape where that shows: it matches empty there, not here.)
//
// A pattern does match at the end of the subject: find("abc", "a*", 4) is 4 3.
// What stops gsub's loop on "aaa" after one replacement is not the matcher but
// str_gsub's own e == lastmatch test, which is a step of the library loop.
mod patNextItem() {
  if patP >= patPEnd {
    patSt = 5
  } else if patPlain {
    // the whole pattern is literal, so a magic character is just a character:
    // $ is an anchor only when the pattern is read as a pattern
    patItemP = patP
    patQS = patI
    patAfter = 2
    patFailTo = 2
    patHit = if patTestItem(patP, patI) == 1 then true else false
    patSt = 2
  } else {
    let ch = patPat.Substring(patP, 1)
    if ch == "$" && patP + 1 == patPEnd {
      if patI == patLen {
        patSt = 5
      } else {
        patSt = 4
      }
    } else if ch == "(" {
      patSt = patOpen()
    } else if ch == ")" {
      if patCapN != 0 {
        patSt = patClose()
      } else if patNCap == 0 {
        patSt = 4
      } else {
        patErr = "invalid pattern capture"
        patSt = 8
      }
    } else if ch == "*" || ch == "+" || ch == "?" {
      // A quantifier with no item in front of it is PUC's own dead end, not an
      // error: max_expand wants at least one match of the character it names, so
      // "*l" and "a??b" are patterns that do not match, while "(%d+)-" still
      // finds its minus.  (PUC's lazy branch starts the rest one character early,
      // and "l???" is the one shape where that shows: it matches empty there and
      // finds nothing here.)
      patItemP = patP
      patQS = patI
      patAfter = 2
      patFailTo = 2
      let rq = patTestItem(patP, patI)
      if rq == 3 {
        patSt = 8
      } else if rq == 2 {
        patSt = 7
      } else {
        patHit = if rq == 1 then true else false
        patSt = 2
      }
    } else if ch == "%" && patP + 1 < patPEnd {
      let code = patPat.Substring(patP + 1, 1).ToCharCode().Codepoint
      if code == 98 {
        patSt = patBS()
      } else if code == 102 {
        patSt = patF()
      } else {
        patItemP = patP
        patQS = patI
        patAfter = 2
        patFailTo = 2
        let r = patTestItem(patP, patI)
        if r == 3 {
          patSt = 8
        } else if r == 2 {
          patSt = 7
        } else {
          patHit = if r == 1 then true else false
          patSt = 2
        }
      }
    } else {
      patItemP = patP
      patQS = patI
      patAfter = 2
      patFailTo = 2
      let r = patTestItem(patP, patI)
      if r == 3 {
        patSt = 8
      } else if r == 2 {
        patSt = 7
      } else {
        patHit = if r == 1 then true else false
        patSt = 2
      }
    }
  }
}

// A greedy quantifier, taking one more character while the item still matches.
// When it stops, the pattern carries on past the quantifier with as many as it
// took, and the stack entry is left holding the position one before the last
// character it took, which is where the rest starts if this attempt fails.
mod patGreedy() {
  if patI < patLen {
    patAfter = 12
    patFailTo = 14
    let r = patTestItem(patItemP, patI)
    if r == 0 {
      patSt = 14
    } else if r == 3 {
      patSt = 8
    } else if r == 2 {
      patSt = 7
    } else {
      patSl[patSp - 2] = patI
      patI = patI + 1
      patSt = 11
    }
  } else {
    patSt = 14
  }
}

// Take back the most recent alternative.  A greedy entry moves the rest of the
// pattern one character back and records where to move it back to next time; a
// lazy entry gives the item one more character if it matches there; a ?'s entry
// carries on with its item skipped.  An empty stack means this attempt is over.
//
// The four slots are read into locals before anything is written, at the top of
// the mod: an array read that follows a var write inside a nested arm loses its
// Exec chain when the mod is inlined this many times, and the writes fed by it
// quietly never happen.  Reading them first is what the header's trap is about.
mod patBack() {
  if patSp <= 0 {
    patSt = 6
  } else {
    let sp = patSp - 4
    let k0 = patSl[sp]
    let k1 = patSl[sp + 1]
    let k2 = patSl[sp + 2]
    let k3 = patSl[sp + 3]
    if k0 == 1 {
      patSp = sp
      patI = k2
      patItemP = k1
      patQEnd = k3
      if 0 <= patI - 1 {
        patPush(1, patItemP, patI - 1, patQEnd)
      }
      patP = patQEnd
      patSt = 1
    } else if k0 == 2 {
      patSp = sp
      patP = k1
      patSt = 1
    } else if k0 == 5 {
      // undo a capture: PUC's start_capture is a recursive call, so when the
      // rest inside the parens has no alternative left, neither has the attempt
      patSp = sp
      patCapS[k1] = k2
      patCapE[k1] = 0
      patCapP[k1] = 0
      patCapN = k1 - 1
      patNCap = k1 - 1
      patSt = 4
    } else if k0 == 6 {
      // a position capture has no depth to undo, only a number and a start
      patSp = sp
      patCapS[k1] = k2
      patCapP[k1] = 0
      patNCap = k1 - 1
      patSt = 4
    } else if k0 == 7 {
      // a rewind past a ) has to open the capture again, because the item
      // inside it is about to run once more; k3 is the depth to put back, and
      // the open list holds the capture's number one below it
      patSp = sp
      patCapE[k1] = k2
      patCapIx[k3 - 1] = k1
      patCapN = k3
      patSt = 4
    } else if k0 == 4 {
      patSp = sp
      patI = k2
      patItemP = k1
      patQEnd = k3
      patAfter = 13
      patFailTo = 4
      let r = patTestItem(k1, k2)
      if r == 0 {
        patSt = 4
      } else if r == 3 {
        patSt = 8
      } else if r == 2 {
        patSt = 7
      } else {
        patI = k2 + 1
        if 0 <= patI {
          patPush(4, k1, patI, k3)
        }
        patP = k3
        patSt = 1
      }
    } else {
      patSp = sp
      patSt = 4
    }
  }
}

mod patStepB() {
  if patSt == 9 {
    patFPrevStep()
  } else if patSt == 10 {
    patFCurStep()
  } else if patSt == 11 {
    patGreedy()
  } else if patSt == 12 {
    patSetHit()
  } else if patSt == 13 {
    patSetRetry()
  } else if patSt == 14 {
    patGreedyEnd()
  } else {
    patAnswer()
  }
}

mod patStepA() {
  if patSt == 0 {
    patStartStep()
  } else if patSt == 1 {
    patNextItem()
  } else if patSt == 2 {
    patApply()
  } else if patSt == 3 {
    patBStep()
  } else if patSt == 4 {
    patBack()
  } else if patSt == 5 {
    patDone()
  } else if patSt == 6 {
    patNextStart()
  } else if patSt == 7 {
    patSetStep()
  } else {
    patError()
  }
}

// %f %e %g, which dispatch apart from fmtConv's chain: that chain was already
// at the edge of what holds, and two more arms in it stopped the %d arm's write
// from taking effect.
mod fmtConvFloatish() {
  if fmtCh == "f" {
    fmtConvFloat()
  } else if fmtCh == "e" || fmtCh == "E" {
    fmtConvExp()
  } else {
    fmtConvG()
  }
}

// The conversion character, consumed here.  Each conversion sets up its own
// state and checks its own argument, so %% does not consume one and a missing
// one is reported against the conversion that wanted it.  The cursor advance is
// repeated in every branch rather than written once at the top: a write at the
// top of a mod followed by a chain this deep, with mod calls in it, is silently
// dropped, and the walk then re-read the conversion character as a literal
// ("%d" -> "42d").
mod fmtConv() {
  let bad = fmtSpecBad()
  if fmtCh == "%" {
    fmtPos = fmtPos + 1
    fmtBody = "%"
    fmtPre = ""
    fmtState = 6
  } else if bad == 1 {
    fmtPos = fmtPos + 1
    fmtSpec = fmtSpec .. fmtCh
    vmFail("invalid conversion specification: '" .. fmtSpec .. "'")
  } else if bad == 2 {
    fmtPos = fmtPos + 1
    vmFail("specifier '%q' cannot have modifiers")
  } else if fmtCh == "s" || fmtCh == "q" {    fmtPos = fmtPos + 1
    fmtConvStr(fmtCh)
  } else if fmtCh == "d" || fmtCh == "i" || fmtCh == "u" {
    fmtPos = fmtPos + 1
    fmtConvInt()
  } else if fmtCh == "x" || fmtCh == "X" || fmtCh == "o" {
    fmtPos = fmtPos + 1
    fmtConvRadix()
  } else if fmtCh == "c" {
    fmtPos = fmtPos + 1
    fmtConvChar()
  } else if fmtCh == "f" || fmtCh == "e" || fmtCh == "E" || fmtCh == "g"
      || fmtCh == "G" {
    // the float conversions dispatch in a mod of their own: with them in this
    // chain the arms above stopped taking effect and %d of 42 came out 00
    fmtPos = fmtPos + 1
    fmtConvFloatish()
  } else {
    fmtPos = fmtPos + 1
    vmFail("invalid conversion '%" .. fmtCh .. "' to 'format'")
  }
}

mod fmtStepA() {
  if fmtState == 0 {
    fmtLit()
  } else if fmtState == 1 {
    fmtFlag()
  } else if fmtState == 2 {
    fmtWidthStep()
  } else if fmtState == 3 {
    fmtPrecStep()
  } else if fmtState == 4 {
    fmtConv()
  } else if fmtState == 5 {
    fmtPadStep()
  } else if fmtState == 6 {
    fmtFinish()
  } else if fmtState == 7 {
    fmtDigit()
  } else if fmtState == 8 {
    fmtQuoted()
  } else if fmtState == 9 {
    fmtPrecZero()
  } else if fmtState == 10 {
    fmtFetch()
  } else if fmtState == 11 {
    fmtQFetch()
  } else if fmtState == 13 {
    fmtDigitEnd()
  } else {
    fmtFScale()
  }
}

// The dispatch, in two halves.  One chain for all of it stops working once it
// is this long: the arms near the top quietly stop taking effect, and %d of 42
// came out 00 because the integer digit state was never entered.  Sixteen arms
// each is what holds, which is the same lesson as the conversion chain.
mod fmtStep() {
  if fmtState < 16 {
    fmtStepA()
  } else {
    fmtStepB()
  }
}

// The dispatch, in two halves for the same reason fmtStep is: one chain for
// fifteen states is at the edge where the arms near the top stop taking effect.
mod patStep() {
  if patSt < 9 {
    patStepA()
  } else {
    patStepB()
  }
}

// The low half of the gate dispatch: fids 0..8.  The chain was one of
// seventeen arms inside the old four-copy vmStep, and the documented edge for
// a chain is about sixteen -- past it the arms near the top stop taking effect,
// silently.  tools/chip/chainmap.py counts them.

mod gateLow(fid: int, a: int, nargs: int) {
  if fid == 0 {
    if nargs > 16 {
      vmFail("too many print args (max 16)")
    } else {
      // one pure expression (no variable traffic): guarded segments
      let raw = (if 0 < nargs then fmtVal(vTag(a + 1), vNum(a + 1), vStr(a + 1)) else "") .. (if 1 < nargs then "\t" .. fmtVal(vTag(a + 2), vNum(a + 2), vStr(a + 2)) else "") .. (if 2 < nargs then "\t" .. fmtVal(vTag(a + 3), vNum(a + 3), vStr(a + 3)) else "") .. (if 3 < nargs then "\t" .. fmtVal(vTag(a + 4), vNum(a + 4), vStr(a + 4)) else "") .. (if 4 < nargs then "\t" .. fmtVal(vTag(a + 5), vNum(a + 5), vStr(a + 5)) else "") .. (if 5 < nargs then "\t" .. fmtVal(vTag(a + 6), vNum(a + 6), vStr(a + 6)) else "") .. (if 6 < nargs then "\t" .. fmtVal(vTag(a + 7), vNum(a + 7), vStr(a + 7)) else "") .. (if 7 < nargs then "\t" .. fmtVal(vTag(a + 8), vNum(a + 8), vStr(a + 8)) else "") .. (if 8 < nargs then "\t" .. fmtVal(vTag(a + 9), vNum(a + 9), vStr(a + 9)) else "") .. (if 9 < nargs then "\t" .. fmtVal(vTag(a + 10), vNum(a + 10), vStr(a + 10)) else "") .. (if 10 < nargs then "\t" .. fmtVal(vTag(a + 11), vNum(a + 11), vStr(a + 11)) else "") .. (if 11 < nargs then "\t" .. fmtVal(vTag(a + 12), vNum(a + 12), vStr(a + 12)) else "") .. (if 12 < nargs then "\t" .. fmtVal(vTag(a + 13), vNum(a + 13), vStr(a + 13)) else "") .. (if 13 < nargs then "\t" .. fmtVal(vTag(a + 14), vNum(a + 14), vStr(a + 14)) else "") .. (if 14 < nargs then "\t" .. fmtVal(vTag(a + 15), vNum(a + 15), vStr(a + 15)) else "") .. (if 15 < nargs then "\t" .. fmtVal(vTag(a + 16), vNum(a + 16), vStr(a + 16)) else "") .. "\n"
      // the 64-character cap is print's, and it stays here so the log
      // itself takes whatever it is given
      let line = if raw.Length() > 64 then raw.Substring(0, 63) .. "\n" else raw
      logPush(line)
      vSet(a, 0, 0.0, "")
      retCountV = 0
    }
  } else if fid == 1 || fid == 2 {
    if nargs == 0 {
      vmFail("wrong number of arguments")
    } else if fid == 1 {
      let t = vTag(a + 1)
      // the name is chosen with a folded || in the chain, so it is built first
      // and the call takes a plain register: a call whose argument is a folded
      // && or || loses the operand's tag in the compiler's register allocation
      let tn = if t == 0 then "nil" else if t == 1 || t == 6 then "number" else if t == 2 then "string" else if t == 3 then "boolean" else if t == 4 then "function" else "table"
      vSet(a, 2, 0.0, tn)
      retCountV = 1
    } else {
      vSet(a, 2, 0.0, fmtVal(vTag(a + 1), vNum(a + 1), vStr(a + 1)))
      retCountV = 1
    }
  // fid 4 was outcol(r, g, b, a); the colour port is gone and the id stays
  // RESERVED, because renumbering the builtins above it would move every
  // one of them and a dead slot costs nothing.
  } else if fid == 5 {
    if nargs != 0 {
      vmFail("wrong number of arguments to clock")
    } else {
      vSetNum(a, ServerUptime())
      retCountV = 1
    }
  } else if fid == 6 {
    // innumarr(i) reads one slot; innumarr(i, k) reads k of them into k results, so a
    // run of adjacent slots costs one call instead of k.  k is capped at 8: the
    // results go into consecutive registers and MAXVALS is 16, and a wider read
    // wants a table, which is a different question (see AGENTS.md on innumarr).
    let it = if 0 < nargs then vTag(a + 1) else 0
    let iv = if 0 < nargs then vNum(a + 1) else 0.0
    let kv = if 1 < nargs then vNum(a + 2) else 1.0
    if (it != 1 && it != 6) || iv != floor(iv) || iv < 1.0 || iv > inNumArr.length() {
      vSet(a, 0, 0.0, "")
      retCountV = 1
    } else if kv != floor(kv) || kv < 1.0 || kv > 8.0 {
      vmFail("bad argument #2 to 'innumarr' (count out of range)")
    } else {
      // i and k are captured into locals BEFORE any result is written: the
      // results land in the registers the arguments are in, so reading them after
      // the first write would read the new value (see AGENTS.md).
      let w = toInt(iv) - 1
      let cnt = toInt(kv)
      if 0 < cnt {
        if w < inNumArr.length() { vSetNum(a, inNumArr[w]) } else { vSet(a, 0, 0.0, "") }
      }
      if 1 < cnt {
        if w + 1 < inNumArr.length() { vSetNum(a + 1, inNumArr[w + 1]) } else { vSet(a + 1, 0, 0.0, "") }
      }
      if 2 < cnt {
        if w + 2 < inNumArr.length() { vSetNum(a + 2, inNumArr[w + 2]) } else { vSet(a + 2, 0, 0.0, "") }
      }
      if 3 < cnt {
        if w + 3 < inNumArr.length() { vSetNum(a + 3, inNumArr[w + 3]) } else { vSet(a + 3, 0, 0.0, "") }
      }
      if 4 < cnt {
        if w + 4 < inNumArr.length() { vSetNum(a + 4, inNumArr[w + 4]) } else { vSet(a + 4, 0, 0.0, "") }
      }
      if 5 < cnt {
        if w + 5 < inNumArr.length() { vSetNum(a + 5, inNumArr[w + 5]) } else { vSet(a + 5, 0, 0.0, "") }
      }
      if 6 < cnt {
        if w + 6 < inNumArr.length() { vSetNum(a + 6, inNumArr[w + 6]) } else { vSet(a + 6, 0, 0.0, "") }
      }
      if 7 < cnt {
        if w + 7 < inNumArr.length() { vSetNum(a + 7, inNumArr[w + 7]) } else { vSet(a + 7, 0, 0.0, "") }
      }
      retCountV = cnt
    }
  } else if fid == 7 {
    // outarr(i, v, ...) writes i and the next slots, one per extra value, up to
    // 8.  A call with more values writes the first 8, the same way the two-value
    // form ignored whatever came after the second.  The port is @right out, so the
    // whole array reaches it every tick however it was filled: what this saves is
    // the CALL, and 8 values to a call is the cheap way to pay less of it.
    let it = if 0 < nargs then vTag(a + 1) else 0
    let iv = if 0 < nargs then vNum(a + 1) else 0.0
    if (it != 1 && it != 6) || iv != floor(iv) || iv < 1.0 || iv > outArrV.length() {
      vmFail("array index out of range")
    } else {
      let w = toInt(iv) - 1
      // one value per extra argument, so the count is nargs - 1 and not nargs:
      // counting the index made outarr(64, -1) ask for slot 65, which the demo
      // caught because it writes the last slot
      let cnt = if nargs < 9 then nargs - 1 else 8
      if w + cnt > outArrV.length() {
        vmFail("array index out of range")
      } else {
        if 1 < nargs && !arrNumOk(vTag(a + 2)) { vmFail("array element must be a number") }
        if 1 < nargs { outArrV[w] = if vTag(a + 2) == 0 then 0.0 else vNum(a + 2) }
        if 2 < nargs && !arrNumOk(vTag(a + 3)) { vmFail("array element must be a number") }
        if 2 < nargs { outArrV[w + 1] = if vTag(a + 3) == 0 then 0.0 else vNum(a + 3) }
        if 3 < nargs && !arrNumOk(vTag(a + 4)) { vmFail("array element must be a number") }
        if 3 < nargs { outArrV[w + 2] = if vTag(a + 4) == 0 then 0.0 else vNum(a + 4) }
        if 4 < nargs && !arrNumOk(vTag(a + 5)) { vmFail("array element must be a number") }
        if 4 < nargs { outArrV[w + 3] = if vTag(a + 5) == 0 then 0.0 else vNum(a + 5) }
        if 5 < nargs && !arrNumOk(vTag(a + 6)) { vmFail("array element must be a number") }
        if 5 < nargs { outArrV[w + 4] = if vTag(a + 6) == 0 then 0.0 else vNum(a + 6) }
        if 6 < nargs && !arrNumOk(vTag(a + 7)) { vmFail("array element must be a number") }
        if 6 < nargs { outArrV[w + 5] = if vTag(a + 7) == 0 then 0.0 else vNum(a + 7) }
        if 7 < nargs && !arrNumOk(vTag(a + 8)) { vmFail("array element must be a number") }
        if 7 < nargs { outArrV[w + 6] = if vTag(a + 8) == 0 then 0.0 else vNum(a + 8) }
        if 8 < nargs && !arrNumOk(vTag(a + 9)) { vmFail("array element must be a number") }
        if 8 < nargs { outArrV[w + 7] = if vTag(a + 9) == 0 then 0.0 else vNum(a + 9) }
        vSet(a, 0, 0.0, "")
        retCountV = 0
      }
    }
  } else if fid == 8 {
    // select('#', ...) counts the extra arguments; select(n, ...) returns
    // them from n (negative counts from the end)
    let st = if 0 < nargs then vTag(a + 1) else 0
    let sv = if 0 < nargs then vNum(a + 1) else 0.0
    if nargs == 0 {
      vmFail("bad argument #1 to 'select' (number expected, got no value)")
    } else if st == 2 && vStr(a + 1) == "#" {
      vSetInt(a, nargs - 1)
      retCountV = 1
    } else if st != 1 && st != 6 {
      vmFail("bad argument #1 to 'select' (number expected)")
    } else {
      // the arguments after the index are the "extra arguments"; a
      // positive n starts at the n-th of those, a negative one counts
      // back from the last
      let n = toInt(sv)
      let m = nargs - 1
      var cnt = 0
      var src = a
      if n < 0 {
        if 0 - n > m {
          vmFail("bad argument #1 to 'select' (index out of range)")
        } else {
          cnt = 0 - n
          src = a + m + n + 2
        }
      } else if n == 0 {
        vmFail("bad argument #1 to 'select' (index out of range)")
      } else if n <= m {
        cnt = m - n + 1
        src = a + n + 1
      }
      if cnt > MAXVALS {
        vmFail("too many results to select")
      } else if cnt == 0 {
        // An empty result list still has to leave the callee's own register
        // nil: the compiler puts the local a call is assigned to in the slot
        // the function was in, so `local c = select(2, ...)` read the select
        // VALUE (type "function") where PUC reads nil.  tools/chip/wswarn.py's
        // "empty result" check watches for exactly this arm.
        vSet(a, 0, 0.0, "")
        retCountV = 0
      } else {
        shiftDown(a, src, cnt)
        retCountV = cnt
      }
    }
  }
}

// One gathered local/assign target per micro-step is overkill; stores run
// one target per parseStep via stState 12 (locals) / 13 (assign).
mod doStoreStep() {
  if stState == 12 {
    if tmpA >= tmpNames.length() {
      stState = 0
    } else {
      let nm = tmpNames[tmpA]
      let vr = if tmpA < tmpRegs.length() then tmpRegs[tmpA] else -1
      if vr > cfMaxLoc[fnDepth] && vr >= cfBase[fnDepth] {
        locBind(nm, vr)
      } else {
        let r = locDeclare(nm)
        if vr >= 0 {
          bEmit(7, r, vr, 0)
        } else {
          bEmit(1, r, 0, 0)
        }
      }
      dirtySelf(nm)
      tmpA = tmpA + 1
    }
  } else if stState == 15 {
    if tmpA < 0 {
      stState = 0
    } else {
      var vr = -1
      if tmpA < tmpRegs.length() {
        vr = tmpRegs[tmpA]
      } else {
        vr = regAlloc()
        bEmit(1, vr, 0, 0)
      }
      bEmit(30, itBase[tmpA], itKey[tmpA], vr)
      tmpA = tmpA - 1
    }
  } else if stState == 13 {
    if tmpA < 0 {
      stState = 0
    } else if tmpA < tmpRegs.length() {
      tmpB = tmpRegs[tmpA]
      stState = 14
    } else {
      let z = regAlloc()
      bEmit(1, z, 0, 0)
      tmpB = z
      stState = 14
    }
  } else if stState == 14 {
    let nm = tmpNames[tmpA]
    if forNames.find(nm).Found {
      perr = true
      perrMsg = "cannot assign to for loop control variable"
    } else {
    lkRaw = true
    locFind(nm)
    lkRaw = false
    if lkKind == 3 {
      // an upvalue has no register to fold into, so this is always its own
      // instruction
      bEmit(47, tmpB, lkReg, upKind())
      dirtySelf(nm)
    } else if lkKind == 1 {
      // fold the store into the instruction that produced the value
      let li = bop.length() - 1
      let op0 = if li >= 0 then bop[li] else -1
      let canFold = li >= 0 && bpa[li] == tmpB && tmpB > cfMaxLoc[fnDepth] && lastPatchTarget != bop.length() && op0 != 23 && op0 != 20 && op0 != 21 && op0 != 22 && op0 != 24 && op0 != 26 && op0 != 27 && op0 != 6 && op0 != 30
      if canFold {
        bpa[li] = lkReg
      } else {
        bEmit(7, lkReg, tmpB, 0)
      }
      dirtySelf(nm)
    } else if lkKind == 0 {
      bEmit(6, gDeclare(nm), tmpB, 0)
    } else {
      perr = true
      perrMsg = "bad store"
    }
    tmpA = tmpA - 1
    stState = 13
    }
  }
}

mod stmtProgress() {
  if stState == 10 {
    stmtNameList(true)
  } else if stState == 11 {
    stmtNameList(false)
  } else if stState == 12 || stState == 13 || stState == 14 || stState == 15 {
    doStoreStep()
  } else if stState == 20 {
    funcParams()
  } else if stState == 21 {
    // gathering the remaining names of a generic-for header
    if curKind() == 3 {
      tmpNames.push(curStr())
      cpos = cpos + 1
      if curKind() == 5 && curSub() == 16 {
        cpos = cpos + 1
      } else if curKind() == 4 && curSub() == 19 {
        cpos = cpos + 1
        stState = 0
        startUnit(15)
      } else {
        perr = true
        perrMsg = "expected , or in after for name"
      }
    } else {
      perr = true
      perrMsg = "expected name after , in for"
    }
  } else {
    perr = true
    perrMsg = "bad statement state"
  }
}

mod parseStep() {
  if !perr && !pDone {
    if pdThen != 0 {
      pdDrain()
    } else if inExpr {
      exprMicro()
      if exprDone {
        doCont()
      }
    } else if stState != 0 {
      stmtProgress()
    } else {
      stmtDispatch()
    }
  }
}

// The high half: the rest of the builtins, and the generic Lua call at the
// end, which is what a program function reaches.  a and nargs are the call's
// own registers; mtSelf says whether the call wants every result or one.

// `fid` is the prototype, which for every gate builtin is its own function
// number; `cid` is the closure the call actually names, and it goes on the
// frame so a closure body can ask which closure it is (GETCLO, the recursive
// name of a `local function`).
mod gateHigh(fid: int, a: int, nargs: int, mtSelf: bool, cid: int) -> bool {
  // This mod is INLINED into vmStep, which is why writing `advanced` here used to
  // work at all -- the name resolved to vmStep's local after inlining, and the
  // compiler's scope check runs before that, so it called the identifier unknown
  // and refused to write the artifact.  The flag is answered as a value instead:
  // a parameter is by value, so a write would not travel back, and a return does.
  // Only two arms step over their own instruction (the pairs/next walk and the
  // CALL arm, which sets vmPc to the callee's entry), and every other arm falls
  // through to the end with the flag still false.
  var advanced = false
  if fid == 9 {
    // next(t [, k]): the entry after k in insertion order, as key+value.
    // A nil result means the walk is over.  Tombstones (keys assigned nil)
    // are skipped one per tick, so this needs the micro-step below rather
    // than a loop.
    if nargs < 1 || vTag(a + 1) != 5 {
      vmFail("bad argument #1 to 'next' (table expected)")
    } else {
      let tid = toInt(vNum(a + 1))
      var sl = -1
      if nargs < 2 || vTag(a + 2) == 0 {
        sl = tFirst[tid]
      } else {
        let kt = keyTag(vTag(a + 2), vNum(a + 2))
        if kt == 0 {
          vmFail("invalid key to 'next'")
        } else {
          let kr = tmap.get(tkey(tid, kt, vNum(a + 2), vStr(a + 2)))
          if !kr.Found {
            vmFail("invalid key to 'next'")
          } else {
            sl = tNext[kr.Value]
          }
        }
      }
      if !vmFailed {
        nxSlot = sl
        nxDst = vmBase + a
        nxPc = vmPc
        nxMode = 0
        nxActive = true
        nxStep()
        advanced = true
      }
    }
  } else if fid == 10 {
    // _s(mode, s, pos, len): the string operations Lua cannot express.
    // 1 substring  2 upper  3 lower  4 byte at pos  5 char  6 find
    let so = toInt(vNum(a + 1))
    let s = vStr(a + 2)
    let p = toInt(vNum(a + 3))
    let q = if 3 < nargs then toInt(vNum(a + 4)) else 1
    if so == 1 {
      vSet(a, 2, 0.0, if q < 1 then "" else s.Substring(p, q))
    } else if so == 2 {
      vSet(a, 2, 0.0, s.ToUpper())
    } else if so == 3 {
      vSet(a, 2, 0.0, s.ToLower())
    } else if so == 4 {
      if 0 <= p && p < s.Length() {
        vSetInt(a, s.Substring(p, 1).ToCharCode().Codepoint)
      } else {
        vSet(a, 0, 0.0, "")
      }
    } else if so == 5 {
      vSet(a, 2, 0.0, FromCharCode(p).Character)
    } else {
      // 6: find(needle) from pos q, 1-based like Lua's string.find
      vSetInt(a, s.Find(vStr(a + 3), true, q) + 1)
    }
    retCountV = 1
  } else if fid == 11 {
    // _m(mode, x, y): the transcendental functions, which have no way to
    // be written in Lua.  1 floor 2 ceil 3 sqrt 4 sin 5 cos 6 tan 7 asin
    // 8 acos 9 atan2 10 exp 11 ln 12 log10 13 tointeger 14 math.type
    let mo = toInt(vNum(a + 1))
    // math.type answers for a value of any type, so it must not go through the
    // number check at all.  It cannot be guarded in place: a mod call in an if
    // expression's VALUE position runs whether the arm runs or not, so
    // `let x = if mo == 14 then xv else numArg(...)` still raised "bad argument
    // (number expected)" for math.type('x').  Putting the arm first and the
    // check in the other branch is what keeps the two apart.
    if mo == 14 {
      vSet(a, 2, 0.0, if vTag(a + 2) == 6 then "integer"
        else if vTag(a + 2) == 1 then "float" else "nil")
    } else {
      // PUC's math functions take luaL_checknumber, which COERCES a string:
      // math.floor('3') is 3, math.floor(' 2.5 ') is 2, math.sqrt('9') is 3.0,
      // math.tointeger('10') is 10, and a string that is not a number says
      // "bad argument #1 to 'floor' (number expected, got string)".  The
      // conversion is the arithmetic one (arithValL/arithValR), so PUC's numeral
      // rules stay in one place in the chip -- and so 'inf' is nil here too.
      //
      // The second argument is only converted where the mode reads it: PUC's
      // math.floor('3', 'x') is 3, because the extra argument is ignored, so
      // converting y unconditionally would raise where PUC does not.
      let mt = if 1 < nargs then vTag(a + 2) else 0
      let mx = arithValL(mt, if 1 < nargs then vNum(a + 2) else 0.0, if 1 < nargs then vStr(a + 2) else "")
      let yt = if 2 < nargs then vTag(a + 3) else 0
      let yx = arithValR(yt, if 2 < nargs then vNum(a + 3) else 0.0, if 2 < nargs then vStr(a + 3) else "")
      if coerceL == 3 || mo == 9 && coerceR == 3 {
        // The two pieces of the message are locals first: the host cannot lower
        // an if-expression inside a binary operation, only variable + variable,
        // and an `if` written straight into the `..` is a placeholder.
        let argn = if coerceL == 3 then "1" else "2"
        let fname = if mo == 1 then "floor" else if mo == 2 then "ceil"
          else if mo == 3 then "sqrt" else if mo == 4 then "sin"
          else if mo == 5 then "cos" else if mo == 6 then "tan"
          else if mo == 7 then "asin" else if mo == 8 then "acos"
          else if mo == 9 then "atan" else if mo == 10 then "exp"
          else if mo == 11 then "log" else if mo == 12 then "log10"
          else "tointeger"
        vmFail("bad argument #" .. argn .. " to '" .. fname
          .. "' (number expected, got string)")
      } else {
      let x = numArg(if mt == 2 then 1 else mt, mx)
      let y = numArg(if yt == 2 then 1 else yt, yx)
      if mo == 1 || mo == 2 || mo == 13 {
        // the floor gate truncates toward zero, so step to the right for
        // negatives (floor) or positives (ceil)
        let t = x | 0
        let fl = if x < 0.0 && x != t + 0.0 then t - 1 else t
        let ce = if 0 < x && x != t + 0.0 then t + 1 else t
        if mo == 1 {
          // Lua's floor/ceil return integers; the chip tags whole numbers
          // apart from fractions so they print and compare the same way
          if abs(fl) < 9.2e18 { vSetInt(a, fl) } else { vSetNum(a, fl + 0.0) }
        } else if mo == 2 {
          if abs(ce) < 9.2e18 { vSetInt(a, ce) } else { vSetNum(a, ce + 0.0) }
        } else if x == fl + 0.0 && abs(x) < 9.2e18 {
          vSetInt(a, fl)
        } else {
          vSet(a, 0, 0.0, "")
        }
      } else {
        vSetNum(a, if mo == 3 then sqrt(x) else if mo == 4 then sin(x)
          else if mo == 5 then cos(x) else if mo == 6 then tan(x)
          else if mo == 7 then asin(x) else if mo == 8 then acos(x)
          else if mo == 9 then atan2(x, y)
          else if mo == 10 then exp(x) else if mo == 11 then ln(x)
          else log(x, 10.0))
      }
      }
    }
    retCountV = 1
  } else if fid == 18 || fid == 19 {
    // pcall(f, ...) and xpcall(f, handler, ...): the marker, `true` in the
    // call's own register, and then the call itself.  A Lua function's frame
    // goes up one register and is pushed by pcallEnter on the next step,
    // because a mod cannot switch frames where it stands; a gate builtin has no
    // frame, so its arguments move down one and the instruction runs again as
    // the gate.  The two differ only on the error path, which is pcallStep's.
    // The design note is by vmFail, which is where the error path starts.
    pcallIsX = fid == 19
    if nargs < 1 {
      vmFail("bad argument #1 to 'pcall' (value expected)")
    } else if pcallIsX && nargs < 2 {
      vmFail("bad argument #2 to 'xpcall' (function expected, got no value)")
    } else if pcallIsX && vTag(a + 2) != 4 {
      // PUC checks the handler before it calls anything, so a handler that is
      // not a function is xpcall's own error and not the protected call's
      vmFail("bad argument #2 to 'xpcall' (function expected, got "
             .. typeName(vTag(a + 2)) .. ")")
    } else if fFunc.length() + 2 >= MAX_CALLS {
      vmFail("call depth exceeded")
    } else if vTag(a + 1) != 4 {
      // PUC raises "attempt to call" at the call and pcall catches it, so a
      // non-function is the pair, not a failure of the call itself: pcall(42)
      // is false, "attempt to call a number value" and not an error.  xpcall
      // gets PUC's other wording, measured: the error object it has to hand
      // the handler is none at all, so the message is that.
      let t0 = vTag(a + 1)
      vtag[vmBase + a] = 3
      vnum[vmBase + a] = 0.0
      vstr[vmBase + a] = "false"
      vtag[vmBase + a + 1] = 2
      vnum[vmBase + a + 1] = 0.0
      vstr[vmBase + a + 1] = if pcallIsX then "<no error object>"
        else "attempt to call a " .. typeName(t0) .. " value"
      retCountV = 2
    } else if toInt(vNum(a + 1)) == 18 || toInt(vNum(a + 1)) == 19 {
      // pcall of pcall is the one gate that pushes a frame, and the in-place
      // dispatch has one result slot, so it cannot be nested this way
      vmFail("pcall of pcall is not supported on this chip")
    } else {
      let a1 = if 1 < nargs then nargs - 1 else 0
      fFunc.push(PCALL_MARK)
      fBase.push(vmBase)
      fRetA.push(a)
      fRetBase.push(vmBase)
      fRetPC.push(vmPc + 1)
      fRetN.push(if mtSelf then -2 else 1)
      fVaB.push(vaTop)
      fForDepth.push(forDepth)
      pcallDepth = pcallDepth + 1
      pcallMode = 0
      pcallBase = vmBase
      vtag[vmBase + a] = 3
      vnum[vmBase + a] = 1.0
      vstr[vmBase + a] = "true"
      pcallFid = toInt(vNum(a + 1))
      pcallHT = if pcallIsX then vTag(a + 2) else 0
      pcallH = if pcallIsX then vNum(a + 2) else 0.0
      pcallA = a
      pcallNArgs = nargs
      pcallGatePc = vmPc
      if pcallFid < NB {
        // A gate has no frame and reads its function from the call's own
        // register, so f and every argument move down one and the instruction
        // runs again as the gate -- a step of its own, like pcallEnter, because
        // a mod's write to a file variable is only read back reliably at the top
        // of vmStep.  The gate's argument count is a1 and not a1 + 1: f moved
        // into the call's own register, so it is no longer an argument.
        retCopy(vmBase + a + 1, vmBase + a, a1 + 1)
        pcallGateArgs = a1
        pcallGate = true
      } else {
        pcallGo = true
      }
    }
  } else if fid == 12 {
    // unpack(t [, i [, j]]): t[i..j] as multiple results.  Lua cannot
    // write this -- a return list is fixed length -- so it is a primitive.
    if nargs < 1 || vTag(a + 1) != 5 {
      vmFail("bad argument #1 to 'unpack' (table expected)")
    } else {
      let tid = toInt(vNum(a + 1))
      // the tag and the value are chosen first, then numArg sees only
      // those: a mod call in a conditional's value position is evaluated
      // whether the arm runs or not, so an absent argument has to be
      // sanitised before numArg is handed it.  Each one keeps its own
      // default -- 1 for lo, the table's length for hi -- which is why
      // the choice cannot happen inside numArg.
      let lt = if 1 < nargs then vTag(a + 2) else 0
      let lv = if 1 < nargs then vNum(a + 2) else 0.0
      let ht = if 2 < nargs then vTag(a + 3) else 0
      let hv = if 2 < nargs then vNum(a + 3) else 0.0
      let lo = toInt(if lt == 0 then 1.0 else numArg(lt, lv))
      let hi = toInt(if ht == 0 then tLen[tid] + 0.0 else numArg(ht, hv))
      let cnt = if hi < lo then 0 else hi - lo + 1
      if cnt > MAXVALS {
        vmFail("too many results to unpack")
      } else {
        // fill high to low: the values move up into the call's own
        // registers, so copying down would overwrite them
        if 16 <= cnt { tblFill(a + 15, tid, lo + 15) }
        if 15 <= cnt { tblFill(a + 14, tid, lo + 14) }
        if 14 <= cnt { tblFill(a + 13, tid, lo + 13) }
        if 13 <= cnt { tblFill(a + 12, tid, lo + 12) }
        if 12 <= cnt { tblFill(a + 11, tid, lo + 11) }
        if 11 <= cnt { tblFill(a + 10, tid, lo + 10) }
        if 10 <= cnt { tblFill(a + 9, tid, lo + 9) }
        if 9 <= cnt { tblFill(a + 8, tid, lo + 8) }
        if 8 <= cnt { tblFill(a + 7, tid, lo + 7) }
        if 7 <= cnt { tblFill(a + 6, tid, lo + 6) }
        if 6 <= cnt { tblFill(a + 5, tid, lo + 5) }
        if 5 <= cnt { tblFill(a + 4, tid, lo + 4) }
        if 4 <= cnt { tblFill(a + 3, tid, lo + 3) }
        if 3 <= cnt { tblFill(a + 2, tid, lo + 2) }
        if 2 <= cnt { tblFill(a + 1, tid, lo + 1) }
        if 1 <= cnt { tblFill(a, tid, lo) }
        // An empty range answers no values, and PUC's empty result list still
        // makes the callee's own register nil -- that is the slot the compiler
        // puts the local in, so `local c = unpack(t, 2, 1)` read unpack itself.
        if cnt == 0 { vSet(a, 0, 0.0, "") }
        retCountV = cnt
      }
    }
  } else if fid == 13 {
    // _fmt(fmt, ...): string.format, as a micro-step.  lib/str_format.lua
    // is the PUC-verified Lua version of this algorithm; as prepended
    // source it models at 15,400 to 21,300 ticks of boot per program at
    // the measured rates (tools/chip/lexrate.py) and at 11,478 characters
    // it would not fit the source buffer at all, so it lives here
    // and the library only aliases the name (LIB_str_fmt).
    if nargs < 1 {
      vmFail("bad argument #1 to 'format' (string expected, got no value)")
    } else {
      // PUC reads the format with luaL_checkstring, which takes a number as
      // a string: string.format(5) is "5", not an error
      if vTag(a + 1) == 2 {
        fmtSrc = vStr(a + 1)
      } else if vTag(a + 1) == 1 || vTag(a + 1) == 6 {
        fmtSrc = fmtVal(vTag(a + 1), vNum(a + 1), vStr(a + 1))
      } else {
        vmFail("bad argument #1 to 'format' (string expected, got "
               .. typeName(vTag(a + 1)) .. ")")
      }
      if !vmFailed {
        fmtBase = vmBase + a
        fmtArgs = nargs - 1
        fmtArgI = 0
        fmtPos = 0
        fmtQPos = 0
        // fmtTo is where the next fetch goes, and a call that raised leaves it
        // on whatever the last conversion asked for: the next call's first fetch
        // then jumped straight into a conversion and the whole format came back
        // as literal text.
        fmtTo = 0
        fmtOut = ""
        fmtBody = ""
        fmtPre = ""
        fmtPadAcc = ""
        fmtPad = 0
        fmtNeg = false
        fmtWidth = 0
        fmtPrec = -1
        fmtMinus = 0
        fmtPlus = 0
        fmtSpace = 0
        fmtHash = 0
        fmtZero = 0
        fmtPadLeft = false
        fmtPadZero = false
        fmtCh = ""
        fmtEof = false
        fmtBase_ = 10.0
        fmtBaseI = 10
        fmtQ_ = 0
        fmtD_ = 0
        fmtUpper = false
        fmtDigits = 0
        fmtDigitsMax = 0
        fmtSpec = ""
        // start at the fetch, not at the literal state: the walk has not
        // read a character yet, and entering at the literal state skipped
        // the first one (every spec came out one character late)
        fmtState = 10
        nxDst = vmBase + a
        nxPc = vmPc
        nxMode = 1
        nxActive = true
      }
    }
  } else if fid == 15 {
    // _wr(s): raw text into the log, no tab and no newline, through the
    // one append path -- a write to logV that is not paired with a
    // logLines push does not reach the port at all (io.write produced
    // nothing until it went through logPush)
    if nargs < 1 {
      vSet(a, 0, 0.0, "")
    } else {
      let w = fmtVal(vTag(a + 1), vNum(a + 1), vStr(a + 1))
      logPush(w)
      vSet(a, 0, 0.0, "")
    }
    retCountV = 1
  } else if fid == 16 {
    // error(msg [, level]) and assert, which PUC has in C (lbaselib.c)
    // and are gates here for the same reason.  pcall and xpcall are C
    // there too, and the shape they need is settled:
    //
    //   - pcall pushes a marker frame, a sentinel fid on the same fFunc
    //     stack the calls use, carrying its own fRetA / fRetBase /
    //     fRetPC; then it makes the call to f with fRetA at one past the
    //     pcall's own register, so f's results land beside it and the
    //     `true` has a register of its own.
    //   - the four RETURN variants recognise the marker when it comes up
    //     and write `true` where the results start, then return to the
    //     pcall's caller.  The test has to be at the top of each variant:
    //     they are mods this size, and a condition in the middle of one
    //     of these chains is the trap the header warns about.
    //   - vmFail gets a protected mode: it finds the marker, unwinds the
    //     frames above it, and writes (false, message) in the same place.
    //     Without it an error inside a pcall stops the program, which is
    //     the whole thing pcall is for.
    //   - xpcall is the same call with a handler, and the handler is the one
    //     part that does not fit in a register: the protected call's own frame
    //     is written over the register the handler was in, so the arm keeps it
    //     in pcallH/pcallHT and pcallStep calls it from there.  It is called
    //     through the same two steps -- a function handler by pcallEnter, a gate
    //     handler by the in-place dispatch -- with its results landing where the
    //     message would have gone, and pcallMode telling pcallEnd to write false
    //     and to take one value rather than all of them.  That is measured, not
    //     assumed: PUC 5.5 returns false plus the handler's *first* result, so a
    //     handler returning 7, 8 gives false 7.
    //
    // The one thing none of them can do is name a position: PUC prefixes
    // error's message with the chunk and line of whatever called error,
    // and the chip has no line at run time, so the message goes through
    // as it is.
    if nargs < 1 {
      vmFail("")
    } else {
      let t = vTag(a + 1)
      vmFail(fmtVal(t, vNum(a + 1), vStr(a + 1)))
    }
  } else if fid == 17 {
    // assert(v [, msg, ...]): a truthy first argument returns *all* of
    // the arguments, which on a register VM is a shift down by one
    // register, and a falsey one raises with the message or PUC's
    // default.  The shift is retAdjust's job: copying forward would
    // overwrite each value with the one below it.
    if nargs < 1 {
      vmFail("bad argument #1 to 'assert' (value expected)")
    } else if vTag(a + 1) == 0 || vTag(a + 1) == 3 && vNum(a + 1) == 0.0 {
      if 1 < nargs {
        let t2 = vTag(a + 2)
        vmFail(fmtVal(t2, vNum(a + 2), vStr(a + 2)))
      } else {
        vmFail("assertion failed!")
      }
    } else {
      if 0 < nargs {
        retCopy(vmBase + a + 1, vmBase + a, nargs)
        retCountV = nargs
      } else {
        vSet(a, 0, 0.0, "")
        retCountV = 1
      }
    }
  } else if fid == 20 {
    // _pat(mode, s, p [, init [, plain]]): the pattern matcher.  mode 0 is
    // find, 1 is match, 2 is one step of string.gsub's loop and 3 is one step of
    // string.gmatch's.  All of this is argument checking and setup; the matching
    // is the machine at the top of vmStep, which writes its answers into this
    // call's own registers the way the _fmt machine does.
    let mode = toInt(numArg(vTag(a + 1), vNum(a + 1)))
    let nm = if mode == 0 then "string.find" else if mode == 1 then "string.match" else "string.gsub"
    // Only the arguments that were actually passed may be read: a register past
    // nargs still holds whatever the caller's previous call left in it, and a
    // find whose init came from there is a find with a boolean init.
    let it = if 3 < nargs then vTag(a + 4) else 0
    let inum = if 3 < nargs then vNum(a + 4) else 0.0
    let pl = if 4 < nargs then vTag(a + 5) else 0
    let plv = if 4 < nargs then vNum(a + 5) else 0.0
    if patCheck(a, nargs, nm, 2) {
      // only nil and false are false, so a plain of 0 or "" is plain all the same
      patPlain = mode == 0 && !(pl == 0 || pl == 3 && plv == 0.0)
      // PUC's posrelat: a positive init is itself, a negative one counts back
      // from the end plus one, and a zero goes to the clamp below.  A numeric
      // *string* init is the one thing here PUC takes and this does not: the
      // chip has no string-to-number conversion, so it is a number or nothing.
      var ini = 1
      if it == 0 {
        ini = 1
      } else if it == 1 || it == 6 {
        let raw = toInt(inum)
        ini = if 0 < raw then raw else if 0 < 0 - raw then patSrc.Length() + raw + 1 else 0
      } else {
        vmFail("bad argument #3 to '" .. nm .. "' (number expected, got " .. typeName(it) .. ")")
      }
      if !vmFailed {
        patArm(ini, mode, vmBase + a, 0)
      }
    }
  } else if fid == 21 || fid == 22 {
    // _gmatch(s, p) is string.gmatch: it answers the iterator, the state it
    // walks and the control, which is how a generic for takes three values from
    // an expression and shows only the results to the body.  _gmnext(state) is
    // one step of that walk, and it is a *different* gate because PUC's
    // iterator is a different value from string.gmatch: a call with one string
    // is a gmatch missing its pattern, and the iterator is handed whatever the
    // loop has and ignores it.  PUC's is a closure over (s, p, the cursor) and
    // there are no closures here, so the cursor is a table the loop never sees.
    // The differences from PUC are that type() of the state is a table where PUC
    // answers nil, and that a hand-made table is an error where PUC ignores its
    // argument.
    if fid == 21 {
      if patCheck(a, nargs, "string.gmatch", 1) {
        // gmatch's third argument is the init posrelat gives it, with the same
        // shape find has: a negative one counts back from the end
        var ini = 1
        if 2 < nargs {
          let it = vTag(a + 3)
          if it == 0 {
            ini = 1
          } else if it == 1 || it == 6 {
            let raw = toInt(vNum(a + 3))
            ini = if 0 < raw then raw else if 0 < 0 - raw then patSrc.Length() + raw + 1 else 0
          } else {
            vmFail("bad argument #3 to 'gmatch' (number expected, got " .. typeName(it) .. ")")
          }
        }
        if !vmFailed {
          if PAT_WALKS <= patTid {
            vmFail("too many gmatch walks")
          } else {
            patGmId = patTid
            patLastTid = patTid
            patTid = patTid + 1
            patGmIni = ini
            patGmPhase = 0
            nxDst = vmBase + a
            nxPc = vmPc
            nxMode = 3
            nxActive = true
          }
        }
      }
    } else {
      var id = patLastTid
      if vTag(a + 1) == 1 || vTag(a + 1) == 6 {
        let raw = toInt(vNum(a + 1))
        if 0 <= raw && raw < patTid {
          id = raw
        }
      }
      if id < 0 || PAT_WALKS <= id {
        vmFail("bad argument #1 to 'gmatch' (number expected)")
      } else {
        patGmId = id
        patGmPhase = 1
        nxDst = vmBase + a
        nxPc = vmPc
        nxMode = 3
        nxActive = true
      }
    }
  } else if fid == 14 {
    // _rd(fmt): one read from the text in inStr0, the way io.read does it
    if nargs < 1 {
      rdLine()
      if rdGot {
        vSet(a, 2, 0.0, rdBuf)
      } else {
        vSet(a, 0, 0.0, "")
      }
    } else if vTag(a + 1) == 1 || vTag(a + 1) == 6 {
      rdTake(toInt(vNum(a + 1)))
      vSet(a, 2, 0.0, rdBuf)
    } else {
      let f = vStr(a + 1)
      if f == "*a" || f == "a" {
        rdTake(rdText.Length())
        vSet(a, 2, 0.0, rdBuf)
      } else if f == "*l" || f == "l" {
        rdLine()
        if rdGot {
          vSet(a, 2, 0.0, rdBuf)
        } else {
          vSet(a, 0, 0.0, "")
        }
      } else if f == "*r" || f == "r" {
        rdPos = 0
        vSet(a, 2, 0.0, "")
      } else {
        vmFail("bad argument to 'read' (invalid format)")
      }
    }
    retCountV = 1
  } else if fid == 23 {
    // outnum(i, v): write one of the five numeric output ports.  A call, not an
    // assignment, so writing to the world reads as an action.  The index is
    // 1-BASED like every table a Lua program can already see, so outnum(1, v)
    // and outarr(1, v) are the same slot and neither has an off-by-one to
    // remember.
    let oi = if 0 < nargs then toInt(vNum(a + 1)) else -1
    let ot = if 1 < nargs then vTag(a + 2) else 0
    let ov = if 1 < nargs then vNum(a + 2) else 0.0
    if oi < 1 || oi > 5 {
      vmFail("outnum index must be 1..5")
    } else if ot != 1 && ot != 6 && ot != 0 && ot != 3 {
      vmFail("cannot convert to number (outnum takes numbers)")
    } else if oi == 1 {
      oF0 = if ot == 0 then 0.0 else ov
    } else if oi == 2 {
      oF1 = if ot == 0 then 0.0 else ov
    } else if oi == 3 {
      oF2 = if ot == 0 then 0.0 else ov
    } else if oi == 4 {
      oF3 = if ot == 0 then 0.0 else ov
    } else {
      oF4 = if ot == 0 then 0.0 else ov
    }
    vSet(a, 0, 0.0, "")
    retCountV = 0
  } else if fid == 24 {
    // outstr(i, v): one of the two string output ports, Lua-formatted.  Also
    // 1-based, for the same reason as outnum.
    let si = if 0 < nargs then toInt(vNum(a + 1)) else -1
    let st = if 1 < nargs then vTag(a + 2) else 0
    let sn = if 1 < nargs then vNum(a + 2) else 0.0
    let su = if 1 < nargs then vStr(a + 2) else ""
    if si < 1 || si > 2 {
      vmFail("outstr index must be 1..2")
    } else if st == 0 {
      if si == 1 { oS4 = "" } else { oS5 = "" }
    } else if st == 1 || st == 6 || st == 2 || st == 3 {
      let sv = fmtVal(st, sn, su)
      if si == 1 { oS4 = sv } else { oS5 = sv }
    } else {
      vmFail("cannot convert to string (outstr takes a string, number or nil)")
    }
    vSet(a, 0, 0.0, "")
    retCountV = 0
  } else if fid == 25 {
    // instrarr(i) and instrarr(i, k): innumarr's two shapes, reading the string
    // array.  Every bound, the 1-based index, the k cap of 8 and the nil past
    // the end are innumarr's, deliberately -- one reader for an array input is a
    // rule, and two hand-written copies of the bounds is how they stop agreeing.
    // A port carries one wire type, so this reads a SECOND port rather than a
    // wider inNumArr; the header says why that is not the same thing.  The arm
    // lives here and not in gateLow because the call site splits on cid < 9, and
    // a fid of 25 is not below 9 however small the arm is.
    let it = if 0 < nargs then vTag(a + 1) else 0
    let iv = if 0 < nargs then vNum(a + 1) else 0.0
    let kv = if 1 < nargs then vNum(a + 2) else 1.0
    if (it != 1 && it != 6) || iv != floor(iv) || iv < 1.0 || iv > inStrArr.length() {
      vSet(a, 0, 0.0, "")
      retCountV = 1
    } else if kv != floor(kv) || kv < 1.0 || kv > 8.0 {
      vmFail("bad argument #2 to 'instrarr' (count out of range)")
    } else {
      // i and k captured first, for the reason the innumarr arm gives.
      let w = toInt(iv) - 1
      let cnt = toInt(kv)
      if 0 < cnt {
        if w < inStrArr.length() { vSet(a, 2, 0.0, inStrArr[w]) } else { vSet(a, 0, 0.0, "") }
      }
      if 1 < cnt {
        if w + 1 < inStrArr.length() { vSet(a + 1, 2, 0.0, inStrArr[w + 1]) } else { vSet(a + 1, 0, 0.0, "") }
      }
      if 2 < cnt {
        if w + 2 < inStrArr.length() { vSet(a + 2, 2, 0.0, inStrArr[w + 2]) } else { vSet(a + 2, 0, 0.0, "") }
      }
      if 3 < cnt {
        if w + 3 < inStrArr.length() { vSet(a + 3, 2, 0.0, inStrArr[w + 3]) } else { vSet(a + 3, 0, 0.0, "") }
      }
      if 4 < cnt {
        if w + 4 < inStrArr.length() { vSet(a + 4, 2, 0.0, inStrArr[w + 4]) } else { vSet(a + 4, 0, 0.0, "") }
      }
      if 5 < cnt {
        if w + 5 < inStrArr.length() { vSet(a + 5, 2, 0.0, inStrArr[w + 5]) } else { vSet(a + 5, 0, 0.0, "") }
      }
      if 6 < cnt {
        if w + 6 < inStrArr.length() { vSet(a + 6, 2, 0.0, inStrArr[w + 6]) } else { vSet(a + 6, 0, 0.0, "") }
      }
      if 7 < cnt {
        if w + 7 < inStrArr.length() { vSet(a + 7, 2, 0.0, inStrArr[w + 7]) } else { vSet(a + 7, 0, 0.0, "") }
      }
      retCountV = cnt
    }
  } else {
    if fFunc.length() >= MAX_CALLS {
      vmFail("call depth exceeded")
    } else {
      let nbase = vmBase + a
      let np = fParams[fid]
      if np > 8 {
        vmFail("too many parameters")
      } else {
        if 0 < np && 0 < nargs {
          vtag[nbase + 0] = vtag[vmBase + a + 1]
          vnum[nbase + 0] = vnum[vmBase + a + 1]
          vstr[nbase + 0] = vstr[vmBase + a + 1]
        } else if 0 < np {
          vtag[nbase + 0] = 0
        }
        if 1 < np && 1 < nargs {
          vtag[nbase + 1] = vtag[vmBase + a + 2]
          vnum[nbase + 1] = vnum[vmBase + a + 2]
          vstr[nbase + 1] = vstr[vmBase + a + 2]
        } else if 1 < np {
          vtag[nbase + 1] = 0
        }
        if 2 < np && 2 < nargs {
          vtag[nbase + 2] = vtag[vmBase + a + 3]
          vnum[nbase + 2] = vnum[vmBase + a + 3]
          vstr[nbase + 2] = vstr[vmBase + a + 3]
        } else if 2 < np {
          vtag[nbase + 2] = 0
        }
        if 3 < np && 3 < nargs {
          vtag[nbase + 3] = vtag[vmBase + a + 4]
          vnum[nbase + 3] = vnum[vmBase + a + 4]
          vstr[nbase + 3] = vstr[vmBase + a + 4]
        } else if 3 < np {
          vtag[nbase + 3] = 0
        }
        if 4 < np && 4 < nargs {
          vtag[nbase + 4] = vtag[vmBase + a + 5]
          vnum[nbase + 4] = vnum[vmBase + a + 5]
          vstr[nbase + 4] = vstr[vmBase + a + 5]
        } else if 4 < np {
          vtag[nbase + 4] = 0
        }
        if 5 < np && 5 < nargs {
          vtag[nbase + 5] = vtag[vmBase + a + 6]
          vnum[nbase + 5] = vnum[vmBase + a + 6]
          vstr[nbase + 5] = vstr[vmBase + a + 6]
        } else if 5 < np {
          vtag[nbase + 5] = 0
        }
        if 6 < np && 6 < nargs {
          vtag[nbase + 6] = vtag[vmBase + a + 7]
          vnum[nbase + 6] = vnum[vmBase + a + 7]
          vstr[nbase + 6] = vstr[vmBase + a + 7]
        } else if 6 < np {
          vtag[nbase + 6] = 0
        }
        if 7 < np && 7 < nargs {
          vtag[nbase + 7] = vtag[vmBase + a + 8]
          vnum[nbase + 7] = vnum[vmBase + a + 8]
          vstr[nbase + 7] = vstr[vmBase + a + 8]
        } else if 7 < np {
          vtag[nbase + 7] = 0
        }
        // a variadic function keeps the arguments past its named
        // parameters in the vararg stack; the frame records the base
        let nva = if fVar[fid] && np < nargs then nargs - np else 0
        // above the varargs come this frame's slot table and the word below it
        // that says which frame it is (see slotBase), so the table can be
        // scratch space a later frame reuses without adopting stale cells
        let nslots = 3 * fUpSlotN[fid] + 1
        if vaTop + nslots > MAX_VA {
          vmFail("too many captured locals live at once")
        } else if vaTop + nslots + nva > MAX_VA {
          vmFail("too many varargs")
        } else {
          frameSeq = frameSeq + 1
          let slotB = vaTop
          vaNum[slotB] = frameSeq
          vaSpill(vmBase + a + 1 + np, slotB + nslots, nva)
          fVaB.push(slotB + nslots)
          vaTop = slotB + nslots + nva
        }
        fFunc.push(cid)
        fBase.push(nbase)
        fRetA.push(a)
        fRetBase.push(vmBase)
        fRetPC.push(vmPc + 1)
        fRetN.push(if mtSelf then -2 else 1)
        fForDepth.push(forDepth)
        vmBase = nbase
        vmPc = fStart[fid]
        advanced = true
      }
    }
  }
  return advanced
}

// Lex one chunk per call; the driver loops these across ticks.
mod lexChunk() {
  // Two lexStep calls per tick, not four.  Same inlining as vmBurst and
  // parseChunk: four calls compiled the lexer four times over, 6,692 nodes for
  // what is one step's work at four copies.  Two is the middle of the road --
  // one call is 5,019 nodes cheaper again but costs 83% more boot, and boot is
  // what a library piece is charged in (its characters, at 1.3 to 1.75 ticks each,
  // tools/chip/lexrate.py).
  //
  // Measured: a gsub program ran 2,400 ticks with four calls, 3,067 with two,
  // 4,401 with one.  Two takes a third of the available saving for half the
  // boot cost, and the string Find fast path already cut the piece's own boot
  // from 692 to 617 ticks, so the rate is not the whole story any more.
  lexStep()
  if !lerr { lexStep() }
}

mod parseChunk() {
  // One parseStep per tick rather than two, for the same reason vmBurst makes
  // one vmStep call: a mod is inlined at its call site, so two calls compiled
  // the parser twice over.  parseStep is 22,293 of the chip's 52,386 nodes, and
  // one call is 11,143 fewer.
  //
  // Measured beside it: a gsub program went from 2,400 ticks to 3,084, so boot
  // is 28% longer.  That is a smaller price than the vmStep change (a program
  // takes 3.6x the ticks to *run*) because parsing is a one-pass pipeline over
  // the source and the extra cost is bounded by the program's length, while the
  // library piece is charged by the lexer's rate, which this does not touch.
  parseStep()
}
// gmatch's two halves, run from the micro-step at the top of vmStep (nxMode 3)
// because an array element write inside gateHigh's arm is dropped; see the note
// there.  Phase 0 is the constructor: the walk's subject, pattern and cursor go
// into three arrays, and the three values a generic for takes come back.  Phase
// 1 is one step: the cursor comes out of the arrays and the matcher runs from
// it.  The walk is a number where PUC's is a closure, and it is the second
// value here and nil in PUC; the loop hands it back and the body never sees it,
// so the only difference a program can see is type() of that value.
mod gmStep() {
  if patGmPhase == 0 {
    patGmS[patGmId] = patSrc
    patGmP[patGmId] = patPat
    patGmPos[patGmId] = patGmIni
    vtag[nxDst] = 4
    vnum[nxDst] = 22.0
    vstr[nxDst] = ""
    vtag[nxDst + 1] = 6
    vnum[nxDst + 1] = patGmId * 1.0
    vstr[nxDst + 1] = ""
    vtag[nxDst + 2] = 0
    vnum[nxDst + 2] = 0.0
    vstr[nxDst + 2] = ""
    retCountV = 3
    nxActive = false
    nxDone()
  } else {
    patSrc = patGmS[patGmId]
    patPat = patGmP[patGmId]
    let pos = patGmPos[patGmId]
    // patArm records where to come back to as vmPc, and this step runs a tick
    // *after* the call, by which time vmPc is the next instruction: without
    // putting it back the machine returns past the generic-for's nil test, the
    // loop never ends, and the walk is called again from the start for ever.
    vmPc = nxPc
    // patArm answers a single nil itself when the walk is past the end, and it
    // leaves the machine down: the arm raised nxActive before it knew whether a
    // machine was coming, so without this the call re-runs the gate for ever.
    patMode = -1
    patArm(pos, 3, nxDst, patGmId)
    if patMode == -1 {
      nxActive = false
      nxDone()
    }
  }
}

// Is a micro-step machine, a protected call or a closure fill driving this tick?
// vmStep routes on these; vmStepFast has to stand aside on the SAME set, and the
// set is written once here so the two cannot drift.  A copied list is how
// string.format got dispatched past: the fast step had its own idea of what
// "busy" meant and did not include the format machine.
mod vmBusy() -> bool {
  return cloActive || pcallUnwind || pcallGo || pcallGate || lenChase || nxActive
      || cmpActive
}

// FORLOOP, ONE body for both dispatch paths.  vmBurst runs four fast steps and
// then one full step, so any op can be the one vmStep dispatches and vmStep must
// handle FORLOOP too - the duplication is structural.  What is not acceptable is
// two hand-kept copies of the same semantics, which drift, and the drift would
// be a loop that miscounts under one dispatch path only.  A mod inlines at its
// call sites, so this is the same node count as the copy and one source instead.
// RETURN (op 24), ONE body for both dispatch paths, for the reason vmForLoop
// documents: vmBurst's four fast steps and one full step mean both must handle
// every op, and two hand-kept copies would drift - which for a frame teardown
// would be a popped frame under one dispatch path only.
mod vmReturn(a: int) {
  let rv = vTag(a)
  let rn = vNum(a)
  let rs = vStr(a)
  let ra = fRetA[fRetA.length() - 1]
  let rb = fRetBase[fRetBase.length() - 1]
  let rpc = fRetPC[fRetPC.length() - 1]
  fFunc.pop()
  fBase.pop()
  fRetA.pop()
  fRetBase.pop()
  fRetPC.pop()
  fRetN.pop()
  vaTop = fVaB.pop().Value
  forDepth = fForDepth.pop()
  if fFunc.length() == 0 {
    resultV = fmtVal(rv, rn, rs)
    vmHalted = true
  } else if fFunc[fFunc.length() - 1] == PCALL_MARK {
    pcallEnd(vmBase + a, 1, 0)
  } else {
    vmBase = rb
    vSet(ra, rv, rn, rs)
    vmPc = rpc
    retCountV = 1
  }
}

mod vmForLoop(a: int, c: int) {
  let ctrl_reg = forCtrl[forDepth - 1]
  let ctrl = vNum(ctrl_reg)
  let stp = vNum(c)
  let newCtrl = ctrl + stp
  let rem = forRem[forDepth - 1] - 1.0
  if vTag(ctrl_reg) == 6 {
    vSetInt(ctrl_reg, newCtrl)
  } else {
    vSetNum(ctrl_reg, newCtrl)
  }
  forRem[forDepth - 1] = rem
  if 0.0 < rem {
    vmPc = a
  } else {
    forDepth = forDepth - 1
    vmPc = vmPc + 2
  }
}

mod vmStep() {
  if cloActive {
    // A closure being filled owns the WHOLE tick: its cells go in one per tick
    // and the value is published at the end, so a dispatch that ran instead of
    // this would read the closure half-built.  The check belongs here, in the
    // step that owns the state, rather than only in vmBurst - with one call per
    // tick the two are the same thing, and with more than one they are not: a
    // second step after a fill started dispatched straight into the opcode
    // chain, the fill never finished, and every program that read an upvalue
    // produced no output at all.
    cloStep()
  } else if pcallUnwind {
    // a caught error: frames come off until the marker is up.  This is the
    // first arm because the instruction that raised is still in vmPc and must
    // not run again while the unwind is in progress.
    pcallStep()
  } else if pcallGo {
    pcallGo = false
    pcallEnter()
  } else if pcallGate {
    // The gate a protected call is running: a pcall's own builtin, or the
    // message handler an xpcall caught an error with.  Put vmPc back on the
    // instruction, which now reads the gate where its function belongs, mark
    // the dispatch so the call site knows whose results these are, and set the
    // argument count -- pcall's, less the function that moved, or one for a
    // handler.  In the bytecode, where a write is read back the same step.
    pcallGate = false
    pcallRan = true
    pcallBad[0] = 0
    bpb[pcallGatePc] = pcallGateArgs
    vmPc = pcallGatePc
  } else if lenChase {
    lenStep()
  } else if nxActive {
    if nxMode == 1 {
      if fmtGo {
        fmtGo = false
        fmtStep()
      }
    } else if nxMode == 2 {
      // the pattern matcher, one state per burst, the same latch fmtGo is
      if patGo {
        patGo = false
        patStep()
      }
    } else if nxMode == 3 {
      // gmatch's two halves.  They are here and not in the gate arm because an
      // array element write inside gateHigh -- which is inlined once per vmStep
      // -- is dropped: the walk's subject, pattern and cursor went into three
      // arrays and every one of the stores was lost, so the first call read a
      // cursor of 0 and matched at -1.  A scalar write in the same place lands,
      // so the arm only sets the phase and the id and this does the arrays.
      gmStep()
    } else {
      nxStep()
    }
  } else if cmpActive {
    cmpStep()
  } else if !vmHalted {
    let op = bop[vmPc]
    let a = bpa[vmPc]
    let b = bpb[vmPc]
    let c = bpc[vmPc]
    var advanced = false
    if op == 0 {
      vmHalted = true
      advanced = true
    } else if op == 1 {
      vSet(a, 0, 0.0, "")
    } else if op == 2 {
      if c == 1 {
        vSetIntSat(a, constNum[b])
      } else {
        vSetNum(a, constNum[b])
      }
    } else if op == 3 {
      vSet(a, 2, 0.0, constStr[b])
    } else if op == 4 {
      if b == 0 {
        vSet(a, 3, 0.0, "")
      } else {
        vSet(a, 3, 1.0, "")
      }
    } else if op == 5 {
      vSet(a, gTag(b), gNum(b), gStr(b))
    } else if op == 6 {
      // The output ports are written by outnum/outstr now, not by
      // assigning a global, so a store to a global is just a store.
      gSet(a, vTag(b), vNum(b), vStr(b))
    } else if op == 7 {
      vSet(a, vTag(b), vNum(b), vStr(b))
    } else if op >= 8 && op <= 13 {
      let immK = c < 0
      let immPack = if immK then (-1 - c) | 0 else 0
      let bt = vTag(b)
      let ct = if immK then (if (immPack & 1) == 1 then 6 else 1) else vTag(c)
      // String operands go through PUC's coercion (arithValL/arithValR), and
      // the failure message is PUC's: a string that will not convert names the
      // operator and both operand types ("attempt to add a 'string' with a
      // 'number'"), while any other non-number names the offending operand
      // ("attempt to perform arithmetic on a table value").  Both are built in
      // the failing branch, so neither concat runs on arithmetic that succeeds.
      let x = arithValL(bt, vNum(b), vStr(b))
      let y = arithValR(ct, if immK then constNum[immPack >> 1] else vNum(c), if immK then "" else vStr(c))
      let badL = coerceL == 3
      let badR = coerceR == 3
      if badL || badR || !((bt == 1 || bt == 6 || bt == 2) && (ct == 1 || ct == 6 || ct == 2)) {
        let opn = if op == 8 then "add" else if op == 9 then "sub"
          else if op == 10 then "mul" else if op == 11 then "div"
          else if op == 12 then "mod" else "pow"
        if badL || badR {
          vmFail("attempt to " .. opn .. " a '" .. typeName(bt) .. "' with a '" .. typeName(ct) .. "'")
        } else {
          // hoisted out of the call for the same reason as the LT arm: a folded
          // && as a call argument costs the operand its tag
          let badT = if bt != 1 && bt != 6 then bt else ct
          vmFail("attempt to perform arithmetic on a " .. typeName(badT) .. " value")
        }
      } else {
        // A string that converted is an integer only when ParseInt took it, so
        // '2' + 1 is 3 where '2.0' + 1 is 3.0 and 2.0 + 1 is 3.0.
        let ii = if bt == 6 then true else if bt == 2 then coerceL == 1 else false
        let ij = if ct == 6 then true else if ct == 2 then coerceR == 1 else false
        if op == 8 {
          if ii && ij {
            vSetInt(a, x + y)
          } else {
            vSetNum(a, x + y)
          }
        } else if op == 9 {
          if ii && ij {
            vSetInt(a, x - y)
          } else {
            vSetNum(a, x - y)
          }
        } else if op == 10 {
          if ii && ij {
            vSetInt(a, x * y)
          } else {
            vSetNum(a, x * y)
          }
        } else if op == 11 {
          // A zero divisor is not special-cased: the host's divide gate is
          // `x / y` on a 64-bit float, so 1/0 is inf and 0/0 is nan, which is
          // what PUC prints too.  A guard here answered 0.0 for both, and
          // 1/(0.0*-1) with it.
          vSetNum(a, x / y)
        } else if op == 12 {
          if y == 0.0 {
            if ii && ij {
              vmFail("attempt to perform 'n%0'")
            } else {
              vSetNum(a, x % y)
            }
          } else {
            // floored quotient: the floor gate truncates toward zero,
            // so adjust negative non-integral quotients down by one
            let q = x / y
            let t = q | 0
            let fl = if q < 0.0 && q != t + 0.0 then t - 1 else t
            let flf = fl + 0.0
            if ii && ij {
              vSetInt(a, x - flf * y)
            } else {
              vSetNum(a, x - flf * y)
            }
          }
        } else {
          vSetNum(a, x ** y)
        }
      }
    } else if op == 14 {
      // -v, not 0.0 - v: IEEE negation of 0.0 is -0.0, and 0.0 - 0.0 is +0.0,
      // which is how `print(-0.0)` came out "0.0".
      let nt = vTag(b)
      let nx = arithValL(nt, vNum(b), vStr(b))
      let nbad = coerceL == 3
      if nbad {
        // PUC names the operand twice for a unary op: attempt to unm a 'string'
        // with a 'string'
        vmFail("attempt to unm a '" .. typeName(nt) .. "' with a '" .. typeName(nt) .. "'")
      } else if nt != 1 && nt != 6 && nt != 2 {
        vmFail("attempt to perform arithmetic on a " .. typeName(nt) .. " value")
      } else {
        if nt == 6 || coerceL == 1 {
          vSetInt(a, -nx)
        } else {
          vSetNum(a, -nx)
        }
      }
    } else if op == 15 {
      if truthyOf(vTag(b), vNum(b)) {
        vSet(a, 3, 0.0, "")
      } else {
        vSet(a, 3, 1.0, "")
      }
    } else if op == 16 {
      let lct = vTag(b)
      let rct = vTag(c)
      if (lct == 1 || lct == 6 || lct == 2) && (rct == 1 || rct == 6 || rct == 2) {
        let ls = if lct == 2 then vStr(b) else if lct == 6 then "" .. (vNum(b) | 0) else fmtNum(vNum(b))
        let rs = if rct == 2 then vStr(c) else if rct == 6 then "" .. (vNum(c) | 0) else fmtNum(vNum(c))
        vSet(a, 2, 0.0, ls .. rs)
      } else {
        vmFail("attempt to concatenate a "
          .. typeName(if lct == 1 || lct == 6 then rct else lct) .. " value")
      }
    } else if op == 17 || op == 18 || op == 19 {
      let immK = c < 0
      let immConst = if immK then -1 - c else 0
      let lt = vTag(b)
      let rt = if immK then 1 else vTag(c)
      let rv = if immK then constNum[immConst] else vNum(c)
      let ln = lt == 1 || lt == 6
      let rn = rt == 1 || rt == 6
      if op == 17 {
        if ln && rn {
          vSet(a, 3, if vNum(b) == rv then 1.0 else 0.0, "")
        } else if lt != rt {
          vSet(a, 3, 0.0, "")
        } else if lt == 1 {
          vSet(a, 3, if vNum(b) == rv then 1.0 else 0.0, "")
        } else if lt == 2 {
          vSet(a, 3, if vStr(b) == vStr(c) then 1.0 else 0.0, "")
        } else if lt == 3 {
          vSet(a, 3, if vNum(b) == rv then 1.0 else 0.0, "")
        } else if lt == 4 || lt == 5 {
          vSet(a, 3, if vNum(b) == rv then 1.0 else 0.0, "")
        } else {
          vSet(a, 3, 1.0, "")
        }
      } else if ln && rn {
        let hit = if op == 18 then vNum(b) < rv else vNum(b) <= rv
        if a < 0 && op == 19 {
          if hit {
            vmPc = vmPc + 2
          } else {
            vmPc = -1 - a
          }
          advanced = true
        } else {
          vSet(a, 3, if hit then 1.0 else 0.0, "")
        }
      } else if lt == 2 && rt == 2 {
        // lexicographic string order cannot use the MathCompare gate
        // (numbers only), so compare one codepoint per vmStep instead
        cmpActive = true
        cmpAA = vmBase + b
        cmpBB = vmBase + c
        cmpDst = vmBase + a
        cmpI = 0
        cmpOp = if op == 19 then 1 else 0
        advanced = true
      } else {
        // PUC names both types, unquoted: "attempt to compare number with string"
        vmFail("attempt to compare " .. typeName(lt) .. " with " .. typeName(rt))
      }
    } else if op == 20 {
      vmPc = a
      advanced = true
    } else if op == 21 {
      if !truthyOf(vTag(b), vNum(b)) {
        vmPc = a
        advanced = true
      }
    } else if op == 22 {
      if truthyOf(vTag(b), vNum(b)) {
        vmPc = a
        advanced = true
      }
    } else if op == 23 || op == 41 {
      if vTag(a) != 4 {
        vmFail("attempt to call")
      } else {
        let cid = toInt(vNum(a))
        // C operand bits: 1 = my last argument is an expanding call (so the
        // arg count is one short and the tail's own count is added at run
        // time); 2 = I return all of my results, not just one.  Both can be
        // set (3) when a call is both the tail of an enclosing call and itself
        // expanded into a target list.
        let mtArg = if c == 1 || c == 3 then true else false
        let mtSelf = if c == 2 || c == 3 || op == 41 then true else false
        // a tail argument's call already ran and reported how many values it
        // produced; the enclosing call counts those in place of its last arg
        let tailN = if mtArg then (if 0 <= retCountV then retCountV else 0) else 0
        let nargs = if mtArg && 0 < b then (b - 1) + tailN else b
        let pc0 = vmPc
        if cid < 9 {
          gateLow(cid, a, nargs)
        } else {
          // a builtin is its own closure, so the prototype is the number again
          // until the closure records start
          let fid = if cid < cloBase then cid else cloF[cid]
          if gateHigh(fid, a, nargs, mtSelf, cid) {
            advanced = true
          }
        }
        if pcallRan && pcallBad[0] == 0 && !nxActive {
          // a gate dispatched in place by a pcall: its results are at the
          // pcall's own register, so they move up one and the true goes below.
          // A gate that raised does not come here: the error is the value, and
          // the unwind finds the marker with the message in it.
          //
          // Nor does one still running: _fmt, _pat and _gmatch answer through a
          // micro-step, so the gate arm leaves nxActive set and this
          // instruction re-runs once the machine is done.  Completing the
          // protected call here would pop the marker and drop pcallDepth to 0
          // before the work ran, and the failure that work raises -- one tick
          // later -- would end the program instead of answering false, message.
          pcallRan = false
          pcallEnd(vmBase + a, if 0 <= retCountV then retCountV else 0, 0)
          advanced = true
        } else if vmPc != pc0 {
          // a gate that changed the frame moved vmPc; one that did not falls
          // through to the caller's vmPc + 1, as every other arm here does
          advanced = true
        }
      }
    } else if op == 45 {
      // VARARG a, b: b = 1 gives one value, b = 0 gives all of them
      let base = fVaB[fVaB.length() - 1]
      let have = vaTop - base
      let want = if b == 0 then have else b
      if 1 <= want {
        let k = if have < want then have else want
        vaFill(base, vmBase + a, k)
        if k < want {
          // pad with nil so a fixed-arity target list sees the missing values
          if k + 1 <= want { vSet(a + k, 0, 0.0, "") }
          if k + 2 <= want { vSet(a + k + 1, 0, 0.0, "") }
          if k + 3 <= want { vSet(a + k + 2, 0, 0.0, "") }
          if k + 4 <= want { vSet(a + k + 3, 0, 0.0, "") }
          if k + 5 <= want { vSet(a + k + 4, 0, 0.0, "") }
          if k + 6 <= want { vSet(a + k + 5, 0, 0.0, "") }
          if k + 7 <= want { vSet(a + k + 6, 0, 0.0, "") }
          if k + 8 <= want { vSet(a + k + 7, 0, 0.0, "") }
          if k + 9 <= want { vSet(a + k + 8, 0, 0.0, "") }
          if k + 10 <= want { vSet(a + k + 9, 0, 0.0, "") }
          if k + 11 <= want { vSet(a + k + 10, 0, 0.0, "") }
          if k + 12 <= want { vSet(a + k + 11, 0, 0.0, "") }
          if k + 13 <= want { vSet(a + k + 12, 0, 0.0, "") }
          if k + 14 <= want { vSet(a + k + 13, 0, 0.0, "") }
          if k + 15 <= want { vSet(a + k + 14, 0, 0.0, "") }
          if k + 16 <= want { vSet(a + k + 15, 0, 0.0, "") }
        }
      } else {
        vSet(a, 0, 0.0, "")
      }
      retCountV = want
    } else if op == 24 {
      vmReturn(a)
      advanced = true
    } else if op == 26 {
      let ra = fRetA[fRetA.length() - 1]
      let rb = fRetBase[fRetBase.length() - 1]
      let rpc = fRetPC[fRetPC.length() - 1]
      fFunc.pop()
      fBase.pop()
      fRetA.pop()
      fRetBase.pop()
      fRetPC.pop()
      fRetN.pop()
      vaTop = fVaB.pop().Value
      forDepth = fForDepth.pop()
      if fFunc.length() == 0 {
        resultV = ""
        vmHalted = true
      } else if fFunc[fFunc.length() - 1] == PCALL_MARK {
        pcallEnd(vmBase + a, 0, 0)
      } else {
        vmBase = rb
        vSet(ra, 0, 0.0, "")
        vmPc = rpc
        retCountV = 0
      }
      advanced = true
    } else if op == 27 {
      if retCountV == -1 {
        retCountV = 1
      }
      // a tail `return f()` forwards every value f produced, bounded by what
      // this frame's own caller asked for
      let want = fRetN[fRetN.length() - 1]
      let rv = vTag(a)
      let rn = vNum(a)
      let rs = vStr(a)
      let ra = fRetA[fRetA.length() - 1]
      let rb = fRetBase[fRetBase.length() - 1]
      let rpc = fRetPC[fRetPC.length() - 1]
      fFunc.pop()
      fBase.pop()
      fRetA.pop()
      fRetBase.pop()
      fRetPC.pop()
      fRetN.pop()
      vaTop = fVaB.pop().Value
      forDepth = fForDepth.pop()
      let have = if 0 <= retCountV then retCountV else 0
      let n = if want == -2 then have else 1
      let k = if have < n then have else n
      if fFunc.length() == 0 {
        if 1 <= k {
          resultV = fmtVal(rv, rn, rs)
        } else {
          resultV = ""
        }
        vmHalted = true
      } else if fFunc[fFunc.length() - 1] == PCALL_MARK {
        pcallEnd(vmBase + a, k, 0)
      } else {
        if want == -2 {
          // forward every value the call produced (absolute indices, so this
          // runs before the frame switch below)
          retAdjust(vmBase + a, rb + ra, k, n)
        } else if 1 <= k {
          vmBase = rb
          vSet(ra, rv, rn, rs)
        } else {
          vmBase = rb
          vSet(ra, 0, 0.0, "")
        }
        vmBase = rb
        vmPc = rpc
        retCountV = n
      }
      advanced = true
    } else if op == 43 {
      // ADJUST a=src b=dst c=max: normalise the rest of the last call's results
      // into c consecutive registers.  `a` already points past the first value
      // (the caller consumed it), so only retCountV-1 values remain to copy.
      let avail = if 0 < retCountV then retCountV - 1 else 0
      let n = if avail < c then avail else c
      retAdjust(vmBase + a, vmBase + b, n, c)
    } else if op == 42 {
      // RETURNM a, b: b >= 0 returns b values from a; b < 0 returns -b values
      // from a and then every value the call at register c produced, which is
      // how `return x, f()` reaches the caller.
      var cnt = b
      var tail = 0
      var tailSrc = 0
      if cnt < 0 {
        tail = if 0 < retCountV then retCountV else 0
        if tail > MAXVALS {
          tail = MAXVALS
        }
        tailSrc = c
        cnt = 0 - cnt
      }
      if 16 < cnt + tail {
        vmFail("too many values")
      } else {
        let ra = fRetA[fRetA.length() - 1]
        let rb = fRetBase[fRetBase.length() - 1]
        let rpc = fRetPC[fRetPC.length() - 1]
        let want = fRetN[fRetN.length() - 1]
        fFunc.pop()
        fBase.pop()
        fRetA.pop()
        fRetBase.pop()
        fRetPC.pop()
        fRetN.pop()
        vaTop = fVaB.pop().Value
        forDepth = fForDepth.pop()
        let n = if want == -2 then cnt + tail else 1
        let k = if cnt + tail < n then cnt + tail else n
        if fFunc.length() == 0 {
          resultV = if 1 <= k then fmtVal(vTag(a), vNum(a), vStr(a)) else ""
          vmHalted = true
        } else if fFunc[fFunc.length() - 1] == PCALL_MARK {
          pcallEndJoin(vmBase + a, cnt, vmBase + tailSrc, tail)
        } else {
          if 0 < tail {
            // The call's values sit in this frame and the fixed ones are copied
            // into the caller's return block, which overlaps them (a frame
            // starts at the very register the results go to).  Park the call's
            // values on the vararg stack first so neither copy can clobber the
            // other.
            let save = vaTop
            vaSpill(vmBase + tailSrc, save, tail)
            retAdjust(vmBase + a, rb + ra, k, n)
            vaFill(save, rb + ra + cnt, if k < cnt + tail then k - cnt else tail)
            vaTop = save
          } else {
            retAdjust(vmBase + a, rb + ra, k, n)
          }
          vmBase = rb
          vmPc = rpc
          retCountV = n
        }
      }
      advanced = true
    } else if op == 25 {
      if fUpN[b] == 0 {
        vSet(a, 4, b, "")
      } else if cloF.length() <= cloTop {
        // The array's own length, which is MAX_FUNCS + MAX_CLO, rather than a
        // literal: the literal was 1000000, so this never fired and 400 closures
        // wrote cloF[352..427] and cloU past the end of both.  The five internal
        // numbers it used to print were the debugging that found it, and a user
        // cannot act on any of them.
        vmFail("too many closures (" .. (cloF.length() | 0) .. " records)")
      } else {
        // A function with upvalues is a fresh closure every time it is
        // evaluated.  Only scalars are written here: this arm is inlined once
        // per vmStep and the array stores in it are dropped (the gmatch trap),
        // so cloStep fills the cells from the micro-step arm instead.
        cloCid = cloTop
        cloTop = cloTop + 1
        cloF[cloCid] = b
        cloCur = b
        cloK = 0
        cloN = fUpN[b]
        cloDst = vmBase + a
        cloActive = true
        // step over the instruction here: the fill owns the next tick, and the
        // instruction after this runs the tick after that
        vmPc = vmPc + 1
        advanced = true
      }
    } else if op == 46 {
      // GETUP a, b=descriptor, c=0 this frame's own cell for the local or
      // c=1 the enclosing closure's cell for it
      //
      // NOT on the fast path, and measured: a fast arm here cost 364 nodes and
      // saved ZERO ticks, because GETUP only runs inside closure code and
      // vmStepFast returns early when vmBusy() - and cloActive is exactly what
      // makes GETUP frequent.  The fast path and the micro-step machines are
      // mutually exclusive, so a fast arm can only ever help an op that runs in
      // PLAIN execution.  That is the whole reason FORLOOP gained a tick per
      // iteration and this did not.
      let cell = cellRead(curFid(), b, c == 1)
      if 0 < cell {
        vSet(a, uTag[cell], uNum[cell], uStr[cell])
      } else {
        vSet(a, 0, 0.0, "")
      }
    } else if op == 47 {
      // SETUP a=source, b=descriptor, c=kind.  The local's own register is
      // written as well as the cell, because the register is its home and a
      // closure made later copies the register in (see cellAt).
      let fid = curFid()
      if c == 1 {
        let cell = cloU[curClo() * MAX_UP + b]
        if 0 < cell {
          uTag[cell] = vTag(a)
          uNum[cell] = vNum(a)
          uStr[cell] = vStr(a)
        }
      } else {
        let cell = cellRead(fid, b, false)
        if 0 < cell {
          uTag[cell] = vTag(a)
          uNum[cell] = vNum(a)
          uStr[cell] = vStr(a)
        }
        let abs = vmBase + fUpSrc[fid * MAX_UP + b]
        vtag[abs] = vTag(a)
        vnum[abs] = vNum(a)
        vstr[abs] = vStr(a)
      }
    } else if op == 48 {
      vSet(a, 4, curClo(), "")
    } else if op == 49 {
      iterGen = iterGen + 1
    } else if op == 50 {
      forDepth = forDepth - 1
    } else if op == 28 {
      if tCount >= MAX_TABLES {
        // toInt, because the constant folder turns `MAX_TABLES | 0` into the
        // float literal 68 and the message then reads "68.0"
        let cap = toInt(MAX_TABLES + 0.0)
        vmFail("too many tables (" .. (cap | 0) .. ")")
      } else {
        tLen[tCount] = 0
        vSet(a, 5, tCount + 0.0, "")
        tCount = tCount + 1
      }
    } else if op == 29 {
      let kt = keyTag(vTag(c), vNum(c))
      if vTag(b) == 2 {
        // Indexing a string reaches the string library, the way PUC Lua's
        // string metatable does.  This is what makes s:upper() work without
        // metatables.  The table is looked up here rather than cached: the
        // library creates it while the program runs, so a cached id would be
        // resolved before it exists.
        let sr = gmap.get("string")
        if kt == 2 && sr.Found && gtag[sr.Value] == 5 {
          let r = tmap.get(tkey(toInt(gnum[sr.Value]), kt, vNum(c), vStr(c)))
          if r.Found {
            vSet(a, tvTag[r.Value], tvNum[r.Value], tvStr[r.Value])
          } else {
            vSet(a, 0, 0.0, "")
          }
        } else {
          vSet(a, 0, 0.0, "")
        }
      } else if vTag(b) != 5 {
        // PUC says WHICH kind.  Indexing nil is the common case -- a field off a
        // nil return, a typo'd global, `coroutine.create` on a build with no
        // coroutines -- and "non-table" sends the reader hunting for a number or
        // a string when the value is nil.
        vmFail(if vTag(b) == 0 then "attempt to index a nil value"
          else "attempt to index a " .. typeName(vTag(b)) .. " value")
      } else if kt == 0 {
        vmFail("table index is nil")
      } else if kt == 1 && vNum(c) != floor(vNum(c)) {
        vSet(a, 0, 0.0, "")
      } else {
        let r = tmap.get(tkey(toInt(vNum(b)), kt, vNum(c), vStr(c)))
        if r.Found {
          vSet(a, tvTag[r.Value], tvNum[r.Value], tvStr[r.Value])
        } else {
          vSet(a, 0, 0.0, "")
        }
      }
    } else if op == 30 {
      let kt = keyTag(vTag(b), vNum(b))
      if vTag(a) != 5 {
        vmFail("attempt to index a non-table value")
      } else if kt == 0 {
        vmFail("table index is nil")
      } else if kt == 1 && vNum(b) != floor(vNum(b)) {
        vmFail("non-integer number keys are not supported")
      } else {
        tblSetKey(toInt(vNum(a)), kt, vNum(b), vStr(b), vTag(c), vNum(c), vStr(c))
      }
    } else if op == 44 {
      // TAPPEND a=table b=src c=max: append up to `max` of the last call's
      // results (registers b..) to the table at consecutive integer keys.  Used
      // for a call in the last positional slot of a table constructor.
      if vTag(a) != 5 {
        vmFail("attempt to index a non-table value")
      } else {
        let tid = toInt(vNum(a))
        let start = tLen[tid]
        let have = if 0 <= retCountV then retCountV else 0
        let n = if have < c then have else c
        if 1 <= n { tblSetKey(tid, 6, start + 1.0, "", vTag(b), vNum(b), vStr(b)) }
        if 2 <= n { tblSetKey(tid, 6, start + 2.0, "", vTag(b+1), vNum(b+1), vStr(b+1)) }
        if 3 <= n { tblSetKey(tid, 6, start + 3.0, "", vTag(b+2), vNum(b+2), vStr(b+2)) }
        if 4 <= n { tblSetKey(tid, 6, start + 4.0, "", vTag(b+3), vNum(b+3), vStr(b+3)) }
        if 5 <= n { tblSetKey(tid, 6, start + 5.0, "", vTag(b+4), vNum(b+4), vStr(b+4)) }
        if 6 <= n { tblSetKey(tid, 6, start + 6.0, "", vTag(b+5), vNum(b+5), vStr(b+5)) }
        if 7 <= n { tblSetKey(tid, 6, start + 7.0, "", vTag(b+6), vNum(b+6), vStr(b+6)) }
        if 8 <= n { tblSetKey(tid, 6, start + 8.0, "", vTag(b+7), vNum(b+7), vStr(b+7)) }
        if 9 <= n { tblSetKey(tid, 6, start + 9.0, "", vTag(b+8), vNum(b+8), vStr(b+8)) }
        if 10 <= n { tblSetKey(tid, 6, start + 10.0, "", vTag(b+9), vNum(b+9), vStr(b+9)) }
        if 11 <= n { tblSetKey(tid, 6, start + 11.0, "", vTag(b+10), vNum(b+10), vStr(b+10)) }
        if 12 <= n { tblSetKey(tid, 6, start + 12.0, "", vTag(b+11), vNum(b+11), vStr(b+11)) }
        if 13 <= n { tblSetKey(tid, 6, start + 13.0, "", vTag(b+12), vNum(b+12), vStr(b+12)) }
        if 14 <= n { tblSetKey(tid, 6, start + 14.0, "", vTag(b+13), vNum(b+13), vStr(b+13)) }
        if 15 <= n { tblSetKey(tid, 6, start + 15.0, "", vTag(b+14), vNum(b+14), vStr(b+14)) }
        if 16 <= n { tblSetKey(tid, 6, start + 16.0, "", vTag(b+15), vNum(b+15), vStr(b+15)) }
      }
    } else if op == 31 {
      let bt = vTag(b)
      if bt == 5 {
        // The cached border: it follows an append, it follows a delete, and it
        // extends across a gap that is filled later, because tblHas asks the map
        // the way the rest of the table code does.  All three were measured
        // against PUC; see AGENTS.md.
        vSet(a, 6, tLen[toInt(vNum(b))] + 0.0, "")
      } else if bt == 2 {

        vSet(a, 6, vStr(b).Length() + 0.0, "")
      } else {
        // PUC also names the value: "attempt to get length of a nil value", plus
        // "(global 'print')" when it is a named one, which needs a descriptor the
        // length operator does not carry
        vmFail("attempt to get length of a " .. typeName(bt) .. " value")
      }
    } else if op == 32 {
      let stp = vNum(c)
      if stp == 0.0 { vmFail("'for' step is zero") }
      if vTag(a) == 6 && (vTag(b) != 6 || vTag(c) != 6) {
        vSetNum(a, vNum(a))
      }
      let ctrl = vNum(a)
      let lim = vNum(b)
      if (stp > 0.0 && ctrl <= lim) || (stp < 0.0 && ctrl >= lim) {
        let rem = floor((lim - ctrl) / stp) + 1.0
        if 16 <= forDepth {
          vmFail("too many nested numeric loops")
        } else {
          forCtrl[forDepth] = a
          forRem[forDepth] = rem
          forDepth = forDepth + 1
          vmPc = vmPc + 2
          advanced = true
        }
      } else {
        advanced = false
      }
    } else if op == 33 {
      vmForLoop(a, c)
      advanced = true
    } else if op == 34 {
      let lt = vTag(b)
      let rt = vTag(c)
      // // coerces like the other arithmetic operators (PUC: '10' // 3 is 3), and
      // a string that will not convert says "attempt to idiv a 'string' with a
      // 'number'" where anything else says "on a <type> value".
      let lx = arithValL(lt, vNum(b), vStr(b))
      let rx = arithValR(rt, vNum(c), vStr(c))
      let lbad = coerceL == 3
      let rbad = coerceR == 3
      if lbad || rbad {
        vmFail("attempt to idiv a '" .. typeName(lt) .. "' with a '" .. typeName(rt) .. "'")
      } else if lt != 6 && lt != 1 && lt != 2 || rt != 6 && rt != 1 && rt != 2 {
        // the tag choice is hoisted out of the call: a call whose argument is a
        // folded && or || loses the operand's tag in the compiler's register
        // allocation, and a message that names the wrong type is worse than no
        // message.  compute, use, write last.
        let badT = if lt != 1 && lt != 6 && lt != 2 then lt else rt
        vmFail("attempt to perform arithmetic on a " .. typeName(badT) .. " value")
      } else {
        let li = lt == 6 || coerceL == 1
        let ri = rt == 6 || coerceR == 1
        let x = lx
        let y = rx
        if y == 0.0 {
          if li && ri {
            vmFail("attempt to divide by zero")
          } else {
            vSetNum(a, x / y)
          }
        } else if li && ri {
          let q = x / y
          let t = q | 0
          let fl = if q < 0.0 && q != t + 0.0 then t - 1 else t
          vSetInt(a, fl)
        } else {
          let q = x / y
          let t = q | 0
          let fl = if q < 0.0 && q != t + 0.0 then t - 1 else t
          vSetNum(a, fl)
        }
      }
    } else if op == 35 {
      let lt = vTag(b)
      let rt = vTag(c)
      bitFail(lt, vNum(b), rt, vNum(c))
      let na = 0.0 - vNum(b) - 1.0
      let nb = 0.0 - vNum(c) - 1.0
      let nob = na | nb
      vSetInt(a, -(nob) - 1.0)
    } else if op == 36 {
      let lt = vTag(b)
      let rt = vTag(c)
      bitFail(lt, vNum(b), rt, vNum(c))
      vSetInt(a, vNum(b) | vNum(c))
    } else if op == 37 {
      let lt = vTag(b)
      let rt = vTag(c)
      bitFail(lt, vNum(b), rt, vNum(c))
      let na = 0.0 - vNum(b) - 1.0
      let nb = 0.0 - vNum(c) - 1.0
      let nob = na | nb
      let band = -(nob) - 1.0
      vSetInt(a, vNum(b) + vNum(c) - 2.0 * band)
    } else if op == 38 {
      let vt = vTag(b)
      if vt != 6 && !(vt == 1 && vNum(b) == floor(vNum(b))) {
        vmFail("attempt to perform bitwise operation on a " .. typeName(vt) .. " value")
      }
      vSetInt(a, -(vNum(b)) - 1.0)
    } else if op == 39 {
      let lt = vTag(b)
      let rt = vTag(c)
      bitFail(lt, vNum(b), rt, vNum(c))
      vSetInt(a, vNum(b) * (2.0 ** vNum(c)))
    } else if op == 40 {
      let lt = vTag(b)
      let rt = vTag(c)
      bitFail(lt, vNum(b), rt, vNum(c))
      vSetInt(a, floor(vNum(b) / (2.0 ** vNum(c))))
    }
    if !advanced && !vmHalted {
      vmPc = vmPc + 1
      if vmPc >= bop.length() {
        vmHalted = true
      }
    }
  }
}

// A closure being filled owns the whole tick: its cells go in one per tick and
// the value is published at the end, and nothing may read it half-built. The
// step lives here rather than in vmStep: measured in the old four-step burst,
// the rare arm cost every program about a fifth of its per-tick time.
// A fast dispatch: the arms a loop body and straight-line code are made of, and
// nothing else.  Four of these plus one full vmStep is most of the 4x speed for a
// fraction of the gates, because the three extra copies never carry the helpers
// the expensive arms call - retCopy, retAdjust, tblSetKey, vmFail - and those are
// what made the full unroll 2.58x the artifact.
//
// The pc advances only when an arm in THIS step matched, which is the whole point:
// the shared tail in vmStep fires whenever `advanced` is false, and that is only
// safe because vmStep has EVERY arm.  Here the set is a range test on the opcode,
// so no arm body is edited - an earlier attempt inserted a statement per arm and
// the compiler reported a branch type mismatch three arms later, because an arm
// body whose last statement is a single expression gives the block its value.
mod vmStepFast() {
  if vmHalted || vmBusy() {
    return
  }
  let op = bop[vmPc]
  let a = bpa[vmPc]
  let b = bpb[vmPc]
  let c = bpc[vmPc]
  var advanced = false
  if op == 0 {
    vmHalted = true
    advanced = true
  } else if op == 1 {
    vSet(a, 0, 0.0, "")
  } else if op == 2 {
    if c == 1 {
      vSetIntSat(a, constNum[b])
    } else {
      vSetNum(a, constNum[b])
    }
  } else if op == 3 {
    vSet(a, 2, 0.0, constStr[b])
  } else if op == 4 {
    if b == 0 {
      vSet(a, 3, 0.0, "")
    } else {
      vSet(a, 3, 1.0, "")
    }
  } else if op == 5 {
    vSet(a, gTag(b), gNum(b), gStr(b))
  } else if op == 6 {
    // The output ports are written by outnum/outstr now, not by
    // assigning a global, so a store to a global is just a store.
    gSet(a, vTag(b), vNum(b), vStr(b))
  } else if op == 7 {
    vSet(a, vTag(b), vNum(b), vStr(b))
  } else if op >= 8 && op <= 13 {
    let immK = c < 0
    let immPack = if immK then (-1 - c) | 0 else 0
    let bt = vTag(b)
    let ct = if immK then (if (immPack & 1) == 1 then 6 else 1) else vTag(c)
    // String operands go through PUC's coercion (arithValL/arithValR), and
    // the failure message is PUC's: a string that will not convert names the
    // operator and both operand types ("attempt to add a 'string' with a
    // 'number'"), while any other non-number names the offending operand
    // ("attempt to perform arithmetic on a table value").  Both are built in
    // the failing branch, so neither concat runs on arithmetic that succeeds.
    let x = arithValL(bt, vNum(b), vStr(b))
    let y = arithValR(ct, if immK then constNum[immPack >> 1] else vNum(c), if immK then "" else vStr(c))
    let badL = coerceL == 3
    let badR = coerceR == 3
    if badL || badR || !((bt == 1 || bt == 6 || bt == 2) && (ct == 1 || ct == 6 || ct == 2)) {
      let opn = if op == 8 then "add" else if op == 9 then "sub"
        else if op == 10 then "mul" else if op == 11 then "div"
        else if op == 12 then "mod" else "pow"
      if badL || badR {
        vmFail("attempt to " .. opn .. " a '" .. typeName(bt) .. "' with a '" .. typeName(ct) .. "'")
      } else {
        // hoisted out of the call for the same reason as the LT arm: a folded
        // && as a call argument costs the operand its tag
        let badT = if bt != 1 && bt != 6 then bt else ct
        vmFail("attempt to perform arithmetic on a " .. typeName(badT) .. " value")
      }
    } else {
      // A string that converted is an integer only when ParseInt took it, so
      // '2' + 1 is 3 where '2.0' + 1 is 3.0 and 2.0 + 1 is 3.0.
      let ii = if bt == 6 then true else if bt == 2 then coerceL == 1 else false
      let ij = if ct == 6 then true else if ct == 2 then coerceR == 1 else false
      if op == 8 {
        if ii && ij {
          vSetInt(a, x + y)
        } else {
          vSetNum(a, x + y)
        }
      } else if op == 9 {
        if ii && ij {
          vSetInt(a, x - y)
        } else {
          vSetNum(a, x - y)
        }
      } else if op == 10 {
        if ii && ij {
          vSetInt(a, x * y)
        } else {
          vSetNum(a, x * y)
        }
      } else if op == 11 {
        // A zero divisor is not special-cased: the host's divide gate is
        // `x / y` on a 64-bit float, so 1/0 is inf and 0/0 is nan, which is
        // what PUC prints too.  A guard here answered 0.0 for both, and
        // 1/(0.0*-1) with it.
        vSetNum(a, x / y)
      } else if op == 12 {
        if y == 0.0 {
          if ii && ij {
            vmFail("attempt to perform 'n%0'")
          } else {
            vSetNum(a, x % y)
          }
        } else {
          // floored quotient: the floor gate truncates toward zero,
          // so adjust negative non-integral quotients down by one
          let q = x / y
          let t = q | 0
          let fl = if q < 0.0 && q != t + 0.0 then t - 1 else t
          let flf = fl + 0.0
          if ii && ij {
            vSetInt(a, x - flf * y)
          } else {
            vSetNum(a, x - flf * y)
          }
        }
      } else {
        vSetNum(a, x ** y)
      }
    }
  } else if op == 14 {
    // -v, not 0.0 - v: IEEE negation of 0.0 is -0.0, and 0.0 - 0.0 is +0.0,
    // which is how `print(-0.0)` came out "0.0".
    let nt = vTag(b)
    let nx = arithValL(nt, vNum(b), vStr(b))
    let nbad = coerceL == 3
    if nbad {
      // PUC names the operand twice for a unary op: attempt to unm a 'string'
      // with a 'string'
      vmFail("attempt to unm a '" .. typeName(nt) .. "' with a '" .. typeName(nt) .. "'")
    } else if nt != 1 && nt != 6 && nt != 2 {
      vmFail("attempt to perform arithmetic on a " .. typeName(nt) .. " value")
    } else {
      if nt == 6 || coerceL == 1 {
        vSetInt(a, -nx)
      } else {
        vSetNum(a, -nx)
      }
    }
  } else if op == 15 {
    if truthyOf(vTag(b), vNum(b)) {
      vSet(a, 3, 0.0, "")
    } else {
      vSet(a, 3, 1.0, "")
    }
  } else if op == 17 || op == 18 || op == 19 {
    let immK = c < 0
    let immConst = if immK then -1 - c else 0
    let lt = vTag(b)
    let rt = if immK then 1 else vTag(c)
    let rv = if immK then constNum[immConst] else vNum(c)
    let ln = lt == 1 || lt == 6
    let rn = rt == 1 || rt == 6
    if op == 17 {
      if ln && rn {
        vSet(a, 3, if vNum(b) == rv then 1.0 else 0.0, "")
      } else if lt != rt {
        vSet(a, 3, 0.0, "")
      } else if lt == 1 {
        vSet(a, 3, if vNum(b) == rv then 1.0 else 0.0, "")
      } else if lt == 2 {
        vSet(a, 3, if vStr(b) == vStr(c) then 1.0 else 0.0, "")
      } else if lt == 3 {
        vSet(a, 3, if vNum(b) == rv then 1.0 else 0.0, "")
      } else if lt == 4 || lt == 5 {
        vSet(a, 3, if vNum(b) == rv then 1.0 else 0.0, "")
      } else {
        vSet(a, 3, 1.0, "")
      }
    } else if ln && rn {
      let hit = if op == 18 then vNum(b) < rv else vNum(b) <= rv
      if a < 0 && op == 19 {
        if hit {
          vmPc = vmPc + 2
        } else {
          vmPc = -1 - a
        }
        advanced = true
      } else {
        vSet(a, 3, if hit then 1.0 else 0.0, "")
      }
    } else if lt == 2 && rt == 2 {
      // lexicographic string order cannot use the MathCompare gate
      // (numbers only), so compare one codepoint per vmStep instead
      cmpActive = true
      cmpAA = vmBase + b
      cmpBB = vmBase + c
      cmpDst = vmBase + a
      cmpI = 0
      cmpOp = if op == 19 then 1 else 0
      advanced = true
    } else {
      // PUC names both types, unquoted: "attempt to compare number with string"
      vmFail("attempt to compare " .. typeName(lt) .. " with " .. typeName(rt))
    }
  } else if op == 20 {
    vmPc = a
    advanced = true
  } else if op == 21 {
    if !truthyOf(vTag(b), vNum(b)) {
      vmPc = a
      advanced = true
    }
  } else if op == 22 {
    if truthyOf(vTag(b), vNum(b)) {
      vmPc = a
      advanced = true
    }
  } else if op == 24 {
    vmReturn(a)
    advanced = true
  } else if op == 33 {
    // Here for POSITION, not for what it does: the body is fifteen-odd gates with
    // no error path, but op 33 sits near the end of vmStep's 33-arm chain, so the
    // slow path spent thirty-odd failed comparisons reaching it and this arm is the
    // sixth.  On this chip a hot op costs mostly where it SITS in the chain.
    vmForLoop(a, c)
    advanced = true
  } else if op == 50 {
    forDepth = forDepth - 1
  }
  if (op <= 15 || (17 <= op && op <= 22) || op == 24 || op == 33 || op == 50)
    && !advanced && !vmHalted {
    vmPc = vmPc + 1
    if vmPc >= bop.length() {
      vmHalted = true
    }
  }
}

mod vmBurst() {
  fmtGo = true
  patGo = true
  if cloActive {
    cloStep()
  } else {
    // Four cheap dispatches and one full one.  Each vmStep re-reads the routing
    // flags, so a closure fill, a pcall or a micro-step machine that the first
    // step started is serviced by the second instead of dispatched past - which
    // is what made every upvalue program produce no output at all before the
    // guard moved out of vmBurst and into vmStep.
    vmStepFast()
    vmStepFast()
    vmStepFast()
    vmStepFast()
    vmStep()
  }
}

// The host re-pushes the SAME text to a port it already holds.  A host syncs the
// chip every tick, and a string port is a value, not an event: re-sending what it
// already sent is NOT an edit, and treating it as one re-compiled the program on
// every sync - 1114 ticks on a restart against the first run's 1113, so a second
// run was never cheaper than the run it repeated.  This is where the text is
// compared with what is loaded, and it is the only place that does so.
//
// progDirty is the "there is unparsed text" flag that the CLOCK and `sched` both
// consult.  It is set HERE, where the difference is known, rather than at each
// site that might ask for a parse - a flag set by the request sites is a flag
// three call sites have to remember, and one of them already had.
//
// A stopped chip does NOT parse.  Parsing here put a parse completion next to a
// running VM, and that is the only way the program counter and the log can come
// apart - a pc rewound without the log cleared, or registers cleared with the pc
// left mid-call.  An edit while stopped waits for the run edge and pays its parse
// then, before the first instruction rather than during one.  So this handler does
// NOT ask for a parse: the CLOCK asks, and it asks only while `run`.
//
// Text that has never run means the chip has NOT finished, even though its VM is
// idle.  The sim latches `finished` as soon as the halt is high, the error is
// empty and the queue is drained, so a chip idling over unparsed text reported
// itself done and the run ended before it was asked to do anything.  Halted is a
// claim about a PROGRAM, so it must mean "the loaded program ran to completion".
on Change(program) {
  if program != progText {
    progText = program
    // with the text, like every other finding: nameWarn is built while parsing
    nameWarn = ""
    progDirty = true
    vmHalted = false
  }
}

on Change(run) {
  if run && progOkV && !jobBusy {
    vmReset()
  }
  // The parse for text that arrived while stopped is asked for by the CLOCK, not
  // here.  A request raised in a port handler is raised and consumed inside one
  // tick, so no per-tick view of the chip could show who asked - which is why the
  // site that was actually recompiling on every restart looked innocent.  The
  // clock reads `run` fresh every tick, so it sees the edge whenever it falls.
}

// A host syncs the chip every tick, so this handler runs constantly and must not
// do work: it used to ask for a parse on every grid read, which meant a chip that
// was never asked to run parsed anyway.  It no longer asks at all - the CLOCK
// raises the request, once, while the text is unparsed, and `sched` refuses a
// request when there is nothing to compile.  A read is a read.
on ReadBrickGrid() {
}

// The ONLY place a parse starts, and the only place that can be wrong about it.
//
// There used to be a `wantParse` REQUEST as well as `progDirty`, the FACT that
// there is unparsed text, and one boolean was doing both jobs.  That is what made
// the bug invisible: a request raised while a parse was still in flight was
// indistinguishable from one being made right now, so on a restart the request
// that survived to run was the grid read's.  The chip was handed text it already
// had and recompiled it, 1114 ticks against the first run's 1113 - a second run
// that was not cheaper than the run it repeated.
//
// `progDirty` alone answers it, because only a completed parse clears it.  The
// request was a second thing to keep in step with the first, and the one that
// needed it was the one that could not be trusted.
on sched {
  if !jobBusy && progDirty {
    jobBusy = true
    emit goParse
  }
}

on goParse {
  // Before anything else, so the port says the job started even if the job then
  // fails: an `err:` line with no start above it is a chip that went quiet.
  parseInfoStart(program.Length())
  parseJobStart()
  // The library goes in front of the program, so the user's line numbers are
  // shifted by however many lines it added; libLines undoes that for errors.
  // One variable per library piece, then concatenate: the host compiler cannot
  // lower a mod call inside a binary operation, only variable + variable.
  // A piece is charged by its characters, so only pieces of a few hundred
  // characters belong here, and a comment-heavy one costs far less than its
  // length suggests now that a comment is a single Find. string.format is a
  // builtin instead (lib/str_format.lua is the reference implementation it is
  // built from, and at 11,468 characters it would not fit the source buffer at
  // all -- which is the real reason it is a gate).
  let libA = libIter(program)
  let libB = libStrIndex(program)
  let libC = libStrCase(program)
  let libD = libStrMisc(program)
  let libE = libMathConst(program)
  let libF = libMathInt(program)
  let libG = libMathTrig(program)
  let libH = libMathExp(program)
  let libI = libMathMisc(program)
  let libJ = libTabIns(program)
  let libK = libTabList(program)
  let libL = libTabConcat(program)
  let libM = libTabSort(program)
  let libN = libStrFmt(program)
  let libO = libIo(program)
  let libP = libStrPat(program)
  let libQ = libStrGsub(program)
  let libR = libStrGmatch(program)
  let libS = libTonumber(program)
  let libT = libMathRandom(program)
  let lib = libA .. libB .. libC .. libD .. libE .. libF .. libG
    .. libH .. libI .. libJ .. libK .. libL .. libM .. libN .. libO .. libP
    .. libQ .. libR .. libS .. libT
  libLines = if 0 < lib.Length() then lib.Length() - lib.Replace("\n", "").Length() else 0
  lsrc = if 0 < lib.Length() then lib .. program else program
  llen = lsrc.Length()
  lpos = 0
  lstage = 0
  lidBuf = ""
  let loop: exec
  buffer emit loop
  await loop
  lexChunk()
  if lstage != 99 && !lerr {
    buffer emit loop
  } else {
    if lerr {
      progOkV = false
      let i0 = parseInfoEnd()
      let i1 = "err: line " .. userLine(lerrLine) .. ": " .. lerrMsg
      progDebugV = i0 .. i1
      vmHalted = true
      jobBusy = false
    } else {
      emit goParse2
    }
  }
}

// Names this build does not have, and every one of them, so a single boot
// tells the user everything that is wrong instead of one thing per run.  A run of
// Find()s over text the parser already holds, once per program, at parse time.
//
// Scanned against the user's own source and not `lsrc`, because `lsrc` has the
// library pieces prepended and those are the chip's text, not the program's.
//
// A finding is advice, never a refusal: PUC also lets an undefined global read
// as nil, so the program still runs and still prints what PUC would print.  A
// typo is the common case - `in0` for `inNum0` - and it is caught by the general
// rule in gRef rather than by anything listed here, because that names every
// unresolved name instead of the ones somebody thought to write down.
mod staticAdvice(p: string) -> string {
  var h = nameWarn
  // A program that compiled to nothing RUNS, and PUC agrees -- `lua -e ""` is a
  // valid chunk that does nothing -- so this is `info: ` and never a refusal.
  // It is here because the symptom otherwise has no cause attached: the log
  // stays empty, `busy` goes low, `err` is empty and `progOk` is true, so a chip
  // whose program port was never wired looks exactly like a chip running a
  // program that has decided to print nothing, forever.  The test is the
  // bytecode rather than the source, because the four shapes a person actually
  // hits -- not wired, "", whitespace, and a comment left behind by pasting --
  // all compile to the same single RETURN0, and one comparison covers them.
  if bop.length() <= 1 {
    h = h .. "info: nothing to run: the program port is empty, or holds only"
      .. " whitespace and comments\n"
  }
  if srcUses(p, "setmetatable") || srcUsesField(p, "setmetatable")
    || srcUses(p, "getmetatable") || srcUses(p, "rawget") || srcUses(p, "rawset")
    || srcUses(p, "rawequal") || srcUses(p, "rawlen") || srcUsesField(p, "metatable") {
    h = h .. "warn: no metatables: setmetatable/getmetatable/rawget/rawset/rawequal are absent\n"
  }
  if srcUses(p, "coroutine") {
    h = h .. "warn: no coroutines\n"
  }
  if srcUses(p, "require") || srcUses(p, "module") || srcUses(p, "dofile")
    || srcUses(p, "loadfile") || srcUses(p, "loadstring") || srcUses(p, "package") {
    h = h .. "warn: no modules or file loading: require/module/dofile/loadfile/loadstring are absent\n"
  }
  if srcUsesField(p, "io") || srcUsesField(p, "os") || srcUsesField(p, "debug")
    || srcUsesField(p, "utf8") {
    h = h .. "warn: no io/os/debug/utf8 library\n"
  }
  if srcUsesField(p, "inInt0") || srcUsesField(p, "outInt0") {
    h = h .. "warn: there is no int port: one number type, so use inNum0..inNum3 and outnum(i, v) with i in 1..5\n"
  }
  if srcUsesField(p, "inVec") || srcUsesField(p, "outVec")
    || srcUsesField(p, "invecx") || srcUsesField(p, "outvec") {
    h = h .. "warn: there is no vector port: use innumarr(i) and outarr(i, v, ...) with i from 1\n"
  }
  if srcUsesField(p, "inCol") || srcUsesField(p, "outCol")
    || srcUsesField(p, "incol") || srcUsesField(p, "outcol") {
    h = h .. "warn: there is no colour port\n"
  }
  // No listing of the ports here on purpose.  It was a catch-all for a typo the
  // chip could not name, back when the only findings were a fixed list of known
  // absent names; the general rule now names every unresolved name exactly, so
  // `in1` and `prrint` each get one precise line.  A second vague line per
  // finding answers nothing, and a port list written out by hand is a mirror free
  // to drift from the ports the chip actually has.
  return h
}

on goParse2 {
  let loop: exec
  buffer emit loop
  await loop
  parseChunk()
  if !pDone && !perr {
    buffer emit loop
  } else {
    progOkV = !perr && pDone
    // A parse that has LANDED means there is no unparsed text waiting, and this is
    // the only thing that says so.  `progDirty` is what the clock's request and
    // `sched` both consult, so a completed parse is what stops the next thing that
    // asks from recompiling text that has not changed - a 615-char program cost
    // 1113 ticks on its first run and 1114 on its second, so stopping and starting
    // again re-parsed every time.
    progDirty = false
    jobBusy = false
    // Seed the input latches from the PORTS, here, before the reset copies them
    // into the globals the program reads.
    //
    // This is the fix for a value that was already on a port before the chip had
    // anything to compare it against.  The six `on Change` handlers latch a value
    // when the port CHANGES, and an edge needs a transition -- so an input wired
    // to "test" before the program started produced no edge, nothing latched it,
    // and the program read "" until the value was changed once.  A program that
    // begins here has to be able to see what is on the ports NOW, with no
    // transition required.
    //
    // It is here, in a handler body, because that is the one context where a port
    // read is known to work: it is what the six Change handlers have always done.
    // Two earlier versions read the ports from inside a MOD -- one in the clock,
    // one in vmReset -- and both broke the restart contract, so this shape is
    // what is left after ruling them out.  What broke them is NOT established:
    // each attempt changed more than one thing, so "a mod cannot read a port" is
    // a guess that fits the failures rather than a measured rule.  If someone
    // wants to settle it, the experiment is one tiny .ws -- a mod that reads a
    // port and a handler that does not -- and nothing here should be read as
    // evidence that the mod form is impossible.
    //
    // Latches, not globals, so that every LATER reset (a `run` edge, a grid read)
    // copies the same correct value.  Seeding the globals directly would be
    // undone by the next vmReset.
    latchN0 = inNum0
    latchN1 = inNum1
    latchN2 = inNum2
    latchN3 = inNum3
    latchS0 = inStr0
    latchS1 = inStr1
    vmReset()
    vmClosures()
    if perr {
      // cpos sits at (or just past) the offending token in nearly every perr
      // path, which is the line to name
      let epos = if cpos >= tl.length() then tl.length() - 1 else cpos
      let i0 = parseInfoEnd()
      let i1 = "err: line " .. userLine(if epos < 0 then lline else tl[epos])
        .. ": " .. perrMsg
      progDebugV = i0 .. i1
    } else {
      // staticAdvice into a local first: the host cannot lower a mod call inside
      // a binary operation, only variable + variable.
      let advice = staticAdvice(program)
      let i0 = parseInfoEnd()
      progDebugV = i0 .. advice
    }
  }
}

on Change(inNum0) {
  latchN0 = inNum0
  if run && progOkV && !jobBusy {
    vmReset()
  }
}

on Change(inNum1) {
  latchN1 = inNum1
  if run && progOkV && !jobBusy {
    vmReset()
  }
}

on Change(inNum2) {
  latchN2 = inNum2
  if run && progOkV && !jobBusy {
    vmReset()
  }
}

on Change(inNum3) {
  latchN3 = inNum3
  if run && progOkV && !jobBusy {
    vmReset()
  }
}

on Change(inStr0) {
  latchS0 = inStr0
  if run && progOkV && !jobBusy {
    vmReset()
  }
}

on Change(inStr1) {
  latchS1 = inStr1
  if run && progOkV && !jobBusy {
    vmReset()
  }
}



on Clock(interval = STEP_INTERVAL) {
  // The ONE place a parse is requested, for the same reason the clock is the one
  // place the VM is stepped: it reads `run` fresh every tick, so it sees the edge
  // whenever it falls.  A request raised in a port handler is raised and consumed
  // inside one tick, which is why three such sites all looked innocent when a
  // restart was recompiling text that had not changed.
  if run && progDirty && !jobBusy {
    emit sched
  }
  if run && progOkV && !vmHalted && !jobBusy {
    vmBurst()
  }
  syncOuts()
}

// Drain one patch-list entry per call; pdThen 1 restores the loop link.

// ---------------------------------------------------------------- changelog (fixes to the original)
// 1. emitTok pushed `kind` into tk twice, so tk was out of step with ts/tn/tt and every
//    program failed to parse ("not a call statement"). Removed the duplicate push.
// 2. parseInit never cleared tk/ts/tn/tt or lerr, so a second parse (chip load, then
//    Change(program)) appended to the old tokens, and one lexer error stuck forever.
// 3. `v & 0` is always 0. toInt() (function ids, so only print worked) and fmtNum
//    (print(7) showed 0.0) now use `v | 0`, which truncates the float to an int.
// 4. String < and <= advanced the pc twice (once in vmStep, once in cmpFinish), which skipped
//    the next instruction. Now sets `advanced = true` like the other branches.
// 5. `break` appended to the top control frame (the enclosing `if`), not the loop, so it was
//    never patched and jumped to pc 0. It now joins ctlC[ctlLoop].
// 6. Parallel assignment (a, b = b, a) stored into a before reading a on the right. Values are
//    now copied to temporaries first when there is more than one target.
// 7. `5.` lexed as an error although the header lists it as accepted.
// 8. Tables: constructors, t[k] / t.k reads and writes, nested tables, parallel assignment
//    to fields, # on tables and strings, table equality, type() and tostring(). Opcodes 28..31
//    (NEWT, GETI, SETI, LEN); entries live in a Map keyed by table id + key, with a free list.
// 9. `run` is now a bool level: low stops execution, a rising edge restarts, input changes
//    only restart while it is high.
// 10. Registers: 64 per function (register file 2048), temporaries are reused and freed after
//    operators, indexing, call arguments and constructor elements, `local x = expr` adopts the
//    value's register, and `x = expr` folds its store into the producing instruction.
// 11. Gate count: lexer unrolled 4x (was 32x), parser 2x (was 12x), helper mods rewritten in
//    single-expression form, exprPushName de-duplicated, builtin globals initialised from
//    constant arrays. Step Clock 0.1 s -> 0.01 s.
// 12. busy and halted merged into one busy port (pure expression over the parse job,
//    run, progDebug and the halt flag); progLen and nPrint ports dropped.
// 13. print feeds one multiline log port (one tab-separated line per call, last 32 lines
//    at 64 chars each, cleared on restart) instead of 8 slots; the 16-way slot dispatch
//    is gone, lines stream through a small array plus a string mirror.
// 14. the outputs are written by outnum/outstr calls, not by assigning globals
//    globals (mirrored to their ports once per tick); innumarr/outarr bridge 1-based
//    float arrays.
// 18. Number/string ports renamed by type: inNum0..inNum3, inStr0..inStr1,
//    outNum0..outNum3, outStr0..outStr1.
// 15. Compile failures report "line N: message" in err (token lines ride a parallel array,
//    lexer errors carry their own line).
// 16. Duplicate targets in one assignment store right to left (a, a = 1, 2 leaves 1).
// 17. Table constructors accept [k] = v with any key expression.
// 19. Function ids 6 and 7 were taken by innumarr/outarr but parseJobStart still reserved only six
//    builtin slots, so the first two user functions (and the main chunk) collided with them:
//    any program defining a function printed nothing or failed with "array index out of range".
//    It now reserves eight slots.
