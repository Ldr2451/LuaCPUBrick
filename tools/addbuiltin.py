"""Register new gate builtins: every place a builtin's id has to appear.

A builtin is not one line.  Adding `_fmt` by hand meant touching seven: the NB
count, a gDeclare in parseInit, one tag in GTAG_INIT, one number in GNUM_INIT,
the two lists in tests/spec.py, and the comment that names the builtins.  Miss one
and nothing says so -- the stress case only failed because the chip ran out of
global slots one builtin later, and a stale fid is a *different* builtin
silently.

  python -u tools/addbuiltin.py _rd _wr         (ids continue from NB)
  python -u tools/addbuiltin.py --at 20 pcall   (explicit id, must be == NB)
  python -u tools/addbuiltin.py --check

This only does the bookkeeping.  The builtin's state, its mods and its dispatch
case in vmStep are written by hand; this keeps the seven lists in step.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WS = os.path.join(ROOT, 'lua.ws')
SPEC = os.path.join(ROOT, 'tests', 'spec.py')


def sub1(txt, old, new, what):
    n = txt.count(old)
    if n != 1:
        sys.exit('anchor %r matched %d times, expected 1' % (what, n))
    return txt.replace(old, new, 1)


def read():
    return (open(WS, encoding='utf-8', newline='').read(),
            open(SPEC, encoding='utf-8', newline='').read())


def spec_builtins(spec):
    return re.findall(r'\("(\w+)",\s*(\d+)\)', spec)


def spec_order(spec):
    m = re.search(r'GSLOT_ORDER = \[(.*?)\]', spec, re.S)
    return re.findall(r'"(\w+)"', m.group(1))


def apply(names, at):
    ws, spec = read()
    have = spec_builtins(spec)
    ids = [int(i) for _, i in have]
    if ids != list(range(len(ids))):
        sys.exit('spec BUILTINS ids are not contiguous from 0: %s' % ids)
    next_id = len(ids)
    if at is not None and at != next_id:
        sys.exit('--at %d but the next free id is %d' % (at, next_id))
    new = [(n, next_id + k) for k, n in enumerate(names)]
    for n, _ in new:
        if n in [x for x, _ in have]:
            sys.exit('%s is already a builtin' % n)

    ws = sub1(ws, 'const NB = %d' % next_id, 'const NB = %d' % (next_id + len(new)),
              'const NB')
    # the gDeclare block ends with the two int globals
    ws = sub1(ws, '  gDeclare("inInt0")',
              ''.join('  gDeclare("%s")\n' % n for n, _ in new) + '  gDeclare("inInt0")',
              'gDeclare(inInt0)')
    for arr, before, val in (('GTAG_INIT', '6, 6', '4'),
                             ('GNUM_INIT', '0.0, 0.0', None)):
        m = re.search(r'var %s: (?:int|float)\[\] = \[([^\]]*)\]' % arr, ws)
        vals = [v.strip() for v in m.group(1).split(',')]
        trail = len(before.split(','))
        if [v.strip() for v in before.split(',')] != vals[-trail:]:
            sys.exit('%s does not end in %s' % (arr, before))
        if val is not None:
            add = [val] * len(new)
        else:
            add = ['%d.0' % i for _, i in new]
        vals[len(vals) - trail:-trail] = add
        ws = ws[:m.start(1)] + ', '.join(vals) + ws[m.end(1):]
    # the comment that names the builtins, so it cannot go stale; two small
    # substitutions keep whatever wrapping the line already has
    lo = spec_order(spec).index(have[0][0])
    hi = lo + len(have) + len(new) - 1
    ws, n1 = re.subn(r'\d+\.\.\d+ builtins', '%d..%d builtins' % (lo, hi), ws, count=1)
    last = re.escape(have[-1][0])
    ws, n2 = re.subn(r'(%s)([,)] as)' % last,
                     r'\1, %s\2' % ', '.join(n for n, _ in new), ws, count=1)
    if not (n1 and n2):
        sys.exit('could not find the "NN..NN builtins (...)" comment to update')

    m = re.search(r'BUILTINS = \(.*?\)\n', spec, re.S)
    # drop the tuple's closing paren, add the new entries, put it back
    body = m.group(0).rstrip()
    assert body.endswith(')'), body
    add = ''.join(',\n             ("%s", %d)' % (n, i) for n, i in new)
    spec = spec[:m.start()] + body[:-1].rstrip() + add + ')\n' + spec[m.end():]
    order = spec_order(spec)
    at_in = order.index('inInt0')
    ins = ''.join('"%s", ' % n for n, _ in new)
    spec = sub1(spec, '"inInt0"', ins + '"inInt0"', 'GSLOT_ORDER inInt0')

    open(WS, 'w', encoding='utf-8', newline='').write(ws)
    open(SPEC, 'w', encoding='utf-8', newline='').write(spec)
    print('registered %s -> ids %s, NB = %d'
          % (', '.join(n for n, _ in new), [i for _, i in new],
             next_id + len(new)))
    print('now write the state, the mods and the dispatch case for each')


def check():
    ws, spec = read()
    have = spec_builtins(spec)
    order = spec_order(spec)
    nb = int(re.search(r'const NB = (\d+)', ws).group(1))
    ok = True
    if len(have) != nb:
        print('FAIL NB=%d but spec has %d builtins' % (nb, len(have)))
        ok = False
    tags = re.search(r'var GTAG_INIT: int\[\] = \[([^\]]*)\]', ws).group(1).split(',')
    nums = re.search(r'var GNUM_INIT: float\[\] = \[([^\]]*)\]', ws).group(1).split(',')
    if len(tags) != len(order) or len(nums) != len(order):
        print('FAIL the init arrays are %d/%d long, GSLOT_ORDER is %d'
              % (len(tags), len(nums), len(order)))
        ok = False
    else:
        for n, i in have:
            slot = order.index(n)
            if tags[slot].strip() != '4' or float(nums[slot]) != int(i):
                print('FAIL %s: slot %d has tag %s num %s, want tag 4 num %s'
                      % (n, slot, tags[slot].strip(), nums[slot].strip(), i))
                ok = False
    decls = re.findall(r'gDeclare\("(\w+)"\)', ws)
    if decls != order:
        print('FAIL parseInit declares %d names, GSLOT_ORDER has %d'
              % (len(decls), len(order)))
        ok = False
    print('builtins %d, NB %d, slots %d: %s'
          % (len(have), nb, len(order), 'OK' if ok else 'MISMATCH'))
    return 0 if ok else 1


if __name__ == '__main__':
    if '--check' in sys.argv:
        sys.exit(check())
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    at = None
    if '--at' in sys.argv:
        at = int(sys.argv[sys.argv.index('--at') + 1])
        args = [a for a in args if a != str(at)]
    if not args:
        sys.exit('usage: addbuiltin.py [--at N] name [name ...] | --check')
    apply(args, at)
