"""Do vmStep and vmStepFast agree on every opcode they both implement?

The opcode dispatch is written TWICE in lua.ws: `mod vmStep` is the complete
interpreter and `vmStepFast` is the subset that runs when `vmBusy()` is
false.  Every `op == N` arm therefore exists in two places, and nothing in the
compiler stops the two from drifting.

It already happened, and it was invisible.  Fixing the pow arm in vmStep alone
left `local z = -0.0 print(z ^ 3)` answering 0.0 where PUC answers -0.0, because
that program runs the vmStepFast copy.  The suite was green, because the case
that covered pow ran the other arm.

So this compares the two arms textually: for every opcode present in BOTH, the
bodies must be the same once comments and whitespace are removed.  An opcode in
only one of them is not a disagreement -- vmStepFast is deliberately a subset --
so those are listed as information, not failures.

  python -u tools/chip/twopaths.py [lua.ws]

Exit 0 when they agree, 1 with the list of arms that differ.
"""
import os
import re
import sys

# Arms whose bodies legitimately differ, with the reason.  Keep this short: an
# entry here is a place where two copies of one rule are being kept in step by
# hand, which is the thing this tool exists to measure.
ALLOWED = {}


def strip_noise(text):
    """Code with comments and whitespace removed, so only structure is compared.

    Comments go FIRST and this ordering is the whole reason the tool works.  A
    brace-matching scan that does not skip comments desynchronises on the first
    comment holding an unbalanced brace or quote, and then reports an arm as
    disagreeing because it swallowed its neighbours: op 11 looked like a
    difference that was really four arms of overrun.  Comparing comment-free text
    also means a comment that explains WHY two copies differ cannot mask the
    difference, which is the failure this is looking for.
    """
    out = []
    i = 0
    quote = None
    while i < len(text):
        c = text[i]
        if quote:
            out.append(c)
            if c == '\\' and i + 1 < len(text):
                out.append(text[i + 1])
                i += 2
                continue
            if c == quote:
                quote = None
            i += 1
            continue
        if c in "\"'":
            quote = c
            out.append(c)
            i += 1
            continue
        if text[i:i + 2] == '//':
            end = text.find('\n', i)
            i = len(text) if end < 0 else end
            continue
        if c in ' \t\r\n':
            i += 1
            continue
        out.append(c)
        i += 1
    return ''.join(out)


def body_of(src, name):
    """The text between `mod NAME(...) {` or `chip NAME(...) {` and its closer.

    Either keyword counts, and deliberately so.  vmStepFast used to be a `mod`
    because vmBurst calls it four times and a mod inlines at every call site --
    four copies of a 1,173-node body, 12% of the chip.  It is a `chip` now, one
    body with four call sites, and the drift this tool exists to catch is a
    property of the two BODIES, not of how they are declared.  Keying the search
    on `mod` alone made this tool report "could not find vmStepFast" on a chip
    that is perfectly fine, which is the worst kind of net failure: it cries wolf
    once and then it gets ignored.
    """
    m = re.search(r'\b(?:mod|chip)\s+%s\s*\(' % re.escape(name), src)
    if not m:
        return None
    start = src.index('{', m.end())
    depth = 0
    quote = None
    i = start
    while i < len(src):
        c = src[i]
        if quote:
            if c == '\\':
                i += 2
                continue
            if c == quote:
                quote = None
            i += 1
            continue
        if c in "\"'":
            quote = c
        elif c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                return src[start + 1:i]
        i += 1
    return None


def arms(body):
    """opcode -> arm text, for the `else if op == N {` chain inside a mod body.

    Only an ARM OPENER counts.  Matching a bare `op == N` also matches the
    membership tests in the guards -- `op == 24 || op == 33 || op == 50` at the
    bottom of vmStepFast is a list of ops, not three arms -- and taking the brace
    after one of those silently compares an arm against whatever block happens to
    follow it.  That reported op 33 as a disagreement when both copies call
    vmForLoop; the opener requirement is what makes this a check rather than a
    coincidence.

    The body is comment-free by the time it gets here (see strip_noise), so the
    brace and quote walk below cannot be thrown off by prose.
    """
    found = {}
    spans = []
    # `else` carries no trailing \\s: the body reaching here is whitespace-free,
    # so `else if op == 8` has already become `elseifop==8`.  Allowing the space
    # and requiring it each broke this differently -- one found nothing at all.
    for m in re.finditer(r'(?:^|[{};])else?if\s*op\s*==\s*(\d+)\s*\{', body):
        op = int(m.group(1))
        brace = body.index('{', m.end() - 1)
        close = match_brace(body, brace)
        if close is None:
            continue
        found.setdefault(op, body[brace + 1:close])
        spans.append((op, close))

    # A chain that ends in a bare `else` has an arm with no opcode to key it on,
    # and that is not a corner case: POW is the `else` after the op == 12 arm in
    # both dispatchers.  A tool that only matched `op == N` therefore could not
    # see the very arm that drifted when the negative-zero fix reached one copy --
    # it reported OK on a chip where one site called powSignedZero and the other
    # did not.  Each terminal else is keyed as `else<N>` for the arm it follows,
    # a name both sides agree on.
    for op, close in spans:
        m = re.match(r'else\{', body[close + 1:])
        if not m:
            continue
        brace = close + 1 + m.end() - 1
        end = match_brace(body, brace)
        if end is None:
            continue
        key = 'else%d' % op
        if key not in found:
            found[key] = body[brace + 1:end]
    return found


def match_brace(body, brace):
    """Index of the `}` that closes the `{` at `brace`, or None if unbalanced."""
    depth = 0
    quote = None
    i = brace
    while i < len(body):
        c = body[i]
        if quote:
            if c == '\\':
                i += 2
                continue
            if c == quote:
                quote = None
            i += 1
            continue
        if c in "\"'":
            quote = c
        elif c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return None


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        os.path.dirname(os.path.dirname(os.path.dirname(
            os.path.abspath(__file__)))), 'lua.ws')
    src = open(path, encoding='utf-8').read()
    slow = body_of(src, 'vmStep')
    fast = body_of(src, 'vmStepFast')
    if slow is None or fast is None:
        print('could not find both bodies (vmStep=%s vmStepFast=%s)'
              % (slow is not None, fast is not None))
        return 1
    sa, fa = arms(strip_noise(slow)), arms(strip_noise(fast))
    # Zero arms is a FAILURE, not a pass.  The first version of this regex
    # required a space after `else`, so on whitespace-free text it matched nothing
    # and printed "OK: every shared opcode has the same body in both" -- a green
    # run having compared no arms at all, which is the one outcome this tool
    # exists to make impossible elsewhere.  A net that cannot fail is not a net,
    # so the count is asserted rather than assumed.
    if not sa or not fa:
        print('FAIL: found %d arms in vmStep and %d in vmStepFast; the '
              'extraction is broken, not the chip' % (len(sa), len(fa)))
        return 1
    both = sorted(set(sa) & set(fa), key=str)
    only_slow = sorted(set(sa) - set(fa))
    only_fast = sorted(set(fa) - set(sa))
    bad = []
    for op in both:
        if sa[op] == fa[op]:
            continue
        if op in ALLOWED:
            continue
        bad.append((op, sa[op], fa[op]))
    print('vmStep arms: %d   vmStepFast arms: %d   shared: %d'
          % (len(sa), len(fa), len(both)))
    print('shared keys: %s' % (both,))
    print('only in vmStep (%d): %s' % (len(only_slow), only_slow))
    print('only in vmStepFast (%d): %s' % (len(only_fast), only_fast))
    if not bad:
        print('OK: every shared arm has the same body in both')
        return 0
    print('DIFFER: %d shared arm(s) disagree' % len(bad))
    for op, a, b in bad:
        print('\n  arm %s' % op)
        print('    vmStep     : %s' % a[:300])
        print('    vmStepFast : %s' % b[:300])
    return 1


if __name__ == '__main__':
    sys.exit(main())