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

A seventh trap -- an assignment at the bottom of a deep else-if chain silently
not taking effect -- is not a shape, it is a structure, so the fix for it is one
mod per state (see fmtLit/fmtFlag/... in lua.ws) rather than a check here.

  python -u tools/wswarn.py [lua.ws]
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
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

names = {}
for m in re.finditer(r'^(?:var|mod|const)\s+(\w+)', src, re.M):
    names.setdefault(m.group(1), []).append(m.start())
dups = [k for k, v in names.items() if len(v) > 1]

p = subprocess.run([WS_EXE, 'compile', path, '--dump-ir'],
                   capture_output=True, text=True, cwd=WS_DIR)
warn = [l.strip() for l in p.stderr.splitlines()
        if 'WARN' in l or '_Unsupported' in l]

print('compiler warnings: %d, name collisions: %d, trap candidates: %d, rc=%d'
      % (len(warn), len(dups), len(hits), p.returncode))
for l in warn[:12]:
    print('  WARN ' + l[:170])
for k in dups:
    print('  HARD %-21s %s is declared more than once' % ('name collision', k))
for i, name, l in hits:
    print('  cand %-21s lua.ws:%d  %s' % (name, i, l[:88]))
if warn or dups:
    print('=> fix the compiler warnings and the collisions')
elif hits:
    print('=> trap candidates only: some shapes are false positives (the print')
    print('   handler concatenates mod calls fine), so read them and judge')
sys.exit(1 if (warn or dups) else 0)
