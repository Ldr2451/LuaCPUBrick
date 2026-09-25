// The protected-call rule for a gate that answers through a micro-step.
//
// _fmt, _pat and _gmatch do not answer in the tick they are called: they start
// a machine that runs for several more ticks and writes the result at the end.
// pcall dispatches such a gate in place, so the question is WHEN the protected
// call is complete.  The chip answers it at the end of the work (nxDone), not
// when the call started, and an error caught by the unwind abandons the machine
// (pcallStep clears nxActive and the pcall latches).
//
// Both halves were wrong once.  Completing the call on the starting tick popped
// the marker and dropped pcallDepth to zero before the work ran, so the failure
// that work raised a tick later ended the program instead of answering
// false, message -- and the machine, still running, failed a second time with
// the pcall already gone.  Leaving the machine running through the unwind is the
// same bug from the other side.
//
// This proves the RULE, not the chip.  See tools/vmmodel.py.
//
// A model that cannot fail is not a net.  Dropping `machine' = "Idle"` from
// unwind (the old chip, which let the abandoned machine keep ticking) gives a
// three-step counterexample ending in pcallDepth 0 with the machine still
// "Protected" -- the state that failed a second time outside the pcall.
module PcallGate {
  // Idle: no machine.  Plain: a gate the program called directly.  Protected: a
  // machine a pcall dispatched in place, which nobody may complete until the
  // work is done.
  var machine: str
  var pcallDepth: int
  // pcallRan: the protected call is waiting for that machine's results.
  var pcallRan: bool
  // pcallUnwind: a caught error is on its way out.
  var pcallUnwind: bool
  // A gate is running and has raised; the message is the error's value now.
  var raised: bool

  action init = all {
    machine' = "Idle",
    pcallDepth' = 0,
    pcallRan' = false,
    pcallUnwind' = false,
    raised' = false,
  }

  // pcall of a gate: the marker goes down, the machine starts, and the call is
  // not finished yet.
  action startProtected = all {
    machine == "Idle",
    pcallDepth == 0,
    machine' = "Protected",
    pcallDepth' = 1,
    pcallRan' = true,
    pcallUnwind' = pcallUnwind,
    raised' = raised,
  }

  // pcall of a gate the program called directly: no marker, no protection, and
  // the machine owns the tick it runs in.
  action startPlain = all {
    machine == "Idle",
    pcallDepth == 0,
    machine' = "Plain",
    pcallDepth' = 0,
    pcallRan' = false,
    pcallUnwind' = pcallUnwind,
    raised' = raised,
  }

  // One tick of a running machine, either kind.
  action machineStep = all {
    machine != "Idle",
    machine' = machine,
    pcallDepth' = pcallDepth,
    pcallRan' = pcallRan,
    pcallUnwind' = pcallUnwind,
    raised' = raised,
  }

  // nxDone with results: the protected call is completed HERE, where the work
  // actually finished, and the marker comes off.
  action protectedOk = all {
    machine == "Protected",
    pcallRan,
    machine' = "Idle",
    pcallDepth' = pcallDepth - 1,
    pcallRan' = false,
    pcallUnwind' = false,
    raised' = false,
  }

  action plainOk = all {
    machine == "Plain",
    machine' = "Idle",
    pcallDepth' = pcallDepth,
    pcallRan' = pcallRan,
    pcallUnwind' = pcallUnwind,
    raised' = false,
  }

  // vmFail inside the machine: with a marker up, the error is a value.
  action protectedFail = all {
    machine == "Protected",
    pcallRan,
    machine' = machine,
    pcallDepth' = pcallDepth,
    pcallRan' = pcallRan,
    pcallUnwind' = true,
    raised' = true,
  }

  // pcallStep: the unwind abandons whatever raised, pops the marker, and
  // answers false, message.  The machine is Idle afterwards -- this is the line
  // the old chip did not have, and without it machineStep keeps a machine
  // running with pcallDepth at 0 and it fails again outside the pcall.
  action unwind = all {
    pcallUnwind,
    pcallDepth > 0,
    machine' = "Idle",
    pcallDepth' = pcallDepth - 1,
    pcallRan' = false,
    pcallUnwind' = false,
    raised' = false,
  }

  // vmFail with no marker up ends the program; nothing to model past it.
  action plainFail = all {
    machine == "Plain",
    pcallDepth == 0,
    machine' = "Idle",
    pcallDepth' = pcallDepth,
    pcallRan' = pcallRan,
    pcallUnwind' = false,
    raised' = true,
  }

  // The program carries on, and calls again later.
  action stutter = all {
    machine' = machine,
    pcallDepth' = pcallDepth,
    pcallRan' = pcallRan,
    pcallUnwind' = pcallUnwind,
    raised' = raised,
  }

  action step = any {
    startProtected,
    startPlain,
    machineStep,
    protectedOk,
    plainOk,
    protectedFail,
    unwind,
    plainFail,
    stutter,
  }

  // Nobody is left waiting on a call that is over, or the other way round.
  val pcallMatchesMachine =
    (pcallRan implies machine == "Protected") and
    (machine == "Protected" implies pcallRan)
  // A protected call is only ever open while its machine is the one running.
  val noUnprotectedGate = pcallDepth == 0 or machine != "Plain"
  // The unwind never outlives the marker it is unwinding to.
  val unwindHasMarker = pcallUnwind implies pcallDepth > 0
  // A machine is not left running once the call that started it is gone.
  val noOrphanMachine = pcallRan implies pcallDepth > 0
}
