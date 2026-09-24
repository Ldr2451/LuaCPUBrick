/// Lua 5.5 in WireScript: a parser, a register VM, and the standard library,
/// on one chip.
///
/// Wire a Lua program into `program` (a string variable gate) and drive `run` high.
/// The program is lexed, parsed to flat bytecode, then executed on a register VM.
/// Numbers go in through inNum0..inNum3, strings through inStr0..inStr1, a vector through inVec,
/// a color through inCol and a float array through inArr. Printed values accumulate
/// in the log; outNum0..outNum3, outStr0..outStr1, outArr, outVec and outCol
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
///   in  inVec: vector     Lua reads invecx / invecy / invecz
///   in  inCol: color      Lua reads incolr / incolg / incolb / incola
///   in  inArr: float[]    Lua reads it 1-based via inarr(i); out-of-range reads nil
///   out log: string       print output: one line per call (args tab-separated plus
///                         a newline); the last 32 lines are kept, each capped at
///                         64 chars; cleared on restart
///   out outNum0..outNum3: float  writable numeric globals (nil writes 0.0;
///                         writing a string/table/function is a runtime error)
///   out outStr0..outStr1: string  writable globals, Lua-formatted (nil writes "")
///   out outArr: float[] 64 slots, written 1-based via outarr(i, v) (nil writes 0.0)
///   out outVec: vector    written by setvec(x, y, z)
///   out outCol: color     written by setcol(r, g, b, a)
///   out result: string    top-level return value, "" when none
///   out err: string       runtime error text, "" when none; compile failures read
///                         "line N: message"
///   out progOk: bool      false when the program did not compile
///   out busy: bool        true while lexing, parsing, or executing with run high
///   A change on any scalar input while `run` is high restarts the program with the new
///   value. inArr is read live by inarr() (no restart needed). Changing an input while
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
///   library    the source of pairs, ipairs, next, select, string.*, math.* and
///              table.* is Lua text prepended to the program when the program mentions
///              it, so it is ordinary Lua running on this chip; the only gates are
///              what Lua cannot express (string byte/char/upper/lower/sub, the math
///              functions, table.unpack, next)
///   numbers    integers (exact on-chip inside +/-2^53; Lua wraps 64-bit beyond that)
///              and floats: 0.5 .5 5. 1e3 1E-3, hex ints 0xFF. / and ^ always return
///              floats. Ints print bare (3), floats print Lua-style (3.0); 'x' .. 1
///              gives "x1", #t prints like 3
///   strings    "..." and '...' with \n \r \t \\ \" \' \<newline>, \z, \ddd and \xXX
///              for printable ASCII (32..126); other escapes are a compile error
///   compare    == and ~= work on all types without coercion (tables by identity);
///              < > <= >= work on numbers or lexicographically on strings;
///              arithmetic never coerces strings
///   divzero    x/0, x%0 and 0/0 yield 0 (Brickadia gate behavior, unlike Lua inf/nan)
///
/// Not implemented yet (each is a loud error, never a wrong answer)
///   closures / upvalues      a function cannot read a local of an enclosing scope,
///                             so it cannot call a local function of one
///   metatables               no setmetatable, no __index, no operator metamethods
///   string patterns          no find, match, gmatch, gsub, string.format
///   error handling           no error, assert, pcall, xpcall: a runtime error
///                             halts with err set
///   goto and labels          a compile error
///   coroutines, modules, bitwise operators
///   integers as a type       one number type: math.type reports "integer" for a
///                             whole number, 1 == 1.0, and 64-bit wraparound is
///                             absent beyond 2^53
///   non-integer number keys  a runtime error on write, nil on read
///
/// Other differences from PUC-Lua 5.5
///   tostring of a table is "table" (PUC prints an address). t[nil] reads nil (PUC
///   errors). outNum0..outNum3 only take numbers/booleans/nil and outArr only
///   numbers (PUC tables take anything; fixed-size float storage is a gate
///   limitation). The log keeps the last 32 lines at 64 chars each (about 2 KB).
///
/// Limits (compile error past them, progOk = false)
///   1024 tokens, 512 bytecode instructions, 64 registers per function, 32 functions,
///   64 globals (27 pre-registered), 256 numeric and 256 string constants, 16 call
///   arguments, 32 nested calls. At run time: 64 tables and 512 table entries in total.
///
/// Speed and gate count
///   Everything is unrolled per tick, so gates buy speed. Approximate cost of one extra
///   copy: vmStep 2.5k gates, parseStep 6k, lexStep 1k.
///   Execution   vmBurst() = 4 vmStep() calls, fired by the Clock at STEP_INTERVAL
///               (0.01 s, so at most once per tick): up to about 240 VM instructions per
///               second at 60 ticks per second. Whether the game really fires the Clock
///               that fast has not been measured; time a loop with clock() to check.
///               Rough sizes: an 8 element bubble sort is ~740 instructions, 16 elements
///               ~2600, 32 elements ~9400.
///   Parsing     lexChunk() = 4 characters per tick, parseChunk() = 2 parser steps per
///               tick. A few hundred characters take a few seconds. Add or remove calls in
///               lexChunk / parseChunk / vmBurst to trade gates for speed.
///
/// Verification: differential tests against real Lua 5.4 (about 190 hand-written programs
/// plus a 200-seed random differential fuzz, all matching apart from the documented
/// differences), structural model<->chip consistency checks (builtin ids, global slots,
/// limits, ports, opcode and keyword coverage, re-parse/restart clearing), and simulated
/// handler tests for run, the log, inarr/outarr, outNum/outStr and error reporting.
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
@left in inVec: vector
@left in inCol: color
@left in inArr: float[]
@left in inInt0: int

@right out log: string = logV.Value
@right out outNum0: float = oF0.Value
@right out outNum1: float = oF1.Value
@right out outNum2: float = oF2.Value
@right out outNum3: float = oF3.Value
@right out outInt0: int = oI0.Value
@right out outStr0: string = oS4.Value
@right out outStr1: string = oS5.Value
@right out outArr: float[] = outArrV
@right out outVec: vector = outVecV.Value
@right out outCol: color = outColV.Value
@right out result: string = resultV.Value
@right out err: string = errV.Value
@right out progOk: bool = progOkV.Value
@right out busy: bool = jobBusy || (run && progOkV && !vmHalted)

// ---------------------------------------------------------------- tunables

const STEP_INTERVAL = 0.01
const MAX_INSTR = 1024
// the prepended library plus a full program; the token arrays are sized from
// this, so raising it costs gates (see tools/gatecount.py)
const MAX_TOKENS = 4096
const MAX_REGS = 64
// function slots: the reserved builtins, the prepended library, and the
// program's own functions.  The arrays grow on demand, so this is a bound, not
// a size.
const MAX_FUNCS = 96
const MAX_GLOBALS = 64
const MAX_CALLS = 32
const MAX_TABLES = 64
const MAX_HEAP = 512
// live vararg values across all active frames
const MAX_VA = 256
// most values one call/return/statement can carry (matches MAX_INSTR-style
// unrolling in retAdjust and the return paths)
const MAXVALS = 16

// Gate builtins live in function slots 0..NB-1; a program's own functions start
// at NB.  Each one is a case in the vmStep call dispatch, so adding a builtin
// means: extend this, declare its global, extend GTAG_INIT/GNUM_INIT, and add
// the dispatch case.  test_ws_consistency.py checks all four line up.
const NB = 14

// Library sources, prepended on demand (see libIter and friends).  These are
// ordinary Lua: the parser sees them exactly like the user's program.  They are
// split per family because lexing them is the cost -- a program that names one
// string function pays for one family, not for all eight.
// Library functions are written as field assignments, not `function string.f`:
// the parser does not take a dotted name on `function` yet.
const LIB_iter = "function _ipairs_iter(t, i) i = i + 1 local v = t[i] if v ~= nil then return i, v end end\nfunction ipairs(t) return _ipairs_iter, t, 0 end\nfunction pairs(t) return next, t, nil end\n"
const LIB_str_index = "string = string or {}\nstring.len = function(s) return #s end\nstring.sub = function(s, i, j)\n  local l = #s\n  i = i or 1\n  j = j or -1\n  if i < 0 then i = l + i + 1 if i < 1 then i = 1 end elseif i == 0 then i = 1 end\n  if j < 0 then j = l + j + 1 elseif j > l then j = l end\n  if i > j then return \"\" end\n  return _s(1, s, i - 1, j - i + 1)\nend\nstring.byte = function(s, i, j)\n  i = i or 1\n  j = j or i\n  if i < 0 then i = #s + i + 1 end\n  if j < 0 then j = #s + j + 1 end\n  if i < 1 then i = 1 end\n  if j > #s then j = #s end\n  if i > j then return end\n  if i == j then return _s(4, s, i - 1, 0) end\n  return _s(4, s, i - 1, 0), string.byte(s, i + 1, j)\nend\nstring.char = function(...)\n  local r = \"\"\n  for i = 1, select('#', ...) do r = r .. _s(5, \"\", select(i, ...), 0) end\n  return r\nend\n"
const LIB_str_fmt = "string = string or {}\nstring.format = _fmt\n"
const LIB_str_case = "string = string or {}\nstring.upper = function(s) return _s(2, s) end\nstring.lower = function(s) return _s(3, s) end\n"
const LIB_str_misc = "string = string or {}\nstring.rep = function(s, n, sep)\n  if n <= 0 then return \"\" end\n  sep = sep or \"\"\n  local r = s\n  for i = 2, n do r = r .. sep .. s end\n  return r\nend\nstring.reverse = function(s)\n  local r = \"\"\n  for i = #s, 1, -1 do r = r .. _s(1, s, i - 1, 1) end\n  return r\nend\n"
const LIB_math_const = "math = math or {}\nmath.pi = 3.141592653589793\nmath.huge = 1.7976931348623157e308\nmath.maxinteger = 9223372036854775807\nmath.mininteger = -9223372036854775807 - 1\n"
const LIB_math_int = "math = math or {}\nmath.floor = function(x) return _m(1, x, 0) end\nmath.ceil = function(x) return _m(2, x, 0) end\nmath.tointeger = function(x) return _m(13, x, 0) end\nmath.type = function(x) return _m(14, x, 0) end\nmath.abs = function(x) if x < 0 then return -x end return x end\nmath.sqrt = function(x) return _m(3, x, 0) end\n"
const LIB_math_trig = "math = math or {}\nmath.sin = function(x) return _m(4, x, 0) end\nmath.cos = function(x) return _m(5, x, 0) end\nmath.tan = function(x) return _m(6, x, 0) end\nmath.asin = function(x) return _m(7, x, 0) end\nmath.acos = function(x) return _m(8, x, 0) end\nmath.atan = function(y, x) return _m(9, y, x or 1) end\n"
const LIB_math_exp = "math = math or {}\nmath.exp = function(x) return _m(10, x, 0) end\nmath.log = function(x, b)\n  if b == nil then return _m(11, x, 0) end\n  if b == 10 then return _m(12, x, 0) end\n  return _m(11, x, 0) / _m(11, b, 0)\nend\n"
const LIB_math_misc = "math = math or {}\nmath.max = function(a, ...)\n  local m = a\n  for i = 1, select('#', ...) do local v = select(i, ...) if v > m then m = v end end\n  return m\nend\nmath.min = function(a, ...)\n  local m = a\n  for i = 1, select('#', ...) do local v = select(i, ...) if v < m then m = v end end\n  return m\nend\nmath.fmod = function(a, b)\n  local r = a % b\n  if r ~= 0 and (a < 0) ~= (b < 0) then r = r - b end\n  return r\nend\nmath.modf = function(x) local i = (x >= 0 and _m(1, x, 0)) or _m(2, x, 0) return i + 0.0, x - i end\n"
const LIB_tab_ins = "table = table or {}\ntable.insert = function(t, ...)\n  local n = #t\n  local c = select('#', ...)\n  if c == 1 then\n    t[n + 1] = (...)\n  elseif c == 2 then\n    local pos, v = ...\n    for i = n, pos, -1 do t[i + 1] = t[i] end\n    t[pos] = v\n  end\nend\ntable.remove = function(t, pos)\n  local n = #t\n  if pos == nil then pos = n end\n  local v = t[pos]\n  for i = pos, n - 1 do t[i] = t[i + 1] end\n  t[n] = nil\n  return v\nend\n"
const LIB_tab_list = "table = table or {}\ntable.unpack = unpack\ntable.pack = function(...) local t = {...} t.n = select('#', ...) return t end\ntable.move = function(a1, f, e, t, a2)\n  a2 = a2 or a1\n  if e >= f then\n    if t > e or t <= f or a1 ~= a2 then\n      for i = 0, e - f do a2[t + i] = a1[f + i] end\n    else\n      for i = e - f, 0, -1 do a2[t + i] = a1[f + i] end\n    end\n  end\n  return a2\nend\n"
const LIB_tab_concat = "table = table or {}\ntable.concat = function(t, sep, i, j)\n  sep = sep or \"\"\n  i = i or 1\n  j = j or #t\n  local r = \"\"\n  for k = i, j do\n    local v = t[k]\n    if k > i then r = r .. sep end\n    r = r .. v\n  end\n  return r\nend\n"
const LIB_tab_sort = "table = table or {}\n_lt = function(a, b) return a < b end\ntable.sort = function(t, cmp)\n  local lt = cmp or _lt\n  for i = 2, #t do\n    local v = t[i]\n    local j = i - 1\n    while j >= 1 and lt(v, t[j]) do t[j + 1] = t[j] j = j - 1 end\n    t[j + 1] = v\n  end\nend\n"

// ---------------------------------------------------------------- state: outputs + status

var logV: string = ""
var logLines: string[]
var oF0: float = 0.0
var oF1: float = 0.0
var oF2: float = 0.0
var oF3: float = 0.0
var oI0: int = 0
var oS4: string = ""
var oS5: string = ""
var outArrV: float[]
var outVecV: vector = Vec(0.0, 0.0, 0.0)
var outColV: color = Color(0.0, 0.0, 0.0, 0.0)
var resultV: string = ""
var errV: string = ""
var progOkV: bool = false

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
    else if v == floor(v) && abs(v) < 1e15 then ("" .. (v | 0)) .. ".0"
    else "" .. v
}

mod fmtVal(tag: int, num: float, s: string) -> string {
  return if tag == 0 then "nil"
    else if tag == 3 then if num == 0.0 then "false" else "true"
    else if tag == 2 then s
    else if tag == 4 then "function"
    else if tag == 5 then "table"
    else if tag == 6 then "" .. (num | 0)
    else fmtNum(num)
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
var lescHex: string = ""

var tk: int[]
var ts: int[]
var tn: float[]
var tt: string[]
var tl: int[]

mod lexFail(msg: string) {
  lerr = true
  lerrMsg = msg
  lerrLine = lline
}

// printable ASCII table for \ddd / \xXX escapes (32..126 only)
const PRINTABLES = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"

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

mod hexVal(cp: int) -> int {
  return if cp >= 48 && cp <= 57 then cp - 48
    else if cp >= 97 && cp <= 102 then cp - 87
    else if cp >= 65 && cp <= 70 then cp - 55
    else -1
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

mod closerFor(level: int) -> string {
  return if level == 0 then "]]" else if level == 1 then "]=]" else if level == 2 then "]==]"
    else if level == 3 then "]===]" else if level == 4 then "]====]" else "]=====]"
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

mod emitEscByte(v: int) {
  if v >= 32 && v <= 126 {
    lidBuf = lidBuf .. PRINTABLES.Substring(v - 32, 1)
  } else {
    lexFail("bad escape")
  }
}

mod lexStep() {
  if lstage != 99 && !lerr {
    let cp = if lpos < llen then lsrc.Substring(lpos, 1).ToCharCode().Codepoint else 0
    let ch = lsrc.Substring(lpos, 1)
    let cp2 = if lpos + 1 < llen then lsrc.Substring(lpos + 1, 1).ToCharCode().Codepoint else 0
    let cp3 = if lpos + 2 < llen then lsrc.Substring(lpos + 2, 1).ToCharCode().Codepoint else 0
    let isDigit = cp >= 48 && cp <= 57
    let isAlpha = (cp >= 65 && cp <= 90) || (cp >= 97 && cp <= 122) || cp == 95
    let isAlNum = isAlpha || isDigit
    if lstage == 10 {
      // line comment: skip to newline or end
      if lpos >= llen {
        lstage = 99
      } else if cp == 10 || cp == 13 {
        if cp == 10 {
          lline = lline + 1
        }
        lstage = 0
        lpos = lpos + 1
      } else {
        lpos = lpos + 1
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
        lstrDelim = ch
        lidBuf = ""
        lstage = 4
        lpos = lpos + 1
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
var perr: bool = false
var perrMsg: string = ""
var pMode: int = 0
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
var slotOutLatch: int = 0
var slotInLatch: int = 0
var slotInInt0: int = 0
var slotOutInt0: int = 0
var fnDepth: int = 0
var cfNext: int[]
var cfMax: int[]
var cfBase: int[]
var cfMaxLoc: int[]
var locName: string[]
var locReg: int[]
var locDepth: int[]
var locLen: int = 0
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
var popLeft: bool = true
var pendKind: int = -1
var pendPrec: int = 0
var pendLeft: bool = true
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

mod popFlag() -> bool {
  let had = valCall.length() > 0
  let v = valCall.pop().Value
  return had && v
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
    perrMsg = "program too long"
  }
  return bop.length() - 1
}

var lastPatchTarget: int = -1
// Position of the most recently emitted CALL whose result count is still
// undecided.  Lua only expands a call's results when the call sits in the LAST
// argument position of an enclosing call (or feeds a fixed-arity target list),
// and that is not known when the call itself closes: `f()` ends before the
// enclosing `print(...)` does.  So record the call, then patch its C operand to
// 1 once we learn it was in tail position.
var lastCallPos: int = -1
// Position of the CALL that produced the value currently in presReg, or -1 if
// that value is not a call.  It outlives lastCallPos (which only tracks the
// most recent emission) so the consumers of a finished value â€” `return f()`,
// a target list, a constructor's last element â€” can still mark the call as
// returning all of its results.
var presCallPos: int = -1


mod bPatch(pos: int, target: int) {
  bpa[pos] = target
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

mod gLookup(name: string) -> int {
  let r = gmap.get(name)
  return if r.Found then r.Value else -1
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
  valStk.clear()
  valCall.clear()
  valPrefix.clear()
  opKind.clear()
  opPrec.clear()
  opA.clear()
  opB.clear()
  opC.clear()
  forCtrl.clear()
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
  gDeclare("outNum0")
  gDeclare("outNum1")
  gDeclare("outNum2")
  gDeclare("outNum3")
  gDeclare("outStr0")
  gDeclare("outStr1")
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
  gDeclare("invecx")
  gDeclare("invecy")
  gDeclare("invecz")
  gDeclare("incolr")
  gDeclare("incolg")
  gDeclare("incolb")
  gDeclare("incola")
  gDeclare("print")
  gDeclare("type")
  gDeclare("tostring")
  gDeclare("setvec")
  gDeclare("setcol")
  gDeclare("clock")
  gDeclare("inarr")
  gDeclare("outarr")
  gDeclare("select")
  gDeclare("next")
  gDeclare("_s")
  gDeclare("_m")
  gDeclare("unpack")
  gDeclare("_fmt")
  gDeclare("inInt0")
  gDeclare("outInt0")
  // The runtime wires the latches and outputs straight into these slots, so
  // take the numbers from the declarations instead of repeating them: adding a
  // builtin used to leave a stale literal behind and overwrite its id.
  slotOutLatch = gLookup("outNum0")
  slotInLatch = gLookup("inNum0")
  slotInInt0 = gLookup("inInt0")
  slotOutInt0 = gLookup("outInt0")
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
  } else {
    locName.push(name)
    locReg.push(r)
    locDepth.push(fnDepth)
  }
  locLen = locLen + 1
  if r > cfMaxLoc[fnDepth] {
    cfMaxLoc[fnDepth] = r
  }
}

mod locDeclare(name: string) -> int {
  let r = regAlloc()
  locBind(name, r)
  return r
}

mod blkEnter() {
  blkLen.push(locLen)
  blkNext.push(cfNext[fnDepth])
}

mod blkExit() {
  locLen = blkLen.pop().Value
  cfNext[fnDepth] = blkNext.pop().Value
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

// lkKind: 0 none, 1 local reg, 2 self-recursion (LOADFUNC lkFid).
// Sets perr on upvalue use.
mod locFind(name: string) {
  lkKind = 0
  lkReg = -1
  lkFid = -1
  lkDone = false
  if !lkRaw && selfName[fnDepth] == name && selfClean[fnDepth] {
    lkKind = 2
    lkFid = selfFid[fnDepth]
    lkDone = true
  }
  if !lkDone {
    let ix0 = locLen - 1 - 0
    if ix0 >= 0 && locName[ix0] == name {
      if locDepth[ix0] == fnDepth {
        lkKind = 1
        lkReg = locReg[ix0]
      } else {
        perr = true
        perrMsg = "upvalues/closures are not supported"
      }
      lkDone = true
    }
  }
  if !lkDone {
    let ix1 = locLen - 1 - 1
    if ix1 >= 0 && locName[ix1] == name {
      if locDepth[ix1] == fnDepth {
        lkKind = 1
        lkReg = locReg[ix1]
      } else {
        perr = true
        perrMsg = "upvalues/closures are not supported"
      }
      lkDone = true
    }
  }
  if !lkDone {
    let ix2 = locLen - 1 - 2
    if ix2 >= 0 && locName[ix2] == name {
      if locDepth[ix2] == fnDepth {
        lkKind = 1
        lkReg = locReg[ix2]
      } else {
        perr = true
        perrMsg = "upvalues/closures are not supported"
      }
      lkDone = true
    }
  }
  if !lkDone {
    let ix3 = locLen - 1 - 3
    if ix3 >= 0 && locName[ix3] == name {
      if locDepth[ix3] == fnDepth {
        lkKind = 1
        lkReg = locReg[ix3]
      } else {
        perr = true
        perrMsg = "upvalues/closures are not supported"
      }
      lkDone = true
    }
  }
  if !lkDone {
    let ix4 = locLen - 1 - 4
    if ix4 >= 0 && locName[ix4] == name {
      if locDepth[ix4] == fnDepth {
        lkKind = 1
        lkReg = locReg[ix4]
      } else {
        perr = true
        perrMsg = "upvalues/closures are not supported"
      }
      lkDone = true
    }
  }
  if !lkDone {
    let ix5 = locLen - 1 - 5
    if ix5 >= 0 && locName[ix5] == name {
      if locDepth[ix5] == fnDepth {
        lkKind = 1
        lkReg = locReg[ix5]
      } else {
        perr = true
        perrMsg = "upvalues/closures are not supported"
      }
      lkDone = true
    }
  }
  if !lkDone {
    let ix6 = locLen - 1 - 6
    if ix6 >= 0 && locName[ix6] == name {
      if locDepth[ix6] == fnDepth {
        lkKind = 1
        lkReg = locReg[ix6]
      } else {
        perr = true
        perrMsg = "upvalues/closures are not supported"
      }
      lkDone = true
    }
  }
  if !lkDone {
    let ix7 = locLen - 1 - 7
    if ix7 >= 0 && locName[ix7] == name {
      if locDepth[ix7] == fnDepth {
        lkKind = 1
        lkReg = locReg[ix7]
      } else {
        perr = true
        perrMsg = "upvalues/closures are not supported"
      }
      lkDone = true
    }
  }
  if !lkDone {
    let ix8 = locLen - 1 - 8
    if ix8 >= 0 && locName[ix8] == name {
      if locDepth[ix8] == fnDepth {
        lkKind = 1
        lkReg = locReg[ix8]
      } else {
        perr = true
        perrMsg = "upvalues/closures are not supported"
      }
      lkDone = true
    }
  }
  if !lkDone {
    let ix9 = locLen - 1 - 9
    if ix9 >= 0 && locName[ix9] == name {
      if locDepth[ix9] == fnDepth {
        lkKind = 1
        lkReg = locReg[ix9]
      } else {
        perr = true
        perrMsg = "upvalues/closures are not supported"
      }
      lkDone = true
    }
  }
  if !lkDone {
    let ix10 = locLen - 1 - 10
    if ix10 >= 0 && locName[ix10] == name {
      if locDepth[ix10] == fnDepth {
        lkKind = 1
        lkReg = locReg[ix10]
      } else {
        perr = true
        perrMsg = "upvalues/closures are not supported"
      }
      lkDone = true
    }
  }
  if !lkDone {
    let ix11 = locLen - 1 - 11
    if ix11 >= 0 && locName[ix11] == name {
      if locDepth[ix11] == fnDepth {
        lkKind = 1
        lkReg = locReg[ix11]
      } else {
        perr = true
        perrMsg = "upvalues/closures are not supported"
      }
      lkDone = true
    }
  }
  if !lkDone {
    let ix12 = locLen - 1 - 12
    if ix12 >= 0 && locName[ix12] == name {
      if locDepth[ix12] == fnDepth {
        lkKind = 1
        lkReg = locReg[ix12]
      } else {
        perr = true
        perrMsg = "upvalues/closures are not supported"
      }
      lkDone = true
    }
  }
  if !lkDone {
    let ix13 = locLen - 1 - 13
    if ix13 >= 0 && locName[ix13] == name {
      if locDepth[ix13] == fnDepth {
        lkKind = 1
        lkReg = locReg[ix13]
      } else {
        perr = true
        perrMsg = "upvalues/closures are not supported"
      }
      lkDone = true
    }
  }
  if !lkDone {
    let ix14 = locLen - 1 - 14
    if ix14 >= 0 && locName[ix14] == name {
      if locDepth[ix14] == fnDepth {
        lkKind = 1
        lkReg = locReg[ix14]
      } else {
        perr = true
        perrMsg = "upvalues/closures are not supported"
      }
      lkDone = true
    }
  }
  if !lkDone {
    let ix15 = locLen - 1 - 15
    if ix15 >= 0 && locName[ix15] == name {
      if locDepth[ix15] == fnDepth {
        lkKind = 1
        lkReg = locReg[ix15]
      } else {
        perr = true
        perrMsg = "upvalues/closures are not supported"
      }
      lkDone = true
    }
  }
  if !lkDone {
    let ix16 = locLen - 1 - 16
    if ix16 >= 0 && locName[ix16] == name {
      if locDepth[ix16] == fnDepth {
        lkKind = 1
        lkReg = locReg[ix16]
      } else {
        perr = true
        perrMsg = "upvalues/closures are not supported"
      }
      lkDone = true
    }
  }
  if !lkDone {
    let ix17 = locLen - 1 - 17
    if ix17 >= 0 && locName[ix17] == name {
      if locDepth[ix17] == fnDepth {
        lkKind = 1
        lkReg = locReg[ix17]
      } else {
        perr = true
        perrMsg = "upvalues/closures are not supported"
      }
      lkDone = true
    }
  }
  if !lkDone {
    let ix18 = locLen - 1 - 18
    if ix18 >= 0 && locName[ix18] == name {
      if locDepth[ix18] == fnDepth {
        lkKind = 1
        lkReg = locReg[ix18]
      } else {
        perr = true
        perrMsg = "upvalues/closures are not supported"
      }
      lkDone = true
    }
  }
  if !lkDone {
    let ix19 = locLen - 1 - 19
    if ix19 >= 0 && locName[ix19] == name {
      if locDepth[ix19] == fnDepth {
        lkKind = 1
        lkReg = locReg[ix19]
      } else {
        perr = true
        perrMsg = "upvalues/closures are not supported"
      }
      lkDone = true
    }
  }
  if !lkDone {
    let ix20 = locLen - 1 - 20
    if ix20 >= 0 && locName[ix20] == name {
      if locDepth[ix20] == fnDepth {
        lkKind = 1
        lkReg = locReg[ix20]
      } else {
        perr = true
        perrMsg = "upvalues/closures are not supported"
      }
      lkDone = true
    }
  }
  if !lkDone {
    let ix21 = locLen - 1 - 21
    if ix21 >= 0 && locName[ix21] == name {
      if locDepth[ix21] == fnDepth {
        lkKind = 1
        lkReg = locReg[ix21]
      } else {
        perr = true
        perrMsg = "upvalues/closures are not supported"
      }
      lkDone = true
    }
  }
  if !lkDone {
    let ix22 = locLen - 1 - 22
    if ix22 >= 0 && locName[ix22] == name {
      if locDepth[ix22] == fnDepth {
        lkKind = 1
        lkReg = locReg[ix22]
      } else {
        perr = true
        perrMsg = "upvalues/closures are not supported"
      }
      lkDone = true
    }
  }
  if !lkDone {
    let ix23 = locLen - 1 - 23
    if ix23 >= 0 && locName[ix23] == name {
      if locDepth[ix23] == fnDepth {
        lkKind = 1
        lkReg = locReg[ix23]
      } else {
        perr = true
        perrMsg = "upvalues/closures are not supported"
      }
      lkDone = true
    }
  }
  if !lkDone {
    let ix24 = locLen - 1 - 24
    if ix24 >= 0 && locName[ix24] == name {
      if locDepth[ix24] == fnDepth {
        lkKind = 1
        lkReg = locReg[ix24]
      } else {
        perr = true
        perrMsg = "upvalues/closures are not supported"
      }
      lkDone = true
    }
  }
  if !lkDone {
    let ix25 = locLen - 1 - 25
    if ix25 >= 0 && locName[ix25] == name {
      if locDepth[ix25] == fnDepth {
        lkKind = 1
        lkReg = locReg[ix25]
      } else {
        perr = true
        perrMsg = "upvalues/closures are not supported"
      }
      lkDone = true
    }
  }
  if !lkDone {
    let ix26 = locLen - 1 - 26
    if ix26 >= 0 && locName[ix26] == name {
      if locDepth[ix26] == fnDepth {
        lkKind = 1
        lkReg = locReg[ix26]
      } else {
        perr = true
        perrMsg = "upvalues/closures are not supported"
      }
      lkDone = true
    }
  }
  if !lkDone {
    let ix27 = locLen - 1 - 27
    if ix27 >= 0 && locName[ix27] == name {
      if locDepth[ix27] == fnDepth {
        lkKind = 1
        lkReg = locReg[ix27]
      } else {
        perr = true
        perrMsg = "upvalues/closures are not supported"
      }
      lkDone = true
    }
  }
  if !lkDone {
    let ix28 = locLen - 1 - 28
    if ix28 >= 0 && locName[ix28] == name {
      if locDepth[ix28] == fnDepth {
        lkKind = 1
        lkReg = locReg[ix28]
      } else {
        perr = true
        perrMsg = "upvalues/closures are not supported"
      }
      lkDone = true
    }
  }
  if !lkDone {
    let ix29 = locLen - 1 - 29
    if ix29 >= 0 && locName[ix29] == name {
      if locDepth[ix29] == fnDepth {
        lkKind = 1
        lkReg = locReg[ix29]
      } else {
        perr = true
        perrMsg = "upvalues/closures are not supported"
      }
      lkDone = true
    }
  }
  if !lkDone {
    let ix30 = locLen - 1 - 30
    if ix30 >= 0 && locName[ix30] == name {
      if locDepth[ix30] == fnDepth {
        lkKind = 1
        lkReg = locReg[ix30]
      } else {
        perr = true
        perrMsg = "upvalues/closures are not supported"
      }
      lkDone = true
    }
  }
  if !lkDone {
    let ix31 = locLen - 1 - 31
    if ix31 >= 0 && locName[ix31] == name {
      if locDepth[ix31] == fnDepth {
        lkKind = 1
        lkReg = locReg[ix31]
      } else {
        perr = true
        perrMsg = "upvalues/closures are not supported"
      }
      lkDone = true
    }
  }
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
    bEmit(opc, res, L, R)
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
    let rr = popVal()
    regFree(rr)
    let R = opA[opA.length() - 1]
    let pp = opB[opB.length() - 1]
    opKind.pop()
    opPrec.pop()
    opA.pop()
    opB.pop()
    opC.pop()
    bEmit(7, R, rr, 0)
    bPatch(pp, bop.length())
    pushVal(R, false, false)
  } else {
    perr = true
    perrMsg = "bad pop"
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
  pendLeft = (fl & 1) == 1
  pendSub = opc
  pendAux = fl
  popMode = 1
  popPrec = prec
  popLeft = (fl & 1) == 1
}

// and/or arrival: pops drain first, then the frame goes up with its jump.
mod andOrArrive(isOr: bool) {
  pendKind = if isOr then 5 else 4
  pendPrec = if isOr then 0 else 1
  pendLeft = true
  pendSub = 0
  pendAux = 0
  popMode = 1
  popPrec = if isOr then 0 else 1
  popLeft = true
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

// ---------------------------------------------------------------- codegen helpers

mod exprPushName(callParen: bool, callSugar: bool) {
  let name = curStr()
  locFind(name)
  if callParen || callSugar {
    // the callee goes into a fresh call-frame register
    let fr = regAlloc()
    if lkKind == 2 {
      bEmit(25, fr, lkFid, 0)
    } else if lkKind == 1 {
      bEmit(7, fr, lkReg, 0)
    } else {
      bEmit(5, fr, gDeclare(name), 0)
    }
    if callParen {
      pushOp(2, -1, fr, 0, valStk.length())
      cpos = cpos + 2
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
        bEmit(25, r, lkFid, 0)
      } else {
        bEmit(5, r, gDeclare(name), 0)
      }
      pushVal(r, false, true)
    }
    cpos = cpos + 1
    expectOperand = false
  }
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
        let wasCall = topFlag()
        let arg = popVal()
        bEmit(7, fr + 1 + nargs, arg, 0)
        cfNext[fnDepth] = fr + nargs + 2
        // this argument is the last one of the call being closed, so a call
        // used as that argument expands all of its results
        if wasCall {
          patchMultiTail()
        }
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
    if closeTrig == 1 && (mk == 2 || mk == 9) {
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
    } else if closeTrig == 1 && mk == 6 {
      if valStk.length() == opC[opC.length() - 1] {
        perr = true
        perrMsg = "expected table element"
      } else {
        finishCtorElem(false)
      }
      cpos = cpos + 1
      expectOperand = true
      closeMode = 0
    } else if opKind.length() != 0 {
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
var tmpSStk: string[]
// field name of a `function M.f()` definition, popped when its body closes
var fnKey: string[]
var funcEntryLoc: int[]
var pDone: bool = false

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

mod lstAppendC(pos: int) {
  plNext[pos] = ctlC[ctlC.length() - 1]
  ctlC[ctlC.length() - 1] = pos
}

// Start an expression unit ending in the given continuation.
mod startUnit(cont: int) {
  inExpr = true
  contKind = cont
  expectOperand = true
  exprDone = false
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
  blkEnter()
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

mod forDoHead() {
  cpos = cpos + 1
  blkEnter()
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
      blkEnter()
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
      blkEnter()
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
      blkEnter()
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
    if lkKind == 1 {
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

mod pdDrain() {
  if pdHead == -1 {
    if pdThen == 1 {
      ctlLoop = tmpC
    }
    pdThen = 0
  } else {
    bPatch(pdHead, bop.length())
    pdHead = plNext[pdHead]
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
    blkEnter()
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
        if lkKind == 1 {
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
    blkEnter()
  } else if k == 4 && s == 3 {
    cpos = cpos + 1
    blkEnter()
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
      startUnit(13)
    }
  } else if k == 4 && (s == 6 || s == 4 || s == 5) {
    doBlockClose()
  } else {
    perr = true
    perrMsg = "unexpected token at statement start"
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
// One micro-step per burst.  vmBurst calls vmStep four times, so the whole VM
// body -- and this state machine with it -- is inlined four times and entered up
// to four times in one tick.  Extra hops are harmless for next()'s walk but not
// for a state machine: each inlined copy reads the state the earlier copies wrote
// in an order the graph does not define, and the walk takes a wrong branch (the
// spec's conversion character came out as a literal).  vmBurst raises this, the
// first copy consumes it.
var fmtGo: bool = false
var lenChase: bool = false
var lenTid: int = 0
var latchN0: float = 0.0
var latchN1: float = 0.0
var latchN2: float = 0.0
var latchN3: float = 0.0
var latchS0: string = ""
var latchS1: string = ""
var latchVX: float = 0.0
var latchVY: float = 0.0
var latchVZ: float = 0.0
var latchCR: float = 0.0
var latchCG: float = 0.0
var latchCB: float = 0.0
var latchCA: float = 0.0
var latchI0: int = 0
var forDepth: int = 0
var forCtrl: int[]

mod vTag(r: int) -> int {
  return vtag[vmBase + r]
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

// Pre-registered globals: 0..3 outNum0..outNum3 (numbers), 4..5 outStr0..outStr1,
// 6..9 inNum0..inNum3, 10..11 inStr0..inStr1, 12..14 invec x/y/z, 15..18 incol r/g/b/a
// (inputs filled from the latches), 19..31 builtins (print, type, tostring,
// setvec, setcol, clock, inarr, outarr, select, next, _s, _m, unpack, _fmt) as
// functions with ids 0..NB-1, then the two int globals.
var GTAG_INIT: int[] = [1, 1, 1, 1, 2, 2, 1, 1, 1, 1, 2, 2, 1, 1, 1, 1, 1, 1, 1, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6]
var GNUM_INIT: float[] = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 0.0, 0.0]

mod vmReset() {
  tmap.clear()
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
  tCount = 0
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
  forDepth = 0
  fFunc.clear()
  fBase.clear()
  fRetA.clear()
  fRetBase.clear()
  fRetPC.clear()
  fRetN.clear()
  fVaB.clear()
  vaTag.clear()
  vaNum.clear()
  vaStr.clear()
  vaTag.resize(MAX_VA, 0)
  vaNum.resize(MAX_VA, 0.0)
  vaStr.resize(MAX_VA, "")
  vaTop = 0
  gtag.clear()
  gnum.clear()
  gstr.clear()
  gtag.resize(64, 0)
  gnum.resize(64, 0.0)
  gstr.resize(64, "")
  gtag.copyFrom(GTAG_INIT)
  gnum.copyFrom(GNUM_INIT)
  gtag.resize(64, 0)
  gnum.resize(64, 0.0)
  gnum[slotInLatch + 0] = latchN0
  gnum[slotInLatch + 1] = latchN1
  gnum[slotInLatch + 2] = latchN2
  gnum[slotInLatch + 3] = latchN3
  gstr[slotInLatch + 4] = latchS0
  gstr[slotInLatch + 5] = latchS1
  gnum[slotInLatch + 6] = latchVX
  gnum[slotInLatch + 7] = latchVY
  gnum[slotInLatch + 8] = latchVZ
  gnum[slotInLatch + 9] = latchCR
  gnum[slotInLatch + 10] = latchCG
  gnum[slotInLatch + 11] = latchCB
  gnum[slotInLatch + 12] = latchCA
  gnum[slotInInt0] = latchI0 + 0.0
  vmPc = 0
  vmBase = 0
  vmHalted = bop.length() == 0
  vmFailed = false
  retCountV = -1
  cmpActive = false
  logV = ""
  logLines.clear()
  oF0 = 0.0
  oF1 = 0.0
  oF2 = 0.0
  oF3 = 0.0
  oI0 = 0
  oS4 = ""
  oS5 = ""
  outArrV.clear()
  outArrV.resize(64, 0.0)
  outVecV = Vec(0.0, 0.0, 0.0)
  outColV = Color(0.0, 0.0, 0.0, 0.0)
  resultV = ""
  errV = ""
  fFunc.push(mainFid)
  fBase.push(0)
  fRetA.push(-1)
  fRetBase.push(0)
  fRetPC.push(-1)
  fRetN.push(-1)
  fVaB.push(0)
}

mod vmFail(msg: string) {
  vmFailed = true
  errV = msg
  vmHalted = true
}

mod numArg(t: int, v: float) -> float {
  if t != 1 && t != 6 && t != 0 {
    vmFail("bad argument (number expected)")
  }
  return if t == 0 then 0.0 else v
}

mod toInt(v: float) -> int {
  return v | 0
}

// One print call: one tab-separated line plus a newline. The log keeps the
// last 32 lines (each capped at 64 chars, about 2 KB); logV mirrors the
// joined lines so the port stays a plain string read.
mod logPush(line: string) {
  let kept = if line.Length() > 64 then line.Substring(0, 63) .. "\n" else line
  logLines.push(kept)
  logV = logV .. kept
  if logLines.length() > 32 {
    let drop = logLines[0]
    logV = logV.Substring(drop.Length(), logV.Length() - drop.Length())
    logLines.remove(0)
  }
}

// Writable output globals live in gtag/gnum/gstr (slots 0..5); the ports
// mirror them once per tick. Numeric outs read as numbers (nil -> 0.0),
// string outs Lua-formatted (nil -> "").
mod syncOuts() {
  oF0 = if gtag[slotOutLatch + 0] == 0 then 0.0 else gnum[slotOutLatch + 0]
  oF1 = if gtag[slotOutLatch + 1] == 0 then 0.0 else gnum[slotOutLatch + 1]
  oF2 = if gtag[slotOutLatch + 2] == 0 then 0.0 else gnum[slotOutLatch + 2]
  oF3 = if gtag[slotOutLatch + 3] == 0 then 0.0 else gnum[slotOutLatch + 3]
  oI0 = if gtag[slotOutInt0] == 0 then 0 else toInt(gnum[slotOutInt0])
  oS4 = if gtag[slotOutLatch + 4] == 0 then "" else fmtVal(gtag[slotOutLatch + 4], gnum[slotOutLatch + 4], gstr[slotOutLatch + 4])
  oS5 = if gtag[slotOutLatch + 5] == 0 then "" else fmtVal(gtag[slotOutLatch + 5], gnum[slotOutLatch + 5], gstr[slotOutLatch + 5])
}

mod vmNum2(op: int, b: int, c: int) -> bool {
  let bt = vTag(b)
  let ct = vTag(c)
  let ok = (bt == 1 || bt == 6) && (ct == 1 || ct == 6)
  if !ok {
    vmFail("attempt to perform arithmetic")
  }
  return ok
}

// Store an integer-valued float with the int tag when exactly
// representable (chip ints are precise inside +/-2^53); otherwise float.
mod vSetInt(a: int, v: float) {
  if v == floor(v) && abs(v) <= 9007199254740992.0 {
    vSet(a, 6, v, "")
  } else {
    vSetNum(a, v)
  }
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

// One VM instruction (ISA in spec.py).
// Composite map key for table `tid`: kt is the key's value tag.
mod tkey(tid: int, kt: int, kn: float, ks: string) -> string {
  return if kt == 1 || kt == 6 then tid .. "#" .. (kn | 0)
    else if kt == 2 then tid .. "$" .. ks
    else tid .. "@" .. kt .. ":" .. (kn | 0)
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

mod tblFill(dst: int, tid: int, idx: int) {
  let r = tmap.get(tkey(tid, 1, idx, ""))
  if r.Found {
    vSet(dst, tvTag[r.Value], tvNum[r.Value], tvStr[r.Value])
  } else {
    vSet(dst, 0, 0.0, "")
  }
}

mod keyTag(t: int, v: float) -> int {
  return if t == 1 && v == floor(v) then 6 else t
}

// After t[len+1] was filled, keep extending the border while t[len+1] exists.
mod lenStep() {
  if tmap.has(lenTid .. "#" .. (tLen[lenTid] + 1)) {
    tLen[lenTid] = tLen[lenTid] + 1
  } else {
    lenChase = false
  }
}

// next(): one chain hop per tick, so a run of tombstones (keys assigned nil)
// costs ticks but needs no loop.  Finishing writes key+value (or a lone nil)
// and advances past the call.
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

// ================================================================= _fmt
//
// string.format as a WireScript micro-step: one character of the spec, or one
// digit, per tick, stepped from nxStep like next() is.  This hunk is installed
// and the suite covers it; lib/fmt_gate_draft.txt is the extracted copy of it,
// with the findings that took the builds to get:
//
//   python -u tools/fmtdraft.py --check      what lua.ws has
//   python -u tools/fmtdraft.py --extract    save this hunk back to the draft
//
// Why a gate and not the library: the PUC-verified Lua implementation of this
// function is lib/str_format.lua, 10769 characters, and the lexer runs at four
// characters per tick, so prepending it cost 2692 ticks of boot per program --
// about 45 seconds in-game.  As a gate it costs +3,308 nodes and +6,026 wires
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
//     two arms changed nothing.  vmStep is inlined four times and the compiler
//     shares one Get per var across the copies; the lexer's chain has the same
//     shape and works, because lexChunk inlines it once.  So the rule of thumb
//     is to hoist the test to the top of the mod or take the flag as a
//     parameter, and tools/wswarn.py flags the shape as a candidate.
//   - one micro-step per burst.  vmBurst calls vmStep four times, so this whole
//     machine is inlined four times and entered up to four times in one tick;
//     fmtGo is raised by vmBurst and consumed by the first copy, so a state sees
//     one write per tick.
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
// WireScript traps measured while building this, all of them in tools/wswarn.py
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
//   - tools/vargraph.py is what settled the rest: it lists the var nodes behind
//     a name, how many write it, and what fires each write.
//
// ---------------------------------------------------------------- _fmt
//
// string.format as a micro-step: one character of the spec, or one digit, per
// tick.  The library is prepended Lua source and the lexer runs at four
// characters per tick, so the PUC-verified Lua implementation of this function
// (kept as lib/str_format.lua) cost 10769 characters -- 2692 ticks of boot, about
// 45 seconds in-game, before the program so much as started.  A gate pays
// nothing for the source and one state machine covers the loops, so this is the
// cheaper host by two orders of magnitude.  The semantics are settled by that
// reference: 107 of 108 cases match lua5.5 byte for byte.
// The argument register of the call being formatted, absolute: fmtBase + 1 +
// fmtArgI.  A mod because a write at the top of a mod is dropped, and an
// expression in the middle of fmtConv's chain would be too deep for the same
// reason.
var fmtSrc: string = ""
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

// states: 0 literal, 1 flags, 2 width, 3 precision, 4 conversion, 5 padding,
// 6 finish a conversion, 7 one integer digit, 8 one quoted byte, 9 one
// precision zero
// The character at a 1-based position is read inline at each use rather than
// from a mod: a string returned from a mod compares equal to the right text but
// its ToCharCode() reads 0, so a digit test on it never fires.
mod fmtArgAt() -> int {
  return fmtBase + 1 + fmtArgI
}

// The name of a value tag, for error messages: PUC says "got string" for a
// wrong argument and "got no value" for a missing one, so the caller passes the
// tag it would have read and says "no value" itself when there is none.
mod typeName(t: int) -> string {
  return if t == 0 then "nil" else if t == 1 || t == 6 then "number" else if t == 2 then "string" else if t == 3 then "boolean" else if t == 4 then "function" else if t == 5 then "table" else "userdata"
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

mod fmtDone() {
  vtag[nxDst] = 2
  vnum[nxDst] = 0.0
  vstr[nxDst] = fmtOut
  retCountV = 1
  nxActive = false
  vmPc = nxPc + 1
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
  } else {
    fmtPos = fmtPos + 1
    vmFail("invalid conversion '%" .. fmtCh .. "' to 'format'")
  }
}

// %s and %q.  %q quotes a string and leaves everything else as %s does, which
// is why the tag is tested here rather than in the walk.
mod fmtConvStr(c: string) {
  fmtArgI = fmtArgI + 1
  let ab = fmtArgAt()
  if fmtArgI > fmtArgs {
    vmFail("bad argument #" .. fmtArgName() .. " to 'format' (no value)")
  } else {
    let t = vTag(ab)
    fmtArg = fmtVal(t, vNum(ab), vStr(ab))
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

mod fmtConvInt() {
  fmtArgI = fmtArgI + 1
  let ab = fmtArgAt()
  if fmtArgI > fmtArgs {
    vmFail("bad argument #" .. fmtArgName() .. " to 'format' (no value)")
  } else {
    let t = vTag(ab)
    if t != 1 && t != 6 {
      vmFail("bad argument #" .. fmtArgName() .. " to 'format' (number expected, got "
             .. typeName(t) .. ")")
    } else if vNum(ab) != floor(vNum(ab)) {
      vmFail("number has no integer representation")
    } else {
      fmtNeg = vNum(ab) < 0.0
      fmtNum_ = if fmtNeg then 0.0 - vNum(ab) else vNum(ab)
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
    let t = vTag(ab)
    if t != 1 && t != 6 {
      vmFail("bad argument #" .. fmtArgName() .. " to 'format' (number expected, got "
             .. typeName(t) .. ")")
    } else if vNum(ab) != floor(vNum(ab)) {
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
      fmtNeg = vNum(ab) < 0.0
      fmtNum_ = vNum(ab)
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
    let t = vTag(ab)
    if t != 1 && t != 6 {
      vmFail("bad argument #" .. fmtArgName() .. " to 'format' (number expected, got "
             .. typeName(t) .. ")")
    } else if vNum(ab) != floor(vNum(ab)) {
      vmFail("number has no integer representation")
    } else {
      fmtQ_ = toInt(vNum(ab) / 256.0)
      let r = toInt(vNum(ab) - fmtQ_ * 256.0)
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
  } else if fmtHash == 1 {
    return 1
  }
  return 0
}

// One digit of a radix conversion, with the division done by hand: the host's
// floor truncates toward zero, so a negative quotient never goes negative and
// %x of -1 came out as fifteen zeros.  The quotient is a truncating cast and a
// negative remainder is carried into the digit and taken off the quotient, which
// is floor division; the quotient then settles at -1 and the digit count is what
// stops the loop, which is where the 64-bit two's complement comes from.
mod fmtRadixDigit() {
  fmtQ_ = toInt(fmtNum_ / fmtBase_)
  let r = toInt(fmtNum_ - fmtQ_ * fmtBase_)
  if r < 0 {
    fmtD_ = r + fmtBaseI
    fmtQ_ = fmtQ_ - 1
  } else {
    fmtD_ = r
  }
  let ch = if fmtUpper then HEXDIG_U.Substring(fmtD_, 1) else HEXDIG.Substring(fmtD_, 1)
  fmtBody = ch .. fmtBody
  fmtNum_ = fmtQ_
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
      let d = toInt(fmtNum_ - q * 10.0)
      let ch = FromCharCode(48 + d).Character
      fmtBody = ch .. fmtBody
      fmtNum_ = q
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

mod fmtStep() {
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
  } else {
    fmtDigitEnd()
  }
}


// Unlink a slot from its table's insertion chain.
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
}

// Link a slot at the tail of its table's chain, so pairs/next walk entries in
// insertion order (the order PUC-Lua uses, which the tests compare against).
mod tblLink(tid: int, sl: int) {
  let last = tLast[tid]
  tPrev[sl] = last
  tNext[sl] = -1
  if last != -1 {
    tNext[last] = sl
  } else {
    tFirst[tid] = sl
  }
  tLast[tid] = sl
}

// One table store from raw values; false means the store failed (error already
// raised).  Shared by SETFIELD and by TAPPEND's unrolled ladder.  A nil value
// leaves the key's slot in place as a tombstone so the chain order is stable and
// re-assigning the key revives the same slot.
mod tblSetKey(tid: int, kt: int, kn: float, ks: string, vt: int, vn: float, vs: string) -> bool {
  let key = tkey(tid, kt, kn, ks)
  let r = tmap.get(key)
  let kint = toInt(kn)
  if r.Found {
    let sl = r.Value
    if vt == 0 {
      // nil leaves the slot in the chain as a tombstone, so the walk order is
      // stable and re-assigning the key revives the same slot
      if tvTag[sl] != 0 {
        tvTag[sl] = 0
        tFree.push(sl)
        if kt == 6 && kint == tLen[tid] {
          tLen[tid] = kint - 1
        }
      }
    } else {
      tvTag[sl] = vt
      tvNum[sl] = vn
      tvStr[sl] = vs
      if kt == 6 && kint == tLen[tid] + 1 {
        tLen[tid] = kint
        if tmap.has(tid .. "#" .. (kint + 1)) {
          lenChase = true
          lenTid = tid
        }
      }
    }
  } else if vt == 0 {
    // assigning nil to a missing key does nothing
  } else {
    var sl = -1
    if tFree.length() > 0 {
      sl = tFree.pop().Value
      if tNext[sl] != -2 {
        // still chained in its old table: unhook it and drop the stale key
        let ot = tOwner[sl]
        tblUnlink(ot, sl)
        tmap.remove(tkey(ot, tKeyTag[sl], tKeyNum[sl], tKeyStr[sl]))
      }
    } else {
      sl = tHeap
      tHeap = tHeap + 1
    }
    if sl >= MAX_HEAP {
      vmFail("out of table memory")
      return false
    }
    tvTag[sl] = vt
    tvNum[sl] = vn
    tvStr[sl] = vs
    tOwner[sl] = tid
    tKeyTag[sl] = kt
    tKeyNum[sl] = kn
    tKeyStr[sl] = ks
    tblLink(tid, sl)
    tmap.set(key, sl)
    if kt == 6 && kint == tLen[tid] + 1 {
      tLen[tid] = kint
      if tmap.has(tid .. "#" .. (kint + 1)) {
        lenChase = true
        lenTid = tid
      }
    }
  }
  return true
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

mod vmStep() {
  if lenChase {
    lenStep()
  } else if nxActive {
    if nxMode == 1 {
      if fmtGo {
        fmtGo = false
        fmtStep()
      }
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
        vSet(a, 6, constNum[b], "")
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
      // The typed output ports check what they accept, by slot: the numeric
      // ones take numbers, booleans and nil, and outInt0 takes integers.
      if slotOutLatch <= a && a <= slotOutLatch + 3
         && vTag(b) != 1 && vTag(b) != 6 && vTag(b) != 0 && vTag(b) != 3 {
        vmFail("cannot convert to number (outNum0..outNum3 take numbers)")
      } else if a == slotOutInt0 {
        // outInt0 takes integers (integral floats convert, like outNum)
        if vTag(b) == 6 {
          gSet(a, 6, vNum(b), "")
        } else if vTag(b) == 1 && vNum(b) == floor(vNum(b)) {
          gSet(a, 6, vNum(b), "")
        } else if vTag(b) == 3 {
          gSet(a, 6, vNum(b), "")
        } else if vTag(b) == 0 {
          gSet(a, 0, 0.0, "")
        } else {
          vmFail("cannot convert to integer (outInt0 takes integers)")
        }
      } else {
        gSet(a, vTag(b), vNum(b), vStr(b))
      }
    } else if op == 7 {
      vSet(a, vTag(b), vNum(b), vStr(b))
    } else if op >= 8 && op <= 13 {
      if vmNum2(op, b, c) {
        let x = vNum(b)
        let y = vNum(c)
        let ii = vTag(b) == 6 && vTag(c) == 6
        if op == 8 {
          if ii {
            vSetInt(a, x + y)
          } else {
            vSetNum(a, x + y)
          }
        } else if op == 9 {
          if ii {
            vSetInt(a, x - y)
          } else {
            vSetNum(a, x - y)
          }
        } else if op == 10 {
          if ii {
            vSetInt(a, x * y)
          } else {
            vSetNum(a, x * y)
          }
        } else if op == 11 {
          if y == 0.0 {
            vSetNum(a, 0.0)
          } else {
            vSetNum(a, x / y)
          }
        } else if op == 12 {
          if y == 0.0 {
            if ii {
              vSet(a, 6, 0.0, "")
            } else {
              vSetNum(a, 0.0)
            }
          } else {
            // floored quotient: the floor gate truncates toward zero,
            // so adjust negative non-integral quotients down by one
            let q = x / y
            let t = q | 0
            let fl = if q < 0.0 && q != t + 0.0 then t - 1 else t
            let flf = fl + 0.0
            if ii {
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
      if vTag(b) == 6 {
        vSetInt(a, 0.0 - vNum(b))
      } else if vTag(b) != 1 {
        vmFail("attempt to negate")
      } else {
        vSetNum(a, 0.0 - vNum(b))
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
        vmFail("attempt to concatenate")
      }
    } else if op == 17 || op == 18 || op == 19 {
      let lt = vTag(b)
      let rt = vTag(c)
      let ln = lt == 1 || lt == 6
      let rn = rt == 1 || rt == 6
      if op == 17 {
        if ln && rn {
          vSet(a, 3, if vNum(b) == vNum(c) then 1.0 else 0.0, "")
        } else if lt != rt {
          vSet(a, 3, 0.0, "")
        } else if lt == 1 {
          vSet(a, 3, if vNum(b) == vNum(c) then 1.0 else 0.0, "")
        } else if lt == 2 {
          vSet(a, 3, if vStr(b) == vStr(c) then 1.0 else 0.0, "")
        } else if lt == 3 {
          vSet(a, 3, if vNum(b) == vNum(c) then 1.0 else 0.0, "")
        } else if lt == 4 || lt == 5 {
          vSet(a, 3, if vNum(b) == vNum(c) then 1.0 else 0.0, "")
        } else {
          vSet(a, 3, 1.0, "")
        }
      } else if ln && rn {
        if op == 18 {
          vSet(a, 3, if vNum(b) < vNum(c) then 1.0 else 0.0, "")
        } else {
          vSet(a, 3, if vNum(b) <= vNum(c) then 1.0 else 0.0, "")
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
        vmFail("attempt to compare")
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
        let fid = toInt(vNum(a))
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
        if fid == 0 {
          if nargs > 16 {
            vmFail("too many print args (max 16)")
          } else {
            // one pure expression (no variable traffic): guarded segments
            logPush((if 0 < nargs then fmtVal(vTag(a + 1), vNum(a + 1), vStr(a + 1)) else "") .. (if 1 < nargs then "\t" .. fmtVal(vTag(a + 2), vNum(a + 2), vStr(a + 2)) else "") .. (if 2 < nargs then "\t" .. fmtVal(vTag(a + 3), vNum(a + 3), vStr(a + 3)) else "") .. (if 3 < nargs then "\t" .. fmtVal(vTag(a + 4), vNum(a + 4), vStr(a + 4)) else "") .. (if 4 < nargs then "\t" .. fmtVal(vTag(a + 5), vNum(a + 5), vStr(a + 5)) else "") .. (if 5 < nargs then "\t" .. fmtVal(vTag(a + 6), vNum(a + 6), vStr(a + 6)) else "") .. (if 6 < nargs then "\t" .. fmtVal(vTag(a + 7), vNum(a + 7), vStr(a + 7)) else "") .. (if 7 < nargs then "\t" .. fmtVal(vTag(a + 8), vNum(a + 8), vStr(a + 8)) else "") .. (if 8 < nargs then "\t" .. fmtVal(vTag(a + 9), vNum(a + 9), vStr(a + 9)) else "") .. (if 9 < nargs then "\t" .. fmtVal(vTag(a + 10), vNum(a + 10), vStr(a + 10)) else "") .. (if 10 < nargs then "\t" .. fmtVal(vTag(a + 11), vNum(a + 11), vStr(a + 11)) else "") .. (if 11 < nargs then "\t" .. fmtVal(vTag(a + 12), vNum(a + 12), vStr(a + 12)) else "") .. (if 12 < nargs then "\t" .. fmtVal(vTag(a + 13), vNum(a + 13), vStr(a + 13)) else "") .. (if 13 < nargs then "\t" .. fmtVal(vTag(a + 14), vNum(a + 14), vStr(a + 14)) else "") .. (if 14 < nargs then "\t" .. fmtVal(vTag(a + 15), vNum(a + 15), vStr(a + 15)) else "") .. (if 15 < nargs then "\t" .. fmtVal(vTag(a + 16), vNum(a + 16), vStr(a + 16)) else "") .. "\n")
            vSet(a, 0, 0.0, "")
            retCountV = 0
          }
        } else if fid == 1 || fid == 2 {
          if nargs == 0 {
            vmFail("wrong number of arguments")
          } else if fid == 1 {
            let t = vTag(a + 1)
            vSet(a, 2, 0.0, if t == 0 then "nil" else if t == 1 || t == 6 then "number" else if t == 2 then "string" else if t == 3 then "boolean" else if t == 4 then "function" else "table")
            retCountV = 1
          } else {
            vSet(a, 2, 0.0, fmtVal(vTag(a + 1), vNum(a + 1), vStr(a + 1)))
            retCountV = 1
          }
        } else if fid == 3 {
          let x = numArg(if 0 < nargs then vTag(a + 1) else 0, if 0 < nargs then vNum(a + 1) else 0.0)
          let y = numArg(if 1 < nargs then vTag(a + 2) else 0, if 1 < nargs then vNum(a + 2) else 0.0)
          let z = numArg(if 2 < nargs then vTag(a + 3) else 0, if 2 < nargs then vNum(a + 3) else 0.0)
          outVecV = Vec(x, y, z)
          vSet(a, 0, 0.0, "")
          retCountV = 0
        } else if fid == 4 {
          let r = numArg(if 0 < nargs then vTag(a + 1) else 0, if 0 < nargs then vNum(a + 1) else 0.0)
          let g = numArg(if 1 < nargs then vTag(a + 2) else 0, if 1 < nargs then vNum(a + 2) else 0.0)
          let bl = numArg(if 2 < nargs then vTag(a + 3) else 0, if 2 < nargs then vNum(a + 3) else 0.0)
          let al = numArg(if 3 < nargs then vTag(a + 4) else 0, if 3 < nargs then vNum(a + 4) else 0.0)
          outColV = Color(r, g, bl, al)
          vSet(a, 0, 0.0, "")
          retCountV = 0
        } else if fid == 5 {
          if nargs != 0 {
            vmFail("wrong number of arguments to clock")
          } else {
            vSetNum(a, ServerUptime())
            retCountV = 1
          }
        } else if fid == 6 {
          let it = if 0 < nargs then vTag(a + 1) else 0
          let iv = if 0 < nargs then vNum(a + 1) else 0.0
          if (it == 1 || it == 6) && iv == floor(iv) && iv >= 1.0 && iv <= inArr.length() {
            vSetNum(a, inArr[toInt(iv) - 1])
          } else {
            vSet(a, 0, 0.0, "")
          }
          retCountV = 1
        } else if fid == 7 {
          let it = if 0 < nargs then vTag(a + 1) else 0
          let iv = if 0 < nargs then vNum(a + 1) else 0.0
          let vt = if 1 < nargs then vTag(a + 2) else 0
          let vv = if 1 < nargs then vNum(a + 2) else 0.0
          if (it != 1 && it != 6) || iv != floor(iv) || iv < 1.0 || iv > outArrV.length() {
            vmFail("array index out of range")
          } else if vt == 1 || vt == 6 || vt == 0 || vt == 3 {
            outArrV[toInt(iv) - 1] = if vt == 0 then 0.0 else vv
            vSet(a, 0, 0.0, "")
            retCountV = 0
          } else {
            vmFail("array element must be a number")
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
            } else {
              shiftDown(a, src, cnt)
              retCountV = cnt
            }
          }
        } else if fid == 9 {
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
          let x = if 1 < nargs then numArg(vTag(a + 2), vNum(a + 2), 0.0) else 0.0
          let y = if 2 < nargs then numArg(vTag(a + 3), vNum(a + 3), 0.0) else 0.0
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
          } else if mo == 14 {
            vSet(a, 2, 0.0, if vTag(a + 2) == 6 then "integer"
              else if vTag(a + 2) == 1 then "float" else "nil")
          } else {
            vSetNum(a, if mo == 3 then sqrt(x) else if mo == 4 then sin(x)
              else if mo == 5 then cos(x) else if mo == 6 then tan(x)
              else if mo == 7 then asin(x) else if mo == 8 then acos(x)
              else if mo == 9 then atan2(x, y)
              else if mo == 10 then exp(x) else if mo == 11 then ln(x)
              else log(x, 10.0))
          }
          retCountV = 1
        } else if fid == 12 {
          // unpack(t [, i [, j]]): t[i..j] as multiple results.  Lua cannot
          // write this -- a return list is fixed length -- so it is a primitive.
          if nargs < 1 || vTag(a + 1) != 5 {
            vmFail("bad argument #1 to 'unpack' (table expected)")
          } else {
            let tid = toInt(vNum(a + 1))
            let lo = if 1 < nargs then toInt(numArg(vTag(a + 2), vNum(a + 2), 1.0)) else 1
            let hi = if 2 < nargs then toInt(numArg(vTag(a + 3), vNum(a + 3), 0.0)) else tLen[tid]
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
              retCountV = cnt
            }
          }
        } else if fid == 13 {
          // _fmt(fmt, ...): string.format, as a micro-step.  lib/str_format.lua
          // is the PUC-verified Lua version of this algorithm; as prepended
          // source it cost 2692 ticks of lexing per program, so it lives here
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
              if vaTop + nva > MAX_VA {
                vmFail("too many varargs")
              } else {
                vaSpill(vmBase + a + 1 + np, vaTop, nva)
                fVaB.push(vaTop)
                vaTop = vaTop + nva
              }
              fFunc.push(fid)
              fBase.push(nbase)
              fRetA.push(a)
              fRetBase.push(vmBase)
              fRetPC.push(vmPc + 1)
              fRetN.push(if mtSelf then -2 else 1)
              vmBase = nbase
              vmPc = fStart[fid]
              advanced = true
            }
          }
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
      if fFunc.length() == 0 {
        resultV = fmtVal(rv, rn, rs)
        vmHalted = true
      } else {
        vmBase = rb
        vSet(ra, rv, rn, rs)
        vmPc = rpc
        retCountV = 1
      }
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
      if fFunc.length() == 0 {
        resultV = ""
        vmHalted = true
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
      vSet(a, 4, b, "")
    } else if op == 28 {
      if tCount >= MAX_TABLES {
        vmFail("too many tables")
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
        vmFail("attempt to index a non-table value")
      } else if kt == 0 || (kt == 1 && vNum(c) != floor(vNum(c))) {
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
        vSet(a, 6, tLen[toInt(vNum(b))] + 0.0, "")
      } else if bt == 2 {
        vSet(a, 6, vStr(b).Length() + 0.0, "")
      } else {
        vmFail("attempt to get length")
      }
    } else if op == 32 {
      let stp = vNum(c)
      if stp == 0.0 { vmFail("'for' step is zero") }
      if vTag(a) == 6 && (vTag(b) != 6 || vTag(c) != 6) {
        vSetNum(a, vNum(a))
      }
      forCtrl[forDepth] = a
      forDepth = forDepth + 1
      let ctrl = vNum(a)
      let lim = vNum(b)
      if (stp > 0.0 && ctrl <= lim) || (stp < 0.0 && ctrl >= lim) {
        vmPc = vmPc + 2
        advanced = true
      } else {
        advanced = false
      }
    } else if op == 33 {
      let ctrl_reg = forCtrl[forDepth - 1]
      let ctrl = vNum(ctrl_reg)
      let lim = vNum(b)
      let stp = vNum(c)
      let newCtrl = ctrl + stp
      if vTag(ctrl_reg) == 6 {
        vSetInt(ctrl_reg, newCtrl)
      } else {
        vSetNum(ctrl_reg, newCtrl)
      }
      if (stp > 0.0 && newCtrl <= lim) || (stp < 0.0 && newCtrl >= lim) {
        vmPc = a
        advanced = true
      } else {
        forDepth = forDepth - 1
      }
    } else if op == 34 {
      let lt = vTag(b)
      let rt = vTag(c)
      if lt != 6 && lt != 1 { vmFail("attempt to perform floor division") }
      if rt != 6 && rt != 1 { vmFail("attempt to perform floor division") }
      let x = vNum(b)
      let y = vNum(c)
      if y == 0.0 {
        if lt == 6 { vSetInt(a, 0) } else { vSetNum(a, 0.0) }
      } else if lt == 6 && rt == 6 {
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
    } else if op == 35 {
      let lt = vTag(b)
      let rt = vTag(c)
      if lt != 6 && !(lt == 1 && vNum(b) == floor(vNum(b))) { vmFail("attempt to perform 'bitwise'") }
      if rt != 6 && !(rt == 1 && vNum(c) == floor(vNum(c))) { vmFail("attempt to perform 'bitwise'") }
      let na = 0.0 - vNum(b) - 1.0
      let nb = 0.0 - vNum(c) - 1.0
      let nob = na | nb
      vSetInt(a, -(nob) - 1.0)
    } else if op == 36 {
      let lt = vTag(b)
      let rt = vTag(c)
      if lt != 6 && !(lt == 1 && vNum(b) == floor(vNum(b))) { vmFail("attempt to perform 'bitwise'") }
      if rt != 6 && !(rt == 1 && vNum(c) == floor(vNum(c))) { vmFail("attempt to perform 'bitwise'") }
      vSetInt(a, vNum(b) | vNum(c))
    } else if op == 37 {
      let lt = vTag(b)
      let rt = vTag(c)
      if lt != 6 && !(lt == 1 && vNum(b) == floor(vNum(b))) { vmFail("attempt to perform 'bitwise'") }
      if rt != 6 && !(rt == 1 && vNum(c) == floor(vNum(c))) { vmFail("attempt to perform 'bitwise'") }
      let na = 0.0 - vNum(b) - 1.0
      let nb = 0.0 - vNum(c) - 1.0
      let nob = na | nb
      let band = -(nob) - 1.0
      vSetInt(a, vNum(b) + vNum(c) - 2.0 * band)
    } else if op == 38 {
      let vt = vTag(b)
      if vt != 6 && !(vt == 1 && vNum(b) == floor(vNum(b))) { vmFail("attempt to perform 'bitwise'") }
      vSetInt(a, -(vNum(b)) - 1.0)
    } else if op == 39 {
      let lt = vTag(b)
      let rt = vTag(c)
      if lt != 6 && !(lt == 1 && vNum(b) == floor(vNum(b))) { vmFail("attempt to perform 'bitwise'") }
      if rt != 6 && !(rt == 1 && vNum(c) == floor(vNum(c))) { vmFail("attempt to perform 'bitwise'") }
      vSetInt(a, vNum(b) * (2.0 ** vNum(c)))
    } else if op == 40 {
      let lt = vTag(b)
      let rt = vTag(c)
      if lt != 6 && !(lt == 1 && vNum(b) == floor(vNum(b))) { vmFail("attempt to perform 'bitwise'") }
      if rt != 6 && !(rt == 1 && vNum(c) == floor(vNum(c))) { vmFail("attempt to perform 'bitwise'") }
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

// ---------------------------------------------------------------- jobs + events

let sched: exec
let goParse: exec
let goParse2: exec

var jobBusy: bool = false
var wantParse: bool = false

mod parseJobStart() {
  parseInit()
  // One reserved function slot per gate builtin (ids 0..NB-1), so a program's
  // own functions start at NB and can never collide with one.  The rest of the
  // standard library is Lua source prepended to the program (see libIter etc).
  fStart.resize(NB, -1)
  fParams.resize(NB, -1)
  fRegs.resize(NB, -1)
  mainFid = newFunc()
  fStart[mainFid] = 0
  fParams[mainFid] = 0
}

// Lex one chunk per call; the driver loops these across ticks.
mod lexChunk() {
  lexStep()
  lexStep()
  lexStep()
  lexStep()
}

mod parseChunk() {
  parseStep()
  parseStep()
}

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

mod libStrMisc(p: string) -> string {
  return if srcUses(p, "string.rep") || srcUses(p, "string.reverse")
      || srcUsesField(p, "rep") || srcUsesField(p, "reverse")
      then LIB_str_misc else ""
}

mod libMathConst(p: string) -> string {
  return if srcUses(p, "math.pi") || srcUses(p, "math.huge")
      || srcUses(p, "math.maxinteger") || srcUses(p, "math.mininteger")
      then LIB_math_const else ""
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

mod vmBurst() {
  fmtGo = true
  vmStep()
  vmStep()
  vmStep()
  vmStep()
}

on Change(program) {
  wantParse = true
  emit sched
}

on Change(run) {
  if run && progOkV && !jobBusy {
    vmReset()
  }
}

on ReadBrickGrid() {
  wantParse = true
  emit sched
}

on sched {
  if !jobBusy {
    if wantParse {
      wantParse = false
      jobBusy = true
      emit goParse
    }
  }
}

on goParse {
  parseJobStart()
  // The library goes in front of the program, so the user's line numbers are
  // shifted by however many lines it added; libLines undoes that for errors.
  // One variable per library piece, then concatenate: the host compiler cannot
  // lower a mod call inside a binary operation, only variable + variable.
  // A piece is charged by its characters (4 per tick of lexing), so only pieces
  // of a few hundred characters belong here; string.format is a builtin instead
  // (lib/str_format.lua is the reference implementation it is built from).
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
  let lib = libA .. libB .. libC .. libD .. libE .. libF .. libG
    .. libH .. libI .. libJ .. libK .. libL .. libM .. libN
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
      let el = lerrLine | 0
      if libLines < el { el = el - libLines } else { el = 1 }
      errV = "line " .. el .. ": " .. lerrMsg
      vmHalted = true
      jobBusy = false
    } else {
      emit goParse2
    }
  }
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
    jobBusy = false
    vmReset()
    if perr {
      // vmReset clears errV, so report the failure after it; cpos sits at
      // (or just past) the offending token in nearly every perr path
      let epos = if cpos >= tl.length() then tl.length() - 1 else cpos
      let eline = if epos < 0 then lline else tl[epos]
      errV = "line " .. (eline | 0) .. ": " .. perrMsg
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

on Change(inInt0) {
  latchI0 = inInt0
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

on Change(inVec) {
  latchVX = inVec.x
  latchVY = inVec.y
  latchVZ = inVec.z
  if run && progOkV && !jobBusy {
    vmReset()
  }
}

on Change(inCol) {
  latchCR = inCol.r
  latchCG = inCol.g
  latchCB = inCol.b
  latchCA = inCol.a
  if run && progOkV && !jobBusy {
    vmReset()
  }
}

on Clock(interval = STEP_INTERVAL) {
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
//    run, progOk and the halt flag); progLen and nPrint ports dropped.
// 13. print feeds one multiline log port (one tab-separated line per call, last 32 lines
//    at 64 chars each, cleared on restart) instead of 8 slots; the 16-way slot dispatch
//    is gone, lines stream through a small array plus a string mirror.
// 14. outNum0..outNum3 are writable numeric globals, outStr0..outStr1 writable string
//    globals (mirrored to their ports once per tick); inarr/outarr bridge 1-based
//    float arrays.
// 18. Number/string ports renamed by type: inNum0..inNum3, inStr0..inStr1,
//    outNum0..outNum3, outStr0..outStr1.
// 15. Compile failures report "line N: message" in err (token lines ride a parallel array,
//    lexer errors carry their own line).
// 16. Duplicate targets in one assignment store right to left (a, a = 1, 2 leaves 1).
// 17. Table constructors accept [k] = v with any key expression.
// 19. Function ids 6 and 7 were taken by inarr/outarr but parseJobStart still reserved only six
//    builtin slots, so the first two user functions (and the main chunk) collided with them:
//    any program defining a function printed nothing or failed with "array index out of range".
//    It now reserves eight slots.
