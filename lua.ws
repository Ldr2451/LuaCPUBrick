/// Tiny Lua: numbers, strings, booleans, nil, functions, tables, globals + locals.
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
/// Language subset (anything else is a compile error and sets progOk = false)
///   types      numbers (one double type), strings, booleans, nil, functions, tables
///   vars       globals (the inputs, the writable outputs, plus print, type, tostring,
///              setvec, setcol, clock, inarr, outarr) and locals; shadowing works;
///              upvalues do NOT (loud compile error), so a function cannot call a local
///              function or read a local defined outside it
///   stmts      local (single or multi), assignment (single or parallel, to names or
///              table fields; stores run right to left like PUC Lua), if / elseif / else,
///              while, break, do / end, function f() and local function f(), return
///              (single value), calls (including f"str" and chained f()())
///   exprs      + - * / % ^ (power, right assoc), unary -, # (length of a table or string),
///              .. (concat), < > <= >= == ~= (non-associative, like Lua), and, or, not
///   tables     constructors {}, {1, 2, 3}, {x = 1, y = 2}, {[k] = v}, mixed, with , or ;
///              separators and a trailing separator; t[k], t.name, t[k] = v, t.name = v,
///              nesting (m[i][j], t.a.b), t[i], t[j] = t[j], t[i]; #t; assigning nil
///              deletes a key. Tables are references and compare by identity. Keys may be
///              integers, strings, booleans, tables or functions. Functions can be stored
///              in fields and called as t.f(x).
///              NOT supported: non-integer number keys (a runtime error on write, nil on
///              read), pairs / ipairs / next, for loops, the table library, metatables,
///              t:method() calls, mixing plain names and table fields in one statement.
///              #t returns a border like Lua: it follows t[#t + 1] = v appends and fills
///              in out-of-order assignments. Reading a missing key gives nil.
///   calls      missing args become nil, extras dropped; bare `return` and falling off
///              the end yield ZERO values (print(f()) prints nothing); `return a, b` is
///              rejected (single value only)
///   builtins   print(...) -> log; type(v), tostring(v) (a table prints as "table");
///              setvec(x, y, z) -> outVec; setcol(r, g, b, a) -> outCol;
///              inarr(i) -> inArr[i] (1-based, out-of-range reads nil);
///              outarr(i, v) -> outArr[i] = v (1-based, out-of-range is an error);
///              clock() -> seconds (ServerUptime)
///   numbers    integers (exact on-chip inside +/-2^53; Lua wraps 64-bit
///              beyond that) and floats: 0.5 .5 5. 1e3 1E-3, hex ints 0xFF.
///              / and ^ always return floats. Ints print bare (3), floats
///              print Lua-style (3.0); 'x' .. 1 gives "x1", #t prints like 3
///   strings    "..." and '...' with \n \r \t \\ \" \' \<newline>, \z, \ddd and \xXX
///              for printable ASCII (32..126); other escapes are a compile error
///   compare    == and ~= work on all types without coercion (tables by identity);
///              < > <= >= work on numbers or lexicographically on strings;
///              arithmetic never coerces strings
///   divzero    x/0, x%0 and 0/0 yield 0 (Brickadia gate behavior, unlike Lua inf/nan)
///   missing    for, methods, goto, bitwise operators, coroutines, metatables, modules,
///              pcall / error, closures / upvalues, multiple return values
///
/// Other differences from PUC-Lua 5.4
///   Runtime errors halt with err set (there is no pcall). tostring of a table is
///   "table" (PUC prints an address). t[nil] reads nil (PUC errors). outNum0..outNum3
///   only take numbers/booleans/nil and outArr only numbers (PUC tables take anything;
///   fixed-size float storage is a gate limitation). The log keeps the last 32 lines
///   at 64 chars each (about 2 KB).
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
const MAX_INSTR = 512
const MAX_REGS = 64
const MAX_FUNCS = 32
const MAX_GLOBALS = 64
const MAX_CALLS = 32
const MAX_TABLES = 64
const MAX_HEAP = 512

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
// SYM ids: +1 -2 *3 /4 %5 ^6 <7 >8 <=9 >=10 ==11 ~=12 =13 (14 )15 ,16 ;17 ..18 &25 |26 ~27 <<28 >>29 //30
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
  if tk.length() > 1024 {
    lexFail("too many tokens (max 1024)")
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
            lexFail("varargs '...' not supported")
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
          lstage = 10
          lpos = lpos + 2
        } else {
          emitTok(5, 2, 0.0, "")
          lpos = lpos + 1
        }
      } else if cp == 42 {
        emitTok(5, 3, 0.0, "")
        lpos = lpos + 1
      } else if cp == 47 {
        emitTok(5, 4, 0.0, "")
        lpos = lpos + 1
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
        } else {
          emitTok(5, 7, 0.0, "")
          lpos = lpos + 1
        }
      } else if cp == 62 {
        if cp2 == 61 {
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
        } else {
          lexFail("unexpected character")
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
        emitTok(5, 21, 0.0, "")
        lpos = lpos + 1
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
        lpos = lpos + 1
      } else if cp == 46 {
        if cp2 >= 48 && cp2 <= 57 {
          lnumDot = true
          lstage = 2
          lpos = lpos + 1
        } else if cp2 == 46 {
          lexFail("malformed number (like Lua '5..3')")
        } else {
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
  bop.clear()
  bpa.clear()
  bpb.clear()
  bpc.clear()
  constNum.clear()
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
  plNext.resize(512, -1)
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
  gDeclare("inInt0")
  gDeclare("outInt0")
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
        perrMsg = "upvalues/closures not supported in Tiny"
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
        perrMsg = "upvalues/closures not supported in Tiny"
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
        perrMsg = "upvalues/closures not supported in Tiny"
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
        perrMsg = "upvalues/closures not supported in Tiny"
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
        perrMsg = "upvalues/closures not supported in Tiny"
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
        perrMsg = "upvalues/closures not supported in Tiny"
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
        perrMsg = "upvalues/closures not supported in Tiny"
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
        perrMsg = "upvalues/closures not supported in Tiny"
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
        perrMsg = "upvalues/closures not supported in Tiny"
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
        perrMsg = "upvalues/closures not supported in Tiny"
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
        perrMsg = "upvalues/closures not supported in Tiny"
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
        perrMsg = "upvalues/closures not supported in Tiny"
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
        perrMsg = "upvalues/closures not supported in Tiny"
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
        perrMsg = "upvalues/closures not supported in Tiny"
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
        perrMsg = "upvalues/closures not supported in Tiny"
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
        perrMsg = "upvalues/closures not supported in Tiny"
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
        perrMsg = "upvalues/closures not supported in Tiny"
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
        perrMsg = "upvalues/closures not supported in Tiny"
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
        perrMsg = "upvalues/closures not supported in Tiny"
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
        perrMsg = "upvalues/closures not supported in Tiny"
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
        perrMsg = "upvalues/closures not supported in Tiny"
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
        perrMsg = "upvalues/closures not supported in Tiny"
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
        perrMsg = "upvalues/closures not supported in Tiny"
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
        perrMsg = "upvalues/closures not supported in Tiny"
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
        perrMsg = "upvalues/closures not supported in Tiny"
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
        perrMsg = "upvalues/closures not supported in Tiny"
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
        perrMsg = "upvalues/closures not supported in Tiny"
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
        perrMsg = "upvalues/closures not supported in Tiny"
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
        perrMsg = "upvalues/closures not supported in Tiny"
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
        perrMsg = "upvalues/closures not supported in Tiny"
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
        perrMsg = "upvalues/closures not supported in Tiny"
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
        perrMsg = "upvalues/closures not supported in Tiny"
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
    let isNot = opA[opA.length() - 1] == 1
    let isLen = opA[opA.length() - 1] == 2
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
mod finishCtorElem() {
  let v = popVal()
  let tr = opA[opA.length() - 1]
  let kr = opB[opB.length() - 1]
  if kr == -1 {
    let idx = opPrec[opPrec.length() - 1] + 1
    opPrec[opPrec.length() - 1] = idx
    let kk = regAlloc()
    bEmit(2, kk, cNum(idx + 0.0), 1)
    bEmit(30, tr, kk, v)
  } else {
    bEmit(30, tr, kr, v)
    opB[opB.length() - 1] = -1
  }
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

mod newFunc() -> int {
  fStart.push(-1)
  fParams.push(0)
  fRegs.push(-1)
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
}

mod funcHeadAnon(fr: int) {
  let skip = bEmit(20, 0, 0, 0)
  pushCtl(3, tmpB, skip, 1, ctlLoop, fr, contKind)
  ctlG[ctlG.length() - 1] = stState
  tmpSStk.push("")
  ctorStk.push(openCtor)
  openCtor = 0
  ctlLoop = -1
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
  if k == 1 {
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
  } else if k == 6 || (k == 5 && s == 17) || (k == 4 && (s == 6 || s == 4 || s == 5)) || (k == 5 && s == 13) || (k == 4 && (s == 3 || s == 15)) {
    closeMode = 3
    popMode = 2
  } else if k == 3 || (k == 4 && (s == 10 || s == 8 || s == 9 || s == 17 || s == 3 || s == 2 || s == 14)) {
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
      opKind.pop()
      opPrec.pop()
      opA.pop()
      opB.pop()
      opC.pop()
      if valStk.length() == depth {
        if nargs == 0 {
          bEmit(23, fr, 0, 0)
          bumpMax(fr + 2)
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
        finishCtorElem()
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
        finishCtorElem()
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
var ctlLoop: int = -1
var pdHead: int = -1
var pdThen: int = 0
var tmpSStk: string[]
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

// Post-unit continuations: 1 expr-stmt, 2 if-cond, 3 elif-cond,
// 4 while-cond, 5 return, 6 local-values, 7 assign-values.
mod atStmtEnd() -> bool {
  let k = curKind()
  let s = curSub()
  return if k == 6 then true
    else if k == 5 && s == 17 then true
    else if k == 4 && (s == 6 || s == 4 || s == 5) then true
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
      perr = true
      perrMsg = "multiple return values not supported"
    } else if presIsCall {
      bEmit(27, presReg, 0, 0)
    } else {
      bEmit(24, presReg, 0, 0)
    }
    inExpr = false
    contKind = 0
  } else if contKind == 6 {
    tmpRegs.push(presReg)
    if curKind() == 5 && curSub() == 16 {
      cpos = cpos + 1
      startUnit(6)
    } else {
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
  } else if contKind == 7 {
    if tmpNames.length() > 1 {
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
  } else {
    pushCtl(3, fid, skip, 0, ctlLoop, 0, 0)
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

// stState 20: parameter list.
mod funcParams() {
  if curKind() == 3 {
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
      bEmit(26, 0, 0, 0)
      fRegs[fid] = cfMax[fnDepth]
      locLen = funcEntryLoc[fnDepth]
      fnDepth = fnDepth - 1
      bPatch(skip, bop.length())
      ctlLoop = ctlD[n]
      tmpS = tmpSStk.pop().Value
      openCtor = ctorStk.pop().Value
      popCtl()
      if resume == 1 {
        pushVal(extra, true, true)
        expectOperand = false
        inExpr = true
        exprDone = false
        contKind = savedCont
        stState = savedSt
      } else if extra == 1 {
        let outer = locDeclare(tmpS)
        bEmit(25, outer, fid, 0)
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
      funcHead(false, 0, 0)
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
// (inputs filled from the latches), 19..26 builtins (print, type, tostring,
// setvec, setcol, clock, inarr, outarr) as functions with ids 0..7.
var GTAG_INIT: int[] = [1, 1, 1, 1, 2, 2, 1, 1, 1, 1, 2, 2, 1, 1, 1, 1, 1, 1, 1, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6]
var GNUM_INIT: float[] = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 0.0, 0.0]

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
  lenChase = false
  vtag.clear()
  vnum.clear()
  vstr.clear()
  vtag.resize(2048, 0)
  vnum.resize(2048, 0.0)
  vstr.resize(2048, "")
  forCtrl.resize(16, 0)
  fFunc.clear()
  fBase.clear()
  fRetA.clear()
  fRetBase.clear()
  fRetPC.clear()
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
  gnum[6] = latchN0
  gnum[7] = latchN1
  gnum[8] = latchN2
  gnum[9] = latchN3
  gstr[10] = latchS0
  gstr[11] = latchS1
  gnum[12] = latchVX
  gnum[13] = latchVY
  gnum[14] = latchVZ
  gnum[15] = latchCR
  gnum[16] = latchCG
  gnum[17] = latchCB
  gnum[18] = latchCA
  gnum[27] = latchI0 + 0.0
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
  oF0 = if gtag[0] == 0 then 0.0 else gnum[0]
  oF1 = if gtag[1] == 0 then 0.0 else gnum[1]
  oF2 = if gtag[2] == 0 then 0.0 else gnum[2]
  oF3 = if gtag[3] == 0 then 0.0 else gnum[3]
  oI0 = if gtag[28] == 0 then 0 else toInt(gnum[28])
  oS4 = if gtag[4] == 0 then "" else fmtVal(gtag[4], gnum[4], gstr[4])
  oS5 = if gtag[5] == 0 then "" else fmtVal(gtag[5], gnum[5], gstr[5])
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

// One VM instruction. Mirrors lua_model.VM.step (same ISA/semantics).
// Composite map key for table `tid`: kt is the key's value tag.
mod tkey(tid: int, kt: int, kn: float, ks: string) -> string {
  return if kt == 1 || kt == 6 then tid .. "#" .. (kn | 0)
    else if kt == 2 then tid .. "$" .. ks
    else tid .. "@" .. kt .. ":" .. (kn | 0)
}

// Normalize integral floats to the int tag so 1 and 1.0 share one key.
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

mod vmStep() {
  if lenChase {
    lenStep()
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
      // outNum0..outNum3 are numeric ports: numbers/booleans/nil only
      if a <= 3 && vTag(b) != 1 && vTag(b) != 6 && vTag(b) != 0 && vTag(b) != 3 {
        vmFail("cannot convert to number (outNum0..outNum3 take numbers)")
      } else if a == 28 {
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
    } else if op == 23 {
      if vTag(a) != 4 {
        vmFail("attempt to call")
      } else {
        let fid = toInt(vNum(a))
        let multitail = if c == 1 then true else false
        let nargs = if multitail then (b - 1) + (if retCountV == 1 then 1 else 0) else b
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
              fFunc.push(fid)
              fBase.push(nbase)
              fRetA.push(a)
              fRetBase.push(vmBase)
              fRetPC.push(vmPc + 1)
              vmBase = nbase
              vmPc = fStart[fid]
              advanced = true
            }
          }
        }
      }
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
      if fFunc.length() == 0 {
        if retCountV == 1 {
          resultV = fmtVal(rv, rn, rs)
        } else {
          resultV = ""
        }
        vmHalted = true
      } else {
        if retCountV == 1 {
          vmBase = rb
          vSet(ra, rv, rn, rs)
        } else {
          vmBase = rb
        }
        vmPc = rpc
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
      if vTag(b) != 5 {
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
      let vt = vTag(c)
      if vTag(a) != 5 {
        vmFail("attempt to index a non-table value")
      } else if kt == 0 {
        vmFail("table index is nil")
      } else if kt == 1 && vNum(b) != floor(vNum(b)) {
        vmFail("non-integer number keys are not supported")
      } else {
        let tid = toInt(vNum(a))
        let key = tkey(tid, kt, vNum(b), vStr(b))
        let r = tmap.get(key)
        let kint = toInt(vNum(b))
        if vt == 0 {
          if r.Found {
            tmap.remove(key)
            tFree.push(r.Value)
            if kt == 6 && kint == tLen[tid] {
              tLen[tid] = kint - 1
            }
          }
        } else {
          var sl = 0
          if r.Found {
            sl = r.Value
          } else if tFree.length() > 0 {
            sl = tFree.pop().Value
          } else {
            sl = tHeap
            tHeap = tHeap + 1
          }
          if sl >= MAX_HEAP {
            vmFail("out of table memory")
          } else {
            tvTag[sl] = vt
            tvNum[sl] = vNum(c)
            tvStr[sl] = vStr(c)
            if !r.Found {
              tmap.set(key, sl)
              if kt == 6 && kint == tLen[tid] + 1 {
                tLen[tid] = kint
                if tmap.has(tid .. "#" .. (kint + 1)) {
                  lenChase = true
                  lenTid = tid
                }
              }
            }
          }
        }
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
      forDepth = forDepth - 1
      let ctrl_reg = forCtrl[forDepth]
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
      }
    } else if op == 34 {
      let lt = vTag(b)
      let rt = vTag(c)
      if lt != 6 && !(lt == 1 && vNum(b) == floor(vNum(b))) { vmFail("attempt to perform floor division") }
      if rt != 6 && !(rt == 1 && vNum(c) == floor(vNum(c))) { vmFail("attempt to perform floor division") }
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
      let quotient = vNum(b) / vNum(c)
      let tr = quotient | 0
      let fl = if quotient < 0.0 && quotient != tr + 0.0 then tr - 1 else tr
      vSetInt(a, fl)
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
  // one reserved slot per builtin (ids 0..7); user functions start after them
  fStart.push(-1)
  fParams.push(-1)
  fRegs.push(-1)
  fStart.push(-1)
  fParams.push(-1)
  fRegs.push(-1)
  fStart.push(-1)
  fParams.push(-1)
  fRegs.push(-1)
  fStart.push(-1)
  fParams.push(-1)
  fRegs.push(-1)
  fStart.push(-1)
  fParams.push(-1)
  fRegs.push(-1)
  fStart.push(-1)
  fParams.push(-1)
  fRegs.push(-1)
  fStart.push(-1)
  fParams.push(-1)
  fRegs.push(-1)
  fStart.push(-1)
  fParams.push(-1)
  fRegs.push(-1)
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

mod vmBurst() {
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
  lsrc = program
  llen = program.Length()
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
