"""Turn a Lua library piece into the WireScript const that carries it.

The standard library is Lua source prepended to the program, so each piece lives
in lua.ws as a string constant.  Writing that by hand means hand-escaping every
quote, backslash and newline, which is exactly the kind of silent mistake a
linter cannot see -- a missed escape turns the piece into different Lua.

  python -u tools/lib/libconst.py piece.lua LIB_name [-o out.txt]
  python -u tools/lib/libconst.py piece.lua LIB_name --install

prints the const line ready to paste, or writes it to a file.  --install instead
replaces the `const LIB_name` line in lua.ws (or adds one after the last LIB_
const), which is how a piece actually lands: a hand-pasted 10k-character escape
is exactly the kind of mistake nothing can see.  The piece must be plain Lua: run
it under the oracle (with an _s/_m shim) to settle its behavior first.

The const is *minified*, and that is not cosmetic: every character a piece does
not carry is a tick of boot every program that names that library function waits
for, before it has run one instruction.  The master in lib/ stays readable and
the const is what ships.  Two steps, in order:

  1. comments, indentation and blank lines go.  A line inside a long bracket
     string is left exactly as it is, because there it is data.
  2. the chunk's own locals are renamed to single letters (renamelib.py): only
     names DECLARED in the piece, never a field, a method, a global or an
     `_`-prefixed name (those are shared across pieces, which are minified
     separately).  One mapping per chunk, so shadowing is preserved exactly.

Step 2 refuses rather than guesses.  A use before its declaration, a
`local x = ...x...`, a `for i = <uses i>`, a use that resolves to the global --
each stops the install with the reason, because the alternative is a piece that
means something else, and a piece that means something else usually still parses.
The proof is the suite, not this tool: renaming cannot change behaviour, and
nametest.py proves only that the refusals bite.
"""
import os
import sys

from renamelib import rename_names


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


def master_to_const(src):
    """Drop the leading comment block: the piece is data, and a comment there
    only costs lexer time on every program that pulls it in."""
    if not src.startswith('--'):
        return src
    lines = src.splitlines(True)
    i = 0
    while i < len(lines) and lines[i].startswith('--'):
        i += 1
    return ''.join(lines[i:])


def const_text(src):
    """(minified+renamed source, escaped text, chars saved) for one master.

    The escaped length is the number that matters: it is what the chip's
    source buffer carries, and so what every program naming this library
    function waits to lex.  Raises ValueError when the rename is not provably
    safe, with the reason.
    """
    src = minify(master_to_const(src)) if src else src
    renamed = 0
    if src:
        before = len(src)
        src = rename_names(src)
        renamed = before - len(src)
    esc = (src.replace('\\', '\\\\')
              .replace('"', '\\"')
              .replace('\n', '\\n')
              .replace('\r', '\\r')
              .replace('\t', '\\t'))
    return src, esc, renamed


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    path, name = argv[0], argv[1]
    flags = argv[2:]
    if '--remove' in flags:
        src = esc = ''
        renamed = 0
    else:
        try:
            src, esc, renamed = const_text(
                open(path, encoding='utf-8').read())
        except ValueError as e:
            sys.exit('%s: refusing to install -- renaming would change what '
                     'the piece means, so fix the master instead: %s'
                     % (name, e))

    line = 'const %s = "%s"' % (name, esc)
    if '--install' in flags or '--remove' in flags:
        ws_path = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(
            os.path.abspath(__file__)))), 'lua.ws')
        with open(ws_path, encoding='utf-8', newline='') as f:
            ws = f.read()
        lines = ws.split('\n')
        hit = [i for i, l in enumerate(lines)
               if l.startswith('const %s = ' % name)]
        if '--remove' in flags:
            if not hit:
                sys.exit('no const %s in lua.ws' % name)
            del lines[hit[0]]
            with open(ws_path, 'w', encoding='utf-8', newline='') as f:
                f.write('\n'.join(lines))
            print('removed %s from lua.ws' % name)
        elif hit:
            lines[hit[0]] = line
        else:
            last = max(i for i, l in enumerate(lines)
                       if l.startswith('const LIB_'))
            lines.insert(last + 1, line)
        if '--remove' not in flags:
            with open(ws_path, 'w', encoding='utf-8', newline='') as f:
                f.write('\n'.join(lines))
            print('installed %s into %s (%s)' % (
                name, os.path.basename(ws_path),
                'replaced line %d' % (hit[0] + 1) if hit
                else 'new line %d' % (last + 2)))
    elif '-o' in flags:
        with open(flags[flags.index('-o') + 1], 'w', encoding='utf-8',
                  newline='\n') as f:
            f.write(line + '\n')
    else:
        print(line)
    print('// %s: %d source lines, %d escaped chars (renaming saved %d)'
          % (name, len(src.splitlines()), len(esc), renamed), file=sys.stderr)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))