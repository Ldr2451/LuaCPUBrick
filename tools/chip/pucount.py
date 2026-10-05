"""Count PUC-suite assertions by harvest verdict, without running the chip.

pucsuite.py's full run is ~4 minutes because every harvested expression runs on
the chip.  The HARVEST (which lines qualify) and the self_contained filter are
pure text and take seconds.  This answers "how many are we ignoring, and why"
from the same code that decides it, so the numbers cannot drift from the tool.

  python -u tools/chip/pucount.py [--dir path]
"""
import collections
import glob
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import pucsuite as P  # noqa: E402


def main(argv):
    d = None
    for i, a in enumerate(argv):
        if a == "--dir" and i + 1 < len(argv):
            d = argv[i + 1]
    d = d or os.path.join(tempfile_dir(), "opencode", "lua-5.5.1-tests")
    files = sorted(glob.glob(os.path.join(d, "*.lua")))
    if not files:
        print("no .lua files in %s" % d)
        return 1
    total_asserts = 0
    kept = 0
    lifted = 0
    reasons = collections.Counter()
    per_file = collections.Counter()
    for path in files:
        try:
            text = open(path, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        # the same prelude the harvester builds, so these numbers cannot drift
        # from the ones the run reports
        pre, bound = P.file_prelude(text)
        for line in text.splitlines():
            s = line.strip()
            if not s.startswith("assert(") or not s.endswith(")"):
                continue
            expr = s[len("assert("):-1].strip()
            if not expr:
                continue
            total_asserts += 1
            ok, why = P.self_contained(expr)
            if ok:
                kept += 1
                per_file[os.path.basename(path)] += 1
                continue
            m = re.match(r"closes over '(\w+)'$", why)
            if pre and m and m.group(1) in bound \
                    and len(pre) + len(expr) <= P.PRELUDE_MAX:
                lifted += 1
                per_file[os.path.basename(path)] += 1
                continue
            reasons[why] += 1
    print("%d single-line assert() in %d files" % (total_asserts, len(files)))
    print("harvested (runnable on chip): %d" % kept)
    print("  +%d more through a file-local prelude, which tests the EXPRESSION "
          "under a\n  substituted binding rather than PUC's context -- weaker "
          "than the %d above" % (lifted, kept))
    print("not harvested:")
    for why, n in reasons.most_common():
        print("  %-28s %4d" % (why, n))
    print("harvested per file (top 10):")
    for f, n in per_file.most_common(10):
        print("  %-22s %4d" % (f, n))
    # Of the keyword skips, how many are banned ONLY for and/or/not (operators
    # the chip runs) rather than for statements (function/for/if/...)?  Those
    # are harvestable with no chip change, by narrowing BANNED to statements.
    stmt = re.compile(r"\b(function|local|return|for|while|repeat|until|do|"
                      r"then|else|elseif|end|::|goto|in|if)\b")
    andor = re.compile(r"\b(and|or|not)\b")
    only_op = 0
    op_examples = []
    for path in files:
        try:
            text = open(path, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        for line in text.splitlines():
            s = line.strip()
            if not s.startswith("assert(") or not s.endswith(")"):
                continue
            expr = s[len("assert("):-1].strip()
            if not expr or len(expr) > 400 or "..." in expr or "->" in expr \
                    or ";" in expr:
                continue
            bare = P.strip_strings(expr)
            if not P.BANNED.search(bare):
                continue
            if andor.search(bare) and not stmt.search(bare):
                # still needs the globals check to pass to be harvestable
                ok = True
                for m in P.IDENT.finditer(bare):
                    st = m.start()
                    if st and bare[st - 1] in ".:’":
                        continue
                    if m.group(0) not in P.GLOBALS and m.group(0) not in (
                            "and", "or", "not", "true", "false", "nil"):
                        ok = False
                        break
                if ok:
                    only_op += 1
                    if len(op_examples) < 5:
                        op_examples.append(
                            "%s: %s" % (os.path.basename(path), expr[:90]))
    print("keyword skips banned only for and/or/not (else harvestable): %d"
          % only_op)
    for e in op_examples:
        print("  e.g. %s" % e)
    return 0


def tempfile_dir():
    import tempfile
    return tempfile.gettempdir()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
