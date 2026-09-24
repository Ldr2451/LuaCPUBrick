"""Which operators and call shapes does the WireScript source actually use?

The compiler leaves an _Unsupported placeholder for an expression it cannot
lower, and tools/audit.py counts them, but it does not say which line produced
one.  Rather than guess, read what the working chip uses: if no mod in the
WireScript source contains a `%`, then `%` is not lowerable, and every new `%` is
a placeholder.  Same for a method call inside a binary operation.

  python -u tools/ws_features.py
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ws = open(os.path.join(ROOT, 'lua.ws'), encoding='utf-8').read()

# const LIB_* lines carry Lua source, not WireScript: hide them
lines = ['' if l.startswith('const LIB_') else l for l in ws.splitlines()]
code = [(i, l) for i, l in enumerate(lines, 1)
        if l.strip() and not l.strip().startswith('//')]

CHECKS = [
    ('percent', re.compile(r'[^%]%[^%]')),
    ('bitwise-and', re.compile(r'[^&]&[^&=]')),
    ('method-in-expr', re.compile(r'[+*/-]\s*\w+\.\w+\(')),
    ('mod-in-expr', re.compile(r'[+*/-]\s*[A-Za-z_]\w*\(')),
    ('unary-not', re.compile(r'!\s*[A-Za-z_]')),
    ('for-loop', re.compile(r'^\s*for\b')),
]
for name, pat in CHECKS:
    hits = [(i, l.strip()) for i, l in code if pat.search(l)]
    print('%-16s %3d' % (name, len(hits)))
    for i, l in hits[:4]:
        print('   %5d %s' % (i, l[:92]))
