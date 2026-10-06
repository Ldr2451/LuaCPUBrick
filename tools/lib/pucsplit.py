"""PUC-Lua 5.5's own C/Lua split, next to what the chip does with each name.

The repo's rule (AGENTS.md, "PUC's own split decides where a library function
belongs") is only checkable against PUC's SOURCE, so this reads the registration
tables out of the oracle's own tree rather than guessing: every entry in a
`static const luaL_Reg ...[]` is a C function, and a function PUC writes in Lua
would not be in one.  A `#if defined(LUA_COMPAT_MATHLIB)` block is a DEFAULT-OFF
build, so its names are reported as compat and count as "PUC does not have it".

  python -u tools/lib/pucsplit.py                 # the audit table
  python -u tools/lib/pucsplit.py --extras        # only the chip names PUC lacks
  python -u tools/lib/pucsplit.py --src <dir>     # a PUC-5.5 tree with src/*.c

Where the tree comes from: PUC_LUA_SRC, then %TEMP%\\opencode\\puclua, then the
path this tool printed when it was missing.  It is the ORACLE's source, so keep
it: `https://www.lua.org/ftp/lua-5.5.1.tar.gz` (the oracle is 5.5.x; the split
has not moved since 5.3, but the compat block has).
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
WS = os.path.join(ROOT, "lua.ws")

LIBS = ("lbaselib.c", "lstrlib.c", "ltablib.c", "lmathlib.c")
# the table each file's names land in: the base library registers globals, the
# rest register fields of their own table, so PUC's "abs" is math.abs
TABLE = {"lbaselib.c": "", "lstrlib.c": "string.", "ltablib.c": "table.",
         "lmathlib.c": "math."}
# the chip's own host ports: the game drives the chip through these, so they are
# not "PUC does not have it" candidates -- they are the point of the chip
HOST_IO = ("clock", "program", "run",
           "inNum0", "inNum1", "inNum2", "inNum3", "inStr0", "inStr1",
           "inNumArr", "inStrArr", "innumarr", "instrarr",
           "outNumArr", "outStrArr", "outnumarr", "outstrarr",
           "outnum", "outstr",
           "outNum0", "outNum1", "outNum2", "outNum3",
           "outStr0", "outStr1", "last")


def find_src():
    for cand in (os.environ.get("PUC_LUA_SRC"),
                 os.path.join(os.environ.get("TEMP", ""), "opencode", "puclua")):
        if cand and os.path.isfile(os.path.join(cand, "lbaselib.c")):
            return cand
    return None


def puc_names(src):
    """name -> ('C' | 'compat') for every registered library function.

    Read from the ARRAY, not the definitions, and track the #if around the
    entries: in lmathlib.c the compat *definitions* sit above the array, so
    cutting the file at the marker would call the whole of math "compat".
    """
    out = {}
    for lib in LIBS:
        path = os.path.join(src, lib)
        if not os.path.isfile(path):
            continue
        text = open(path, encoding="utf-8", errors="replace").read()
        # EVERY array, not the first: lmathlib.c registers math.random through
        # randfuncs and the rest through mathlib, and lstrlib.c has the string
        # metatable's methods as well as the library.
        for m in re.finditer(r'static const luaL_Reg\s+\w+\[\]\s*=\s*\{', text):
            i = m.end() - 1
            depth, compat = 1, False
            while i < len(text) and depth:
                line_end = text.find("\n", i)
                line = text[i:line_end if line_end > 0 else len(text)]
                depth += line.count("{") - line.count("}")
                if "#if" in line and "COMPAT" in line:
                    compat = True
                if "#endif" in line:
                    compat = False
                for ent in re.finditer(r'\{\s*"([\w.]+)"\s*,\s*(\w+)\s*\}', line):
                    name, fn = ent.group(1), ent.group(2)
                    if fn == "NULL":
                        continue      # a placeholder, filled in separately
                    out.setdefault(TABLE[lib] + name,
                                   "compat" if compat else "C")
                i = line_end + 1 if line_end > 0 else len(text)
    return out


def chip_names():
    """name -> ('gate' | 'alias' | 'piece') for every stdlib name the chip has.

    A gate is a declared builtin (`gDeclare("x")`).  A PIECE can be either a
    real implementation (string.rep, table.sort -- the whole function is Lua) or
    an ALIAS whose body just calls a `_`-prefixed primitive (math.floor is
    `return _m(1, x, 0)`, string.gmatch is `= _gmatch`), and the difference is
    the repo's own rule: the split is about the PRIMITIVE, so an alias over a
    gate is a gate with a Lua spelling, while a real piece is a gate-saving
    departure that has to earn it.
    """
    src = open(WS, encoding="utf-8").read()
    gates = set(re.findall(r'gDeclare\("([\w.]+)"\)', src))
    kinds = {}
    for const in re.findall(r'^const LIB_\w+ = "(.*)"$', src, re.M):
        body = const.replace('\\n', '\n').replace('\\"', '"')
        for m in re.finditer(r'^\s*([\w.]+)\.([\w.]+)\s*=\s*(.+)$', body, re.M):
            name, rhs = "%s.%s" % (m.group(1), m.group(2)), m.group(3)
            prim = bool(re.match(r'^\s*_\w+', rhs)) or "_" in rhs.split("\n")[0][:40] \
                and "return" in rhs
            kinds[name] = "alias" if prim else "piece"
        for m in re.finditer(r'^\s*function\s+([\w.]+)\s*\(([^)]*)\)', body, re.M):
            kinds.setdefault(m.group(1), "piece")
        for m in re.finditer(r'^\s*([\w.]+)\s*=\s*(_?\w+)\s*$', body, re.M):
            kinds.setdefault(m.group(1), "alias")
    return gates, kinds


def main(argv):
    src = None
    if "--src" in argv:
        src = argv[argv.index("--src") + 1]
    else:
        src = find_src()
    if not src:
        print("no PUC-Lua 5.5 source found.  The split is only checkable against")
        print("the oracle's own tree; get it with:")
        print("  python -c \"import urllib.request;"
              "open('lua-5.5.1.tar.gz','wb').write("
              "urllib.request.urlopen("
              "'https://www.lua.org/ftp/lua-5.5.1.tar.gz').read())\"")
        print("then unpack it and pass --src <dir> (the dir holding lbaselib.c),")
        print("or set PUC_LUA_SRC.")
        return 1
    puc = puc_names(src)
    gates, kinds = chip_names()
    both = sorted(n for n in puc if kinds.get(n) == "piece")
    alias = sorted(n for n in puc if kinds.get(n) == "alias")
    print("PUC 5.5 registers %d library names from %s: %d C, %d compat-only"
          % (len(puc), src, sum(1 for v in puc.values() if v == "C"),
             sum(1 for v in puc.values() if v == "compat")))
    print("the chip installs %d gates, %d piece aliases over them and %d names"
          " with the whole function in Lua"
          % (len(gates), len(alias), len(both)))
    print()
    print("-- PUC has NO Lua-implemented library function (every name above is C"
          " or compat),")
    print("   so the split's Lua branch is empty and there is no gate that"
          " ought to be a piece.")
    print("-- the chip implements these in Lua, so they are the departures from"
          " the C rule,")
    print("   each one kept because it earns it on nodes (the rule's own"
          " test):")
    for n in both:
        print("   piece  %s" % n)
    print()
    print("-- aliases: the primitive is a gate, the piece is only its Lua"
          " spelling:")
    print("   %s" % ", ".join(alias))
    print()
    print("-- chip names PUC 5.5 does NOT register (removal candidates):")
    extras = []
    for n in sorted(gates | set(kinds)):
        if n in puc or n.startswith("_") or n in HOST_IO:
            continue
        if n in ("math", "string", "table", "io"):
            continue
        extras.append(n)
    for n in extras:
        print("   %s" % n)
    print()
    compat = sorted(n for n, k in puc.items() if k == "compat")
    print("-- PUC compat-only (off in a default build, so the chip's copy of one"
          " is also an extra): %s"
          % (", ".join(compat) if compat else "none"))
    if "--extras" in argv:
        return 0
    print()
    print("-- PUC names the chip does not implement at all:")
    missing = sorted(n for n in puc if puc[n] == "C" and n not in gates
                     and n not in kinds)
    print("   %s" % (", ".join(missing) if missing else "none"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
