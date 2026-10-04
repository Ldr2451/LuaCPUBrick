"""Regenerate locFind's backwards ladder, and the guard that has to agree with it.

locFind is a hand-unrolled chain, one local per arm, and its DEPTH decides how
many live locals a name reference can see.  Too shallow is the only dangerous
direction, because a miss is indistinguishable from a real global reference: a
local the ladder never reached resolves as a global and the program answers
wrong with no error on either channel.  That is not hypothetical -- 31 declared
locals compiled `return r0` to LOADGLOBAL and answered nil where PUC answers 0.

So the ladder and the guard must be changed together, which is why they are
generated here rather than edited by hand: a hand-edited arm count silently
desynchronises the two, and the guard then refuses programs it could have
compiled (or, worse, stops refusing ones it cannot).

  python -u tools/chip/ladder.py            # report the current depth
  python -u tools/chip/ladder.py 64         # set it, and move the guard with it
  python -u tools/chip/ladder.py --check    # verify they agree, build nothing

A depth of MAX_REGS means one whole frame of locals, which is the most a single
function can declare.  Reaching across frames can still exceed it, and that case
is refused rather than guessed.
"""
import io
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
WS = os.path.join(ROOT, "lua.ws")

ARM = ("  if !lkDone && 0 <= ix && locName[ix] == name {\n"
       "    lkIx = ix\n"
       "    lkDone = true\n"
       "  }\n"
       "  ix = ix - 1\n")

GUARD = """// The ladder below checks the {n} most recent live locals, so a MISS is only
  // proof that the name is a global when it saw all of them.  With more than
  // {n} live it does not: a local the ladder never reached resolves as a global
  // and the program answers wrong with no error anywhere.
  //
  // So the shortfall is refused rather than compiled.  The alternative is to
  // treat an unreached local as a global, which is the bug; and the check has to
  // live here, before any name is resolved, because every later caller reads
  // lkKind and cannot tell a proven global from an unchecked one.
  //
  // {n} is one whole frame of locals, the most a single function can declare.
  // Reaching across frames can still exceed it, and that case is refused rather
  // than guessed.  tools/chip/ladder.py keeps this number and the arm count in
  // step, because a hand-edited one silently desynchronises them.
  if {n} < locLen {{
    perr = true
    perrMsg = "too many locals in scope (max {n})"
  }}
"""


# The region to replace is everything between the end of locFind's prologue and
# the local-vs-capture decision.
#
# It USED to be anchored below the self-recursion block (the one that made
# `lkKind == 2`, a GETCLO of the running frame).  That block is gone: `local
# function f` declares its name in the ENCLOSING scope and reaches itself through
# an ordinary upvalue, so nothing sets lkKind to 2 any more and the whole
# mechanism -- selfName, selfClean, selfFid, lkFid, dirtySelf and the GETCLO arm --
# was dead code.  The anchor is the prologue's last line instead, which is stable
# and has no body to protect.
#
# The warning below still stands, and it is the reason the anchor is checked
# rather than trusted: an earlier version of this anchored on the self-name
# block's OPENING brace and began inside it, deleting its body -- and `--check`
# still reported OK, because it counts arms and guards and never looks at the
# code around them.
HEAD = "  lkIx = -1\n"
# nothing between the anchor and the ladder
HEAD_BODY = ""
TAIL = "  if lkDone && lkKind == 0 {\n"


def bounds(src):
    """(start, end) of the ladder region: after the self-name block's close,
    up to the local-vs-capture decision."""
    open_at = src.index(HEAD)
    if not src.startswith(HEAD_BODY, open_at + len(HEAD)):
        raise SystemExit("ladder.py: the self-name block's body is not what this "
                         "tool expects -- refusing to write.  Find it by hand; it "
                         "is not part of the ladder.")
    start = open_at + len(HEAD) + len(HEAD_BODY)
    end = src.index(TAIL, start)
    return start, end


def read():
    return io.open(WS, encoding="utf-8", newline="").read()


def current(src):
    """(arm count, guard threshold) as they are on disk right now."""
    start, end = bounds(src)
    ladder = src[start:end]
    arms = ladder.count("locName[ix] == name")
    thresholds = re.findall(r"if (\d+) < locLen \{", ladder)
    guard = int(thresholds[-1]) if thresholds else None
    if len(thresholds) > 1:
        raise SystemExit("ladder.py: %d guards present (%s) -- refusing to "
                         "report a depth that is not the one that fires"
                         % (len(thresholds), ", ".join(thresholds)))
    return arms, guard


def verify(src, arms, depth):
    """The ladder is N identical arms over descending indices, and each arm is
    exactly five lines.  Anything else means the region is not the ladder."""
    start, end = bounds(src)
    region = src[start:end]
    # start AFTER the `var ix` line: it opens the ladder but is not an arm
    opener = "  var ix = locLen - 1\n"
    body = region[region.index(opener) + len(opener):]
    want = ARM * arms
    if body != want:
        raise SystemExit("ladder.py: the %d arms are not the expected %d "
                         "five-line interleave -- found %d arm lines in %d.  Not "
                         "rewriting." % (depth, arms, body.count("locName[ix]"),
                                         len(body.splitlines())))
    if body.count("ix = ix - 1\n") != arms:
        raise SystemExit("ladder.py: %d arms but %d decrements -- the ladder "
                         "would skip or double an index."
                         % (arms, body.count("ix = ix - 1\n")))


def main(argv):
    src = read()
    try:
        arms, guard = current(src)
        if arms:
            verify(src, arms, arms)
    except SystemExit as e:
        print(e)
        return 2
    if not argv or argv[0] == "--check":
        ok = "OK" if arms == guard else "DESYNCHRONISED"
        print("locFind: %d arms, guard at %s -- %s"
              % (arms, "none" if guard is None else guard, ok))
        return 0 if arms == guard else 1
    depth = int(argv[0])
    start, end = bounds(src)
    body = GUARD.format(n=depth) + "  var ix = locLen - 1\n" + ARM * depth
    out = src[:start] + body + src[end:]
    # verify the RESULT, not the intent: the rewrite that ate a block body was
    # correct as written and only wrong on disk
    try:
        verify(out, depth, depth)
    except SystemExit as e:
        print(e)
        return 2
    io.open(WS, "w", encoding="utf-8", newline="").write(out)
    print("locFind ladder set to %d arms, guard at %d" % (depth, depth))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))