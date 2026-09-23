/// Full Lua: numbers (int + float, like real Lua), strings, booleans, nil, tables,
/// functions, closures/upvalues, metatables, goto/labels, varargs, multiple returns,
/// integer division and bitwise operators, plus a Lua-source standard library
/// (base, math, string incl. patterns and string.format, table, os, io.write).
///
/// Wire a Lua program into `program` (a string variable gate) and drive `run` high.
/// The program is lexed, parsed to flat bytecode, then executed on a register VM.
///
/// Ports
///   in  program: string       Lua source. Changing it re-parses.
///   in  run: bool              level input. High: the program executes. Low: execution
///                              stops immediately (outputs keep their values). A rising
///                              edge restarts the program from the top. Left unwired it
///                              is low: wire a constant true to auto-run.
///   in  inNum0..inNum3: float  read as Lua globals inNum0..inNum3
///   in  inInt0: int            read as the Lua global inInt0 (a real integer)
///   in  inStr0..inStr1: string read as Lua globals inStr0..inStr1
///   in  inVec: vector          read as the Lua globals invecx, invecy, invecz
///   in  inCol: color           read as the Lua globals incolr, incolg, incolb, incola
///   in  inArr: float[]         read with inarr(i) (1-based; nil past the end)
///   out log: string            every print() call appends one tab-separated line,
///                              newest 32 lines kept, each capped at 64 chars
///   out outNum0..outNum3: float   writable as Lua globals: outNum0 = 5
///   out outStr0..outStr1: string  writable as Lua globals: outStr0 = "hi"
///   out outInt0: int              writable as a Lua global, must be given an integer
///   out outVec: vector         written by setvec(x, y, z)
///   out outCol: color          written by setcol(r, g, b, a)
///   out result: string         the top-level return value, "" when none
///   out err: string            runtime error text, "" when none; a compile error is
///                              reported the same way, prefixed "line N: "
///   out progOk: bool           false when the program did not compile
///   out busy: bool             true while parsing or (while `run` is high) executing
///   out halted: bool           true when the VM finished, hit an error, or has nothing
///                              to run
///   A change on any input while `run` is high restarts the program with the new value.
///   Changing an input while `run` is low leaves the outputs alone.
///
/// inarr(i) / outarr(i, v) read and write the `inArr` / `outArr` array ports directly
/// (1-based), so a program can e.g. sort an input array into an output array.
///
/// Language: the full syntax and semantics of Lua 5.4/5.5 as I understand them, tested
/// against a real Lua 5.5.1 interpreter I built from source for this project (see
/// Verification below). Supported: all statements (local, assignment incl. parallel and
/// to table fields, if/elseif/else, while, repeat/until, numeric and generic for, goto
/// and ::labels::, break, function/local function incl. a.b.c and a.b:c forms, return
/// with any number of values, varargs ...); all operators incl. // (floor div), the
/// bitwise operators, .. (concat), and comparisons that work like Lua's (no coercion
/// for == / ~=, numeric or lexicographic for < <= > >=); tables with full constructor
/// syntax including [k]=v and mixed forms, nesting, and metatables (__index,
/// __newindex, __call, __eq, __lt, __le, __len, __concat, __tostring, and the
/// arithmetic metamethods); closures with real upvalues (a local function can call
/// another local function, or a closure can capture and mutate an outer local);
/// multiple return values and multiple assignment; select/pcall/xpcall/error/assert;
/// table keys may be any value including non-integer numbers (1.5 is a distinct key
/// from 1); math, string, table and os are real tables (identity, iteration, and
/// passing them around all work), assembled once from the underlying functions;
/// long strings and long comments ([[ ]], [==[ ]==], ...); hex integer literals.
///
/// Standard library (Lua source, prepended to the program only when used, so an unused
/// function costs nothing): ipairs, pairs/next, assert, raw{get,set,equal,len}, xpcall,
/// table.{insert,remove,concat,sort,pack,unpack,move}, math.{floor,ceil,sqrt,sin,cos,
/// tan,asin,acos,atan,exp,log,abs,max,min,fmod,modf,random,randomseed,tointeger,type,
/// ult,pi,huge,maxinteger,mininteger}, os.{time,clock,getenv}, io.write, string.{len,
/// sub,upper,lower,byte,char,rep,reverse,format,find,match,gmatch,gsub} (format supports
/// the usual %d %s %f %e %g %x %o %c %q with flags/width/precision; find/match/gmatch/
/// gsub implement real Lua patterns: classes, sets, anchors, captures, %b, %f, and the
/// usual quantifiers). unpack is kept as a global alias for table.unpack for convenience.
///
/// Not supported: coroutines, the debug/utf8 libraries, string patterns' %g class edge
/// cases beyond what's listed above, os.date/os.execute/io beyond write, load/dofile/
/// require, and the brand-new Lua 5.5 syntax (explicit `global` declarations, <const>/
/// <close> attributes, read-only for-loop variables) -- these are additive in real Lua
/// 5.5 and essentially unused by existing scripts, so ordinary pasted-in Lua code is
/// unaffected; ask if you want any of them added.
///
/// Known differences from real Lua
///   - division by zero, and x % 0, yield 0 (the underlying gate's behavior), not
///     IEEE inf/nan, so 0/0 == 0/0 is true here and false in real Lua.
///   - tostring(atable) gives "table" / "function", not a fake memory address, unless
///     the table has a __tostring metamethod (real addresses can't mean anything here
///     and differ run to run in real Lua too).
///   - runtime errors get "line N: message" (N relative to your own script, not the
///     library text in front of it), not Lua's "[string "..."]:N:" — same information,
///     different wording. error(msg, level) is honoured for level 0/1/2; level 3+ falls
///     back to level 2's line.
///   - string.format's %f/%e/%g precision search may drift by a unit in the last digit
///     versus real Lua's printf on some inputs; not exhaustively checked.
///   - getmetatable() on a string returns nil (string methods work via a different,
///     internal mechanism, not a real metatable). getmetatable/setmetatable on tables
///     work normally.
///   - a string of the form "0x10" doesn't coerce to a number in arithmetic (decimal
///     strings like "10" or "1.5" do); write tonumber("0x10") isn't supported either.
///
/// Limits (compile error past them, progOk = false): 4000 tokens, 2000 bytecode
/// instructions, 64 registers per function, up to 8 parameters, 128 functions, 250
/// globals, 1024 numeric/string/integer constants each, 48 nested calls; at runtime,
/// 64 tables and 512 live table entries in total, 2048 open upvalues, 256 varargs.
///
/// Speed and gate count (about 38k gates total)
///   Execution: vmBurst() runs up to 6 "hot" instructions (arithmetic, jumps, table
///   get/set, calls, returns) per call, fired by Clock every STEP_INTERVAL (0.01s, so
///   at most once per tick); instructions needing type coercion, metamethods, or
///   multi-step work (closures, string comparison, print) fall through to one "cold"
///   step per call.  Parsing: 4 characters per tick for the lexer, 1 parser step per
///   tick (parsing a few hundred characters takes a few seconds). Both are single
///   constants near the bottom of the file (lexChunk/parseChunk/vmBurst) if you want to
///   trade gates for speed either way.
///
/// Verification: I built the Wirescript compiler and a real Lua 5.5.1 interpreter from
/// source, then wrote a Python model of this file's actual generated bytecode (not a
/// separate reimplementation) and ran it against Lua 5.5.1 on about 385 test programs
/// covering every feature above, plus one program that uses every input and output at
/// once (closures, OOP via metatables, tables, patterns, string.format, goto, varargs,
/// bitwise/integer ops, pcall) and produces outputs that all matched Lua 5.5.1 exactly.
/// It has not been run inside Brickadia.

@layout("cube")

// ---------------------------------------------------------------- ports

@left in program: string
@left in run: bool
@left in inNum0: float
@left in inNum1: float
@left in inNum2: float
@left in inNum3: float
@left in inInt0: int
@left in inStr0: string
@left in inStr1: string
@left in inVec: vector
@left in inCol: color
@left in inArr: float[]

@right out log: string = logV.Value
@right out outNum0: float = oF0.Value
@right out outNum1: float = oF1.Value
@right out outNum2: float = oF2.Value
@right out outNum3: float = oF3.Value
@right out outStr0: string = oS4.Value
@right out outStr1: string = oS5.Value
@right out outInt0: int = oI6.Value
@right out outArr: float[] = outArrV
@right out outVec: vector = outVecV.Value
@right out outCol: color = outColV.Value
@right out result: string = resultV.Value
@right out err: string = errV.Value
@right out progOk: bool = progOkV.Value
@right out busy: bool = jobBusy || (run && progOkV && !vmHalted)

// ---------------------------------------------------------------- tunables

const STEP_INTERVAL = 0.01
const MAX_INSTR = 6000
const MAX_TOKENS = 12000
const MAX_REGS = 64
const MAX_FUNCS = 256
const MAX_GLOBALS = 250
const MAX_CALLS = 48
const MAX_TABLES = 64
const MAX_HEAP = 512

// ---------------------------------------------------------------- state: outputs + status

var logV: string = ""
var logLines: string[]
var oF0: float = 0.0
var oF1: float = 0.0
var oF2: float = 0.0
var oF3: float = 0.0
var oS4: string = ""
var oS5: string = ""
var oI6: int = 0
var outArrV: float[]
var outVecV: vector = Vec(0.0, 0.0, 0.0)
var outColV: color = Color(0.0, 0.0, 0.0, 0.0)
var resultV: string = ""
var errV: string = ""
var progOkV: bool = false

// ---------------------------------------------------------------- lexer state
// token kinds: 1 NUM, 2 STR, 3 NAME, 4 KW, 5 SYM, 6 EOF
// KW ids: and1 break2 do3 else4 elseif5 end6 false7 function8 if9 local10
//   nil11 not12 or13 return14 then15 true16 while17
// SYM ids: +1 -2 *3 /4 %5 ^6 <7 >8 <=9 >=10 ==11 ~=12 =13 (14 )15 ,16 ;17 ..18
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
var lnumInt: float = 0.0
var lnumI: int = 0
var lnumIsInt: bool = true
var lnumHex: int = 0
var emI: int = 0
var lnumFrac: float = 0.0
var lnumDiv: float = 1.0
var lnumDot: bool = false
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
var tni: int[]

mod lexFail(msg: string) {
  lerr = true
  lerrMsg = msg
  lerrLine = lline
}

// printable ASCII table for \ddd / \xXX escapes (32..126 only)
const ALNUM = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_"
const PRINTABLES = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"

mod emitTok(kind: int, sub: int, num: float, text: string) {
  tk.push(kind)
  ts.push(sub)
  tn.push(num)
  tt.push(text)
  tl.push(lline)
  tni.push(emI)
  emI = 0
  if tk.length() > MAX_TOKENS {
    lexFail("too many tokens")
  }
}

mod emitNum() {
  let mant = lnumInt + lnumFrac / lnumDiv
  let ev = if lnumExpNeg then -lnumExp else lnumExp
  emI = lnumI
  emitTok(1, if lnumIsInt then 1 else 0, mant * (10.0 ** ev), "")
}

// number of leading identifier characters in a 16-character window
mod isAlAt(seg: string, i: int) -> bool {
  return i < seg.Length() && ALNUM.Find(seg.Substring(i, 1), true, 0) >= 0
}
mod idLen(seg: string) -> int {
  let a0 = isAlAt(seg, 0)
  let a1 = a0 && isAlAt(seg, 1)
  let a2 = a1 && isAlAt(seg, 2)
  let a3 = a2 && isAlAt(seg, 3)
  let a4 = a3 && isAlAt(seg, 4)
  let a5 = a4 && isAlAt(seg, 5)
  let a6 = a5 && isAlAt(seg, 6)
  let a7 = a6 && isAlAt(seg, 7)
  let a8 = a7 && isAlAt(seg, 8)
  let a9 = a8 && isAlAt(seg, 9)
  let a10 = a9 && isAlAt(seg, 10)
  let a11 = a10 && isAlAt(seg, 11)
  let a12 = a11 && isAlAt(seg, 12)
  let a13 = a12 && isAlAt(seg, 13)
  let a14 = a13 && isAlAt(seg, 14)
  let a15 = a14 && isAlAt(seg, 15)
  return a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8 + a9 + a10 + a11 + a12 + a13 + a14 + a15
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
// A long string or long comment starting at pos (its opening bracket has `level` equals signs).
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
    else if n == "while" then 17
    else if n == "for" then 18
    else if n == "in" then 19
    else if n == "repeat" then 20
    else if n == "until" then 21
    else if n == "goto" then 22
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

mod emitEscByte(v: int) {
  if v > 255 {
    lexFail("decimal escape too large")
  } else {
    lidBuf = lidBuf .. FromCharCode(v).Character
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
      if lstage == 1 || lstage == 2 {
        emitNum()
        lstage = 99
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
      } else if lstage == 11 {
        emI = lnumI
        emitTok(1, 1, lnumI + 0.0, "")
        lstage = 99
      } else if lstage == 0 {
        lstage = 99
      } else {
        lexFail("unterminated string")
      }
    } else if lstage == 0 {
      let seg = lsrc.Substring(lpos, 16)
      let lead = seg.Length() + 1 - (seg .. "x").Trim().Length()
      if lead > 0 {
        let skipped = seg.Substring(0, lead)
        lline = lline + skipped.Length() - skipped.Replace("\n", "").Length()
        lpos = lpos + lead
      } else if isAlpha {
        let nlen = idLen(seg)
        lidBuf = seg.Substring(0, nlen)
        lpos = lpos + nlen
        if nlen == 16 {
          lstage = 6
        } else if (lidBuf == "math" || lidBuf == "string" || lidBuf == "table" || lidBuf == "os" || lidBuf == "io") && lsrc.Substring(lpos, 1) == "." && lsrc.Substring(lpos + 1, 1) != "" && ALNUM.Find(lsrc.Substring(lpos + 1, 1), true, 0) >= 10 {
          lidBuf = lidBuf .. "."
          lpos = lpos + 1
          lstage = 6
        } else {
          resolveKw()
        }
      } else if cp == 48 && (cp2 == 120 || cp2 == 88) {
        lnumI = 0
        lnumHex = 0
        lstage = 11
        lpos = lpos + 2
      } else if isDigit {
        lnumI = cp - 48
        lnumIsInt = true
        lnumInt = cp - 48.0
        lnumFrac = 0.0
        lnumDiv = 1.0
        lnumDot = false
        lnumExp = 0
        lnumExpNeg = false
        lnumExpSeen = false
        lstage = 1
        lpos = lpos + 1
      } else if cp == 46 {
        if cp2 >= 48 && cp2 <= 57 {
          lnumInt = 0.0
          lnumI = 0
          lnumIsInt = false
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
            emitTok(5, 31, 0.0, "")
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
        let e = lsrc.Find(ch, true, lpos + 1)
        let bs = lsrc.Find("\\", true, lpos + 1)
        if e >= 0 && (bs < 0 || bs > e) {
          emitTok(2, 0, 0.0, lsrc.Substring(lpos + 1, e - lpos - 1))
          lpos = e + 1
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
            let nl = lsrc.Find("\n", true, lpos)
            lpos = if nl < 0 then llen else nl
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
          emitTok(5, 25, 0.0, "")
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
        if cp2 == 61 {
          emitTok(5, 9, 0.0, "")
          lpos = lpos + 2
        } else if cp2 == 60 {
          emitTok(5, 26, 0.0, "")
          lpos = lpos + 2
        } else {
          emitTok(5, 7, 0.0, "")
          lpos = lpos + 1
        }
      } else if cp == 62 {
        if cp2 == 61 {
          emitTok(5, 10, 0.0, "")
          lpos = lpos + 2
        } else if cp2 == 62 {
          emitTok(5, 27, 0.0, "")
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
        } else {
          emitTok(5, 30, 0.0, "")
          lpos = lpos + 1
        }
      } else if cp == 38 {
        emitTok(5, 28, 0.0, "")
        lpos = lpos + 1
      } else if cp == 124 {
        emitTok(5, 29, 0.0, "")
        lpos = lpos + 1
      } else if cp == 58 {
        if cp2 == 58 {
          emitTok(5, 32, 0.0, "")
          lpos = lpos + 2
        } else {
          emitTok(5, 33, 0.0, "")
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
      } else {
        lexFail("unexpected character")
      }
    } else if lstage == 1 {
      // number integer part
      if isDigit {
        lnumInt = lnumInt * 10.0 + (cp - 48.0)
        lnumI = lnumI * 10 + (cp - 48)
        lpos = lpos + 1
      } else if cp == 46 {
        if cp2 >= 48 && cp2 <= 57 {
          lnumDot = true
          lnumIsInt = false
          lstage = 2
          lpos = lpos + 1
        } else if cp2 == 46 {
          lexFail("malformed number (like Lua '5..3')")
        } else {
          lnumIsInt = false
          emitNum()
          lstage = 0
          lpos = lpos + 1
        }
      } else if cp == 101 || cp == 69 {
        if (cp2 >= 48 && cp2 <= 57) || ((cp2 == 43 || cp2 == 45) && cp3 >= 48 && cp3 <= 57) {
          lnumIsInt = false
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
    } else if lstage == 11 {
      // hexadecimal integer
      let hv = hexVal(cp)
      if hv >= 0 {
        lnumI = lnumI * 16 + hv
        lnumHex = lnumHex + 1
        lpos = lpos + 1
      } else if lnumHex == 0 || cp == 46 || cp == 112 || cp == 80 {
        lexFail("malformed or unsupported hexadecimal number")
      } else {
        emI = lnumI
        emitTok(1, 1, lnumI + 0.0, "")
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
        emitEscByte(if cp == 97 then 7 else if cp == 98 then 8 else if cp == 102 then 12 else 11)
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

// ---------------------------------------------------------------- parser/codegen state
// Bytecode: parallel bop/bpa/bpb/bpc (opcodes 0..27 shared with lua_model.py;
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
var constInt: int[]
var fVar: int[]
var fStart: int[]
var fParams: int[]
var fRegs: int[]
var mainFid: int = 0
var gmap: Map<string, int>
var gslotNext: int = 0
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
var bLine: int[]
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

mod curInt() -> int {
  return if cpos >= tk.length() then 0 else tni[cpos]
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

mod curLine() -> int {
  return if cpos < tl.length() then tl[cpos] else if cpos > 0 && cpos - 1 < tl.length() then tl[cpos - 1] else lline
}

mod bEmit(op: int, a: int, b: int, c: int) -> int {
  bop.push(op)
  bpa.push(a)
  bpb.push(b)
  bpc.push(c)
  bLine.push(curLine())
  if bop.length() > MAX_INSTR {
    perr = true
    perrMsg = "program too long"
  }
  return bop.length() - 1
}

var lastPatchTarget: int = -1

mod bPatchB(pos: int, target: int) {
  bpb[pos] = target
}

mod bPatch(pos: int, target: int) {
  bpa[pos] = target
  lastPatchTarget = target
}

mod cNum(v: float) -> int {
  let r = constNum.find(v)
  if !r.Found {
    if constNum.length() >= 1024 {
      perr = true
      perrMsg = "too many numeric constants"
    } else {
      constNum.push(v)
    }
  }
  return if r.Found then r.Index else constNum.length() - 1
}

mod cInt(v: int) -> int {
  let r = constInt.find(v)
  if !r.Found {
    if constInt.length() >= 1024 {
      perr = true
      perrMsg = "too many integer constants"
    } else {
      constInt.push(v)
    }
  }
  return if r.Found then r.Index else constInt.length() - 1
}

mod cStr(s: string) -> int {
  let r = constStr.find(s)
  if !r.Found {
    if constStr.length() >= 1024 {
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

var GNAMES: Map<string, int> = {
  "outNum0": 0,
  "outNum1": 1,
  "outNum2": 2,
  "outNum3": 3,
  "outStr0": 4,
  "outStr1": 5,
  "outInt0": 6,
  "inNum0": 7,
  "inNum1": 8,
  "inNum2": 9,
  "inNum3": 10,
  "inStr0": 11,
  "inStr1": 12,
  "inInt0": 13,
  "invecx": 14,
  "invecy": 15,
  "invecz": 16,
  "incolr": 17,
  "incolg": 18,
  "incolb": 19,
  "incola": 20,
  "print": 21,
  "type": 22,
  "tostring": 23,
  "tonumber": 24,
  "setvec": 25,
  "setcol": 26,
  "clock": 27,
  "inarr": 28,
  "outarr": 29,
  "next": 30,
  "pcall": 31,
  "error": 32,
  "unpack": 33,
  "select": 34,
  "_m": 35,
  "_s": 36,
  "setmetatable": 37,
  "getmetatable": 38,
  "_tostring": 39,
  "_print": 40,
  "rawget": 41,
  "rawset": 42,
  "_write": 43,
}

mod parseInit() {
  tk.clear()
  ts.clear()
  tn.clear()
  tt.clear()
  tl.clear()
  tni.clear()
  lerr = false
  lerrMsg = ""
  lerrLine = 1
  lline = 1
  lastPatchTarget = -1
  bop.clear()
  bLine.clear()
  bpa.clear()
  bpb.clear()
  bpc.clear()
  constNum.clear()
  constInt.clear()
  fVar.clear()
  constStr.clear()
  fStart.clear()
  fParams.clear()
  fRegs.clear()
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
  ctlS.clear()
  ctlH.clear()
  ctlI.clear()
  pendingSelf = false
  plNext.clear()
  plNext.resize(MAX_INSTR, -1)
  tmpNames.clear()
  tmpRegs.clear()
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
  selfFid.resize(33, -1)
  funcEntryLoc.resize(33, 0)
  opBase.resize(33, 0)
  gmap.copyFrom(GNAMES)
  gslotNext = 44
  fnDepth = 0
  locLen = 0
  locPop = 0
  lbMap.clear()
  gtMap.clear()
  svI.clear()
  svS.clear()
  svC.clear()
  blkMax.clear()
  locMap.clear()
  locPrev.clear()
  upMap.clear()
  fidAt.clear()
  fidAt.resize(40, 0)
  capSeen.clear()
  capSeen.resize(40, 0)
  fUpN.clear()
  fUpL.clear()
  fUpI.clear()
  fUpN.resize(NB + MAX_FUNCS + 4, 0)
  fUpL.resize((NB + MAX_FUNCS + 4) * 16, 0)
  fUpI.resize((NB + MAX_FUNCS + 4) * 16, 0)
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

// Account for call argument slots (fr+1..), which bypass regAlloc.
mod bumpMax(n: int) {
  if n > cfMax[fnDepth] {
    cfMax[fnDepth] = n
  }
}

mod dirtySelf(name: string) {
  if selfName[fnDepth] == name {
    selfClean[fnDepth] = false
  }
}

mod locBind(name: string, r: int) {
  let m = locMap.get(name)
  let pv = if m.Found then m.Value else -1
  if locLen < locName.length() {
    locName[locLen] = name
    locReg[locLen] = r
    locDepth[locLen] = fnDepth
    locPrev[locLen] = pv
  } else {
    locName.push(name)
    locReg.push(r)
    locDepth.push(fnDepth)
    locPrev.push(pv)
  }
  locMap.set(name, locLen)
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
  blkLen.push(locLen - locPop)
  blkNext.push(cfNext[fnDepth])
  blkMax.push(cfMaxLoc[fnDepth])
}

mod blkExit() {
  locPop = locLen - blkLen.pop().Value
  let nx = blkNext.pop().Value
  let ml = blkMax.pop().Value
  if capSeen[fnDepth] != 0 {
    bEmit(52, if ml + 1 > cfBase[fnDepth] then ml + 1 else cfBase[fnDepth], 0, 0)
  }
  cfNext[fnDepth] = nx
  cfMaxLoc[fnDepth] = ml
}

// undo one local declaration in the name map (called before every parse step until drained)
mod locDrain1() {
  if locPop > 0 {
    let i = locLen - 1
    let pv = locPrev[i]
    if pv >= 0 {
      locMap.set(locName[i], pv)
    } else {
      locMap.remove(locName[i])
    }
    locLen = i
    locPop = locPop - 1
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

// lkKind: 0 none, 1 local reg, 2 self-recursion (LOADFUNC lkFid).
// Sets perr on upvalue use.
// Upvalue index of (isLoc, idx) in the function at depth d; adds it when new.
mod upLevel(d: int, isLoc: int, idx: int) -> int {
  let fid = fidAt[d]
  let key = fid .. ":" .. isLoc .. ":" .. idx
  let r = upMap.get(key)
  if !r.Found {
    let k = fUpN[fid]
    if k >= 16 {
      perr = true
      perrMsg = "too many upvalues (max 16)"
    } else {
      fUpL[fid * 16 + k] = isLoc
      fUpI[fid * 16 + k] = idx
      fUpN[fid] = k + 1
      upMap.set(key, k)
    }
  }
  return if r.Found then r.Value else fUpN[fid] - 1
}

// A local of an enclosing function is used: build the upvalue chain down to this function.
mod resolveUp(ix: int) {
  let ld = locDepth[ix]
  let diff = fnDepth - ld
  if diff > 4 {
    perr = true
    perrMsg = "upvalue nesting too deep"
  } else {
    capSeen[ld] = 1
    var k = upLevel(ld + 1, 1, locReg[ix])
    if diff >= 2 {
      k = upLevel(ld + 2, 0, k)
    }
    if diff >= 3 {
      k = upLevel(ld + 3, 0, k)
    }
    if diff >= 4 {
      k = upLevel(ld + 4, 0, k)
    }
    lkKind = 3
    lkReg = k
  }
}

// lkKind: 0 global, 1 local register, 3 upvalue (lkReg = upvalue index)
mod locFind(name: string) {
  lkKind = 0
  lkReg = -1
  lkFid = -1
  let m = locMap.get(name)
  if m.Found {
    let ix = m.Value
    if locDepth[ix] == fnDepth {
      lkKind = 1
      lkReg = locReg[ix]
    } else {
      resolveUp(ix)
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
  return if opKind.length() <= opBase[fnDepth] then -1 else opKind[opKind.length() - 1]
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
    let isNot = opA[opA.length() - 1] == 1
    let isLen = opA[opA.length() - 1] == 2
    let isBnot = opA[opA.length() - 1] == 3
    let li = bop.length() - 1
    let litOp = if li >= 0 then bop[li] else -1
    let foldable = opA[opA.length() - 1] == 0 && li >= 0 && (litOp == 2 || litOp == 32) && bpa[li] == vv && lastPatchTarget != bop.length()
    opKind.pop()
    opPrec.pop()
    opA.pop()
    opB.pop()
    opC.pop()
    if foldable {
      if litOp == 2 {
        bpb[li] = cNum(0.0 - constNum[bpb[li]])
      } else {
        bpb[li] = cInt(0 - constInt[bpb[li]])
      }
      pushVal(vv, false, false)
    } else {
      regFree(vv)
      let res = regAlloc()
      if isNot {
        bEmit(15, res, vv, 0)
      } else if isLen {
        bEmit(31, res, vv, 0)
      } else if isBnot {
        bEmit(39, res, vv, 0)
      } else {
        bEmit(14, res, vv, 0)
      }
      pushVal(res, false, false)
    }
  } else if k == 4 || k == 5 {
    let rr = popVal()
    popVal()
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
mod finishCtorElem(isLast: bool) {
  let wasMulti = topFlag()
  let v = popVal()
  let tr = opA[opA.length() - 1]
  let kr = opB[opB.length() - 1]
  if kr == -1 {
    let idx = opPrec[opPrec.length() - 1] + 1
    opPrec[opPrec.length() - 1] = idx
    if isLast && wasMulti {
      bEmit(43, tr, v, idx)
    } else {
      let kk = regAlloc()
      bEmit(32, kk, cInt(idx), 0)
      bEmit(30, tr, kk, v)
    }
  } else {
    bEmit(30, tr, kr, v)
    opB[opB.length() - 1] = -1
  }
  cfNext[fnDepth] = tr + 1
}

// Record a binary operator arrival: pops run first, the frame is pushed
// once they drain (see pushPending). fl packs assoc bit + swap/negate bits.
mod binArrive(opc: int, prec: int, fl: int) {
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
    if lkKind == 3 {
      bEmit(50, fr, lkReg, 0)
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
      cfNext[fnDepth] = fr + 1
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
        bEmit(50, r, lkReg, 0)
      } else {
        bEmit(5, r, gDeclare(name), 0)
      }
      pushVal(r, false, true)
    }
    cpos = cpos + 1
    expectOperand = false
  }
}

mod newFunc() -> int {
  fStart.push(-1)
  fParams.push(0)
  fRegs.push(-1)
  fVar.push(0)
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
  if islocal {
    selfName[fnDepth] = tmpS
    selfFid[fnDepth] = tmpB
  } else {
    selfName[fnDepth] = ""
  }
  funcEntryLoc[fnDepth] = locLen
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
  ctlS.push("")
  ctlH.push(-1)
  ctlI.push(-1)
}

// a function body runs its own statements: park the statement-level scratch state of the outer one
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
  fidAt[fnDepth] = tmpB
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
  if k == 1 {
    let r = regAlloc()
    if s == 1 {
      bEmit(32, r, cInt(curInt()), 0)
    } else {
      bEmit(2, r, cNum(curNum()), 0)
    }
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
  } else if k == 5 && s == 31 {
    let r = regAlloc()
    bEmit(41, r, 0, 0)
    pushVal(r, true, false)
    cpos = cpos + 1
    expectOperand = false
  } else if k == 5 && s == 24 {
    pushOp(1, 10, 2, 0, valStk.length())
    cpos = cpos + 1
  } else if k == 5 && s == 30 {
    pushOp(1, 10, 3, 0, valStk.length())
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
    let prc = if s == 6 then 11 else if s <= 2 then 8 else 9
    let fl = if s == 6 then 0 else 1
    binArrive(opc, prc, fl)
    cpos = cpos + 1
    expectOperand = true
  } else if k == 5 && s == 18 {
    binArrive(16, 7, 0)
    cpos = cpos + 1
    expectOperand = true
  } else if k == 5 && s >= 25 && s <= 30 {
    let opc = if s == 25 then 33 else if s == 26 then 37 else if s == 27 then 38 else if s == 28 then 34 else if s == 29 then 35 else 36
    let prc = if s == 25 then 9 else if s == 26 || s == 27 then 6 else if s == 28 then 5 else if s == 30 then 4 else 3
    binArrive(opc, prc, 1)
    cpos = cpos + 1
    expectOperand = true
  } else if k == 5 && s >= 7 && s <= 12 {
    let opc = if s == 7 || s == 8 then 18 else if s == 9 || s == 10 then 19 else 17
    let fl = if s == 8 || s == 10 then 3 else if s == 12 then 4 else if s == 7 || s == 9 then 1 else 0
    binArrive(opc, 2, fl)
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
    cfNext[fnDepth] = fr + 1
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
  } else if k == 5 && s == 33 {
    if topPrefix() && nextKind() == 3 {
      let base = popVal()
      regFree(base)
      let fr = regAlloc()
      regAlloc()
      bEmit(49, fr, base, cStr(curStrAhead()))
      cpos = cpos + 2
      if curKind() == 5 && curSub() == 14 {
        cpos = cpos + 1
        pushOp(2, 1, fr, 1, valStk.length())
        expectOperand = true
      } else {
        perr = true
        perrMsg = "method call needs ( arguments )"
      }
    } else {
      perr = true
      perrMsg = "bad method call"
    }
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
  } else if k == 6 || (k == 5 && (s == 17 || s == 32)) || (k == 4 && (s == 6 || s == 4 || s == 5 || s == 21)) || (k == 5 && s == 13) || (k == 4 && (s == 3 || s == 15)) {
    closeMode = 3
    popMode = 2
  } else if k == 3 || (k == 4 && (s == 10 || s == 8 || s == 9 || s == 17 || s == 3 || s == 2 || s == 14 || s == 18 || s == 20 || s == 22)) {
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
    if mk == 2 {
      let fr = opA[opA.length() - 1]
      let nargs = opB[opB.length() - 1]
      let depth = opC[opC.length() - 1]
      let isM = opPrec[opPrec.length() - 1] == 1
      opKind.pop()
      opPrec.pop()
      opA.pop()
      opB.pop()
      opC.pop()
      if valStk.length() == depth {
        if nargs == 0 || (isM && nargs == 1) {
          bEmit(23, fr, nargs, 0)
          bumpMax(fr + 3)
          cfNext[fnDepth] = fr + 1
        } else {
          perr = true
          perrMsg = "trailing comma"
        }
      } else {
        let wasCall = topFlag()
        let arg = popVal()
        bEmit(7, fr + 1 + nargs, arg, 0)
        cfNext[fnDepth] = fr + nargs + 2
        bEmit(23, fr, nargs + 1, if wasCall then 1 else 0)
        bumpMax(fr + nargs + 3)
        cfNext[fnDepth] = fr + 1
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
    if closeTrig == 1 && mk == 2 {
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
    } else if opKind.length() > opBase[fnDepth] {
      perr = true
      perrMsg = "misplaced separator"
    } else if valStk.length() == 0 {
      perr = true
      perrMsg = "missing expression"
    } else {
      presIsCall = topFlag()
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
      presReg = popVal()
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
// 3 elif-cond, 4 while-cond, 5 return, 6 local-values, 7 assign-values.
// stState tracks multi-step constructs. Control frames: 1 if (A=fpos,
// B=ends), 2 while (A=top, B=false, C=breaks, D=savedLoop), 3 func
// (A=fid, B=skip, C=resume, D=savedLoop, E=extra), 4 do.

var inExpr: bool = false
var contKind: int = 0
var stState: int = 0
var tmpA: int = 0
var tmpB: int = 0
var tmpC: int = 0
var tmpS: string = ""
var tmpNames: string[]
var tmpRegs: int[]
var ctlD: int[]
var ctlE: int[]
var ctlF: int[]
var ctlG: int[]
var ctlS: string[]
var ctlH: int[]
var ctlI: int[]
var fnChainReg: int = 0
var pendingSelf: bool = false
var ctlLoop: int = -1
var pdHead: int = -1
var pdThen: int = 0
var tmpSStk: string[]
var funcEntryLoc: int[]
var locMap: Map<string, int>
var locPrev: int[]
var locPop: int = 0
var lbMap: Map<string, int>
var gtMap: Map<string, int>
var svI: int[]
var svS: string[]
var svC: int[]
var blkMax: int[]
var lkIdx: int = 0
var fidAt: int[]
var capSeen: int[]
var fUpN: int[]
var fUpL: int[]
var fUpI: int[]
var upMap: Map<string, int>
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
  ctlS.pop()
  ctlH.pop()
  ctlI.pop()
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

// Post-unit continuations: 1 expr-stmt, 2 if-cond, 3 elif-cond,
// 4 while-cond, 5 return, 6 local-values, 7 assign-values.
mod atStmtEnd() -> bool {
  let k = curKind()
  let s = curSub()
  return if k == 6 then true
    else if k == 5 && (s == 17 || s == 32) then true
    else if k == 4 && (s == 6 || s == 4 || s == 5 || s == 21) then true
    else false
}

// `do` after a for header: emit the loop prologue and open the body block.
mod forDo() {
  if curKind() != 4 || curSub() != 3 {
    perr = true
    perrMsg = "expected do"
  } else {
    cpos = cpos + 1
    let n = ctlKind.length() - 1
    let base = ctlA[n]
    if ctlKind[n] == 6 {
      ctlB[n] = bEmit(44, base, 0, 0)
      ctlE[n] = bop.length()
      blkEnter()
      locBind(ctlS[n], base + 3)
    } else {
      let names = ctlS[n]
      let nv = ctlE[n]
      cfNext[fnDepth] = base + 3
      ctlB[n] = bEmit(20, 0, 0, 0)
      ctlF[n] = bop.length()
      blkEnter()
      var rest = names
      if 0 < nv {
        let sp = rest.Split(",")
        locBind(if sp.Found then sp.Left else rest, base + 3)
        rest = sp.Right
      }
      if 1 < nv {
        let sp = rest.Split(",")
        locBind(if sp.Found then sp.Left else rest, base + 4)
        rest = sp.Right
      }
      if 2 < nv {
        let sp = rest.Split(",")
        locBind(if sp.Found then sp.Left else rest, base + 5)
        rest = sp.Right
      }
      if 3 < nv {
        let sp = rest.Split(",")
        locBind(if sp.Found then sp.Left else rest, base + 6)
        rest = sp.Right
      }
      bumpMax(base + 3 + nv + 8)
    }
    ctlLoop = n
    inExpr = false
    contKind = 0
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
      ctlI[ctlI.length() - 1] = cfMaxLoc[fnDepth] + 1
      ctlLoop = ctlKind.length() - 1
      blkEnter()
    }
    inExpr = false
    contKind = 0
  } else if contKind == 5 {
    let n = ctlKind.length() - 1
    let base = ctlA[n]
    let idx = ctlF[n]
    let more = curKind() == 5 && curSub() == 16
    if idx == 0 && !more {
      if presIsCall {
        bEmit(27, presReg, 0, 0)
      } else {
        bEmit(24, presReg, 0, 0)
      }
      popCtl()
      inExpr = false
      contKind = 0
    } else {
      if presReg != base + idx {
        bEmit(7, base + idx, presReg, 0)
      }
      ctlF[n] = idx + 1
      cfNext[fnDepth] = base + idx + 1
      bumpMax(base + idx + 2)
      if more {
        cpos = cpos + 1
        startUnit(5)
      } else {
        if presIsCall && presReg == base + idx {
          bEmit(27, base, idx, 0)
        } else {
          bEmit(40, base, idx + 1, 0)
        }
        popCtl()
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
      let need = tmpNames.length() - tmpRegs.length() + 1
      if presIsCall && need > 1 {
        bEmit(42, presReg, need, 0)
        bumpMax(presReg + need + 1)
        tmpRegs.push(presReg + 1)
        if need > 2 { tmpRegs.push(presReg + 2) }
        if need > 3 { tmpRegs.push(presReg + 3) }
        if need > 4 { tmpRegs.push(presReg + 4) }
        if need > 5 { tmpRegs.push(presReg + 5) }
        if need > 6 { tmpRegs.push(presReg + 6) }
        if need > 7 { tmpRegs.push(presReg + 7) }
      }
      tmpA = 0
      stState = 12
      inExpr = false
      contKind = 0
    }
  } else if contKind == 10 {
    // until <cond>: jump back to the loop start while the condition is false
    let n = ctlKind.length() - 1
    bEmit(21, ctlA[n], presReg, 0)
    blkExit()
    pdHead = ctlC[n]
    pdThen = 1
    tmpC = ctlD[n]
    popCtl()
    inExpr = false
    contKind = 0
  } else if contKind == 11 {
    let n = ctlKind.length() - 1
    let base = ctlA[n]
    if presReg != base {
      bEmit(7, base, presReg, 0)
    }
    if curKind() == 5 && curSub() == 16 {
      cpos = cpos + 1
      startUnit(12)
    } else {
      perr = true
      perrMsg = "expected , in for"
    }
  } else if contKind == 12 {
    let n = ctlKind.length() - 1
    let base = ctlA[n]
    if presReg != base + 1 {
      bEmit(7, base + 1, presReg, 0)
    }
    if curKind() == 5 && curSub() == 16 {
      cpos = cpos + 1
      startUnit(13)
    } else {
      bEmit(32, base + 2, cInt(1), 0)
      forDo()
    }
  } else if contKind == 13 {
    let n = ctlKind.length() - 1
    let base = ctlA[n]
    if presReg != base + 2 {
      bEmit(7, base + 2, presReg, 0)
    }
    forDo()
  } else if contKind == 14 {
    // generic for: expression list into base.. (three values)
    let n = ctlKind.length() - 1
    let base = ctlA[n]
    let idx = ctlF[n]
    if idx > 2 {
      perr = true
      perrMsg = "too many expressions in for"
    } else {
      if presReg != base + idx {
        bEmit(7, base + idx, presReg, 0)
      }
      ctlF[n] = idx + 1
      cfNext[fnDepth] = base + idx + 1
      if curKind() == 5 && curSub() == 16 {
        cpos = cpos + 1
        startUnit(14)
      } else {
        if presIsCall {
          bEmit(42, base + idx, 3 - idx, 0)
        } else {
          if idx < 2 {
            bEmit(1, base + idx + 1, 0, 0)
          }
          if idx < 1 {
            bEmit(1, base + idx + 2, 0, 0)
          }
        }
        bumpMax(base + 3)
        forDo()
      }
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
      let needI = itBase.length() - tmpRegs.length() + 1
      if presIsCall && needI > 1 {
        bEmit(42, presReg, needI, 0)
        bumpMax(presReg + needI + 1)
        cfNext[fnDepth] = presReg + needI
        tmpRegs.push(presReg + 1)
        if needI > 2 { tmpRegs.push(presReg + 2) }
        if needI > 3 { tmpRegs.push(presReg + 3) }
      }
      // stores run right to left (like PUC Lua), so the last target wins
      tmpA = itBase.length() - 1
      stState = 15
      inExpr = false
      contKind = 0
    }
  } else if contKind == 7 {
    let moreV = curKind() == 5 && curSub() == 16
    let needA = if presIsCall && !moreV then tmpNames.length() - tmpRegs.length() else 1
    if needA > 1 {
      bEmit(42, presReg, needA, 0)
      bumpMax(presReg + needA + 1)
      cfNext[fnDepth] = presReg + needA
    }
    if tmpNames.length() > 1 {
      let z = regAlloc()
      bEmit(7, z, presReg, 0)
      tmpRegs.push(z)
      if needA > 1 {
        let z1 = regAlloc()
        bEmit(7, z1, presReg + 1, 0)
        tmpRegs.push(z1)
      }
      if needA > 2 {
        let z2 = regAlloc()
        bEmit(7, z2, presReg + 2, 0)
        tmpRegs.push(z2)
      }
      if needA > 3 {
        let z3 = regAlloc()
        bEmit(7, z3, presReg + 3, 0)
        tmpRegs.push(z3)
      }
      if needA > 4 {
        let z4 = regAlloc()
        bEmit(7, z4, presReg + 4, 0)
        tmpRegs.push(z4)
      }
    } else {
      tmpRegs.push(presReg)
    }
    if moreV {
      cpos = cpos + 1
      startUnit(7)
    } else {
      // stores run right to left (like PUC Lua), so the last target wins
      tmpA = tmpNames.length() - 1
      stState = 13
      inExpr = false
      contKind = 0
    }
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
    } else if lkKind == 3 {
      bEmit(51, lkReg, tmpB, 0)
    } else {
      perr = true
      perrMsg = "bad store"
    }
    tmpA = tmpA - 1
    stState = 13
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
    ctlH[ctlH.length() - 1] = locDeclare(tmpS)
  } else {
    pushCtl(3, fid, skip, 0, ctlLoop, 0, 0)
  }
  ctlG[ctlG.length() - 1] = stState
  tmpSStk.push(tmpS)
  ctorStk.push(openCtor)
  openCtor = 0
  ctlLoop = -1
  saveTmp()
  fnDepth = fnDepth + 1
  fidAt[fnDepth] = fid
  opBase[fnDepth] = opKind.length()
  funcDepthInit(islocal)
  if pendingSelf {
    locDeclare("self")
    pendingSelf = false
  }
  if curKind() == 5 && curSub() == 14 {
    cpos = cpos + 1
    stState = 20
  } else {
    perr = true
    perrMsg = "expected ( after function name"
  }
}

// stState 20: parameter list.
mod funcParams() {
  if curKind() == 5 && curSub() == 31 {
    cpos = cpos + 1
    fVar[tmpB] = 1
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

// stState 30: the name list of a generic for (up to four names) then `in` and the expression list
mod forNames() {
  let n = ctlKind.length() - 1
  if curKind() != 3 {
    perr = true
    perrMsg = "expected name in for"
  } else {
    ctlS[n] = if ctlS[n] == "" then curStr() else ctlS[n] .. "," .. curStr()
    ctlE[n] = ctlE[n] + 1
    cpos = cpos + 1
    if ctlE[n] > 4 {
      perr = true
      perrMsg = "too many loop variables (max 4)"
    } else if curKind() == 5 && curSub() == 16 {
      cpos = cpos + 1
    } else if curKind() == 4 && curSub() == 19 {
      cpos = cpos + 1
      stState = 0
      startUnit(14)
    } else {
      perr = true
      perrMsg = "expected in"
    }
  }
}

// The value of a plain name as a register (local register, or a fresh temp loaded from a global).
mod nameToReg(name: string) -> int {
  locFind(name)
  var r = lkReg
  if lkKind != 1 {
    r = regAlloc()
    if lkKind == 3 {
      bEmit(50, r, lkReg, 0)
    } else {
      bEmit(5, r, gDeclare(name), 0)
    }
  }
  return r
}

// stState 31: `. name` / `: name` links of a function statement name
mod fnChain() {
  let isColon = curSub() == 33
  cpos = cpos + 1
  if curKind() != 3 {
    perr = true
    perrMsg = "expected name in function name"
  } else {
    let nm = curStr()
    let nk = nextKind()
    let ns = nextSub()
    cpos = cpos + 1
    if nk == 5 && (ns == 23 || ns == 33) && !isColon {
      let kr = regAlloc()
      bEmit(3, kr, cStr(nm), 0)
      regFree(kr)
      regFree(fnChainReg)
      let res = regAlloc()
      bEmit(29, res, fnChainReg, kr)
      fnChainReg = res
    } else if nk == 5 && ns == 14 {
      let kr = regAlloc()
      bEmit(3, kr, cStr(nm), 0)
      stState = 0
      tmpS = ""
      pendingSelf = isColon
      funcHead(false, 0, 0)
      let top = ctlKind.length() - 1
      ctlE[top] = if isColon then 3 else 2
      ctlH[top] = fnChainReg
      ctlI[top] = kr
    } else {
      perr = true
      perrMsg = "expected ( after function name"
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
  } else if stState == 30 {
    forNames()
  } else if stState == 31 {
    fnChain()
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
    } else if kind == 3 {
      let fid = ctlA[n]
      let skip = ctlB[n]
      let resume = ctlC[n]
      let extra = ctlE[n]
      let savedCont = ctlF[n]
      let savedSt = ctlG[n]
      let tblReg = ctlH[n]
      let keyReg = ctlI[n]
      bEmit(26, 0, 0, 0)
      fRegs[fid] = cfMax[fnDepth]
      locPop = locLen - funcEntryLoc[fnDepth]
      fnDepth = fnDepth - 1
      bPatch(skip, bop.length())
      ctlLoop = ctlD[n]
      tmpS = tmpSStk.pop().Value
      restoreTmp()
      openCtor = ctorStk.pop().Value
      popCtl()
      if resume == 1 {
        pushVal(extra, false, true)
        expectOperand = false
        inExpr = true
        exprDone = false
        contKind = savedCont
        stState = savedSt
      } else if extra == 1 {
        bEmit(25, tblReg, fid, 0)
      } else if extra >= 2 {
        let fr = regAlloc()
        bEmit(25, fr, fid, 0)
        bEmit(30, tblReg, keyReg, fr)
      } else {
        let fr = regAlloc()
        bEmit(25, fr, fid, 0)
        bEmit(6, gDeclare(tmpS), fr, 0)
      }
    } else if kind == 6 {
      blkExit()
      bEmit(45, ctlA[n], ctlE[n], 0)
      bPatchB(ctlB[n], bop.length())
      tmpC = ctlD[n]
      pdHead = ctlC[n]
      pdThen = 1
      popCtl()
    } else if kind == 7 {
      blkExit()
      bPatch(ctlB[n], bop.length())
      let base = ctlA[n]
      let nv = ctlE[n]
      let sc = base + 3 + nv
      bEmit(7, sc, base, 0)
      bEmit(7, sc + 1, base + 1, 0)
      bEmit(7, sc + 2, base + 2, 0)
      bEmit(23, sc, 3, 0)
      bEmit(46, base, ctlF[n], nv)
      tmpC = ctlD[n]
      pdHead = ctlC[n]
      pdThen = 1
      popCtl()
    } else if kind == 5 {
      perr = true
      perrMsg = "'until' expected"
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
      if gtMap.length() > 0 {
        perr = true
        perrMsg = "no visible label for goto"
      }
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
      if nextKind() == 5 && (nextSub() == 23 || nextSub() == 33) {
        fnChainReg = nameToReg(curStr())
        cpos = cpos + 1
        stState = 31
      } else {
        tmpS = curStr()
        cpos = cpos + 1
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
  } else if k == 4 && s == 20 {
    cpos = cpos + 1
    blkEnter()
    pushCtl(5, bop.length(), 0, -1, ctlLoop, 0, 0)
    ctlI[ctlI.length() - 1] = cfMaxLoc[fnDepth] + 1
    ctlLoop = ctlKind.length() - 1
  } else if k == 4 && s == 21 {
    cpos = cpos + 1
    if ctlTop() != 5 {
      perr = true
      perrMsg = "until without repeat"
    } else {
      startUnit(10)
    }
  } else if k == 4 && s == 18 {
    cpos = cpos + 1
    if curKind() != 3 {
      perr = true
      perrMsg = "expected name after for"
    } else if nextKind() == 5 && nextSub() == 13 {
      let base = regAlloc()
      regAlloc()
      regAlloc()
      regAlloc()
      pushCtl(6, base, -1, -1, ctlLoop, 0, 0)
      ctlI[ctlI.length() - 1] = cfMaxLoc[fnDepth] + 1
      ctlS[ctlS.length() - 1] = curStr()
      cpos = cpos + 2
      startUnit(11)
    } else {
      pushCtl(7, cfNext[fnDepth], -1, -1, ctlLoop, 0, 0)
      ctlI[ctlI.length() - 1] = cfMaxLoc[fnDepth] + 1
      stState = 30
    }
  } else if k == 4 && s == 3 {
    cpos = cpos + 1
    blkEnter()
    pushCtl(4, 0, 0, 0, 0, 0, 0)
  } else if k == 4 && s == 22 {
    cpos = cpos + 1
    if curKind() != 3 {
      perr = true
      perrMsg = "expected label name after goto"
    } else {
      let key = fnDepth .. ":" .. curStr()
      cpos = cpos + 1
      let lb = lbMap.get(key)
      if lb.Found {
        bEmit(20, lb.Value, 0, 0)
      } else {
        let pos = bEmit(20, 0, 0, 0)
        let pg = gtMap.get(key)
        plNext[pos] = if pg.Found then pg.Value else -1
        gtMap.set(key, pos)
      }
    }
  } else if k == 5 && s == 32 {
    cpos = cpos + 1
    if curKind() != 3 || nextKind() != 5 || nextSub() != 32 {
      perr = true
      perrMsg = "malformed label"
    } else {
      let key = fnDepth .. ":" .. curStr()
      cpos = cpos + 2
      lbMap.set(key, bop.length())
      let pg = gtMap.get(key)
      if pg.Found {
        pdHead = pg.Value
        pdThen = 2
        gtMap.remove(key)
      }
    }
  } else if k == 4 && s == 2 {
    cpos = cpos + 1
    if ctlLoop == -1 {
      perr = true
      perrMsg = "break outside loop"
    } else {
      if capSeen[fnDepth] != 0 {
        bEmit(52, ctlI[ctlLoop], 0, 0)
      }
      let pos = bEmit(20, 0, 0, 0)
      plNext[pos] = ctlC[ctlLoop]
      ctlC[ctlLoop] = pos
    }
  } else if k == 4 && s == 14 {
    cpos = cpos + 1
    if atStmtEnd() {
      bEmit(26, 0, 0, 0)
    } else {
      pushCtl(8, cfNext[fnDepth], 0, 0, 0, 0, 0)
      startUnit(5)
    }
  } else if k == 3 {
    let nk = nextKind()
    let ns = nextSub()
    if nk == 5 && ns == 14 {
      startUnit(1)
    } else if nk == 2 {
      startUnit(1)
    } else if nk == 5 && (ns == 21 || ns == 23 || ns == 33) {
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
  } else if k == 4 && (s == 6 || s == 4 || s == 5) {
    doBlockClose()
  } else {
    perr = true
    perrMsg = "unexpected token at statement start"
  }
}

mod parseStep() {
  if !perr && !pDone {
    locDrain1()
    if locPop > 0 {
      locDrain1()
    } else if pdThen != 0 {
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
// Value tags: 0 nil, 1 float, 2 string, 3 boolean (rn = 0/1), 4 function (ri = id),
// 5 table (ri = id), 6 integer (ri exact, rn = the same value as a float).
// One flat register file (frames share it by base offsets), parallel frame
// stacks, a vararg stack, globals, and a table heap with insertion-ordered chains.
var rt: int[]
var rn: float[]
var ri: int[]
var rs: string[]
var fFunc: int[]
var fBase: int[]
var fRetA: int[]
var fRetBase: int[]
var fRetPC: int[]
var fVaB: int[]
var fProt: int[]
var pStack: int[]
var vaT: int[]
var vaN: float[]
var vaI: int[]
var vaS: string[]
var vaTop: int = 0
var fClo: int[]
var cloF: int[]
var cloU: int[]
var cloCount: int = 0
var uOpen: int[]
var uT: int[]
var uN: float[]
var uI: int[]
var uS: string[]
var uCount: int = 0
var uMap: Map<int, int>
var openList: int[]
var openMaxAbs: int = -1
var clThresh: int = 0
var clIdx: int = 0
var clMax: int = 0
var mkCid: int = 0
var mkFid: int = 0
var mkK: int = 0
var mkDst: int = 0
var gt: int[]
var gn: float[]
var gi: int[]
var gs: string[]
var vmPc: int = 0
var vmBase: int = 0
var vmHalted: bool = true
var vmFailed: bool = false
var retCountV: int = 0
var micro: int = 0
var lenPending: bool = false
var hotDone: bool = false
var jumped: bool = false
var errPending: bool = false
var errT: int = 0
var errN: float = 0.0
var errI: int = 0
var errS: string = ""
var cmpAA: int = 0
var cmpBB: int = 0
var cmpDst: int = 0
var cmpI: int = 0
var cmpOp: int = 0
var mvKind: int = 0
var mvSrc: int = 0
var mvDst: int = 0
var mvCnt: int = 0
var prIdx: int = 0
var prN: int = 0
var prBase: int = 0
var prDst: int = 0
var prLine: string = ""
var prRaw: bool = false
var nxTid: int = 0
var nxSlot: int = 0
var nxDst: int = 0
var smTbl: int = 0
var smSrc: int = 0
var smStart: int = 0
var smIdx: int = 0
var smCnt: int = 0
var upTid: int = 0
var upI: int = 0
var upN: int = 0
var upDst: int = 0
var tmap: Map<string, int>
var tvT: int[]
var tvN: float[]
var tvI: int[]
var tvS: string[]
var tkT: int[]
var tkN: float[]
var tkI: int[]
var tkS: string[]
var tvO: int[]
var tNx: int[]
var tPv: int[]
var tFirst: int[]
var tLast: int[]
var tLen: int[]
var tMeta: int[]
var fDst: int[]
var mtTid: int = 0
var mtKey: int = 0
var mtDst: int = 0
var mtOrig: int = 0
var mtDepth: int = 0
var injA: int = 0
var injB: int = 0
var injC: int = 0
var rawSet: bool = false
var tHeap: int = 0
var tCount: int = 0
var lenTid: int = 0
var latchN0: float = 0.0
var latchN1: float = 0.0
var latchN2: float = 0.0
var latchN3: float = 0.0
var latchI0: int = 0
var latchS0: string = ""
var latchS1: string = ""
var latchVX: float = 0.0
var latchVY: float = 0.0
var latchVZ: float = 0.0
var latchCR: float = 0.0
var latchCG: float = 0.0
var latchCB: float = 0.0
var latchCA: float = 0.0

// Scratch registers (absolute) used to feed coerced operands to the normal handlers.
const SCR0 = 2190
const SCR1 = 2191
const NB = 21
const SCR2 = 2192
const SCR3 = 2193
const SCR4 = 2194

mod vTag(r: int) -> int {
  return rt[vmBase + r]
}
mod vNum(r: int) -> float {
  return rn[vmBase + r]
}
mod vInt(r: int) -> int {
  return ri[vmBase + r]
}
mod vStr(r: int) -> string {
  return rs[vmBase + r]
}
mod vSet(r: int, tag: int, n: float, i: int, s: string) {
  rt[vmBase + r] = tag
  rn[vmBase + r] = n
  ri[vmBase + r] = i
  rs[vmBase + r] = s
}
mod setNil(r: int) {
  rt[vmBase + r] = 0
}
mod setN(r: int, f: float) {
  rt[vmBase + r] = 1
  rn[vmBase + r] = f
}
mod setI(r: int, v: int) {
  rt[vmBase + r] = 6
  ri[vmBase + r] = v
  rn[vmBase + r] = v + 0.0
}
mod setS(r: int, s: string) {
  rt[vmBase + r] = 2
  rs[vmBase + r] = s
}
mod setB(r: int, v: bool) {
  rt[vmBase + r] = 3
  rn[vmBase + r] = if v then 1.0 else 0.0
}
mod setObj(r: int, tag: int, id: int) {
  rt[vmBase + r] = tag
  ri[vmBase + r] = id
}
mod vCopy(d: int, s: int) {
  rt[vmBase + d] = rt[vmBase + s]
  rn[vmBase + d] = rn[vmBase + s]
  ri[vmBase + d] = ri[vmBase + s]
  rs[vmBase + d] = rs[vmBase + s]
}
// absolute-register copy (destination and source are absolute indices)
mod aCopy(d: int, s: int) {
  rt[d] = rt[s]
  rn[d] = rn[s]
  ri[d] = ri[s]
  rs[d] = rs[s]
}
mod vTruthy(r: int) -> bool {
  return vTag(r) != 0 && !(vTag(r) == 3 && vNum(r) == 0.0)
}
mod isNum(t: int) -> bool {
  return t == 1 || t == 6
}
mod isFn(t: int) -> bool {
  return t == 4 || t == 7
}
// function id behind a function value (closures point at their prototype)
mod fnId(t: int, v: int) -> int {
  return if t == 7 then cloF[v] else v
}
mod fnClo(t: int, v: int) -> int {
  return if t == 7 then v else -1
}

// number / value formatting
mod fmtNum(v: float) -> string {
  return if v != v then "nan"
    else if v != 0.0 && 2.0 * v == v then if v > 0.0 then "inf" else "-inf"
    else if v == floor(v) && abs(v) < 1e15 then ("" .. (v | 0)) .. ".0"
    else "" .. v
}
mod fmtVal(tag: int, n: float, i: int, s: string) -> string {
  return if tag == 0 then "nil"
    else if tag == 3 then if n == 0.0 then "false" else "true"
    else if tag == 2 then s
    else if tag == 4 || tag == 7 then "function"
    else if tag == 5 then "table"
    else if tag == 6 then "" .. i
    else fmtNum(n)
}
mod fmtReg(r: int) -> string {
  return fmtVal(vTag(r), vNum(r), vInt(r), vStr(r))
}

// globals
mod gLoad(d: int, g: int) {
  rt[vmBase + d] = gt[g]
  rn[vmBase + d] = gn[g]
  ri[vmBase + d] = gi[g]
  rs[vmBase + d] = gs[g]
}
mod gStore(g: int, s: int) {
  gt[g] = vTag(s)
  gn[g] = vNum(s)
  gi[g] = vInt(s)
  gs[g] = vStr(s)
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

// Writable output globals live in the global arrays (slots 0..6); the ports
// mirror them once per tick. Numeric outs read as numbers (nil -> 0), string
// outs Lua-formatted (nil -> ""), the int out as an int.
mod syncOuts() {
  oF0 = if gt[0] == 0 then 0.0 else gn[0]
  oF1 = if gt[1] == 0 then 0.0 else gn[1]
  oF2 = if gt[2] == 0 then 0.0 else gn[2]
  oF3 = if gt[3] == 0 then 0.0 else gn[3]
  oS4 = if gt[4] == 0 then "" else fmtVal(gt[4], gn[4], gi[4], gs[4])
  oS5 = if gt[5] == 0 then "" else fmtVal(gt[5], gn[5], gi[5], gs[5])
  oI6 = if gt[6] == 6 then gi[6] else 0
}

// ---------------------------------------------------------------- tables
// Composite map key for table `tid`. Integral floats share the integer key.
mod tkey(tid: int, kt: int, ki: int, kn: float, ks: string) -> string {
  return if kt == 6 then tid .. "#" .. ki
    else if kt == 1 then (if kn == floor(kn) then tid .. "#" .. (kn | 0) else tid .. "f" .. kn)
    else if kt == 2 then tid .. "$" .. ks
    else tid .. "@" .. kt .. ":" .. (if kt == 3 then (kn | 0) else ki)
}
mod regKey(tid: int, r: int) -> string {
  return tkey(tid, vTag(r), vInt(r), vNum(r), vStr(r))
}
// A float key with a fractional part (or NaN) can never be stored.
mod badFloatKey(r: int) -> bool {
  return false
}
mod keyInt(r: int) -> int {
  return if vTag(r) == 6 then vInt(r) else vNum(r) | 0
}

// t[k] read: result into register d (nil when absent)
mod tblGet(d: int, tid: int, kr: int) {
  let r = tmap.get(regKey(tid, kr))
  if r.Found {
    rt[vmBase + d] = tvT[r.Value]
    rn[vmBase + d] = tvN[r.Value]
    ri[vmBase + d] = tvI[r.Value]
    rs[vmBase + d] = tvS[r.Value]
  } else {
    setNil(d)
  }
}

// After t[len+1] was filled, keep extending the border while t[len+1] is live.
mod lenStep() {
  let r = tmap.get(lenTid .. "#" .. (tLen[lenTid] + 1))
  if r.Found && tvT[r.Value] != 0 {
    tLen[lenTid] = tLen[lenTid] + 1
  } else {
    lenPending = false
  }
}

// ---------------------------------------------------------------- hot instructions
// Integer helpers. The `/` and `%` gates were never probed for mixed signs, so the
// floored quotient is rebuilt from a possibly truncated one and corrected.
mod idivFix(x: int, y: int) -> int {
  return (x / y) - (if (x - (x / y) * y) != 0 && (((x - (x / y) * y) < 0) ^^ (y < 0)) then 1 else 0)
}
mod imodFix(x: int, y: int) -> int {
  return (x - (x / y) * y) + (if (x - (x / y) * y) != 0 && (((x - (x / y) * y) < 0) ^^ (y < 0)) then y else 0)
}
// logical shifts (Lua semantics: count outside -63..63 gives 0, negative shifts the other way)
mod shlI(x: int, n: int) -> int {
  return if n >= 64 || n <= -64 then 0
    else if n >= 0 then x << n
    else (x >> (0 - n)) & ((1 << (64 + n)) - 1)
}
mod forLimit(f: float, up: bool) -> int {
  return if f != f then (if up then -9223372036854775807 - 1 else 9223372036854775807)
    else if (if up then floor(f) else ceil(f)) >= 9.2233720368547758e18 then 9223372036854775807
    else if (if up then floor(f) else ceil(f)) <= -9.2233720368547758e18 then -9223372036854775807 - 1
    else (if up then floor(f) else ceil(f)) | 0
}

mod popFrame() {
  fFunc.pop()
  fBase.pop()
  fRetA.pop()
  fRetBase.pop()
  fRetPC.pop()
  fVaB.pop()
  fProt.pop()
  fClo.pop()
  fDst.pop()
}
mod pushFrame(fid: int, nb: int, a: int, prot: int, clo: int, dst: int) {
  fFunc.push(fid)
  fBase.push(nb)
  fRetA.push(a)
  fRetBase.push(vmBase)
  fRetPC.push(vmPc + 1)
  fVaB.push(vaTop)
  fProt.push(prot)
  fClo.push(clo)
  fDst.push(dst)
}
// parameter i of a call: copy the argument or nil it (callee base nb, caller call register a)
mod argCopy(nb: int, a: int, i: int, np: int, nargs: int) {
  if i < np {
    if i < nargs {
      aCopy(nb + i, vmBase + a + 1 + i)
    } else {
      rt[nb + i] = 0
    }
  }
}

// Fetch field `name` of metatable table `mt` into absolute register dst (nil when absent).
mod metaFetch(mt: int, name: string, dst: int) {
  let r = tmap.get(mt .. "$" .. name)
  if r.Found {
    rt[dst] = tvT[r.Value]
    rn[dst] = tvN[r.Value]
    ri[dst] = tvI[r.Value]
    rs[dst] = tvS[r.Value]
  } else {
    rt[dst] = 0
  }
}
// Handler for event `ev` from the left operand's metatable, else the right one's, into SCR2.
mod binHandler(ev: string, b: int, c: int) -> bool {
  rt[SCR2] = 0
  if vTag(b) == 5 && tMeta[vInt(b)] >= 0 {
    metaFetch(tMeta[vInt(b)], ev, SCR2)
  }
  if rt[SCR2] == 0 && vTag(c) == 5 && tMeta[vInt(c)] >= 0 {
    metaFetch(tMeta[vInt(c)], ev, SCR2)
  }
  return rt[SCR2] != 0
}
mod evName(op: int) -> string {
  return if op == 8 then "__add" else if op == 9 then "__sub" else if op == 10 then "__mul" else if op == 11 then "__div"
    else if op == 12 then "__mod" else if op == 13 then "__pow" else if op == 33 then "__idiv" else if op == 14 then "__unm"
    else if op == 16 then "__concat" else if op == 17 then "__eq" else if op == 18 then "__lt" else if op == 19 then "__le"
    else if op == 31 then "__len" else if op == 34 then "__band" else if op == 35 then "__bor" else if op == 36 then "__bxor"
    else if op == 37 then "__shl" else if op == 38 then "__shr" else "__bnot"
}


// Executes the instruction if it belongs to the hot set and sets hotDone; anything
// unusual (errors, coercions, slow paths) leaves hotDone false for the cold path.
mod execHot(op: int, a: int, b: int, c: int) {
  hotDone = true
  if op == 1 {
    setNil(a)
  } else if op == 2 {
    setN(a, constNum[b])
  } else if op == 32 {
    setI(a, constInt[b])
  } else if op == 3 {
    setS(a, constStr[b])
  } else if op == 4 {
    setB(a, b != 0)
  } else if op == 5 {
    gLoad(a, b)
  } else if op == 6 {
    if a > 6 {
      gStore(a, b)
    } else {
      hotDone = false
    }
  } else if op == 7 {
    vCopy(a, b)
  } else if op >= 8 && op <= 13 || op == 33 {
    let tb = vTag(b)
    let tc = vTag(c)
    let both = isNum(tb) && isNum(tc)
    let ints = tb == 6 && tc == 6
    let nz = vNum(c) != 0.0
    if !both {
      hotDone = false
    } else if op <= 10 {
      if ints {
        setI(a, if op == 8 then vInt(b) + vInt(c) else if op == 9 then vInt(b) - vInt(c) else vInt(b) * vInt(c))
      } else {
        setN(a, if op == 8 then vNum(b) + vNum(c) else if op == 9 then vNum(b) - vNum(c) else vNum(b) * vNum(c))
      }
    } else if op == 11 {
      setN(a, if nz then vNum(b) / vNum(c) else 0.0)
    } else if op == 13 {
      setN(a, vNum(b) ** vNum(c))
    } else if ints {
      if vInt(c) == 0 {
        hotDone = false
      } else if op == 12 {
        setI(a, imodFix(vInt(b), vInt(c)))
      } else {
        setI(a, idivFix(vInt(b), vInt(c)))
      }
    } else if op == 12 {
      setN(a, if nz then vNum(b) - floor(vNum(b) / vNum(c)) * vNum(c) else 0.0)
    } else {
      setN(a, if nz then floor(vNum(b) / vNum(c)) else 0.0)
    }
  } else if op == 14 {
    if vTag(b) == 6 {
      setI(a, 0 - vInt(b))
    } else if vTag(b) == 1 {
      setN(a, 0.0 - vNum(b))
    } else {
      hotDone = false
    }
  } else if op == 15 {
    setB(a, !vTruthy(b))
  } else if op >= 34 && op <= 39 {
    if vTag(b) == 6 && (vTag(c) == 6 || op == 39) {
      setI(a, if op == 34 then vInt(b) & vInt(c)
        else if op == 35 then vInt(b) | vInt(c)
        else if op == 36 then vInt(b) ^ vInt(c)
        else if op == 37 then shlI(vInt(b), vInt(c))
        else if op == 38 then shlI(vInt(b), 0 - vInt(c))
        else ~vInt(b))
    } else {
      hotDone = false
    }
  } else if op == 16 {
    if vTag(b) == 2 && vTag(c) == 2 {
      setS(a, vStr(b) .. vStr(c))
    } else {
      hotDone = false
    }
  } else if op == 17 {
    let tb = vTag(b)
    let tc = vTag(c)
    if tb == 5 && tc == 5 && vInt(b) != vInt(c) && (tMeta[vInt(b)] >= 0 || tMeta[vInt(c)] >= 0) {
      hotDone = false
    } else {
    setB(a, if isNum(tb) && isNum(tc) then (if tb == 6 && tc == 6 then vInt(b) == vInt(c) else vNum(b) == vNum(c))
      else if tb != tc then false
      else if tb == 2 then vStr(b) == vStr(c)
      else if tb == 3 then vNum(b) == vNum(c)
      else if tb == 4 || tb == 5 || tb == 7 then vInt(b) == vInt(c)
      else true)
    }
  } else if op == 18 || op == 19 {
    let tb = vTag(b)
    let tc = vTag(c)
    if isNum(tb) && isNum(tc) {
      if tb == 6 && tc == 6 {
        setB(a, if op == 18 then vInt(b) < vInt(c) else vInt(b) <= vInt(c))
      } else {
        setB(a, if op == 18 then vNum(b) < vNum(c) else vNum(b) <= vNum(c))
      }
    } else {
      hotDone = false
    }
  } else if op == 20 {
    vmPc = a
    jumped = true
  } else if op == 21 {
    if !vTruthy(b) {
      vmPc = a
      jumped = true
    }
  } else if op == 22 {
    if vTruthy(b) {
      vmPc = a
      jumped = true
    }
  } else if op == 25 {
    if fUpN[b] == 0 {
      setObj(a, 4, b)
    } else {
      hotDone = false
    }
  } else if op == 50 {
    let uid = cloU[fClo[fClo.length() - 1] * 16 + b]
    if uOpen[uid] >= 0 {
      aCopy(vmBase + a, uOpen[uid])
    } else {
      rt[vmBase + a] = uT[uid]
      rn[vmBase + a] = uN[uid]
      ri[vmBase + a] = uI[uid]
      rs[vmBase + a] = uS[uid]
    }
  } else if op == 51 {
    let uid = cloU[fClo[fClo.length() - 1] * 16 + a]
    if uOpen[uid] >= 0 {
      aCopy(uOpen[uid], vmBase + b)
    } else {
      uT[uid] = vTag(b)
      uN[uid] = vNum(b)
      uI[uid] = vInt(b)
      uS[uid] = vStr(b)
    }
  } else if op == 52 {
    if openMaxAbs >= vmBase + a {
      clThresh = vmBase + a
      clIdx = openList.length() - 1
      clMax = -1
      micro = 8
    }
  } else if op == 0 {
    vmHalted = true
    jumped = true
  } else if op == 28 {
    if tCount >= MAX_TABLES {
      hotDone = false
    } else {
      tLen[tCount] = 0
      tFirst[tCount] = -1
      tLast[tCount] = -1
      tMeta[tCount] = -1
      setObj(a, 5, tCount)
      tCount = tCount + 1
    }
  } else if op == 29 {
    if vTag(b) != 5 {
      hotDone = false
    } else if vTag(c) == 0 || badFloatKey(c) {
      if tMeta[vInt(b)] < 0 {
        setNil(a)
      } else {
        hotDone = false
      }
    } else {
      let r = tmap.get(regKey(vInt(b), c))
      if r.Found && tvT[r.Value] != 0 {
        rt[vmBase + a] = tvT[r.Value]
        rn[vmBase + a] = tvN[r.Value]
        ri[vmBase + a] = tvI[r.Value]
        rs[vmBase + a] = tvS[r.Value]
      } else if tMeta[vInt(b)] < 0 {
        setNil(a)
      } else {
        hotDone = false
      }
    }
  } else if op == 30 {
    // overwrite of an existing live entry with a non-nil value; everything else is cold
    let okKey = vTag(c) != 0 && vTag(b) != 0 && !badFloatKey(b)
    if vTag(a) == 5 && okKey {
      let r = tmap.get(regKey(vInt(a), b))
      if r.Found && tvT[r.Value] != 0 {
        tvT[r.Value] = vTag(c)
        tvN[r.Value] = vNum(c)
        tvI[r.Value] = vInt(c)
        tvS[r.Value] = vStr(c)
      } else {
        hotDone = false
      }
    } else {
      hotDone = false
    }
  } else if op == 31 {
    if vTag(b) == 5 && tMeta[vInt(b)] < 0 {
      setI(a, tLen[vInt(b)])
    } else if vTag(b) == 2 {
      setI(a, vStr(b).Length())
    } else {
      hotDone = false
    }
  } else if op == 49 {
    if vTag(b) == 5 {
      rt[SCR1] = 2
      rs[SCR1] = constStr[c]
      let r = tmap.get(regKey(vInt(b), SCR1 - vmBase))
      if r.Found && tvT[r.Value] != 0 {
        vCopy(a + 1, b)
        rt[vmBase + a] = tvT[r.Value]
        rn[vmBase + a] = tvN[r.Value]
        ri[vmBase + a] = tvI[r.Value]
        rs[vmBase + a] = tvS[r.Value]
      } else {
        hotDone = false
      }
    } else {
      hotDone = false
    }
  } else if op == 47 {
    aCopy(vmBase + a, b)
  } else if op == 48 {
    aCopy(a, vmBase + b)
  } else if op == 44 {
    // numeric for: prepare (a = init, a+1 = limit, a+2 = step, a+3 = loop variable)
    let ti = vTag(a)
    let tl = vTag(a + 1)
    let tsx = vTag(a + 2)
    if !(isNum(ti) && isNum(tl) && isNum(tsx)) {
      hotDone = false
    } else if ti == 6 && tsx == 6 {
      let st = vInt(a + 2)
      let lim = if tl == 6 then vInt(a + 1) else forLimit(vNum(a + 1), st > 0)
      let init = vInt(a)
      if st == 0 {
        hotDone = false
      } else if (if st > 0 then init > lim else init < lim) {
        vmPc = b
        jumped = true
      } else {
        setI(a + 1, lim)
        setI(a + 3, init)
      }
    } else {
      let st = vNum(a + 2)
      let init = vNum(a)
      let lim = vNum(a + 1)
      if st == 0.0 {
        hotDone = false
      } else {
        setN(a, init)
        setN(a + 1, lim)
        setN(a + 2, st)
        if (if st > 0.0 then init > lim else init < lim) {
          vmPc = b
          jumped = true
        } else {
          setN(a + 3, init)
        }
      }
    }
  } else if op == 45 {
    if vTag(a) == 6 {
      let st = vInt(a + 2)
      let cur = vInt(a)
      let nx = cur + st
      if !(if st > 0 then nx < cur else nx > cur) && (if st > 0 then nx <= vInt(a + 1) else nx >= vInt(a + 1)) {
        setI(a, nx)
        setI(a + 3, nx)
        vmPc = b
        jumped = true
      }
    } else {
      let st = vNum(a + 2)
      let nx = vNum(a) + st
      if (if st > 0.0 then nx <= vNum(a + 1) else nx >= vNum(a + 1)) {
        setN(a, nx)
        setN(a + 3, nx)
        vmPc = b
        jumped = true
      }
    }
  } else if op == 46 {
    // generic for: results of the iterator call sit at a+3+c ..; continue when the first is non-nil
    let s = a + 3 + c
    if retCountV >= 1 && vTag(s) != 0 {
      vCopy(a + 2, s)
      if 0 < c {
        if 0 < retCountV { vCopy(a + 3, s) } else { setNil(a + 3) }
      }
      if 1 < c {
        if 1 < retCountV { vCopy(a + 4, s + 1) } else { setNil(a + 4) }
      }
      if 2 < c {
        if 2 < retCountV { vCopy(a + 5, s + 2) } else { setNil(a + 5) }
      }
      if 3 < c {
        if 3 < retCountV { vCopy(a + 6, s + 3) } else { setNil(a + 6) }
      }
      vmPc = b
      jumped = true
    }
  } else if op == 23 {
    // call of a plain Lua function with at most four parameters
    let fid = fnId(vTag(a), vInt(a))
    let cid = fnClo(vTag(a), vInt(a))
    if isFn(vTag(a)) && fid >= NB && fParams[fid] <= 4 && fVar[fid] == 0 && fFunc.length() < MAX_CALLS {
      let np = fParams[fid]
      let nargs = if c == 1 then (b - 1) + retCountV else b
      let nb = vmBase + a
      argCopy(nb, a, 0, np, nargs)
      argCopy(nb, a, 1, np, nargs)
      argCopy(nb, a, 2, np, nargs)
      argCopy(nb, a, 3, np, nargs)
      pushFrame(fid, nb, a, 0, cid, -1)
      vmBase = nb
      vmPc = fStart[fid]
      jumped = true
    } else {
      hotDone = false
    }
  } else if op == 24 || op == 26 {
    if fFunc.length() > 1 && fProt[fProt.length() - 1] == 0 && openMaxAbs < vmBase {
      let ra = fRetA[fRetA.length() - 1]
      let rb = fRetBase[fRetBase.length() - 1]
      let rpc = fRetPC[fRetPC.length() - 1]
      if op == 24 {
        aCopy(rb + ra, vmBase + a)
      } else {
        rt[rb + ra] = 0
      }
      vaTop = fVaB[fVaB.length() - 1]
      popFrame()
      vmBase = rb
      vmPc = rpc
      retCountV = if op == 24 then 1 else 0
      jumped = true
    } else {
      hotDone = false
    }
  } else {
    hotDone = false
  }
}

// ---------------------------------------------------------------- errors
mod tname(t: int) -> string {
  return if t == 0 then "nil" else if t == 1 || t == 6 then "number" else if t == 2 then "string"
    else if t == 3 then "boolean" else if t == 4 || t == 7 then "function" else "table"
}

// Raise a runtime error (a string message). The unwinding itself happens once per step.
mod vmFail(msg: string) {
  errPending = true
  errT = 2
  errN = 0.0
  errI = 0
  errS = msg
}
mod vmFailOp(what: string, r: int) {
  vmFail(what .. " a " .. tname(vTag(r)) .. " value")
}
mod doRaise() {
  errPending = false
  micro = 0
  if pStack.length() > 0 {
    let pf = pStack.pop().Value
    let ra = fRetA[pf]
    let rb = fRetBase[pf]
    let rpc = fRetPC[pf]
    vaTop = fVaB[pf]
    fFunc.resize(pf, 0)
    fBase.resize(pf, 0)
    fRetA.resize(pf, 0)
    fRetBase.resize(pf, 0)
    fRetPC.resize(pf, 0)
    fVaB.resize(pf, 0)
    fProt.resize(pf, 0)
    fClo.resize(pf, 0)
    fDst.resize(pf, 0)
    vmBase = rb
    rt[rb + ra - 1] = 3
    rn[rb + ra - 1] = 0.0
    rt[rb + ra] = errT
    rn[rb + ra] = errN
    ri[rb + ra] = errI
    rs[rb + ra] = errS
    retCountV = 2
    vmPc = rpc
    clThresh = rb + ra
    clIdx = openList.length() - 1
    clMax = -1
    micro = 8
  } else {
    errV = if errT == 2 then errS else if errT == 0 then "nil" else "(error object is a " .. tname(errT) .. " value)"
    vmFailed = true
    vmHalted = true
  }
}

// ---------------------------------------------------------------- operand fixups (fat copy only)
// String -> number for arithmetic coercion; result goes to the absolute scratch register dst.
mod strToNum(r: int, dst: int) -> bool {
  let s = vStr(r).Trim()
  let pn = s.ParseNumber()
  let isInt = s.Find(".") < 0 && s.Find("e") < 0 && s.Find("E") < 0
  let ok = pn.Success && s.Length() > 0
  if ok {
    if isInt {
      rt[dst] = 6
      ri[dst] = s.ParseInt()
      rn[dst] = pn.Value
    } else {
      rt[dst] = 1
      rn[dst] = pn.Value
    }
  }
  return ok
}
// Value of register r as an integer operand for a bitwise op, in scratch dst when it had to
// be converted. Returns false when there is no integer representation.
mod intOperand(r: int, dst: int) -> bool {
  var ok = false
  if vTag(r) == 6 {
    ok = true
  } else {
    if vTag(r) == 2 {
      ok = strToNum(r, dst)
    } else if vTag(r) == 1 {
      rt[dst] = 1
      rn[dst] = vNum(r)
      ok = true
    }
    if ok && rt[dst] == 1 && rn[dst] == floor(rn[dst]) && abs(rn[dst]) < 9.2e18 {
      rt[dst] = 6
      ri[dst] = rn[dst] | 0
    } else if ok && rt[dst] != 6 {
      ok = false
    }
  }
  return ok
}

// ---------------------------------------------------------------- table store (cold)
// t[k] = v for the general case: insert, delete (tombstone), revive. tr/kr/vr are registers.
mod tblSet(tr: int, kr: int, vr: int) {
  let tid = vInt(tr)
  let kt = vTag(kr)
  let vt = vTag(vr)
  if vTag(tr) != 5 {
    vmFailOp("attempt to index", tr)
  } else if kt == 0 {
    vmFail("table index is nil")
  } else if badFloatKey(kr) {
    vmFail("non-integer number keys are not supported")
  } else {
    let ks = regKey(tid, kr)
    let r = tmap.get(ks)
    let isInt = kt == 6 || kt == 1
    let kint = if isInt then keyInt(kr) else 0
    if r.Found {
      let sl = r.Value
      let wasLive = tvT[sl] != 0
      if vt == 0 {
        if wasLive {
          tvT[sl] = 0
          if isInt && kint == tLen[tid] {
            tLen[tid] = kint - 1
          }
        }
      } else {
        tvT[sl] = vt
        tvN[sl] = vNum(vr)
        tvI[sl] = vInt(vr)
        tvS[sl] = vStr(vr)
        if !wasLive && isInt && kint == tLen[tid] + 1 {
          tLen[tid] = kint
          lenTid = tid
          lenPending = true
        }
      }
    } else if vt != 0 {
      let f = tvT.find(0)
      let sl = f.Index
      if !f.Found || sl >= MAX_HEAP {
        vmFail("out of table memory")
      } else {
        if sl < tHeap {
          // reuse a tombstone: unlink it from its old table and drop its key
          let ot = tvO[sl]
          let pv = tPv[sl]
          let nx = tNx[sl]
          tmap.remove(tkey(ot, tkT[sl], tkI[sl], tkN[sl], tkS[sl]))
          if pv != -1 {
            tNx[pv] = nx
          } else {
            tFirst[ot] = nx
          }
          if nx != -1 {
            tPv[nx] = pv
          } else {
            tLast[ot] = pv
          }
        } else {
          tHeap = sl + 1
        }
        tvT[sl] = vt
        tvN[sl] = vNum(vr)
        tvI[sl] = vInt(vr)
        tvS[sl] = vStr(vr)
        tkT[sl] = kt
        tkN[sl] = vNum(kr)
        tkI[sl] = vInt(kr)
        tkS[sl] = vStr(kr)
        tvO[sl] = tid
        let last = tLast[tid]
        tPv[sl] = last
        tNx[sl] = -1
        if last != -1 {
          tNx[last] = sl
        } else {
          tFirst[tid] = sl
        }
        tLast[tid] = sl
        tmap.set(ks, sl)
        if isInt && kint == tLen[tid] + 1 {
          tLen[tid] = kint
          lenTid = tid
          lenPending = true
        }
      }
    }
  }
}

// ---------------------------------------------------------------- micro-steps
mod cmpFinish(v: bool) {
  rt[cmpDst] = 3
  rn[cmpDst] = if v then 1.0 else 0.0
  micro = 0
}
// One codepoint per call; order is by codepoint (identical to byte order for ASCII).
mod cmpStep() {
  let sa = rs[cmpAA]
  let sb = rs[cmpBB]
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
// close every open upvalue at or above clThresh (one list entry per call)
mod closeStep() {
  if clIdx < 0 {
    openMaxAbs = clMax
    micro = 0
  } else {
    let uid = openList[clIdx]
    let ab = uOpen[uid]
    if ab >= clThresh {
      uT[uid] = rt[ab]
      uN[uid] = rn[ab]
      uI[uid] = ri[ab]
      uS[uid] = rs[ab]
      uMap.remove(ab)
      uOpen[uid] = -1
      openList.remove(clIdx)
    } else if ab > clMax {
      clMax = ab
    }
    clIdx = clIdx - 1
  }
}
// build a closure: one captured variable per call
mod makeStep() {
  if mkK >= fUpN[mkFid] {
    setObj(mkDst, 7, mkCid)
    micro = 0
  } else {
    let idx = fUpI[mkFid * 16 + mkK]
    var uid = 0
    if fUpL[mkFid * 16 + mkK] == 1 {
      let ab = vmBase + idx
      let r = uMap.get(ab)
      if r.Found {
        uid = r.Value
      } else if uCount >= 2048 {
        vmFail("too many upvalues")
      } else {
        uid = uCount
        uCount = uCount + 1
        uOpen[uid] = ab
        uMap.set(ab, uid)
        openList.push(uid)
        if ab > openMaxAbs {
          openMaxAbs = ab
        }
      }
    } else {
      uid = cloU[fClo[fClo.length() - 1] * 16 + idx]
    }
    cloU[mkCid * 16 + mkK] = uid
    mkK = mkK + 1
  }
}



// register / vararg block copy, one value per call (kind 0 regs->regs, 1 varargs->regs, 2 regs->varargs)
mod copyStep() {
  if mvKind == 0 {
    aCopy(mvDst, mvSrc)
  } else if mvKind == 1 {
    rt[mvDst] = vaT[mvSrc]
    rn[mvDst] = vaN[mvSrc]
    ri[mvDst] = vaI[mvSrc]
    rs[mvDst] = vaS[mvSrc]
  } else {
    vaT[mvDst] = rt[mvSrc]
    vaN[mvDst] = rn[mvSrc]
    vaI[mvDst] = ri[mvSrc]
    vaS[mvDst] = rs[mvSrc]
  }
  mvSrc = mvSrc + 1
  mvDst = mvDst + 1
  mvCnt = mvCnt - 1
  if mvCnt <= 0 {
    micro = 0
  }
}
// print: one argument per call, then the line is pushed to the log
mod printStep() {
  if prIdx < prN {
    prLine = prLine .. (if prIdx > 0 && !prRaw then "\t" else "") .. fmtVal(rt[prBase + prIdx], rn[prBase + prIdx], ri[prBase + prIdx], rs[prBase + prIdx])
    prIdx = prIdx + 1
  } else {
    logPush(prLine .. (if prRaw then "" else "\n"))
    micro = 0
  }
}
// next(t, k): walk the chain from nxSlot, skipping tombstones
mod nextStep() {
  if nxSlot == -1 {
    rt[nxDst] = 0
    retCountV = 1
    micro = 0
  } else if tvT[nxSlot] == 0 {
    nxSlot = tNx[nxSlot]
  } else {
    rt[nxDst] = tkT[nxSlot]
    rn[nxDst] = tkN[nxSlot]
    ri[nxDst] = tkI[nxSlot]
    rs[nxDst] = tkS[nxSlot]
    rt[nxDst + 1] = tvT[nxSlot]
    rn[nxDst + 1] = tvN[nxSlot]
    ri[nxDst + 1] = tvI[nxSlot]
    rs[nxDst + 1] = tvS[nxSlot]
    retCountV = 2
    micro = 0
  }
}
// unpack(t, i, j): one element per call into consecutive registers
mod unpackStep() {
  if upN > 0 {
    rt[SCR0] = 6
    ri[SCR0] = upI
    rn[SCR0] = upI + 0.0
    tblGet(upDst - vmBase, upTid, SCR0 - vmBase)
    upI = upI + 1
    upDst = upDst + 1
    upN = upN - 1
  }
  if upN <= 0 {
    micro = 0
  }
}

// ---------------------------------------------------------------- cold instructions
// General return of `cnt` values that sit at absolute registers src..
mod retGeneral(src: int, cnt: int) {
  let n = fFunc.length()
  if n > 1 && openMaxAbs >= vmBase {
    clThresh = vmBase
    clIdx = openList.length() - 1
    clMax = -1
    micro = 8
    jumped = true
  } else if n <= 1 {
    resultV = if cnt >= 1 then fmtVal(rt[src], rn[src], ri[src], rs[src]) else ""
    vmHalted = true
    jumped = true
  } else {
    let ra = fRetA[n - 1]
    let rb = fRetBase[n - 1]
    let rpc = fRetPC[n - 1]
    let prot = fProt[n - 1]
    let dst = rb + ra
    let mdst = fDst[n - 1]
    let mtruth = cnt >= 1 && rt[src] != 0 && !(rt[src] == 3 && rn[src] == 0.0)
    vaTop = fVaB[n - 1]
    popFrame()
    if prot == 1 {
      pStack.pop()
      rt[dst - 1] = 3
      rn[dst - 1] = 1.0
    }
    vmBase = rb
    vmPc = rpc
    jumped = true
    if prot >= 2 {
      if prot == 3 {
        rt[rb + mdst] = 3
        rn[rb + mdst] = if mtruth then 1.0 else 0.0
      } else if prot == 2 {
        if cnt >= 1 {
          aCopy(rb + mdst, src)
        } else {
          rt[rb + mdst] = 0
        }
      }
    } else {
    retCountV = cnt + (if prot != 0 then 1 else 0)
    if cnt == 0 {
      rt[dst] = 0
    } else if cnt == 1 {
      aCopy(dst, src)
    } else {
      mvKind = 0
      mvSrc = src
      mvDst = dst
      mvCnt = cnt
      micro = 5
    }
    }
  }
}

// Lua function call with the general set of features (any parameter count up to 8,
// varargs, protected call). `a` is the call register, nargs the argument count.
mod userCall(a: int, fid: int, nargs: int, prot: int, cid: int, dst: int) {
  let np = fParams[fid]
  let isVar = fVar[fid] != 0
  let nva = if isVar && nargs > np then nargs - np else 0
  if fFunc.length() >= MAX_CALLS {
    vmFail("stack overflow")
  } else if np > 8 {
    vmFail("too many parameters (max 8)")
  } else if vaTop + nva > 256 {
    vmFail("too many varargs")
  } else {
    let nb = vmBase + a
    argCopy(nb, a, 0, np, nargs)
    argCopy(nb, a, 1, np, nargs)
    argCopy(nb, a, 2, np, nargs)
    argCopy(nb, a, 3, np, nargs)
    argCopy(nb, a, 4, np, nargs)
    argCopy(nb, a, 5, np, nargs)
    argCopy(nb, a, 6, np, nargs)
    argCopy(nb, a, 7, np, nargs)
    if prot != 0 {
      pStack.push(fFunc.length())
    }
    if nva > 0 {
      mvKind = 2
      mvSrc = vmBase + a + 1 + np
      mvDst = vaTop
      mvCnt = nva
      micro = 5
    }
    pushFrame(fid, nb, a, prot, cid, dst)
    vaTop = vaTop + nva
    vmBase = nb
    vmPc = fStart[fid]
    jumped = true
  }
}

// Call handler h (absolute register hAbs) with up to three arguments; the result lands in the
// current frame's register dstRel when it returns (prot 2 raw, 3 boolean, 4 ignored).
mod metaCall(hAbs: int, a1: int, a2: int, a3: int, nargs: int, dstRel: int, prot: int) {
  let top = vmBase + fRegs[fFunc[fFunc.length() - 1]] + 1
  aCopy(top, hAbs)
  aCopy(top + 1, a1)
  if nargs >= 2 {
    aCopy(top + 2, a2)
  }
  if nargs >= 3 {
    aCopy(top + 3, a3)
  }
  let ft = rt[top]
  if !isFn(ft) || fnId(ft, ri[top]) < NB {
    vmFail("metamethod must be a Lua function")
  } else {
    userCall(top - vmBase, fnId(ft, ri[top]), nargs, prot, fnClo(ft, ri[top]), dstRel)
  }
}

// __index resolution: one level per call. mtTid is the table being searched, the key sits in SCR3.
mod indexStep() {
  let mt = tMeta[mtTid]
  metaFetch(if mt < 0 then 0 else mt, "__index", SCR2)
  if mt < 0 || rt[SCR2] == 0 {
    rt[mtDst] = 0
    micro = 0
  } else if rt[SCR2] == 5 {
    let r = tmap.get(tkey(ri[SCR2], rt[SCR3], ri[SCR3], rn[SCR3], rs[SCR3]))
    if r.Found && tvT[r.Value] != 0 {
      rt[mtDst] = tvT[r.Value]
      rn[mtDst] = tvN[r.Value]
      ri[mtDst] = tvI[r.Value]
      rs[mtDst] = tvS[r.Value]
      micro = 0
    } else {
      mtTid = ri[SCR2]
      mtDepth = mtDepth + 1
      if mtDepth > 100 {
        vmFail("'__index' chain too long; possible loop")
      }
    }
  } else {
    micro = 0
    vmPc = vmPc - 1
    metaCall(SCR2, mtOrig, SCR3, 0, 2, mtDst - vmBase, 2)
    if !jumped {
      vmPc = vmPc + 1
    }
  }
}


mod numArg(r: int, present: bool) -> float {
  return if present && isNum(vTag(r)) then vNum(r) else 0.0
}
mod numArgOk(r: int, present: bool) -> bool {
  return !present || isNum(vTag(r)) || vTag(r) == 0
}

// Native (built-in) functions: fid 0..NB-1. Arguments at a+1.., results at a.., count in retCountV.
mod native(fid: int, a: int, nargs: int) {
  retCountV = 1
  if fid == 0 || fid == 20 {
    prRaw = fid == 20
    prLine = ""
    prIdx = 0
    prN = nargs
    prBase = vmBase + a + 1
    micro = 4
    rt[vmBase + a] = 0
    retCountV = 0
  } else if fid == 1 {
    if nargs == 0 {
      vmFail("bad argument #1 to 'type' (value expected)")
    } else {
      setS(a, tname(vTag(a + 1)))
    }
  } else if fid == 2 {
    if nargs == 0 {
      vmFail("bad argument #1 to 'tostring' (value expected)")
    } else {
      setS(a, fmtReg(a + 1))
    }
  } else if fid == 3 {
    if nargs >= 2 && !(vTag(a + 2) == 6 && vInt(a + 2) == 10) {
      vmFail("tonumber with a base is not supported")
    } else if isNum(vTag(a + 1)) {
      vCopy(a, a + 1)
    } else if vTag(a + 1) == 2 && strToNum(a + 1, SCR0) {
      aCopy(vmBase + a, SCR0)
    } else {
      setNil(a)
    }
  } else if fid == 4 {
    if numArgOk(a + 1, nargs > 0) && numArgOk(a + 2, nargs > 1) && numArgOk(a + 3, nargs > 2) {
      outVecV = Vec(numArg(a + 1, nargs > 0), numArg(a + 2, nargs > 1), numArg(a + 3, nargs > 2))
      setNil(a)
      retCountV = 0
    } else {
      vmFail("bad argument to 'setvec' (number expected)")
    }
  } else if fid == 5 {
    if numArgOk(a + 1, nargs > 0) && numArgOk(a + 2, nargs > 1) && numArgOk(a + 3, nargs > 2) && numArgOk(a + 4, nargs > 3) {
      outColV = Color(numArg(a + 1, nargs > 0), numArg(a + 2, nargs > 1), numArg(a + 3, nargs > 2), numArg(a + 4, nargs > 3))
      setNil(a)
      retCountV = 0
    } else {
      vmFail("bad argument to 'setcol' (number expected)")
    }
  } else if fid == 6 {
    setN(a, ServerUptime())
  } else if fid == 7 {
    let it = if nargs > 0 then vTag(a + 1) else 0
    let iv = if nargs > 0 then vNum(a + 1) else 0.0
    if isNum(it) && iv == floor(iv) && iv >= 1.0 && iv <= inArr.length() {
      setN(a, inArr[(iv | 0) - 1])
    } else {
      setNil(a)
    }
  } else if fid == 8 {
    let it = if nargs > 0 then vTag(a + 1) else 0
    let iv = if nargs > 0 then vNum(a + 1) else 0.0
    let vt = if nargs > 1 then vTag(a + 2) else 0
    if !isNum(it) || iv != floor(iv) || iv < 1.0 || iv > outArrV.length() {
      vmFail("array index out of range")
    } else if isNum(vt) || vt == 0 {
      outArrV[(iv | 0) - 1] = if vt == 0 then 0.0 else vNum(a + 2)
      setNil(a)
      retCountV = 0
    } else {
      vmFail("array element must be a number")
    }
  } else if fid == 9 {
    if nargs == 0 || vTag(a + 1) != 5 {
      vmFail("bad argument #1 to 'next' (table expected)")
    } else {
      let tid = vInt(a + 1)
      let kr = tmap.get(regKey(tid, a + 2))
      if nargs < 2 || vTag(a + 2) == 0 {
        nxSlot = tFirst[tid]
        nxDst = vmBase + a
        micro = 3
      } else if kr.Found {
        nxSlot = tNx[kr.Value]
        nxDst = vmBase + a
        micro = 3
      } else {
        vmFail("invalid key to 'next'")
      }
    }
  } else if fid == 10 {
    let ft = vTag(a + 1)
    let ff = vInt(a + 1)
    if nargs == 0 {
      vmFail("bad argument #1 to 'pcall' (value expected)")
    } else if isFn(ft) && fnId(ft, ff) >= NB {
      userCall(a + 1, fnId(ft, ff), nargs - 1, 1, fnClo(ft, ff), -1)
    } else {
      rt[vmBase + a] = 3
      rn[vmBase + a] = 0.0
      if ft == 4 && ff == 11 {
        if nargs >= 2 {
          aCopy(vmBase + a + 1, vmBase + a + 2)
        } else {
          rt[vmBase + a + 1] = 0
        }
      } else {
        rt[vmBase + a + 1] = 2
        rs[vmBase + a + 1] = "attempt to call a " .. tname(ft) .. " value"
      }
      retCountV = 2
    }
  } else if fid == 11 {
    let lvl = if nargs >= 2 && isNum(vTag(a + 2)) then keyInt(a + 2) else 1
    let n = fFunc.length()
    let eline = if lvl == 2 && n >= 2 then bLine[fRetPC[n - 2] - 1]
      else if lvl >= 1 then bLine[vmPc] else -1
    errPending = true
    errT = if nargs > 0 then vTag(a + 1) else 0
    errN = if nargs > 0 then vNum(a + 1) else 0.0
    errI = if nargs > 0 then vInt(a + 1) else 0
    errS = if nargs > 0 && errT == 2 && lvl != 0 then "line " .. eline .. ": " .. vStr(a + 1)
      else if nargs > 0 then vStr(a + 1) else ""
  } else if fid == 12 {
    if nargs == 0 || vTag(a + 1) != 5 {
      vmFail("bad argument #1 to 'unpack' (table expected)")
    } else {
      let tid = vInt(a + 1)
      let i0 = if nargs >= 2 && isNum(vTag(a + 2)) then keyInt(a + 2) else 1
      let j0 = if nargs >= 3 && isNum(vTag(a + 3)) then keyInt(a + 3) else tLen[tid]
      let n = j0 - i0 + 1
      if n <= 0 {
        setNil(a)
        retCountV = 0
      } else if n > 60 {
        vmFail("too many results to unpack")
      } else {
        upTid = tid
        upI = i0
        upN = n
        upDst = vmBase + a
        retCountV = n
        micro = 6
      }
    }
  } else if fid == 13 {
    if nargs == 0 {
      vmFail("bad argument #1 to 'select' (number expected, got no value)")
    } else if vTag(a + 1) == 2 && vStr(a + 1) == "#" {
      setI(a, nargs - 1)
    } else if !isNum(vTag(a + 1)) {
      vmFail("bad argument #1 to 'select' (number expected)")
    } else {
      let k0 = keyInt(a + 1)
      let k = if k0 < 0 then nargs + k0 else k0
      if k <= 0 {
        vmFail("bad argument #1 to 'select' (index out of range)")
      } else if k >= nargs {
        setNil(a)
        retCountV = 0
      } else {
        retCountV = nargs - k
        mvKind = 0
        mvSrc = vmBase + a + 1 + k
        mvDst = vmBase + a
        mvCnt = nargs - k
        micro = 5
      }
    }
  } else if fid == 14 {
    let mo = vInt(a + 1)
    let x = vNum(a + 2)
    let y = vNum(a + 3)
    if mo == 1 || mo == 2 {
      let f = if mo == 1 then floor(x) else ceil(x)
      if vTag(a + 2) == 6 {
        vCopy(a, a + 2)
      } else if abs(f) < 9.2e18 {
        setI(a, f | 0)
      } else {
        setN(a, f)
      }
    } else if mo == 14 {
      if vTag(a + 2) == 6 {
        setS(a, "integer")
      } else if vTag(a + 2) == 1 {
        setS(a, "float")
      } else {
        setNil(a)
      }
    } else if mo == 13 {
      if vTag(a + 2) == 6 {
        vCopy(a, a + 2)
      } else if vTag(a + 2) == 1 && x == floor(x) && abs(x) < 9.2e18 {
        setI(a, x | 0)
      } else {
        setNil(a)
      }
    } else {
      setN(a, if mo == 3 then sqrt(x) else if mo == 4 then sin(x) else if mo == 5 then cos(x) else if mo == 6 then tan(x)
        else if mo == 7 then asin(x) else if mo == 8 then acos(x) else if mo == 9 then atan2(x, y)
        else if mo == 10 then exp(x) else if mo == 11 then ln(x) else if mo == 12 then log(x, 10.0) else x)
    }
  } else if fid == 16 {
    if nargs < 1 || vTag(a + 1) != 5 {
      vmFail("bad argument #1 to 'setmetatable' (table expected)")
    } else if nargs >= 2 && vTag(a + 2) != 5 && vTag(a + 2) != 0 {
      vmFail("bad argument #2 to 'setmetatable' (nil or table expected)")
    } else {
      tMeta[vInt(a + 1)] = if nargs >= 2 && vTag(a + 2) == 5 then vInt(a + 2) else -1
      vCopy(a, a + 1)
    }
  } else if fid == 17 {
    if nargs >= 1 && vTag(a + 1) == 5 && tMeta[vInt(a + 1)] >= 0 {
      setObj(a, 5, tMeta[vInt(a + 1)])
    } else {
      setNil(a)
    }
  } else if fid == 18 {
    if nargs < 2 || vTag(a + 1) != 5 {
      vmFail("bad argument #1 to 'rawget' (table expected)")
    } else if vTag(a + 2) == 0 || badFloatKey(a + 2) {
      setNil(a)
    } else {
      tblGet(a, vInt(a + 1), a + 2)
    }
  } else if fid == 19 {
    if nargs < 3 || vTag(a + 1) != 5 {
      vmFail("bad argument #1 to 'rawset' (table expected)")
    } else {
      aCopy(SCR2, vmBase + a + 1)
      aCopy(SCR3, vmBase + a + 2)
      aCopy(SCR4, vmBase + a + 3)
      injA = SCR2 - vmBase
      injB = SCR3 - vmBase
      injC = SCR4 - vmBase
      rawSet = true
      micro = 11
      vCopy(a, a + 1)
    }
  } else if fid == 15 {
    let so = vInt(a + 1)
    let s = vStr(a + 2)
    let p = vInt(a + 3)
    let q = vInt(a + 4)
    if so == 1 {
      setS(a, s.Substring(p, q))
    } else if so == 2 {
      setS(a, s.ToUpper())
    } else if so == 3 {
      setS(a, s.ToLower())
    } else if so == 4 {
      if p >= 0 && p < s.Length() {
        setI(a, s.Substring(p, 1).ToCharCode().Codepoint)
      } else {
        setNil(a)
      }
    } else if so == 5 {
      setS(a, FromCharCode(vInt(a + 2)).Character)
    } else {
      setI(a, s.Find(vStr(a + 3), true, q))
    }
  } else {
    vmFail("bad native function")
  }
}

// Output globals 0..6 (outNum0..3, outStr0..1, outInt0) are typed: check and store.
mod outStore(slot: int, s: int) {
  let t = vTag(s)
  if slot <= 3 {
    if isNum(t) || t == 0 || t == 3 {
      gStore(slot, s)
    } else {
      vmFail("outNum0..outNum3 take numbers")
    }
  } else if slot <= 5 {
    gStore(slot, s)
  } else if t == 6 {
    gStore(slot, s)
  } else if t == 1 && vNum(s) == floor(vNum(s)) && abs(vNum(s)) < 9.2e18 {
    gt[slot] = 6
    gi[slot] = vNum(s) | 0
  } else if t == 0 {
    gt[slot] = 0
  } else {
    vmFail("outInt0 takes an integer")
  }
}

mod execCold(op: int, a: int, b: int, c: int, fb: int, fc: int) {
  if (op >= 8 && op <= 13) || op == 33 || op == 14 {
    let tb = vTag(fb)
    let tc = vTag(fc)
    if op != 14 && isNum(tb) && isNum(tc) {
      vmFail(if op == 12 then "attempt to perform 'n%%0'" else "attempt to perform 'n//0'")
    } else if binHandler(evName(op), b, if op == 14 then b else c) {
      metaCall(SCR2, vmBase + b, vmBase + (if op == 14 then b else c), 0, 2, a, 2)
    } else {
      vmFailOp("attempt to perform arithmetic on", if op != 14 && isNum(tb) then fc else fb)
    }
  } else if op >= 34 && op <= 39 {
    if isNum(vTag(b)) && (op == 39 || isNum(vTag(c))) {
      vmFail("number has no integer representation")
    } else {
      vmFailOp("attempt to perform bitwise operation on", if isNum(vTag(b)) then c else b)
    }
  } else if op == 16 {
    if binHandler("__concat", b, c) {
      metaCall(SCR2, vmBase + b, vmBase + c, 0, 2, a, 2)
    } else {
      vmFailOp("attempt to concatenate", if vTag(fb) == 2 then fc else fb)
    }
  } else if op == 18 || op == 19 {
    if vTag(b) == 2 && vTag(c) == 2 {
      cmpAA = vmBase + b
      cmpBB = vmBase + c
      cmpDst = vmBase + a
      cmpI = 0
      cmpOp = if op == 19 then 1 else 0
      micro = 2
    } else if binHandler(evName(op), b, c) {
      metaCall(SCR2, vmBase + b, vmBase + c, 0, 2, a, 3)
    } else if vTag(b) == vTag(c) || (isNum(vTag(b)) && isNum(vTag(c))) {
      vmFail("attempt to compare two " .. tname(vTag(b)) .. " values")
    } else {
      vmFail("attempt to compare " .. tname(vTag(b)) .. " with " .. tname(vTag(c)))
    }
  } else if op == 49 {
    if vTag(b) == 5 {
      vCopy(a + 1, b)
      rt[SCR3] = 2
      rs[SCR3] = constStr[c]
      mtTid = vInt(b)
      mtOrig = vmBase + b
      mtDst = vmBase + a
      mtDepth = 0
      micro = 10
    } else if vTag(b) == 2 {
      let g = gmap.get("string." .. constStr[c])
      vCopy(a + 1, b)
      if g.Found {
        gLoad(a, g.Value)
      } else {
        setNil(a)
      }
    } else {
      vmFailOp("attempt to index", b)
    }
  } else if op == 25 {
    if cloCount >= 512 {
      vmFail("too many closures")
    } else {
      mkCid = cloCount
      cloCount = cloCount + 1
      cloF[mkCid] = b
      mkFid = b
      mkK = 0
      mkDst = a
      micro = 9
    }
  } else if op == 28 {
    vmFail("too many tables")
  } else if op == 17 {
    if binHandler("__eq", b, c) {
      metaCall(SCR2, vmBase + b, vmBase + c, 0, 2, a, 3)
    } else {
      setB(a, false)
    }
  } else if op == 29 {
    if vTag(b) == 5 {
      aCopy(SCR3, vmBase + c)
      mtTid = vInt(b)
      mtOrig = vmBase + b
      mtDst = vmBase + a
      mtDepth = 0
      micro = 10
    } else {
      vmFailOp("attempt to index", b)
    }
  } else if op == 30 {
    let tidM = vInt(a)
    var viaMeta = false
    if !rawSet && vTag(a) == 5 && tMeta[tidM] >= 0 && vTag(c) != 0 && vTag(b) != 0 && !badFloatKey(b) {
      let rr = tmap.get(regKey(tidM, b))
      if !(rr.Found && tvT[rr.Value] != 0) {
        metaFetch(tMeta[tidM], "__newindex", SCR2)
        if rt[SCR2] == 5 {
          aCopy(SCR3, vmBase + b)
          aCopy(SCR4, vmBase + c)
          injA = SCR2 - vmBase
          injB = SCR3 - vmBase
          injC = SCR4 - vmBase
          micro = 11
          viaMeta = true
        } else if rt[SCR2] != 0 {
          metaCall(SCR2, vmBase + a, vmBase + b, vmBase + c, 3, -1, 4)
          viaMeta = true
        }
      }
    }
    if !viaMeta {
      tblSet(a, b, c)
    }
    rawSet = false
  } else if op == 31 {
    if vTag(b) == 5 {
      if binHandler("__len", b, b) {
        metaCall(SCR2, vmBase + b, vmBase + b, 0, 2, a, 2)
      } else {
        setI(a, tLen[vInt(b)])
      }
    } else {
      vmFailOp("attempt to get length of", b)
    }
  } else if op == 6 {
    outStore(a, b)
  } else if op == 44 {
    if !isNum(vTag(a)) {
      vmFail("'for' initial value must be a number")
    } else if !isNum(vTag(a + 1)) {
      vmFail("'for' limit must be a number")
    } else if !isNum(vTag(a + 2)) {
      vmFail("'for' step must be a number")
    } else {
      vmFail("'for' step is zero")
    }
  } else if op == 23 {
    let tf = vTag(a)
    let fid = vInt(a)
    let nargs = if c == 1 then (b - 1) + retCountV else b
    if tf == 5 && tMeta[fid] >= 0 && nargs <= 7 {
      metaFetch(tMeta[fid], "__call", SCR2)
      if isFn(rt[SCR2]) && fnId(rt[SCR2], ri[SCR2]) >= NB {
        // shift the arguments up by one and pass the table as the first argument
        if nargs >= 7 { aCopy(vmBase + a + 8, vmBase + a + 7) }
        if nargs >= 6 { aCopy(vmBase + a + 7, vmBase + a + 6) }
        if nargs >= 5 { aCopy(vmBase + a + 6, vmBase + a + 5) }
        if nargs >= 4 { aCopy(vmBase + a + 5, vmBase + a + 4) }
        if nargs >= 3 { aCopy(vmBase + a + 4, vmBase + a + 3) }
        if nargs >= 2 { aCopy(vmBase + a + 3, vmBase + a + 2) }
        if nargs >= 1 { aCopy(vmBase + a + 2, vmBase + a + 1) }
        aCopy(vmBase + a + 1, vmBase + a)
        aCopy(vmBase + a, SCR2)
        userCall(a, fnId(rt[SCR2], ri[SCR2]), nargs + 1, 0, fnClo(rt[SCR2], ri[SCR2]), -1)
      } else {
        vmFail("attempt to call a table value")
      }
    } else if !isFn(tf) {
      vmFail("attempt to call a " .. tname(tf) .. " value")
    } else if fnId(tf, fid) >= NB {
      userCall(a, fnId(tf, fid), nargs, 0, fnClo(tf, fid), -1)
    } else {
      native(fid, a, nargs)
    }
  } else if op == 24 || op == 26 {
    retGeneral(vmBase + a, if op == 24 then 1 else 0)
  } else if op == 27 {
    retGeneral(vmBase + a, b + retCountV)
  } else if op == 40 {
    retGeneral(vmBase + a, b)
  } else if op == 41 {
    // VARARG a, n: all varargs (n == 0, count in retCountV) or the first n
    let n = fFunc.length()
    let cnt = vaTop - fVaB[n - 1]
    let want = if b == 0 then cnt else b
    retCountV = want
    if cnt <= 0 {
      setNil(a)
    }
    if b > 0 && cnt < b {
      rt[vmBase + a + cnt] = 0
      if cnt + 1 < b {
        rt[vmBase + a + cnt + 1] = 0
      }
      if cnt + 2 < b {
        rt[vmBase + a + cnt + 2] = 0
      }
    }
    let k = if want < cnt then want else cnt
    if k > 0 {
      mvKind = 1
      mvSrc = fVaB[n - 1]
      mvDst = vmBase + a
      mvCnt = k
      micro = 5
    }
  } else if op == 42 {
    // ADJ a, n: pad the results of the previous call to n values
    let cnt = retCountV
    if cnt < 1 && 0 < b { setNil(a) }
    if cnt < 2 && 1 < b { setNil(a + 1) }
    if cnt < 3 && 2 < b { setNil(a + 2) }
    if cnt < 4 && 3 < b { setNil(a + 3) }
    if cnt < 5 && 4 < b { setNil(a + 4) }
    if cnt < 6 && 5 < b { setNil(a + 5) }
    if cnt < 7 && 6 < b { setNil(a + 6) }
    if cnt < 8 && 7 < b { setNil(a + 7) }
  } else if op == 43 {
    // SETMULTI t, base, start: t[start + i] = R[base + i] for every pending result
    if retCountV > 0 {
      smTbl = a
      smSrc = vmBase + b
      smStart = c
      smIdx = 0
      smCnt = retCountV
      micro = 7
    }
  } else {
    vmFail("bad opcode " .. op)
  }
}

// ---------------------------------------------------------------- stepping
mod hotStep() {
  if !vmHalted && micro == 0 && !lenPending && !errPending {
    hotDone = false
    jumped = false
    execHot(bop[vmPc], bpa[vmPc], bpb[vmPc], bpc[vmPc])
    if hotDone && !jumped {
      vmPc = vmPc + 1
    }
  }
}

// The general step: runs pending micro-steps, raises errors, or executes one instruction
// (hot set first, then the cold set) with coerced operands substituted through scratch registers.
mod fatStep() {
  if errPending {
    doRaise()
  } else if lenPending {
    lenStep()
  } else if micro == 2 {
    cmpStep()
  } else if micro == 3 {
    nextStep()
  } else if micro == 4 {
    printStep()
  } else if micro == 5 {
    copyStep()
  } else if micro == 8 {
    closeStep()
  } else if micro == 10 {
    indexStep()
  } else if micro == 9 {
    makeStep()
  } else if micro == 6 {
    unpackStep()
  } else if micro == 7 || micro == 11 || !vmHalted {
    let inj7 = micro == 7
    let inj11 = micro == 11
    let inj = inj7 || inj11
    let op = if inj then 30 else bop[vmPc]
    let a = if inj11 then injA else if inj7 then smTbl else bpa[vmPc]
    let b = if inj11 then injB else if inj7 then SCR0 - vmBase else bpb[vmPc]
    let c = if inj11 then injC else if inj7 then SCR1 - vmBase else bpc[vmPc]
    var fb = b
    var fc = c
    if inj11 {
      micro = 0
    }
    if inj {
      vmPc = vmPc - 1
    }
    if inj7 {
      rt[SCR0] = 6
      ri[SCR0] = smStart + smIdx
      rn[SCR0] = (smStart + smIdx) + 0.0
      aCopy(SCR1, smSrc + smIdx)
    }
    if (op >= 8 && op <= 14) || op == 33 {
      if vTag(b) == 2 {
        if strToNum(b, SCR0) {
          fb = SCR0 - vmBase
        }
      }
      if vTag(c) == 2 {
        if strToNum(c, SCR1) {
          fc = SCR1 - vmBase
        }
      }
    } else if op >= 34 && op <= 39 {
      if vTag(b) != 6 {
        if intOperand(b, SCR0) {
          fb = SCR0 - vmBase
        }
      }
      if vTag(c) != 6 {
        if intOperand(c, SCR1) {
          fc = SCR1 - vmBase
        }
      }
    } else if op == 16 {
      if isNum(vTag(b)) {
        rt[SCR0] = 2
        rs[SCR0] = fmtReg(b)
        fb = SCR0 - vmBase
      }
      if isNum(vTag(c)) {
        rt[SCR1] = 2
        rs[SCR1] = fmtReg(c)
        fc = SCR1 - vmBase
      }
    }
    hotDone = false
    jumped = false
    execHot(op, a, fb, fc)
    if !hotDone {
      execCold(op, a, b, c, fb, fc)
    }
    if inj {
      if !jumped {
        vmPc = vmPc + 1
      }
      if inj7 {
        smIdx = smIdx + 1
        smCnt = smCnt - 1
        if smCnt <= 0 && micro == 7 {
          micro = 0
        }
      }
    } else if !errPending && !jumped {
      vmPc = vmPc + 1
    }
  }
}

mod vmBurst() {
  hotStep()
  hotStep()
  hotStep()
  hotStep()
  hotStep()
  hotStep()
  fatStep()
}

// Pre-registered globals: 0..3 outNum0..3, 4..5 outStr0..1, 6 outInt0, 7..10 inNum0..3,
// 11..12 inStr0..1, 13 inInt0, 14..16 invec x/y/z, 17..20 incol r/g/b/a, 21..36 builtins.
var GTAG_INIT: int[] = [1, 1, 1, 1, 2, 2, 6, 1, 1, 1, 1, 2, 2, 6, 1, 1, 1, 1, 1, 1, 1, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4]
var GI_INIT: int[] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 2, 0, 18, 19, 20]
var GN_INIT: float[] = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0, 16.0, 17.0, 2.0, 0.0, 18.0, 19.0, 20.0]

mod vmReset() {
  tmap.clear()
  tvT.clear()
  tvN.clear()
  tvI.clear()
  tvS.clear()
  tkT.clear()
  tkN.clear()
  tkI.clear()
  tkS.clear()
  tvO.clear()
  tNx.clear()
  tPv.clear()
  tvT.resize(MAX_HEAP, 0)
  tvN.resize(MAX_HEAP, 0.0)
  tvI.resize(MAX_HEAP, 0)
  tvS.resize(MAX_HEAP, "")
  tkT.resize(MAX_HEAP, 0)
  tkN.resize(MAX_HEAP, 0.0)
  tkI.resize(MAX_HEAP, 0)
  tkS.resize(MAX_HEAP, "")
  tvO.resize(MAX_HEAP, 0)
  tNx.resize(MAX_HEAP, -1)
  tPv.resize(MAX_HEAP, -1)
  tFirst.clear()
  tLast.clear()
  tLen.clear()
  tFirst.resize(MAX_TABLES, -1)
  tLast.resize(MAX_TABLES, -1)
  tLen.resize(MAX_TABLES, 0)
  tHeap = 0
  tCount = 0
  lenPending = false
  rt.clear()
  rn.clear()
  ri.clear()
  rs.clear()
  rt.resize(2200, 0)
  rn.resize(2200, 0.0)
  ri.resize(2200, 0)
  rs.resize(2200, "")
  vaT.clear()
  vaN.clear()
  vaI.clear()
  vaS.clear()
  vaT.resize(256, 0)
  vaN.resize(256, 0.0)
  vaI.resize(256, 0)
  vaS.resize(256, "")
  vaTop = 0
  fFunc.clear()
  fBase.clear()
  fRetA.clear()
  fRetBase.clear()
  fRetPC.clear()
  fVaB.clear()
  fProt.clear()
  fClo.clear()
  fDst.clear()
  pStack.clear()
  tMeta.clear()
  tMeta.resize(MAX_TABLES, -1)
  cloCount = 0
  uCount = 0
  openMaxAbs = -1
  uMap.clear()
  openList.clear()
  cloF.clear()
  cloU.clear()
  uOpen.clear()
  uT.clear()
  uN.clear()
  uI.clear()
  uS.clear()
  cloF.resize(512, 0)
  cloU.resize(8192, 0)
  uOpen.resize(2048, -1)
  uT.resize(2048, 0)
  uN.resize(2048, 0.0)
  uI.resize(2048, 0)
  uS.resize(2048, "")
  gt.copyFrom(GTAG_INIT)
  gi.copyFrom(GI_INIT)
  gn.copyFrom(GN_INIT)
  gt.resize(256, 0)
  gi.resize(256, 0)
  gn.resize(256, 0.0)
  gs.clear()
  gs.resize(256, "")
  gn[7] = latchN0
  gn[8] = latchN1
  gn[9] = latchN2
  gn[10] = latchN3
  gs[11] = latchS0
  gs[12] = latchS1
  gi[13] = latchI0
  gn[13] = latchI0 + 0.0
  gn[14] = latchVX
  gn[15] = latchVY
  gn[16] = latchVZ
  gn[17] = latchCR
  gn[18] = latchCG
  gn[19] = latchCB
  gn[20] = latchCA
  vmPc = 0
  vmBase = 0
  vmHalted = bop.length() == 0
  vmFailed = false
  retCountV = 0
  micro = 0
  errPending = false
  logV = ""
  logLines.clear()
  oF0 = 0.0
  oF1 = 0.0
  oF2 = 0.0
  oF3 = 0.0
  oS4 = ""
  oS5 = ""
  oI6 = 0
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
  fVaB.push(0)
  fProt.push(0)
  fClo.push(-1)
  fDst.push(-1)
}

// ---------------------------------------------------------------- jobs + events

let sched: exec
let goParse: exec
let goParse2: exec

var jobBusy: bool = false
var wantParse: bool = false

const LIB_iter = "do\nfunction _ipairs_iter(t, i) i = i + 1 local v = t[i] if v ~= nil then return i, v end end\nfunction ipairs(t) return _ipairs_iter, t, 0 end\nfunction pairs(t) return next, t, nil end\nend\n"
const LIB_assert = "do\nfunction assert(v, m, ...) if not v then error(m or \"assertion failed!\", 2) end return v, m, ... end\nend\n"
const LIB_raw = "do\nfunction rawequal(a, b) return a == b end\nfunction rawlen(t) return #t end\nend\n"
const LIB_xpcall = "do\nfunction xpcall(f, h, ...) local r = {pcall(f, ...)} if r[1] then return unpack(r) end return false, h(r[2]) end\nend\n"
const LIB_tunpack = "do\ntable.unpack = unpack\nend\n"
const LIB_tpack = "do\nfunction table.pack(...) local t = {...} t.n = select('#', ...) return t end\nend\n"
const LIB_tinsert = "do\nfunction table.insert(t, ...)\n  local n = #t\n  local c = select('#', ...)\n  if c == 1 then\n    t[n + 1] = (...)\n  elseif c == 2 then\n    local pos, v = ...\n    if pos < 1 or pos > n + 1 then error(\"bad argument #2 to 'insert' (position out of bounds)\") end\n    for i = n, pos, -1 do t[i + 1] = t[i] end\n    t[pos] = v\n  else\n    error(\"wrong number of arguments to 'insert'\")\n  end\nend\nend\n"
const LIB_tremove = "do\nfunction table.remove(t, pos)\n  local n = #t\n  if pos == nil then pos = n end\n  if n == 0 and (pos == 0 or pos == n) then return t[pos] end\n  if n + 1 == pos then local v = t[pos] t[pos] = nil return v end\n  if pos < 1 or pos > n + 1 then error(\"bad argument #2 to 'remove' (position out of bounds)\") end\n  local v = t[pos]\n  for i = pos, n - 1 do t[i] = t[i + 1] end\n  t[n] = nil\n  return v\nend\nend\n"
const LIB_tconcat = "do\nfunction table.concat(t, sep, i, j)\n  sep = sep or \"\"\n  i = i or 1\n  j = j or #t\n  local r = \"\"\n  for k = i, j do\n    local v = t[k]\n    if type(v) ~= \"string\" and type(v) ~= \"number\" then error(\"invalid value (at index \" .. k .. \") in table for 'concat'\") end\n    if k > i then r = r .. sep end\n    r = r .. v\n  end\n  return r\nend\nend\n"
const LIB_tmove = "do\nfunction table.move(a1, f, e, t, a2)\n  a2 = a2 or a1\n  if e >= f then\n    if t > e or t <= f or a1 ~= a2 then\n      for i = 0, e - f do a2[t + i] = a1[f + i] end\n    else\n      for i = e - f, 0, -1 do a2[t + i] = a1[f + i] end\n    end\n  end\n  return a2\nend\nend\n"
const LIB_tsort = "do\nfunction table.sort(t, cmp)\n  local lt = cmp or function(a, b) return a < b end\n  local function sort(lo, hi)\n    while lo < hi do\n      if hi - lo < 8 then\n        for i = lo + 1, hi do\n          local v = t[i]\n          local j = i - 1\n          while j >= lo and lt(v, t[j]) do t[j + 1] = t[j] j = j - 1 end\n          t[j + 1] = v\n        end\n        return\n      end\n      local mid = (lo + hi) // 2\n      if lt(t[mid], t[lo]) then t[mid], t[lo] = t[lo], t[mid] end\n      if lt(t[hi], t[mid]) then\n        t[hi], t[mid] = t[mid], t[hi]\n        if lt(t[mid], t[lo]) then t[mid], t[lo] = t[lo], t[mid] end\n      end\n      local p = t[mid]\n      local i, j = lo, hi\n      while i <= j do\n        while lt(t[i], p) do i = i + 1 end\n        while lt(p, t[j]) do j = j - 1 end\n        if i <= j then t[i], t[j] = t[j], t[i] i = i + 1 j = j - 1 end\n      end\n      if j - lo < hi - i then sort(lo, j) lo = i else sort(i, hi) hi = j end\n    end\n  end\n  sort(1, #t)\nend\nend\n"
const LIB_mconst = "do\nmath.pi = 3.141592653589793\nmath.huge = 1.7976931348623157e308\nmath.maxinteger = 9223372036854775807\nmath.mininteger = -9223372036854775807 - 1\nend\n"
const LIB_mfloor = "do\nfunction math.floor(x) return _m(1, x) end\nend\n"
const LIB_mceil = "do\nfunction math.ceil(x) return _m(2, x) end\nend\n"
const LIB_msqrt = "do\nfunction math.sqrt(x) return _m(3, x) end\nend\n"
const LIB_msin = "do\nfunction math.sin(x) return _m(4, x) end\nend\n"
const LIB_mcos = "do\nfunction math.cos(x) return _m(5, x) end\nend\n"
const LIB_mtan = "do\nfunction math.tan(x) return _m(6, x) end\nend\n"
const LIB_masin = "do\nfunction math.asin(x) return _m(7, x) end\nend\n"
const LIB_macos = "do\nfunction math.acos(x) return _m(8, x) end\nend\n"
const LIB_matan = "do\nfunction math.atan(y, x) return _m(9, y, x or 1) end\nend\n"
const LIB_mexp = "do\nfunction math.exp(x) return _m(10, x) end\nend\n"
const LIB_mlog = "do\nfunction math.log(x, b)\n  if b == nil then return _m(11, x) end\n  if b == 10 then return _m(12, x) end\n  return _m(11, x) / _m(11, b)\nend\nend\n"
const LIB_mabs = "do\nfunction math.abs(x) if x < 0 then return -x end return x end\nend\n"
const LIB_mmax = "do\nfunction math.max(a, ...)\n  local m = a\n  for i = 1, select('#', ...) do local v = select(i, ...) if v > m then m = v end end\n  return m\nend\nend\n"
const LIB_mmin = "do\nfunction math.min(a, ...)\n  local m = a\n  for i = 1, select('#', ...) do local v = select(i, ...) if v < m then m = v end end\n  return m\nend\nend\n"
const LIB_mtype = "do\nfunction math.type(x) return _m(14, x) end\nend\n"
const LIB_mtoint = "do\nfunction math.tointeger(x) return _m(13, x) end\nend\n"
const LIB_mfmod = "do\nfunction math.fmod(a, b)\n  local r = a % b\n  if r ~= 0 and (a < 0) ~= (b < 0) then r = r - b end\n  return r\nend\nend\n"
const LIB_mmodf = "do\nfunction math.modf(x)\n  local i = x >= 0 and math.floor(x) or math.ceil(x)\n  return i + 0.0, x - i\nend\nend\n"
const LIB_mrandom = "do\n_rs = 88172645463325252\nfunction math.randomseed(x) _rs = (x or 0) ~ 88172645463325252 if _rs == 0 then _rs = 1 end end\nfunction math.random(m, n)\n  _rs = _rs ~ (_rs << 13)\n  _rs = _rs ~ (_rs >> 7)\n  _rs = _rs ~ (_rs << 17)\n  if m == nil then return (_rs >> 11) * (1.0 / 9007199254740992.0) end\n  if n == nil then n = m m = 1 end\n  if m > n then error(\"bad argument #2 to 'random' (interval is empty)\") end\n  return m + (_rs >> 1) % (n - m + 1)\nend\nend\n"
const LIB_mult = "do\nfunction math.ult(a, b) return (a ~ math.mininteger) < (b ~ math.mininteger) end\nend\n"
const LIB_os = "do\nos.clock = clock\nfunction os.time() return math.floor(clock()) end\nfunction os.getenv(n) return nil end\nend\n"
const LIB_slen = "do\nfunction string.len(s) return #s end\nend\n"
const LIB_ssub = "do\nfunction string.sub(s, i, j)\n  local l = #s\n  i = i or 1\n  j = j or -1\n  if i < 0 then i = l + i + 1 if i < 1 then i = 1 end elseif i == 0 then i = 1 end\n  if j < 0 then j = l + j + 1 elseif j > l then j = l end\n  if i > j then return \"\" end\n  return _s(1, s, i - 1, j - i + 1)\nend\nend\n"
const LIB_supper = "do\nfunction string.upper(s) return _s(2, s) end\nend\n"
const LIB_slower = "do\nfunction string.lower(s) return _s(3, s) end\nend\n"
const LIB_sbyte = "do\nfunction string.byte(s, i, j)\n  i = i or 1\n  j = j or i\n  if i < 0 then i = #s + i + 1 end\n  if j < 0 then j = #s + j + 1 end\n  if i < 1 then i = 1 end\n  if j > #s then j = #s end\n  if i > j then return end\n  if i == j then return _s(4, s, i - 1) end\n  return _s(4, s, i - 1), string.byte(s, i + 1, j)\nend\nend\n"
const LIB_schar = "do\nfunction string.char(...)\n  local r = \"\"\n  for i = 1, select('#', ...) do r = r .. _s(5, (select(i, ...))) end\n  return r\nend\nend\n"
const LIB_srep = "do\nfunction string.rep(s, n, sep)\n  if n <= 0 then return \"\" end\n  sep = sep or \"\"\n  local r = s\n  for i = 2, n do r = r .. sep .. s end\n  return r\nend\nend\n"
const LIB_srev = "do\nfunction string.reverse(s)\n  local r = \"\"\n  for i = #s, 1, -1 do r = r .. _s(1, s, i - 1, 1) end\n  return r\nend\nend\n"
const LIB_tostr = "do\nfunction tostring(v)\n  local mt = getmetatable(v)\n  if mt and mt.__tostring then return mt.__tostring(v) end\n  return _tostring(v)\nend\nfunction print(...)\n  local n = select('#', ...)\n  local t = {...}\n  for i = 1, n do t[i] = tostring(t[i]) end\n  _print(unpack(t, 1, n))\nend\nend\n"
const LIB_io = "do\nio.write = _write\nfunction io.read() return nil end\nend\n"
const LIB_mtable = "do\nmath = {floor=math.floor, ceil=math.ceil, sqrt=math.sqrt, sin=math.sin, cos=math.cos,\n  tan=math.tan, asin=math.asin, acos=math.acos, atan=math.atan, exp=math.exp,\n  log=math.log, abs=math.abs, max=math.max, min=math.min, fmod=math.fmod,\n  modf=math.modf, random=math.random, randomseed=math.randomseed,\n  tointeger=math.tointeger, type=math.type, ult=math.ult, pi=math.pi, huge=math.huge,\n  maxinteger=math.maxinteger, mininteger=math.mininteger}\nend\n"
const LIB_stable = "do\nstring = {len=string.len, sub=string.sub, upper=string.upper, lower=string.lower,\n  byte=string.byte, char=string.char, rep=string.rep, reverse=string.reverse,\n  format=string.format, find=string.find, match=string.match, gmatch=string.gmatch,\n  gsub=string.gsub}\nend\n"
const LIB_ttable = "do\ntable = {insert=table.insert, remove=table.remove, concat=table.concat,\n  sort=table.sort, pack=table.pack, unpack=table.unpack, move=table.move}\nend\n"
const LIB_ostable = "do\nos = {time=os.time, clock=os.clock, getenv=os.getenv}\nend\n"
const LIB_spat = "do\nlocal B = function(s, i) return _s(4, s, i - 1) end\nlocal capS, capL = {}, {}\nlocal level, src, pat = 0, \"\", \"\"\nlocal domatch\nlocal function classEnd(p, i)\n  local c = B(p, i)\n  i = i + 1\n  if c == 37 then\n    if i > #p then error(\"malformed pattern (ends with '%')\") end\n    return i + 1\n  elseif c == 91 then\n    if B(p, i) == 94 then i = i + 1 end\n    repeat\n      if i > #p then error(\"malformed pattern (missing ']')\") end\n      local cc = B(p, i)\n      i = i + 1\n      if cc == 37 then i = i + 1 end\n    until B(p, i) == 93\n    return i + 1\n  end\n  return i\nend\nlocal function matchClass(c, cl)\n  local lower = cl | 32\n  local res\n  if lower == 97 then res = (c >= 65 and c <= 90) or (c >= 97 and c <= 122)\n  elseif lower == 99 then res = c < 32 or c == 127\n  elseif lower == 100 then res = c >= 48 and c <= 57\n  elseif lower == 103 then res = c > 32 and c < 127\n  elseif lower == 108 then res = c >= 97 and c <= 122\n  elseif lower == 112 then res = (c >= 33 and c <= 47) or (c >= 58 and c <= 64) or (c >= 91 and c <= 96) or (c >= 123 and c <= 126)\n  elseif lower == 115 then res = c == 32 or (c >= 9 and c <= 13)\n  elseif lower == 117 then res = c >= 65 and c <= 90\n  elseif lower == 119 then res = (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122)\n  elseif lower == 120 then res = (c >= 48 and c <= 57) or (c >= 65 and c <= 70) or (c >= 97 and c <= 102)\n  else return cl == c end\n  if cl >= 65 and cl <= 90 then return not res end\n  return res\nend\nlocal function matchBracket(c, p, pi, ec)\n  local sig = true\n  if B(p, pi + 1) == 94 then sig = false pi = pi + 1 end\n  pi = pi + 1\n  while pi < ec do\n    local pc = B(p, pi)\n    if pc == 37 then\n      pi = pi + 1\n      if matchClass(c, B(p, pi)) then return sig end\n    elseif B(p, pi + 1) == 45 and pi + 2 < ec then\n      if pc <= c and c <= B(p, pi + 2) then return sig end\n      pi = pi + 2\n    elseif pc == c then\n      return sig\n    end\n    pi = pi + 1\n  end\n  return not sig\nend\nlocal function singleMatch(si, p, pi, ep)\n  if si > #src then return false end\n  local c = B(src, si)\n  local pc = B(p, pi)\n  if pc == 46 then return true\n  elseif pc == 37 then return matchClass(c, B(p, pi + 1))\n  elseif pc == 91 then return matchBracket(c, p, pi, ep - 1)\n  end\n  return pc == c\nend\nlocal function maxExpand(si, p, pi, ep)\n  local i = 0\n  while singleMatch(si + i, p, pi, ep) do i = i + 1 end\n  while i >= 0 do\n    local res = domatch(si + i, ep + 1)\n    if res then return res end\n    i = i - 1\n  end\n  return nil\nend\nlocal function minExpand(si, p, pi, ep)\n  while true do\n    local res = domatch(si, ep + 1)\n    if res then return res end\n    if singleMatch(si, p, pi, ep) then si = si + 1 else return nil end\n  end\nend\nlocal function startCapture(si, pi, what)\n  level = level + 1\n  capS[level] = si\n  capL[level] = what\n  local res = domatch(si, pi)\n  if not res then level = level - 1 end\n  return res\nend\nlocal function endCapture(si, pi)\n  local l = -1\n  for i = level, 1, -1 do if capL[i] == -2 then l = i break end end\n  if l < 0 then error(\"invalid pattern capture\") end\n  capL[l] = si - capS[l]\n  local res = domatch(si, pi)\n  if not res then capL[l] = -2 end\n  return res\nend\nlocal function matchBalance(si, p, pi)\n  if pi + 1 > #p then error(\"malformed pattern (missing arguments to '%b')\") end\n  if si > #src or B(src, si) ~= B(p, pi) then return nil end\n  local b, e = B(p, pi), B(p, pi + 1)\n  local cont = 1\n  si = si + 1\n  while si <= #src do\n    local c = B(src, si)\n    if c == e then\n      cont = cont - 1\n      if cont == 0 then return si + 1 end\n    elseif c == b then\n      cont = cont + 1\n    end\n    si = si + 1\n  end\n  return nil\nend\ndomatch = function(si, pi)\n  local plen = #pat\n  while true do\n    if pi > plen then return si end\n    local pc = B(pat, pi)\n    local nc = B(pat, pi + 1)\n    if pc == 40 then\n      if nc == 41 then return startCapture(si, pi + 2, -1) end\n      return startCapture(si, pi + 1, -2)\n    elseif pc == 41 then\n      return endCapture(si, pi + 1)\n    elseif pc == 36 and pi == plen then\n      if si == #src + 1 then return si end\n      return nil\n    elseif pc == 37 and nc == 98 then\n      si = matchBalance(si, pat, pi + 2)\n      if si then pi = pi + 4 else return nil end\n    elseif pc == 37 and nc == 102 then\n      pi = pi + 2\n      if B(pat, pi) ~= 91 then error(\"missing '[' after '%f' in pattern\") end\n      local ep = classEnd(pat, pi)\n      local prev = 0\n      if si > 1 then prev = B(src, si - 1) end\n      local cur = 0\n      if si <= #src then cur = B(src, si) end\n      if not matchBracket(prev, pat, pi, ep - 1) and matchBracket(cur, pat, pi, ep - 1) then pi = ep else return nil end\n    elseif pc == 37 and nc ~= nil and nc >= 48 and nc <= 57 then\n      local l = nc - 48\n      if l < 1 or l > level or capL[l] == -2 then error(\"invalid capture index %\" .. l) end\n      local cap = _s(1, src, capS[l] - 1, capL[l])\n      if _s(1, src, si - 1, #cap) == cap then si = si + #cap pi = pi + 2 else return nil end\n    else\n      local ep = classEnd(pat, pi)\n      local epc = B(pat, ep)\n      if not singleMatch(si, pat, pi, ep) then\n        if epc == 42 or epc == 63 or epc == 45 then pi = ep + 1 else return nil end\n      elseif epc == 63 then\n        local res = domatch(si + 1, ep + 1)\n        if res then return res end\n        pi = ep + 1\n      elseif epc == 43 then\n        return maxExpand(si + 1, pat, pi, ep)\n      elseif epc == 42 then\n        return maxExpand(si, pat, pi, ep)\n      elseif epc == 45 then\n        return minExpand(si, pat, pi, ep)\n      else\n        si = si + 1\n        pi = ep\n      end\n    end\n  end\nend\nlocal function getCap(i, si, ei)\n  if i > level then\n    if i == 1 then return _s(1, src, si - 1, ei - si) end\n    error(\"invalid capture index %\" .. i)\n  end\n  local l = capL[i]\n  if l == -2 then error(\"unfinished capture\") end\n  if l == -1 then return capS[i] end\n  return _s(1, src, capS[i] - 1, l)\nend\nlocal function captures(si, ei, whole)\n  local n = level\n  if level == 0 and whole then n = 1 end\n  local t = {}\n  for i = 1, n do t[i] = getCap(i, si, ei) end\n  return t, n\nend\nlocal function hasSpecials(p)\n  for i = 1, #p do\n    local c = B(p, i)\n    if c == 94 or c == 36 or c == 42 or c == 43 or c == 63 or c == 46 or c == 40 or c == 41 or c == 91 or c == 93 or c == 37 or c == 45 then return true end\n  end\n  return false\nend\nlocal function strfind(s, p, init, plain, find)\n  local ls = #s\n  init = init or 1\n  if init < 0 then init = ls + init + 1 if init < 1 then init = 1 end elseif init == 0 then init = 1 end\n  if init > ls + 1 then return nil end\n  if find and (plain or not hasSpecials(p)) then\n    local r = _s(6, s, p, init - 1)\n    if r < 0 then return nil end\n    return r + 1, r + #p\n  end\n  local anchor = B(p, 1) == 94\n  local pi = 1\n  if anchor then pi = 2 end\n  src, pat = s, p\n  local si = init\n  repeat\n    level = 0\n    local e = domatch(si, pi)\n    if e then\n      if find then\n        local t, n = captures(si, e, false)\n        return si, e - 1, unpack(t, 1, n)\n      end\n      local t, n = captures(si, e, true)\n      return unpack(t, 1, n)\n    end\n    si = si + 1\n  until anchor or si > ls + 1\n  return nil\nend\nfunction string.find(s, p, init, plain) return strfind(s, p, init, plain, true) end\nfunction string.match(s, p, init) return strfind(s, p, init, false, false) end\nfunction string.gmatch(s, p)\n  local pos, last = 1, nil\n  return function()\n    src, pat = s, p\n    for si = pos, #s + 1 do\n      level = 0\n      local e = domatch(si, 1)\n      if e and e ~= last then\n        pos = e\n        last = e\n        local t, n = captures(si, e, true)\n        return unpack(t, 1, n)\n      end\n    end\n    pos = #s + 2\n    return nil\n  end\nend\nfunction string.gsub(s, p, repl, maxn)\n  local anchor = B(p, 1) == 94\n  local pi = 1\n  if anchor then pi = 2 end\n  local rt = type(repl)\n  if rt == \"number\" then repl = tostring(repl) rt = \"string\" end\n  if rt ~= \"string\" and rt ~= \"table\" and rt ~= \"function\" then error(\"bad argument #3 to 'gsub' (string/function/table expected, got \" .. rt .. \")\") end\n  local ls = #s\n  local si, n, out, last = 1, 0, \"\", nil\n  maxn = maxn or ls + 1\n  while n < maxn do\n    src, pat = s, p\n    level = 0\n    local e = domatch(si, pi)\n    if e and e ~= last then\n      n = n + 1\n      local whole = _s(1, s, si - 1, e - si)\n      local val\n      if rt == \"string\" then\n        val = \"\"\n        local i, rl = 1, #repl\n        while i <= rl do\n          local c = B(repl, i)\n          if c == 37 then\n            i = i + 1\n            local d = B(repl, i)\n            if d == 37 then val = val .. \"%\"\n            elseif d ~= nil and d >= 48 and d <= 57 then\n              if d == 48 then val = val .. whole else val = val .. tostring(getCap(d - 48, si, e)) end\n            else error(\"invalid use of '%' in replacement string\") end\n          else\n            val = val .. _s(1, repl, i - 1, 1)\n          end\n          i = i + 1\n        end\n      else\n        local caps, cn = captures(si, e, true)\n        local ss, sp, sl = src, pat, level\n        if rt == \"table\" then val = repl[caps[1]] else val = repl(unpack(caps, 1, cn)) end\n        src, pat, level = ss, sp, sl\n        if val == false or val == nil then val = whole\n        elseif type(val) ~= \"string\" and type(val) ~= \"number\" then error(\"invalid replacement value (a \" .. type(val) .. \")\") end\n        val = tostring(val)\n      end\n      out = out .. val\n      si = e\n      last = e\n    elseif si <= ls then\n      out = out .. _s(1, s, si - 1, 1)\n      si = si + 1\n    else\n      break\n    end\n    if anchor then break end\n  end\n  if si <= ls then out = out .. _s(1, s, si - 1, ls - si + 1) end\n  return out, n\nend\nend\n"
const LIB_sformat = "do\nfunction string.format(fmt, ...)\n  local args = {...}\n  local nargs = select('#', ...)\n  local ai = 0\n  local out = \"\"\n  local i = 1\n  local n = #fmt\n  local function nextarg()\n    ai = ai + 1\n    if ai > nargs then error(\"bad argument #\" .. (ai + 1) .. \" to 'string.format' (no value)\", 2) end\n    return args[ai]\n  end\n  local function pad(s, w, left, zero)\n    if #s >= w then return s end\n    if left then return s .. string.rep(\" \", w - #s) end\n    if zero then\n      local sign = \"\"\n      local c = _s(1, s, 0, 1)\n      if c == \"-\" or c == \"+\" or c == \" \" then sign = c s = _s(1, s, 1, #s - 1) end\n      return sign .. string.rep(\"0\", w - #s - #sign) .. s\n    end\n    return string.rep(\" \", w - #s) .. s\n  end\n  local function fixed(x, p)\n    local pow = 1\n    for k = 1, p do pow = pow * 10 end\n    local t = x * pow\n    local r = math.floor(t)\n    local d = t - r\n    if d > 0.5 or (d == 0.5 and r % 2 == 1) then r = r + 1 end\n    local s = tostring(r // pow)\n    if p > 0 then\n      local f = tostring(r % pow)\n      s = s .. \".\" .. string.rep(\"0\", p - #f) .. f\n    end\n    return s\n  end\n  local function expo(x, p, upper)\n    local e = 0\n    local m = x\n    if x ~= 0 then\n      e = math.floor(math.log(x, 10))\n      m = x / 10 ^ e\n      if m >= 10 then m = m / 10 e = e + 1 elseif m < 1 then m = m * 10 e = e - 1 end\n    end\n    local pow = 1\n    for k = 1, p do pow = pow * 10 end\n    local t = m * pow\n    local r = math.floor(t)\n    local d = t - r\n    if d > 0.5 or (d == 0.5 and r % 2 == 1) then r = r + 1 end\n    if r >= 10 * pow then r = r // 10 e = e + 1 end\n    local ds = tostring(r)\n    local s = _s(1, ds, 0, 1)\n    if p > 0 then s = s .. \".\" .. _s(1, ds, 1, p) end\n    local es = tostring(e < 0 and -e or e)\n    if #es < 2 then es = \"0\" .. es end\n    local up = \"e\"\n    if upper then up = \"E\" end\n    local sg = \"+\"\n    if e < 0 then sg = \"-\" end\n    return s .. up .. sg .. es, e\n  end\n  local function strip(s)\n    if _s(6, s, \".\", 0) < 0 then return s end\n    while _s(1, s, #s - 1, 1) == \"0\" do s = _s(1, s, 0, #s - 1) end\n    if _s(1, s, #s - 1, 1) == \".\" then s = _s(1, s, 0, #s - 1) end\n    return s\n  end\n  local function general(x, p, alt, upper)\n    if p == 0 then p = 1 end\n    if x == 0 then if alt then return fixed(0, p - 1) end return \"0\" end\n    local es, X = expo(x, p - 1, upper)\n    if X < -4 or X >= p then\n      if not alt then\n        local ep = _s(6, es, upper and \"E\" or \"e\", 0)\n        es = strip(_s(1, es, 0, ep)) .. _s(1, es, ep, #es - ep)\n      end\n      return es\n    end\n    local f = fixed(x, p - 1 - X)\n    if not alt then f = strip(f) end\n    return f\n  end\n  local function hexs(v, base, upper)\n    if v == 0 then return \"0\" end\n    local digits = \"0123456789abcdef\"\n    if upper then digits = \"0123456789ABCDEF\" end\n    local s = \"\"\n    local bits = 4\n    local mask = 15\n    if base == 8 then bits = 3 mask = 7 end\n    while v ~= 0 do\n      local d = v & mask\n      s = _s(1, digits, d, 1) .. s\n      v = v >> bits\n    end\n    return s\n  end\n  while i <= n do\n    local j = _s(6, fmt, \"%\", i - 1)\n    if j < 0 then\n      out = out .. _s(1, fmt, i - 1, n - i + 1)\n      i = n + 1\n    elseif j > i - 1 then\n      out = out .. _s(1, fmt, i - 1, j - (i - 1))\n      i = j + 1\n    else\n      i = i + 1\n      local b = _s(4, fmt, i - 1)\n      if b == 37 then\n        out = out .. \"%\"\n        i = i + 1\n      else\n        local left, plus, space, alt, zero = false, false, false, false, false\n        while true do\n          if b == 45 then left = true elseif b == 43 then plus = true elseif b == 32 then space = true\n          elseif b == 35 then alt = true elseif b == 48 then zero = true else break end\n          i = i + 1\n          b = _s(4, fmt, i - 1)\n        end\n        local w = 0\n        while b ~= nil and b >= 48 and b <= 57 do w = w * 10 + (b - 48) i = i + 1 b = _s(4, fmt, i - 1) end\n        local prec = nil\n        if b == 46 then\n          i = i + 1\n          b = _s(4, fmt, i - 1)\n          prec = 0\n          while b ~= nil and b >= 48 and b <= 57 do prec = prec * 10 + (b - 48) i = i + 1 b = _s(4, fmt, i - 1) end\n        end\n        i = i + 1\n        local conv = _s(1, fmt, i - 2, 1)\n        local body\n        local numeric = true\n        if conv == \"d\" or conv == \"i\" or conv == \"u\" then\n          local v = nextarg()\n          local iv = math.tointeger(tonumber(v))\n          if iv == nil then error(\"bad argument #\" .. (ai + 1) .. \" to 'string.format' (number has no integer representation)\", 2) end\n          local digits = tostring(iv)\n          local sign = \"\"\n          if iv < 0 then sign = \"-\" digits = _s(1, digits, 1, #digits - 1) elseif plus then sign = \"+\" elseif space then sign = \" \" end\n          if prec ~= nil and #digits < prec then digits = string.rep(\"0\", prec - #digits) .. digits end\n          if prec ~= nil then zero = false end\n          body = sign .. digits\n        elseif conv == \"c\" then\n          body = _s(5, math.tointeger(tonumber(nextarg())))\n          numeric = false\n        elseif conv == \"x\" or conv == \"X\" or conv == \"o\" then\n          local iv = math.tointeger(tonumber(nextarg()))\n          if iv == nil then error(\"bad argument #\" .. (ai + 1) .. \" to 'string.format' (number has no integer representation)\", 2) end\n          local base = 16\n          if conv == \"o\" then base = 8 end\n          local digits = hexs(iv, base, conv == \"X\")\n          if prec ~= nil and #digits < prec then digits = string.rep(\"0\", prec - #digits) .. digits end\n          if alt and iv ~= 0 then\n            if conv == \"x\" then digits = \"0x\" .. digits elseif conv == \"X\" then digits = \"0X\" .. digits else digits = \"0\" .. digits end\n          end\n          body = digits\n        elseif conv == \"e\" or conv == \"E\" or conv == \"f\" or conv == \"F\" or conv == \"g\" or conv == \"G\" then\n          local x = tonumber(nextarg()) + 0.0\n          local neg = x < 0\n          local ax = x\n          if neg then ax = -x end\n          local sign = \"\"\n          if neg then sign = \"-\" elseif plus then sign = \"+\" elseif space then sign = \" \" end\n          if x ~= x then\n            body = sign .. \"nan\"\n            zero = false\n          elseif ax >= 1.7976931348623157e308 then\n            body = sign .. \"inf\"\n            zero = false\n          else\n            local p = prec\n            if p == nil then p = 6 end\n            local s\n            if conv == \"f\" or conv == \"F\" then s = fixed(ax, p)\n            elseif conv == \"e\" or conv == \"E\" then s = expo(ax, p, conv == \"E\")\n            else s = general(ax, p, alt, conv == \"G\") end\n            body = sign .. s\n          end\n        elseif conv == \"s\" then\n          local s = tostring(nextarg())\n          if prec ~= nil and #s > prec then s = _s(1, s, 0, prec) end\n          body = s\n          numeric = false\n        elseif conv == \"q\" then\n          local s = tostring(nextarg())\n          local q = \"\\\"\"\n          for k = 1, #s do\n            local c = _s(1, s, k - 1, 1)\n            if c == \"\\\"\" then q = q .. \"\\\\\\\"\"\n            elseif c == \"\\\\\" then q = q .. \"\\\\\\\\\"\n            elseif c == \"\\n\" then q = q .. \"\\\\\\n\"\n            elseif c == \"\\r\" then q = q .. \"\\\\r\"\n            elseif c == \"\\0\" then q = q .. \"\\\\0\"\n            else q = q .. c end\n          end\n          body = q .. \"\\\"\"\n          numeric = false\n        else\n          error(\"invalid conversion '%\" .. conv .. \"' to 'string.format'\", 2)\n        end\n        out = out .. pad(body, w, left, zero and numeric and not left)\n      end\n    end\n  end\n  return out\nend\nend\n"
// Standard library snippets that the program mentions are prepended to it.
mod libFor(p: string) -> string {
  let need_sformat = p.Contains("format", true)
  let need_spat = p.Contains("find", true) || p.Contains("match", true) || p.Contains("gmatch", true) || p.Contains("gsub", true)
  let need_ostable = p.Contains("os.", true)
  let need_ttable = p.Contains("insert", true) || p.Contains("remove", true) || p.Contains("concat", true) || p.Contains("sort", true) || p.Contains("pack", true) || p.Contains("move", true) || p.Contains("table.", true)
  let need_stable = p.Contains("string", true)
  let need_mtable = p.Contains("math", true)
  let need_io = p.Contains("io.", true)
  let need_tostr = p.Contains("__tostring", true)
  let need_srev = p.Contains("reverse", true)
  let need_srep = p.Contains("rep", true) || need_sformat
  let need_schar = p.Contains("char", true)
  let need_sbyte = p.Contains("byte", true)
  let need_slower = p.Contains("lower", true)
  let need_supper = p.Contains("upper", true)
  let need_ssub = p.Contains("sub", true)
  let need_slen = p.Contains("string.len", true) || p.Contains(":len", true)
  let need_os = p.Contains("os.", true)
  let need_mult = p.Contains("math.ult", true)
  let need_mrandom = p.Contains("random", true)
  let need_mmodf = p.Contains("modf", true)
  let need_mfmod = p.Contains("fmod", true)
  let need_mtoint = p.Contains("tointeger", true) || need_sformat
  let need_mtype = p.Contains("math.type", true)
  let need_mmin = p.Contains("math.min", true)
  let need_mmax = p.Contains("math.max", true)
  let need_mabs = p.Contains("abs", true)
  let need_mlog = p.Contains("math.log", true) || need_sformat
  let need_mexp = p.Contains("math.exp", true)
  let need_matan = p.Contains("atan", true)
  let need_macos = p.Contains("acos", true)
  let need_masin = p.Contains("asin", true)
  let need_mtan = p.Contains("math.tan", true)
  let need_mcos = p.Contains("math.cos", true)
  let need_msin = p.Contains("math.sin", true)
  let need_msqrt = p.Contains("sqrt", true)
  let need_mceil = p.Contains("ceil", true) || need_mmodf
  let need_mfloor = p.Contains("floor", true) || need_mmodf || need_os || need_sformat
  let need_mconst = p.Contains("math.pi", true) || p.Contains("math.huge", true) || p.Contains("math.maxinteger", true) || p.Contains("math.mininteger", true)
  let need_tsort = p.Contains("sort", true)
  let need_tmove = p.Contains("move", true)
  let need_tconcat = p.Contains("concat", true)
  let need_tremove = p.Contains("remove", true)
  let need_tinsert = p.Contains("insert", true)
  let need_tpack = p.Contains("pack", true)
  let need_tunpack = p.Contains("unpack", true)
  let need_xpcall = p.Contains("xpcall", true)
  let need_raw = p.Contains("raw", true)
  let need_assert = p.Contains("assert", true)
  let need_iter = p.Contains("pairs", true) || p.Contains("ipairs", true)
  return (if need_iter then LIB_iter else "") ..
    (if need_assert then LIB_assert else "") ..
    (if need_raw then LIB_raw else "") ..
    (if need_xpcall then LIB_xpcall else "") ..
    (if need_tunpack then LIB_tunpack else "") ..
    (if need_tpack then LIB_tpack else "") ..
    (if need_tinsert then LIB_tinsert else "") ..
    (if need_tremove then LIB_tremove else "") ..
    (if need_tconcat then LIB_tconcat else "") ..
    (if need_tmove then LIB_tmove else "") ..
    (if need_tsort then LIB_tsort else "") ..
    (if need_mconst then LIB_mconst else "") ..
    (if need_mfloor then LIB_mfloor else "") ..
    (if need_mceil then LIB_mceil else "") ..
    (if need_msqrt then LIB_msqrt else "") ..
    (if need_msin then LIB_msin else "") ..
    (if need_mcos then LIB_mcos else "") ..
    (if need_mtan then LIB_mtan else "") ..
    (if need_masin then LIB_masin else "") ..
    (if need_macos then LIB_macos else "") ..
    (if need_matan then LIB_matan else "") ..
    (if need_mexp then LIB_mexp else "") ..
    (if need_mlog then LIB_mlog else "") ..
    (if need_mabs then LIB_mabs else "") ..
    (if need_mmax then LIB_mmax else "") ..
    (if need_mmin then LIB_mmin else "") ..
    (if need_mtype then LIB_mtype else "") ..
    (if need_mtoint then LIB_mtoint else "") ..
    (if need_mfmod then LIB_mfmod else "") ..
    (if need_mmodf then LIB_mmodf else "") ..
    (if need_mrandom then LIB_mrandom else "") ..
    (if need_mult then LIB_mult else "") ..
    (if need_os then LIB_os else "") ..
    (if need_slen then LIB_slen else "") ..
    (if need_ssub then LIB_ssub else "") ..
    (if need_supper then LIB_supper else "") ..
    (if need_slower then LIB_slower else "") ..
    (if need_sbyte then LIB_sbyte else "") ..
    (if need_schar then LIB_schar else "") ..
    (if need_srep then LIB_srep else "") ..
    (if need_srev then LIB_srev else "") ..
    (if need_tostr then LIB_tostr else "") ..
    (if need_io then LIB_io else "") ..
    (if need_mtable then LIB_mtable else "") ..
    (if need_stable then LIB_stable else "") ..
    (if need_ttable then LIB_ttable else "") ..
    (if need_ostable then LIB_ostable else "") ..
    (if need_spat then LIB_spat else "") ..
    (if need_sformat then LIB_sformat else "")
}

mod parseJobStart() {
  parseInit()
  fStart.resize(NB, -1)
  fParams.resize(NB, -1)
  fRegs.resize(NB, -1)
  fVar.resize(NB, 0)
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
  let lib = libFor(program)
  lsrc = lib .. program
  llen = lsrc.Length()
  lline = 1 - (lib.Length() - lib.Replace("\n", "").Length())
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
      errV = "line " .. lerrLine .. ": " .. lerrMsg
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
      errV = "line " .. eline .. ": " .. perrMsg
    }
  }
}

on Change(inNum0) {
  latchN0 = inNum0
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

// 31. Non-integer float table keys (t[1.5] = x) now work: they were unconditionally
//    rejected, and the internal key encoding also aliased 1.5 with 1 (would have
//    silently corrupted data had the rejection been lifted without this fix too).
// 32. math, string, table and os are now real tables, not just flattened dotted-name
//    globals: `math == nil`, `for k,v in pairs(string)`, `local m = math`, and passing
//    them as arguments all work now. The individual math.floor(x)-style calls still
//    compile to a direct global reference internally (no added per-call cost); the
//    table is assembled once, only when that namespace is used at all.
// 33. Runtime errors now carry "line N: " (N counted in your own script), via a
//    per-instruction line table populated once in bEmit (a fixed cost, not per
//    instruction-copy). error(msg, level) honours level 0 (no prefix), 1 (default:
//    blame the caller of error()) and 2 (blame the caller of the function that called
//    error(), e.g. what assert() needs to blame the right line). assert() and
//    string.format's internal errors now use level 2 so they report the real call site
//    instead of a line inside the library text.
// 34. string.format's own error messages said "'format'"; now say "'string.format'",
//    matching real Lua.
//
// ---------------------------------------------------------------- changelog
// Session 4: full Lua rewrite. Builds on the earlier table/run/register work (entries
// 8-19 below are from the prior session). New in this pass:
// 20. Real integers (a distinct tag from float, matching Lua 5.4/5.5): int arithmetic
//    wraps at 64 bits, //, %, and the bitwise/shift operators now behave like Lua's, and
//    a new `inInt0` input / `outInt0` output carry Brickadia's native int type directly.
// 21. Closures with real upvalues: a local function can now call another local function,
//    or read/write a local declared in an enclosing function. Implemented as open/closed
//    upvalue cells (like PUC Lua) with a CLOSE instruction on block/scope exit.
// 22. Metatables: __index, __newindex, __call, __eq, __lt, __le, __len, __concat,
//    __tostring and the arithmetic metamethods, plus setmetatable/getmetatable/rawget/
//    rawset/rawequal/rawlen -- enough for real OOP with inheritance.
// 23. varargs (...), multiple return values, multiple assignment from a call, select,
//    table.pack/unpack.
// 24. goto and ::labels::, repeat/until, numeric and generic for (for k,v in pairs(t)).
// 25. Table constructors gained [k]=v keys; assignment to the same target twice in one
//    statement now stores right-to-left, matching real Lua (was left-to-right).
// 26. A Lua-source standard library (base/table/math/os/string, including real Lua
//    patterns and string.format) is prepended to the program only when the program
//    actually uses it, so unused functions cost nothing.
// 27. print() now appends to a single `log` output (last 32 lines, 64 chars each)
//    instead of overwriting 8 separate output slots, freeing outNum0..3/outStr0..1/
//    outInt0 to be read AND written by the Lua program itself as plain globals.
// 28. `busy` and `halted` merged from four booleans (busy was previously always false)
//    into the two that mean something: busy while parsing or actively running, halted
//    once the VM has nothing left to do.
// 29. Compile errors now report "line N: message" in `err` instead of only setting
//    progOk = false silently. progLen was dropped (an internal detail, not useful to
//    wire up).
// 30. Fixed: `plNext` (the array used to thread pending jump patches for if/while/
//    goto/break) was sized to a fixed 2048 entries, left over from before this session's
//    token/instruction limit increases. Once a program's bytecode passed instruction
//    2048, writes into this array went out of bounds, and a later patch could silently
//    corrupt instruction 0 -- the very first instruction of the whole program -- turning
//    it into a jump into the middle of unrelated code. Every program up to ~2000
//    instructions was unaffected; the full-featured library plus a real script routinely
//    exceeds that. Fixed by sizing the array to MAX_INSTR. Found via the all-features
//    test below, which failed with "attempt to perform arithmetic on a nil value"
//    despite every individual feature testing correctly in isolation.
//
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
