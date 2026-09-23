"""Turn a Lua library piece into the WireScript const that carries it.

The standard library is Lua source prepended to the program, so each piece lives
in lua.ws as a string constant.  Writing that by hand means hand-escaping every
quote, backslash and newline, which is exactly the kind of silent mistake a
linter cannot see -- a missed escape turns the piece into different Lua.

  python -u tools/libconst.py piece.lua LIB_name [-o out.txt]
  python -u tools/libconst.py piece.lua LIB_name --install

prints the const line ready to paste, or writes it to a file.  --install instead
replaces the `const LIB_name` line in lua.ws (or adds one after the last LIB_
const), which is how a piece actually lands: a hand-pasted 10k-character escape
is exactly the kind of mistake nothing can see.  The piece must be plain Lua: run
it under the oracle (with an _s/_m shim) to settle its behavior first.
"""
import os
import sys

if len(sys.argv) < 3:
    sys.exit(__doc__)

path, name = sys.argv[1], sys.argv[2]
if '--remove' in sys.argv:
    src = ''
else:
    src = open(path, encoding='utf-8').read()
if src.startswith('--'):
    # keep the leading comment block out of the const: the piece is data, and a
    # comment there only costs lexer time on every program that pulls it in
    lines = src.splitlines(True)
    i = 0
    while i < len(lines) and lines[i].startswith('--'):
        i += 1
    src = ''.join(lines[i:])

esc = (src.replace('\\', '\\\\')
          .replace('"', '\\"')
          .replace('\n', '\\n')
          .replace('\r', '\\r')
          .replace('\t', '\\t'))

line = 'const %s = "%s"' % (name, esc)
if '--install' in sys.argv or '--remove' in sys.argv:
    ws_path = os.path.join(os.path.dirname(os.path.dirname(
        os.path.abspath(__file__))), 'lua.ws')
    with open(ws_path, encoding='utf-8', newline='') as f:
        ws = f.read()
    lines = ws.split('\n')
    hit = [i for i, l in enumerate(lines) if l.startswith('const %s = ' % name)]
    if '--remove' in sys.argv:
        if not hit:
            sys.exit('no const %s in lua.ws' % name)
        del lines[hit[0]]
        with open(ws_path, 'w', encoding='utf-8', newline='') as f:
            f.write('\n'.join(lines))
        print('removed %s from lua.ws' % name)
    elif hit:
        lines[hit[0]] = line
    else:
        last = max(i for i, l in enumerate(lines) if l.startswith('const LIB_'))
        lines.insert(last + 1, line)
    if '--remove' not in sys.argv:
        with open(ws_path, 'w', encoding='utf-8', newline='') as f:
            f.write('\n'.join(lines))
        print('installed %s into %s (%s)' % (
            name, os.path.basename(ws_path),
            'replaced line %d' % (hit[0] + 1) if hit else 'new line %d' % (last + 2)))
elif '-o' in sys.argv:
    with open(sys.argv[sys.argv.index('-o') + 1], 'w', encoding='utf-8',
              newline='\n') as f:
        f.write(line + '\n')
else:
    print(line)
print('// %s: %d source lines, %d escaped chars' % (
    name, len(src.splitlines()), len(esc)), file=sys.stderr)
