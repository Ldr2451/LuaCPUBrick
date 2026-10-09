"""One chip run vs the Lua 5.5 oracle, shared by every differential check.

The parser is a hand-rolled resumable state machine whose scratch state lives
in globals, so a construct that nests differently can silently clobber the
outer one's state.  These checks all want the same thing -- run the chip and
real Lua on one program and compare what they printed -- so the glue lives
here once: one ChipRunner for the whole process (a rebuild per program costs
six seconds), one oracle call, one normalisation, one result shape.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.dirname(HERE), 'irrun'))

from irsims import ChipRunner
import lua_oracle as OR

RUNNER = None


def runner():
    global RUNNER
    if RUNNER is None:
        RUNNER = ChipRunner(os.path.join(os.path.dirname(HERE), 'lua.ws'))
    return RUNNER


def norm_fn(s):
    """PUC Lua prints 'function: 0x...' / 'table: 0x...'; the chip prints the
    type name.  Documented divergence, so compare on the type."""
    return re.sub(r'\b(function|table|thread|userdata): [0-9a-fx]+', r'\1', s)


def oracle(src):
    o = OR.oracle_run(src)
    if not o.get('avail'):
        return '<oracle unavailable>'
    if o.get('calls') is None:
        return '<oracle: %s>' % o.get('stderr')
    return OR.oracle_log(o['calls'])


def diff(src, ticks=8000, norm=False):
    """Run src on the chip and on the oracle.  Returns (ok, got, want, err).

    norm=True compares with the type names PUC prints addresses for folded to
    their type, for cases that print functions or tables.
    """
    want = oracle(src)
    try:
        r = runner().run(src, ticks)
        got, err = r.get('log', ''), r.get('outGlobals', {}).get('runErrors', '')
    except Exception as e:                      # a sim build error is a failure
        got, err = '<sim error: %s>' % e, ''
    a, b = (norm_fn(got), norm_fn(want)) if norm else (got, want)
    return a == b, got, want, err


def report(cases, label, ticks=8000, norm=False):
    """Diff every case, print one line each, and return the failure count."""
    ok = fail = 0
    for src in cases:
        good, got, want, err = diff(src, ticks, norm)
        ok += good
        fail += not good
        print("%s chip=%r lua=%r err=%r :: %s" % (
            'OK  ' if good else 'FAIL', got, want, err, src), flush=True)
    print('\n%s OK=%d FAIL=%d' % (label, ok, fail))
    return fail
