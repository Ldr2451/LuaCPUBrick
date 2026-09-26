"""Explain why the chip is unhappy: compiler warnings, and the traps it has.

Two sources, one report:

  * the compiler's own warnings, which name the line and the expression it could
    not lower, and
  * the shapes that compile clean and then misbehave, which cost far more time
    because nothing complains.  Every one of these was measured on this chip:

      mod-call in a concat   `s = s .. _s(1, ...)`  -> "attempt to call"
      string `+`             `a .. b + c`           -> placeholder
      `%` or `for`           no loop, no modulo      -> placeholder
      compare into a var     `flag = a == 1`        -> placeholder
      name collision         a mod and a var named x -> placeholder
      string ordering        `c >= "0"`             -> silently false
      string from a mod      its ToCharCode() is 0
      index form             vTag takes a register RELATIVE to the frame and adds
                             vmBase; handing it an absolute index counts vmBase
                             twice, which is invisible at top level and wrong by
                             exactly vmBase in a function

A seventh trap -- an assignment at the bottom of a deep else-if chain silently
not taking effect -- is not a shape, it is a structure, so the fix for it is one
mod per state (see fmtLit/fmtFlag/... in lua.ws) rather than a check here.

  python -u tools/chip/wswarn.py [lua.ws]
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, 'irrun'))
from irdump import WS_EXE, WS_DIR

path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'lua.ws')
src = open(path, encoding='utf-8', newline='').read()

# const LIB_* lines are Lua source for the library, not WireScript: a trap in
# that text is PUC's problem to solve, not the compiler's
code = [(i, l) for i, l in enumerate(src.splitlines(), 1)
        if l.strip() and not l.strip().startswith('//')
        and not l.startswith('const LIB_')]


def strip_strings(l):
    """Blank out string literals so a `+` or `%` inside one is not a hit."""
    return re.sub(r'"(\\.|[^"\\])*"', '""', l)


TRAPS = [
    # Two concat shapes fail, both measured: a call on the RIGHT of `..`
    # (`s = s .. _s(1, ...)` -> "attempt to call") and a call whose result has
    # a property read before the `..` (`out .. FromCharCode(x).Character`).
    # A plain call on the left is fine -- logPush does `line.Substring(0, 63)
    # .. "\n"` and the log-wide case passes -- so only these two are flagged.
    ('concat with a call', re.compile(r'\.\.\s*[A-Za-z_]\w*\(|'
                                      r'[A-Za-z_]\w*\([^()]*\)\.\w+\s*\.\.')),
    ('string +', re.compile(r'""\s*\+|\+\s*""')),
    ('percent', re.compile(r'[^%]%[^%]')),
    ('for loop', re.compile(r'^\s*for\b')),
    ('compare into a var', re.compile(r'^\s*var\s+\w+\s*=.*(?:==|!=|<=|>=)')),
    ('string ordering', re.compile(r'[A-Za-z_)\]]\s*(?:>=|<=)\s*"')),
]

# A condition on a file-level var, nested inside another if, is unreliable where
# the mod around it is inlined more than once: measured while building _fmt, where
# fmtPadStep's `if fmtPadLeft` chose the else arm whatever the var held -- swapping
# the two arms changed nothing.  vmStep is inlined four times (vmBurst calls it
# four times a tick) and the compiler shares one Get per var across the copies;
# the lexer's own chain has the same shape and works, because lexChunk inlines it
# once.  So this is a prompt to hoist the test or take the flag as a parameter,
# not a verdict -- the two candidates it prints today are both in the lexer and
# both work.  Indent is the proxy for "nested"; the file is formatted consistently.
NESTED = re.compile(r'^\s{4,}(?:}\s*else\s+)?if\s+(!?\w+)\s*\{')

hits = []
for name, pat in TRAPS:
    for i, l in code:
        if pat.search(strip_strings(l)):
            hits.append((i, name, l.strip()))
            break       # one example per trap is enough to act on

filevars = set(re.findall(r'^var\s+(\w+)', src, re.M))
for i, l in code:
    m = NESTED.match(l)
    if m and m.group(1).lstrip('!') in filevars:
        hits.append((i, 'nested filevar cond', l.strip()))
        break

# A copy of a var the same mod has already written reads the value from before
# that write, not the one the source says: measured, and silent both times.
# patArm's `patR = patStart` read the patStart from before the line above wrote
# it, so the pattern walk never advanced its right edge and a for-in in gmatch
# ran to the tick budget; patOpen's `n = patCapN + 1` came out as `n + 1` at the
# push.  The rule is deliberately narrow -- only a *bare* copy of a file-level var
# -- because reading a var after writing it is normal and usually right, and the
# first version of this check flagged 259 sites of which two were bugs.  The fix
# is always the same: compute into a `let`, then write the vars.
COPY = re.compile(r'^\s*(?:var\s+|let\s+)?(\w+)\s*=\s*(\w+)\s*$')
MODHEAD = re.compile(r'^mod\s+(\w+)\(')

# Register access comes in two forms and mixing them is the bug this catches.
# vTag/vNum/vStr/vSet take a register RELATIVE to the current frame and add
# vmBase themselves; a var holding an ABSOLUTE index has to read vtag[]/vnum[]/
# vstr[] directly.  Handing an absolute index to the accessor counts vmBase twice:
# invisible at top level, where vmBase is 0, and wrong by exactly vmBase inside a
# function.  The formatter's conversions did it, so every argument but the last
# came from two registers too high -- `return string.format('%s%s%s', 'a', 'b',
# 'c')` printed `cnilnil`.  Three fixes that changed the *shape* of the read all
# failed the same way before anyone read what vTag does with its argument, which
# is why this is a shape check and not a comment.
#
# The carriers are these names and these mods, and a name that no longer exists is
# itself a finding so the list cannot rot.  The check is per mod and follows the
# value, because the bug arrives as a local: `let ab = fmtArgAt()` and then
# `vTag(ab)`, which is why matching on the argument text alone finds nothing.
# The converse -- a relative index read out of vtag[] -- is NOT visible here: the
# two forms are the same text, and only the value's origin tells them apart.
ABSOLUTE_VARS = ('fmtBase', 'nxDst')
ABSOLUTE_FNS = ('fmtArgAt',)
ACCESSOR = re.compile(r'\bv(?:Tag|Num|Str|Set|SetNum|SetInt|SetStr)\(\s*'
                      r'([^()]*?)\s*\)')
ASSIGN = re.compile(r'^\s*(?:var\s+|let\s+)?(\w+)\s*=\s*(?!=)(\S.*)$')


def root_name(expr):
    """The identifier an index expression starts from, if any."""
    m = re.match(r'([A-Za-z_]\w*)', expr.strip())
    return m.group(1) if m else None


def is_absolute_expr(expr):
    """Whether an expression yields an absolute register index."""
    if 'vmBase' in expr:
        return 'it already carries vmBase'
    head = expr.strip()
    for fn in ABSOLUTE_FNS:
        if head.startswith(fn + '('):
            return '%s returns an absolute index' % fn
    r = root_name(head)
    if r in ABSOLUTE_VARS:
        return '%s is an absolute index' % r
    return None


def absolute_as_relative(body, mod_name):
    """Accessor calls in one mod whose argument is an absolute index.

    An assignment that *makes* a value absolute is how they are made, so only
    the reads and writes through an accessor are reported."""
    out, absolute = [], set()
    for ln, line in body:
        m = ASSIGN.match(line)
        if m and is_absolute_expr(m.group(2)):
            absolute.add(m.group(1))
        for arg in ACCESSOR.findall(line):
            why = is_absolute_expr(arg) if arg else None
            if why is None and root_name(arg) in absolute:
                why = 'it traces back to an absolute index'
            if why:
                out.append((ln, mod_name, arg, why))
                break
    return out


def empty_result_slots(head, body, mod_name):
    """A gate arm that can answer NO values without nil-ing the callee slot.

    A call's results land in the register the function was in, and that is the
    register the compiler puts the local in, so an empty result list has to
    leave a nil there -- PUC's `local c = select(2, ...)` is nil.  print, outvec,
    outcol, outarr and _s's byte-out-of-range all write it; select and unpack
    did not, and `type(c)` read "function".

    The unit is the ARM, not the mod: print nils its own register and select did
    not, and a mod-wide test sees print's write and says nothing.  So the body is
    cut at the `} else if fid ==` boundaries and each arm is judged on its own
    text.  Only mods with a parameter named `a` are read at all -- that is the
    call's own register, which is what gateLow and gateHigh hand their arms;
    patArm and pcallEnd write an absolute register of their own (the machine's
    dst, the pcall marker) and are not this shape.
    """
    if not re.search(r'\(\s*[^)]*\ba\s*:\s*int', head):
        return []
    arm, arms = [], []
    for ln, bl in body:
        if re.match(r'\s*\}\s*else\s+if\s+fid\s*==', bl) and arm:
            arms.append(arm)
            arm = []
        arm.append((ln, bl))
    if arm:
        arms.append(arm)
    out = []
    for seg in arms:
        text = "\n".join(bl for _, bl in seg)
        m = re.search(r'retCountV\s*=\s*(?:0|cnt|0\s*-\s*n\b)', text)
        if not m:
            continue
        if re.search(r'vSet\(\s*\w+\s*,\s*0\s*,|vtag\[[^\]]*\]\s*=\s*0\b',
                     text):
            continue
        out.append((seg[0][0], mod_name, m.group(0)))
    return out


filevars = set(re.findall(r'^var\s+(\w+)', src, re.M))
hits_raw = []
hits_abs = []
hits_empty = []
lines = src.splitlines()
i = 0
while i < len(lines):
    m = MODHEAD.match(lines[i])
    if m:
        j, depth, body, started = i, 0, [], False
        while j < len(lines):
            body.append((j + 1, lines[j]))
            if '{' in lines[j]:
                depth += lines[j].count('{')
                started = True
            if '}' in lines[j]:
                depth -= lines[j].count('}')
                if started and depth <= 0:
                    break
            j += 1
        written = {}
        for ln, bl in body:
            c = COPY.match(bl)
            if c and c.group(2) in filevars and c.group(2) in written:
                hits_raw.append((ln, m.group(1), c.group(1), c.group(2),
                                 written[c.group(2)], bl.strip()))
                continue
            w = re.match(r'^\s*(?:var\s+)?(\w+)\s*(?:\[[^\]]*\])?\s*'
                         r'(?:=|\+=|-=)\s*(?!=)', bl)
            if w and w.group(1) in filevars:
                written.setdefault(w.group(1), ln)
        hits_abs += absolute_as_relative(
            [(ln, bl) for ln, bl in body if bl.strip()
             and not bl.strip().startswith('//')], m.group(1))
        mod_ln = i + 1
        for ln, mn, what in empty_result_slots(
                lines[i], [(ln, bl) for ln, bl in body if bl.strip()
                           and not bl.strip().startswith('//')], m.group(1)):
            hits_empty.append((ln, mn, what))
        i = j
    i += 1

for v in ABSOLUTE_VARS:
    if not re.search(r'^var\s+%s\b' % re.escape(v), src, re.M):
        hits_abs.append((0, 'list', v, '%s is in ABSOLUTE_VARS but is gone' % v))

names = {}
for m in re.finditer(r'^(?:var|mod|const)\s+(\w+)', src, re.M):
    names.setdefault(m.group(1), []).append(m.start())
dups = [k for k, v in names.items() if len(v) > 1]

p = subprocess.run([WS_EXE, 'compile', path, '--dump-ir'],
                   capture_output=True, text=True, cwd=WS_DIR)
warn = [l.strip() for l in p.stderr.splitlines()
        if 'WARN' in l or '_Unsupported' in l]

print('compiler warnings: %d, name collisions: %d, trap candidates: %d, '
      'var rereads: %d, index forms: %d, empty results: %d, rc=%d'
      % (len(warn), len(dups), len(hits), len(hits_raw), len(hits_abs),
         len(hits_empty), p.returncode))
for l in warn[:12]:
    print('  WARN ' + l[:170])
for k in dups:
    print('  HARD %-21s %s is declared more than once' % ('name collision', k))
for i, name, l in hits:
    print('  cand %-21s lua.ws:%d  %s' % (name, i, l[:88]))
for ln, mod_name, dst, src, wln, l in hits_raw:
    print('  cand %-21s lua.ws:%d  %s: %s = %s copies a var written at :%d'
          % ('var copy after write', ln, mod_name, dst, src, wln))
for ln, mod_name, arg, why in hits_abs:
    print('  cand %-21s lua.ws:%d  %s: accessor argument %r -- %s'
          % ('absolute as relative', ln, mod_name, arg, why))
for ln, mod_name, what in hits_empty:
    print('  cand %-21s lua.ws:%d  %s: %s with no nil written to the '
          'callee slot' % ('empty result', ln, mod_name, what))
if warn or dups:
    print('=> fix the compiler warnings and the collisions')
elif hits or hits_raw or hits_abs or hits_empty:
    print('=> trap candidates only: some shapes are false positives (the print')
    print('   handler concatenates mod calls fine), so read them and judge')
sys.exit(1 if (warn or dups) else 0)
