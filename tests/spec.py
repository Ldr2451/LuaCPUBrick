"""Canonical spec constants for the chip.

Single source of truth for the chip's limits and for the shape of the language
it implements.  The chip is WireScript and cannot import this, so the values are
written there too and `test_consistency.py` checks the two agree -- explicit
coupling, never a number that only exists in one place.

The harness knobs (tick budget, timeouts) live here too because four scripts
need the same ones.
"""

KEYWORDS = {"and", "break", "do", "else", "elseif", "end", "false",
            "for", "function", "goto", "if", "in", "local", "nil", "not", "or",
            "repeat", "return", "then", "true", "until", "while"}

(HALT, LOADNIL, LOADNUM, LOADSTR, LOADBOOL, LOADGLOBAL, STOREGLOBAL, MOV,
 ADD, SUB, MUL, DIV, MOD, POW, UNM, NOT, CONCAT, EQ, LT, LE, JMP, JMPF,
 JMPT, CALL, RETURN, LOADFUNC, RETURN0, RETURNV, NEWTABLE, GETFIELD,
 SETFIELD, LEN, FORPREP, FORLOOP, IDIV, BAND, BOR, BXOR, BNOT, SHL, SHR,
 CALLM, RETURNM, ADJUST, TAPPEND, VARARG) = range(46)

N_OPS = 46

# Chip limits.  Each has a `const` of the same name in lua.ws.
MAX_INSTR = 1024
MAX_TOKENS = 4096
MAX_REGS = 64
MAX_FUNCS = 96
MAX_GLOBALS = 64
MAX_CALLS = 32
MAX_TABLES = 64
MAX_HEAP = 512
MAXVALS = 16       # values one call/return/statement can carry
LOG_LINES = 32     # lines kept in the log before the oldest are dropped
LOG_WIDTH = 64     # characters kept per log line
OUTARR = 64        # entries in the outArr port

# Harness defaults, shared by the suite and the oracle-diff checks.
TICKS = 6000       # VM ticks a normal program gets
PROBE_TICKS = 8000  # a little more for the iteration checks
TIMEOUT = 90       # seconds per case before the worker is killed

# Gate-level builtins (VM primitives).  Everything else in the standard library
# is Lua source prepended to the program on demand (see libIter/libString in
# lua.ws).  A program's own functions get ids from NB upward, and NB has to
# match the `const NB` in lua.ws.
BUILTINS = (("print", 0), ("type", 1), ("tostring", 2), ("setvec", 3),
            ("setcol", 4), ("clock", 5), ("inarr", 6), ("outarr", 7),
            ("select", 8), ("next", 9), ("_s", 10), ("_m", 11), ("unpack", 12),
             ("_fmt", 13),
             ("_rd", 14),
             ("_wr", 15))

NB = len(BUILTINS)  # first id available to the program's own functions

# Canonical global slot order the chip must declare (out, in, builtins, ints).
GSLOT_ORDER = ["outNum0", "outNum1", "outNum2", "outNum3", "outStr0",
               "outStr1", "inNum0", "inNum1", "inNum2", "inNum3", "inStr0",
               "inStr1", "invecx", "invecy", "invecz", "incolr", "incolg",
               "incolb", "incola", "print", "type", "tostring", "setvec",
               "setcol", "clock", "inarr", "outarr", "select", "next", "_s",
               "_m", "unpack", "_fmt", "_rd", "_wr", "inInt0", "outInt0"]
