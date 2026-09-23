"""Wall-clock timing for the test scripts, so every run says how long it took.

Without a number next to the output there is no way to tell a 3-second check
from a 3-minute one, and slow scripts quietly become the ones run in a loop.

    with Elapsed("iter_check") as t:
        ...
    # prints 'iter_check: 12.3s' on exit, also on an exception
"""
import sys
import time


class Elapsed:
    def __init__(self, label: str, quiet: bool = False):
        self.label = label
        self.quiet = quiet
        self.seconds = 0.0

    def __enter__(self):
        self.t0 = time.time()
        return self

    def __exit__(self, *exc):
        self.seconds = time.time() - self.t0
        if not self.quiet:
            print("%s: %.1fs" % (self.label, self.seconds), file=sys.stderr,
                  flush=True)
        return False
