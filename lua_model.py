"""Tiny Lua reference model: lexer -> parser/codegen -> register VM.

Same ISA the Wirescript port uses. Differential-tested against real Lua 5.4.

SUBSET (Tiny): numbers (double only), booleans, nil, strings, tables,
functions (named/anonymous, recursion, 0/1 return values), globals +
locals, if/while/break/do, print/type/tostring/setvec/setcol/clock/
inarr/outarr, numeric inputs inNum0..inNum3, string inputs inStr0..inStr1, vector
input as invecx/y/z, color input as incolr/g/b/a, float array input
inArr, one multiline log output fed by print plus outNum0..outNum3 (float),
outStr0..outStr1 (string), outArr (float array), outVec/outCol.
NO: integers-as-type (one number type; `#` yields an integral float),
for, methods, varargs, metatables, coroutines, string coercion in
arithmetic, closures/upvalues (inner functions see globals + own
params/locals only), long strings, hex numerals, bitwise ops,
pcall/error, pairs/ipairs, the table library, t:method() calls.
Division/modulo by zero yield 0 (Brickadia gate behavior, unlike IEEE754
inf/nan -- covered by model-only tests, not the oracle). Negative-base
fractional powers yield 0 similarly.
Tables hold integer numbers, strings, booleans, functions and tables as
keys (non-integer number keys are a runtime error on write, read as nil
on read; nil keys are a runtime error). `#t` follows the array border.
Multiple assignment stores right to left (like PUC Lua). Mixed
name+field targets in one statement are rejected (gate limitation).
print appends tab-separated args + newline to the log (last 32 lines,
each capped at 64 chars). inarr(i) reads the float input array 1-based
(out of range -> nil); outarr(i, v) writes the 64-slot float output
array (out of range -> runtime error; non-numbers except nil -> runtime
error; nil writes 0.0). outNum0..outNum3 accept numbers/booleans/nil (nil ->
0.0, anything else -> runtime error); outStr0..outStr1 accept anything
(nil -> ""). Reading a missing table key gives nil; assigning nil
deletes the key. tostring of a table is "table" (real Lua prints an
address). Indexing a non-table, `#` of a non-table/string, and calling a
non-function are runtime errors. Compile errors carry "line N:".
"""

import math
import re
import shutil
import subprocess
import tempfile
import os

MAX_INSTR = 512
MAX_REGS = 64
MAX_FUNCS = 32
MAX_GLOBALS = 64
MAX_CALLS = 32
N_OUT = 8

# ---------------------------------------------------------------- values
def Vnum(x):
    return ("num", float(x), "")

def Vint(x):
    return ("int", int(x), "")

M64 = (1 << 64) - 1

def wrap64(x):
    """Two's-complement 64-bit wrap, matching Lua integer semantics."""
    x &= M64
    return x - (1 << 64) if x >= (1 << 63) else x

def Vstr(s):
    return ("str", 0.0, s)

def Vbool(b):
    return ("bool", 1.0 if b else 0.0, "")

def Vfunc(fid):
    return ("func", float(fid), "")

NIL = ("nil", 0.0, "")

def truthy(v):
    return not (v[0] == "nil" or (v[0] == "bool" and v[1] == 0.0))

_EXP3 = re.compile(r"e([+-])(\d+)$")

def lua_fstr(v):
    """Format a float like Lua 5.5 tostring (shortest round-trip + '.0')."""
    if math.isnan(v):
        return "-nan"
    if math.isinf(v):
        return "inf" if v > 0 else "-inf"
    s = format(v, ".14g")
    try:
        if float(s) != v:
            s = format(v, ".17g")
    except (ValueError, OverflowError):
        s = format(v, ".17g")
    s = _EXP3.sub(lambda m: "e%s%s" % (m.group(1), m.group(2).zfill(3)), s)
    if "." not in s and "e" not in s and "E" not in s and "n" not in s:
        s += ".0"
    return s

def fmt_val(v):
    t = v[0]
    if t == "nil":
        return "nil"
    if t == "bool":
        return "true" if v[1] != 0.0 else "false"
    if t == "num":
        return lua_fstr(v[1])
    if t == "int":
        return str(v[1])
    if t == "str":
        return v[2]
    if t == "table":
        return "table"
    return "function: F"


# Print log: one line per print call (args tab-separated + newline),
# last LOG_LINES lines kept, each line capped at LOG_WIDTH chars.
LOG_LINES = 32
LOG_WIDTH = 64


def log_append(lines, args):
    line = "\t".join(fmt_val(a) for a in args) + "\n"
    if len(line) > LOG_WIDTH:
        line = line[:LOG_WIDTH - 1] + "\n"
    lines.append(line)
    if len(lines) > LOG_LINES:
        del lines[0]
    return "".join(lines)

# ---------------------------------------------------------------- lexer
KEYWORDS = {"and", "break", "do", "else", "elseif", "end", "false",
            "function", "if", "local", "nil", "not", "or", "return",
            "then", "true", "while"}

SIMPLE_ESC = {"a": "\a", "b": "\b", "f": "\f", "n": "\n", "r": "\r",
              "t": "\t", "v": "\v", "\\": "\\", '"': '"', "'": "'",
              "\n": "\n"}

class LangError(Exception):
    pass

class Tok:
    __slots__ = ("kind", "v", "raw", "a", "b", "line")
    def __init__(self, kind, v=None, raw="", a=0, b=0, line=1):
        self.kind, self.v, self.raw, self.a, self.b = kind, v, raw, a, b
        self.line = line
    def __repr__(self):
        return f"Tok({self.kind},{self.v!r})"

def lex(src):
    toks = []
    i, n = 0, len(src)
    line = 1

    def fail(msg):
        raise LangError(f"line {line}: {msg}")

    while i < n:
        c = src[i]
        if c in " \t\n\r":
            if c == "\n":
                line += 1
            i += 1
            continue
        if c == "-" and i + 1 < n and src[i + 1] == "-":
            while i < n and src[i] != "\n":
                i += 1
            continue
        if c == "0" and i + 1 < n and src[i + 1] in "xX":
            j = i + 2
            while j < n and src[j] in "0123456789abcdefABCDEF":
                j += 1
            if j == i + 2:
                fail("malformed number (like Lua '0x')")
            raw = src[i:j]
            toks.append(Tok("NUM", wrap64(int(raw, 16)), raw, i, j, line))
            i = j
            continue
        if c.isdigit() or (c == "." and i + 1 < n and src[i + 1].isdigit()):
            j = i
            while j < n and src[j].isdigit():
                j += 1
            isint = True
            if j < n and src[j] == ".":
                if j + 1 < n and src[j + 1] == ".":
                    fail("malformed number (like Lua '5..3')")
                j += 1
                isint = False
                while j < n and src[j].isdigit():
                    j += 1
            if j < n and src[j] in "eE":
                k = j + 1
                if k < n and src[k] in "+-":
                    k += 1
                if k < n and src[k].isdigit():
                    while k < n and src[k].isdigit():
                        k += 1
                    j = k
                    isint = False
            raw = src[i:j]
            if isint:
                v = int(raw)
                # overlarge decimal literals fall back to float, like Lua
                tokv = v if v < (1 << 63) else float(raw)
            else:
                tokv = float(raw)
            toks.append(Tok("NUM", tokv, raw, i, j, line))
            i = j
            continue
        if c == '"' or c == "'":
            q = c
            j = i + 1
            out = []
            while True:
                if j >= n:
                    fail("unterminated string")
                d = src[j]
                if d == "\n" or d == "\r":
                    fail("unterminated string")
                if d == q:
                    break
                if d == "\\":
                    j += 1
                    if j >= n:
                        fail("unterminated string")
                    e = src[j]
                    if e in SIMPLE_ESC:
                        out.append(SIMPLE_ESC[e])
                    elif e.isdigit():
                        k = j
                        while k < n and k < j + 3 and src[k].isdigit():
                            k += 1
                        out.append(chr(int(src[j:k]) % 256))
                        j = k - 1
                    elif e == "x":
                        hx = src[j + 1:j + 3]
                        if len(hx) != 2 or not all(
                                ch in "0123456789abcdefABCDEF" for ch in hx):
                            fail("bad hex escape")
                        out.append(chr(int(hx, 16)))
                        j += 2
                    elif e == "z":
                        j += 1
                        while j < n and src[j] in " \t\n\r":
                            j += 1
                        j -= 1
                    else:
                        fail(f"bad escape \\{e}")
                else:
                    out.append(d)
                j += 1
            toks.append(Tok("STR", "".join(out), src[i:j + 1], i, j + 1, line))
            i = j + 1
            continue
        if c.isalpha() or c == "_":
            j = i
            while j < n and (src[j].isalnum() or src[j] == "_"):
                j += 1
            w = src[i:j]
            toks.append(Tok("KW" if w in KEYWORDS else "NAME", w, w, i, j, line))
            i = j
            continue
        two = src[i:i + 2]
        if two in ("==", "~=", "<=", ">=", ".."):
            toks.append(Tok("SYM", two, two, i, i + 2, line))
            i += 2
            continue
        if c == "." and src[i + 1:i + 3] == "..":
            fail("varargs '...' not supported")
        if c in "+-*/%^<>=(),;{}[].#":
            toks.append(Tok("SYM", c, c, i, i + 1, line))
            i += 1
            continue
        fail(f"unexpected character {c!r}")
    toks.append(Tok("EOF", None, "", n, n, line))
    if len(toks) > 1025:
        raise LangError("line 1: too many tokens (max 1024)")
    return toks

# ---------------------------------------------------------------- bytecode
(HALT, LOADNIL, LOADNUM, LOADSTR, LOADBOOL, LOADGLOBAL, STOREGLOBAL, MOV,
 ADD, SUB, MUL, DIV, MOD, POW, UNM, NOT, CONCAT, EQ, LT, LE, JMP, JMPF,
 JMPT, CALL, RETURN, LOADFUNC, RETURN0, RETURNV, NEWTABLE, GETFIELD,
 SETFIELD, LEN) = range(32)

MAX_TABLES = 64
MAX_HEAP = 512

BUILTINS = (("print", 0), ("type", 1), ("tostring", 2), ("setvec", 3),
            ("setcol", 4), ("clock", 5), ("inarr", 6), ("outarr", 7))


def Vtable(tid):
    return ("table", float(tid), "")


def tkey(tid, kt, kn, ks):
    """Composite table key, mirroring the gate's tkey() exactly."""
    if kt == 1:
        return f"{tid}#{int(kn)}"
    if kt == 2:
        return f"{tid}${ks}"
    return f"{tid}@{kt}:{int(kn)}"

class FuncInfo:
    def __init__(self, name, start, nparams):
        self.name = name
        self.start = start
        self.nparams = nparams
        self.nregs = 0

class Compiler:
    def __init__(self):
        self.op, self.pa, self.pb, self.pc = [], [], [], []
        self.constNum, self.constStr = [], []
        self.funcs = [FuncInfo("print", -1, -1), FuncInfo("type", -1, -1),
                      FuncInfo("tostring", -1, -1), FuncInfo("setvec", -1, -1),
                      FuncInfo("setcol", -1, -1), FuncInfo("clock", -1, -1),
                      FuncInfo("inarr", -1, -1), FuncInfo("outarr", -1, -1)]
        self.gslot = {}
        for k in range(4):
            self.gslot[f"outNum{k}"] = len(self.gslot)
        for k in range(2):
            self.gslot[f"outStr{k}"] = len(self.gslot)
        for k in range(4):
            self.gslot[f"inNum{k}"] = len(self.gslot)
        self.gslot["inStr0"] = len(self.gslot)
        self.gslot["inStr1"] = len(self.gslot)
        for c in ("x", "y", "z"):
            self.gslot[f"invec{c}"] = len(self.gslot)
        for c in ("r", "g", "b", "a"):
            self.gslot[f"incol{c}"] = len(self.gslot)
        self.gslot["print"] = len(self.gslot)
        self.gslot["type"] = len(self.gslot)
        self.gslot["tostring"] = len(self.gslot)
        self.gslot["setvec"] = len(self.gslot)
        self.gslot["setcol"] = len(self.gslot)
        self.gslot["clock"] = len(self.gslot)
        self.gslot["inarr"] = len(self.gslot)
        self.gslot["outarr"] = len(self.gslot)
        self.gslot["inInt0"] = len(self.gslot)
        self.gslot["outInt0"] = len(self.gslot)
        self.mainFunc = 0

    def emit(self, op, a=0, b=0, c=0):
        if len(self.op) >= MAX_INSTR:
            raise LangError("program too long (max 512 instructions)")
        self.op.append(op)
        self.pa.append(a)
        self.pb.append(b)
        self.pc.append(c)
        return len(self.op) - 1

    def patch(self, pos, target):
        self.pa[pos] = target

    def const_num(self, v, isint=False):
        for i, x in enumerate(self.constNum):
            if type(x) is type(v) and x == v:
                return i
        if len(self.constNum) >= 256:
            raise LangError("too many numeric constants")
        self.constNum.append(v)
        return len(self.constNum) - 1

    def const_str(self, s):
        if s not in self.constStr:
            if len(self.constStr) >= 256:
                raise LangError("too many string constants")
            self.constStr.append(s)
        return self.constStr.index(s)

    def gindex(self, name):
        if name not in self.gslot:
            if len(self.gslot) >= MAX_GLOBALS:
                raise LangError("too many globals")
            self.gslot[name] = len(self.gslot)
        return self.gslot[name]

class Frame:
    def __init__(self):
        self.locals = {}
        self.nextReg = 0
        self.maxReg = 0
        self.baseNext = 0
        self.selfname = None
        self.self_clean = True
        self.selffid = -1

class Parser:
    def __init__(self, comp, toks):
        self.c = comp
        self.t = toks
        self.pos = 0
        self.frames = [Frame()]
        self.loopStack = []
        self.hasReturn = False

    def peek(self):
        return self.t[self.pos]

    def next(self):
        t = self.t[self.pos]
        self.pos += 1
        return t

    def expect(self, kind, v=None):
        t = self.next()
        if t.kind != kind or (v is not None and t.v != v):
            raise LangError(f"line {t.line}: expected {v or kind}, got {t}")
        return t

    def at(self, kind, v=None):
        t = self.peek()
        return t.kind == kind and (v is None or t.v == v)

    def at_stmt_end(self):
        t = self.peek()
        return (t.kind == "EOF" or t.kind == "SYM" and t.v == ";" or
                t.kind == "KW" and t.v in (
                    "end", "else", "elseif", "until"))

    def alloc(self):
        f = self.frames[-1]
        if f.nextReg >= MAX_REGS:
            self.err("too many registers")
        r = f.nextReg
        f.nextReg += 1
        f.maxReg = max(f.maxReg, f.nextReg)
        return r

    def free(self, r):
        f = self.frames[-1]
        if r == f.nextReg - 1 and r not in f.locals.values():
            f.nextReg -= 1

    def alloc_local(self, name):
        f = self.frames[-1]
        r = self.alloc()
        f.locals[name] = r
        return r

    def scoped_block(self, stop):
        """Block with Lua scope semantics: locals die at the end."""
        f = self.frames[-1]
        saved_locals = dict(f.locals)
        saved_next = f.nextReg
        saved_clean = f.self_clean
        h = self.block(stop)
        f.locals = saved_locals
        f.nextReg = saved_next
        f.self_clean = saved_clean
        return h

    def find_local(self, name):
        f = self.frames[-1]
        if f.selfname == name and f.self_clean:
            return ("self", f.selffid, f.locals[name])
        if name in f.locals:
            return f.locals[name]
        for g in self.frames[-2::-1]:
            if name in g.locals or g.selfname == name:
                self.err("upvalues/closures not supported in Tiny")
        return None

    def dirty_self(self, name):
        f = self.frames[-1]
        if f.selfname == name:
            f.self_clean = False

    def err(self, msg):
        t = self.peek()
        raise LangError(f"line {t.line}: {msg}")

    def sync_regs(self):
        """Temps are dead at statement boundaries; reclaim them."""
        f = self.frames[-1]
        top = f.baseNext
        for r in f.locals.values():
            if r + 1 > top:
                top = r + 1
        f.nextReg = top

    # -- chunk / blocks (block() saves/restores hasReturn and RETURNS
    # whether the block definitely returns; callers combine paths)
    def parse_chunk(self):
        fi = FuncInfo("__main", 0, 0)
        self.c.funcs.append(fi)
        self.c.mainFunc = len(self.c.funcs) - 1
        self.hasReturn = False
        h = self.block({"EOF"})
        self.expect("EOF")
        if not h:
            self.c.emit(RETURN0)
        fi.nregs = self.frames[-1].maxReg
        return fi

    def block(self, stop):
        saved = self.hasReturn
        self.hasReturn = False
        while True:
            while self.at("SYM", ";"):
                self.next()
            t = self.peek()
            if t.kind == "EOF" or (t.kind == "KW" and t.v in stop):
                h = self.hasReturn
                self.hasReturn = saved
                return h
            self.stmt(silent=self.hasReturn)
            self.sync_regs()

    # -- statements
    def stmt(self, silent=False):
        t = self.peek()
        if t.kind == "KW":
            w = t.v
            if w == "local":
                return self.stmt_local(silent)
            if w == "function":
                return self.stmt_function(silent)
            if w == "if":
                return self.stmt_if(silent)
            if w == "while":
                return self.stmt_while(silent)
            if w == "do":
                self.next()
                h = self.scoped_block({"end"})
                self.expect("KW", "end")
                self.hasReturn = self.hasReturn or h
                return
            if w == "break":
                self.next()
                if not self.loopStack:
                    self.err("break outside loop")
                if not silent:
                    self.loopStack[-1].append(self.c.emit(JMP, 0))
                return
            if w == "return":
                self.next()
                if self.at_stmt_end():
                    if not silent:
                        self.c.emit(RETURN0)
                else:
                    j = self.scan_call_span(self.pos)
                    multi = (j is not None and j < len(self.t) and
                             self.at_end_token(self.t[j]))
                    r = self.expr()
                    if self.at("SYM", ","):
                        self.err(
                            "multiple return values not supported")
                    if not silent:
                        if multi:
                            self.c.emit(RETURNV, r)
                        else:
                            self.c.emit(RETURN, r)
                    self.free(r)
                self.hasReturn = True
                return
        if t.kind == "NAME":
            return self.stmt_name(silent)
        if t.kind == "SYM" and t.v == "(":
            self.next()
            r = self.expr()
            self.expect("SYM", ")")
            if not (self.at("SYM", "(") or self.peek().kind == "STR" or
                    self.at("SYM", "[") or self.at("SYM", ".")):
                self.err("not a call statement")
            while self.at("SYM", "(") or self.peek().kind == "STR":
                r = self.finish_local_call(r, False)
            while self.at("SYM", "[") or self.at("SYM", "."):
                k = self.parse_index_key(silent)
                if self.at_postfix_cont():
                    res = self.alloc()
                    if not silent:
                        self.c.emit(GETFIELD, res, r, k)
                    self.free(r)
                    self.free(k)
                    r = res
                    while self.at("SYM", "(") or self.peek().kind == "STR":
                        r = self.finish_local_call(r, False)
                else:
                    self.expect("SYM", "=")
                    v = self.expr()
                    if not silent:
                        self.c.emit(SETFIELD, r, k, v)
                    self.free(r)
                    self.free(k)
                    self.free(v)
                    return
            return
        self.err(f"unexpected {t}")

    def stmt_local(self, silent):
        self.expect("KW", "local")
        if self.at("KW", "function"):
            self.next()
            name = self.expect("NAME").v
            self.parse_func(silent, selfname=name, islocal=True)
            return
        names = [self.expect("NAME").v]
        while self.at("SYM", ","):
            self.next()
            names.append(self.expect("NAME").v)
        vals = []
        if self.at("SYM", "="):
            self.next()
            vals = self.expr_list()
        regs = []
        locregs = set(self.frames[-1].locals.values())
        for e in vals:
            if e == self.frames[-1].nextReg - 1 and e not in locregs:
                r = e
            else:
                r = self.alloc()
                if not silent:
                    self.c.emit(MOV, r, e)
                self.free(e)
            regs.append(r)
        while len(regs) < len(names):
            r = self.alloc()
            if not silent:
                self.c.emit(LOADNIL, r)
            regs.append(r)
        for name, r in zip(names, regs):
            self.dirty_self(name)
            if not silent:
                self.alloc_local(name)
                lr = self.find_local(name)
                if isinstance(lr, tuple):
                    _, _, lr = lr
                if lr != r:
                    self.c.emit(MOV, lr, r)
            self.free(r)

    def stmt_function(self, silent):
        self.next()
        name = self.expect("NAME").v
        self.parse_func(silent, selfname=name, islocal=False)

    def parse_func(self, silent, selfname=None, islocal=False, anon=False):
        self.expect("SYM", "(")
        params = []
        if not self.at("SYM", ")"):
            params.append(self.expect("NAME").v)
            while self.at("SYM", ","):
                self.next()
                params.append(self.expect("NAME").v)
        self.expect("SYM", ")")
        if len(params) > 8:
            self.err("too many parameters (max 8 in-gate)")
        fi = FuncInfo(selfname or "anon", -1, len(params))
        if len(self.c.funcs) >= MAX_FUNCS:
            self.err("too many functions")
        fid = len(self.c.funcs)
        self.c.funcs.append(fi)
        fr = None
        skip = None
        if not silent:
            skip = self.c.emit(JMP, 0)
        self.frames.append(Frame())
        nf = self.frames[-1]
        if islocal:
            nf.selfname = selfname
            nf.self_clean = True
            nf.selffid = fid
        for p in params:
            self.alloc_local(p)
            if islocal and p == selfname:
                nf.self_clean = False
        nf.baseNext = nf.nextReg
        if islocal:
            # slot for writes/shadows; clean reads use the marker instead
            self.alloc_local(selfname)
        fi.start = len(self.c.op)
        h = self.block({"end"})
        self.expect("KW", "end")
        if not h:
            self.c.emit(RETURN0)
        fi.nregs = self.frames[-1].maxReg
        self.frames.pop()
        if not silent:
            self.c.patch(skip, len(self.c.op))
            if islocal:
                outer = self.alloc_local(selfname)
                self.dirty_self(selfname)
                self.c.emit(LOADFUNC, outer, fid)
                return outer
            fr = self.alloc()
            self.c.emit(LOADFUNC, fr, fid)
            if selfname and not anon:
                self.c.emit(STOREGLOBAL, self.c.gindex(selfname), fr)
                self.free(fr)
                return None
            return fr
        return None

    def stmt_if(self, silent):
        self.expect("KW", "if")
        ends = []
        r = self.expr()
        self.expect("KW", "then")
        fpos = None
        if not silent:
            fpos = self.c.emit(JMPF, 0, r)
        self.free(r)
        dead = self.scoped_block({"elseif", "else", "end"})
        has_else = False
        while self.at("KW", "elseif"):
            self.next()
            if not silent:
                ends.append(self.c.emit(JMP, 0))
                self.c.patch(fpos, len(self.c.op))
            r = self.expr()
            self.expect("KW", "then")
            if not silent:
                fpos = self.c.emit(JMPF, 0, r)
            self.free(r)
            dead = self.scoped_block({"elseif", "else", "end"}) and dead
        if self.at("KW", "else"):
            self.next()
            if not silent:
                ends.append(self.c.emit(JMP, 0))
                self.c.patch(fpos, len(self.c.op))
            dead = self.scoped_block({"end"}) and dead
            has_else = True
        else:
            if not silent:
                self.c.patch(fpos, len(self.c.op))
        self.expect("KW", "end")
        if not silent:
            for p in ends:
                self.c.patch(p, len(self.c.op))
        if not has_else:
            dead = False
        self.hasReturn = self.hasReturn or dead

    def stmt_while(self, silent):
        self.expect("KW", "while")
        top = len(self.c.op)
        r = self.expr()
        self.expect("KW", "do")
        fpos = None
        if not silent:
            fpos = self.c.emit(JMPF, 0, r)
        self.free(r)
        self.loopStack.append([])
        self.scoped_block({"end"})
        self.expect("KW", "end")
        if not silent:
            self.c.emit(JMP, top)
            self.c.patch(fpos, len(self.c.op))
            for p in self.loopStack.pop():
                self.c.patch(p, len(self.c.op))
        else:
            self.loopStack.pop()

    def parse_index_key(self, silent):
        """Parse one `[k]` / `.name` step; returns the key register."""
        if self.at("SYM", "["):
            self.next()
            k = self.expr()
            self.expect("SYM", "]")
            return k
        self.next()
        nm = self.expect("NAME").v
        k = self.alloc()
        if not silent:
            self.c.emit(LOADSTR, k, self.c.const_str(nm))
        return k

    def at_postfix_cont(self):
        return (self.at("SYM", "[") or self.at("SYM", ".") or
                self.at("SYM", "(") or self.peek().kind == "STR")

    def parse_target(self, silent):
        """One assignment target: ("name", n) | ("field", base, key) |
        ("call", None). A trailing index with no continuation is kept as
        a field store; anything else on the chain reads via GETFIELD."""
        t = self.expect("NAME")
        lr = self.find_local(t.v)
        saw_call = False
        if self.at("SYM", "(") or self.peek().kind == "STR":
            if lr is None:
                base = self.finish_call(t.v, silent)
            elif isinstance(lr, tuple):
                base = self.finish_self_call(lr[1], silent)
            else:
                base = self.finish_local_call(lr, silent)
            saw_call = True
        elif lr is None:
            base = self.alloc()
            if not silent:
                self.c.emit(LOADGLOBAL, base, self.c.gindex(t.v))
        elif isinstance(lr, tuple):
            base = self.alloc()
            if not silent:
                self.c.emit(LOADFUNC, base, lr[1])
        else:
            base = lr
            if not (self.at("SYM", "[") or self.at("SYM", ".") or
                    self.at("SYM", "(") or self.peek().kind == "STR"):
                return ("name", t.v)
        saw_call = saw_call or self.at("SYM", "(") or \
            self.peek().kind == "STR"
        while True:
            if self.at("SYM", "[") or self.at("SYM", "."):
                k = self.parse_index_key(silent)
                if self.at_postfix_cont():
                    res = self.alloc()
                    if not silent:
                        self.c.emit(GETFIELD, res, base, k)
                    self.free(base)
                    self.free(k)
                    base = res
                    saw_call = self.at("SYM", "(") or \
                        self.peek().kind == "STR"
                    continue
                if saw_call:
                    self.err("cannot assign to this expression")
                return ("field", base, k)
            if self.at("SYM", "(") or self.peek().kind == "STR":
                base = self.finish_local_call(base, silent)
                saw_call = True
                continue
            break
        if saw_call:
            if self.at("SYM", "=") or self.at("SYM", ","):
                self.err("cannot assign to this expression")
            return ("call", None)
        return ("name", t.v)

    def stmt_name(self, silent):
        first = self.parse_target(silent)
        if first[0] == "call":
            return
        targets = [first]
        while self.at("SYM", ","):
            self.next()
            tg = self.parse_target(silent)
            if tg[0] == "call":
                self.err("cannot assign to this expression")
            targets.append(tg)
        self.expect("SYM", "=")
        vals = self.expr_list()
        if silent:
            for e in vals:
                self.free(e)
            return
        if any(t[0] == "field" for t in targets) and \
                any(t[0] == "name" for t in targets):
            self.err("assignment targets must all be table fields")
        tmps = []
        locregs = set(self.frames[-1].locals.values())
        for e in vals:
            if e == self.frames[-1].nextReg - 1 and e not in locregs:
                r = e
            else:
                r = self.alloc()
                self.c.emit(MOV, r, e)
                self.free(e)
            tmps.append(r)
        while len(tmps) < len(targets):
            r = self.alloc()
            self.c.emit(LOADNIL, r)
            tmps.append(r)
        # Real Lua stores right to left (so `a, a = 1, 2` leaves 1).
        for i in range(len(targets) - 1, -1, -1):
            kind = targets[i][0]
            r = tmps[i]
            if kind == "name":
                n = targets[i][1]
                lr = self.find_local(n)
                if isinstance(lr, tuple):
                    self.c.emit(MOV, lr[2], r)
                elif lr is not None:
                    self.c.emit(MOV, lr, r)
                else:
                    self.c.emit(STOREGLOBAL, self.c.gindex(n), r)
                self.dirty_self(n)
            else:
                self.c.emit(SETFIELD, targets[i][1], targets[i][2], r)
            self.free(r)

    def expr_list(self):
        es = [self.expr()]
        while self.at("SYM", ","):
            self.next()
            es.append(self.expr())
        return es

    # -- calls
    def at_end_token(self, t):
        return (t.kind == "EOF" or
                (t.kind == "SYM" and t.v == ";") or
                (t.kind == "KW" and t.v in ("end", "else", "elseif")))

    def scan_call_span(self, i):
        """If tokens[i] starts a bare call, return index just past it."""
        t = self.t
        n = len(t)
        if i >= n or t[i].kind != "NAME":
            return None
        j = i + 1
        if j < n and t[j].kind == "STR":
            j += 1
        elif j < n and t[j].kind == "SYM" and t[j].v == "(":
            depth = 0
            while j < n:
                if t[j].kind == "SYM" and t[j].v == "(":
                    depth += 1
                elif t[j].kind == "SYM" and t[j].v == ")":
                    depth -= 1
                    if depth == 0:
                        j += 1
                        break
                j += 1
            if depth != 0:
                return None
        else:
            return None
        while True:
            if j < n and t[j].kind == "STR":
                j += 1
            elif j < n and t[j].kind == "SYM" and t[j].v == "(":
                depth = 0
                while j < n:
                    if t[j].kind == "SYM" and t[j].v == "(":
                        depth += 1
                    elif t[j].kind == "SYM" and t[j].v == ")":
                        depth -= 1
                        if depth == 0:
                            j += 1
                            break
                    j += 1
                if depth != 0:
                    return None
            else:
                break
        return j

    def finish_call(self, name, silent):
        fr = self.alloc()
        if not silent:
            self.c.emit(LOADGLOBAL, fr, self.c.gindex(name))
        return self.call_rest(silent, fr)

    def finish_local_call(self, lr, silent):
        fr = self.alloc()
        if not silent:
            self.c.emit(MOV, fr, lr)
        return self.call_rest(silent, fr)

    def finish_self_call(self, fid, silent):
        fr = self.alloc()
        if not silent:
            self.c.emit(LOADFUNC, fr, fid)
        return self.call_rest(silent, fr)

    def call_rest(self, silent, fr):
        self.call_args(silent, fr)
        while self.at("SYM", "(") or self.peek().kind == "STR":
            self.call_args(silent, fr)
        if silent:
            self.free(fr)
            return None
        return fr

    def call_args(self, silent, fr):
        """Parse one arg list; returns pc of the CALL emit (or None).

        Each argument moves straight into its frame slot before the next
        one parses (temps stay above the frame), so later marshaling can
        never clobber an unevaluated argument temp."""
        f = self.frames[-1]
        nargs = 0
        multitail = False

        def place(e):
            if not silent:
                if fr + 1 + nargs >= MAX_REGS:
                    self.err("too many registers")
                self.c.emit(MOV, fr + 1 + nargs, e)
            self.free(e)
            nn = fr + 2 + nargs
            if nn > f.nextReg:
                f.nextReg = nn

        if self.at("SYM", "("):
            self.next()
            if not self.at("SYM", ")"):
                while True:
                    j = self.scan_call_span(self.pos)
                    last_bare = (j is not None and j < len(self.t) and
                                 self.t[j].kind == "SYM" and
                                 self.t[j].v == ")")
                    place(self.expr())
                    nargs += 1
                    if nargs > 16:
                        self.err("too many arguments")
                    if self.at("SYM", ","):
                        self.next()
                        continue
                    multitail = last_bare
                    break
            self.expect("SYM", ")")
        else:
            t = self.expect("STR")
            r = self.alloc()
            if not silent:
                self.c.emit(LOADSTR, r, self.c.const_str(t.v))
            place(r)
            nargs = 1
        if silent:
            return None
        pos = self.c.emit(CALL, fr, nargs, 1 if multitail else 0)
        f.maxReg = max(f.maxReg, fr + 1 + nargs)
        f.nextReg = fr + 1
        return pos

    # -- expressions
    def expr(self):
        return self.parse_or()

    def parse_or(self):
        l = self.parse_and()
        while self.at("KW", "or"):
            self.next()
            r = self.alloc()
            self.c.emit(MOV, r, l)
            self.free(l)
            end = self.c.emit(JMPT, 0, r)
            q = self.parse_and()
            self.c.emit(MOV, r, q)
            self.free(q)
            self.c.patch(end, len(self.c.op))
            l = r
        return l

    def parse_and(self):
        l = self.parse_cmp()
        while self.at("KW", "and"):
            self.next()
            r = self.alloc()
            self.c.emit(MOV, r, l)
            self.free(l)
            end = self.c.emit(JMPF, 0, r)
            q = self.parse_cmp()
            self.c.emit(MOV, r, q)
            self.free(q)
            self.c.patch(end, len(self.c.op))
            l = r
        return l

    def parse_cmp(self):
        l = self.parse_concat()
        t = self.peek()
        if t.kind == "SYM" and t.v in (
                "<", ">", "<=", ">=", "==", "~="):
            self.next()
            r = self.parse_concat()
            if self.peek().kind == "SYM" and self.peek().v in (
                    "<", ">", "<=", ">=", "==", "~="):
                self.err("chained comparison (like Lua)")
            op = t.v
            # free first so top-of-stack temps cascade back for reuse
            self.free(r)
            self.free(l)
            res = self.alloc()
            if op == "<":
                self.c.emit(LT, res, l, r)
            elif op == ">":
                self.c.emit(LT, res, r, l)
            elif op == "<=":
                self.c.emit(LE, res, l, r)
            elif op == ">=":
                self.c.emit(LE, res, r, l)
            elif op == "==":
                self.c.emit(EQ, res, l, r)
            else:
                self.c.emit(EQ, res, l, r)
                self.c.emit(NOT, res, res)
            return res
        return l

    def parse_concat(self):
        l = self.parse_add()
        if self.at("SYM", ".."):
            self.next()
            r = self.parse_concat()
            self.free(r)
            self.free(l)
            res = self.alloc()
            self.c.emit(CONCAT, res, l, r)
            return res
        return l

    def parse_add(self):
        l = self.parse_mul()
        while self.peek().kind == "SYM" and self.peek().v in ("+", "-"):
            op = self.next().v
            r = self.parse_mul()
            self.free(r)
            self.free(l)
            res = self.alloc()
            self.c.emit(ADD if op == "+" else SUB, res, l, r)
            l = res
        return l

    def parse_mul(self):
        l = self.parse_unary()
        while self.peek().kind == "SYM" and self.peek().v in ("*", "/", "%"):
            op = self.next().v
            r = self.parse_unary()
            self.free(r)
            self.free(l)
            res = self.alloc()
            self.c.emit({"*": MUL, "/": DIV, "%": MOD}[op], res, l, r)
            l = res
        return l

    def parse_unary(self):
        if self.at("KW", "not"):
            self.next()
            q = self.parse_unary()
            self.free(q)
            res = self.alloc()
            self.c.emit(NOT, res, q)
            return res
        if self.at("SYM", "#"):
            self.next()
            q = self.parse_unary()
            self.free(q)
            res = self.alloc()
            self.c.emit(LEN, res, q, 0)
            return res
        if self.at("SYM", "-"):
            self.next()
            q = self.parse_unary()
            self.free(q)
            res = self.alloc()
            self.c.emit(UNM, res, q)
            return res
        return self.parse_power()

    def parse_power(self):
        b = self.parse_simple()
        if self.at("SYM", "^"):
            self.next()
            e = self.parse_unary()
            self.free(e)
            self.free(b)
            res = self.alloc()
            self.c.emit(POW, res, b, e)
            return res
        return b

    def parse_simple(self):
        t = self.peek()
        if t.kind == "NUM":
            self.next()
            r = self.alloc()
            isint = type(t.v) is int
            self.c.emit(LOADNUM, r, self.c.const_num(t.v), 1 if isint else 0)
            return r
        if t.kind == "STR":
            self.next()
            r = self.alloc()
            self.c.emit(LOADSTR, r, self.c.const_str(t.v))
            return r
        if t.kind == "KW" and t.v in ("true", "false", "nil"):
            self.next()
            r = self.alloc()
            if t.v == "nil":
                self.c.emit(LOADNIL, r)
            else:
                self.c.emit(LOADBOOL, r, 1 if t.v == "true" else 0)
            return r
        if t.kind == "KW" and t.v == "function":
            self.next()
            return self.parse_func(False, anon=True)
        if t.kind == "NAME":
            self.next()
            lr = self.find_local(t.v)
            if self.at("SYM", "(") or self.peek().kind == "STR":
                if lr is None:
                    return self.postfix(self.finish_call(t.v, False))
                if isinstance(lr, tuple):
                    return self.postfix(
                        self.finish_self_call(lr[1], False))
                return self.postfix(self.finish_local_call(lr, False))
            if lr is None:
                r = self.alloc()
                self.c.emit(LOADGLOBAL, r, self.c.gindex(t.v))
                return self.postfix(r)
            if isinstance(lr, tuple):
                r = self.alloc()
                self.c.emit(LOADFUNC, r, lr[1])
                return self.postfix(r)
            return self.postfix(lr)
        if t.kind == "SYM" and t.v == "(":
            self.next()
            r = self.expr()
            self.expect("SYM", ")")
            while self.at("SYM", "(") or self.peek().kind == "STR":
                r = self.finish_local_call(r, False)
            return self.postfix(r)
        if t.kind == "SYM" and t.v == "{":
            return self.parse_ctor()
        self.err(f"unexpected {t} in expression")

    def postfix(self, r):
        """Index (.name / [key]) and call chains after a primary."""
        while True:
            if self.at("SYM", "["):
                self.next()
                k = self.expr()
                self.expect("SYM", "]")
                self.free(k)
                self.free(r)
                res = self.alloc()
                self.c.emit(GETFIELD, res, r, k)
                r = res
            elif self.at("SYM", "."):
                self.next()
                nm = self.expect("NAME").v
                kr = self.alloc()
                self.c.emit(LOADSTR, kr, self.c.const_str(nm))
                self.free(kr)
                self.free(r)
                res = self.alloc()
                self.c.emit(GETFIELD, res, r, kr)
                r = res
            elif self.at("SYM", "(") or self.peek().kind == "STR":
                r = self.finish_local_call(r, False)
            else:
                return r

    def parse_ctor(self):
        self.expect("SYM", "{")
        tr = self.alloc()
        self.c.emit(NEWTABLE, tr, 0, 0)
        idx = 0
        if not self.at("SYM", "}"):
            while True:
                if self.at("SYM", "["):
                    self.next()
                    k = self.expr()
                    self.expect("SYM", "]")
                    self.expect("SYM", "=")
                    v = self.expr()
                    self.c.emit(SETFIELD, tr, k, v)
                    self.free(k)
                    self.free(v)
                elif self.peek().kind == "NAME":
                    t2 = self.t[self.pos + 1] if self.pos + 1 < len(
                        self.t) else None
                    if t2 is not None and t2.kind == "SYM" and \
                            t2.v == "=":
                        nm = self.next().v
                        self.next()
                        kr = self.alloc()
                        self.c.emit(LOADSTR, kr, self.c.const_str(nm))
                        v = self.expr()
                        self.c.emit(SETFIELD, tr, kr, v)
                        self.free(kr)
                        self.free(v)
                    else:
                        idx += 1
                        v = self.expr()
                        kr = self.alloc()
                        self.c.emit(LOADNUM, kr,
                                    self.c.const_num(idx), 1)
                        self.c.emit(SETFIELD, tr, kr, v)
                        self.free(kr)
                        self.free(v)
                else:
                    idx += 1
                    v = self.expr()
                    kr = self.alloc()
                    self.c.emit(LOADNUM, kr,
                                self.c.const_num(idx), 1)
                    self.c.emit(SETFIELD, tr, kr, v)
                    self.free(kr)
                    self.free(v)
                if self.at("SYM", ",") or self.at("SYM", ";"):
                    self.next()
                    if self.at("SYM", "}"):
                        break
                    continue
                break
        self.expect("SYM", "}")
        return tr

# ---------------------------------------------------------------- VM
class RuntimeError_(Exception):
    pass

class VM:
    def __init__(self, comp):
        self.c = comp
        n = len(comp.gslot)
        self.gtag = [0] * n
        self.gnum = [0.0] * n
        self.gstr = [""] * n
        for k in range(4):
            self.gtag[comp.gslot[f"inNum{k}"]] = 1
        for name in ("inStr0", "inStr1"):
            self.gtag[comp.gslot[name]] = 2
        for name in ("invecx", "invecy", "invecz", "incolr", "incolg",
                     "incolb", "incola"):
            self.gtag[comp.gslot[name]] = 1
        for name, fid in (("print", 0), ("type", 1), ("tostring", 2),
                          ("setvec", 3), ("setcol", 4), ("clock", 5),
                          ("inarr", 6), ("outarr", 7)):
            s = comp.gslot[name]
            self.gtag[s] = 4
            self.gnum[s] = float(fid)
        for k in range(4):
            self.gtag[comp.gslot[f"outNum{k}"]] = 1
        for k in range(2):
            self.gtag[comp.gslot[f"outStr{k}"]] = 2
        self.outVec = [0.0, 0.0, 0.0]
        self.outCol = [0.0, 0.0, 0.0, 0.0]
        self.inArr = []
        self.outArr = [0.0] * 64
        self.log = ""
        self.tmap = {}
        self.tv = []
        self.tfree = []
        self.theap = 0
        self.tlen = {}
        self.tcount = 0
        self.tag, self.num, self.str = [], [], []
        self.frames = []  # (funcId, base, retSlot, retBase, retPC)
        self.pc = 0
        self.base = 0
        self.halted = False
        self.failed = False
        self.err = ""
        self.logLines = []
        self.log = ""
        self.retCount = -1
        self.result = NIL
        self.steps = 0
        main = comp.mainFunc
        self.frames.append((main, 0, -1, 0, -1))
        need = comp.funcs[main].nregs
        self.tag.extend([0] * need)
        self.num.extend([0.0] * need)
        self.str.extend([""] * need)

    def set_input(self, ch, v):
        if ch >= 4:
            raise IndexError("numeric inputs are inNum0..inNum3")
        s = self.c.gslot[f"inNum{ch}"]
        self.gtag[s] = 1
        self.gnum[s] = float(v)

    def set_iinput(self, v):
        s = self.c.gslot["inInt0"]
        self.gtag[s] = 6
        self.gnum[s] = int(v)

    def set_sinput(self, ch, s):
        if ch >= 2:
            raise IndexError("string inputs are inStr0..inStr1")
        slot = self.c.gslot[f"inStr{ch}"]
        self.gtag[slot] = 2
        self.gstr[slot] = s

    def set_vec(self, x, y, z):
        for name, v in (("invecx", x), ("invecy", y), ("invecz", z)):
            s = self.c.gslot[name]
            self.gtag[s] = 1
            self.gnum[s] = float(v)

    def set_col(self, r, g, b, a):
        for name, v in (("incolr", r), ("incolg", g), ("incolb", b),
                         ("incola", a)):
            s = self.c.gslot[name]
            self.gtag[s] = 1
            self.gnum[s] = float(v)

    def R(self, r):
        i = self.base + r
        t = self.tag[i]
        if t == 0:
            return NIL
        if t == 1:
            return ("num", self.num[i], "")
        if t == 2:
            return ("str", 0.0, self.str[i])
        if t == 3:
            return ("bool", self.num[i], "")
        if t == 5:
            return ("table", self.num[i], "")
        if t == 6:
            return ("int", self.num[i], "")
        return ("func", self.num[i], "")

    def W(self, r, v):
        i = self.base + r
        t = v[0]
        if t == "nil":
            self.tag[i] = 0
        elif t == "num":
            self.tag[i] = 1
            self.num[i] = v[1]
        elif t == "str":
            self.tag[i] = 2
            self.str[i] = v[2]
        elif t == "bool":
            self.tag[i] = 3
            self.num[i] = v[1]
        elif t == "table":
            self.tag[i] = 5
            self.num[i] = v[1]
        elif t == "int":
            self.tag[i] = 6
            self.num[i] = v[1]
        else:
            self.tag[i] = 4
            self.num[i] = v[1]

    def G(self, gi):
        t = self.gtag[gi]
        if t == 0:
            return NIL
        if t == 1:
            return ("num", self.gnum[gi], "")
        if t == 2:
            return ("str", 0.0, self.gstr[gi])
        if t == 3:
            return ("bool", self.gnum[gi], "")
        if t == 5:
            return ("table", self.gnum[gi], "")
        if t == 6:
            return ("int", self.gnum[gi], "")
        return ("func", self.gnum[gi], "")

    def S(self, gi, v):
        t = v[0]
        if t == "nil":
            self.gtag[gi] = 0
        elif t == "num":
            self.gtag[gi] = 1
            self.gnum[gi] = v[1]
        elif t == "str":
            self.gtag[gi] = 2
            self.gstr[gi] = v[2]
        elif t == "bool":
            self.gtag[gi] = 3
            self.gnum[gi] = v[1]
        elif t == "table":
            self.gtag[gi] = 5
            self.gnum[gi] = v[1]
        elif t == "int":
            self.gtag[gi] = 6
            self.gnum[gi] = v[1]
        else:
            self.gtag[gi] = 4
            self.gnum[gi] = v[1]

    def out_snapshot(self):
        """Mirror of the gate's Clock-tick sync: numeric outs read as
        numbers (nil -> 0.0), string outs Lua-formatted (nil -> "")."""
        floats = []
        for k in range(4):
            s = self.c.gslot[f"outNum{k}"]
            floats.append(0.0 if self.gtag[s] == 0 else self.gnum[s])
        strings = []
        for k in range(2):
            s = self.c.gslot[f"outStr{k}"]
            strings.append("" if self.gtag[s] == 0 else fmt_val(self.G(s)))
        s = self.c.gslot["outInt0"]
        ints = 0 if self.gtag[s] == 0 else int(self.gnum[s])
        return floats + strings + [ints]

    def numarg(self, v, what):
        if v[0] in ("num", "int"):
            return v[1]
        if v[0] == "nil":
            return 0.0
        raise RuntimeError_(f"bad argument to '{what}' (number expected)")

    def call_builtin(self, fid, args):
        if fid == 0:
            self.log = log_append(self.logLines, args)
            return NIL
        if fid in (1, 2):
            if not args:
                raise RuntimeError_("wrong number of arguments")
            if fid == 1:
                t = args[0][0]
                return Vstr({"nil": "nil", "num": "number", "int": "number",
                             "str": "string",
                             "bool": "boolean", "func": "function",
                             "table": "table"}[t])
            return Vstr(fmt_val(args[0]))
        if fid == 3:
            self.outVec = [self.numarg(args[k] if k < len(args) else NIL,
                                       "setvec") for k in range(3)]
            return NIL
        if fid == 4:
            self.outCol = [self.numarg(args[k] if k < len(args) else NIL,
                                       "setcol") for k in range(4)]
            return NIL
        if fid == 5:
            if args:
                raise RuntimeError_("wrong number of arguments to 'clock'")
            return Vnum(self.steps * 0.025)
        if fid == 6:
            v = args[0] if args else NIL
            if v[0] in ("num", "int") and v[1] == int(v[1]) and \
                    1 <= int(v[1]) <= len(self.inArr):
                return Vnum(self.inArr[int(v[1]) - 1])
            return NIL
        if fid == 7:
            iv = args[0] if len(args) > 0 else NIL
            vv = args[1] if len(args) > 1 else NIL
            if iv[0] not in ("num", "int") or iv[1] != int(iv[1]) or \
                    not 1 <= int(iv[1]) <= len(self.outArr):
                raise RuntimeError_("array index out of range")
            if vv[0] in ("num", "int"):
                self.outArr[int(iv[1]) - 1] = vv[1]
            elif vv[0] == "nil":
                self.outArr[int(iv[1]) - 1] = 0.0
            elif vv[0] == "bool":
                self.outArr[int(iv[1]) - 1] = vv[1]
            else:
                raise RuntimeError_("array element must be a number")
            return NIL
        raise RuntimeError_("unknown builtin")

    def num2(self, op, a, b):
        if a[0] != "num" or b[0] != "num":
            raise RuntimeError_(
                f"attempt to perform '{op}' on {a[0]} and {b[0]}")
        return a[1], b[1]

    def step(self):
        if self.halted:
            return False
        c = self.c
        op, a, b, c_ = c.op[self.pc], c.pa[self.pc], c.pb[self.pc], \
            c.pc[self.pc]
        self.steps += 1
        try:
            if op == HALT:
                self.halted = True
                return False
            if op == LOADNIL:
                self.W(a, NIL)
            elif op == LOADNUM:
                self.W(a, Vint(c.constNum[b]) if c_ else Vnum(c.constNum[b]))
            elif op == LOADSTR:
                self.W(a, Vstr(c.constStr[b]))
            elif op == LOADBOOL:
                self.W(a, Vbool(b != 0))
            elif op == LOADGLOBAL:
                self.W(a, self.G(b))
            elif op == STOREGLOBAL:
                v = self.R(b)
                if a == self.c.gslot["outInt0"]:
                    if v[0] == "int":
                        pass
                    elif v[0] == "num" and v[1] == math.floor(v[1]):
                        v = ("int", int(v[1]), "")
                    elif v[0] == "bool":
                        v = ("int", int(v[1]), "")
                    elif v[0] == "nil":
                        pass
                    else:
                        raise RuntimeError_(
                            "cannot convert " + v[0] + " to integer")
                self.S(a, v)
                for k in range(4):
                    if a == self.c.gslot[f"outNum{k}"] and \
                            v[0] not in ("num", "int", "nil", "bool"):
                        raise RuntimeError_(
                            "cannot convert " + v[0] + " to number")
            elif op == MOV:
                self.W(a, self.R(b))
            elif op in (ADD, SUB, MUL, DIV, MOD, POW):
                l, r_ = self.R(b), self.R(c_)
                if l[0] not in ("num", "int") or r_[0] not in ("num", "int"):
                    raise RuntimeError_(
                        f"attempt to perform 'arith' on {l[0]} and {r_[0]}")
                ii = l[0] == "int" and r_[0] == "int"
                x, y = l[1], r_[1]
                if op == ADD:
                    self.W(a, Vint(wrap64(int(x) + int(y))) if ii
                           else Vnum(x + y))
                elif op == SUB:
                    self.W(a, Vint(wrap64(int(x) - int(y))) if ii
                           else Vnum(x - y))
                elif op == MUL:
                    self.W(a, Vint(wrap64(int(x) * int(y))) if ii
                           else Vnum(x * y))
                elif op == DIV:
                    # Brickadia gates yield 0 for division by zero
                    self.W(a, Vnum(0.0 if y == 0.0 else x / y))
                elif op == MOD:
                    if y == 0.0 or y == 0:
                        self.W(a, Vint(0) if ii else Vnum(0.0))
                    elif ii:
                        self.W(a, Vint(int(x) % int(y)))
                    else:
                        self.W(a, Vnum(x - math.floor(x / y) * y))
                else:
                    try:
                        self.W(a, Vnum(math.pow(x, y)))
                    except ValueError:
                        self.W(a, Vnum(0.0))
            elif op == UNM:
                v = self.R(b)
                if v[0] == "int":
                    r = -v[1]
                    # unary minus overflows to float at INT64_MIN, like Lua
                    self.W(a, Vint(r) if -(1 << 63) <= r < (1 << 63)
                           else Vnum(float(r)))
                elif v[0] == "num":
                    self.W(a, Vnum(-v[1]))
                else:
                    raise RuntimeError_("attempt to negate a " + v[0])
            elif op == NOT:
                self.W(a, Vbool(not truthy(self.R(b))))
            elif op == CONCAT:
                l, r = self.R(b), self.R(c_)
                if l[0] not in ("num", "int", "str") or \
                        r[0] not in ("num", "int", "str"):
                    raise RuntimeError_("attempt to concatenate")
                self.W(a, Vstr(fmt_val(l) + fmt_val(r)))
            elif op in (EQ, LT, LE):
                l, r = self.R(b), self.R(c_)
                if op == EQ:
                    if l[0] in ("num", "int") and r[0] in ("num", "int"):
                        if (l[0] == "int") != (r[0] == "int"):
                            res = float(l[1]) == float(r[1])
                        else:
                            res = l[1] == r[1]
                    elif l[0] != r[0]:
                        res = False
                    elif l[0] == "num":
                        res = l[1] == r[1]
                    elif l[0] == "int":
                        res = l[1] == r[1]
                    elif l[0] == "str":
                        res = l[2] == r[2]
                    elif l[0] == "bool":
                        res = l[1] == r[1]
                    elif l[0] == "func":
                        res = l[1] == r[1]
                    elif l[0] == "table":
                        res = l[1] == r[1]
                    else:
                        res = True
                elif l[0] in ("num", "int") and r[0] in ("num", "int"):
                    if (l[0] == "int") != (r[0] == "int"):
                        a_, b_ = float(l[1]), float(r[1])
                    else:
                        a_, b_ = l[1], r[1]
                    res = (a_ < b_) if op == LT else (a_ <= b_)
                elif l[0] == "str" and r[0] == "str":
                    res = (l[2] < r[2]) if op == LT else (l[2] <= r[2])
                else:
                    raise RuntimeError_("attempt to compare")
                self.W(a, Vbool(res))
            elif op == JMP:
                self.pc = a
                return True
            elif op == JMPF:
                if not truthy(self.R(b)):
                    self.pc = a
                    return True
            elif op == JMPT:
                if truthy(self.R(b)):
                    self.pc = a
                    return True
            elif op == CALL:
                fv = self.R(a)
                if fv[0] != "func":
                    raise RuntimeError_("attempt to call a " + fv[0])
                fid = int(fv[1])
                multitail = c_ == 1
                if multitail:
                    nargs = (b - 1) + (1 if self.retCount == 1 else 0)
                else:
                    nargs = b
                args = [self.R(a + 1 + k) for k in range(nargs)]
                if fid <= 7:
                    if fid == 0:
                        self.log = log_append(self.logLines, args)
                        self.W(a, NIL)
                        self.retCount = 0
                    else:
                        self.W(a, self.call_builtin(fid, args))
                        self.retCount = 1
                else:
                    if len(self.frames) >= MAX_CALLS:
                        raise RuntimeError_("call depth exceeded")
                    fi = c.funcs[fid]
                    nbase = self.base + a
                    need = nbase + fi.nregs - len(self.tag)
                    if need > 0:
                        self.tag.extend([0] * need)
                        self.num.extend([0.0] * need)
                        self.str.extend([""] * need)
                    for k in range(fi.nparams):
                        self.tag[nbase + k] = 0
                        if k < len(args):
                            av = args[k]
                            self.tag[nbase + k] = {
                                "nil": 0, "num": 1, "str": 2,
                                "bool": 3, "func": 4, "table": 5,
                                "int": 6}[av[0]]
                            if av[0] in ("num", "bool", "func",
                                           "table", "int"):
                                self.num[nbase + k] = av[1]
                            elif av[0] == "str":
                                self.str[nbase + k] = av[2]
                    self.frames.append((fid, nbase, a, self.base,
                                        self.pc + 1))
                    self.base = nbase
                    self.pc = fi.start
                    return True
            elif op == RETURN:
                rv = self.R(a)
                fid, fbase, retA, retBase, retPC = self.frames.pop()
                if not self.frames:
                    self.result = rv
                    self.halted = True
                    return False
                self.base = retBase
                self.W(retA, rv)
                self.pc = retPC
                self.retCount = 1
                return True
            elif op == RETURN0:
                fid, fbase, retA, retBase, retPC = self.frames.pop()
                if not self.frames:
                    self.result = NIL
                    self.halted = True
                    return False
                self.base = retBase
                self.W(retA, NIL)
                self.pc = retPC
                self.retCount = 0
                return True
            elif op == RETURNV:
                if self.retCount == -1:
                    self.retCount = 1
                rv = self.R(a)
                fid, fbase, retA, retBase, retPC = self.frames.pop()
                if not self.frames:
                    if self.retCount == 1:
                        self.result = rv
                    else:
                        self.result = NIL
                    self.halted = True
                    return False
                if self.retCount == 1:
                    self.base = retBase
                    self.W(retA, rv)
                else:
                    self.base = retBase
                self.pc = retPC
                return True
            elif op == LOADFUNC:
                self.W(a, Vfunc(b))
            elif op == NEWTABLE:
                if self.tcount >= MAX_TABLES:
                    raise RuntimeError_("too many tables")
                tid = self.tcount
                self.tcount += 1
                self.tlen[tid] = 0
                self.W(a, Vtable(tid))
            elif op == GETFIELD:
                base = self.R(b)
                if base[0] != "table":
                    raise RuntimeError_(
                        "attempt to index a non-table value")
                key = self.R(c_)
                if key[0] == "nil" or (
                        key[0] == "num" and key[1] != math.floor(key[1])):
                    self.W(a, NIL)
                else:
                    kk = ("int", int(key[1])) \
                        if key[0] in ("num", "int") else key
                    kt = {"int": 1, "num": 1, "str": 2, "bool": 3,
                          "func": 4, "table": 5}[kk[0]]
                    kn = kk[1] if kk[0] in ("int", "num", "bool", "func",
                                            "table") else 0.0
                    ks = key[2] if key[0] == "str" else ""
                    slot = self.tmap.get(tkey(int(base[1]), kt, kn, ks))
                    if slot is None:
                        self.W(a, NIL)
                    else:
                        self.W(a, self.tv[slot])
            elif op == SETFIELD:
                base = self.R(a)
                if base[0] != "table":
                    raise RuntimeError_(
                        "attempt to index a non-table value")
                key = self.R(b)
                val = self.R(c_)
                if key[0] == "nil":
                    raise RuntimeError_("table index is nil")
                if key[0] == "num" and key[1] != math.floor(key[1]):
                    raise RuntimeError_(
                        "non-integer number keys are not supported")
                kk = ("int", int(key[1])) \
                    if key[0] in ("num", "int") else key
                kt = {"int": 1, "num": 1, "str": 2, "bool": 3,
                      "func": 4, "table": 5}[kk[0]]
                kn = kk[1] if kk[0] in ("int", "num", "bool", "func",
                                        "table") else 0.0
                ks = key[2] if key[0] == "str" else ""
                tid = int(base[1])
                kk = tkey(tid, kt, kn, ks)
                slot = self.tmap.get(kk)
                if val[0] == "nil":
                    if slot is not None:
                        del self.tmap[kk]
                        self.tfree.append(slot)
                        if kt == 1 and int(key[1]) == self.tlen.get(tid, 0):
                            self.tlen[tid] = int(key[1]) - 1
                else:
                    if slot is None:
                        if self.tfree:
                            slot = self.tfree.pop()
                        else:
                            slot = self.theap
                            self.theap += 1
                        if slot >= MAX_HEAP:
                            raise RuntimeError_("out of table memory")
                        self.tmap[kk] = slot
                        if kt == 1 and int(key[1]) == \
                                self.tlen.get(tid, 0) + 1:
                            self.tlen[tid] = int(key[1])
                            while tkey(tid, 1, float(
                                    self.tlen[tid] + 1), "") in self.tmap:
                                self.tlen[tid] += 1
                    if slot >= len(self.tv):
                        self.tv.extend([NIL] * (slot + 1 - len(self.tv)))
                    self.tv[slot] = val
            elif op == LEN:
                v = self.R(b)
                if v[0] == "table":
                    tid = int(v[1])
                    hi = 0
                    for k in self.tmap:
                        if k.startswith(str(tid) + "#"):
                            try:
                                ki = int(k.split("#")[1])
                                if ki > hi:
                                    hi = ki
                            except ValueError:
                                pass
                    i = 1
                    while i <= hi + 1 and tkey(tid, 1, float(i), "") in self.tmap:
                        i += 1
                    self.W(a, Vint(i - 1))
                elif v[0] == "str":
                    self.W(a, Vint(len(v[2])))
                else:
                    raise RuntimeError_("attempt to get length")
            else:
                raise RuntimeError_(f"bad opcode {op}")
        except RuntimeError_ as ex:
            self.failed = True
            self.err = str(ex)
            self.halted = True
            return False
        self.pc += 1
        if self.pc >= len(c.op):
            self.halted = True
            return False
        return True

    def run(self, budget=None):
        n = 0
        while budget is None or n < budget:
            if not self.step():
                break
            n += 1
        return n

# ---------------------------------------------------------------- driver
def compile_src(src):
    comp = Compiler()
    toks = lex(src)
    p = Parser(comp, toks)
    try:
        p.parse_chunk()
    except LangError as ex:
        msg = str(ex)
        if not msg.startswith("line "):
            tok = toks[min(p.pos, len(toks) - 1)]
            msg = f"line {tok.line}: {msg}"
        raise LangError(msg)
    comp.emit(HALT)
    return comp

def oracle_log(calls):
    """Rebuild the print log from oracle-captured print calls, applying
    the same line cap/width the chip enforces."""
    lines = []
    for call in calls:
        line = "\t".join(call) + "\n"
        if len(line) > LOG_WIDTH:
            line = line[:LOG_WIDTH - 1] + "\n"
        lines.append(line)
        if len(lines) > LOG_LINES:
            del lines[0]
    return "".join(lines)


def run_model(src, inputs=None, sinputs=None, vec=None, col=None,
              inarr=None, budget=None, inint=None):
    try:
        comp = compile_src(src)
    except LangError as ex:
        return {"ok": False, "err": str(ex)}
    vm = VM(comp)
    for k in range(4):
        if inputs and k < len(inputs):
            vm.set_input(k, inputs[k])
    if inint is not None:
        vm.set_iinput(inint)
    if sinputs:
        for ch, s in sinputs.items():
            vm.set_sinput(ch, s)
    if vec:
        vm.set_vec(*vec)
    if col:
        vm.set_col(*col)
    if inarr is not None:
        vm.inArr = [float(v) for v in inarr]
    vm.run(budget)
    return {"ok": True, "log": vm.log, "failed": vm.failed, "err": vm.err,
            "result": fmt_val(vm.result), "steps": vm.steps,
            "ninstr": len(comp.op), "outVec": list(vm.outVec),
            "outCol": list(vm.outCol),
            "outGlobals": vm.out_snapshot(),
            "outArr": list(vm.outArr)}

# ---------------------------------------------------------------- oracle
def _find_oracle():
    """Locate a Lua 5.5 oracle binary; None when unavailable (tests SKIP)."""
    cands = [
        os.path.join(os.environ.get("LOCALAPPDATA", ""),
                     "Programs", "Lua55", "bin", "lua55.exe"),
        shutil.which("lua55"),
    ]
    for c in cands:
        if not c or not os.path.isfile(c):
            continue
        try:
            p = subprocess.run([c, "-v"], capture_output=True, text=True,
                               timeout=10)
            if "5.5" in (p.stdout + p.stderr):
                return c
        except (OSError, subprocess.SubprocessError):
            continue
    return None


LUA_BIN = _find_oracle()
FUNC_NORM = re.compile(r"function: 0x[0-9a-fA-F]+")

NAN_NORM = re.compile(r"^-?nan(\(ind\))?$")

def norm_val(v):
    v = FUNC_NORM.sub("function: F", v)
    if NAN_NORM.match(v):
        return "-nan"
    return v

def lua_str_lit(s):
    out = ['"']
    for ch in s:
        if ch == '"':
            out.append('\\"')
        elif ch == "\\":
            out.append("\\\\")
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\t":
            out.append("\\t")
        elif ch == "\r":
            out.append("\\r")
        elif 32 <= ord(ch) <= 126:
            out.append(ch)
        else:
            out.append("\\%d" % ord(ch))
    out.append('"')
    return "".join(out)


def oracle_run(src, inputs=None, sinputs=None, vec=None, col=None,
               inarr=None, timeout=15, inint=None):
    if LUA_BIN is None:
        return {"avail": False}
    pre = []
    for k in range(4):
        v = float(inputs[k]) if inputs and k < len(inputs) else 0.0
        pre.append(f"inNum{k} = {lua_num_lit(v)}")
    pre.append(f"inInt0 = {int(inint) if inint is not None else 0}")
    for k in (0, 1):
        s = sinputs.get(k, "") if sinputs else ""
        pre.append(f"inStr{k} = {lua_str_lit(s)}")
    arr = [float(v) for v in inarr] if inarr else []
    pre.append("ARR = {" + ", ".join(lua_num_lit(v) for v in arr) + "}")
    pre.append("inarr = function(i)")
    pre.append("  if type(i) == 'number' and i == math.floor(i)")
    pre.append("      and i >= 1 and i <= #ARR then return ARR[i] end")
    pre.append("  return nil")
    pre.append("end")
    pre.append("outarr = function() end")
    vv = vec or (0.0, 0.0, 0.0)
    for name, v in zip(("invecx", "invecy", "invecz"), vv):
        pre.append(f"{name} = {lua_num_lit(float(v))}")
    cc = col or (0.0, 0.0, 0.0, 0.0)
    for name, v in zip(("incolr", "incolg", "incolb", "incola"), cc):
        pre.append(f"{name} = {lua_num_lit(float(v))}")
    pre.append("print = function(...)")
    pre.append("  local n = select('#', ...)")
    pre.append("  io.write('\\0' .. n .. '\\0')")
    pre.append("  if n > 0 then")
    pre.append("    local t = {}")
    pre.append("    for i = 1, n do t[i] = tostring(select(i, ...)) end")
    pre.append("    io.write(table.concat(t, '\\1'))")
    pre.append("  end")
    pre.append("  io.write('\\2')")
    pre.append("end")
    prog = "\n".join(pre) + "\n" + src
    with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False) as f:
        f.write(prog)
        path = f.name
    try:
        p = subprocess.run([LUA_BIN, path], capture_output=True, text=True,
                           timeout=timeout)
    except FileNotFoundError:
        return {"avail": False}
    finally:
        os.unlink(path)
    calls = []
    if p.stdout:
        chunks = p.stdout.split("\2")
        for ch in chunks[:-1]:
            parts = ch.split("\0")
            if len(parts) != 3 or parts[0] != "":
                return {"avail": True, "rc": p.returncode, "calls": None,
                        "stderr": "bad framing: %r" % ch}
            try:
                n = int(parts[1])
            except ValueError:
                return {"avail": True, "rc": p.returncode, "calls": None,
                        "stderr": "bad count: %r" % ch}
            if n == 0:
                calls.append([])
            else:
                vals = parts[2].split("\1")
                if len(vals) != n:
                    return {"avail": True, "rc": p.returncode,
                            "calls": None,
                            "stderr": "arity mismatch: %r" % ch}
                calls.append(vals)
    norm = []
    for call in calls:
        norm.append([norm_val(v) for v in call])
    return {"avail": True, "rc": p.returncode, "calls": norm,
            "stderr": p.stderr.strip().splitlines()[-1] if p.stderr.strip()
            else ""}

def lua_num_lit(v):
    if math.isnan(v):
        return "(0/0)"
    if math.isinf(v):
        return "(1/0)" if v > 0 else "(-1/0)"
    s = format(v, ".17g")
    if "." not in s and "e" not in s and "E" not in s:
        s += ".0"
    return s

# ---------------------------------------------------------------- tests
# Each test: (name, source, inputs|None, mode)
# mode 'run'     : must succeed both sides, values identical
#      'synfail' : both sides must reject
#      'haltfail': both sides must fail; printed-so-far identical
DEMO_SRC = open(os.path.join(os.path.dirname(os.path.abspath(__file__)),
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
     "modelonly"),
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
    ("over-cap", "OVERCAP", None, "modelonly"),
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
     None, "modelonly"),
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
    ("tab-set-nonint", "t = {} t[1.5] = 1", None, "modelhalt",
     {"expect": {"err": "non-integer number keys"}}),
    ("tab-set-nil-key", "t = {} t[nil] = 1", None, "haltfail"),
    ("tab-idx-nontable", "x = 5 print(x[1])", None, "haltfail"),
    ("tab-len-nontable", "print(#5)", None, "haltfail"),
    ("tab-toomany", "t = {} i = 0 while i < 65 do t[#t+1] = {} "
     "i = i+1 end", None, "modelhalt",
     {"expect": {"err": "too many tables"}}),
    ("tab-oom", "t = {} i = 0 while i < 513 do t[#t+1] = i i = i+1 end",
     None, "modelhalt", {"expect": {"err": "out of table memory"}}),
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
    ("assign-mixed-reject", "a, t.x = 1, 2", None, "modelonly"),
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
    ("arr-oob-write", "outarr(0, 1)", None, "modelhalt",
     {"expect": {"err": "array index out of range"}}),
    ("arr-oob-write2", "outarr(65, 1)", None, "modelhalt",
     {"expect": {"err": "array index out of range"}}),
    ("arr-badval", "outarr(1, 'x')", None, "modelhalt",
     {"expect": {"err": "array element must be a number"}}),
    ("arr-badval2", "outarr(1, {})", None, "modelhalt",
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
    ("io-int-bad", "outInt0 = 7.5", None, "modelhalt",
     {"expect": {"err": "cannot convert"}}),
    ("inputs-int", "print(inInt0 + 1)", None, "run", {"inint": 41}),
    ("out-readback", "outNum0 = 5 print(outNum0 + 1)", None, "run"),
    ("out-badnum", "outNum0 = 'x'", None, "modelhalt",
     {"expect": {"err": "cannot convert"}}),
    ("out-badnum2", "outNum1 = {}", None, "modelhalt",
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





def norm_calls(calls):
    return [[norm_val(v) for v in call] for call in calls]


def check_one(name, src, inputs, mode, kw=None):
    kw = kw or {}
    if src == "STRESS":
        src = build_stress()
    if src == "OVERCAP":
        src = build_overcap()
    if src == "DEMO":
        src = DEMO_SRC
        for k, v in DEMO_KW.items():
            kw.setdefault(k, v)
    rkw = {k: v for k, v in kw.items()
           if k not in ("expect", "errline")}
    m = run_model(src, inputs, **rkw)
    o = oracle_run(src, inputs, **rkw)
    if not o.get("avail"):
        return ("SKIP", f"{name}: lua binary not available")
    if mode == "run":
        if not m["ok"]:
            return ("FAIL", f"{name}: model rejected: {m.get('err')}")
        if m["failed"]:
            return ("FAIL", f"{name}: model runtime fail: {m['err']}")
        if o["rc"] != 0:
            return ("FAIL", f"{name}: lua rc={o['rc']}: {o['stderr']}")
        if o["calls"] is None:
            return ("FAIL", f"{name}: oracle framing broken: {o['stderr']}")
        want = oracle_log(norm_calls(o["calls"]))
        if m["log"] != want:
            return ("FAIL",
                    f"{name}: log mismatch\n  model={m['log']!r}\n"
                    f"  lua  ={want!r}")
        return ("PASS", f"{name} steps={m['steps']} instr={m['ninstr']}")
    if mode == "modelio":
        exp = kw.get("expect", {}) if kw else {}
        if not m["ok"]:
            return ("FAIL", f"{name}: model rejected: {m.get('err')}")
        if m["failed"]:
            return ("FAIL", f"{name}: model runtime fail: {m['err']}")
        for key in ("log", "outVec", "outCol", "outGlobals", "outArr",
                    "result"):
            if key in exp:
                got = m[key]
                if got != exp[key]:
                    return ("FAIL", f"{name}: {key} mismatch "
                                    f"got={got!r} want={exp[key]!r}")
        return ("PASS", name)
    if mode == "modelonly":
        if m["ok"]:
            return ("FAIL", f"{name}: model accepted, want reject "
                            "(documented Tiny exclusion)")
        return ("PASS", name)
    if mode == "modelhalt":
        # Model compiles but must halt at runtime (gate limits or
        # documented divergences); oracle may succeed.
        exp = kw.get("expect", {}) if kw else {}
        if not m["ok"]:
            return ("FAIL", f"{name}: model rejected, want runtime halt: "
                            f"{m.get('err')}")
        if not m["failed"]:
            return ("FAIL", f"{name}: model did not halt-fail")
        for key in ("log", "outGlobals", "outArr", "err"):
            if key in exp:
                got = m[key]
                if key == "err":
                    if exp[key] not in got:
                        return ("FAIL", f"{name}: err missing "
                                        f"{exp[key]!r}: got {got!r}")
                elif got != exp[key]:
                    return ("FAIL", f"{name}: {key} mismatch "
                                    f"got={got!r} want={exp[key]!r}")
        return ("PASS", name)
    if mode == "synfail":
        if m["ok"]:
            return ("FAIL", f"{name}: model accepted, want reject")
        if o["rc"] == 0:
            return ("FAIL", f"{name}: lua accepted, want reject")
        if "errline" in kw:
            want = f"line {kw['errline']}:"
            if want not in m.get("err", ""):
                return ("FAIL", f"{name}: err missing {want!r}: "
                                f"got {m.get('err')!r}")
        return ("PASS", name)
    if mode == "haltfail":
        if not m["ok"]:
            return ("FAIL", f"{name}: model rejected, want runtime halt")
        if not m["failed"]:
            return ("FAIL", f"{name}: model did not halt-fail")
        if o["rc"] == 0:
            return ("FAIL", f"{name}: lua accepted, want error")
        if o["calls"] is None:
            return ("FAIL", f"{name}: oracle framing broken: {o['stderr']}")
        want = oracle_log(norm_calls(o["calls"]))
        if m["log"] != want:
            return ("FAIL",
                    f"{name}: partial mismatch\n  model={m['log']!r}\n"
                    f"  lua  ={want!r}")
        return ("PASS", name)
    return ("FAIL", f"{name}: bad mode")


if __name__ == "__main__":
    only = None
    import sys
    if len(sys.argv) > 1:
        only = sys.argv[1]
    npass, nfail, nskip = 0, 0, 0
    worst = (0, "")
    for t in TESTS:
        name, src, inputs, mode = t[0], t[1], t[2], t[3]
        kw = t[4] if len(t) > 4 else None
        if only and only not in name:
            continue
        st, msg = check_one(name, src, inputs, mode, kw)
        if st == "PASS":
            npass += 1
            print("PASS " + msg)
        elif st == "SKIP":
            nskip += 1
            print("SKIP " + msg)
        else:
            nfail += 1
            print("FAIL " + msg)
    print(f"{npass} passed, {nfail} failed, {nskip} skipped")
    print("ALL-OK" if nfail == 0 and nskip == 0 else "SOME-FAILED")