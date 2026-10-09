/// Lua 5.5 in WireScript: a parser, a register VM, and the standard library,
/// on one chip.
///
/// Wire a Lua program into `program` (a string variable gate) and drive `run` high.
/// The program is lexed, parsed to flat bytecode, then executed on a register VM.
/// Numbers go in through inNum0..inNum3, strings through inStr0..inStr1, whole arrays
/// through inNumArr and inStrArr, and the program itself in the log; outNum0..outNum3,
/// outStr0..outStr1, outNumArr and outStrArr come back out and are
/// writable from Lua.
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
///   lowercase of that name -- outNum0/outStr0/outNumArr/outStrArr are written
///   by outnum, outstr, outnumarr and outstrarr, and inNumArr/inStrArr are
///   read by innumarr/instrarr.  The
///   camelCase names a program sees as VALUES (inNum0, inStr0) are the port
///   mirrors, which are values and not calls, so they keep the port's spelling.
///   out log: string       print and io.write output: a print call is one line (args
///                         tab-separated plus a newline, capped at 64 chars), an
///                         io.write is its raw text with no tab and no newline; the
///                         last 32 appends are kept, cleared on restart
///   out outNum0..outNum3: float  written by outnum(i, v), i 1..4 (nil writes 0.0;
///                         writing a string/table/function is a runtime error)
///   out outStr0..outStr1: string  written by outstr(i, v), i 1..2, Lua-formatted
///                                (nil writes "")
///   out outNumArr: float[] 16,384 slots, written 1-based via outnumarr(i, v)
///                         (nil writes 0.0).  outnumarr(i, v, ...) writes one
///                         slot per extra value, up to 8, so a run of adjacent
///                         slots costs one call instead of k; a call with more
///                         values than that writes the first 8
///   out outStrArr: string[] the same slots and the same shapes for strings,
///                         via outstrarr(i, v) and outstrarr(i, v, ...): nil
///                         writes "" and anything but a string is a runtime error
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
///              falsey one raises), and an error ENDS the run: there is no catch
///              on this chip.  pcall and xpcall are loud stub pieces that raise
///              "not supported on this chip" -- catching measured ~6,500 nodes
///              here (marker frames, resume state, result relocation, and the
///              marker test inlined into all four RETURN variants), which bought
///              back the whole size budget and then some.  A program that wants
///              to recover answers nil plus a message from its own function,
///              which is what the library pieces here already do
///
/// Not implemented yet (each is a loud error, never a wrong answer)
///   metatables               no setmetatable, no __index, no operator metamethods
///   goto and labels          a compile error
///   coroutines, modules
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
///   time, so the text goes through as it is
///   a math PIECE given a string that is not a number raises the arithmetic
///   message ("attempt to add a 'string' with a 'number'") where PUC names the
///   function ("bad argument #1 to 'abs' (number expected, got string)").  The
///   pieces convert with `x + 0.0`, and that is the raise; the _m gate gets the
///   PUC wording right because it does the conversion itself.  Loud, never wrong
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
///   os.date and os.time(t) are UTC and need an explicit time: the chip has
///   no OS timezone (a hardcoded offset would be wrong twice a year) and no
///   epoch clock (clock() is uptime), so os.time() and a dateless os.date()
///   raise "no clock" rather than answer from a clock that does not exist,
///   and a date is formatted in UTC -- a local-zone PUC differs by its own
///   offset, which is the boundary, not a bug.  os.getenv answers nil for
///   everything: the host exposes no environment, so the chip's environment
///   is empty and nil is getenv's own "not set" result (a host-set variable
///   is the one divergence).  See lib/os_date.lua and lib/os_env.lua.
///   tostring of a table is address-shaped (PUC's exact address is unstable).
///   t[nil] reads and writes raise "table index is nil". The output ports only
///   take numbers/booleans/nil, outNumArr only numbers and outStrArr only
///   strings (PUC tables take anything; fixed-size float and string storage
///   is a gate limitation). The log keeps
///   the last 32 lines at 64 chars each (about 2 KB).
///
/// Limits (a compile error past them, reported as an `err: ` line)
///   4096 tokens, 1024 bytecode instructions, 64 registers per function, 96 functions,
///   96 globals (35 pre-registered), 256 numeric and 256 string constants, 16 values
///   per expanded call/return/statement, 32 nested calls, 16 upvalues per function.
///   At run time: 64 program tables plus four library tables, 512 table entries,
///   352 closure records and 1024 upvalue cells.  The records are shared with the
///   program's own prototypes, which take the low end of the array, so a program
///   with N functions can make 352 - N closures; and a cell is three words of the
///   256-word vararg stack, so that stack is what runs out first and 1024 is a
///   ceiling rather than the limit a program meets.
///   A table entry is handed back when its key is assigned nil, and that is the
///   whole of the arena's reuse: there is no collector, so a table that grows
///   without deleting keys stops at the heap limit with "out of table memory".
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
/// innumarr/outnumarr, outnum/outstr/outstrarr and error reporting.
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
@right out outStr0: string = oS4.Value
@right out outStr1: string = oS5.Value
@right out outNumArr: float[] = outNumArrV
@right out outStrArr: string[] = outStrArrV
@right out result: string = resultV.Value
@right out err: string = errV.Value
@right out progDebug: string = progDebugV.Value
@right out busy: bool = jobBusy || (run && progOkV && !vmHalted)

// ---------------------------------------------------------------- tunables

const STEP_INTERVAL = 0.01
const MAX_INSTR = 4096
// the prepended library plus a full program; the token arrays are sized from
// this, so raising it costs gates (see tools/chip/audit.py)
const MAX_TOKENS = 4096
// Entries in the inNumArr, inStrArr, outNumArr and outStrArr ports.  A
// const rather than inNumArr.length() because an input PORT cannot be
// read during codegen - it empties every program's log - and the width
// is needed while parsing.  test_consistency checks this against
// spec.OUTARR, which is what actually sizes the array, so the two
// cannot drift without the suite going red.  The size is a memory
// bound, not a graph: the ArrayVars are resized at reset, so raising
// it costs no nodes and no per-tick gates (measured: 64 -> 16384 left
// tools/chip/audit.py at the same figure).  What it does cost is wire
// width in game: an @right out array port carries its whole array every
// tick, so 16k slots is 16k values on the wire whether or not the
// program wrote any of them.
const ARR_SLOTS = 16384
const MAX_REGS = 200
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
// PUC's limit, not ours: LUAI_MAXCCALLS is 200, and a Lua-to-Lua call really
// does take a C level (luaV_execute recurses), so PUC answers "stack overflow"
// at about this depth.  Going above it would let a program nest deeper here than
// the reference ever does -- capacity nobody asked for, and a divergence for
// anyone comparing.
const MAX_CALLS = 200
// Frames are 1-based on fnDepth (the main chunk is frame 1), so every array
// indexed by fnDepth needs one slot more than the call limit.  This used to be a
// bare 33 in twelve places and a bare 33 in four MORE that are sized by CAPTURE
// count instead -- the same number, two different meanings, which is exactly why
// raising MAX_CALLS nearly resized the wrong four.
const FRAMES = 201
// the register file is MAX_CALLS frames of MAX_REGS slots.  Spelled as a
// literal, not MAX_CALLS * MAX_REGS: a const computed from a const is one node
// more per use than the number it works out to (measured, both here).
const VREGS = 40000
const MAX_TABLES = 512
// TOTAL entries across every table, not per table -- there is no collector, so
// this is the whole budget a program gets.  PUC sets no limit here (tables grow
// until memory runs out), so the number is ours to pick and the only costs are
// reset clearing it (nine arrays this wide) and the wire width in game.  It is
// sized for a loop-filled table, not for source text: 65,536 entries holds
// 64k numbers with room for the free list to breathe, and a program that wants
// more gets "out of table memory" past the end.  Raising it costs no nodes --
// every heap array is resize()d at reset, so the width is memory, not graph --
// but every full-arena proof costs a full arena of stores, which is why the
// suite pins the mechanism at small scale and limits.py owns the ceiling.
const MAX_HEAP = 65536
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
const NB = 27

// Library sources, prepended on demand (see libIter and friends).  These are
// ordinary Lua: the parser sees them exactly like the user's program.  They are
// =============================================================================
// LIBRARY PIECES BELOW -- GENERATED, DO NOT EDIT
// =============================================================================
//
// Every `const LIB_*` line in this block is MINIFIED and MACHINE-GENERATED.
// The readable source of truth is the matching file in lib/, and a piece is
// installed only by a tool:
//
//     python -u tools/lib/libconst.py lib/<master>.lua <CONST> --install
//     python -u tools/lib/installall.py          # every piece
//
// A piece is minified because its character count IS boot cost: a library
// function is not a gate, it is Lua source prepended to the program, so every
// character a piece carries is a tick every program naming that function waits
// for, before it has run one instruction.  lib/constmap.txt says which master
// builds which const -- nothing can infer it, because a master's text stops
// matching its const the moment it is installed, which is the point of
// installing it.
//
// To change a library function: edit its master in lib/, run the installer,
// and run the suite.  Do NOT edit a const here.  Two reasons, and both are
// silent:
//
//   * a hand-edited const and its master disagree, and nothing notices -- the
//     piece still parses and still runs, it just is not the piece lib/ says.
//     `python -u tools/lib/constcheck.py` is what notices, and it is in
//     preflight for that reason.
//   * a const that fails to PARSE is not an error any program can see.  Every
//     function in the piece simply stops answering, with no message and no
//     line.  Four pieces were broken this way for a session before anything
//     reported it.
//
// Deliberately NOT installed: lib/str_format.lua, lib/gmatch.lua and
// lib/str_gsub_str.lua are PUC-verified reference implementations for features
// that are gates.  string.format cannot be a piece at all (11,468 characters
// does not fit the ~4 KB source buffer) and gmatch cannot be one because it
// has to suspend mid-pattern-match and resume.
// =============================================================================

// split per family because lexing them is the cost -- a program that names one
// string function pays for one family, not for all eight.
// Library functions are written as field assignments, not `function string.f`:
// the parser does not take a dotted name on `function` yet.
const LIB_iter = "function _ipairs_iter(a, b) b = b + 1 local c = a[b] if c ~= nil then return b, c end end\nfunction ipairs(a) return _ipairs_iter, a, 0 end\nfunction pairs(a) return next, a, nil, nil end\n"
const LIB_str_index = "string = string or {}\nstring.len = function(...)\nlocal a = select('#', ...) == 0\nlocal b = select(1, ...)\nlocal c = type(b)\nif c == \"number\" then\nb = tostring(b)\nelseif c ~= \"string\" then\nlocal d = c\nif a then d = \"no value\" end\nerror(\"bad argument #1 to 'string.len' (string expected, got \" .. d .. \")\", 2)\nend\nreturn #b\nend\nstring.sub = function(...)\nlocal a = select('#', ...) == 0\nlocal b, e, f = select(1, ...)\nlocal c = type(b)\nif c == \"number\" then\nb = tostring(b)\nelseif c ~= \"string\" then\nlocal d = c\nif a then d = \"no value\" end\nerror(\"bad argument #1 to 'string.sub' (string expected, got \" .. d .. \")\", 2)\nend\nlocal g = #b\ne = e or 1\nf = f or -1\nif e < 0 then e = g + e + 1 if e < 1 then e = 1 end elseif e == 0 then e = 1 end\nif f < 0 then f = g + f + 1 elseif f > g then f = g end\nif e > f then return \"\" end\nreturn _s(1, b, e - 1, f - e + 1)\nend\n"
const LIB_str_fmt = "string = string or {}\nstring.format = _fmt\n"
// The wrappers pass their arguments straight through rather than naming them:
// a named parameter pads a missing one with nil, and PUC's "got no value" and
// "got nil" are different messages.  A vararg call keeps the real count.
const LIB_str_pat = "string = string or {}\nstring.find = function(...) return _pat(0, ...) end\nstring.match = function(...) return _pat(1, ...) end\n"
// gmatch is a gate that answers all three values itself, so the piece is the
// binding and nothing else: 25 characters, where the gsub piece is 3109.
const LIB_str_gmatch = "string = string or {}\nstring.gmatch = _gmatch\n"
const LIB_str_case = "string = string or {}\nstring.upper = function(...)\nlocal a = select('#', ...) == 0\nlocal b = select(1, ...)\nlocal c = type(b)\nif c == \"number\" then\nb = tostring(b)\nelseif c ~= \"string\" then\nlocal d = c\nif a then d = \"no value\" end\nerror(\"bad argument #1 to 'string.upper' (string expected, got \" .. d .. \")\", 2)\nend\nreturn _s(2, b)\nend\nstring.lower = function(...)\nlocal a = select('#', ...) == 0\nlocal b = select(1, ...)\nlocal c = type(b)\nif c == \"number\" then\nb = tostring(b)\nelseif c ~= \"string\" then\nlocal d = c\nif a then d = \"no value\" end\nerror(\"bad argument #1 to 'string.lower' (string expected, got \" .. d .. \")\", 2)\nend\nreturn _s(3, b)\nend\n"
const LIB_str_misc = "string = string or {}\nstring.rep = function(...)\nlocal a = select('#', ...)\nif a == 0 then\nerror(\"bad argument #1 to 'string.rep' (string expected, got no value)\", 2)\nend\nlocal b, c, d = select(1, ...)\nlocal e = type(b)\nif e == \"number\" then\nb = tostring(b)\nelseif e ~= \"string\" then\nerror(\"bad argument #1 to 'string.rep' (string expected, got \" .. e .. \")\", 2)\nend\nif a < 2 then\nerror(\"bad argument #2 to 'string.rep' (number expected, got no value)\", 2)\nend\nlocal f = type(c)\nlocal g = c\nif f ~= \"number\" and f ~= \"string\" then\nerror(\"bad argument #2 to 'string.rep' (number expected, got \" .. f .. \")\", 2)\nend\nif f == \"string\" then\nlocal h = _m(15, c, 0)\nif h == nil then\nerror(\"bad argument #2 to 'string.rep' (number expected, got string)\", 2)\nend\ng = h\nend\nlocal j = _m(13, g, 0)\nif j == nil then\nerror(\"bad argument #2 to 'string.rep' (number has no integer representation)\", 2)\nend\nc = j\nif d == nil then\nd = \"\"\nelse\nlocal l = type(d)\nif l == \"number\" then\nd = tostring(d)\nelseif l ~= \"string\" then\nerror(\"bad argument #3 to 'string.rep' (string expected, got \" .. l .. \")\", 2)\nend\nend\nif c <= 0 then return \"\" end\nlocal m = \"\"\nlocal o = b\nlocal p = c\nlocal q = false\nwhile 0 < p do\nif p % 2 == 1 then\nif q then\nm = m .. d .. o\nelse\nm = o\nq = true\nend\nend\np = (p - p % 2) / 2\nif 0 < p then o = o .. d .. o end\nend\nreturn m\nend\nstring.reverse = function(...)\nlocal u = select('#', ...) == 0\nlocal b = select(1, ...)\nlocal x = type(b)\nif x == \"number\" then\nb = tostring(b)\nelseif x ~= \"string\" then\nlocal y = x\nif u then y = \"no value\" end\nerror(\"bad argument #1 to 'string.reverse' (string expected, got \" .. y .. \")\", 2)\nend\nlocal m = \"\"\nfor z = #b, 1, -1 do m = m .. _s(1, b, z - 1, 1) end\nreturn m\nend\n"
const LIB_math_const = "math = math or {}\nmath.pi = 3.141592653589793\nmath.huge = 1.7976931348623157e308\nmath.maxinteger = 9223372036854775807\nmath.mininteger = -9223372036854775808\n"
const LIB_math_int = "math = math or {}\nlocal function _ult_num(f)\nreturn f + 0\nend\nmath.ult = function(...)\nlocal c = select(\"#\", ...)\nif c == 0 then\nerror(\"bad argument #1 to 'math.ult' (number expected, got no value)\", 2)\nend\nlocal d = select(1, ...)\nlocal e = type(d)\nif e ~= \"number\" and e ~= \"string\" then\nerror(\"bad argument #1 to 'math.ult' (number expected, got \" .. e .. \")\", 2)\nend\nif e == \"string\" then\nlocal f = _m(15, d, 0)\nif f == nil then\nerror(\"bad argument #1 to 'math.ult' (number expected, got string)\", 2)\nend\nd = f\nend\nlocal g = _m(13, d, 0)\nif g == nil then\nerror(\"bad argument #1 to 'math.ult' (number has no integer representation)\", 2)\nend\nif c < 2 then\nerror(\"bad argument #2 to 'math.ult' (number expected, got no value)\", 2)\nend\nlocal h = select(2, ...)\nlocal i = type(h)\nif i ~= \"number\" and i ~= \"string\" then\nerror(\"bad argument #2 to 'math.ult' (number expected, got \" .. i .. \")\", 2)\nend\nif i == \"string\" then\nlocal j = _m(15, h, 0)\nif j == nil then\nerror(\"bad argument #2 to 'math.ult' (number expected, got string)\", 2)\nend\nh = j\nend\nlocal k = _m(13, h, 0)\nif k == nil then\nerror(\"bad argument #2 to 'math.ult' (number has no integer representation)\", 2)\nend\nif g < 0 then\nif k < 0 then\nreturn g < k\nelse\nreturn false\nend\nelse\nif k < 0 then\nreturn true\nelse\nreturn g < k\nend\nend\nend\nmath.floor = function(l) return _m(1, l, 0) end\nmath.ceil = function(l) return _m(2, l, 0) end\nmath.tointeger = function(l) return _m(13, l, 0) end\nmath.type = function(l) return _m(14, l, 0) end\nmath.abs = function(l) if type(l) == \"string\" then l = l + 0.0 end if l < 0 then return -l end if l == 0 then return l - l end return l end\nmath.sqrt = function(l) return _m(3, l, 0) end\n"
const LIB_math_trig = "math = math or {}\nmath.sin = function(a) return _m(4, a, 0) end\nmath.cos = function(a) return _m(5, a, 0) end\nmath.tan = function(a) return _m(6, a, 0) end\nmath.asin = function(a) return _m(7, a, 0) end\nmath.acos = function(a) return _m(8, a, 0) end\nmath.atan = function(b, a) return _m(9, b, a or 1) end\nmath.deg = function(a) return a * 57.295779513082323 end\nmath.rad = function(a) return a * 0.017453292519943295 end\n"
const LIB_math_exp = "math = math or {}\nmath.exp = function(a) return _m(10, a, 0) end\nmath.log = function(a, c)\nif c == nil then return _m(11, a, 0) end\nif c == 10 then return _m(12, a, 0) end\nreturn _m(11, a, 0) / _m(11, c, 0)\nend\nmath.ldexp = function(a, d) return a * (2.0 ^ d) end\n"
const LIB_tab_concat = "table = table or {}\ntable.concat = function(a, b, c, d)\nb = b or \"\"\nc = c or 1\nd = d or #a\nlocal e = \"\"\nfor f = c, d do\nlocal g = a[f]\nif f > c then e = e .. b end\ne = e .. g\nend\nreturn e\nend\n"
const LIB_tab_sort = "table = table or {}\n_lt = function(c, d) return c < d end\ntable.sort = function(e, f)\nlocal g = f or _lt\nfor h = 2, #e do\nlocal k = e[h]\nlocal l = h - 1\nwhile l >= 1 and g(k, e[l]) do e[l + 1] = e[l] l = l - 1 end\ne[l + 1] = k\nend\nend\n"
const LIB_io = "io = io or {}\nio.read = function(...) if select('#', ...) == 0 then return _rd('*l') end return _rd((...)) end\nio.write = function(...) for a = 1, select('#', ...) do _wr(tostring((select(a, ...)))) end end\n_io_next = function() local b = _rd('*l') if b == nil then return nil end return b end\nio.lines = function() _rd('*r') return _io_next end\n"
const LIB_str_gsub = "string = string or {}\nstring.gsub = function(c, e, f, g)\nif type(c) == \"number\" then c = tostring(c) end\nlocal h, l, t, u, x = #c, \"\", 1, 0, -1\nlocal y = _s(1, e, 0, 1) == \"^\"\nlocal z = type(f)\nif f == nil then error(\"bad argument #3 to 'string.gsub' (string/function/table expected, got no value)\", 2) end\nif z == \"number\" then f = tostring(f) z = \"string\" end\nlocal aa = function(v)\nlocal tv = type(v)\nif tv == \"string\" then return v end\nif tv == \"number\" then return tostring(v) end\nif tv == \"boolean\" then error(\"invalid replacement value (a boolean)\", 2) end\nerror(\"invalid replacement value (a \" .. tv .. \")\", 2)\nend\nlocal ab = function(kt, kr, aa, ac, m)\nif kt == \"function\" then\nlocal v, w\nif ac[3] == 0 then v, w = kr(m) else v, w = kr(unpack(ac, 4, 3 + ac[3])) end\nif v == nil or v == false then return m end\nif w == nil or w == false then return aa(v) end\nreturn aa(v) .. aa(w)\nelseif kt == \"table\" then\nlocal k = m\nif ac[3] > 0 then k = ac[4] end\nlocal v = kr[k]\nif v == nil or v == false then return m end\nreturn aa(v)\nelse\nlocal o, i, rl = \"\", 1, #kr\nwhile i <= rl do\nlocal j = string.find(kr, \"%\", i, true)\nif j == nil then o = o .. _s(1, kr, i - 1, rl - i + 1) break end\nif i < j then o = o .. _s(1, kr, i - 1, j - i) end\nif j == rl then error(\"invalid use of '%' in replacement string\", 2) end\nlocal d = _s(1, kr, j, 1)\nif d == \"%\" then o = o .. \"%\"\nelseif d == \"0\" then o = o .. m\nelse\nlocal q = _s(4, d, 0, 0) - 48\nif q < 1 or 9 < q then error(\"invalid use of '%' in replacement string\", 2) end\nif 1 < q and ac[3] < q then error(\"invalid capture index %\" .. d, 2) end\nif q == 1 and ac[3] == 0 then o = o .. m else o = o .. aa(ac[q + 3]) end\nend\ni = j + 2\nend\nreturn o\nend\nend\nif z ~= \"string\" and z ~= \"table\" and z ~= \"function\" then error(\"bad argument #3 to 'string.gsub' (string/function/table expected, got \" .. z .. \")\", 2) end\nif g == nil then g = h + 1 end\nif type(g) ~= \"number\" then error(\"bad argument #4 to 'string.gsub' (number expected, got \" .. type(g) .. \")\", 2) end\ng = _m(13, g, 0)\nif g == nil then error(\"bad argument #4 to 'string.gsub' (number has no integer representation)\", 2) end\nif g < 1 then return c, 0 end\nwhile u < g do\nlocal ac = {_pat(2, c, e, t)}\nif ac[1] == nil then break end\nlocal ad, ae = ac[1], ac[2]\nif ae == x then\nif t <= h then l = l .. _s(1, c, t - 1, 1) t = t + 1 else break end\nelse\nif t < ad then l = l .. _s(1, c, t - 1, ad - t) end\nl = l .. ab(z, f, aa, ac, _s(1, c, ad - 1, ae - ad + 1))\nu = u + 1\nt = ae + 1\nend\nx = ae\nif y then break end\nend\nreturn l .. _s(1, c, t - 1, h - t + 1), u\nend\n"
const LIB_tonumber = "tonumber = function(...)\nlocal a = select(\"#\", ...)\nlocal b = select(1, ...)\nlocal c = select(2, ...)\nif a == 0 then\nerror(\"bad argument #1 to 'tonumber' (value expected)\", 2)\nend\nif c ~= nil then\nif type(b) ~= \"string\" then\nerror(\"bad argument #1 to 'tonumber' (string expected, got \" .. type(b) .. \")\", 2)\nend\nif c < 2 or c > 36 then\nerror(\"bad argument #2 to 'tonumber' (base out of range)\", 2)\nend\nreturn _tonum_int(b, c)\nend\nif type(b) == \"number\" then return b end\nif type(b) ~= \"string\" then return nil end\nlocal d = _m(15, b, 0)\nif d ~= nil then return d end\nif _pat(0, b, \"0x\", 1, 1) or _pat(0, b, \"0X\", 1, 1) then return _tonum_hex(b) end\nreturn nil\nend\n"
const LIB_math_random = "math = math or {}\nlocal _rs = 12345\nmath.random = function(c, d, ...)\nif select(\"#\", c, d, ...) > 2 then\nerror(\"wrong number of arguments\", 2)\nend\nlocal e = (_rs * 1664525 + 1013904223) & 0xFFFFFFFF\n_rs = e\nif c == nil then\nreturn e / 4294967296.0\nend\nif type(c) == \"string\" then c = c + 0 end\nif _m(13, c, 0) == nil then\nerror(\"bad argument #1 to 'random' (number has no integer representation)\", 2)\nend\nlocal f, g\nif d == nil then\nf, g = 1, c\nelse\nif type(d) == \"string\" then d = d + 0 end\nif _m(13, d, 0) == nil then\nerror(\"bad argument #2 to 'random' (number has no integer representation)\", 2)\nend\nf, g = c, d\nargn = \"2\"\nend\nif g < f then\nerror(\"bad argument #1 to 'random' (interval is empty)\", 2)\nend\nreturn f + _m(1, e / 4294967296.0 * (g - f + 1), 0)\nend\nmath.randomseed = function(h, i)\nlocal j = 0\nlocal k = 0\nif h ~= nil then j = _m(1, h, 0) end\nif i ~= nil then k = _m(1, i, 0) end\nlocal l = (j * 1013904223 + k) & 0xFFFFFFFF\nif l == 0 then l = 1 end\n_rs = l\nreturn j, k\nend\n"
const LIB_io_stderr = "io = io or {}\nio.stderr = {\nwrite = function(a, ...)\nfor b = 1, select(\"#\", ...) do _wr(tostring((select(b, ...)))) end\nreturn a\nend,\nflush = function(a) return a end,\n}\n"
const LIB_os_exit = "os = os or {}\nos.exit = function(a)\nif a == nil or a == true or a == 0 then error(\"\", 0) else error(\"exit: \" .. tostring(a), 0) end\nend\n"
const LIB_tonumber_hex = "local function _tonum_hex(s)\nlocal a = #s\nlocal c = 0\nlocal d = 0\nwhile c < a do\nd = _s(4, s, c, 0)\nif d ~= 32 and d ~= 9 and d ~= 10 and d ~= 13 and d ~= 12 and d ~= 11 then break end\nc = c + 1\nend\nlocal e = a - 1\nwhile e >= c do\nd = _s(4, s, e, 0)\nif d ~= 32 and d ~= 9 and d ~= 10 and d ~= 13 and d ~= 12 and d ~= 11 then break end\ne = e - 1\nend\nif c > e then return nil end\nlocal f = false\nd = _s(4, s, c, 0)\nif d == 43 or d == 45 then\nf = d == 45\nc = c + 1\nend\nif _s(1, s, c, 2) ~= \"0x\" and _s(1, s, c, 2) ~= \"0X\" then return nil end\nc = c + 2\nlocal g = 0\nlocal h = 0\nlocal k = 0\nlocal l = 0\nlocal o = false\nlocal p = 0\nlocal q = false\nwhile c <= e do\nd = _s(4, s, c, 0)\nlocal r = nil\nif d >= 48 and d <= 57 then r = d - 48 end\nif d >= 65 and d <= 70 then r = d - 55 end\nif d >= 97 and d <= 102 then r = d - 87 end\nif r == nil then break end\nl = l + 1\nif r ~= 0 or o then\no = true\nif h < 13 then\ng = g * 16 + r\nh = h + 1\nelseif k == 0 then\np = r\nk = k + 1\nelse\nif r ~= 0 then q = true end\nk = k + 1\nend\nend\nc = c + 1\nend\nif p > 8 or (p == 8 and (q or g % 2 == 1)) then\ng = g + 1\nend\nlocal t = 0\nlocal u = 0\nlocal w = false\nlocal x = true\nif c <= e and _s(4, s, c, 0) == 46 then\nx = false\nc = c + 1\nlocal y = 0\nwhile c <= e do\nd = _s(4, s, c, 0)\nlocal r = nil\nif d >= 48 and d <= 57 then r = d - 48 end\nif d >= 65 and d <= 70 then r = d - 55 end\nif d >= 97 and d <= 102 then r = d - 87 end\nif r == nil then break end\nl = l + 1\nu = u + 1\nif r ~= 0 or w then\nw = true\nif y < 13 then\nt = t * 16 + r\ny = y + 1\nend\nend\nc = c + 1\nend\nend\nif l == 0 then return nil end\nlocal z = 0\nlocal aa = true\nif c <= e then\nd = _s(4, s, c, 0)\nif d == 112 or d == 80 then\naa = false\nc = c + 1\nlocal ab = false\nif c <= e then\nd = _s(4, s, c, 0)\nif d == 43 or d == 45 then\nab = d == 45\nc = c + 1\nend\nend\nlocal ac = 0\nwhile c <= e do\nd = _s(4, s, c, 0)\nif d < 48 or d > 57 then break end\nz = z * 10 + (d - 48)\nac = ac + 1\nc = c + 1\nend\nif ac == 0 then return nil end\nif ab then z = -z end\nend\nend\nif c <= e then return nil end\nif x and aa then\nlocal ad = g\nif k ~= 0 then ad = g * (16 ^ k) end\nif ad < 9007199254740992 then\nlocal ae = _m(13, ad, 0)\nif ae ~= nil then\nif f then ae = -ae end\nreturn ae\nend\nend\nend\nlocal af = 0\nif g ~= 0 then af = g * (2 ^ (4 * k + z)) end\nif u > 0 and t ~= 0 then af = af + t * (2 ^ (-4 * u + z)) end\nif af == 0 then\nif f then return -0.0 else return 0.0 end\nend\nif f then af = -af end\nreturn af\nend\n"
const LIB_tab_unpack = "table = table or {}\ntable.unpack = unpack\n"
const LIB_tab_pack = "table = table or {}\ntable.pack = function(...) local a = {...} a.n = select('#', ...) return a end\ntable.move = function(b, c, d, a, g)\ng = g or b\nif d >= c then\nif a > d or a <= c or b ~= g then\nfor h = 0, d - c do g[a + h] = b[c + h] end\nelse\nfor h = d - c, 0, -1 do g[a + h] = b[c + h] end\nend\nend\nreturn g\nend\n"
const LIB_math_maxmin = "math = math or {}\nmath.max = function(b, ...)\nlocal c = b\nfor d = 1, select('#', ...) do local e = select(d, ...) if e > c then c = e end end\nreturn c\nend\nmath.min = function(b, ...)\nlocal c = b\nfor d = 1, select('#', ...) do local e = select(d, ...) if e < c then c = e end end\nreturn c\nend\n"
const LIB_math_fmodmodf = "math = math or {}\nmath.fmod = function(c, d)\nif type(c) == \"string\" then c = c + 0.0 end\nif type(d) == \"string\" then d = d + 0.0 end\nlocal e = c % d\nif e ~= 0 and (c < 0) ~= (d < 0) then e = e - d end\nreturn e\nend\nmath.modf = function(f) if type(f) == \"string\" then f = f + 0.0 end local g = (f >= 0 and _m(1, f, 0)) or _m(2, f, 0) return g, f - g end\n"
const LIB_tab_insert = "table = table or {}\ntable.insert = function(a, ...)\nlocal b = #a\nlocal d = select('#', ...)\nif d == 1 then\na[b + 1] = (...)\nelseif d == 2 then\nlocal e, f = ...\nlocal g = _m(13, e, 0)\nif g == nil then\nerror(\"bad argument #2 to 'table.insert' (number has no integer representation)\", 2)\nend\nif g < 1 or g > b + 1 then\nerror(\"bad argument #2 to 'table.insert' (position out of bounds)\", 2)\nend\nfor h = b, g, -1 do a[h + 1] = a[h] end\na[g] = f\nelse\nerror(\"wrong number of arguments to 'insert'\", 2)\nend\nend\n"
const LIB_tab_remove = "table = table or {}\ntable.remove = function(a, b)\nlocal c = #a\nif b == nil then b = c end\nlocal d = _m(13, b, 0)\nif d == nil then\nerror(\"bad argument #2 to 'table.remove' (number has no integer representation)\", 2)\nend\nif d ~= c and (d < 1 or c + 1 < d) then error(\"bad argument #2 to 'table.remove' (position out of bounds)\", 2) end\nlocal e = a[d]\nlocal f = d\nwhile f < c do a[f] = a[f + 1] f = f + 1 end\na[f] = nil\nreturn e\nend\n"
const LIB_str_byte = "string = string or {}\nstring.byte = function(...)\nlocal a = select('#', ...) == 0\nlocal b, c, d = select(1, ...)\nlocal e = type(b)\nif e == \"number\" then\nb = tostring(b)\nelseif e ~= \"string\" then\nlocal f = e\nif a then f = \"no value\" end\nerror(\"bad argument #1 to 'string.byte' (string expected, got \" .. f .. \")\", 2)\nend\nc = c or 1\nd = d or c\nif c < 0 then c = #b + c + 1 end\nif d < 0 then d = #b + d + 1 end\nif c < 1 then c = 1 end\nif d > #b then d = #b end\nif c > d then return end\nif c == d then return _s(4, b, c - 1, 0) end\nlocal g = {}\nfor h = c, d do g[#g + 1] = _s(4, b, h - 1, 0) end\nreturn unpack(g, 1, #g)\nend\n"
const LIB_str_char = "string = string or {}\nstring.char = function(...)\nlocal a = \"\"\nfor b = 1, select('#', ...) do a = a .. _s(5, \"\", select(b, ...), 0) end\nreturn a\nend\n"
const LIB_tonumber_base = "local function _tonum_int(s, base)\nlocal a = #s\nlocal c = 0\nlocal e = 0\nwhile c < a do\ne = _s(4, s, c, 0)\nif e ~= 32 and e ~= 9 and e ~= 10 and e ~= 13 and e ~= 12 and e ~= 11 then break end\nc = c + 1\nend\nlocal f = a - 1\nwhile f >= c do\ne = _s(4, s, f, 0)\nif e ~= 32 and e ~= 9 and e ~= 10 and e ~= 13 and e ~= 12 and e ~= 11 then break end\nf = f - 1\nend\nif c > f then return nil end\nlocal g = false\ne = _s(4, s, c, 0)\nif e == 43 or e == 45 then\ng = e == 45\nc = c + 1\nend\nlocal h = 0\nlocal k = 0\nlocal l = 0\nlocal o = false\nlocal p = 0\nwhile c <= f do\ne = _s(4, s, c, 0)\nlocal q = nil\nif e >= 48 and e <= 57 then q = e - 48 end\nif e >= 65 and e <= 90 then q = e - 55 end\nif e >= 97 and e <= 122 then q = e - 87 end\nif q == nil or q >= base then break end\np = p + 1\nif q ~= 0 or o then\no = true\nif k < 10 then\nh = h * base + q\nk = k + 1\nelse\nl = l + 1\nend\nend\nc = c + 1\nend\nif p == 0 or c <= f then return nil end\nlocal r = h\nif h == 0 then\nr = 0\nelseif l > 0 then\nr = h * (base ^ l)\nend\nif g then r = -r end\nlocal t = _m(13, r, 0)\nif t ~= nil then return t end\nreturn r\nend\n"
const LIB_bit32 = "bit32 = bit32 or {}\nbit32.bnot = function(c) return ~c & 0xFFFFFFFF end\nbit32.band = function(d, e, g, ...)\nif not g then\nreturn ((d or -1) & (e or -1)) & 0xFFFFFFFF\nelse\nlocal h = {...}\nlocal j = d & e & g\nfor k = 1, #h do j = j & h[k] end\nreturn j & 0xFFFFFFFF\nend\nend\nbit32.bor = function(d, e, g, ...)\nif not g then\nreturn ((d or 0) | (e or 0)) & 0xFFFFFFFF\nelse\nlocal h = {...}\nlocal j = d | e | g\nfor k = 1, #h do j = j | h[k] end\nreturn j & 0xFFFFFFFF\nend\nend\nbit32.bxor = function(d, e, g, ...)\nif not g then\nreturn ((d or 0) ~ (e or 0)) & 0xFFFFFFFF\nelse\nlocal h = {...}\nlocal j = d ~ e ~ g\nfor k = 1, #h do j = j ~ h[k] end\nreturn j & 0xFFFFFFFF\nend\nend\nbit32.btest = function(...) return bit32.band(...) ~= 0 end\nbit32.lshift = function(c, l)\nif l * l >= 1024 then return 0 end\nc = c & 0xFFFFFFFF\nif l < 16 then return (c << l) & 0xFFFFFFFF end\nreturn ((c % 65536) << l) & 0xFFFFFFFF\nend\nbit32.rshift = function(c, l)\nif l * l >= 1024 then return 0 end\nreturn ((c & 0xFFFFFFFF) >> l) & 0xFFFFFFFF\nend\nbit32.arshift = function(c, l)\nc = c & 0xFFFFFFFF\nif l <= 0 or (c & 0x80000000) == 0 then\nreturn (c >> l) & 0xFFFFFFFF\nelse\nreturn ((c >> l) | ~(0xFFFFFFFF >> l)) & 0xFFFFFFFF\nend\nend\nbit32.lrotate = function(c, l)\nl = l & 31\nc = c & 0xFFFFFFFF\nc = bit32.lshift(c, l) | (c >> (32 - l))\nreturn c & 0xFFFFFFFF\nend\nbit32.rrotate = function(c, l) return bit32.lrotate(c, -l) end\nlocal function m(n, o)\no = o or 1\nassert(n >= 0, \"field cannot be negative\")\nassert(o > 0, \"width must be positive\")\nassert(n + o <= 32, \"trying to access non-existent bits\")\nreturn n, ~(-1 << o)\nend\nbit32.extract = function(c, n, o)\nlocal n, p = m(n, o)\nreturn (c >> n) & p\nend\nbit32.replace = function(c, q, n, o)\nlocal n, p = m(n, o)\nq = q & p\nc = (c & ~(p << n)) | (q << n)\nreturn c & 0xFFFFFFFF\nend\n"
const LIB_utf8 = "utf8 = utf8 or {}\nlocal _floor = {0, 0x80, 0x800, 0x10000, 0x200000, 0x4000000}\nlocal function a(p, q, u)\nlocal b = _s(4, p, q - 1, 0)\nif b == nil then return nil end\nif b < 0x80 then return b, 1 end\nlocal e, f\nif b < 0xC2 then return nil end\nif b < 0xE0 then e, f = 2, b & 0x1F\nelseif b < 0xF0 then e, f = 3, b & 0x0F\nelseif b < 0xF8 then e, f = 4, b & 0x07\nelseif b < 0xFC then e, f = 5, b & 0x03\nelseif b < 0xFE then e, f = 6, b & 0x01\nelse return nil end\nfor g = 1, e - 1 do\nlocal h = _s(4, p, q + g - 1, 0)\nif h == nil or h < 0x80 or h > 0xBF then return nil end\nf = f * 64 + (h & 0x3F)\nend\nif f < _floor[e] then return nil end\nif u then\nif f >= 0x80000000 then return nil end\nelseif f > 0x10FFFF or (f >= 0xD800 and f <= 0xDFFF) then\nreturn nil\nend\nreturn f, e\nend\nlocal function l(p, g)\nwhile g > 1 do\nlocal b = _s(4, p, g - 1, 0)\nif b == nil or b < 0x80 or b >= 0xC0 then break end\ng = g - 1\nend\nreturn g\nend\nlocal function m(p, q, what)\nlocal o = #p\nif q == nil then return nil end\nif q < 0 then q = o + q + 1 end\nif q < 1 or q > o + 1 then\nerror(\"bad argument #3 to '\" .. what .. \"' (position out of bounds)\", 3)\nend\nreturn q, o\nend\nutf8.len = function(p, q, t, u)\nlocal e = #p\nq = q or 1\nt = t or e\nif q < 0 then q = e + q + 1 end\nif t < 0 then t = e + t + 1 end\nif q < 1 or q > e + 1 then\nerror(\"bad argument #2 to 'utf8.len' (initial position out of bounds)\", 2)\nend\nif t < 0 or t > e then\nerror(\"bad argument #3 to 'utf8.len' (final position out of bounds)\", 2)\nend\nlocal g, x = q, 0\nwhile g <= t do\nlocal _, y = a(p, g, u)\nif y == nil then return nil, g end\ng, x = g + y, x + 1\nend\nreturn x\nend\nutf8.offset = function(p, e, q)\nlocal o = #p\nif e == 0 then\nq, o = m(p, q or 1, \"utf8.offset\")\nq = l(p, q)\nlocal _, y = a(p, q, true)\nif y == nil then return nil end\nreturn q, q + y - 1\nend\nif e > 0 then\nq, o = m(p, q or 1, \"utf8.offset\")\nlocal g, y = q, 1\nfor t = 1, e do\nif g > o + 1 then return nil end\nif g == o + 1 then\nif t == e then return g, g end\nreturn nil\nend\nlocal _, z = a(p, g, true)\nif z == nil then return nil end\ng, y = g + z, z\nend\nreturn g - y, g - 1\nend\nq, o = m(p, q or o + 1, \"utf8.offset\")\nlocal g, y = q, 1\nfor _ = 1, -e do\nif g <= 1 then return nil end\ng = l(p, g - 1)\nlocal _, z = a(p, g, true)\nif z == nil then return nil end\ny = z\nend\nreturn g, g + y - 1\nend\nutf8.codepoint = function(p, q, t, u)\nlocal e = #p\nq = q or 1\nt = t or q\nif q < 0 then q = e + q + 1 end\nif t < 0 then t = e + t + 1 end\nif q < 1 or q > e + 1 then\nerror(\"bad argument #2 to 'utf8.codepoint' (out of bounds)\", 2)\nend\nif t > e then\nerror(\"bad argument #3 to 'utf8.codepoint' (out of bounds)\", 2)\nend\nif t < q then return end\nlocal x = {}\nlocal g = q\nwhile g <= t do\nlocal f, y = a(p, g, u)\nif y == nil then error(\"invalid UTF-8 code\", 2) end\nx[#x + 1] = f\ng = g + y\nend\nreturn unpack(x, 1, #x)\nend\n"
const LIB_utf8_char = "utf8 = utf8 or {}\nlocal _lim = {0x80, 0x800, 0x10000, 0x200000, 0x4000000}\nlocal _lead = {0, 0xC0, 0xE0, 0xF0, 0xF8, 0xFC}\nutf8.char = function(...)\nlocal a = \"\"\nfor b = 1, select('#', ...) do\nlocal c = select(b, ...)\nif c < 0 or c >= 0x80000000 then\nerror(\"bad argument #1 to 'utf8.char' (value out of range)\", 2)\nend\nif c < 0x80 then\na = a .. _s(5, \"\", c, 0)\nelse\nlocal d = 2\nwhile d < 6 and c >= _lim[d] do d = d + 1 end\na = a .. _s(5, \"\", _lead[d] + (c >> (6 * (d - 1))), 0)\nfor e = d - 2, 0, -1 do\na = a .. _s(5, \"\", 0x80 + ((c >> (6 * e)) & 0x3F), 0)\nend\nend\nend\nreturn a\nend\n"
const LIB_os_date = "os = os or {}\nlocal function a(p)\nreturn (p % 4 == 0 and p % 100 ~= 0) or p % 400 == 0\nend\nlocal _md = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}\nlocal _mn = {\"January\", \"February\", \"March\", \"April\", \"May\", \"June\", \"July\",\n\"August\", \"September\", \"October\", \"November\", \"December\"}\nlocal _wn = {\"Sunday\", \"Monday\", \"Tuesday\", \"Wednesday\", \"Thursday\", \"Friday\",\n\"Saturday\"}\nlocal function b(p, q, r)\nif q <= 2 then p, q = p - 1, q + 12 end\nlocal e = (p >= 0 and p or p - 399) // 400\nlocal g = p - e * 400\nlocal j = (153 * (q - 3) + 2) // 5 + r - 1\nlocal l = g * 365 + g // 4 - g // 100 + j\nreturn e * 146097 + l - 719468\nend\nos.time = function(o)\nif o == nil then\nerror(\"bad argument #1 to 'os.time' (no clock)\", 2)\nend\nlocal p, q, r = o.year, o.month, o.day\nif p == nil then\nerror(\"field 'year' missing in date table\", 2)\nend\nlocal u = _m(13, p, 0)\nif u == nil then\nerror(\"field 'year' is not an integer\", 2)\nend\nif u < -2147483648 or u > 2147483647 then\nerror(\"field 'year' is out-of-bound\", 2)\nend\nif q == nil then\nerror(\"field 'month' missing in date table\", 2)\nend\nif _m(13, q, 0) == nil then\nerror(\"field 'month' is not an integer\", 2)\nend\nif r == nil then\nerror(\"field 'day' missing in date table\", 2)\nend\nif _m(13, r, 0) == nil then\nerror(\"field 'day' is not an integer\", 2)\nend\nlocal v, x, aa = o.hour or 12, o.min or 0, o.sec or 0\nif _m(13, v, 0) == nil then\nerror(\"field 'hour' is not an integer\", 2)\nend\nif _m(13, x, 0) == nil then\nerror(\"field 'min' is not an integer\", 2)\nend\nif _m(13, aa, 0) == nil then\nerror(\"field 'sec' is not an integer\", 2)\nend\nlocal ab = b(p, q, r) * 86400 + v * 3600 + x * 60 + aa\nreturn _m(13, ab, 0) or ab\nend\nlocal function ac(z)\nz = z + 719468\nlocal e = (z >= 0 and z or z - 146096) // 146097\nlocal l = z - e * 146097\nlocal g = (l - l // 1460 + l // 36524 - l // 146096) // 365\nlocal p = g + e * 400\nlocal j = l - (365 * g + g // 4 - g // 100)\nlocal ad = (5 * j + 2) // 153\nlocal r = j - (153 * ad + 2) // 5 + 1\nlocal q = ad + 3\nif q > 12 then p, q = p + 1, q - 12 end\nreturn p, q, r\nend\nlocal function ae(o)\no = _m(13, o, 0) or o\nlocal af = o // 86400\nlocal ag = o - af * 86400\nlocal v = ag // 3600\nlocal x = (ag - v * 3600) // 60\nlocal aa = ag - v * 3600 - x * 60\nlocal p, q, r = ac(af)\nif p < -2147483648 or p > 2147483647 then\nerror(\"date result cannot be represented in this installation\", 3)\nend\nlocal ah = (af + 4) % 7 + 1\nif ah < 1 then ah = ah + 7 end\nlocal ai = b(p, q, r) - b(p, 1, 1) + 1\nreturn p, q, r, v, x, aa, ah, ai\nend\nlocal function aj(n)\nn = n - n % 1\nif n < 10 then return \"0\" .. n end\nreturn \"\" .. n\nend\nlocal function ak(ai, ar)\nlocal al = (7 - ar) % 7\nif ai - 1 < al then return \"00\" end\nreturn aj(1 + (ai - 1 - al) // 7)\nend\nos.date = function(am, o)\nif am == nil then\nerror(\"bad argument #1 to 'os.date' (no clock)\", 2)\nend\nif am == \"\" or am == \"!\" then return \"\" end\nlocal an = 1\nif _s(1, am, 0, 1) == \"!\" then an = 2 end\nif _s(1, am, an - 1, 2) == \"*t\" and an + 2 > #am then\nif o == nil then\nerror(\"bad argument #1 to 'os.date' (no clock)\", 2)\nend\nlocal p, q, r, v, x, aa, ah, ai = ae(o)\nreturn {year = p, month = q, day = r, hour = v, min = x, sec = aa,\nwday = ah, yday = ai, isdst = false}\nend\nlocal ao = false\nlocal ap = an\nwhile ap <= #am do\nif _s(1, am, ap - 1, 1) == \"%\" then ao = true break end\nap = ap + 1\nend\nif not ao then\nif an == 1 then return am end\nreturn _s(1, am, an - 1, #am - an + 1)\nend\nif o == nil then\nerror(\"bad argument #1 to 'os.date' (no clock)\", 2)\nend\nlocal p, q, r, v, x, aa, ah, ai = ae(o)\nlocal aq = ah - 1\nlocal ar = (aq - (ai - 1)) % 7\nlocal as = \"\"\nlocal at = an\nwhile at <= #am do\nlocal au = _s(1, am, at - 1, 1)\nif au ~= \"%\" then\nas = as .. au\nat = at + 1\nelse\nlocal av = _s(1, am, at, 1)\nif (av == \"E\" or av == \"O\") and at + 1 <= #am then\nav = av .. _s(1, am, at + 1, 1)\nat = at + 1\nend\nif av == \"Y\" then as = as .. p\nelseif av == \"m\" then as = as .. aj(q)\nelseif av == \"d\" then as = as .. aj(r)\nelseif av == \"H\" then as = as .. aj(v)\nelseif av == \"M\" then as = as .. aj(x)\nelseif av == \"S\" then as = as .. aj(aa)\nelseif av == \"w\" then as = as .. aq\nelseif av == \"y\" or av == \"Oy\" then as = as .. aj(p % 100)\nelseif av == \"j\" then\nlocal aw = \"\" .. ai\nwhile #aw < 3 do aw = \"0\" .. aw end\nas = as .. aw\nelseif av == \"U\" then as = as .. ak(ai, ar)\nelseif av == \"W\" then as = as .. ak(ai, (ar + 6) % 7)\nelseif av == \"a\" then as = as .. _s(1, _wn[aq + 1], 0, 3)\nelseif av == \"A\" then as = as .. _wn[aq + 1]\nelseif av == \"b\" or av == \"h\" then as = as .. _s(1, _mn[q], 0, 3)\nelseif av == \"B\" then as = as .. _mn[q]\nelseif av == \"p\" then as = as .. (v < 12 and \"AM\" or \"PM\")\nelseif av == \"c\" then\nas = as .. aj(q) .. \"/\" .. aj(r) .. \"/\" .. aj(p % 100) .. \" \"\n.. aj(v) .. \":\" .. aj(x) .. \":\" .. aj(aa)\nelseif av == \"x\" or av == \"Ex\" then\nas = as .. aj(q) .. \"/\" .. aj(r) .. \"/\" .. aj(p % 100)\nelseif av == \"X\" then\nas = as .. aj(v) .. \":\" .. aj(x) .. \":\" .. aj(aa)\nelseif av == \"e\" then\nas = as .. (r < 10 and \" \" .. r or \"\" .. r)\nelseif av == \"s\" then as = as .. (o - o % 1)\nelseif av == \"%\" then as = as .. \"%\"\nelse as = as .. \"%\" .. av\nend\nat = at + 2\nend\nend\nreturn as\nend\n"
const LIB_raw = "rawequal = function(c, d) return c == d end\nrawget = function(e, f) return e[f] end\nrawset = function(e, f, g) e[f] = g return e end\nrawlen = function(e) return #e end\n"
const LIB_os_env = "os = os or {}\nos.getenv = function(...)\nif select('#', ...) == 0 then\nerror(\"bad argument #1 to 'os.getenv' (string expected, \"\n.. \"got no value)\", 2)\nend\nlocal a = ...\nif a == nil then\nerror(\"bad argument #1 to 'os.getenv' (string expected, \"\n.. \"got nil)\", 2)\nend\nreturn nil\nend\n"
const LIB_os_clock = "os = os or {}\nos.clock = function() return clock() + 0.0 end\nos.difftime = function(c, d) return c - d + 0.0 end\nos.setlocale = function(c, d)\nif c == nil or c == \"C\" then return \"C\" end\nreturn nil\nend\n"
// The seven library-table names plus debug, as |name| entries.  A Find on
// this answers "is it a library" the way LIBMEMBERS answers "is it a
// member": one gate instead of a seven-way `==` chain (measured both here).
// debug has NO members anywhere -- the chip loads no debug library -- so
// every `debug.X` warns; test_consistency holds this list against the blob's.
const LIBNAMES = "|string|math|table|io|os|bit32|utf8|debug|"
// Every member every library table has, as |lib.member| entries.
// DERIVED, not listed: test_consistency checks this blob against the
// actual `lib.member =` assignments, so a new piece without a blob
// entry fails there instead of warning spuriously here.
const LIBMEMBERS = "|string.byte|string.char|string.find|string.format|string.gmatch|string.gsub|string.len|string.lower|string.match|string.rep|string.reverse|string.sub|string.upper|math.abs|math.acos|math.asin|math.atan|math.ceil|math.cos|math.deg|math.exp|math.floor|math.fmod|math.huge|math.ldexp|math.log|math.max|math.maxinteger|math.min|math.mininteger|math.modf|math.pi|math.rad|math.random|math.randomseed|math.sin|math.sqrt|math.tan|math.tointeger|math.type|math.ult|table.concat|table.insert|table.move|table.pack|table.remove|table.sort|table.unpack|io.lines|io.read|io.stderr|io.write|os.clock|os.date|os.difftime|os.exit|os.getenv|os.setlocale|os.time|bit32.arshift|bit32.band|bit32.bnot|bit32.bor|bit32.btest|bit32.bxor|bit32.extract|bit32.lrotate|bit32.lshift|bit32.replace|bit32.rrotate|bit32.rshift|utf8.char|utf8.codepoint|utf8.len|utf8.offset|"

// ---------------------------------------------------------------- state: outputs + status

var logV: string = ""
var logLen: int = 0
var logLines: string[]
var oF0: float = 0.0
var oF1: float = 0.0
var oF2: float = 0.0
var oF3: float = 0.0
var oS4: string = ""
var oS5: string = ""
var outNumArrV: float[]
var outStrArrV: string[]
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
// The last bare GLOBAL name pushed as a value, and the register it went into.
// A `.field` read checks the pair: the base register must still be that
// global's, so `io.time` warns but `"s".time`, `f().time` and a shadowing
// local's `.time` stay silent.  Cleared on every other name push and whenever
// the register is freed, so only the tight `libname.field` shape warns.
var lastBase: string = ""
var lastBaseReg: int = -1
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
// The loop-body depth this local was declared at, 0 for a local declared outside
// every loop.  That depth is the question a cell's lifetime turns on, because PUC
// closes a local's cell when the block that DECLARED it ends, and a loop body ends
// once per round: a local declared inside a body is fresh each round, and one
// declared outside every loop outlives them all.  It has to be the DEPTH and not a
// flag, because a body nested two loops deep must not close its parent's cells.
var locInLoop: int[]
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
// does the local behind this descriptor live in a loop body, and how deep?
// Strided with fUpSlot, and the reason cellAt's generation test is conditional and
// indexed: without it, one loop body's round-end replaced the cell of every
// captured local in the function, including the ones declared outside the loop
// and still in scope; and with one shared counter instead of one per depth, an
// inner body's exit also closed the outer body's cell.
var fUpDepth: int[]
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
// Was the block being closed a loop body?  blkLoop holds the depth as it was
// BEFORE the block, so this answers the other half: only a body closes cells, and
// only its own depth's.
var blkIsLoop: bool[]
// A cell's round stamp, one counter PER LOOP-BODY DEPTH.  It was one counter for
// the whole chip, which meant any block with a capture closed every captured
// local's cell in the function, and then one counter per slot, which fixed that
// but not a nested body closing its parent's cells.
var upGen: int[]
// A repeat's block ends *after* its until condition, so its one-per-round bump
// is emitted in front of the condition and this says so, or the block exit
// would add a second one outside the loop.
var blkGenDone: bool = false
// is the function being compiled variadic?  `...` outside one is an error, and
// the VM keeps the same flag per function id in fVar
var fnVar: bool[]
// `function M:f(...)` compiles as `M.f = function(M, ...)`: the receiver name
// is not written, so the parameter list has to be told to declare it first.
// Per depth, because a function head and its parameter list are parsed at
// different times and a global would not survive a nested head.
var fnSelfArg: bool[]
// Where a plain `function f()` stores the closure it makes: fnTgtK is locFind's
// lkKind for f, fnTgtR its lkReg and fnTgtI its lkIx, all resolved at the head.
// A STACK, per body, for the reason fnKey is one: the store happens at the end
// of the body, and a nested `function g()` in between would land on a per-depth
// slot.  Only the plain head pushes and only the plain store pops, so they stay
// balanced.  0 is "global", which is what a name in no scope is.
var fnTgtK: int[]
var fnTgtR: int[]
var fnTgtI: int[]
// The capture descriptor that belongs to a local entry: capK[ix] is what upStep
// gave the OWNING function for that entry, written beside locCap[ix].  A store
// made AFTER the capture needs it -- `local function f` stores its closure when
// the body ends, by which time every closure the body made has already seeded
// its cell from a register the store has not written -- and it cannot be asked
// for through upIdx, because upStep runs inside the locFind CHIP and a map
// written from a chip body does not come back out.
//
// Fixed size on purpose.  Growing it alongside the local entries was tried and
// the write landed past the end, which is indistinguishable from an array write
// being dropped at all -- so the size has to be there before the first capture.
var capK: int[]
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
var lkDone: bool = false
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
// Has anything written this cell since cellAt last seeded it?  The register and
// the cell are two homes for one local, and which one is current depends on WHEN
// the capture was noticed: a store compiled before it is a plain register write,
// so the register is ahead and has to be copied in; a store through SETUP, from
// either the declaring frame or a nested one, has already put the value in the
// cell, and for a nested one the register is not updated at all -- so copying the
// register in then would undo it.  The flag is what tells the two apart.
var uDirty: bool[]
var uTop: int = 1
// A frame's slot table -- three words per captured local: the cell, the frame
// that made it, the loop-body generation it was made in -- sits in the vararg
// stack just below that frame's varargs, and the word below *it* is the frame's
// own sequence number.  The stamps are what stop a new frame adopting the last
// one's cells (the table is scratch space) and what give each round of a loop its
// own, which is what PUC gets by closing the cells at the end of the block.  The
// third word is 0 for a local declared outside every loop, which is the "never
// stale" case.
var frameSeq: int = 0
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
// outnum/outstr/outnumarr and read on their own ports, so there is no slot for them
// at all.
// The two arrays below carry the seed for every slot, and that pair plus the
// gDeclare list are the authority.  This comment used to spell the whole slot map
// out in prose, and was wrong twice over: it listed outNum0..outNum3, invec and
// outvec as globals, and none of the three exists -- the outputs are calls and the
// vector ports are gone (RESERVED_FIDS keeps the ids).  That is a hand-kept mirror
// of numbers the chip computes, which is how a doc ends up confidently disagreeing
// with the build, so it now repeats only the two facts worth having.
var GTAG_INIT: int[] = [1, 1, 1, 1, 2, 2, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 5, 5, 5, 5, 4, 4]
var GNUM_INIT: float[] = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 23.0, 24.0, 0.0, 1.0, 2.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0, 16.0, 17.0, 18.0, 19.0, 20.0, 21.0, 22.0, 0.0, 1.0, 2.0, 3.0, 25.0, 26.0]

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
// Normalize integral floats to the int tag so 1 and 1.0 share one key.
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
var patNoSubj: bool = false  // the set machine has no subject character to test,
                             // so the item misses however the set comes out
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
var patWarned: bool = false   // a magic-needle warn is already in progDebug:
                              // one per program, not one per call
var patGmMagic: bool[]        // per walk: its needle has magic characters.
                              // Whether it ever matched needs no array: a
                              // non-empty literal match always moves the cursor
                              // past the walk's init, so pos != ini is "yielded"
                              // (a magic needle is never empty).
var patAfter: int = 0        // where a finished set scan goes on a match
var patFailTo: int = 0       // and on a miss
var patSt: int = 0

// The classes PUC's %a %c %d %g %l %p %s %u %w %x mean, on the codes
// themselves: the host's isalpha is not a gate, and the lexer spells digit and
// letter out the same way.  A letter that names no class is the character
// itself, which is how %. and %b and %q work, and an uppercase letter negates.
// One character-class test: c against the class code, `neg` for a negated
// set.
// %z is PUC's NUL class; without it `c == code` made %z match the letter z.
// It rides on the FALLBACK line rather than taking an arm of its own: an arm
// measured +49 nodes (this is a mod, compiled at both matchers) and the test
// only has to run where no other class claimed the code anyway.
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
  let lit = c == (if code == 122 then 0 else code)
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
// Shunting-yard:
// valStk/valCall, opKind/opPrec/opA/opB. Control stack: ctlKind/ctlA/B/C.
// Patch lists thread through plNext. Parse cursor cpos, error perr/perrMsg.

var cpos: int = 0
// Position of the CALL that produced the value currently in presReg, or -1 if
// that value is not a call.  It outlives lastCallPos (which only tracks the
// most recent emission) so the consumers of a finished value -- `return f()`,
// a target list, a constructor's last element -- can still mark the call as
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
// State: %d %i %u %s %q %x %X %o %c %% %f %e %g, every flag (- + space # 0),
// width, precision, the per-conversion flag table and the error messages all
// match lua5.5, case by case, in the fmt-* suite cases.  Not yet: %a, for
// which lib/str_format.lua has the algorithm and the notes on why the
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

// A CHIP: 22 instances, 3 grids.
// A mod, not a chip: measured cheaper here (instances cost pins -- see the
// chip screening note on cNum).
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

// NOT a chip, and that is measured: 57,865 as a mod, 57,919 as a chip, +54, for
// FOUR call sites at 56 nodes a copy.  It reads constNum (find, then length) and
// writes it (push), which is the read-then-write-the-same-array shape that emptied
// the whole parse when bumpMax was chipped, so it was never going to be free -- but
// the pin wiring beat the four duplicated bodies anyway.
//
// Four chip experiments in a row now, all losses, so this is a rule about the
// compiler and not a run of bad luck:
//
//   srcNames + srcUsesField, 44 sites   +342   (58,201 -> 58,543)
//   slotBase, ~4 sites, 3-line body     +151   (57,860 -> 58,011)
//   cNum, 4 sites, 56 nodes a copy      +54   (57,865 -> 57,919)
//   the concat line, 24 terms           +0    (and it is not a chip at all)
//
// Four more, all void mods -- no return value, so no output pins -- and all losses
// too, which kills the "void is cheap" refinement of the rule:
//
//   pushCtl, 10 sites, 7 int params     +233   (57,929 -> 58,162)
//   emitNum, 9 sites, 0 params          +422   (57,929 -> 58,351)
//   expandTailCall, 2 sites, 0 params   +36   (57,929 -> 57,965)
//   startUnit, 26 sites, 1 int param    +191   (57,929 -> 58,120)
//
// emitNum is the telling one: 0 params, 8 lines, 9 sites, and still +422.  All 9
// sites sit inside lexStep, which is itself a chip -- so a chip called from inside
// another chip's body does not share the way a runtime call does.  Void removes the
// output pins but not the input ones, and evidently not the call wiring either.
//
// The 46 earlier conversions that bought -34.1% were big bodies at many sites, and
// the pin cost does not fall with the body size: at four sites it is the dominant
// term whatever the body is.  So "make it a chip" is not a move to try on a small
// function, and the screening order should be the other way round -- look for a
// big body with many sites, and do not spend a build on anything else.
//
// bEmit sharpened the rule and is why it is not tried again: ~99 sites for a
// ~12-node body (4 int params plus a return) measured +2,096 nodes, about
// +21 a site.  Per-site pins grow with the signature, so the body has to
// exceed them several times over to win -- small bodies never qualify,
// however many sites call them.  (cNum's +54 at four sites is the same rule
// at a smaller signature.)
//
// October size work refined it to instances against grids: a chip costs its
// grids times its body plus its instances times its pins, and a mod costs
// its copies times its body.  Sharing wins only when grids stay few while
// sites are many (vmFail: 122 sites on 53 grids; tblSetKey: sixteen copies
// on one grid), and nested chips multiply through multi-instance outers
// (retCopy's 17 came through gateHigh's 15).  Flipped back to mods,
// measured: retCopy -163, blkExit -160, pushOp -139,
// blkEnter -117, a Tier-2 batch (vmReturn, vmForLoop, cloStep, nxStep,
// forDoHead, regSync, popCtl, lstAppendB, bitFail, rdTake, rdLine,
// rewindTo) -662 together, then gSet/vSetIntSat/vSetIntTag/pushVal/
// cmpFinish/logPush -687 together and retAdjust -180 and vSetN -734.
// Kept as chips: the shared-grid bodies (tblUnlink/Splice, vaSpill/vaFill,
// tblLink, tblFill), the big bodies (vmStepFast, lexStep, locFind,
// tblSetKey, vmFail), and the hot tiny ones where pins would dominate
// either way (vSet and kin, already mods since the register-write revert).
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
      nameWarn = nameWarn .. "warn: outnum() takes an index and a value, i in 1..4, and was given none\n"
    }
    if name == "outstr" {
      nameWarn = nameWarn .. "warn: outstr() takes an index and a value, i in 1..2, and was given none\n"
    }
    if name == "outnumarr" {
      nameWarn = nameWarn .. "warn: outnumarr() takes an index and at least one value, and was given none\n"
    }
    if name == "outstrarr" {
      nameWarn = nameWarn .. "warn: outstrarr() takes an index and at least one value, and was given none\n"
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
    if name == "outnum" && !(1.0 <= v && v <= 4.0) {
      nameWarn = nameWarn .. "warn: outnum index must be 1..4, and this call is out of range\n"
    }
    if name == "outstr" && !(1.0 <= v && v <= 2.0) {
      nameWarn = nameWarn .. "warn: outstr index must be 1..2, and this call is out of range\n"
    }
    // outNumArr raises on a bad index.  innumarr is bounded by the same length but
    // substitutes nil and carries on, and saying THAT is worth having - a silent
    // nil is the worse failure - but it is NOT here, and the reason is worth more
    // than the check: reading an input PORT during codegen empties every program,
    // including ones that never mention innumarr, because all of noteIndex is inlined
    // into exprPushName so the read is in the graph whether or not the branch is
    // taken.  outNumArrV.length() is safe because that is a chip-side array var.  The
    // width has to come from a constant, and no such constant exists yet.
    if name == "outnumarr" {
      if v != floor(v) || v < 1.0 || v > ARR_SLOTS {
        nameWarn = nameWarn
          .. "warn: array index out of range, and outnumarr is 1-based over the outNumArr slots\n"
      }
    }
    // outstrarr raises on a bad index, and the bound is ARR_SLOTS,
    // the const that sizes every array port.
    if name == "outstrarr" {
      if v != floor(v) || v < 1.0 || v > ARR_SLOTS {
        nameWarn = nameWarn
          .. "warn: array index out of range, and outstrarr is 1-based over the outStrArr slots\n"
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

// A library table read for a member the chip never installs: `io.time` is
// nil on PUC too, so this is advice, not a divergence -- the program runs on
// exactly as it would have.  The base is proven by REGISTER (lastBaseReg),
// not by name: only the tight `libname.field` shape warns, so a shadowing
// local, a call result, a literal or an index result on the same register
// number stays silent.  One line per member (the nameWarn check), because
// eight uses of the same missing member are one typo, not eight.
mod noteLibField(baseReg: int, field: string) {
  if baseReg != lastBaseReg {
    return
  }
  if LIBNAMES.Find("|" .. lastBase .. "|", true, 0) < 0 {
    return
  }
  let dotted = lastBase .. "." .. field
  if LIBMEMBERS.Find("|" .. dotted .. "|", true, 0) >= 0 {
    return
  }
  if srcUses(nameWarn, dotted) {
    return
  }
  nameWarn = nameWarn .. "warn: '" .. dotted .. "' is not in the " .. lastBase
    .. " library the chip loads, so it reads as nil\n"
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
  // noteLibField's provenance dies with the register: a recycled number must
  // never match a library push that no longer owns it.  Unconditional, because
  // every live use checks before its own arm frees anything.
  lastBaseReg = -1
  if r > cfMaxLoc[fnDepth] && r == cfNext[fnDepth] - 1 {
    cfNext[fnDepth] = r
  }
}

mod locBind(name: string, r: int) {
  if locLen < locName.length() {
    locName[locLen] = name
    locReg[locLen] = r
    locDepth[locLen] = fnDepth
    locCap[locLen] = false
    locInLoop[locLen] = loopNesting
  } else {
    locName.push(name)
    locReg.push(r)
    locDepth.push(fnDepth)
    locCap.push(false)
    locInLoop.push(loopNesting)
  }
  locLen = locLen + 1
  if r > cfMaxLoc[fnDepth] {
    cfMaxLoc[fnDepth] = r
  }
}

// A mod, not a chip: measured cheaper here (instances cost pins -- see the
// chip screening note on cNum).
mod blkEnter(isLoopBody: bool) {
  blkLen.push(locLen)
  blkNext.push(cfNext[fnDepth])
  blkCapGen.push(capGen)
  // the count as it was BEFORE this block, because blkExit has to put it back
  // exactly where it found it: a local declared after a loop is not in one, and
  // pushing the post-increment value left the count stuck at 1 for the rest of
  // the function
  blkLoop.push(loopNesting + (if isLoopBody then 1 else 0))
  blkIsLoop.push(isLoopBody)
  if isLoopBody {
    loopNesting = loopNesting + 1
  }
}

// A mod, not a chip: measured cheaper here (instances cost pins -- see the
// chip screening note on cNum).
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
    fUpDepth[p * MAX_UP + k] = locInLoop[ix]
    // the declaring function's own reads and writes go through this cell from
    // here on, so a write from a nested function is visible to it
    locCap[ix] = true
    // the descriptor, indexed by the local entry, so a store made after the
    // capture can find it again -- see capK's header
    capK[ix] = k
  }
  upIdx.set(key, k)
  return k
}

// A mod, not a chip: measured cheaper here (instances cost pins -- see the
// chip screening note on cNum).
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
  fnVar[fnDepth] = false
  // There is no self-recursion state here any more, and that is the point.
  //
  // `local function f` used to declare its name TWICE: once inside its own
  // frame, so f could reach itself by GETCLO rather than through a cell, and
  // once at the body's end in the enclosing scope, which is the local the rest
  // of the program sees.
  //
  // Two declarations with one name is the hole: locFind scans newest-first, so
  // the body's own declaration shadowed the enclosing one and every capture in
  // f resolved against a local in a frame that is gone by the time anything reads
  // it (type(f) answered "number"; calling it said "attempt to call").  One
  // declaration, made in the enclosing scope by the head, and self-recursion is
  // an ordinary upvalue read -- GETUP instead of GETCLO, which costs one
  // instruction at the reference and nothing at the call.
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

// A mod, not a chip: measured cheaper here (instances cost pins -- see the
// chip screening note on cNum).
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
// A mod, not a chip: measured cheaper here (instances cost pins -- see the
// chip screening note on cNum).
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
// A CHIP, not a mod: the call-result paths each carried an inlined copy
// of this 16-arm ladder. One shared body instead.
// The nil-fill writes the tag only: a tag-0 payload is never read (the
// same rule vSetNil and the call's missing-parameter arms already follow),
// so the two extra writes per arm were graph for nothing.  Elsewhere, a
// string payload is dropped the same way wherever the tag is not 2:
// vSetNum never wrote one for numbers, so those reads already tolerate
// whatever a reused register holds.
// A mod, not a chip: measured cheaper here (instances cost pins -- see the
// chip screening note on cNum).
mod retAdjust(src: int, dst: int, k: int, n: int) {
  if 1 <= k { vtag[dst] = vtag[src] vnum[dst] = vnum[src] vstr[dst] = vstr[src] } else if 1 <= n { vtag[dst] = 0 }
  if 2 <= k { vtag[dst+1] = vtag[src+1] vnum[dst+1] = vnum[src+1] vstr[dst+1] = vstr[src+1] } else if 2 <= n { vtag[dst+1] = 0 }
  if 3 <= k { vtag[dst+2] = vtag[src+2] vnum[dst+2] = vnum[src+2] vstr[dst+2] = vstr[src+2] } else if 3 <= n { vtag[dst+2] = 0 }
  if 4 <= k { vtag[dst+3] = vtag[src+3] vnum[dst+3] = vnum[src+3] vstr[dst+3] = vstr[src+3] } else if 4 <= n { vtag[dst+3] = 0 }
  if 5 <= k { vtag[dst+4] = vtag[src+4] vnum[dst+4] = vnum[src+4] vstr[dst+4] = vstr[src+4] } else if 5 <= n { vtag[dst+4] = 0 }
  if 6 <= k { vtag[dst+5] = vtag[src+5] vnum[dst+5] = vnum[src+5] vstr[dst+5] = vstr[src+5] } else if 6 <= n { vtag[dst+5] = 0 }
  if 7 <= k { vtag[dst+6] = vtag[src+6] vnum[dst+6] = vnum[src+6] vstr[dst+6] = vstr[src+6] } else if 7 <= n { vtag[dst+6] = 0 }
  if 8 <= k { vtag[dst+7] = vtag[src+7] vnum[dst+7] = vnum[src+7] vstr[dst+7] = vstr[src+7] } else if 8 <= n { vtag[dst+7] = 0 }
  if 9 <= k { vtag[dst+8] = vtag[src+8] vnum[dst+8] = vnum[src+8] vstr[dst+8] = vstr[src+8] } else if 9 <= n { vtag[dst+8] = 0 }
  if 10 <= k { vtag[dst+9] = vtag[src+9] vnum[dst+9] = vnum[src+9] vstr[dst+9] = vstr[src+9] } else if 10 <= n { vtag[dst+9] = 0 }
  if 11 <= k { vtag[dst+10] = vtag[src+10] vnum[dst+10] = vnum[src+10] vstr[dst+10] = vstr[src+10] } else if 11 <= n { vtag[dst+10] = 0 }
  if 12 <= k { vtag[dst+11] = vtag[src+11] vnum[dst+11] = vnum[src+11] vstr[dst+11] = vstr[src+11] } else if 12 <= n { vtag[dst+11] = 0 }
  if 13 <= k { vtag[dst+12] = vtag[src+12] vnum[dst+12] = vnum[src+12] vstr[dst+12] = vstr[src+12] } else if 13 <= n { vtag[dst+12] = 0 }
  if 14 <= k { vtag[dst+13] = vtag[src+13] vnum[dst+13] = vnum[src+13] vstr[dst+13] = vstr[src+13] } else if 14 <= n { vtag[dst+13] = 0 }
  if 15 <= k { vtag[dst+14] = vtag[src+14] vnum[dst+14] = vnum[src+14] vstr[dst+14] = vstr[src+14] } else if 15 <= n { vtag[dst+14] = 0 }
  if 16 <= k { vtag[dst+15] = vtag[src+15] vnum[dst+15] = vnum[src+15] vstr[dst+15] = vstr[src+15] } else if 16 <= n { vtag[dst+15] = 0 }
}

// A CHIP: inlined copies multiply through outer mods (gateHigh, vmStep).
// It stays its own chip on purpose: folding its three sites into retAdjust
// measured +1,073 nodes (58,032 -> 59,105), because those sites inline the
// bigger if/else body per site instead of sharing it.
// A mod, not a chip: measured cheaper here (instances cost pins -- see the
// chip screening note on cNum).
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

// A CHIP: 137 call sites, and a mod inlines at every one of them.  This was
// written off as "a chip call per register write would be catastrophic for
// ticks" -- on the assumption that a chip boundary costs a tick.  vmStepFast
// measured that assumption false (four call sites, ticks identical), so the
// class is worth measuring on its biggest member rather than assuming.
mod vSet(r: int, tag: int, num: float, s: string) {
  vtag[vmBase + r] = tag
  vnum[vmBase + r] = num
  vstr[vmBase + r] = s
}
// A nil store writes only the tag, and a store whose tag is not 2 writes no
// string, and a string store writes no number: docs/vm-isa says those payloads
// are ignored, and vSet is a mod, so each of those writes was a separate copy.
chip vSetNil(r: int) {
  vtag[vmBase + r] = 0
}
// A mod, not a chip: measured cheaper here (instances cost pins -- see the
// chip screening note on cNum).
mod vSetN(r: int, tag: int, num: float) {
  vtag[vmBase + r] = tag
  vnum[vmBase + r] = num
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

// A mod, not a chip: measured cheaper here (instances cost pins -- see the
// chip screening note on cNum).
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
  // The entry is the frame's slotB -- 0 for the main chunk, whose region starts
  // at 0 -- not its vararg base: every return pops to it, and a base here
  // orphaned the table below on every return to top level.
  // (slotBase and op-45 add the table back; main's cells sit at 1 + 3k and its
  // varargs at n either way.)
  fVaB[0] = 0
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
  vtag.resize(VREGS, 0)
  vnum.resize(VREGS, 0.0)
  vstr.resize(VREGS, "")
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
  uDirty.clear()
  uDirty.resize(MAX_CELL, false)
  uTop = 1
  frameSeq = 0
  upGen.clear()
  // 512 because the depth cannot reach it: every nesting level costs at least a
  // conditional jump and a back jump out of MAX_INSTR's 1024 instructions, and a
  // level that declares a local costs one of MAX_REGS' 64 registers as well.  The
  // simulator's out-of-bounds invariant is the backstop if that ever stops holding.
  upGen.resize(512, 0)
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
  // CopyFrom REPLACES the array, so it leaves gtag and gnum at GTAG_INIT's
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
  patSl.clear()
  patCapS.clear()
  patCapE.clear()
  patCapP.clear()
  patCapIx.clear()
  patGmS.clear()
  patGmP.clear()
  patGmPos.clear()
  patGmMagic.clear()
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
  oS4 = ""
  oS5 = ""
  outNumArrV.clear()
  outNumArrV.resize(ARR_SLOTS, 0.0)
  outStrArrV.clear()
  outStrArrV.resize(ARR_SLOTS, "")
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
  return if v + INT64_LIMIT < 0.0 then v + INT64_WRAP
    else if INT64_LIMIT <= v then v - INT64_WRAP
    else v
}

// A mod, not a chip: measured cheaper here (instances cost pins -- see the
// chip screening note on cNum).
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
// A mod, not a chip: measured cheaper here (instances cost pins -- see the
// chip screening note on cNum).
mod nxStep() {
  if 0 <= nxSlot && (tvTag[nxSlot] == 0 || tNext[nxSlot] == -2) {
    nxSlot = tNext[nxSlot]
  } else {
    if nxSlot < 0 {
      vtag[nxDst] = 0
      retCountV = 1
    } else {
      let kt = tKeyTag[nxSlot]
      let kn = tKeyNum[nxSlot]
      let ks = tKeyStr[nxSlot]
      if kt == 6 || kt == 1 {
        vtag[nxDst] = kt
        vnum[nxDst] = kn
      } else if kt == 2 {
        vtag[nxDst] = 2
        vnum[nxDst] = 0.0
        vstr[nxDst] = ks
      } else if kt == 3 {
        vtag[nxDst] = 3
        vnum[nxDst] = kn
      } else if kt == 5 {
        vtag[nxDst] = 5
        vnum[nxDst] = kn
        vstr[nxDst] = ks
      } else {
        vtag[nxDst] = 0
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

// The argument number for an error message.  The concat needs an INT operand:
// a bare `1 + fmtArgI` is float (numeric literals are), and printed "bad
// argument #2.0" -- `| 0` is the cast back.  Int-typed values concat cleanly
// (probed: "err: line 2", "parse start: 16 chars"); the old FromCharCode
// digit-spelling is gone anyway, and with it the two-digit ceiling.
mod fmtArgName() -> string {
  return "" .. ((1 + fmtArgI) | 0)
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
// is 1, 1 is at the precision, and %g gives 1e+01 and not 10.  Deciding before
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
  // Two digits: the walk already wrote the exponent's own digits -- three
  // for the 100..308 no double's exponent passes -- and one pad is all a
  // lone digit needs to reach the two every C library prints at least.
  if fmtExp.Length() < 2 {
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
  }
  // NOT part of the sign chain above: the sign and the # point are independent,
  // and the old else-if made them exclusive -- %+#014.0f of 100 came out
  // +0000000000100 where PUC answers +000000000100., and %#.0f of -100 lost its
  // point the same way.  %e's arm already keeps them apart.
  if fmtHash == 1 && fmtP == 0 {
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
// A CHIP: nested in tblSetKey; 34 instances, 1 grid.
chip tblUnlink(tid: int, sl: int) {
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
    // PUC checks the CLOSING delimiter first (matchbalance: `if (*s == e)` comes
    // before `else if (*s == b)`), and the order is the whole behaviour when the
    // two are the same character: %b'' on "'oi'" must close at the second quote,
    // not count it as a second opening.  With distinct delimiters a character can
    // only equal one of them, so the order changes nothing there.
    let c = patSrc.Substring(patI, 1)
    if c == patBClose {
      if patBC == 1 {
        patI = patI + 1
        patP = patQEnd
        patSt = 1
      } else {
        patBC = patBC - 1
        patI = patI + 1
        patSt = 3
      }
    } else if c == patBOpen {
      patBC = patBC + 1
      patI = patI + 1
      patSt = 3
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
// A mod, not a chip: measured cheaper here (instances cost pins -- see the
// chip screening note on cNum).
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
// A mod, not a chip: measured cheaper here (instances cost pins -- see the
// chip screening note on cNum).
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
// A CHIP: nested in tblSetKey; 34 instances, 2 grids.
chip tblSplice(tid: int, sl: int, pv: int, nx: int) {
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
// A CHIP: 17 instances, 1 grid.
chip tblLink(tid: int, sl: int) {
  tblSplice(tid, sl, tLast[tid], -1)
}

// Copy up to MAXVALS values from the register file into the vararg stack.
// A CHIP: 4 sites, 1 grid.
chip vaSpill(src: int, dst: int, n: int) {
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
// A CHIP: 3 sites, 1 grid.
chip vaFill(base: int, dst: int, n: int) {
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
  // An EXPRESSION chain, not an `if` chain: rewritten as statements the same
  // ladder measured +476 nodes, because every arm of a statement chain is a
  // branch the ones above it pay for on every call.
  return if tag == 0 then "nil"
    else if tag == 3 then if num == 0.0 then "false" else "true"
    else if tag == 2 then s
    // PUC spells both with an address, `function: %p` and `table: %p`.  The
    // address itself cannot be -- the registers are doubles and PUC's pointer
    // is 64-bit -- so this is the closure or table number, which is what the
    // old "function" and "table: 0x" spellings each half-agreed with.
    else if tag == 4 then "function: 0x" .. (num | 0)
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

// The exponent, two digits with a sign: the value's own digits, padded up
// to the two every C library prints at least.  PUC formats floats through
// the platform's printf, so the count is the library's -- the oracle's is
// two, and the chip's tostring already prints two.  (The old LuaBinaries
// oracle linked the MSVCRT printf, which pads to three; the chip matched
// it here and so disagreed with its own tostring.)  An exponent of
// 100..308 keeps its three digits, and no double's exponent passes 308.
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
        patHit = if patNoSubj then false else if patSetNeg then !patSetAny else patSetAny
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
//
// THREE spellings, and the third is the one that is easy to forget.  A program can
// reach a library function through a name it builds at RUN TIME -- `local k =
// "insert"; table[k](t, 1)` -- and no amount of reading the source finds that.  A
// run-time name has to come from somewhere, though, and in practice from a string
// literal, so the quoted form is a gate too: `t["insert"]` and `local k = "insert"`
// both contain `"insert"` with its quotes.
//
// The quotes are the point.  A bare `insert` would match the English word in a
// comment or a variable called `inserted`, and false positives cost boot ticks on
// every program; `"insert"` is nine characters a program only writes when it means
// the string.  This is a heuristic and not a proof -- a name assembled as
// `"ins" .. "ert"`, or arriving from inStr0/io.read, still cannot be seen -- but
// it is the difference between a working program and "attempt to call a nil value"
// for the shape real programs use.
//
// It also repairs a regression the SPLITS introduced.  `table.insert` and
// `table.remove` were one piece, so a program that named one in text and reached
// the other by a run-time name worked: the named one's gate installed both.  Split
// them and it raises, which is a split making a program worse rather than better.
// The rule that falls out: a piece split out of another must gate on the same
// spellings the whole did, or the split has narrowed what was reachable.
// A CHIP, and it has to be: this builds four strings and runs four searches, and as
// a mod it is inlined at every name of every piece -- 44 sites -- which measured
// srcNames is the THREE-spelling gate, and srcUsesField keeps TWO on purpose: the
// difference is not an oversight and it is measured.
//
// A program can reach a library function through a name it builds at RUN TIME --
// `local k = "insert"; table[k](t, 1)` -- and no amount of reading the source finds
// that.  So the quoted name is a gate too: `t["insert"]` and `local k = "insert"`
// both contain the literal `"insert"`.  The quotes are the point.  A bare `insert`
// would match the English word in a comment or a variable called `inserted`, and
// false positives cost boot ticks on every program -- across this name list `log`,
// `read`, `write`, `type` and `max` are all ordinary words a program writes for
// other reasons.  `"insert"` is nine characters a program only writes when it means
// the string.
//
// It is a heuristic and not a proof: a name assembled as `"ins" .. "ert"`, or
// arriving from inStr0/io.read, still cannot be seen.  It is the difference between
// a working program and "attempt to call a nil value" for the shape real programs
// use.
//
// WHAT IT COSTS, MEASURED, because the quotes are what make it affordable and
// nothing else is.  A program whose text merely CONTAINS these words pays nothing:
// print("max min pack move insert remove") boots in 15 ticks, the same as print(1),
// because Find needs the closing quote too and the words are space-separated inside
// one string.  A program that quotes one as DATA pays the piece it never calls:
// local x = "max" print(x) is 345 ticks against 28 for local x = "hello", so +317.
// That is the whole price, and it is a price worth paying for the seven shapes of
// dynamic access it repairs -- but it is a real one and it is why this spelling is
// not going on gates that cannot regress (below).
//
// It also repairs a regression the SPLITS introduced.  `table.insert` and
// `table.remove` were one piece, so a program that named one in text and reached
// the other by a run-time name worked: the named one's gate installed both.  Split
// them and it raised, which is a split making a program worse rather than better.
// The rule that falls out: a piece split out of another must reach everything the
// whole did, or the split has narrowed what a program can do.
//
// WHY srcUsesField DOES NOT HAVE THE THIRD SPELLING: adding it here measured +33
// nodes over its 14 call sites, and adding it to BOTH helpers measured +417.  The
// difference is all of the ~30 sites here, because nothing that uses this helper
// was split out of anything -- so a gate needs the run-time spelling exactly when
// its piece is one half of a split, and paying 380 nodes to add it to gates that
// cannot regress buys nothing.  The two string gates that WERE split, libStrByte
// and libStrChar, spell out all four themselves.
//
// The FOURTH spelling is the one that proves the other three were not enough.  The
// single-quoted form had been left out to save nodes, and then the tests for this
// very feature were written with single quotes -- because that is how this repo, and
// most Lua, spells a string -- and five of them failed.  So the cheap version was
// covering half the realistic shapes, and the way that showed was by writing the
// obvious test.  Cost of putting it back: +42 over this helper's 14 sites.
mod srcUsesField(p: string, name: string) -> bool {
  let dotted = "string." .. name
  let colon = ":" .. name
  return srcUses(p, dotted) || srcUses(p, colon)
}

// srcNames (dotted/colon/quoted-double/quoted-single) lived here and is gone:
// libTabDyn/libMathDyn answer the run-time case for tables and math, so every
// table/math gate uses srcNames2 (two spellings) and nothing called this.  An
// unused mod is 4 nodes; the 14 call sites it once had are the +33/+42
// measurements in the cNum note.

// A LIBRARY TABLE INDEXED BY A NAME THE PROGRAM BUILT AT RUN TIME.
//
// This is the fix for the whole family, and it is cheaper than the quoted-name gate
// it replaces, because `table[` is in the source no matter where the key came from:
//   local k = "ins" .. "ert"   table[k](t, 1)      assembled
//   local k = inStr0           table[k](t, 1)      off a port
//   local k = io.read()        table[k](t, 1)      off a stream
// A text search cannot see the NAME, but it can see the INDEX, and one bracket on a
// NAMED library table is a complete answer: that table's every piece is reachable.
//
// It also SUBSUMES the quoted-name gate for tables and math, which is why this is
// cheaper than what it replaces: `local k = "insert"; table[k](t, 7)` contains
// `table[`, so it no longer needs a spelling of the name at all.  Those two spellings
// were +33 and +42 nodes to add and they were still incomplete -- they covered a
// name written as a literal and nothing else.
//
// NOT applied to strings, and the reason is a hard limit rather than a preference --
// see the note on srcNames below, which is where the string pieces' own gate lives.
// The whole string library compiles to 1,025 instructions against a 1,024 cap, so a
// whole-table answer for strings does not fit and the per-name gate is the best
// available one rather than a choice between good and better.
//
// The over-trigger is deliberate and cheap: `mytable[k]` contains `table[`, so a
// program with a local of that name installs the table pieces.  It costs boot ticks
// on that program and nothing else, and the alternative -- missing a call -- is worse.
//
// The flag crosses as a PARAMETER, not a global, and that is measured: 9 string
// gates taking a global dynStr instead were +11 nodes (57,923 -> 57,934), because a
// persistent var plus 9 reads costs more than 9 bool pins.  Reverted.
mod libTabDyn(p: string) -> bool {
  return srcUses(p, "table[")
}

mod libMathDyn(p: string) -> bool {
  return srcUses(p, "math[")
}

// A string value indexed with a bracket, by a key the program built at run time.
// `string[` is in the source whatever became of the key, so this is the same complete
// answer libTabDyn gives for tables -- and it is now usable because MAX_INSTR is
// 1,536 rather than 1,024.  At 1,024 every string piece together was 1,025
// instructions and the whole-table install overflowed the cap before the program
// added one of its own; raising the cap costs NO NODES (the bytecode arrays are sized
// from the constant at reset, so it is memory and not graph), which is what makes
// this fix possible at all.
//
// THE STRING VARIABLE IS NOT COVERED, and the price of covering it was measured
// rather than guessed.  `local s = "abc"  local m = "up" .. "per"  s[m]()` says
// neither `string[` nor `"[` nor `)[`: the receiver is a local, so its name never
// appears.  The only textual signal that catches it is `](`, and `](` is also what
// ORDINARY table dispatch spells -- t[k](v) -- so every program containing it would
// install the whole string library, which is 9,000 ticks of parse for a function it
// probably never calls.
//
// tools/chip/dynblast.py counts it: 25 of the suite's 863 cases contain `](`, and
// the cost lands on all of them.  So this trigger is deliberately NOT `](`, and the
// remaining hole is a name ASSEMBLED from pieces used to index a string VARIABLE --
// which needs two unusual things at once, and which no static gate can see without
// charging every table-dispatch program for the whole string library.
//
// The bias throughout is deliberate: over-triggering costs boot ticks on one
// program, missing it costs that program its answer.
mod libStrDyn(p: string) -> bool {
  return srcUses(p, "string[") || srcUses(p, "\"[") || srcUses(p, ")[")
}
// WHY THE STRING PIECES ALSO KEEP A PER-NAME GATE
// ---------------------------------------------------------------------
// The obvious fix is the libTabDyn/libMathDyn one applied to strings: `string[` is in
// the source whatever became of the key, so install every string piece.  It does not
// work, and the reason is a hard limit rather than a preference.  Every string piece
// together compiles to 1,025 bytecode instructions and MAX_INSTR is 1,024 -- so the
// pieces ALONE overflow the cap before the program adds one instruction of its own:
//
//   table[  -> 279 instructions     fits
//   math[   -> 606 instructions     fits
//   string[ -> 1,025 instructions    OVER by one, before the program starts
//
// Measured with tools/chip/dump_vm.py.  The failure it produces is the worst shape
// there is: `local k = "by" .. "te" print(string[k]("A", 1))` printed NOTHING and
// reported no error, because bEmit's overflow sets perr with the message "program
// too long" and the parse then stops with an empty log.  One instruction fewer and
// the same program works, which is how it survived a first attempt at this fix.
//
// So the quoted spelling below is the best available answer for strings rather than
// a choice between good and better.  What it cannot see is a name ASSEMBLED from
// pieces -- local k = "up" .. "per" -- used to index a string value.  Same wall that
// keeps string.format a gate: 11,468 characters does not fit the source buffer.

// Purely dynamic signals: a bracket on the table name, whatever the key became.
// The DOTTED form ("io.", "os.") lived here and is gone, and it was load-bearing
// in the wrong direction: every "io.write" contains "io.", so d was true for every
// static user too -- including an io.stderr-only program, which then installed all
// of LIB_io and defeated the split the libIo comment below exists to keep ("stderr
// users must not pay for read/write/lines").  Static names are the name checks'
// job; this answers only what they cannot see.
mod libIoDyn(p: string) -> bool {
  return srcUses(p, "io[")
}

mod libOsDyn(p: string) -> bool {
  return srcUses(p, "os[")
}

mod libBit32Dyn(p: string) -> bool {
  return srcUses(p, "bit32[")
}

mod libUtf8Dyn(p: string) -> bool {
  return srcUses(p, "utf8[")
}

// TWO spellings, for the tables whose gate is now complete on its own because
// libTabDyn and libMathDyn answer the run-time case.  srcNames keeps the four, for
// the string pieces, which is the only place they are still load-bearing.
mod srcNames2(p: string, tbl: string, name: string) -> bool {
  return srcUses(p, tbl .. "." .. name) || srcUses(p, ":" .. name)
}

mod libIter(p: string) -> string {
  return if srcUses(p, "ipairs") || srcUses(p, "pairs") then LIB_iter else ""
}

mod libMathConst(p: string, d: bool) -> string {
  return if d || srcUses(p, "math.pi") || srcUses(p, "math.huge")
      || srcUses(p, "math.maxinteger") || srcUses(p, "math.mininteger")
      then LIB_math_const else ""
}

// Two pieces where there was one, and the measurement is the same shape as the
// table.unpack and math.misc splits: naming table.insert or table.remove cost
// ~640 ticks of boot each (tools/chip/libcost.py) because each carried the other.
// A program that appends in a loop should not parse the gap-closing loop.
mod libTabInsert(p: string, d: bool) -> string {
  return if d || srcNames2(p, "table", "insert") then LIB_tab_insert else ""
}

mod libTabRemove(p: string, d: bool) -> string {
  return if d || srcNames2(p, "table", "remove") then LIB_tab_remove else ""
}

// Three pieces where there was one, and the reason is measured rather than
// guessed: naming table.unpack used to cost 460 ticks of boot (tools/chip/libcost.py)
// to parse table.pack and table.move, which a program calling unpack never
// touches.  unpack is a gate, so the alias needs nothing and can stand alone.
mod libTabUnpack(p: string, d: bool) -> string {
  return if d || srcNames2(p, "table", "unpack") then LIB_tab_unpack else ""
}

mod libTabPack(p: string, d: bool) -> string {
  return if d || srcNames2(p, "table", "pack") || srcNames2(p, "table", "move")
      then LIB_tab_pack else ""
}

mod libTabConcat(p: string, d: bool) -> string {
  return if d || srcUses(p, "table.concat") then LIB_tab_concat else ""
}

mod libTabSort(p: string, d: bool) -> string {
  return if d || srcUses(p, "table.sort") then LIB_tab_sort else ""
}

mod libIo(p: string, d: bool) -> string {
  // stderr is its own piece, not part of LIB_io: io.write users must not pay
  // its parse, and stderr users must not pay for read/write/lines.
  let r = if d || srcUses(p, "io.read") || srcUses(p, "io.write")
      || srcUses(p, "io.lines") then LIB_io else ""
  return r .. (if srcUses(p, "io.stderr") then LIB_io_stderr else "")
}

mod libOs(p: string, d: bool) -> string {
  // exit stays its own piece: os.exit users must not parse date, and date
  // users must not parse exit.  clock/difftime/setlocale are their own tiny
  // piece for the same reason: naming os.clock loaded the whole 5,000-char
  // calendar at boot before the split.  "os.date" and "os.time" are spelled
  // out -- the old "os.d" fold covered difftime too, which loads elsewhere
  // now (the fold list in docs/lessons.md loses os.d to this split).
  let r = if d || srcUses(p, "os.exit") then LIB_os_exit else ""
  let r2 = r .. (if d || srcUses(p, "os.clock") || srcUses(p, "os.difftime")
      || srcUses(p, "os.setlocale") then LIB_os_clock else "")
  let r3 = r2 .. (if d || srcUses(p, "os.time") || srcUses(p, "os.date")
      then LIB_os_date else "")
  // getenv is its own piece too: a program that reads one
  // environment variable must not parse the whole calendar.
  // The chip's environment is empty (the host exposes none),
  // so getenv answers nil for everything -- see lib/os_env.lua.
  return r3 .. (if d || srcUses(p, "os.getenv") then LIB_os_env else "")
}

// One piece for the whole table, because a program that uses bit32 uses
// several of its functions together -- bitwise.lua's own tests call band, bor,
// bxor, btest, both shifts, both rotates, extract and replace in one file.
// Splitting it per function would be twelve parses of the same shared helpers
// (checkfield alone is in two of them).  The static check names the table;
// the dyn flag answers `bit32[k](v)`, which the static text cannot see.
// One piece for all four raw functions, because the chip has no
// metatables and each is a thin wrapper over an op it already has
// (==, index, assign, length) -- see lib/raw.lua.  One "raw"
// prefix covers all four (no other raw* global exists), the same
// fold rule as math.l and os.d.  No dyn flag: these are globals,
// and a dynamic global read needs _G, which the chip does not have.
mod libRaw(p: string) -> string {
  return if srcUses(p, "raw") then LIB_raw else ""
}

mod libBit32(p: string, d: bool) -> string {
  return if d || srcUses(p, "bit32.") then LIB_bit32 else ""
}

// One piece for all four functions, because they share the codec and the
// codec IS the piece: dec is half the characters, and splitting would either
// duplicate it in every piece or reach across pieces for it.  At 4,043 escaped
// characters this is the largest piece by 1.3KB -- and naming utf8 costs that
// in boot -- so if a split ever pays, it is char (enc only, ~700) standing
// alone while len/offset/codepoint keep dec.  Not split now: measure first.
mod libUtf8(p: string, d: bool) -> string {
  // NOT `utf8.`: that prefix matches `utf8.char` too, and then a char-only
  // program would pay for both pieces -- which is the split defeated.  The
  // three decoder names are the trigger; char has its own below.
  return if d || srcUses(p, "utf8.len") || srcUses(p, "utf8.offset")
      || srcUses(p, "utf8.codepoint") then LIB_utf8 else ""
}

// utf8.char stands alone: it needs only the encoder, while the rest shares
// the decoder, so a program that emits UTF-8 pays 615 characters and not
// 2,918.  The split is measured the way every split here is -- by the escaped
// count, which is the boot -- and char is the half that is used alone.
mod libUtf8Char(p: string, d: bool) -> string {
  return if d || srcUses(p, "utf8.char") then LIB_utf8_char else ""
}

// The explicit-base walk, and the gate is the only question that separates the two
// shapes: does any `tonumber(` call carry a comma?  `tonumber("42")` cannot reach
// _tonum_int, and it was paying 1,195 characters of parse to prove it.
//
// A WINDOW per call, unrolled three times -- not a parse, and not a loop, because
// WireScript has neither here: one Find over Substring(i, 64) answers whether THAT
// call carries a comma, and three answers cover a program that mixes
// `tonumber("42")` with `tonumber("ff", 16)`.  Checking only the first occurrence
// missed exactly that mix (found by probing, added as tonum-mixed-base below).
// A fourth call with a base and three without is still missed -- over-triggering
// costs boot ticks, under-triggering costs "attempt to call", so three is the
// measured compromise, not a proof.  64 is free where 48 was: the length is a
// constant either way.
mod libTonumberBase(p: string) -> string {
  if !srcUses(p, "tonumber") {
    return ""
  }
  let i0 = p.Find("tonumber(", true, 0)
  if i0 < 0 {
    return ""
  }
  if p.Substring(i0, 64).Find(",", true, 0) >= 0 {
    return LIB_tonumber_base
  }
  let i1 = p.Find("tonumber(", true, i0 + 9)
  if i1 < 0 {
    return ""
  }
  if p.Substring(i1, 64).Find(",", true, 0) >= 0 {
    return LIB_tonumber_base
  }
  let i2 = p.Find("tonumber(", true, i1 + 9)
  if i2 < 0 {
    return ""
  }
  return if p.Substring(i2, 64).Find(",", true, 0) >= 0 then LIB_tonumber_base else ""
}

mod libTonumber(p: string) -> string {
  return if srcUses(p, "tonumber") then LIB_tonumber else ""
}

// The hex fallback is its own piece, gated on the program TEXT.  Three ways to
// reach it, and all three are needed: a hex numeral the lexer takes (0xff in the
// source), a hex string the program hands to tonumber ("0xff"), and a hex
// numeral that ARRIVES at run time -- inStr0/inStr1/inStrArr/io.read carry
// strings the program never wrote, so a program that reads one and parses it
// needs the walk whatever its source says.  Missing the third is the shape this
// comment exists for: the gate is static and the string is not, so without
// inStr/io.read here a program doing exactly the right thing (read a number from
// the input port, allow hex) got "attempt to call a nil value" on a value PUC
// converts.
//
// Measured: a program that only ever calls tonumber("42") does not pay to parse
// 2,654 characters of walk it cannot call -- 2,900 ticks, and the piece used to
// be 72% of everything naming tonumber paid at boot.  That program is 1,923
// ticks now, against 3,712 before explicit bases existed at all.
//
// The shape that still differs: a program that ASSEMBLES the "0x" at run time
// out of pieces (tonumber("0" .. "xff")) gets "attempt to call a nil value"
// where PUC answers a number.  Loud rather than wrong, and no static gate can
// see it -- which is the whole trade this split makes.
mod libTonumberHex(p: string) -> string {
  if !srcUses(p, "tonumber") {
    return ""
  }
  // A COMPUTED argument is the case the name test cannot see, and the character
  // after `tonumber(` says which it is: a quote is a literal, and anything else --
  // a variable, a concat, a port read -- could be a hex string the program never
  // wrote down.  `local h = "0" .. "x1f"  tonumber(h)` raised "attempt to call"
  // here, and PUC answers 31.
  //
  // This is the precise form of the hole the inStr/io.read terms below were
  // patching one source at a time, and it costs nothing on a program that passes a
  // literal -- which is the only kind the name test was getting right before.
  let i = p.Find("tonumber(", true, 0)
  if i >= 0 {
    let c = p.Substring(i + 9, 1)
    if !(c == "\"" || c == "'") {
      return LIB_tonumber_hex
    }
  }
  return if srcUses(p, "0x") || srcUses(p, "0X")
      || srcUses(p, "inStr") || srcUses(p, "io.read")
      then LIB_tonumber_hex else ""
}

mod libMathRandom(p: string, d: bool) -> string {
  return if d || srcUses(p, "math.random") then LIB_math_random else ""
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
  // Cleared here, not where it is set: patTestItem's `[` arm sets it, but this
  // machine is also driven by %f, which never goes through that arm and DOES read
  // patHit.  A flag cleared by its only writer would still be live when %f
  // started, and %f on an exhausted subject would then be forced to a miss.
  patNoSubj = false
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
  // Full 0-255, not just printable ASCII: PUC's \ddd and \xXX spell any byte,
  // and utf8 (or any binary string) needs high bytes in literals.  This used
  // to allow only 32-126 via the PRINTABLES table, so "\195" was a compile
  // error -- and a SILENT one from the program's side, because the piece or
  // program carrying it simply never parsed.  \ddd above 255 is still an error
  // ("decimal escape too large" in PUC); \xXX cannot exceed 255 by construction.
  // digits only ever add, so v is never negative and only the top needs
  // checking.  \xXX cannot exceed 255 by construction (two hex digits).
  if v > 255 {
    lexFail("bad escape")
  } else {
    lidBuf = lidBuf .. FromCharCode(v).Character
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
  capK.clear()
  capK.resize(1024, -1)
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
  blkIsLoop.clear()
  loopNesting = 0
  upIdx.clear()
  fUpSrc.clear()
  fUpSrc.resize(MAX_FUNCS * MAX_UP, -1)
  fUpSlot.clear()
  fUpSlot.resize(MAX_FUNCS * MAX_UP, 0)
  fUpDepth.clear()
  fUpDepth.resize(MAX_FUNCS * MAX_UP, 0)
  fidAt.clear()
  fidAt.resize(FRAMES, -1)
  cfNext.clear()
  cfMax.clear()
  cfBase.clear()
  cfMaxLoc.clear()
  funcEntryLoc.clear()
  opBase.clear()
  cfNext.resize(FRAMES, 0)
  cfMax.resize(FRAMES, 0)
  cfBase.resize(FRAMES, 0)
  cfMaxLoc.resize(FRAMES, -1)
  fnVar.clear()
  fnVar.resize(FRAMES, false)
  fnSelfArg.clear()
  fnSelfArg.resize(FRAMES, false)
  fnTgtK.clear()
  fnTgtR.clear()
  fnTgtI.clear()
  funcEntryLoc.resize(FRAMES, 0)
  opBase.resize(FRAMES, 0)
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
  gDeclare("outnumarr")
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
  gDeclare("outstrarr")
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
// A mod, not a chip: measured cheaper here (instances cost pins -- see the
// chip screening note on cNum).
mod blkExit() {
  locLen = blkLen.pop().Value
  cfNext[fnDepth] = blkNext.pop().Value
  // The depth THIS block sits at, which is what its cells' stamp counts -- a `do`
  // or `if` block inside a body shares the body's depth, so only the body itself
  // may bump it.  Read off blkLoop rather than from loopNesting, which is the
  // block's own depth only while the block is open: reading the global here
  // emitted depth 0 for every loop body, and with the stamp pinned to depth 1 the
  // cells of a body-declared local were never replaced and `for k = 1, 3 do local
  // j = k t[k] = function() return j end end` answered the same value three times
  // where PUC answers k.  blkLoop holds the depth AFTER this block's own
  // increment, so the restore is one less exactly when the block was a body.
  let blkDepth = blkLoop[blkLoop.length() - 1]
  let blkWasBody = blkIsLoop.pop().Value
  blkLoop.pop()
  loopNesting = blkDepth - (if blkWasBody then 1 else 0)
  let had = blkCapGen.pop().Value != capGen
  if blkGenDone {
    blkGenDone = false
  } else if blkWasBody && had {
    bEmit(49, 0, blkDepth, 0)
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
// NOT a chip: 57,860 as a mod, 58,011 as a chip, +151 for about four call sites.
// Three source lines is three source lines; the pin wiring is not smaller.  See the
// four measurements on cNum and srcNames for why this is now a rule and not a
// result about this one function.
// The frame's slotB: its own fVaB entry IS the caller's top at the call, so
// the table starts one word above it.  (Entries used to hold the vararg base;
// every return then restored to it and orphaned the table below -- one word a
// non-tail call.  Readers below speak base; the entry speaks top.)
mod slotBase() -> int {
  return fVaB[fVaB.length() - 1] + 1
}

// outnumarr's value test, in one place because eight call sites have to
// agree: a number (1), a float (6), nil (0) and a boolean (3) may be
// stored, and nil stores 0.0.  Anything else is a table, a string or a
// function.
mod arrNumOk(tag: int) -> bool {
  return tag == 1 || tag == 6 || tag == 0 || tag == 3
}

// outstrarr's value test, in one place because eight call sites
// have to agree: a string (2) or nil (0) may be stored, and nil
// stores "".  Anything else is a number, a boolean, a table or a
// function.
mod arrStrOk(tag: int) -> bool {
  return tag == 2 || tag == 0
}

// An integer-tagged slot carries no sign, because integer zero does not have
// one.  The arithmetic is done in f64, where -7.0 * 0.0 IS -0.0, and storing
// that under the integer tag leaked the sign into every later float coercion:
// `local z = (3-10)*(10%2) print(z, math.type(z), z*(-5.0))` printed
// `0  integer  0.0` where PUC prints `0  integer  -0.0`, because the runtime MUL
// left -0.0 in the slot and `-5.0 * -0.0` is `+0.0`.  Neither print(z) nor
// math.type(z) could see it -- the tag and the printed integer were both right,
// which is why this survived until a fuzzer multiplied the value by a float.
//
// `w + 0.0` is the normalising step and it is the whole fix: IEEE says (-0.0) +
// (+0.0) is +0.0, and adding positive zero leaves every other value alone,
// infinities and NaN included.  A FLOAT zero is untouched by this and keeps its
// sign, which is a different rule and a correct one: `local z = -5.0 * 0.0
// print(z)` is -0.0 in PUC and here.
//
// One function owns it because there are two places that write the integer tag
// with a computed value (#t and #s add 0.0 themselves before they get here) and
// they have to agree about this exactly as they agree about the tag.
// A mod, not a chip: measured cheaper here (instances cost pins -- see the
// chip screening note on cNum).
mod vSetIntTag(a: int, w: float) {
  vSetN(a, 6, w + 0.0)
}

mod vSetInt(a: int, v: float) {
  let w = intWrap(v)
  if w == floor(w) && 0.0 <= w + INT64_LIMIT && w < INT64_LIMIT {
    vSetIntTag(a, w)
  } else {
    vSetNum(a, w)
  }
}

// A mod, not a chip: measured cheaper here (instances cost pins -- see the
// chip screening note on cNum).
mod vSetIntSat(a: int, v: float) {
  var w = v
  if w + INT64_LIMIT < 0.0 {
    w = 0.0 - INT64_LIMIT
  } else if INT64_LIMIT <= w {
    w = INT64_LIMIT
  }
  vSetIntTag(a, w)
}

// x ** y, with the sign of a negative zero base put back.
//
// The exponentiation gate answers the right MAGNITUDE and the wrong SIGN when
// the base is a negative zero and the exponent is an integer: PUC alternates on
// the parity of the exponent (-0.0/+0.0 for positive exponents, -inf/+inf for
// negative) and the gate answers +0.0 for every positive exponent and -inf for
// every negative one.  Other negative bases are fine (-2.0^3 is -8.0) and a
// non-integer exponent agrees, so this is the sign of a zero or infinite RESULT,
// not of a negative base.
//
// The guard is a STATEMENT if on purpose.  An if-expression compiles to a Select
// fed by BOTH arms -- the language reference is explicit that "both arms
// evaluate... an arm cannot be used to guard another" -- while a statement in exec
// context skips its body.  So the divide and the modulo below are paid only when
// the base is a zero, and a pow of anything else costs one comparison.
//
// It is a mod rather than a second expression because the arithmetic dispatch is
// written twice, in vmStepFast and in vmStep, and a mod is inlined at both call
// sites from one body -- two copies of this rule is two rules to keep in step.
mod powSignedZero(x: float, y: float) -> float {
  var p = x ** y
  if x == 0.0 {
    let iy = y | 0
    // `y == iy + 0.0` keeps an exponent too large to truncate out, and 1/x is the
    // only sign oracle this language has for a zero: -0.0 is not < 0.0, and
    // sign() is modelled as `0.0 if x == 0` so it cannot tell them apart either.
    // The divide gate answers inf rather than faulting, so it is safe here.
    if y == iy + 0.0 && 1/x < 0.0 {
      // floored modulo, so an odd exponent is 1 on either side of zero
      if (p < 0.0) != (iy % 2 != 0) {
        // -p and NOT `0.0 - p`: IEEE says (-0.0) - (+0.0) is -0.0 but
        // (+0.0) - (+0.0) is +0.0, so subtracting zero flips an infinity and
        // leaves a zero exactly where it was.  Unary minus is the operation
        // that changes a zero's sign, which is why the chip's UNM arm negates
        // rather than subtracting.
        p = -p
      }
    }
  }
  return p
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

// A CHIP: 16 ladder sites share one small body.
chip tblFill(dst: int, tid: int, idx: int) {
  let r = tmap.get(tkey(tid, 1, idx, ""))
  if r.Found {
    vSet(dst, tvTag[r.Value], tvNum[r.Value], tvStr[r.Value])
  } else {
    vSetNil(dst)
  }
}

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
chip fmtSign() {
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
    } else {
      // `+` may not give back past its FIRST repetition, and the check above is
      // not enough: it only sees `+` matching nothing AT ALL.  Once a repetition
      // has happened the give-back lives in patBack, which had no lower bound
      // to consult, so it rewound to zero of them.  That is why
      // ("b"):match("b.+b") matched -- and returned a two-character match on a
      // one-character subject.  pm.lua:47 is the assert that found it, once the
      // harvest stopped mis-reading `not` as a captured variable.
      //
      // The floor is WHERE THE REPEAT BEGAN, and for a `+` it rides in the
      // entry's item slot rather than a new one, because patBack's greedy arm
      // never needs patItemP back: patNextItem sets it fresh for every item it
      // tests, which is what the `?` arm's comment already says.  So kind 9 is
      // kind 1 with a floor -- one new KIND, no new stack slot, no new arm in
      // patBack and no extra nesting, which is what makes it affordable at all.
      let kind = if patQ == 2 then 9 else 1
      let item = if patQ == 2 then patI else patItemP
      if !patPush(kind, item, patI, patQEnd) {
        patErr = "pattern too complex"
        patSt = 8
      } else {
        patSt = 11
      }
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
      // k2 carries the subject position BEFORE the item, so the backtrack can
      // give the character back: `?` tries with-item first and without on
      // failure, and ("b"):match(".?b") missed until this rewound patI, because
      // the tail retried at the consumed position.  patI (not patI - 1) because
      // the width is the item's, not one -- a backref can take more.
      if patPush(2, patQEnd, patI, 0) {
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
  let u = if libLines < l then l - libLines else 1
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

// len and sub are one-liners over #s and the substring gate; byte and char each
// build a table in a loop, and byte needs `unpack` besides.  A piece is charged
// for its characters at boot, so a program that only ever takes a substring was
// measured paying 1,094 ticks for a group where 404 of the 838 characters were
// unreachable for it.  The two halves are separate pieces now.
mod libStrIndex(p: string, d: bool) -> string {
  return if d || srcUses(p, "string.len") || srcUses(p, "string.sub")
      || srcUsesField(p, "len") || srcUsesField(p, "sub")
      then LIB_str_index else ""
}

// string.byte and string.char were one piece, and each cost the other: 630 ticks
// of boot to name either (tools/chip/libcost.py).  One reads a byte out of a
// string, the other builds a string out of bytes, and neither calls the other.
// Three spellings spelled out rather than through srcUsesField, because these two
// ARE halves of a split and that is what earns the third one -- see srcNames for
// the measurement and for why the other ~30 gates do not carry it.
mod libStrByte(p: string, d: bool) -> string {
  return if d || srcUses(p, "string.byte") || srcUses(p, ":byte")
      || srcUses(p, "\"byte\"") || srcUses(p, "'byte'")
      then LIB_str_byte else ""
}

mod libStrChar(p: string, d: bool) -> string {
  return if d || srcUses(p, "string.char") || srcUses(p, ":char")
      || srcUses(p, "\"char\"") || srcUses(p, "'char'")
      then LIB_str_char else ""
}

mod libStrCase(p: string, d: bool) -> string {
  return if d || srcUses(p, "string.upper") || srcUses(p, "string.lower")
      || srcUsesField(p, "upper") || srcUsesField(p, "lower")
      then LIB_str_case else ""
}

mod libStrFmt(p: string, d: bool) -> string {
  return if d || srcUses(p, "string.format") || srcUsesField(p, "format")
      then LIB_str_fmt else ""
}

mod libStrGmatch(p: string, d: bool) -> string {
  return if d || srcUses(p, "string.gmatch") || srcUsesField(p, "gmatch")
      then LIB_str_gmatch else ""
}

// gsub's replacement walk scans for '%' with string.find, so it brings the pat
// piece with it; libStrPat then stands down so the program pays for it once.
//
// IT MUST ALSO STAND DOWN WHEN `d` IS SET, and that is a bug this shape invites:
// libStrGsub returns `LIB_str_pat .. LIB_str_gsub`, so a `d ||` in front of BOTH
// gates emits the pattern piece TWICE, and the concatenated library then fails to
// parse with "unexpected token in expression" -- silently, in the sense that the
// program prints nothing and reports no error, because a parse failure leaves an
// empty log rather than a message.  Found by tools/chip/whyempty.py, which exists
// because `chip='' err=''` says nothing about which of the two limits or the parser
// is responsible.
mod libStrPat(p: string, d: bool) -> string {
  if d {
    return ""
  }
  return if (srcUses(p, "string.find") || srcUses(p, "string.match")
      || srcUsesField(p, "find") || srcUsesField(p, "match"))
      && !(srcUses(p, "string.gsub") || srcUsesField(p, "gsub"))
      then LIB_str_pat else ""
}

// No string-literal fast path, and that is measured rather than assumed.  A fast
// piece without the function/table arms is lib/str_gsub_str.lua (1,998 chars
// against 2,649) and it boots a literal-replacement gsub in 2,152 ticks against
// 2,799 -- a real -647.  But the gate costs +99 nodes (57,929 -> 58,028): finding
// the THIRD argument takes two comma Finds plus a class test per call, unrolled
// twice so a mixed program installs everything, and that machinery exists whether
// or not the program uses gsub.  6.5 ticks per node against the tonumber split's
// 31, under a rule that says nodes do not go up.  Reverted; the master and the
// numbers stay so it is not retried blind.
mod libStrGsub(p: string, d: bool) -> string {
  return if d || srcUses(p, "string.gsub") || srcUsesField(p, "gsub")
      then LIB_str_pat .. LIB_str_gsub else ""
}

mod libStrMisc(p: string, d: bool) -> string {
  return if d || srcUses(p, "string.rep") || srcUses(p, "string.reverse")
      || srcUsesField(p, "rep") || srcUsesField(p, "reverse")
      then LIB_str_misc else ""
}

mod libMathInt(p: string, d: bool) -> string {
  if d { return LIB_math_int }
  return if srcUses(p, "math.floor") || srcUses(p, "math.ceil")
      || srcUses(p, "math.tointeger") || srcUses(p, "math.type")
      || srcUses(p, "math.abs") || srcUses(p, "math.sqrt")
      || srcUses(p, "math.ult")
      || srcUsesField(p, "floor") || srcUsesField(p, "ceil")
      || srcUsesField(p, "abs") || srcUsesField(p, "sqrt")
      || srcUsesField(p, "tointeger") || srcUsesField(p, "type")
      || srcUsesField(p, "ult")
      then LIB_math_int else ""
}

mod libMathTrig(p: string, d: bool) -> string {
  if d { return LIB_math_trig }
  return if srcUses(p, "math.sin") || srcUses(p, "math.cos")
      || srcUses(p, "math.tan") || srcUses(p, "math.asin")
      || srcUses(p, "math.acos") || srcUses(p, "math.atan")
      || srcUses(p, "math.deg") || srcUses(p, "math.rad")
      || srcUsesField(p, "sin") || srcUsesField(p, "cos")
      || srcUsesField(p, "tan") || srcUsesField(p, "asin")
      || srcUsesField(p, "acos") || srcUsesField(p, "atan")
      || srcUsesField(p, "deg") || srcUsesField(p, "rad")
      then LIB_math_trig else ""
}

mod libMathExp(p: string, d: bool) -> string {
  if d { return LIB_math_exp }
  // "math.l" names log AND ldexp in one check: both live in this piece and no
  // other math.l* exists, so one Find answers for two functions.  The same
  // trick does NOT work for deg ("math.d" is deg-only, kept), rad ("math.r"
  // would also catch random, a different piece), or any trig prefix (every one
  // collides: s/sqrt, c/ceil, t/tointeger+type, a/abs).  Checked against the
  // derived member list, not by eye.
  return if srcUses(p, "math.exp") || srcUses(p, "math.l")
      || srcUsesField(p, "exp") || srcUsesField(p, "log")
      || srcUsesField(p, "ldexp")
      then LIB_math_exp else ""
}

// Two pieces where there was one, same measurement as the table.unpack split:
// naming any one of max/min/fmod/modf cost 740 ticks of boot
// (tools/chip/libcost.py), because each was carrying the other three.  The pair
// that shares a shape goes together -- max with min, fmod with modf -- so naming
// one does not parse the other pair.
mod libMathMaxMin(p: string, d: bool) -> string {
  if d { return LIB_math_maxmin }
  return if srcNames2(p, "math", "max") || srcNames2(p, "math", "min")
      then LIB_math_maxmin else ""
}

mod libMathFmodModf(p: string, d: bool) -> string {
  if d { return LIB_math_fmodmodf }
  return if srcNames2(p, "math", "fmod") || srcNames2(p, "math", "modf")
      then LIB_math_fmodmodf else ""
}

// Put the allocator back inside a window bumpMax already claimed.  A call's
// arguments are parsed after its callee register is allocated, and they belong
// in that window, so allocation resumes at reg+1 rather than past its end.
// A CHIP: 8 instances, 1 grid.
// A mod, not a chip: measured cheaper here (instances cost pins -- see the
// chip screening note on cNum).
mod rewindTo(r: int) {
  // regAlloc for its side effect alone (cfMax claims the slot): the old
  // `regAlloc() >= cfNext[fnDepth]` test compared the returned top against
  // itself plus one, so it never fired -- the overflow error is regAlloc's own.
  regAlloc()
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
// A mod, not a chip: measured cheaper here (instances cost pins -- see the
// chip screening note on cNum).
mod logPush(line: string) {
  logLines.push(line)
  logAdd(line)
  if logLines.length() > 32 {
    let drop = logLines[0]
    logDrop(drop.Length())
    logLines.remove(0)
  }
}

// shiftDown lived here and is gone: its one call site (select) is
// retAdjust(src, dst, cnt, cnt), which is the same low-to-high copy when
// k == n.  A 16-rung mod body for one site is what it cost.

// %f[set]: the frontier, a transition into the set.  It needs two set tests, the
// character before the cursor and the one at it, and patItemP is what brings the
// second scan back to the set's text.  Returns the state to run next.
mod patF() -> int {
  if patP + 2 >= patPEnd || patPat.Substring(patP + 2, 1) != "[" {
    patErr = "missing '[' after '%f' in pattern"
    return 8
  }
  patItemP = patP
  // PUC tests '\0' as the character before the first one (and *s reads '\0'
  // past the last, which the curr test below already sees: Substring past either
  // end is "", whose ToCharCode reads 0).  So there is no start special case:
  // the old one forced "previous not in set" at position 1, which made %f[a%z]
  // match "aba" at 1 (PUC says 3, since \0 IS in the set and there is no
  // transition) and %f[^%l] miss position 2 of "a" entirely.
  patAfter = 9
  patFailTo = 9
  let prevCode = if patI == 0 then 0 else patSrc.Substring(patI - 1, 1).ToCharCode().Codepoint
  patSetBegin(patP + 3, prevCode)
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

chip resolveKw() {
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
chip locFind(name: string) {
  lkKind = 0
  lkReg = -1
  lkDone = false
  lkIx = -1
// The ladder below checks the 32 most recent live locals, so a MISS is only
  // proof that the name is a global when it saw all of them.  With more than
  // 32 live it does not: a local the ladder never reached resolves as a global
  // and the program answers wrong with no error anywhere.
  //
  // So the shortfall is refused rather than compiled.  The alternative is to
  // treat an unreached local as a global, which is the bug; and the check has to
  // live here, before any name is resolved, because every later caller reads
  // lkKind and cannot tell a proven global from an unchecked one.
  //
  // 32 is one whole frame of locals, the most a single function can declare.
  // Reaching across frames can still exceed it, and that case is refused rather
  // than guessed.  tools/chip/ladder.py keeps this number and the arm count in
  // step, because a hand-edited one silently desynchronises them.
  if 32 < locLen {
    perr = true
    perrMsg = "too many locals in scope (max 32)"
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

// A mod, not a chip: measured cheaper here (instances cost pins -- see the
// chip screening note on cNum).
mod forDoHead() {
  cpos = cpos + 1
  blkEnter(true)
  let ctrl = locDeclare(forName)
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
      fStart[tmpB] = bop.length()
      fnVar[fnDepth] = true
      stState = 0
    } else {
      perr = true
      perrMsg = "expected ) after ..."
    }
  } else if curKind() == 3 {
    locDeclare(curStr())
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
        // `local function f`: the head declared the name in the enclosing
        // scope and pushed the entry here, so this writes THAT local.  When the
        // body captured f, a closure the body made seeded its cell from the
        // register before this store ran -- so the closure has to land in the
        // cell too, which is the correction locFind's own locCap arm makes for
        // every other store.
        let ix = fnTgtI.pop().Value
        let outer = locReg[ix]
        bEmit(25, outer, fid, 0)
        if locCap[ix] {
          let k6 = capK[ix]
          if 0 <= k6 {
            let uk6 = if 0 <= fUpSrc[fidAt[fnDepth] * MAX_UP + k6] then 0 else 1
            bEmit(47, outer, k6, uk6)
          }
        }
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
        // The head resolved this name before the body ran.  The one thing it could
        // not know is whether the BODY captured f, because a capture turns the
        // local's register into a seed and everything after it -- this store
        // included -- goes through the cell.  That is the same correction
        // locFind makes on its own (see the locCap arm), re-done here from the
        // saved entry index, because a second locFind call site costs +790
        // nodes and this one cannot afford it.
        var tk = fnTgtK.pop().Value
        var tgt = fnTgtR.pop().Value
        let ix = fnTgtI.pop().Value
        if tk == 1 && locCap[ix] {
          let k2 = upSelf(ix)
          if 0 <= k2 {
            tk = 3
            tgt = k2
          }
        }
        if tk == 3 {
          let uk = if 0 <= fUpSrc[fidAt[fnDepth] * MAX_UP + tgt] then 0 else 1
          bEmit(47, fr, tgt, uk)
        } else if tk == 1 {
          bEmit(7, tgt, fr, 0)
        } else {
          bEmit(6, gDeclare(tmpS), fr, 0)
        }
        // A store, so a self-recursion reading the name from the running frame
        // is stale -- the assignment path says the same (doStoreStep).  Hoisted
        // out of the arms: it only clears a flag, so the order does not matter,
        // and one call is cheaper than two.
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
  // A new program clears its predecessor's results BEFORE the parse, not after:
  // the parse is hundreds of ticks and until it finishes every result port still
  // shows the old program, which reads as the new one not having loaded.  The
  // run-start vmReset below keeps its own copies (a `run` edge with no new text
  // clears nothing here, and the second lifecycle window must still start
  // clean), so these are the arrival half and those are the run half.
  oF0 = 0.0
  oF1 = 0.0
  oF2 = 0.0
  oF3 = 0.0
  oS4 = ""
  oS5 = ""
  outNumArrV.clear()
  outNumArrV.resize(ARR_SLOTS, 0.0)
  outStrArrV.clear()
  outStrArrV.resize(ARR_SLOTS, "")
  logV = ""
  logLen = 0
  logLines.clear()
  errV = ""
  resultV = ""
  parseInit()
  // One reserved function slot per gate builtin (ids 0..NB-1), so a program's
  // own functions start at NB and can never collide with one.  The rest of the
  // standard library is Lua source prepended to the program (see libIter etc).
  patSl.resize(PAT_STACK, 0)
  patCapS.resize(33, 0)
  patCapE.resize(33, 0)
  patCapP.resize(33, 0)
  patCapIx.resize(33, 0)
  patGmS.resize(PAT_WALKS, "")
  patGmP.resize(PAT_WALKS, "")
  patGmPos.resize(PAT_WALKS, 1)
  patGmMagic.resize(PAT_WALKS, false)
  patWarned = false
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

chip lexStep() {
  if lstage != 99 && !lerr {
    // ONE Substring for the character, not two.  `cp` is its codepoint and `ch`
    // is the character itself, and both were asking the host for the same
    // one-character slice -- two string allocations on every lexStep, which is
    // the hottest loop in the chip.  The bound check stays on the codepoint,
    // because that is where the 0 for "past the end" is wanted; `ch` keeps
    // taking the slice unconditionally, exactly as before, so a lexStep that
    // runs off the end still sees the "" it always did.
    let ch = lsrc.Substring(lpos, 1)
    let cp = if lpos < llen then ch.ToCharCode().Codepoint else 0
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
        // \a \b \f \v are BEL BS FF VT: 7, 8, 12 and 11, spelled through
        // FromCharCode like every other byte -- the old "the gate cannot spell
        // them" was wrong (probe: string.byte('\7') reads 7), so they were
        // rejected with "bad escape" where PUC answers the character.
        let ec = if cp == 97 then 7 else if cp == 98 then 8 else if cp == 102 then 12 else 11
        lidBuf = lidBuf .. FromCharCode(ec).Character
        lstage = 4
        lpos = lpos + 1
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
// isLast marks the element closed by '}' -- a call there expands, so its results
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
  // noteLibField's provenance starts denied: only a bare GLOBAL name sets it
  // below, so a local, a parameter or an upvalue with a library's name never
  // warns for its own table.  Clearing the NAME is enough: the register half
  // is checked first and "" is no library, so a stale register alone warns
  // for nothing.
  lastBase = ""
  if callParen || callSugar {
    // the callee goes into a fresh call-frame register
    let fr = regAlloc()
    if lkKind == 3 {
      bEmit(46, fr, lkReg, upKind())
    } else if lkKind == 1 {
      bEmit(7, fr, lkReg, 0)
    } else {
      bEmit(5, fr, gRef(name), 0)
      lastBase = name
      lastBaseReg = fr
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
      if lkKind == 3 {
        bEmit(46, r, lkReg, upKind())
      } else {
        bEmit(5, r, gRef(name), 0)
        lastBase = name
        lastBaseReg = r
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
  var v2 = -1
  if 1 < tmpNames.length() {
    v2 = locDeclare(tmpNames[1])
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
        // `local function f` declares f HERE, in the enclosing scope, and only
        // here.  That is the local the rest of the program sees and the frame a
        // closure's cell belongs to, and declaring it before the body is parsed
        // is what makes a capture inside the body resolve to it.
        locDeclare(tmpS)
        fnTgtI.push(locLen - 1)
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
      // Both heads resolve their name HERE, once, before the branch: `function
      // M.f` reads the table it stores into, `function f` decides where the
      // closure goes, and both go through the same ladder.  One call site, not
      // two -- an extra locFind call site measures +790 nodes however deep it
      // sits (doBlockClose and here measured the same), so the second one is
      // never written.
      locFind(tmpS)
      if curKind() == 5 && (curSub() == 23 || curSub() == 31) && nextKind() == 3 {
        // function M.f(...) is M.f = function(...): keep the table in a
        // register and store the function into the field when the body ends.
        // With ':' the field name is a method, so the receiver is parameter one.
        let isMethod = curSub() == 31
        let tr = regAlloc()
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
        // `function f()` is `f = function()`, so the ladder's answer decides
        // the store at the end of the body: a local or an upvalue is written,
        // and only a name in no scope becomes a global.  The answer is carried
        // down as a stack, not per depth, because the store happens at the end
        // of the body and a nested `function g()` in between would land on the
        // same slot.
        fnTgtK.push(lkKind)
        fnTgtR.push(lkReg)
        fnTgtI.push(lkIx)
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
    if nk == 2 || (nk == 5 && ns == 14) {
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
      if blkCapGen[blkCapGen.length() - 1] != capGen && 0 < loopNesting {
        blkGenDone = true
        bEmit(49, 0, loopNesting, 0)
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
  } else if k == 4 && (s == 16 || s == 7) {
    let r = regAlloc()
    bEmit(4, r, if s == 16 then 1 else 0, 0)
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
    pushOp(1, 10, 2, 0, valStk.length())
    cpos = cpos + 1
  } else if k == 5 && s == 15 {
    // ')' in prefix (empty call/group, trailing comma, or drain first)
    closeMode = 1
    popMode = 2
  } else if k == 5 && s == 2 {
    pushOp(1, 10, 0, 0, valStk.length())
    cpos = cpos + 1
  } else if k == 4 && s == 12 {
    pushOp(1, 10, 1, 0, valStk.length())
    cpos = cpos + 1
  } else if k == 5 && s == 27 {
    pushOp(1, 10, 38, 0, valStk.length())
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
      // ...and it is a proper tail call, so mark bit 2: the runtime reuses
      // this frame instead of pushing.  Idempotent by construction (a return
      // owns its call: nothing else patches this bit), and addition preserves
      // bits 0-1, so whichever order the two patches run in, the result is
      // exact.  Parenthesized `(f())` never comes here -- `)` clears the call
      // flag -- which is PUC's rule too (only bare `return f()` is proper).
      // Bit 2 is free by measurement: the highest CALL pc across the suite is
      // 3, so no +2 patch has ever collided with it.
      if presCallPos >= 0 && presCallPos < bpc.length() && bpc[presCallPos] < 4 {
        bpc[presCallPos] = bpc[presCallPos] + 4
      }
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
    // + - * / % ^ are sub 1..6 and opcodes 8..13, in order, so the opcode is
    // the sub plus seven -- no chain.
    let opc = s + 7
    // `**` sits ABOVE unary and the shifts, which is Lua's order: ^ binds
    // tighter than unary (`-2^2` is -(2^2), not (-2)^2) and unary binds tighter
    // than << >> (`-1 >> n` is (-1) >> n, not -(1 >> n)).  Unary used to share
    // the shifts' 6, so left-associativity popped the unary first and every
    // literal like `-8 >> 4` was really `-(8 >> 4)`: it agreed with PUC only
    // where the two happen to coincide, which is why `-8 >> 1` looked right
    // (-4) and `-8 >> 4` did not.
    // The middle band sits where PUC puts it: | < ~ < & < << >> < .. < + -,
    // with * / // % above + - and unary and ^ above those.  `&` used to share
    // `*`'s 5 and `+` sat at `~`'s 4, so `0xF0 & 0x0F + 1` parsed as
    // `(0xF0 & 0x0F) + 1` where PUC reads `0xF0 & (0x0F + 1)` -- and `..`
    // sat at `|`'s 3.  Only the NUMBERS move here (opcodes and assoc bits
    // are untouched), which is why this costs no nodes.
    let prc = if s == 6 then 11 else if s <= 2 then 8 else 9
    let fl = if s == 6 then 0 else 1
    binArrive(opc, prc, fl)
    cpos = cpos + 1
    expectOperand = true
  } else if k == 5 && s == 18 {
    binArrive(16, 7, 0)
    cpos = cpos + 1
    expectOperand = true
  } else if k == 5 && s >= 7 && s <= 12 {
    let opc = if s == 7 || s == 8 then 18 else if s == 9 || s == 10 then 19 else 17
    let fl = if s == 8 || s == 10 then 3 else if s == 12 then 4 else if s == 7 || s == 9 then 1 else 0
    binArrive(opc, 2, fl)
    cpos = cpos + 1
    expectOperand = true
  } else if k == 5 && s == 30 {
    binArrive(34, 9, 1)
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
      // A missing library member warns here, on the read both calls and plain
      // reads flow through -- before the frees below recycle the base register.
      noteLibField(base, curStrAhead())
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
// A mod, not a chip: measured cheaper here (instances cost pins -- see the
// chip screening note on cNum).
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
        // what is on the value stack at a call's close
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

// An error ends the program: errV carries PUC's exact words and the run
// stops.  (Protected calls are gone -- pcall/xpcall are loud stub pieces
// now -- so there is no unwind path anymore, only this one.)
// A CHIP: 122 lexical sites share 53 small grids -- one per distinct
// message, the largest shared by 89. Error path, so per-call ticks are
// irrelevant; the saving is instantiated gates.
chip vmFail(msg: string) {
  vmFailed = true
  errV = msg
  vmHalted = true
}

// PUC's bitwise message names the FIRST operand that is not an integer -- the
// left one when that is the bad one, the right otherwise -- and the five checks
// that used to raise a bare "attempt to perform 'bitwise'" all want that one
// answer, so it is built here.  It is called for every bitwise op, so with two
// good operands it does nothing.  PUC adds "(constant 'x')" when the operand is
// a literal; the chip knows the register but not that it came from a literal, so
// that note is the one part of these messages that stays.
// A mod, not a chip: measured cheaper here (instances cost pins -- see the
// chip screening note on cNum).
mod bitFail(lt: int, lv: float, rt: int, rv: float) {
  if lt != 6 && !(lt == 1 && lv == floor(lv)) {
    vmFail("attempt to perform bitwise operation on a " .. typeName(lt)
      .. " value")
  } else if rt != 6 && !(rt == 1 && rv == floor(rv)) {
    vmFail("attempt to perform bitwise operation on a " .. typeName(rt)
      .. " value")
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
      fmtV = if fmtNeg then 0.0 - vnum[ab] else vnum[ab]
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
      fmtV = if fmtNeg then 0.0 - vnum[ab] else vnum[ab]
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
        fmtBody = fmtBody .. (if fmtUpperE then "E+00" else "e+00")
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
// %e and %g live in fmtConvExp and fmtConvG.  %e is a digit stream rather than
// a scaled value -- no division by ten is exact, so it cannot scale the way %f
// does -- and %g chooses between the two by the rounded exponent, at p-1-k
// places, with trailing zeros dropped unless # is given.  See those two mods
// for the shape; tools/fmt/fmtsweep.py takes the conversion letter as its
// second argument, so `python -u tools/fmt/fmtsweep.py 64 e` checks %e.
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
      fmtV = if fmtNeg then 0.0 - vnum[ab] else vnum[ab]
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
      }
    }
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
// A CHIP, not a mod, and the reason is arithmetic rather than taste.
//
// The TAPPEND arm calls this once per result slot, sixteen times in a row, and a
// mod INLINES at every call site -- so that one arm was carrying sixteen inlined
// copies of this body.  Measured by cutting the ladder to 8 arms and taking the
// slope: 204 nodes and 458 wires per copy, exactly linear on two independent
// intervals, so 3,264 nodes, 7.1% of the chip, for one table-constructor arm.
//
// A chip compiles to ONE shared body template reused by every call site, so the
// sixteen sites become sixteen calls into one copy.  Measured: 46,151 -> 42,918
// nodes (-7.0%) and 95,852 -> 89,026 wires.
//
// It is void because nothing ever read the result: all seventeen call sites use it
// as a statement, and a bool nobody reads is a hidden variable for nothing.
chip tblSetKey(tid: int, kt: int, kn: float, ks: string, vt: int, vn: float, vs: string) {
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
      return
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
    return
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
      return
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
  return
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
  // The round stamp is checked ONLY for a local declared inside a loop body, and
  // against the generation of the depth that body is at.  A cell lives as long as
  // the block that declared its local: a local declared outside every loop is
  // still in scope after a body round ends, so testing it here replaced a live cell
  // with a fresh one and every closure made in a later round saw the loop
  // counter's value at ITS round; and a body nested inside another must not close
  // the outer one's cells, which is why the counter is per depth and not one.
  let fd = fUpDepth[fid * MAX_UP + k]
  if cell <= 0 || vaNum[s + 1] != frameStamp()
      || (0 < fd && vaNum[s + 2] != upGen[fd]) {
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
    vaNum[s + 2] = if 0 < fd then upGen[fd] else 0.0
  }
  // Copy the register in unless someone has written the cell since the last time
  // we looked.  That is the whole rule, and both halves were measured rather than
  // argued:
  //
  //  * Always copying closes the pre-capture window: a loop body that writes the
  //    local and only THEN makes a closure over it wrote the register in rounds
  //    where the cell already existed from round one, and every closure read the
  //    first round's value (10 10 where PUC says 20 20).
  //  * Never copying loses that same window, and the window is not hypothetical:
  //    it is decided by the SOURCE ORDER of the store and the closure, so
  //    swapping the two statements is the difference between 10 10 and 20 20 on the
  //    same program doing the same work.
  //
  // Copying unconditionally instead breaks the other shape: a nested function's
  // write reaches this cell through SETUP's c == 1 path, which updates no
  // register of the frame that owns the cell, so the register is stale from that
  // moment and an unconditional copy undoes it -- `while i <= 4 do local f =
  // function() s = s + i end f() end` answered 4 where PUC answers 10, which is
  // lockstep-loop-cell's shape and the suite caught.
  if !uDirty[cell] {
    let reg = fUpSrc[fid * MAX_UP + k]
    uTag[cell] = vtag[vmBase + reg]
    uNum[cell] = vnum[vmBase + reg]
    uStr[cell] = vstr[vmBase + reg]
  }
  uDirty[cell] = false
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

// Fill one cell of a closure per tick, then publish the value.  nxActive
// short-circuits the instruction dispatch, so nothing can read the half-built
// closure: the value lands in cloDst before the instruction after LOADFUNC
// runs.  One tick per cell is the price of keeping the array stores out of
// the op-25 arm.
// A mod, not a chip: measured cheaper here (instances cost pins -- see the
// chip screening note on cNum).
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
// them, and the instruction steps past itself.  A machine that raises ends
// the program with the message, there being no unwind anymore.
// A CHIP: 6 instances, 1 grid.
chip nxDone() {
  vmPc = nxPc + 1
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
    vtag[nxDst + 1] = 6
    vnum[nxDst + 1] = patI * 1.0
    if patMode == 2 {
      vtag[nxDst + 2] = 6
      vnum[nxDst + 2] = patNCap * 1.0
    }
    // mode 2 answers the capture count in the third register, so its window is
    // one wider; the bound check is the same shape either way.
    patAOff = if patMode == 2 then 3 else 2
    if patAOff + patNCap > MAXVALS {
      patErr = "too many captures to return"
      patSt = 8
    } else {
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
  } else if ce == 0 {
    vtag[d] = 0
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

// One literal find/match/gsub-step answer, from the scalars fid-20 left
// (patStart is the 0-based hit or -1, patI the end-exclusive index, patMode
// the call's mode).  A top-level step of its own, called from vmStep: array
// writes inside the gate arm are dropped, so the arm only computes and this
// writes.  Shapes mirror patNone/patDone: nil counts 1, a match is one
// string, positions are two integers, a gsub step adds the zero count.
mod patPlainAnswer() {
  if patStart < 0 {
    vtag[nxDst] = 0
    vnum[nxDst] = 0.0
    vstr[nxDst] = ""
    retCountV = 1
  } else if patMode == 1 {
    vtag[nxDst] = 2
    vnum[nxDst] = 0.0
    vstr[nxDst] = patSrc.Substring(patStart, patI - patStart)
    retCountV = 1
  } else {
    vtag[nxDst] = 6
    vnum[nxDst] = patStart + 1.0
    vstr[nxDst] = ""
    vtag[nxDst + 1] = 6
    vnum[nxDst + 1] = patI * 1.0
    vstr[nxDst + 1] = ""
    if patMode == 2 {
      vtag[nxDst + 2] = 6
      vnum[nxDst + 2] = 0.0
      vstr[nxDst + 2] = ""
      retCountV = 3
    } else {
      retCountV = 2
    }
  }
  nxActive = false
  nxDone()
}

// Whether a needle was probably meant as a pattern: any of PUC's magic
// characters in it.  Twelve host searches, so callers only ask on a miss --
// a needle that matched needs no comment.  A mod (two call sites, both in
// gateHigh): measured against a chip if the audit complains.
mod patHasMagic(s: string) -> bool {
  // most frequent magic first: || short-circuits, so a '.' or '%' needle
  // pays one search and only a '?' pays all twelve.
  return 0 <= s.Find(".", true, 0) || 0 <= s.Find("%", true, 0)
      || 0 <= s.Find("*", true, 0) || 0 <= s.Find("+", true, 0)
      || 0 <= s.Find("?", true, 0) || 0 <= s.Find("[", true, 0)
      || 0 <= s.Find("]", true, 0) || 0 <= s.Find("(", true, 0)
      || 0 <= s.Find(")", true, 0) || 0 <= s.Find("^", true, 0)
      || 0 <= s.Find("$", true, 0) || 0 <= s.Find("-", true, 0)
}

// One warn per program into progDebug: a magic needle that matched nothing
// was almost certainly meant as a pattern, and patterns are literal here, so
// silence would read as the call being broken.  The latch (reset per program
// in parseJobStart, kept across restarts) is what keeps a loop over a missing
// needle to one line.
mod patWarn() {
  if !patWarned {
    patWarned = true
    progDebugV = progDebugV .. "warn: '" .. patPat
      .. "' has magic characters; patterns are literal on this chip\n"
  }
}

// No match anywhere: both find and match answer nil.
mod patNone() {
  vtag[nxDst] = 0
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
  // PUC tries start positions 0..len inclusive (its loop is s <= src_end): an
  // empty match AT the end is a match, which is how (%w*)$ finds "" and %f
  // matches a final transition.  Stopping at len - 1 missed both.  Every
  // consuming item already fails cleanly at patI == patLen (patTestItem answers
  // 0 there, %b's first step misses), so the extra position can only match
  // empty -- which is the point -- at the cost of one more start attempt on a
  // miss.
  if patAnchor || patR + 1 > patLen {
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
  let ini = if iniArg < 1 then 1 else iniArg
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
  if patLen + 1 < ini {
    vtag[dst] = 0
    // the end of a gmatch walk answers *no* values, which is what ends the loop:
    // a single nil is a value, and a for-in that gets one runs for ever
    retCountV = if mode == 3 then 0 else 1
  } else if mode == 3 && patPSkip == 1 {
    // measured: a pattern that starts with ^ matches nothing at all in gmatch,
    // while find and gsub both take it as the anchor and honour it
    vtag[dst] = 0
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
// An item's EXTENT is a property of the pattern, not of the subject, so it is
// written before the subject is looked at.  That order is the fix for a hang and
// for seven wrong answers, and both came from the same line.
//
// ("abc"):match(".*c") tests the `c` against an exhausted subject, misses, and --
// leaving patItemE at the `.`'s extent, one character into a `*` -- patApply read
// a quantifier off THAT, found `*`, and gave the pattern zero more repetitions at
// the position it was already at, for ever.  PUC cannot reach this shape: a
// failed match() returns NULL and do_match backtracks at once, so a quantifier is
// only ever read for an item that matched.  Every item here goes through
// patApply, so the extent has to be honest on the miss path too.
//
// Which is also seven answers the other way.  An item that misses at the end of
// the subject may still legitimately match EMPTY there, and then its own
// quantifier is what says so: ("abc"):match("b*$"), ("abc"):match("%a*$"),
// ("abc"):match("(%d*)$"), ("abc"):match("(.-)$") and ("abc "):match("[a]*$") are
// all "" in PUC and nil here, because the miss never got the quantifier.  p + 1
// is only the right extent for a one-character item; %x is p + 2 and a set is its
// closing bracket, so an extent guessed here is a second bug wearing the first
// one's coat.
mod patTestItem(p: int, s: int) -> int {
  patAdv = 1
  if p >= patPEnd {
    patItemE = p + 1
    return 0
  }
  // One read of the subject, shared by all four arms: this mod is inlined at every
  // item and a repeated Substring and a repeated `s >= patLen` are paid once per
  // copy.  "" is the exhausted subject -- a character the subject holds is never
  // "" -- and "" .ToCharCode() is 0, which is the reading the %f arm already
  // relies on for the ends.
  let sc = if s >= patLen then "" else patSrc.Substring(s, 1)
  let noSubj = sc == ""
  let k = patPat.Substring(p, 1)
  if patPlain {
    patItemE = p + 1
    return if noSubj then 0 else if k == sc then 1 else 0
  }
  if k == "[" {
    // A set's extent is its closing bracket and PUC's match() finds that before it
    // reads the subject, so a set on an exhausted subject still knows it.  The set
    // machine is what walks to the bracket, so hand it the subject character (0
    // when there is none) and tell it SEPARATELY that the verdict is already a miss
    // -- it writes patItemE on the way, and its routing does not depend on patHit
    // (patNextItem gives a set item patAfter == patFailTo == 2, so both verdicts
    // land on patApply).  %f drives this machine too and DOES read patHit, which is
    // why patNoSubj is cleared in patSetBegin rather than here: this arm does not
    // run for %f, so a flag cleared by its only writer would still be live when %f
    // started.
    patSetBegin(p + 1, sc.ToCharCode().Codepoint)
    patNoSubj = noSubj
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
    return if noSubj then 0 else if patClassHit(sc.ToCharCode().Codepoint, if neg then code + 32 else code, neg) then 1 else 0
  }
  patItemE = p + 1
  return if noSubj then 0 else if k == "." then 1 else if k == sc then 1 else 0
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
    if k0 == 1 || k0 == 9 {
      // Every value this arm needs comes from the locals read at the top of the
      // mod, and nothing below READS a var it has just written.  That is this
      // mod's own header rule, and this arm broke it twice: it wrote patI and then
      // read `patI - 1` to re-push, and it wrote patQEnd and then read patQEnd
      // into patP.  Both are reads that follow a var write inside a nested arm,
      // which is the shape the header says loses its Exec chain when the mod is
      // inlined this many times.
      //
      // Kind 9 is the same give-back with a floor, and for kind 9 the item slot
      // carries where the repeat BEGAN rather than the item's pattern position:
      // begin >= lastStart means the last repetition already starts where the
      // repeat starts, so giving it back would leave `+` with none.  The kind is
      // re-pushed, so the floor holds for every step of the walk down and not
      // just the first.
      //
      // `patSp = sp` is the POP, and sp is already the popped pointer -- writing
      // `sp + 4` cancels it, leaves the entry in place and spins patSt 4 for
      // ever.  Two flat tests and no `else`, so the floor overrides patSt after
      // the ordinary writes rather than competing with them for the arm's depth.
      patSp = sp
      patItemP = k1
      patI = k2
      patQEnd = k3
      patP = k3
      patSt = 1
      if k0 == 9 && k1 >= k2 {
        patSt = 4
      } else if 0 <= k2 - 1 {
        patPush(k0, k1, k2 - 1, k3)
      }
    } else if k0 == 2 {
      // The `?` alternative: the tail runs again without the item, which means
      // the subject rewinds to where the item started (k2 above), not where it
      // ended.  Without the rewind ("b"):match(".?b") missed: the tail retried
      // `b` at position 1, past the end, instead of at 0.  (patItemP needs no
      // restore: patNextItem sets it fresh for every item it tests.)
      patSp = sp
      patI = k2
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
      vSetNil(a)
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
      vSetNil(a)
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
        if w < inNumArr.length() { vSetNum(a, inNumArr[w]) } else { vSetNil(a) }
      }
      if 1 < cnt {
        if w + 1 < inNumArr.length() { vSetNum(a + 1, inNumArr[w + 1]) } else { vSetNil(a + 1) }
      }
      if 2 < cnt {
        if w + 2 < inNumArr.length() { vSetNum(a + 2, inNumArr[w + 2]) } else { vSetNil(a + 2) }
      }
      if 3 < cnt {
        if w + 3 < inNumArr.length() { vSetNum(a + 3, inNumArr[w + 3]) } else { vSetNil(a + 3) }
      }
      if 4 < cnt {
        if w + 4 < inNumArr.length() { vSetNum(a + 4, inNumArr[w + 4]) } else { vSetNil(a + 4) }
      }
      if 5 < cnt {
        if w + 5 < inNumArr.length() { vSetNum(a + 5, inNumArr[w + 5]) } else { vSetNil(a + 5) }
      }
      if 6 < cnt {
        if w + 6 < inNumArr.length() { vSetNum(a + 6, inNumArr[w + 6]) } else { vSetNil(a + 6) }
      }
      if 7 < cnt {
        if w + 7 < inNumArr.length() { vSetNum(a + 7, inNumArr[w + 7]) } else { vSetNil(a + 7) }
      }
      retCountV = cnt
    }
  } else if fid == 7 {
    // outnumarr(i, v, ...) writes i and the next slots, one per extra
    // value, up to 8.  A call with more values writes the first 8, the same
    // way the two-value form ignored whatever came after the second.  The
    // port is @right out, so the whole array reaches it every tick however
    // it was filled: what this saves is the CALL, and 8 values to a call is
    // the cheap way to pay less of it.
    let it = if 0 < nargs then vTag(a + 1) else 0
    let iv = if 0 < nargs then vNum(a + 1) else 0.0
    if (it != 1 && it != 6) || iv != floor(iv) || iv < 1.0 || iv > outNumArrV.length() {
      vmFail("array index out of range")
    } else {
      let w = toInt(iv) - 1
      // one value per extra argument, so the count is nargs - 1 and not nargs:
      // counting the index made outnumarr(64, -1) ask for slot 65, which the
      // demo caught because it writes the last slot
      let cnt = if nargs < 9 then nargs - 1 else 8
      if w + cnt > outNumArrV.length() {
        vmFail("array index out of range")
      } else {
        if 1 < nargs && !arrNumOk(vTag(a + 2)) { vmFail("array element must be a number") }
        if 1 < nargs { outNumArrV[w] = if vTag(a + 2) == 0 then 0.0 else vNum(a + 2) }
        if 2 < nargs && !arrNumOk(vTag(a + 3)) { vmFail("array element must be a number") }
        if 2 < nargs { outNumArrV[w + 1] = if vTag(a + 3) == 0 then 0.0 else vNum(a + 3) }
        if 3 < nargs && !arrNumOk(vTag(a + 4)) { vmFail("array element must be a number") }
        if 3 < nargs { outNumArrV[w + 2] = if vTag(a + 4) == 0 then 0.0 else vNum(a + 4) }
        if 4 < nargs && !arrNumOk(vTag(a + 5)) { vmFail("array element must be a number") }
        if 4 < nargs { outNumArrV[w + 3] = if vTag(a + 5) == 0 then 0.0 else vNum(a + 5) }
        if 5 < nargs && !arrNumOk(vTag(a + 6)) { vmFail("array element must be a number") }
        if 5 < nargs { outNumArrV[w + 4] = if vTag(a + 6) == 0 then 0.0 else vNum(a + 6) }
        if 6 < nargs && !arrNumOk(vTag(a + 7)) { vmFail("array element must be a number") }
        if 6 < nargs { outNumArrV[w + 5] = if vTag(a + 7) == 0 then 0.0 else vNum(a + 7) }
        if 7 < nargs && !arrNumOk(vTag(a + 8)) { vmFail("array element must be a number") }
        if 7 < nargs { outNumArrV[w + 6] = if vTag(a + 8) == 0 then 0.0 else vNum(a + 8) }
        if 8 < nargs && !arrNumOk(vTag(a + 9)) { vmFail("array element must be a number") }
        if 8 < nargs { outNumArrV[w + 7] = if vTag(a + 9) == 0 then 0.0 else vNum(a + 9) }
        vSetNil(a)
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
        vSetNil(a)
        retCountV = 0
      } else {
        // retAdjust with k == n is a pure copy, in the same low-to-high
        // order shiftDown used to spell out: the ranges overlap (a frame
        // starts where its results go), so a high slot must not be written
        // before a lower slot has read its source.
        retAdjust(vmBase + src, vmBase + a, cnt, cnt)
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
    locFind(nm)
    if lkKind == 3 {
      // an upvalue has no register to fold into, so this is always its own
      // instruction
      bEmit(47, tmpB, lkReg, upKind())
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
mod gateHigh(fid: int, a: int, nargs: int, mtSelf: bool, cid: int, isTail: bool) -> bool {
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
        vSetNil(a)
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
    } else if mo == 15 {
      // _m(15, s, 0): PUC's string-to-number coercion asked as a QUESTION --
      // the number, or nil when the string is not a numeral.  This is what
      // tonumber is, and it is what the library pieces need to check a
      // numeric STRING argument without raising: string.rep('a', '3x') has to
      // be able to tell "not a numeral" from "a numeral with no integer
      // representation", which are two different PUC messages.  They used to
      // get that by one pcall of a converter each, and catching is gone from
      // the chip now (see fid 18), so the question is asked here instead.
      //
      // ParseInt first, exactly as arithValL does, so '2' answers an integer
      // and '2.0' a float; a string that answers nil here is not a numeral at
      // all ('inf' included, which is not one in Lua and is one to the host).
      let sv = if vTag(a + 2) == 2 then vStr(a + 2) else ""
      let i = sv.ParseInt()
      if i.Success {
        vSetInt(a, i)
      } else {
        let p = sv.ParseNumber()
        if p.Success {
          vSetNum(a, p)
        } else {
          vSetNil(a)
        }
      }
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
          vSetNil(a)
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
    // pcall and xpcall are loud stub pieces on this chip: catching costs
    // ~3,875 nodes (marker frames, resume state, result relocation) and the
    // size budget had those against plain patterns, so catching is gone.  The
    // words are PUC's error gate raising, so a program that names pcall gets
    // one message it can read, and error()/assert() -- separate gates -- keep
    // working exactly as before.  Recovering from an error is the caller's:
    // an erroring function answers nil plus a message, which is what the
    // library pieces here already do.
    vmFail(if fid == 18 then "pcall is not supported on this chip"
           else "xpcall is not supported on this chip")
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
        if cnt == 0 { vSetNil(a) }
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
      vSetNil(a)
    } else {
      let w = fmtVal(vTag(a + 1), vNum(a + 1), vStr(a + 1))
      logPush(w)
      vSetNil(a)
    }
    retCountV = 1
  } else if fid == 16 {
    // error(msg [, level]) and assert, which PUC has in C (lbaselib.c)
    // and are gates here for the same reason.
    //
    // An error ends the run: there is no catch on this chip.  pcall and
    // xpcall were the catching half, and they are removed -- marker frames,
    // resume state and result relocation measured ~6,500 nodes here after
    // inlining, which is more than everything else in the budget combined.
    // The loud stubs at fid 18/19 say so in one line.  What this gate keeps
    // is the whole point of it: PUC's words, on the error port, with the run
    // stopped, which is what a control-plane program does with a failure it
    // cannot recover from.  A program that wants to recover answers nil plus
    // a message from its own function instead.
    //
    // The one thing this gate cannot do is name a position: PUC prefixes
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
        vSetNil(a)
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
    if patCheck(a, nargs, nm, 2) {
      // patLen lived in patArm, which nothing calls now: the bounds below
      // read it, so this arm sets it from the subject it just checked.
      patLen = patSrc.Length()
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
        // Literal needle: one host search here (reads, locals and scalars
        // are all fine in this arm); the answers go out through patPlainAnswer
        // next tick, because array writes inside this arm are dropped.  An
        // empty needle matches empty at the start position.  Bounds are
        // patArm's old rules, verbatim: below 1 starts at 1, and past
        // len + 1 finds nothing at all.
        nxDst = vmBase + a
        nxPc = vmPc
        if ini < 1 {
          ini = 1
        }
        var f = -2
        if ini <= patLen + 1 {
          f = ini - 1
          if 0 < patPat.Length() {
            f = patSrc.Find(patPat, true, ini - 1)
          }
        }
        // A miss with magic in the needle is the shape ported pattern code
        // takes: warn once (patWarn latches) rather than answering a bare nil
        // that reads as the call being broken.  Statement form, not folded
        // into the expression: a mod call in value position runs whether its
        // arm does or not, and a hit must not pay for twelve searches.
        if f < 0 {
          if patHasMagic(patPat) {
            patWarn()
          }
        }
        patStart = f
        patI = f + patPat.Length()
        patMode = mode
        nxActive = true
        nxMode = 2
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
        vSetNil(a)
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
          vSetNil(a)
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
    // outnum(i, v): write one of the four numeric output ports.  A call, not an
    // assignment, so writing to the world reads as an action.  The index is
    // 1-BASED like every table a Lua program can already see, so outnum(1, v)
    // and outnumarr(1, v) are the same slot and neither has an off-by-one to
    // remember.
    let oi = if 0 < nargs then toInt(vNum(a + 1)) else -1
    let ot = if 1 < nargs then vTag(a + 2) else 0
    let ov = if 1 < nargs then vNum(a + 2) else 0.0
    if oi < 1 || oi > 4 {
      vmFail("outnum index must be 1..4")
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
    }
    vSetNil(a)
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
    vSetNil(a)
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
      vSetNil(a)
      retCountV = 1
    } else if kv != floor(kv) || kv < 1.0 || kv > 8.0 {
      vmFail("bad argument #2 to 'instrarr' (count out of range)")
    } else {
      // i and k captured first, for the reason the innumarr arm gives.
      let w = toInt(iv) - 1
      let cnt = toInt(kv)
      if 0 < cnt {
        if w < inStrArr.length() { vSet(a, 2, 0.0, inStrArr[w]) } else { vSetNil(a) }
      }
      if 1 < cnt {
        if w + 1 < inStrArr.length() { vSet(a + 1, 2, 0.0, inStrArr[w + 1]) } else { vSetNil(a + 1) }
      }
      if 2 < cnt {
        if w + 2 < inStrArr.length() { vSet(a + 2, 2, 0.0, inStrArr[w + 2]) } else { vSetNil(a + 2) }
      }
      if 3 < cnt {
        if w + 3 < inStrArr.length() { vSet(a + 3, 2, 0.0, inStrArr[w + 3]) } else { vSetNil(a + 3) }
      }
      if 4 < cnt {
        if w + 4 < inStrArr.length() { vSet(a + 4, 2, 0.0, inStrArr[w + 4]) } else { vSetNil(a + 4) }
      }
      if 5 < cnt {
        if w + 5 < inStrArr.length() { vSet(a + 5, 2, 0.0, inStrArr[w + 5]) } else { vSetNil(a + 5) }
      }
      if 6 < cnt {
        if w + 6 < inStrArr.length() { vSet(a + 6, 2, 0.0, inStrArr[w + 6]) } else { vSetNil(a + 6) }
      }
      if 7 < cnt {
        if w + 7 < inStrArr.length() { vSet(a + 7, 2, 0.0, inStrArr[w + 7]) } else { vSetNil(a + 7) }
      }
      retCountV = cnt
    }
  } else if fid == 26 {
    // outstrarr(i, v, ...) writes i and the next slots, one string
    // per extra value, up to 8.  A call with more values writes the
    // first 8.  The index is 1-based over the outStrArr slots, and a
    // call that would run past the end fails, so a run of adjacent
    // slots costs one call instead of k.  A value may be a string or
    // nil, and nil stores ""; anything else is a runtime error.
    let it = if 0 < nargs then vTag(a + 1) else 0
    let iv = if 0 < nargs then vNum(a + 1) else 0.0
    if (it != 1 && it != 6) || iv != floor(iv) || iv < 1.0 || iv > outStrArrV.length() {
      vmFail("array index out of range")
    } else {
      let w = toInt(iv) - 1
      let cnt = if nargs < 9 then nargs - 1 else 8
      if w + cnt > outStrArrV.length() {
        vmFail("array index out of range")
      } else {
        if 1 < nargs && !arrStrOk(vTag(a + 2)) { vmFail("array element must be a string") }
        if 1 < nargs { outStrArrV[w] = if vTag(a + 2) == 0 then "" else vStr(a + 2) }
        if 2 < nargs && !arrStrOk(vTag(a + 3)) { vmFail("array element must be a string") }
        if 2 < nargs { outStrArrV[w + 1] = if vTag(a + 3) == 0 then "" else vStr(a + 3) }
        if 3 < nargs && !arrStrOk(vTag(a + 4)) { vmFail("array element must be a string") }
        if 3 < nargs { outStrArrV[w + 2] = if vTag(a + 4) == 0 then "" else vStr(a + 4) }
        if 4 < nargs && !arrStrOk(vTag(a + 5)) { vmFail("array element must be a string") }
        if 4 < nargs { outStrArrV[w + 3] = if vTag(a + 5) == 0 then "" else vStr(a + 5) }
        if 5 < nargs && !arrStrOk(vTag(a + 6)) { vmFail("array element must be a string") }
        if 5 < nargs { outStrArrV[w + 4] = if vTag(a + 6) == 0 then "" else vStr(a + 6) }
        if 6 < nargs && !arrStrOk(vTag(a + 7)) { vmFail("array element must be a string") }
        if 6 < nargs { outStrArrV[w + 5] = if vTag(a + 7) == 0 then "" else vStr(a + 7) }
        if 7 < nargs && !arrStrOk(vTag(a + 8)) { vmFail("array element must be a string") }
        if 7 < nargs { outStrArrV[w + 6] = if vTag(a + 8) == 0 then "" else vStr(a + 8) }
        if 8 < nargs && !arrStrOk(vTag(a + 9)) { vmFail("array element must be a string") }
        if 8 < nargs { outStrArrV[w + 7] = if vTag(a + 9) == 0 then "" else vStr(a + 9) }
        vSetNil(a)
        retCountV = 0
      }
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
        // A tail call reuses its frame, and with it the whole region this one
        // owned: its sequence word, its cells and its varargs are dead the
        // moment it hands over, and they are one contiguous run ending at
        // vaTop.  Starting the callee there is what makes the recursion
        // constant-stack -- starting above fVaB[top] instead leaked one word a
        // call, so 100,000 of them ran the vararg arena out with the frame
        // stack still at one ("too many captured locals live at once").  A
        // callee that does NOT fit -- more cells, or more varargs, than the
        // caller had -- falls through to the usual growth, which is still
        // bounded by the frame count and still correct.
        // 0 <= tailB keeps a negative base out; the main chunk never tail-calls
        // (no return at top level), so its entry 0 never reaches the reuse.
        let tailB = slotBase() - 1
        let reuse = isTail && 0 <= tailB && tailB + nslots + nva <= vaTop
        if !reuse && vaTop + nslots > MAX_VA {
          vmFail("too many captured locals live at once")
        } else if !reuse && vaTop + nslots + nva > MAX_VA {
          vmFail("too many varargs")
        } else {
          frameSeq = frameSeq + 1
          let slotB = if reuse then tailB else vaTop
          vaNum[slotB] = frameSeq
          vaSpill(vmBase + a + 1 + np, slotB + nslots, nva)
          if isTail {
            fVaB[fVaB.length() - 1] = slotB
          } else {
            // The entry is the caller's top: the return pops
            // to it, so the callee's slots below are reusable, not orphaned.
            fVaB.push(slotB)
          }
          vaTop = slotB + nslots + nva
        }
        // A tail call overwrites its frame instead of pushing: new function
        // and base on top, return address KEPT -- it returns straight to our
        // caller, with our wanted-count, which is what PUC's tailcall does.
        // fForDepth takes the ambient value, exactly as a push would.
        if isTail {
          fFunc[fFunc.length() - 1] = cid
          fBase[fBase.length() - 1] = nbase
          fForDepth[fForDepth.length() - 1] = forDepth
        } else {
          fFunc.push(cid)
          fBase.push(nbase)
          fRetA.push(a)
          fRetBase.push(vmBase)
          fRetPC.push(vmPc + 1)
          fRetN.push(if mtSelf then -2 else 1)
          fForDepth.push(forDepth)
        }
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
    patGmMagic[patGmId] = patHasMagic(patPat)
    vtag[nxDst] = 4
    vnum[nxDst] = 22.0
    vtag[nxDst + 1] = 6
    vnum[nxDst + 1] = patGmId * 1.0
    vtag[nxDst + 2] = 0
    vnum[nxDst + 2] = 0.0
    vstr[nxDst + 2] = ""
    retCountV = 3
    nxActive = false
    nxDone()
  } else {
    patSrc = patGmS[patGmId]
    patPat = patGmP[patGmId]
    // Below 1 starts at 1, as patArm's old clamp did: the walk's init can be
    // zero through gmatch's own posrelat.
    let pos = if patGmPos[patGmId] < 1 then 1 else patGmPos[patGmId]
    // patArm records where to come back to as vmPc, and this step runs a tick
    // *after* the call, by which time vmPc is the next instruction: without
    // putting it back the machine returns past the generic-for's nil test, the
    // loop never ends, and the walk is called again from the start for ever.
    vmPc = nxPc
    // Literal needle: one host search per step, no machine.  Past the end the
    // walk is over (nil, no values); an empty needle matches empty at the
    // cursor.  The cursor rule is patDone's old mode-3 one, verbatim: past a
    // non-empty match it stands after it, past an empty one it steps one
    // beyond where it stood, and past the subject's end it ends the walk.
    if patSrc.Length() + 1 < pos {
      vtag[nxDst] = 0
      vnum[nxDst] = 0.0
      vstr[nxDst] = ""
      retCountV = 0
      // A magic walk that never yielded warned: pos still at its init means
      // no match ever moved it (a non-empty literal always does).
      if patGmMagic[patGmId] {
        if patGmPos[patGmId] == patGmIni {
          patWarn()
        }
      }
      nxActive = false
      nxDone()
    } else {
      var f = pos - 1
      if 0 < patPat.Length() {
        f = patSrc.Find(patPat, true, pos - 1)
      }
      if f < 0 {
        vtag[nxDst] = 0
        vnum[nxDst] = 0.0
        vstr[nxDst] = ""
        retCountV = 0
        if patGmMagic[patGmId] {
          if patGmPos[patGmId] == patGmIni {
            patWarn()
          }
        }
        nxActive = false
        nxDone()
      } else {
        let s = f
        let e = f + patPat.Length()
        vtag[nxDst] = 2
        vnum[nxDst] = 0.0
        vstr[nxDst] = patSrc.Substring(s, patPat.Length())
        retCountV = 1
        patGmPos[patGmId] = if e == s then s + 2 else if e == patSrc.Length() then patSrc.Length() + 2 else e + 1
        nxActive = false
        nxDone()
      }
    }
  }
}

// Is a micro-step machine or a closure fill driving this tick?
// vmStep routes on these; vmStepFast has to stand aside on the SAME set, and the
// set is written once here so the two cannot drift.  A copied list is how
// string.format got dispatched past: the fast step had its own idea of what
// "busy" meant and did not include the format machine.
mod vmBusy() -> bool {
  return cloActive || lenChase || nxActive || cmpActive
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
// A mod, not a chip: measured cheaper here (instances cost pins -- see the
// chip screening note on cNum).
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
  } else {
    vmBase = rb
    vSet(ra, rv, rn, rs)
    vmPc = rpc
    retCountV = 1
  }
}

// A mod, not a chip: measured cheaper here (instances cost pins -- see the
// chip screening note on cNum).
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
  } else if lenChase {
    lenStep()
  } else if nxActive {
    if nxMode == 1 {
      if fmtGo {
        fmtGo = false
        fmtStep()
      }
    } else if nxMode == 2 {
      patPlainAnswer()
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
    // HALT is the LAST arm, not the first.  docs/vm-isa records it as "handled
    // defensively; the compiler normally ends with RETURN0", so it runs at most
    // once per program -- while in first position its failed comparison is paid
    // by every instruction this step dispatches.  vmStepFast says the same about
    // why FORLOOP is here.
    if op == 1 {
      vSetNil(a)
    } else if op == 2 {
      if c == 1 {
        vSetIntSat(a, constNum[b])
      } else {
        vSetNum(a, constNum[b])
      }
    } else if op == 3 {
      vSet(a, 2, 0.0, constStr[b])
    } else if op == 4 {
      vSetN(a, 3, if b == 0 then 0.0 else 1.0)
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
          // The arithmetic dispatch is written TWICE -- once in vmStep and once in
          // vmStepFast, which is the subset that runs when nothing is busy -- and
          // both copies carry a pow arm.  Fixing only this one changed nothing
          // observable: `local z = -0.0 print(z ^ 3)` still answered 0.0 until the
          // other copy went through the same helper.  One body, two call sites,
          // so the rule about a negative zero base cannot be stated twice.
          vSetNum(a, powSignedZero(x, y))
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
      vSetN(a, 3, if truthyOf(vTag(b), vNum(b)) then 0.0 else 1.0)
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
          vSetN(a, 3, if vNum(b) == rv then 1.0 else 0.0)
        } else if lt != rt {
          vSetN(a, 3, 0.0)
        } else if lt == 2 {
          vSetN(a, 3, if vStr(b) == vStr(c) then 1.0 else 0.0)
        } else if lt == 0 {
          vSetN(a, 3, 1.0)
        } else {
          // lt == rt == 3, 4 or 5 here, all compared by number: lt == 1 went
          // through the numeric arm above (ln covers it), so its own arm --
          // which could never fire -- is gone and the three number-compared
          // tags share one instead of spelling it twice.
          vSetN(a, 3, if vNum(b) == rv then 1.0 else 0.0)
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
          vSetN(a, 3, if hit then 1.0 else 0.0)
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
    } else if op == 23 {
      if vTag(a) != 4 {
        vmFail("attempt to call")
      } else {
        let cid = toInt(vNum(a))
        // C operand bits: 1 = my last argument is an expanding call (so the
        // arg count is one short and the tail's own count is added at run
        // time); 2 = I return all of my results, not just one; 4 = I am a
        // proper tail call (`return f()`), so reuse the current frame instead
        // of pushing.  Bit 2 survives the +2 patches (addition preserves it)
        // and is set once, at the return that owns the call, so masking is
        // exact here.
        //
        // The arm used to be `op == 23 || op == 41` and mtSelf also tested
        // `op == 41`, for CALLM.  It is still an opcode in docs/vm-isa and still
        // nothing emits it -- there is no bEmit(41, ...) anywhere in the
        // compiler -- so both were a comparison paid by every Lua call in the
        // hottest arm in the chip.
        // Bits, not a list of cases: `c == 1 || c == 3 || c == 5 || c == 7`
        // and its five siblings are nine comparisons paid by EVERY Lua call in
        // the chip, and three masks say the same thing.
        let mtArg = (c & 1) == 1
        let mtSelf = (c & 2) != 0
        let isTail = (c & 4) != 0
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
          if gateHigh(fid, a, nargs, mtSelf, cid, isTail) {
            advanced = true
          }
        }
        if vmPc != pc0 {
          // a gate that changed the frame moved vmPc; one that did not falls
          // through to the caller's vmPc + 1, as every other arm here does
          advanced = true
        }
      }
    } else if op == 45 {
      // VARARG a, b: b = 1 gives one value, b = 0 gives all of them.
      // The entry is the frame's slotB (see slotBase); its varargs start a
      // table above it.
      let base = fVaB[fVaB.length() - 1] + 3 * fUpSlotN[curFid()] + 1
      let have = vaTop - base
      let want = if b == 0 then have else b
      if 1 <= want {
        let k = if have < want then have else want
        vaFill(base, vmBase + a, k)
        if k < want {
          // pad with nil so a fixed-arity target list sees the missing values
          if k + 1 <= want { vSetNil(a + k) }
          if k + 2 <= want { vSetNil(a + k + 1) }
          if k + 3 <= want { vSetNil(a + k + 2) }
          if k + 4 <= want { vSetNil(a + k + 3) }
          if k + 5 <= want { vSetNil(a + k + 4) }
          if k + 6 <= want { vSetNil(a + k + 5) }
          if k + 7 <= want { vSetNil(a + k + 6) }
          if k + 8 <= want { vSetNil(a + k + 7) }
          if k + 9 <= want { vSetNil(a + k + 8) }
          if k + 10 <= want { vSetNil(a + k + 9) }
          if k + 11 <= want { vSetNil(a + k + 10) }
          if k + 12 <= want { vSetNil(a + k + 11) }
          if k + 13 <= want { vSetNil(a + k + 12) }
          if k + 14 <= want { vSetNil(a + k + 13) }
          if k + 15 <= want { vSetNil(a + k + 14) }
          if k + 16 <= want { vSetNil(a + k + 15) }
        }
      } else {
        vSetNil(a)
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
      } else {
        vmBase = rb
        vSetNil(ra)
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
          vSetNil(ra)
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
        vSetN(a, 4, b)
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
        vSetNil(a)
      }
    } else if op == 47 {
      // SETUP a=source, b=descriptor, c=kind.  The local's own register is
      // written as well as the cell, because the register is its home and a
      // closure made later copies the register in when the cell has not been
      // written since (see cellAt).  Both paths set uDirty: the c == 0 one has
      // the register current too, but marking it is harmless and it keeps the
      // rule to one statement instead of two that have to agree.
      let fid = curFid()
      if c == 1 {
        let cell = cloU[curClo() * MAX_UP + b]
        if 0 < cell {
          uTag[cell] = vTag(a)
          uNum[cell] = vNum(a)
          uStr[cell] = vStr(a)
          uDirty[cell] = true
        }
      } else {
        let cell = cellRead(fid, b, false)
        if 0 < cell {
          uTag[cell] = vTag(a)
          uNum[cell] = vNum(a)
          uStr[cell] = vStr(a)
          uDirty[cell] = true
        }
        let abs = vmBase + fUpSrc[fid * MAX_UP + b]
        vtag[abs] = vTag(a)
        vnum[abs] = vNum(a)
        vstr[abs] = vStr(a)
      }
    } else if op == 48 {
      vSetN(a, 4, curClo())
    } else if op == 49 {
      // One round of the loop body at depth b ended, so the cells of the locals
      // declared in THAT body are stale: PUC closes them at the end of the block
      // and the next round makes new ones.  A counter per depth rather than one
      // for the chip, so a nested body's exit cannot close its parent's cells.
      upGen[b] = upGen[b] + 1
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
        vSetN(a, 5, tCount + 0.0)
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
            vSetNil(a)
          }
        } else {
          vSetNil(a)
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
        vSetNil(a)
      } else {
        let r = tmap.get(tkey(toInt(vNum(b)), kt, vNum(c), vStr(c)))
        if r.Found {
          vSet(a, tvTag[r.Value], tvNum[r.Value], tvStr[r.Value])
        } else {
          vSetNil(a)
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
        vSetN(a, 6, tLen[toInt(vNum(b))] + 0.0)
      } else if bt == 2 {
        vSetN(a, 6, vStr(b).Length() + 0.0)
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
    } else if op == 39 || op == 40 {
      let lt = vTag(b)
      let rt = vTag(c)
      bitFail(lt, vNum(b), rt, vNum(c))
      // A shift by a NEGATIVE count REVERSES DIRECTION -- Lua 5.3 manual 3.4 --
      // so `1000 << -5` is `1000 >> 5` and not a scale by 2^-5.  Computing
      // `2 ** n` straight off got that wrong: a negative n scaled by a
      // fraction, so `1000 << -5` was 31.25 and a match LENGTH came out
      // fractional.  bitwise.lua:68 is the assert that found it, reachable only
      // once the harvest stopped reading `not` as a captured variable.
      //
      // Both directions are ONE arm because they are one expression with the
      // direction chosen: `shl` is the opcode's own direction, flipped when the
      // count is negative.  As two arms with a helper mod each was 49 nodes,
      // because a MOD INLINES at its call site and this has two of them.
      let n0 = vNum(c)
      let n = if n0 < 0 then 0.0 - n0 else n0
      // A left count of 64 or more shifts every bit out, so PUC answers 0
      // rather than scaling into floats it cannot hold: `~(-1 << 64)` is -1
      // through here, and %u prints all twenty digits of it.  The boundary
      // is 64, not 63: `1 << 63` is still mininteger.  Right counts need no
      // arm of their own: 2^n overflows to +inf past 2^1024 (long past 64),
      // so the quotient below is already 0 there.
      if (n0 < 0) == (op == 40) {
        vSetInt(a, vNum(b) * (if n >= 64.0 then 0.0 else 2.0 ** n))
      } else {
        // A right shift has to FLOOR, and this arm used floor() believing it
        // did: the host's floor() TRUNCATES toward zero (see the note by it), so
        // floor(-0.5) is 0 and not -1, and `-8 >> 4` came out 0.  Every earlier
        // shift test passed because their quotients happened to be integral.
        //
        // This is op 34's `//` floor, verbatim -- truncate toward zero with the
        // bitwise `| 0`, then step down when a negative quotient was not exact.
        // Reusing the idiom rather than a new helper because a MOD INLINES, and
        // this is the second copy of these four lines either way.
        let q = vNum(b) / (2.0 ** n)
        let t = q | 0
        vSetInt(a, if q < 0.0 && q != t + 0.0 then t - 1 else t)
      }
    } else if op == 0 {
      vmHalted = true
      advanced = true
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
// A CHIP: vmBurst calls this four times, so as a mod the body existed four
// times over (1,173 nodes each, 4,692 = 13% of the chip) purely to be four
// call sites.  As a chip it is one body with four call sites, and a chip costs
// no ticks per run -- so this is nodes removed with the tick count unchanged.
chip vmStepFast() {
  if vmHalted || vmBusy() {
    return
  }
  let op = bop[vmPc]
  let a = bpa[vmPc]
  let b = bpb[vmPc]
  let c = bpc[vmPc]
  var advanced = false
  // HALT is the LAST arm, not the first, and it is worth saying why: docs/vm-isa
  // records it as "handled defensively; the compiler normally ends with RETURN0",
  // so it runs at most once per program -- while in first position its failed
  // comparison is paid by EVERY instruction the step ever dispatches.  A chain
  // arm costs a comparison per instruction for every instruction above it, which
  // is why FORLOOP was moved into this mod for position alone.
  if op == 1 {
    vSetNil(a)
  } else if op == 2 {
    if c == 1 {
      vSetIntSat(a, constNum[b])
    } else {
      vSetNum(a, constNum[b])
    }
  } else if op == 3 {
    vSet(a, 2, 0.0, constStr[b])
  } else if op == 4 {
    vSetN(a, 3, if b == 0 then 0.0 else 1.0)
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
        // the other copy of the pow arm; both go through powSignedZero so the rule
        // about a negative zero base has one body, because a fix that reached only
        // one of the two is invisible from a program that runs the other
        vSetNum(a, powSignedZero(x, y))
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
    vSetN(a, 3, if truthyOf(vTag(b), vNum(b)) then 0.0 else 1.0)
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
        vSetN(a, 3, if vNum(b) == rv then 1.0 else 0.0)
      } else if lt != rt {
        vSetN(a, 3, 0.0)
      } else if lt == 2 {
        vSetN(a, 3, if vStr(b) == vStr(c) then 1.0 else 0.0)
      } else if lt == 0 {
        vSetN(a, 3, 1.0)
      } else {
        // as vmStep's == arm above: lt == 1 cannot reach here (ln covers it),
        // and tags 3, 4 and 5 all compare by number
        vSetN(a, 3, if vNum(b) == rv then 1.0 else 0.0)
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
        vSetN(a, 3, if hit then 1.0 else 0.0)
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
          vSetNil(a)
        }
      } else {
        vSetNil(a)
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
      vSetNil(a)
    } else {
      let r = tmap.get(tkey(toInt(vNum(b)), kt, vNum(c), vStr(c)))
      if r.Found {
        vSet(a, tvTag[r.Value], tvNum[r.Value], tvStr[r.Value])
      } else {
        vSetNil(a)
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
  } else if op == 43 {
    // ADJUST a=src b=dst c=max: normalise the rest of the last call's results
    // into c consecutive registers.  `a` already points past the first value
    // (the caller consumed it), so only retCountV-1 values remain to copy.
    let avail = if 0 < retCountV then retCountV - 1 else 0
    let n = if avail < c then avail else c
    retAdjust(vmBase + a, vmBase + b, n, c)
  } else if op == 0 {
    vmHalted = true
    advanced = true
  }
  // The same set as `op <= 15 || (17 <= op && op <= 22) || op == 24 || op == 33
  // || op == 50`, written so it costs five comparisons instead of six: 0..15 and
  // 17..22 together are exactly "at most 22 and not 16".  A comparison is one
  // gate and this runs on every fast dispatch, four of them to a tick, so one
  // fewer term is four fewer gates a tick.
  //
  // The parentheses round the WHOLE set, not just its first term: `||` binds
  // looser than `&&`, so an unbracketed tail would bind only the last term and
  // leave `!advanced` guarding nothing but it.
  if ((op <= 22 && op != 16) || op == 24 || op == 33 || op == 50 || op == 29 || op == 30 || op == 43)
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
  } else if !run {
    // Stopped means no outputs: the falling edge clears the result ports, so a
    // halted chip never shows a previous run's values as if they were live.
    // Log, error and parse state stay -- history must survive a stop, and the
    // next rising edge restarts through vmReset anyway.
    oF0 = 0.0
    oF1 = 0.0
    oF2 = 0.0
    oF3 = 0.0
    oS4 = ""
    oS5 = ""
    outNumArrV.clear()
    outNumArrV.resize(ARR_SLOTS, 0.0)
    outStrArrV.clear()
    outStrArrV.resize(ARR_SLOTS, "")
    resultV = ""
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
  // The five dynamic-index flags, each searched for ONCE.  They are the run-time
  // reachability answer for a library table, and they are computed here rather than
  // inside each gate so a table with six pieces pays for one search and not six.
  let dynTab = libTabDyn(program)
  let dynMath = libMathDyn(program)
  let dynIo = libIoDyn(program)
  let dynOs = libOsDyn(program)
  let dynBit32 = libBit32Dyn(program)
  let dynUtf8 = libUtf8Dyn(program)
  let dynStr = libStrDyn(program)
  let libB = libStrIndex(program, dynStr)
  let libB2 = libStrByte(program, dynStr)
  let libB3 = libStrChar(program, dynStr)
  let libC = libStrCase(program, dynStr)
  let libD = libStrMisc(program, dynStr)
  let libE = libMathConst(program, dynMath)
  let libF = libMathInt(program, dynMath)
  let libG = libMathTrig(program, dynMath)
  let libH = libMathExp(program, dynMath)
  let libI = libMathMaxMin(program, dynMath)
  let libI2 = libMathFmodModf(program, dynMath)
  let libJ = libTabInsert(program, dynTab)
  let libJ2 = libTabRemove(program, dynTab)
  let libK = libTabUnpack(program, dynTab)
  let libK2 = libTabPack(program, dynTab)
  let libL = libTabConcat(program, dynTab)
  let libM = libTabSort(program, dynTab)
  let libN = libStrFmt(program, dynStr)
  let libO = libIo(program, dynIo)
  let libO2 = libOs(program, dynOs)
  let libO3 = libBit32(program, dynBit32)
  let libO4 = libUtf8(program, dynUtf8)
  let libO5 = libUtf8Char(program, dynUtf8)
  let libP = libStrPat(program, dynStr)
  let libQ = libStrGsub(program, dynStr)
  let libR = libStrGmatch(program, dynStr)
  // The hex piece comes BEFORE the one that calls it: _tonum_hex is a chunk-local
  // and `tonumber = function(...)` closes over it, so the other order leaves the
  // reference resolving to a global that is nil -- "attempt to call" on the one
  // path the split exists for.
  let libS2 = libTonumberHex(program)
  let libS3 = libTonumberBase(program)
  let libS = libTonumber(program)
  let libT = libMathRandom(program, dynMath)
  let libU = libRaw(program)
  let lib = libA .. libB .. libB2 .. libB3 .. libC .. libD .. libE .. libF .. libG
    .. libH .. libI .. libI2 .. libJ .. libJ2 .. libK .. libK2 .. libL .. libM .. libN
    .. libO .. libO2 .. libO3 .. libO4 .. libO5 .. libP
    .. libQ .. libR .. libS2 .. libS3 .. libS .. libT .. libU
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
  // rawget/rawset/rawequal/rawlen are NOT listed here: the chip loads them as
  // LIB_raw, so a program naming one gets the function, not this warning.
  if srcUses(p, "setmetatable") || srcUsesField(p, "setmetatable")
    || srcUses(p, "getmetatable") || srcUsesField(p, "metatable") {
    h = h .. "warn: no metatables: setmetatable/getmetatable are absent\n"
  }
  if srcUses(p, "coroutine") {
    h = h .. "warn: no coroutines\n"
  }
  if srcUses(p, "require") || srcUses(p, "module") || srcUses(p, "dofile")
    || srcUses(p, "loadfile") || srcUses(p, "loadstring") || srcUses(p, "package") {
    h = h .. "warn: no modules or file loading: require/module/dofile/loadfile/loadstring are absent\n"
  }
  // No port or library lines here on purpose.  There were four: no-int-port,
  // no-vector-port, no-colour-port and no-io/os/debug/utf8-library, all built
  // on srcUsesField -- which checks "string.<name>" and ":<name>", so none of
  // them ever fired for real port or library use, and all of them fired for a
  // user method spelled ":<name>".  Bare reads are named precisely by
  // noteUnknown, missing library members by noteLibField, and that is the
  // whole of the port/library advice now.
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
//    globals (mirrored to their ports once per tick); innumarr/outnumarr bridge 1-based
//    float arrays.
// 18. Number/string ports renamed by type: inNum0..inNum3, inStr0..inStr1,
//    outNum0..outNum3, outStr0..outStr1.
// 15. Compile failures report "line N: message" in err (token lines ride a parallel array,
//    lexer errors carry their own line).
// 16. Duplicate targets in one assignment store right to left (a, a = 1, 2 leaves 1).
// 17. Table constructors accept [k] = v with any key expression.
// 19. Function ids 6 and 7 were taken by innumarr/outnumarr but parseJobStart still reserved only six
//    builtin slots, so the first two user functions (and the main chunk) collided with them:
//    any program defining a function printed nothing or failed with "array index out of range".
//    It now reserves eight slots.
