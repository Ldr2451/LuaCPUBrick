"""Prove the library-piece renamer: the refusals bite, and nothing else moves.

The renamer's failure mode is SILENT.  A piece that renames wrong usually still
parses -- it just means something else -- and a piece that stops parsing stops
every function in it from answering, with no message and no line.  So there are
two separate proofs and this file is only the first:

  1. here: every shape the resolver could get wrong is a named case, and each
     one says whether it must be renamed or must be refused.  A case that stops
     refusing is caught; a case that starts refusing over a legitimate shape is
     caught too, because `lib/` is run through the same check.
  2. the suite: reinstall every piece and run it, which is the only proof that
     the renamed text means the same thing.

  python -u tools/lib/nametest.py            # the cases + every master
  python -u tools/lib/nametest.py lib/x.lua  # renamed source, no install

Each case is (source, expectation).  "REFUSE" is a ValueError with a non-empty
message -- a refusal that cannot say why is not a guard.
"""
import glob
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from renamelib import rename_names                # noqa: E402

LIB = os.path.normpath(os.path.join(HERE, "..", "..", "lib"))

# The shapes the resolver has to get right, each with WHY it is in the list.
# `local x = ...x...` and `local a, b = b, a` are the same fact (the right side
# evaluates before the variable exists) reached two ways; the `local function`
# case is the scope bug that scoping by name token instead of by keyword caused;
# the field/concat cases are the `..`-is-two-dots bug.
CASES = [
    ("local x = x + 1", "REFUSE",
     "self-init: the right side is the OUTER x"),
    ("local a, b = b, a", "REFUSE",
     "both declarators are unbound through the whole initializer"),
    ("local f = function() return f end", "REFUSE",
     "f binds outside the body, so the body's f is the outer one"),
    ("for i = i, 10 do print(i) end", "REFUSE",
     "loop variable is not visible in its own bounds"),
    ("for a, b in next, s do print(a, b) end", "OK",
     "iterator list is not the bounds, and these bind fine"),
    ("local function h(v) return v + 1 end print(h(41))", "OK",
     "local function binds in the ENCLOSING scope"),
    ("local t = {} t.n = 1 return t", "OK",
     "no initializer self-reference: the `t.n` is the next statement"),
    ("local r = '' for i = 1, 3 do r = r .. i end return r", "OK",
     "concat operand is a use, and `..` must not read as a field"),
    ("local t = {n = 1} return t.n + t.n", "OK",
     "a `{key =}` field is not a variable"),
    ("local s = 'x' return string.upper(s) .. s:lower()", "OK",
     "fields and methods keep their names"),
    ("local _k = 1 return _k", "OK",
     "an _-prefixed name is shared across pieces, so it is never renamed"),
    ("local v = 1 return function() return v end", "OK",
     "upvalue capture resolves to the enclosing local"),
    ("return select('#', ...)", "OK",
     "no declarations at all"),
]

# Cases where the RESULT matters, not just OK/REFUSE: a name half-renamed is
# the worst failure there is, because the piece still compiles and means
# something else.  io_stderr.lua lost the first of these to the `{key =}`
# guard mistaking a `for` header inside a table constructor for a key.
#
# Stated as must/must-not rather than as literal text: the fresh letters depend
# on what else the chunk uses, so the property is the point, not the spelling.
RESULT_CASES = [
    # the `for` lives inside a constructor.  Its variable must rename in BOTH
    # places, or every use reads an undefined global.
    ('io.stderr = { write = function(self, ...)\n'
     'for i = 1, select("#", ...) do _wr(tostring((select(i, ...)))) end\n'
     'return self end }',
     ['for ', 'select('], ['for i =', 'select(i,']),
    # `local a, b = ...` in a constructor's function body: `b` sits after a
    # comma and before an `=`, which is exactly a constructor key's shape.
    ('t = { f = function() local a, b = 1, 2 return a + b end }',
     ['local ', 'return '], ['return a + b']),
    # a real constructor key whose name matches a local must NOT rename, while
    # the variable of the same name elsewhere must.
    ('local n = 1 return { n = 2, m = function() return n end }',
     ['n = 2'], ['local n = 1']),
]


def check_case(src, expect, why):
    try:
        out = rename_names(src)
    except ValueError as e:
        got = "REFUSE"
        detail = str(e)
    else:
        got = "OK"
        detail = out
    if got != expect:
        return "case %r: expected %s, got %s (%s) -- %s" % (
            src, expect, got, detail[:60], why)
    if got == "REFUSE" and not detail.strip():
        return "case %r: refused without saying why" % src
    return None


def check_result_case(src, must, must_not, why):
    """Every listed fragment must survive and every forbidden one must be gone.

    Half-renaming a name is the failure worth guarding: the piece still
    compiles, and every function in it silently means something else.
    """
    try:
        out = rename_names(src)
    except ValueError as e:
        return "expected a rename, refused: %s -- %s" % (e, why)
    for frag in must:
        if frag not in out:
            return "expected %r in the output, got %r -- %s" % (frag, out,
                                                               why)
    for frag in must_not:
        if frag in out:
            return "%r survived into %r -- %s" % (frag, out, why)
    return None


def main(argv):
    if argv:
        print(rename_names(open(argv[0], encoding="utf-8").read()))
        return 0

    fails = []
    for src, expect, why in CASES:
        err = check_case(src, expect, why)
        if err:
            fails.append(err)
        print("%-6s %-52s %s" % (expect, src[:52].replace("\n", " "), why))
    for src, must, must_not in RESULT_CASES:
        err = check_result_case(src, must, must_not, "result")
        if err:
            fails.append(err)
        print("%-6s %-52s keeps %s, drops %s"
              % ("TEXT", src[:52].replace("\n", " "), must, must_not))

    # every master must rename cleanly: a refusal over a legitimate shape is a
    # bug in the renamer, and finding it here is cheaper than in the suite
    masters = sorted(glob.glob(os.path.join(LIB, "*.lua")))
    for path in masters:
        name = os.path.basename(path)
        try:
            rename_names(open(path, encoding="utf-8").read())
        except ValueError as e:
            fails.append("%s: refused a master: %s" % (name, e))
        print("%-6s lib/%s" % ("OK", name))

    print()
    if fails:
        for f in fails:
            print("FAIL: %s" % f)
        print("%d case(s), %d failure(s)"
              % (len(CASES) + len(RESULT_CASES), len(fails)))
        return 1
    print("all %d cases and %d masters OK"
          % (len(CASES) + len(RESULT_CASES), len(masters)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))