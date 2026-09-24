"""Run a command, stream its output, and say how long it took.

Every check script in the repo prints its own elapsed time, because without a
number there is no way to tell a 3-second probe from a 3-minute one.  A command
typed at the shell -- a compiler, a search, a git operation -- has no such
number, so this is where it comes from:

    python -u tools/timecmd.py <command> [args...]

The child's stdout and stderr are inherited, so a long command still shows its
progress as it goes (never pipe it through a filter that hides the output until
the end).  The exit code is the child's, plus the elapsed time on stderr.  If
the command is not found, the message says so, because on Windows a tool
installed while the shell was already open is on the machine's PATH and not yet
in this session's -- a new terminal has it, and the full path works here.
"""
import os
import subprocess
import sys
import time

if len(sys.argv) < 2:
    sys.exit(__doc__)

argv = sys.argv[1:]
if argv[0].endswith('.py'):
    # Windows will not spawn a .py directly; it needs the interpreter in front
    argv = [sys.executable] + argv
cwd = os.getcwd()
t0 = time.time()
try:
    rc = subprocess.call(argv, cwd=cwd)
except FileNotFoundError:
    print('timecmd: %s not found (a fresh shell has newly installed tools on '
          'PATH; the full path works in this one)' % argv[0], file=sys.stderr)
    rc = 127
except PermissionError:
    print('timecmd: %s is not executable here' % argv[0], file=sys.stderr)
    rc = 126
except OSError as e:
    print('timecmd: cannot run %s: %s' % (argv[0], e), file=sys.stderr)
    rc = 126
dt = time.time() - t0
print('timecmd: %s %s rc=%d %.1fs' % (argv[0], argv[1] if len(argv) > 1 else '',
                                      rc, dt), file=sys.stderr, flush=True)
sys.exit(rc)
