"""Fast pre-flight: everything that catches a bad chip edit in seconds.

The parser is a hand-rolled resumable state machine with its scratch state in
globals, so the failures a feature addition tends to cause are not the new
feature misbehaving -- they are the constructs around it.  Those used to be
found by running the whole suite, which is a thirty-second wait for a
two-second answer.  This runs the cheap half of the test matrix instead:

  tools/audit.py       one build, then the three static facts: compiler
                       _Unsupported placeholders (it silently gave up on an
                       expression, so the chip builds and reads 0), gate classes
                       the simulator has no handler for, and the node/wire count
  tests/test_consistency.py
                       static structure: builtin ids, global slot order,
                       limits, opcode and keyword coverage, state clearing
  tests/syntax_check.py
                       the parser battery: nesting and call positions,
                       diffed against real Lua

One chip build is shared by every case in the last one, so the whole run is
build-sized.  It is not a substitute for the suite -- it does not check
results, only shapes -- so run the suite before committing, and this one
after every edit.

  python -u tools/preflight.py
"""
import os
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

CHECKS = [
    ('audit', ['tools/audit.py'], '0 placeholder(s)'),
    ('consistency', ['tests/test_consistency.py'], 'ALL-OK'),
    ('syntax', ['tests/syntax_check.py'], 'FAIL=0'),
]

failed = []
total = 0.0
for name, args, expect in CHECKS:
    t0 = time.time()
    p = subprocess.run([sys.executable, '-u'] + args, cwd=ROOT,
                       capture_output=True, text=True)
    out = p.stdout + p.stderr
    secs = time.time() - t0
    total += secs
    # each checker states its own verdict, so match that rather than guessing
    # from the exit code alone
    good = expect in out
    print('%-12s %-4s %5.1fs  %s' % (
        name, 'OK' if good else 'FAIL', secs, args[-1]))
    if not good:
        failed.append((name, out))
    for line in out.splitlines():
        if line.startswith(('FAIL', 'Traceback')) or 'placeholder(s)' in line \
                or 'unhandled' in line or 'FAIL=' in line or 'ALL-OK' in line:
            print('    ' + line)
print('\npreflight: %d/%d checks passed in %.1fs' % (
    len(CHECKS) - len(failed), len(CHECKS), total))

if failed:
    print('FAILED: ' + ', '.join(n for n, _ in failed))
    for name, out in failed:
        print('--- %s ---\n%s' % (name, '\n'.join(out.splitlines()[-40:])))
sys.exit(1 if failed else 0)
