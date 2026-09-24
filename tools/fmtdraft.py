"""Install the _fmt gate builtin into lua.ws, or take it back out.

  python -u tools/fmtdraft.py --install   splice the draft + all registration in
  python -u tools/fmtdraft.py --check     what lua.ws has
  python -u tools/fmtdraft.py --extract   save lua.ws's copy back to the draft

The draft itself is lib/fmt_gate_draft.txt, which is not WireScript: the two
hunks there are what go where.  Every edit below is a one-anchor replacement and
each one is asserted to match exactly once -- the first version of this tool
anchored the dispatch on `} else {`, which matches hundreds of lines, and spliced
the state machine into the chip 164 times (68k nodes -> 162k, every gate a
placeholder).  A silent multi-match is the failure mode to design against.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WS = os.path.join(ROOT, 'lua.ws')
SPEC = os.path.join(ROOT, 'tests', 'spec.py')
CONS = os.path.join(ROOT, 'tests', 'test_consistency.py')
DRAFT = os.path.join(ROOT, 'lib', 'fmt_gate_draft.txt')
HEAD = '# ---- lua.ws: replace this line with the hunk below ----'
TAIL = '# ---- lua.ws: insert the second hunk before the generic function call ----'

STATE_START = '// ---------------------------------------------------------------- _fmt'
STATE_END = '// Unlink a slot from its table'
DISP_START = '} else if fid == 13 {'
DISP_END = '          if fFunc.length() >= MAX_CALLS {'
NEXTS = '              nxPc = vmPc\n              nxActive = true'
NEXTS_NEW = '              nxPc = vmPc\n              nxMode = 0\n              nxActive = true'
NXSTEP = '  } else if nxActive {\n    nxStep()'
NXSTEP_NEW = """  } else if nxActive {
    if nxMode == 1 {
      if fmtGo {
        fmtGo = false
        fmtStep()
      }
    } else {
      nxStep()
    }"""
FMTGO = 'mod vmBurst() {\n  fmtGo = true'


def sub1(txt, old, new, what):
    n = txt.count(old)
    if n != 1:
        sys.exit('anchor %r matched %d times, expected 1' % (what, n))
    return txt.replace(old, new, 1)


def hunks(path=DRAFT):
    """The draft is: header, then the state machine, HEAD, the dispatch, TAIL."""
    txt = open(path, encoding='utf-8').read()
    a = txt.index(HEAD)
    b = txt.index(TAIL)
    return (txt[:a].strip('\n'),                 # state machine
            txt[a + len(HEAD):b].strip('\n'))     # dispatch case


def extract():
    lines = open(WS, encoding='utf-8', newline='').read().splitlines()
    state = next((i for i, l in enumerate(lines) if l.startswith(STATE_START)), None)
    end = next((i for i, l in enumerate(lines) if l.startswith(STATE_END)), None)
    disp = next((i for i, l in enumerate(lines) if DISP_START in l), None)
    if None in (state, end, disp):
        sys.exit('could not find the _fmt hunks in lua.ws')
    # the hunk runs to the `}` (or `} else {`) that opens the generic call
    disp_end = next(i for i in range(disp + 1, len(lines))
                    if lines[i].strip() in ('}', '} else {')
                    and DISP_END in lines[i + 1])
    with open(DRAFT, 'w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(lines[state:end]).strip('\n') + '\n\n' + HEAD + '\n\n')
        f.write('\n'.join(lines[disp:disp_end + 1]).strip('\n') + '\n\n' + TAIL + '\n')
    print('wrote lib/fmt_gate_draft.txt (%d state lines, %d dispatch lines)'
          % (end - state, disp_end - disp + 1))


def check():
    txt = open(WS, encoding='utf-8', newline='').read()
    parts = [('state machine', 'mod fmtStep()' in txt),
             ('dispatch', DISP_START in txt),
             ('NB = 14', 'const NB = 14' in txt),
             ('global', 'gDeclare("_fmt")' in txt),
             ('nxMode', 'var nxMode: int' in txt),
             ('fmtGo', 'var fmtGo: bool' in txt),
             ('nxStep mode', NXSTEP_NEW in txt),
             ('vmBurst raises fmtGo', FMTGO in txt),
             ('next mode 0', 'nxPc = vmPc\n              nxMode = 0\n' in txt),
             ('library alias', 'LIB_str_fmt' in txt),
             ('GTAG_INIT', re.search(r'var GTAG_INIT: int\[\] = \[[^\]]*4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6\]', txt) is not None),
             ('GNUM_INIT', '12.0, 13.0, 0.0, 0.0]' in txt),
             ('spec BUILTINS', '("_fmt", 13)' in open(SPEC, encoding='utf-8').read())]
    for what, ok in parts:
        print('%-16s %s' % (what, 'present' if ok else 'ABSENT'))
    return 0 if all(ok for _, ok in parts) else 1


def install():
    state, disp = hunks()
    lines = open(WS, encoding='utf-8', newline='').read().splitlines()
    if 'mod fmtStep()' in '\n'.join(lines):
        sys.exit('lua.ws already has the state machine')
    out = []
    for l in lines:
        if l.startswith(STATE_END):
            out += state.splitlines() + ['', '']
        out.append(l)
    ls = out

    at = [i for i, l in enumerate(ls) if DISP_END in l]
    if len(at) != 1:
        sys.exit('%r matched %d lines' % (DISP_END, len(at)))
    at = at[0] - 1
    if ls[at].strip() != '} else {':
        sys.exit('the line above %r is %r, not the generic-call else'
                 % (DISP_END, ls[at].strip()))
    ls[at:at] = disp.splitlines()[:-1]
    txt = '\n'.join(ls) + '\n'

    txt = sub1(txt, 'const NB = 13', 'const NB = 14', 'const NB')
    txt = sub1(txt, '  gDeclare("unpack")',
               '  gDeclare("unpack")\n  gDeclare("_fmt")', 'gDeclare(unpack)')
    txt = sub1(txt, 'next, _s, _m, unpack) as', 'next, _s, _m, unpack, _fmt) as',
               'the builtin list in the GTAG_INIT comment')
    txt = sub1(txt, 'var nxPc: int = 0', 'var nxPc: int = 0\nvar nxMode: int = 0\n'
               '// one micro-step per burst: vmBurst calls vmStep four times, so this\n'
               '// state machine is inlined four times and entered up to four times in\n'
               '// one tick, and each inlined copy reads the state the earlier copies\n'
               '// wrote in an order the graph does not define.  vmBurst raises this\n'
               '// and the first copy consumes it.\nvar fmtGo: bool = false',
               'var nxPc')
    txt = sub1(txt, NXSTEP, NXSTEP_NEW, 'the nxActive branch of vmStep')
    txt = sub1(txt, 'mod vmBurst() {\n  vmStep()',
               'mod vmBurst() {\n  fmtGo = true\n  vmStep()', 'vmBurst')
    txt = sub1(txt, NEXTS, NEXTS_NEW, "the next() dispatch")
    txt = sub1(txt, 'const LIB_str_case = ',
               'const LIB_str_fmt = "string = string or {}\\nstring.format = _fmt\\n"\n'
               'const LIB_str_case = ', 'const LIB_str_case')
    txt = sub1(txt, 'mod libStrMisc(p: string) -> string {',
               'mod libStrFmt(p: string) -> string {\n'
               '  return if srcUses(p, "string.format") || srcUsesField(p, "format")\n'
               '      then LIB_str_fmt else ""\n'
               '}\n\n'
               'mod libStrMisc(p: string) -> string {', 'mod libStrMisc')
    txt = sub1(txt, '  let libM = libTabSort(program)',
               '  let libM = libTabSort(program)\n  let libN = libStrFmt(program)',
               'let libM')
    txt = sub1(txt, '    .. libH .. libI .. libJ .. libK .. libL .. libM',
               '    .. libH .. libI .. libJ .. libK .. libL .. libM .. libN',
               'the library concat')
    for name, arr, before, value in (
            ('GTAG_INIT', 'int', '6, 6', '4'),
            ('GNUM_INIT', 'float', '0.0, 0.0', '13.0')):
        m = re.search(r'var %s: %s\[\] = \[([^\]]*)\]' % (name, arr), txt)
        vals = [v.strip() for v in m.group(1).split(',')]
        trail = len(before.split(','))
        if [v.strip() for v in before.split(',')] != vals[-trail:]:
            sys.exit('%s does not end in %s -- add %s by hand'
                     % (name, before, value))
        vals.insert(len(vals) - trail, value)
        txt = txt[:m.start(1)] + ', '.join(vals) + txt[m.end(1):]
    open(WS, 'w', encoding='utf-8', newline='').write(txt)

    s = open(SPEC, encoding='utf-8').read()
    s = sub1(s, '("_s", 10), ("_m", 11), ("unpack", 12))',
             '("_s", 10), ("_m", 11), ("unpack", 12),\n'
             '             ("_fmt", 13))', 'spec BUILTINS')
    s = sub1(s, '"_m", "unpack", "inInt0", "outInt0"]',
             '"_m", "unpack", "_fmt", "inInt0", "outInt0"]', 'spec GSLOT_ORDER')
    open(SPEC, 'w', encoding='utf-8', newline='').write(s)
    print('installed _fmt into lua.ws (%d + %d lines) and tests/spec.py'
          % (len(state.splitlines()), len(disp.splitlines())))


if '--extract' in sys.argv:
    extract()
elif '--install' in sys.argv:
    install()
else:
    sys.exit(check())
