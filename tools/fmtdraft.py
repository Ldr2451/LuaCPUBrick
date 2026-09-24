"""Save the _fmt draft out of lua.ws (or check it back in).

The gate-side string.format is a work in progress, and lua.ws has to stay in a
state the suite passes, so the draft lives here with the findings that took the
builds to get.  Splice it back in with:

  python -u tools/fmtdraft.py --extract     (write this file's body into lua.ws)
  python -u tools/fmtdraft.py --check       (does lua.ws still have it?)

This file is not WireScript: the two hunks below are what go where.
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WS = os.path.join(ROOT, 'lua.ws')
HEAD = '# ---- lua.ws: replace this line with the hunk below ----'
TAIL = '# ---- lua.ws: insert the second hunk before the generic function call ----'


def hunks(path):
    txt = open(path, encoding='utf-8').read()
    a = txt.index(HEAD) + len(HEAD)
    b = txt.index(TAIL)
    return txt[a:b].strip('\n'), txt[b + len(TAIL):].strip('\n')


def extract():
    lines = open(WS, encoding='utf-8', newline='').read().splitlines()
    state = None
    for i, l in enumerate(lines):
        if l.startswith('// ---------------------------------------------------------------- _fmt'):
            state = i
            break
    end = None
    for i, l in enumerate(lines):
        if l.startswith('// Unlink a slot from its table'):
            end = i
            break
    disp = None
    for i, l in enumerate(lines):
        if '} else if fid == 13 {' in l:
            disp = i
            break
    disp_end = None
    for i in range(disp + 1, len(lines)):
        if lines[i].strip() == '}' and lines[i + 1].strip().startswith('} else {'):
            disp_end = i + 1
            break
    if None in (state, end, disp, disp_end):
        sys.exit('could not find the _fmt hunks in lua.ws')
    out = os.path.join(ROOT, 'lib', 'fmt_gate_draft.txt')
    with open(out, 'w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(lines[state:end]).strip('\n') + '\n\n' + HEAD + '\n\n')
        f.write('\n'.join(lines[disp:disp_end + 1]).strip('\n') + '\n\n' + TAIL + '\n')
    print('wrote lib/fmt_gate_draft.txt (%d state lines, %d dispatch lines)'
          % (end - state, disp_end - disp + 1))


def check():
    txt = open(WS, encoding='utf-8', newline='').read()
    has_state = 'mod fmtStep()' in txt
    has_disp = '} else if fid == 13 {' in txt
    print('lua.ws: state machine %s, dispatch %s'
          % ('present' if has_state else 'absent',
             'present' if has_disp else 'absent'))
    return 0 if has_state and has_disp else 1


def install():
    """Splice both hunks back into lua.ws, and the registration that goes with
    them: NB, the global, and the two init arrays."""
    state, disp = hunks(os.path.join(ROOT, 'lib', 'fmt_gate_draft.txt'))
    lines = open(WS, encoding='utf-8', newline='').read().splitlines()
    if 'mod fmtStep()' in '\n'.join(lines):
        sys.exit('lua.ws already has the state machine')
    out = []
    for l in lines:
        if l.startswith('// Unlink a slot from its table'):
            out += state.splitlines() + ['', '']
        if l.strip() == '} else {':
            out += disp.splitlines()[:-1] + ['    } else {']
            continue
        out.append(l)
    txt = '\n'.join(out)
    for old, new in (('const NB = 13', 'const NB = 14'),
                     ('  gDeclare("unpack")', '  gDeclare("unpack")\n  gDeclare("_fmt")')):
        if old not in txt:
            sys.exit('expected %r in lua.ws -- add it by hand' % old)
        txt = txt.replace(old, new, 1)
    open(WS, 'w', encoding='utf-8', newline='').write(txt)
    print('installed _fmt into lua.ws (%d + %d lines); remember GTAG_INIT, '
          'GNUM_INIT and tests/spec.py' % (len(state.splitlines()),
                                           len(disp.splitlines())))


if '--extract' in sys.argv:
    extract()
elif '--install' in sys.argv:
    install()
else:
    sys.exit(check())
