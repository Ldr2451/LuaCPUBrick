"""Which mod calls each of these?  Parse-path or runtime is the question.

A chip boundary costs no tick from a runtime call site but exactly one boot tick
if the chip is on the PARSE path (measured: five parse-path chips together cost
+1, not +5, and +1 on a 14-character program as on an 88-character one).  So
before converting a batch, every name in it has to be classified -- and reading
it off the source is how two parser helpers (`funcDepthInit`, `saveTmp`, both
called from funcHead/funcHeadAnon) ended up in a batch labelled "runtime".

  python -u tools/chip/whocalls.py name1 name2 ...
  python -u tools/chip/whocalls.py --runtime vSetIntSat patSetBegin
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))

# The parse/lex driver, and the micro-step and builtin machinery.  Anything a
# name is called only from inside these is parse-path or runtime respectively;
# a name called from both is in neither bucket cleanly, and the tool says so
# rather than guessing.
PARSE = ("parseChunk", "parseStep", "parseExpr", "parseStmt", "lexChunk",
         "lexStep", "funcHead", "funcHeadAnon", "stmtDispatch", "stmtNameList",
         "resolveKw", "binArrive", "andOrArrive", "emitTok", "startUnit",
         "pushOp", "pushCtl", "popCtl", "locFind", "locBind", "locDeclare",
         "patchAt", "bPatch", "bumpMax", "cNum", "blkEnter", "blkExit",
         "doBlockClose", "closeAction", "regFree", "regSync", "expandTailCall")


def owners(lines):
    out, cur = [], "<top level>"
    for l in lines:
        m = re.match(r"(?:mod|chip) (\w+)\(", l)
        if m:
            cur = m.group(1)
        elif re.match(r"on \w+", l):
            cur = "on " + l.split()[1]
        out.append(cur)
    return out


def main():
    argv = sys.argv[1:]
    runtime_only = "--runtime" in argv
    names = [a for a in argv if not a.startswith("--")]
    lines = open(os.path.join(ROOT, "lua.ws"), encoding="utf-8").read().split("\n")
    own = owners(lines)

    for name in names:
        tally = {}
        for i, l in enumerate(lines):
            if re.match(r"(?:mod|chip) %s\(" % re.escape(name), l):
                continue
            if re.search(r"(?<![\w.])%s\(" % re.escape(name),
                         l.split("//")[0]):
                tally[own[i]] = tally.get(own[i], 0) + 1
        where = "runtime" if not (set(tally) & set(PARSE)) else "PARSE"
        if runtime_only and where != "runtime":
            continue
        print("%-16s %-8s <- %s" % (name, where, tally))
    return 0


if __name__ == "__main__":
    sys.exit(main())