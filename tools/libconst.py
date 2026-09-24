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

The const is *minified*, and that is not cosmetic: the lexer runs at four
characters per tick, so every character a piece does not carry is a tick of boot
every program that names that library function waits for -- 3,109 characters is
777 ticks before the program has run one instruction.  The master in lib/ stays
readable and the const is what ships.  Conservative on purpose: comments,
indentation and blank lines go, and nothing else -- no renaming (a local name is
one the chunk cannot see, but a *field* or a global is not) and no joining of
lines, because both can change what a piece means.  A line inside a long
bracket string is left exactly as it is.
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


def split_comment(line):
    """(code, long-comment-rest): drop a trailing -- outside any string."""
    out = []
    quote = None
    i = 0
    while i < len(line):
        c = line[i]
        if quote:
            out.append(c)
            if c == '\\' and i + 1 < len(line):
                out.append(line[i + 1])
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
        if line[i:i + 2] == '--':
            if line[i:i + 4] == '--[[' or line[i:i + 4] == '--[=[':
                end = line.find(']]', i)
                return ''.join(out), (line[end + 2:] if end >= 0 else '')
            break
        out.append(c)
        i += 1
    return ''.join(out), None


def minify(text):
    keep = []
    in_long = False
    for raw in text.splitlines():
        if in_long:
            # inside [[...]]: whitespace is part of the string
            keep.append(raw)
            if ']]' in raw:
                in_long = False
            continue
        code, rest = split_comment(raw)
        if rest is not None:          # a whole-line long comment: drop it
            if '[[' in code and ']]' not in code:
                in_long = True
                keep.append(code)
            continue
        line = code.strip()
        if line:
            keep.append(line)
    return '\n'.join(keep) + ('\n' if keep else '')


src = minify(src) if src else src

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
