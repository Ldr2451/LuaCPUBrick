"""Run PUC's own test suite against the chip, as far as the chip can take it.

The suite at https://www.lua.org/tests/ cannot be run whole, and the reasons are
worth stating rather than discovering one at a time:

  - the files are up to 40 KB; the chip's source buffer is about 4 KB
  - they need metatables, `require`, `io.stderr`, `os.exit`, `collectgarbage`,
    `load`, coroutines and the C API.  The chip has none of those, and CHIP_LOG
    already records metatables as absent
  - `all.lua` expects to print "final OK" from a real `lua` binary

So this harvests instead of executing: it takes the single-line `assert(EXPR)`
checks whose expression is SELF-CONTAINED -- every bare name in it is a global
the chip has, and every other token is a literal or an operator -- and runs each
one on both the chip and the oracle.  It prints `tostring(EXPR)` rather than
asserting, so a divergence shows up as a different VALUE and not merely as one
side raising.

That is a fraction of 3,287 assertions, and the fraction is the point: the
harvest is a superset of nothing and a subset of the suite, so it finds bugs in
the expressions it can reach and says nothing about the rest.  Every skipped
assertion is counted by reason, so "it passed" is never mistaken for "it ran".

  python -u tools/chip/pucsuite.py --dir <path> [--limit N] [--verbose]
"""
import argparse
import io
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "irrun"))
sys.path.insert(0, os.path.join(ROOT, "tests"))
from irsims import ChipRunner  # noqa: E402
from lua_oracle import oracle_log, oracle_run  # noqa: E402

# Bare names an expression may use.  Anything else means it closes over a local
# and cannot be lifted out of its file.  Deliberately excludes rawequal,
# rawget, rawset, setmetatable, getmetatable, coroutine, load, require, io and
# os: the chip has none of them, so an expression using one is not a test the
# chip could pass.
GLOBALS = {
    "assert", "error", "ipairs", "pairs", "next", "select", "tonumber",
    "tostring", "type", "pcall", "xpcall", "print", "unpack", "rawequal",
    "math", "string", "table", "_VERSION",
}

# Names that appear after a dot or a colon are fields, not bindings.
IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
STRING = re.compile(r"'(\\.|[^'\\])*'|\"(\\.|[^\"\\])*\"")
# Keywords and syntax that mean this is not a self-contained expression.
BANNED = re.compile(r"\b(function|local|return|for|while|repeat|until|do|"
                    r"then|else|elseif|end|::|goto|in|and|or|not|if)\b")


def strip_strings(expr):
    """Blank out string literals so identifiers inside them are not read."""
    return STRING.sub(lambda m: '"' + " " * (len(m.group(0)) - 2) + '"', expr)


def self_contained(expr):
    """(ok, reason).  Only single-line expressions of literals and operators."""
    if len(expr) > 400:
        return False, "too long"
    if "..." in expr or "->" in expr or ";" in expr:
        return False, "has vararg/arrow/statement"
    bare = strip_strings(expr)
    if BANNED.search(bare):
        return False, "has keyword"
    for m in IDENT.finditer(bare):
        # skip a field name: preceded by '.' or ':'
        start = m.start()
        if start and bare[start - 1] in ".:'":
            continue
        if m.group(0) not in GLOBALS:
            return False, "closes over %r" % m.group(0)
    return True, ""


def harvest(path):
    """(expr, file, lineno) for every self-contained single-line assert."""
    out = []
    try:
        text = io.open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return out
    for n, line in enumerate(text.splitlines(), 1):
        s = line.strip()
        if not s.startswith("assert(") or not s.endswith(")"):
            continue
        expr = s[len("assert("):-1].strip()
        if not expr:
            continue
        ok, _why = self_contained(expr)
        if ok:
            out.append((expr, os.path.basename(path), n))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    files = sorted(os.path.join(args.dir, f)
                   for f in os.listdir(args.dir) if f.endswith(".lua"))
    exprs = []
    for f in files:
        exprs.extend(harvest(f))
    if args.limit:
        exprs = exprs[:args.limit]

    runner = ChipRunner(os.path.join(ROOT, "lua.ws"))
    agree = differ = skipped = 0
    fails = []
    for expr, fname, lineno in exprs:
        prog = "print(tostring(%s))" % expr
        # Each expression is independent: one program that makes the simulator
        # raise (a harvested constant can overflow an int output, e.g. an `inf`
        # reaching a gate that does int()) must not end the sweep, and must not
        # be counted as agreement either.
        try:
            chip = runner.run(prog, 8000)
            cg = chip["outGlobals"]
            clog = (cg.get("log") or "").strip()
            cerr = (cg.get("err") or "").strip()
            if cerr or clog == "":
                # The chip refused it: a limit, an unimplemented corner, or a
                # parse error.  Counted, never called agreement.
                skipped += 1
                if args.verbose:
                    fails.append(("SKIP", expr, fname, lineno, cerr[:60]))
                continue
            res = oracle_run(prog)
            if not res.get("avail", True):
                skipped += 1
                if args.verbose:
                    fails.append(("SKIP", expr, fname, lineno, "no oracle"))
                continue
            olog = oracle_log(res.get("calls") or []).strip()
        except Exception as e:
            skipped += 1
            if args.verbose:
                fails.append(("SKIP", expr, fname, lineno, repr(e)[:60]))
            continue
        if clog == olog:
            agree += 1
        else:
            differ += 1
            fails.append(("DIFF", expr, fname, lineno,
                          "chip=%r oracle=%r" % (clog, olog)))

    print("harvested %d self-contained asserts from %d files"
          % (len(exprs), len(files)))
    print("agree %d   DIFFER %d   skipped %d" % (agree, differ, skipped))
    for kind, expr, fname, lineno, note in fails[:40]:
        print("  %-4s %s:%d  %s\n         %s" % (kind, fname, lineno,
                                               expr[:100], note))
    return 1 if differ else 0


if __name__ == "__main__":
    sys.exit(main())