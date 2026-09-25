// The numeric-loop depth rule, as the chip implements it.
//
// forDepth counts live numeric loops in ONE counter, shared by every frame: a
// callee's loops stack on top of the caller's, so the 16-loop FORPREP limit is a
// budget for the whole call stack rather than per function.  A frame saves the
// count when it is pushed (fForDepth) and restores it on the way out, so a
// return, an error unwinding through a pcall, and a protected call that catches
// one all put the caller's loops back.  A break pops exactly the loop it leaves
// (opcode 50, FOREND) instead of falling off the end of the body.
//
// Before the fix none of the exits popped anything: a break, a return out of a
// loop and an error unwinding through a pcall each left the count high, and the
// next loop in the program then read the wrong control register or refused to
// run.  The suite had 552 green cases over it -- the bug is only visible as
// *later* state, which is why it is worth a model rather than a diff.
//
// This proves the RULE, not the chip: the chip's own constants, its gates and
// the host's float laws are not in here.  See tools/vmmodel.py.
//
// A model that cannot fail is not a net.  Removing the pop from breakLoop (the
// old chip, which had no FOREND) gives a two-step counterexample -- enter, break
// -- leaving depth 1 with no loop, and `python -u tools/vmmodel.py
// <path-to-that-copy>` reports it.
module LoopDepth {
  // The chip's MAX_FOR.  Traces are bounded by --max-steps instead, so the
  // reachable depth stays small whichever bound is used.
  pure val MAX_FOR: int = 16
  // Two frames deep: enough for a call inside a loop, which is where the count
  // used to leak, without making the state space the point of the exercise.
  pure val MAX_FRAMES: int = 2

  var depth: int
  // The depth each live loop was entered at, innermost last.
  var loopBases: List[int]
  // The frame that entered each live loop, innermost last.  Without it a callee
  // can pop a loop its CALLER entered -- the count is shared, so "the innermost
  // loop" is not the same as "a loop of mine".  The chip cannot do this: a
  // callee's FORPREP pushes above the caller's depth, so the only loop it can
  // reach is its own.  savedDepths.length() is the current frame number.
  var loopOwners: List[int]
  // fForDepth: one entry per frame, whether a real frame or a pcall marker.
  var savedDepths: List[int]
  var savedMarkers: List[bool]

  action init = all {
    depth' = 0,
    loopBases' = [],
    loopOwners' = [],
    savedDepths' = [],
    savedMarkers' = [],
  }

  // FORPREP: a trip that runs pushes a loop.  The count is shared, so a callee's
  // loop lands above the caller's rather than on top of it.
  action enterLoop = all {
    depth < MAX_FOR,
    depth' = depth + 1,
    loopBases' = loopBases.append(depth),
    loopOwners' = loopOwners.append(savedDepths.length()),
    savedDepths' = savedDepths,
    savedMarkers' = savedMarkers,
  }

  // FORLOOP with the iteration count spent: only a loop this frame entered.
  action normalExit = all {
    loopBases.length() > 0,
    loopOwners[loopOwners.length() - 1] == savedDepths.length(),
    depth == loopBases[loopBases.length() - 1] + 1,
    depth' = depth - 1,
    loopBases' = loopBases.slice(0, loopBases.length() - 1),
    loopOwners' = loopOwners.slice(0, loopOwners.length() - 1),
    savedDepths' = savedDepths,
    savedMarkers' = savedMarkers,
  }

  // FOREND: a break leaves the innermost loop and only that one, again only if
  // this frame entered it.
  action breakLoop = all {
    loopBases.length() > 0,
    loopOwners[loopOwners.length() - 1] == savedDepths.length(),
    depth > loopBases[loopBases.length() - 1],
    depth' = loopBases[loopBases.length() - 1],
    loopBases' = loopBases.slice(0, loopBases.length() - 1),
    loopOwners' = loopOwners.slice(0, loopOwners.length() - 1),
    savedDepths' = savedDepths,
    savedMarkers' = savedMarkers,
  }

  // A call pushes a frame that saves the count.  The callee keeps it: loops are
  // per stack, not per function.
  action callFrame = all {
    savedDepths.length() < MAX_FRAMES,
    depth' = depth,
    loopBases' = loopBases,
    loopOwners' = loopOwners,
    savedDepths' = savedDepths.append(depth),
    savedMarkers' = savedMarkers.append(false),
  }

  // pcall and xpcall push the same kind of frame and mark it, so the unwind
  // knows where to stop.
  action pcallFrame = all {
    savedDepths.length() < MAX_FRAMES,
    depth' = depth,
    loopBases' = loopBases,
    loopOwners' = loopOwners,
    savedDepths' = savedDepths.append(depth),
    savedMarkers' = savedMarkers.append(true),
  }

  // RETURN: the saved count comes back.  A return from inside a loop leaves that
  // loop's entry above the saved depth, so the restore drops it -- which is the
  // whole point of the saved count, and the same thing a caught error does when
  // the unwind reaches the pcall's own marker.
  action returnFrame = all {
    savedDepths.length() > 0,
    depth' = savedDepths[savedDepths.length() - 1],
    loopBases' = loopBases.slice(0, savedDepths[savedDepths.length() - 1]),
    loopOwners' = loopOwners.slice(0, savedDepths[savedDepths.length() - 1]),
    savedDepths' = savedDepths.slice(0, savedDepths.length() - 1),
    savedMarkers' = savedMarkers.slice(0, savedMarkers.length() - 1),
  }

  // A tick that changes nothing, so the checker can look at a state more than
  // once rather than only at the moments something moved.
  action stutter = all {
    depth' = depth,
    loopBases' = loopBases,
    loopOwners' = loopOwners,
    savedDepths' = savedDepths,
    savedMarkers' = savedMarkers,
  }

  action step = any {
    enterLoop,
    normalExit,
    breakLoop,
    callFrame,
    pcallFrame,
    returnFrame,
    stutter,
  }

  // The invariant the bug broke: the count is exactly the number of live loops.
  val loopBalance = depth == loopBases.length()
  // And it never leaves the range the chip keeps it in.
  val depthBound = depth >= 0 and depth <= MAX_FOR
  // Every frame that saved a count also recorded whether it was a marker, and
  // every live loop has an owner to match its base.
  val frameBalance = savedDepths.length() == savedMarkers.length()
  val ownerBalance = loopBases.length() == loopOwners.length()
}
