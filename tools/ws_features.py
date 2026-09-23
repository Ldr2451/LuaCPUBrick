"""What loop and control facilities does the WireScript host actually offer?

The chip is written in WireScript, which is not Lua: if it has no `while` and
no `break`, then every loop in the chip is a bounded `for` that the compiler
unrolls, and the gate cost of a loop is proportional to its trip count.  That
number decides where expensive work can live, so it is worth reading off the
chip source rather than guessing.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ws = open(os.path.join(ROOT, 'lua.ws'), encoding='utf-8').read()

# const LIB_* lines carry Lua source, not WireScript: hide them
lines = []
for line in ws.splitlines():
    lines.append('' if line.startswith('const LIB_') else line)
body = '\n'.join(lines)

for kw in ('while', 'break', 'continue', 'for', 'loop'):
    pat = re.compile(r'^\s*%s\b' % kw)
    hits = [(i, l.strip()) for i, l in enumerate(lines, 1) if pat.match(l)]
    print('%-8s %d line(s) at statement start' % (kw, len(hits)))
    for i, l in hits[:6]:
        print('   %5d %s' % (i, l[:96]))

print('\nfor-loop headers:')
for m in sorted(set(re.findall(r'^\s*for\s+[^\n{]*\{', body, re.M))):
    print('   ' + m.strip()[:96])

print('\ngate-side unrolled step calls (how the chip avoids loops):')
for m in sorted(set(re.findall(r'^\s*(lexChunk|parseChunk|vmStep|vmBurst|stepOnce)\(\)', body, re.M))):
    print('   ' + m)
