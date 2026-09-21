/// Tiny Lua: numbers, strings, booleans, nil, globals+locals, tables-free.
///
/// Wire a Lua program into `program` (a string variable gate). It is lexed,
/// parsed to flat bytecode, then run on a register VM: 4 instructions per
/// Clock pulse. Types like the program string, restart with `run`, feed
/// numbers into in0..in3, strings into in4..in5, a vector into inVec and a
/// color into inCol, read printed values from out0..out7.
///
/// Ports
///   in  program: string   Lua source, newlines and all.
///   in  run: exec         re-parse and restart (also runs on chip load and
///                         whenever `program` changes; input changes re-run
///                         the parsed program automatically, formula-gate style)
///   in  in0..in3: float  sticky numeric inputs, readable as globals in0..in3
///   in  in4..in5: string sticky string inputs, readable as globals in4..in5
///   in  inVec: vector    unified vector input; Lua reads invecx/y/z
///   in  inCol: color     unified color input; Lua reads incolr/g/b/a
///   out out0..out7: string  print slots in order (overflow overwrites out7)
///   out outVec: vector  written by setvec(x, y, z)
///   out outCol: color   written by setcol(r, g, b, a)
///   out nPrint: int     number of printed values
///   out result: string  top-level return value, "" when none
///   out err: string     runtime error text, "" when none
///   out progOk: bool    false when the program did not compile
///   out progLen: int    compiled instruction count
///   out halted: bool    true when the VM stopped (end, return or error)
///   out busy: bool      true while lexing, parsing or stepping
///
/// Tiny subset (everything else is a compile error, progOk = false)
///   types      numbers (one double type), strings, booleans, nil, functions
///   vars       globals (inputs + print/type/tostring/setvec/setcol/clock
///              built in) and locals; shadowing works; upvalues do NOT
///              (loud error)
///   stmts      local (single or multi), assignment (single or parallel),
///              if/then/elseif/else/end, while/do/end, break, do/end,
///              function f()/local function f(), return (single value),
///              calls (incl. f"str" sugar and f()() chains)
///   exprs      + - * / % ^ (power, right assoc) -x, .. (concat, right assoc,
///              binds looser than + -), < > <= >= == ~= (non-associative,
///              like Lua), and or (return operands, short-circuit), not
///   calls      missing args become nil, extras dropped; bare `return` and
///              falling off the end yield ZERO values (print(f()) prints
///              nothing); `return a, b` is rejected (single value only)
///   builtins   print(...) -> out slots; type(v), tostring(v);
///              setvec(x, y, z) -> outVec (missing/nil args are 0);
///              setcol(r, g, b, a) -> outCol; clock() -> seconds
///              (virtual steps/40 in the model, ServerUptime in-game)
///   print      values go to out0..out7 in order; print() writes an empty call
///   numbers    decimal floats (0.5 .5 5. 1e3 1E-3); NO hex, NO 5..3 (both
///              rejected, like Lua); integer-looking literals are floats,
///              so print(3) shows 3.0 (documented PUC-Lua difference)
///   strings    "..." '...' with \n \r \t \\ \" \' \<newline>, \z,
///              \ddd \xXX for printable ASCII (32..126) only; \a \b \f \v
///              and non-printable escapes are a compile error in-gate
///              (the Python model accepts them; use direct characters)
///   compare    ==/~~= work on all types (no coercion); < > <= >= on
///              numbers, or lexicographically on strings; arithmetic never
///              coerces strings (attempt to add 'x' halts, like Lua errors)
///   missing    tables, for, methods, goto, bitwise ops, coroutines,
///              metatables, modules, pcall/error, closures/upvalues,
///              multiple return values, # length operator
///
/// Notable PUC-Lua differences (all covered by differential tests)
///   one number type (5.4 int/float distinction not modeled; tests force
///   floats on the oracle side), no string coercion in arithmetic,
///   runtime errors halt with err set (there is no pcall to catch them),
///   in-game number printing uses the engine conversion for non-integers
///   (integral floats always render like Lua: 3 becomes 3.0).
///
/// Limits (compile errors past them, progOk = false)
///   512 bytecode instructions, 32 registers per function, 32 functions,
///   64 globals (19 pre-registered), 256 numeric + 256 string constants,
///   16 call arguments, 32 nested calls.
///   Long programs: parsing is chunked across ticks (32 chars/tick), the VM
///   steps 4 instructions per 0.1s pulse; step counts are reported by the
///   Python model so in-game time ~= steps/40 seconds.
///
/// Timing knobs: LEX_PER_TICK below, the Clock interval on the step handler,
/// and the unrolled vmStep() calls per pulse (4 = one STEPS_PER_TICK unit).
///
/// Python reference model: lua_model.py (106/106 differential tests green
/// vs real Lua 5.4). ISA shared with the model: opcodes 0..27, parallel
/// op/pa/pb/pc tables, JMPF/JMPT carry target in pa and test reg in pb,
/// CALL carries arg count in pb and multi-tail bit in pc.

@layout("cube")

// ---------------------------------------------------------------- ports

@left in program: string
@left in run: exec
@left in in0: float
@left in in1: float
@left in in2: float
@left in in3: float
@left in in4: string
@left in in5: string
@left in inVec: vector
@left in inCol: color

@right out out0: string = o0.Value
@right out out1: string = o1.Value
@right out out2: string = o2.Value
@right out out3: string = o3.Value
@right out out4: string = o4.Value
@right out out5: string = o5.Value
@right out out6: string = o6.Value
@right out out7: string = o7.Value
@right out outVec: vector = outVecV.Value
@right out outCol: color = outColV.Value
@right out nPrint: int = nPrintV.Value
@right out result: string = resultV.Value
@right out err: string = errV.Value
@right out progOk: bool = progOkV.Value
@right out progLen: int = progLenV.Value
@right out halted: bool = haltV.Value
@right out busy: bool = busyV.Value

// ---------------------------------------------------------------- tunables

const LEX_PER_TICK = 32
const STEPS_PER_TICK = 4
const MAX_INSTR = 512
const MAX_REGS = 32
const MAX_FUNCS = 32
const MAX_GLOBALS = 64
const MAX_CALLS = 32

// ---------------------------------------------------------------- state: outputs + status

var o0: string = ""
var o1: string = ""
var o2: string = ""
var o3: string = ""
var o4: string = ""
var o5: string = ""
var o6: string = ""
var o7: string = ""
var outVecV: vector = Vec(0.0, 0.0, 0.0)
var outColV: color = Color(0.0, 0.0, 0.0, 0.0)
var nPrintV: int = 0
var resultV: string = ""
var errV: string = ""
var progOkV: bool = false
var progLenV: int = 0
var haltV: bool = true
var busyV: bool = false

// ---------------------------------------------------------------- value helpers
// value tags: 0 nil, 1 number, 2 string, 3 boolean, 4 function

mod truthyOf(tag: int, num: float) -> bool {
  return if tag == 0 then false
    else if tag == 3 && num == 0.0 then false
    else true
}

mod fmtNum(v: float) -> string {
  return if v == floor(v) && abs(v) < 1e15 then ("" .. (v & 0)) .. ".0"
    else "" .. v
}

mod fmtVal(tag: int, num: float, s: string) -> string {
  return if tag == 0 then "nil"
    else if tag == 3 then if num == 0.0 then "false" else "true"
    else if tag == 2 then s
    else if tag == 4 then "function"
    else fmtNum(num)
}

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
var lerr: bool = false
var lstrDelim: string = ""
var lnumInt: float = 0.0
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

// printable ASCII table for \ddd / \xXX escapes (32..126 only)
const PRINTABLES = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"

mod emitTok(kind: int, sub: int, num: float, text: string) {
  tk.push(kind)
  tk.push(kind)
  ts.push(sub)
  tn.push(num)
  tt.push(text)
  if tk.length() > 1024 {
    lerr = true
  }
}

mod emitNum() {
  let mant = lnumInt + lnumFrac / lnumDiv
  let ev = if lnumExpNeg then -lnumExp else lnumExp
  emitTok(1, 0, mant * (10.0 ** ev), "")
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
    lerr = true
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
          lerr = true
        }
      } else if lstage == 6 {
        resolveKw()
        lstage = 99
      } else if lstage == 0 {
        lstage = 99
      } else {
        lerr = true
      }
    } else if lstage == 0 {
      if cp == 32 || cp == 9 || cp == 10 || cp == 13 {
        lpos = lpos + 1
      } else if isDigit {
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
            lerr = true
          } else {
            emitTok(5, 18, 0.0, "")
            lpos = lpos + 2
          }
        } else {
          lerr = true
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
          lerr = true
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
      } else {
        lerr = true
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
          lerr = true
        } else {
          emitNum()
          lstage = 0
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
        lerr = true
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
        lerr = true
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
        lerr = true
      } else if cp == 92 || cp == 34 || cp == 39 {
        lidBuf = lidBuf .. ch
        lstage = 4
        lpos = lpos + 1
      } else if cp == 10 || cp == 13 {
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
        lerr = true
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
        lerr = true
      }
    } else if lstage == 9 {
      // \z skip whitespace
      if cp == 32 || cp == 9 || cp == 10 || cp == 13 {
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
var opC: int[]

mod curKind() -> int {
  if cpos >= tk.length() {
    return 6
  }
  return tk[cpos]
}

mod curSub() -> int {
  if cpos >= tk.length() {
    return 0
  }
  return ts[cpos]
}

mod curNum() -> float {
  if cpos >= tk.length() {
    return 0.0
  }
  return tn[cpos]
}

mod curStr() -> string {
  if cpos >= tk.length() {
    return ""
  }
  return tt[cpos]
}

mod pushVal(r: int, isCall: bool) {
  valStk.push(r)
  valCall.push(isCall)
}

mod popVal() -> int {
  if valStk.length() == 0 {
    perr = true
    perrMsg = "operand stack underflow"
    return 0
  }
  valCall.pop()
  return valStk.pop()
}

mod popFlag() -> bool {
  if valCall.length() == 0 {
    return false
  }
  return valCall.pop()
}

mod topFlag() -> bool {
  if valCall.length() == 0 {
    return false
  }
  return valCall[valCall.length() - 1]
}

mod setTopFlag(v: bool) {
  if valCall.length() > 0 {
    valCall[valCall.length() - 1] = v
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

mod bPatch(pos: int, target: int) {
  bpa[pos] = target
}

mod cNum(v: float) -> int {
  let r = constNum.find(v)
  if r.Found {
    return r.Index
  }
  if constNum.length() >= 256 {
    perr = true
    perrMsg = "too many numeric constants"
    return 0
  }
  constNum.push(v)
  return constNum.length() - 1
}

mod cStr(s: string) -> int {
  let r = constStr.find(s)
  if r.Found {
    return r.Index
  }
  if constStr.length() >= 256 {
    perr = true
    perrMsg = "too many string constants"
    return 0
  }
  constStr.push(s)
  return constStr.length() - 1
}

mod gDeclare(name: string) -> int {
  let r = gmap.get(name)
  if r.Found {
    return r.Value
  }
  if gslotNext >= MAX_GLOBALS {
    perr = true
    perrMsg = "too many globals"
    return 0
  }
  gmap.set(name, gslotNext)
  gslotNext = gslotNext + 1
  return gslotNext - 1
}

mod gLookup(name: string) -> int {
  let r = gmap.get(name)
  if r.Found {
    return r.Value
  }
  return -1
}

mod parseInit() {
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
  opKind.clear()
  opPrec.clear()
  opA.clear()
  opB.clear()
  opC.clear()
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
  cfNext.resize(33, 0)
  cfMax.resize(33, 0)
  cfBase.resize(33, 0)
  cfMaxLoc.resize(33, -1)
  selfName.resize(33, "")
  selfClean.resize(33, true)
  selfFid.resize(33, -1)
  funcEntryLoc.resize(33, 0)
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
  gDeclare("in0")
  gDeclare("in1")
  gDeclare("in2")
  gDeclare("in3")
  gDeclare("in4")
  gDeclare("in5")
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
}

// ---------------------------------------------------------------- registers + scope

mod regAlloc() -> int {
  let r = cfNext[fnDepth]
  if r >= MAX_REGS {
    perr = true
    perrMsg = "too many registers"
    return 0
  }
  cfNext[fnDepth] = r + 1
  if r + 1 > cfMax[fnDepth] {
    cfMax[fnDepth] = r + 1
  }
  return r
}

mod dirtySelf(name: string) {
  if selfName[fnDepth] == name {
    selfClean[fnDepth] = false
  }
}

mod locDeclare(name: string) -> int {
  let r = regAlloc()
  locName.push(name)
  locReg.push(r)
  locDepth.push(fnDepth)
  locLen = locLen + 1
  if r > cfMaxLoc[fnDepth] {
    cfMaxLoc[fnDepth] = r
  }
  dirtySelf(name)
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
  if opKind.length() == 0 {
    return -1
  }
  return opKind[opKind.length() - 1]
}

mod popIsLeft(k: int) -> bool {
  return if k == 0 then (opB[opB.length() - 1] & 1) == 1
    else if k == 1 then false
    else true
}

mod nextKind() -> int {
  if cpos + 1 >= tk.length() {
    return 6
  }
  return tk[cpos + 1]
}

mod nextSub() -> int {
  if cpos + 1 >= tk.length() {
    return 0
  }
  return ts[cpos + 1]
}

// Apply one pending operator pop. Only binop/unary/and/or frames pop;
// call and group markers stop all pops.
mod curStrAhead() -> string {
  if cpos + 1 >= tk.length() {
    return ""
  }
  return tt[cpos + 1]
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
    let res = regAlloc()
    let sw = (fl & 2) != 0
    let L = if sw then rr else ll
    let R = if sw then ll else rr
    bEmit(opc, res, L, R)
    if (fl & 4) != 0 {
      bEmit(15, res, res, 0)
    }
    pushVal(res, false)
  } else if k == 1 {
    let vv = popVal()
    let isNot = opA[opA.length() - 1] == 1
    opKind.pop()
    opPrec.pop()
    opA.pop()
    opB.pop()
    opC.pop()
    let res = regAlloc()
    if isNot {
      bEmit(15, res, vv, 0)
    } else {
      bEmit(14, res, vv, 0)
    }
    pushVal(res, false)
  } else if k == 4 || k == 5 {
    let rr = popVal()
    let R = opA[opA.length() - 1]
    let pp = opB[opB.length() - 1]
    opKind.pop()
    opPrec.pop()
    opA.pop()
    opB.pop()
    opC.pop()
    bEmit(7, R, rr, 0)
    bPatch(pp, bop.length())
    pushVal(R, false)
  } else {
    perr = true
    perrMsg = "bad pop"
  }
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
    pushOp(0, pendPrec, pendSub, pendAux, 0)
  } else {
    let ll = popVal()
    let R = regAlloc()
    bEmit(7, R, ll, 0)
    if pendKind == 5 {
      let pp = bEmit(22, 0, R, 0)
      pushOp(5, pendPrec, R, pp, 0)
    } else {
      let pp = bEmit(21, 0, R, 0)
      pushOp(4, pendPrec, R, pp, 0)
    }
    pushVal(R, false)
  }
  pendKind = -1
}

// ---------------------------------------------------------------- codegen helpers

mod exprPushName(callParen: bool, callSugar: bool) {  let name = curStr()
  locFind(name)
  if lkKind == 2 {
    let fr = regAlloc()
    bEmit(25, fr, lkFid, 0)
    if callParen {
      pushOp(2, -1, fr, 0, valStk.length())
      cpos = cpos + 2
      expectOperand = true
    } else if callSugar {
      let ar = regAlloc()
      bEmit(3, ar, cStr(curStrAhead()), 0)
      bEmit(7, fr + 1, ar, 0)
      bEmit(23, fr, 1, 0)
      pushVal(fr, true)
      cpos = cpos + 2
      expectOperand = false
    } else {
      pushVal(fr, false)
      cpos = cpos + 1
      expectOperand = false
    }
  } else if lkKind == 1 {
    let lr = lkReg
    if callParen {
      let fr = regAlloc()
      bEmit(7, fr, lr, 0)
      pushOp(2, -1, fr, 0, valStk.length())
      cpos = cpos + 2
      expectOperand = true
    } else if callSugar {
      let fr = regAlloc()
      bEmit(7, fr, lr, 0)
      let ar = regAlloc()
      bEmit(3, ar, cStr(curStrAhead()), 0)
      bEmit(7, fr + 1, ar, 0)
      bEmit(23, fr, 1, 0)
      pushVal(fr, true)
      cpos = cpos + 2
      expectOperand = false
    } else {
      pushVal(lr, false)
      cpos = cpos + 1
      expectOperand = false
    }
  } else {
    let slot = gDeclare(name)
    if callParen {
      let fr = regAlloc()
      bEmit(5, fr, slot, 0)
      pushOp(2, -1, fr, 0, valStk.length())
      cpos = cpos + 2
      expectOperand = true
    } else if callSugar {
      let fr = regAlloc()
      bEmit(5, fr, slot, 0)
      let ar = regAlloc()
      bEmit(3, ar, cStr(curStrAhead()), 0)
      bEmit(7, fr + 1, ar, 0)
      bEmit(23, fr, 1, 0)
      pushVal(fr, true)
      cpos = cpos + 2
      expectOperand = false
    } else {
      let r = regAlloc()
      bEmit(5, r, slot, 0)
      pushVal(r, false)
      cpos = cpos + 1
      expectOperand = false
    }
  }
}

mod newFunc() -> int {
  fStart.push(-1)
  fParams.push(0)
  fRegs.push(-1)
  if fStart.length() > MAX_FUNCS {
    perr = true
    perrMsg = "too many functions"
    return 0
  }
  return fStart.length() - 1
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
}

mod funcHeadAnon(fr: int) {
  let skip = bEmit(20, 0, 0, 0)
  pushCtl(3, tmpB, skip, 1, ctlLoop, fr, contKind)
  ctlG[ctlG.length() - 1] = stState
  tmpSStk.push("")
  ctlLoop = -1
  fnDepth = fnDepth + 1
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
    bEmit(2, r, cNum(curNum()), 0)
    pushVal(r, false)
    cpos = cpos + 1
    expectOperand = false
  } else if k == 2 {
    let r = regAlloc()
    bEmit(3, r, cStr(curStr()), 0)
    pushVal(r, false)
    cpos = cpos + 1
    expectOperand = false
  } else if k == 4 && s == 16 {
    let r = regAlloc()
    bEmit(4, r, 1, 0)
    pushVal(r, false)
    cpos = cpos + 1
    expectOperand = false
  } else if k == 4 && s == 7 {
    let r = regAlloc()
    bEmit(4, r, 0, 0)
    pushVal(r, false)
    cpos = cpos + 1
    expectOperand = false
  } else if k == 4 && s == 11 {
    let r = regAlloc()
    bEmit(1, r, 0, 0)
    pushVal(r, false)
    cpos = cpos + 1
    expectOperand = false
  } else if k == 3 {
    let callParen = nextKind() == 5 && nextSub() == 14
    let callSugar = nextKind() == 2
    exprPushName(callParen, callSugar)
  } else if k == 5 && s == 14 {
    pushOp(3, -1, valStk.length(), 0, 0)
    cpos = cpos + 1
    expectOperand = true
  } else if k == 5 && s == 15 {
    // ')' in prefix (empty call/group, trailing comma, or drain first)
    closeMode = 1
    popMode = 2
  } else if k == 5 && s == 2 {
    pushOp(1, 6, 0, 0, 0)
    cpos = cpos + 1
  } else if k == 4 && s == 12 {
    pushOp(1, 6, 1, 0, 0)
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
    let fr = regAlloc()
    bEmit(7, fr, fnr, 0)
    pushOp(2, -1, fr, 0, valStk.length())
    cpos = cpos + 1
    expectOperand = true
  } else if k == 2 {
    let fnr = popVal()
    let fr = regAlloc()
    bEmit(7, fr, fnr, 0)
    let ar = regAlloc()
    bEmit(3, ar, cStr(curStr()), 0)
    bEmit(7, fr + 1, ar, 0)
    bEmit(23, fr, 1, 0)
    pushVal(fr, true)
    cpos = cpos + 1
    expectOperand = false
  } else if k == 5 && s == 15 {
    closeMode = 1
    popMode = 2
  } else if k == 5 && s == 16 {
    closeMode = 2
    popMode = 2
  } else if k == 6 || (k == 5 && s == 17) || (k == 4 && (s == 4 || s == 5 || s == 6)) || (k == 5 && s == 13) || (k == 4 && (s == 3 || s == 15)) {
    closeMode = 3
    popMode = 2
  } else if k == 3 && opKind.length() == 0 && topFlag() {
    // juxtaposed call statement, e.g. print('a') print('b'): a bare NAME
    // after a complete call result ends the unit (Lua: statements need no
    // separator, and only calls are valid expression statements)
    closeMode = 3
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
        } else {
          perr = true
          perrMsg = "trailing comma"
        }
      } else {
        let wasCall = topFlag()
        let arg = popVal()
        bEmit(7, fr + 1 + nargs, arg, 0)
        bEmit(23, fr, nargs + 1, if wasCall then 1 else 0)
      }
      pushVal(fr, true)
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
      }
      cpos = cpos + 1
      expectOperand = false
      closeMode = 0
    } else {
      perr = true
      perrMsg = "unbalanced )"
    }
  } else if closeMode == 2 {
    // ',' arg boundary: top must be a call marker with a fresh arg
    let mk = opTopKind()
    if mk == 2 {
      let fr = opA[opA.length() - 1]
      let nargs = opB[opB.length() - 1]
      let depth = opC[opC.length() - 1]
      if valStk.length() == depth {
        perr = true
        perrMsg = "expected argument"
      } else {
        let arg = popVal()
        bEmit(7, fr + 1 + nargs, arg, 0)
        opB[opB.length() - 1] = nargs + 1
      }
      cpos = cpos + 1
      expectOperand = true
      closeMode = 0
    } else {
      perr = true
      perrMsg = "unexpected ,"
    }
  } else if closeMode == 3 {
    // expression terminator: drain must be complete, no markers left
    if opKind.length() != 0 {
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
  }
}

mod exprMicro() {
  if !perr {
    if popMode != 0 {
      let tk0 = opTopKind()
      var poppable = false
      if tk0 == 0 || tk0 == 1 || tk0 == 4 || tk0 == 5 {
        if popMode == 2 {
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
      if poppable {
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
}

mod ctlTop() -> int {
  if ctlKind.length() == 0 {
    return -1
  }
  return ctlKind[ctlKind.length() - 1]
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
  } else if contKind == 5 {
    if curKind() == 5 && curSub() == 16 {
      perr = true
      perrMsg = "multiple return values not supported"
    } else if presIsCall {
      bEmit(27, presReg, 0, 0)
    } else {
      bEmit(24, presReg, 0, 0)
    }
  } else if contKind == 6 {
    tmpRegs.push(presReg)
    if curKind() == 5 && curSub() == 16 {
      cpos = cpos + 1
      startUnit(6)
    } else {
      tmpA = 0
      stState = 12
    }
  } else if contKind == 7 {
    tmpRegs.push(presReg)
    if curKind() == 5 && curSub() == 16 {
      cpos = cpos + 1
      startUnit(7)
    } else {
      tmpA = 0
      stState = 13
    }
  }
  inExpr = false
  contKind = 0
}

// One gathered local/assign target per micro-step is overkill; stores run
// one target per parseStep via stState 12 (locals) / 13 (assign).
mod doStoreStep() {
  if stState == 12 {
    if tmpA >= tmpNames.length() {
      stState = 0
    } else {
      let nm = tmpNames[tmpA]
      let r = locDeclare(nm)
      if tmpA < tmpRegs.length() {
        bEmit(7, r, tmpRegs[tmpA], 0)
      } else {
        bEmit(1, r, 0, 0)
      }
      tmpA = tmpA + 1
    }
  } else if stState == 13 {
    if tmpA >= tmpNames.length() {
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
      bEmit(7, lkReg, tmpB, 0)
      dirtySelf(nm)
    } else if lkKind == 0 {
      bEmit(6, gDeclare(nm), tmpB, 0)
    } else {
      perr = true
      perrMsg = "bad store"
    }
    tmpA = tmpA + 1
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
  ctlLoop = -1
  fnDepth = fnDepth + 1
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
    cpos = cpos + 1
    if curKind() == 5 && curSub() == 16 {
      cpos = cpos + 1
    } else if curKind() == 5 && curSub() == 15 {
      cpos = cpos + 1
      fParams[tmpB] = cfNext[fnDepth]
      cfBase[fnDepth] = cfNext[fnDepth]
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
    } else if isLocal && atStmtEnd() {
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
  } else if stState == 12 || stState == 13 || stState == 14 {
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
      popCtl()
      if resume == 1 {
        pushVal(extra, true)
        expectOperand = false
        inExpr = true
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
      } else if atStmtEnd() {
        tmpA = 0
        stState = 12
      } else {
        perr = true
        perrMsg = "expected , = or end of statement"
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
      lstAppendC(pos)
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

// Drain one patch-list entry per call; pdThen 1 restores the loop link.
