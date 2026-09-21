"""Tiny Lua reference model: lexer -> parser/codegen -> register VM.

Same ISA the Wirescript port uses. Differential-tested against real Lua 5.4.

SUBSET (Tiny): numbers (double only), booleans, nil, strings (literals +
concatenation only), globals + locals, if/while/break/do, functions
(named/anonymous, recursion, 0/1 return values), print/type/tostring/
setvec/setcol/clock, numeric inputs in0..in3, string inputs in4..in5,
vector input as invecx/y/z, color input as incolr/g/b/a, 8 string outputs
via print plus outVec/outCol via setvec/setcol.
NO: integers-as-type (one number type), tables, for, methods, varargs,
metatables, coroutines, string coercion in arithmetic, closures/upvalues
(inner functions see globals + own params/locals only), long strings,
hex numerals, bitwise ops, pcall/error.
"""

import math
import re
import shutil
import subprocess
import tempfile
import os

MAX_INSTR = 512
MAX_REGS = 32
MAX_FUNCS = 32
MAX_GLOBALS = 64
MAX_CALLS = 32
N_OUT = 8

# ---------------------------------------------------------------- values
def Vnum(x):
    return ("num", float(x), "")

def Vstr(s):
    return ("str", 0.0, s)

def Vbool(b):
    return ("bool", 1.0 if b else 0.0, "")

def Vfunc(fid):
    return ("func", float(fid), "")

NIL = ("nil", 0.0, "")

def truthy(v):
    return not (v[0] == "nil" or (v[0] == "bool" and v[1] == 0.0))

def lua_fstr(v):
    """Format a float exactly like Lua 5.4 tostring (%.14g + '.0' rule)."""
    if math.isnan(v):
        return "-nan"
    if math.isinf(v):
        return "inf" if v > 0 else "-inf"
    s = format(v, ".14g")
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
    if t == "str":
        return v[2]
    return "function: F"

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
    __slots__ = ("kind", "v", "raw", "a", "b")
    def __init__(self, kind, v=None, raw="", a=0, b=0):
        self.kind, self.v, self.raw, self.a, self.b = kind, v, raw, a, b
    def __repr__(self):
        return f"Tok({self.kind},{self.v!r})"

def lex(src):
    toks = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c in " \t\n\r":
            i += 1
            continue
        if c == "-" and i + 1 < n and src[i + 1] == "-":
            while i < n and src[i] != "\n":
                i += 1
            continue
        if c.isdigit() or (c == "." and i + 1 < n and src[i + 1].isdigit()):
            j = i
            while j < n and src[j].isdigit():
                j += 1
            if j < n and src[j] == ".":
                if j + 1 < n and src[j + 1] == ".":
                    raise LangError("malformed number (like Lua '5..3')")
                j += 1
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
            raw = src[i:j]
            toks.append(Tok("NUM", float(raw), raw, i, j))
            i = j
            continue
        if c == '"' or c == "'":
            q = c
            j = i + 1
            out = []
            while True:
                if j >= n:
                    raise LangError("unterminated string")
                d = src[j]
                if d == "\n":
                    raise LangError("unterminated string")
                if d == q:
                    break
                if d == "\\":
                    j += 1
                    if j >= n:
                        raise LangError("unterminated string")
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
                            raise LangError("bad hex escape")
                        out.append(chr(int(hx, 16)))
                        j += 2
                    elif e == "z":
                        j += 1
                        while j < n and src[j] in " \t\n\r":
                            j += 1
                        j -= 1
                    else:
                        raise LangError(f"bad escape \\{e}")
                else:
                    out.append(d)
                j += 1
            toks.append(Tok("STR", "".join(out), src[i:j + 1], i, j + 1))
            i = j + 1
            continue
        if c.isalpha() or c == "_":
            j = i
            while j < n and (src[j].isalnum() or src[j] == "_"):
                j += 1
            w = src[i:j]
            toks.append(Tok("KW" if w in KEYWORDS else "NAME", w, w, i, j))
            i = j
            continue
        two = src[i:i + 2]
        if two in ("==", "~=", "<=", ">=", ".."):
            toks.append(Tok("SYM", two, two, i, i + 2))
            i += 2
            continue
        if c == "." and src[i + 1:i + 3] == "..":
            raise LangError("varargs '...' not supported")
        if c in "+-*/%^<>=(),;":
            toks.append(Tok("SYM", c, c, i, i + 1))
            i += 1
            continue
        raise LangError(f"unexpected character {c!r}")
    toks.append(Tok("EOF", None, "", n, n))
    return toks

# ---------------------------------------------------------------- bytecode
(HALT, LOADNIL, LOADNUM, LOADSTR, LOADBOOL, LOADGLOBAL, STOREGLOBAL, MOV,
 ADD, SUB, MUL, DIV, MOD, POW, UNM, NOT, CONCAT, EQ, LT, LE, JMP, JMPF,
 JMPT, CALL, RETURN, LOADFUNC, RETURN0, RETURNV) = range(28)

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
                      FuncInfo("setcol", -1, -1), FuncInfo("clock", -1, -1)]
        self.gslot = {}
        for k in range(4):
            self.gslot[f"in{k}"] = len(self.gslot)
        self.gslot["in4"] = len(self.gslot)
        self.gslot["in5"] = len(self.gslot)
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

    def const_num(self, v):
        if v not in self.constNum:
            if len(self.constNum) >= 256:
                raise LangError("too many numeric constants")
            self.constNum.append(v)
        return self.constNum.index(v)

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
            raise LangError(f"expected {v or kind}, got {t}")
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
            raise LangError("too many registers")
        r = f.nextReg
        f.nextReg += 1
        f.maxReg = max(f.maxReg, f.nextReg)
        return r

    def free(self, r):
        f = self.frames[-1]
        if r == f.nextReg - 1:
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
                raise LangError("upvalues/closures not supported in Tiny")
        return None

    def dirty_self(self, name):
        f = self.frames[-1]
        if f.selfname == name:
            f.self_clean = False

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
                    raise LangError("break outside loop")
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
                        raise LangError(
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
        raise LangError(f"unexpected {t}")

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
        for e in vals:
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
        fi = FuncInfo(selfname or "anon", -1, len(params))
        if len(self.c.funcs) >= MAX_FUNCS:
            raise LangError("too many functions")
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

    def stmt_name(self, silent):
        name = self.expect("NAME").v
        if self.at("SYM", "(") or self.peek().kind == "STR":
            self.finish_call(name, silent)
            return
        names = [name]
        while self.at("SYM", ","):
            self.next()
            names.append(self.expect("NAME").v)
        self.expect("SYM", "=")
        vals = self.expr_list()
        if not silent:
            tmps = []
            for e in vals:
                r = self.alloc()
                self.c.emit(MOV, r, e)
                self.free(e)
                tmps.append(r)
            while len(tmps) < len(names):
                r = self.alloc()
                self.c.emit(LOADNIL, r)
                tmps.append(r)
            for n, r in zip(names, tmps):
                lr = self.find_local(n)
                if isinstance(lr, tuple):
                    self.c.emit(MOV, lr[2], r)
                elif lr is not None:
                    self.c.emit(MOV, lr, r)
                else:
                    self.c.emit(STOREGLOBAL, self.c.gindex(n), r)
                self.dirty_self(n)
                self.free(r)
        else:
            for e in vals:
                self.free(e)

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
        """Parse one arg list; returns pc of the CALL emit (or None)."""
        argregs = []
        multitail = False
        if self.at("SYM", "("):
            self.next()
            if not self.at("SYM", ")"):
                while True:
                    j = self.scan_call_span(self.pos)
                    last_bare = (j is not None and j < len(self.t) and
                                 self.t[j].kind == "SYM" and
                                 self.t[j].v == ")")
                    argregs.append(self.expr())
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
            argregs = [r]
        if silent:
            for e in argregs:
                self.free(e)
            return None
        if len(argregs) > 16:
            raise LangError("too many arguments")
        f = self.frames[-1]
        if fr + 1 + len(argregs) > MAX_REGS:
            raise LangError("too many registers")
        for i, e in enumerate(argregs):
            self.c.emit(MOV, fr + 1 + i, e)
        pos = self.c.emit(CALL, fr, len(argregs), 1 if multitail else 0)
        f.maxReg = max(f.maxReg, fr + 1 + len(argregs))
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
                raise LangError("chained comparison (like Lua)")
            res = self.alloc()
            op = t.v
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
            self.free(l)
            self.free(r)
            return res
        return l

    def parse_concat(self):
        l = self.parse_add()
        if self.at("SYM", ".."):
            self.next()
            r = self.parse_concat()
            res = self.alloc()
            self.c.emit(CONCAT, res, l, r)
            self.free(l)
            self.free(r)
            return res
        return l

    def parse_add(self):
        l = self.parse_mul()
        while self.peek().kind == "SYM" and self.peek().v in ("+", "-"):
            op = self.next().v
            r = self.parse_mul()
            res = self.alloc()
            self.c.emit(ADD if op == "+" else SUB, res, l, r)
            self.free(l)
            self.free(r)
            l = res
        return l

    def parse_mul(self):
        l = self.parse_unary()
        while self.peek().kind == "SYM" and self.peek().v in ("*", "/", "%"):
            op = self.next().v
            r = self.parse_unary()
            res = self.alloc()
            self.c.emit({"*": MUL, "/": DIV, "%": MOD}[op], res, l, r)
            self.free(l)
            self.free(r)
            l = res
        return l

    def parse_unary(self):
        if self.at("KW", "not"):
            self.next()
            q = self.parse_unary()
            res = self.alloc()
            self.c.emit(NOT, res, q)
            self.free(q)
            return res
        if self.at("SYM", "-"):
            self.next()
            q = self.parse_unary()
            res = self.alloc()
            self.c.emit(UNM, res, q)
            self.free(q)
            return res
        return self.parse_power()

    def parse_power(self):
        b = self.parse_simple()
        if self.at("SYM", "^"):
            self.next()
            e = self.parse_unary()
            res = self.alloc()
            self.c.emit(POW, res, b, e)
            self.free(b)
            self.free(e)
            return res
        return b

    def parse_simple(self):
        t = self.peek()
        if t.kind == "NUM":
            self.next()
            r = self.alloc()
            self.c.emit(LOADNUM, r, self.c.const_num(t.v))
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
                    return self.finish_call(t.v, False)
                if isinstance(lr, tuple):
                    return self.finish_self_call(lr[1], False)
                return self.finish_local_call(lr, False)
            if lr is None:
                r = self.alloc()
                self.c.emit(LOADGLOBAL, r, self.c.gindex(t.v))
                return r
            if isinstance(lr, tuple):
                r = self.alloc()
                self.c.emit(LOADFUNC, r, lr[1])
                return r
            return lr
        if t.kind == "SYM" and t.v == "(":
            self.next()
            r = self.expr()
            self.expect("SYM", ")")
            return r
        raise LangError(f"unexpected {t} in expression")

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
            self.gtag[comp.gslot[f"in{k}"]] = 1
        for name in ("in4", "in5"):
            self.gtag[comp.gslot[name]] = 2
        for name in ("invecx", "invecy", "invecz", "incolr", "incolg",
                     "incolb", "incola"):
            self.gtag[comp.gslot[name]] = 1
        for name, fid in (("print", 0), ("type", 1), ("tostring", 2),
                          ("setvec", 3), ("setcol", 4), ("clock", 5)):
            s = comp.gslot[name]
            self.gtag[s] = 4
            self.gnum[s] = float(fid)
        self.outVec = [0.0, 0.0, 0.0]
        self.outCol = [0.0, 0.0, 0.0, 0.0]
        self.tag, self.num, self.str = [], [], []
        self.frames = []  # (funcId, base, retSlot, retBase, retPC)
        self.pc = 0
        self.base = 0
        self.halted = False
        self.failed = False
        self.err = ""
        self.out = [""] * N_OUT
        self.nprint = 0
        self.calls = []
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
            raise IndexError("numeric inputs are in0..in3")
        s = self.c.gslot[f"in{ch}"]
        self.gtag[s] = 1
        self.gnum[s] = float(v)

    def set_sinput(self, ch, s):
        slot = self.c.gslot[f"in{ch}"]
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
        else:
            self.gtag[gi] = 4
            self.gnum[gi] = v[1]

    def slot_print(self, s):
        slot = self.nprint if self.nprint < N_OUT else N_OUT - 1
        self.out[slot] = s
        self.nprint += 1

    def numarg(self, v, what):
        if v[0] == "num":
            return v[1]
        if v[0] == "nil":
            return 0.0
        raise RuntimeError_(f"bad argument to '{what}' (number expected)")

    def call_builtin(self, fid, args):
        if fid == 0:
            vals = [fmt_val(a) for a in args]
            self.calls.append(vals)
            for s in vals:
                self.slot_print(s)
            return NIL
        if fid in (1, 2):
            if not args:
                raise RuntimeError_("wrong number of arguments")
            if fid == 1:
                t = args[0][0]
                return Vstr({"nil": "nil", "num": "number", "str": "string",
                             "bool": "boolean", "func": "function"}[t])
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
                self.W(a, Vnum(c.constNum[b]))
            elif op == LOADSTR:
                self.W(a, Vstr(c.constStr[b]))
            elif op == LOADBOOL:
                self.W(a, Vbool(b != 0))
            elif op == LOADGLOBAL:
                self.W(a, self.G(b))
            elif op == STOREGLOBAL:
                self.S(a, self.R(b))
            elif op == MOV:
                self.W(a, self.R(b))
            elif op in (ADD, SUB, MUL, DIV, MOD, POW):
                x, y = self.num2("arith", self.R(b), self.R(c_))
                if op == ADD:
                    r = x + y
                elif op == SUB:
                    r = x - y
                if op == ADD:
                    r = x + y
                elif op == SUB:
                    r = x - y
                elif op == MUL:
                    r = x * y
                elif op == DIV:
                    if y == 0.0:
                        r = (math.inf if x > 0 else
                             -math.inf if x < 0 else math.nan)
                    else:
                        r = x / y
                elif op == MOD:
                    r = math.nan if y == 0.0 else x - math.floor(x / y) * y
                else:
                    try:
                        r = math.pow(x, y)
                    except ValueError:
                        r = math.nan
                self.W(a, Vnum(r))
            elif op == UNM:
                v = self.R(b)
                if v[0] != "num":
                    raise RuntimeError_("attempt to negate a " + v[0])
                self.W(a, Vnum(-v[1]))
            elif op == NOT:
                self.W(a, Vbool(not truthy(self.R(b))))
            elif op == CONCAT:
                l, r = self.R(b), self.R(c_)
                if l[0] not in ("num", "str") or r[0] not in ("num", "str"):
                    raise RuntimeError_("attempt to concatenate")
                ls = fmt_val(l) if l[0] == "str" else lua_fstr(l[1])
                rs = fmt_val(r) if r[0] == "str" else lua_fstr(r[1])
                self.W(a, Vstr(ls + rs))
            elif op in (EQ, LT, LE):
                l, r = self.R(b), self.R(c_)
                if op == EQ:
                    if l[0] != r[0]:
                        res = False
                    elif l[0] == "num":
                        res = l[1] == r[1]
                    elif l[0] == "str":
                        res = l[2] == r[2]
                    elif l[0] == "bool":
                        res = l[1] == r[1]
                    elif l[0] == "func":
                        res = l[1] == r[1]
                    else:
                        res = True
                elif l[0] == "num" and r[0] == "num":
                    res = (l[1] < r[1]) if op == LT else (l[1] <= r[1])
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
                if fid <= 5:
                    if fid == 0:
                        vals = [fmt_val(x) for x in args]
                        self.calls.append(vals)
                        for s in vals:
                            self.slot_print(s)
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
                                "bool": 3, "func": 4}[av[0]]
                            if av[0] in ("num", "bool", "func"):
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
    Parser(comp, toks).parse_chunk()
    comp.emit(HALT)
    return comp

def run_model(src, inputs=None, sinputs=None, vec=None, col=None,
              budget=None):
    try:
        comp = compile_src(src)
    except LangError as ex:
        return {"ok": False, "err": str(ex)}
    vm = VM(comp)
    for k in range(4):
        if inputs and k < len(inputs):
            vm.set_input(k, inputs[k])
    if sinputs:
        for ch, s in sinputs.items():
            vm.set_sinput(ch, s)
    if vec:
        vm.set_vec(*vec)
    if col:
        vm.set_col(*col)
    vm.run(budget)
    return {"ok": True, "calls": vm.calls, "out": list(vm.out),
            "nprint": vm.nprint, "failed": vm.failed, "err": vm.err,
            "result": fmt_val(vm.result), "steps": vm.steps,
            "ninstr": len(comp.op), "outVec": list(vm.outVec),
            "outCol": list(vm.outCol)}

# ---------------------------------------------------------------- oracle
LUA_BIN = (shutil.which("lua") or
           r"C:\Users\Alessandro\AppData\Local\Programs\Lua\bin\lua.exe")
FUNC_NORM = re.compile(r"function: 0x[0-9a-fA-F]+")

def force_float(src):
    """Rewrite integer literals as (N+0.0) so Lua 5.4 uses float semantics."""
    try:
        toks = lex(src)
    except LangError:
        return src
    out = []
    pos = 0
    for t in toks:
        if t.kind == "EOF":
            break
        out.append(src[pos:t.a])
        if t.kind == "NUM" and re.fullmatch(r"\d+", t.raw):
            out.append(f"({t.raw}+0.0)")
        else:
            out.append(src[t.a:t.b])
        pos = t.b
    out.append(src[pos:])
    return "".join(out)

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
               timeout=15):
    pre = []
    for k in range(4):
        v = float(inputs[k]) if inputs and k < len(inputs) else 0.0
        pre.append(f"in{k} = {lua_num_lit(v)}")
    for k in (4, 5):
        s = sinputs.get(k, "") if sinputs else ""
        pre.append(f"in{k} = {lua_str_lit(s)}")
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
    prog = "\n".join(pre) + "\n" + force_float(src)
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
TESTS = [
    ("lit-num", "print(3)", None, "run"),
    ("lit-float", "print(3.5)", None, "run"),
    ("lit-exp", "print(1e3, 1.5e-2)", None, "run"),
    ("lit-dot", "print(.5, 5.)", None, "run"),
    ("fmt-add", "print(0.1+0.2)", None, "run"),
    ("fmt-div3", "print(1/3)", None, "run"),
    ("fmt-big", "print(2^100, 1e20)", None, "run"),
    ("fmt-inf", "print(1/0, -1/0)", None, "run"),
    ("fmt-nan", "print(0/0)", None, "run"),
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
    ("inputs-sum", "print(in0+in1+in2+in3)",
     [1, 2, 3, 4], "run"),
    ("inputs-each", "print(in0, in1, in2, in3, in4, in5, invecx, invecy, "
     "invecz, incolr, incolg, incolb, incola)",
     [8, 7, 6, 5], "run",
     {"sinputs": {4: "a", 5: "b"}, "vec": (1, 2, 3),
      "col": (0.5, 0.25, 0.125, 1)}),
    ("inputs-expr", "print(in0*2, in4 .. '!', in3%in1)",
     [10, 3, 0, 7], "run", {"sinputs": {4: "hey"}}),
    ("inputs-vec", "print(invecx+invecy+invecz)", None, "run",
     {"vec": (1.5, 2.5, 3.0)}),
    ("inputs-col", "print(incolr, incolg, incolb, incola)", None, "run",
     {"col": (1, 0.5, 0.25, 1)}),
    ("io-setvec", "setvec(1, 2, 3)", None, "modelio",
     {"expect": {"outVec": [1.0, 2.0, 3.0]}}),
    ("io-setvec-partial", "setvec(in0)", [9], "modelio",
     {"expect": {"outVec": [9.0, 0.0, 0.0]}}),
    ("io-setcol", "setcol(1, 0.5, 0.25, 1)", None, "modelio",
     {"expect": {"outCol": [1.0, 0.5, 0.25, 1.0]}}),
    ("io-strings", "print(in4 .. in5)", None, "run",
     {"sinputs": {4: "foo", 5: "bar"}}),
    ("io-clock", "local a = clock() local b = clock() "
     "print(type(a), b > a)", None, "modelio",
     {"expect": {"calls": [["number", "true"]]}}),
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


def check_one(name, src, inputs, mode, kw=None):
    kw = kw or {}
    if src == "STRESS":
        src = build_stress()
    if src == "OVERCAP":
        src = build_overcap()
    rkw = {k: v for k, v in kw.items() if k != "expect"}
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
        mv = [[norm_val(v) for v in call] for call in m["calls"]]
        if mv != o["calls"]:
            return ("FAIL",
                    f"{name}: value mismatch\n  model={mv}\n  lua  ={o['calls']}")
        return ("PASS", f"{name} steps={m['steps']} instr={m['ninstr']}")
    if mode == "modelio":
        exp = kw.get("expect", {}) if kw else {}
        if not m["ok"]:
            return ("FAIL", f"{name}: model rejected: {m.get('err')}")
        if m["failed"]:
            return ("FAIL", f"{name}: model runtime fail: {m['err']}")
        for key in ("calls", "outVec", "outCol"):
            if key in exp:
                got = [[norm_val(v) for v in call] for call in m[key]] \
                    if key == "calls" else m[key]
                if got != exp[key]:
                    return ("FAIL", f"{name}: {key} mismatch "
                                    f"got={got} want={exp[key]}")
        return ("PASS", name)
    if mode == "modelonly":
        if m["ok"]:
            return ("FAIL", f"{name}: model accepted, want reject "
                            "(documented Tiny exclusion)")
        return ("PASS", name)
    if mode == "synfail":
        if m["ok"]:
            return ("FAIL", f"{name}: model accepted, want reject")
        if o["rc"] == 0:
            return ("FAIL", f"{name}: lua accepted, want reject")
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
        mv = [[norm_val(v) for v in call] for call in m["calls"]]
        if mv != o["calls"]:
            return ("FAIL",
                    f"{name}: partial mismatch\n  model={mv}\n  lua  ={o['calls']}")
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