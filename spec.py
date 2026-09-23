"""Canonical Tiny Lua spec constants.

Single source of truth for the language subset the chip implements, used by
the structural checks. (Formerly read off the Python model; the chip is now
tested directly against the Lua 5.5 oracle instead.)
"""

KEYWORDS = {"and", "break", "do", "else", "elseif", "end", "false",
            "for", "function", "goto", "if", "in", "local", "nil", "not", "or",
            "repeat", "return", "then", "true", "until", "while"}

(HALT, LOADNIL, LOADNUM, LOADSTR, LOADBOOL, LOADGLOBAL, STOREGLOBAL, MOV,
 ADD, SUB, MUL, DIV, MOD, POW, UNM, NOT, CONCAT, EQ, LT, LE, JMP, JMPF,
 JMPT, CALL, RETURN, LOADFUNC, RETURN0, RETURNV, NEWTABLE, GETFIELD,
 SETFIELD, LEN, FORPREP, FORLOOP, IDIV, BAND, BOR, BXOR, BNOT, SHL, SHR) = range(41)

N_OPS = 41

MAX_INSTR = 512
MAX_REGS = 64
MAX_FUNCS = 32
MAX_GLOBALS = 64
MAX_CALLS = 32
MAX_TABLES = 64
MAX_HEAP = 512

BUILTINS = (("print", 0), ("type", 1), ("tostring", 2), ("setvec", 3),
            ("setcol", 4), ("clock", 5), ("inarr", 6), ("outarr", 7))

# Canonical global slot order the chip must declare (out, in, builtins, ints).
GSLOT_ORDER = ["outNum0", "outNum1", "outNum2", "outNum3", "outStr0",
               "outStr1", "inNum0", "inNum1", "inNum2", "inNum3", "inStr0",
               "inStr1", "invecx", "invecy", "invecz", "incolr", "incolg",
               "incolb", "incola", "print", "type", "tostring", "setvec",
               "setcol", "clock", "inarr", "outarr", "inInt0", "outInt0"]
