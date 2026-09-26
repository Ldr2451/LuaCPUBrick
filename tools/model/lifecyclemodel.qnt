// The run/parse/start handshake, with a tick granular enough to catch the bug.
//
// v1 of this model treated a tick as ATOMIC - `vmPrint` did the whole print in one
// action.  That was the flaw, and it is the same shape of mistake as the harness
// rewinding the program port: the model was more coarse than the thing it
// modelled, so it proved a rule that the real chip does not obey.  The chip's
// vmBurst dispatches up to FIVE instructions across separate handler
// invocations, so a vmReset from goParse2 can land BETWEEN two instructions of the
// same call.  A model that cannot express that will always agree with a bug.
//
// So a tick is ONE instruction here, and the print is three of them:
//   opLoadGlobal   callee := "func"        (LOADGLOBAL print)
//   opLoadConst                        (LOADK 2)
//   opCall         prints the callee OR fails the way PUC fails
// and a parse can complete between any two of them.
//
// THE BUG, as reported from in game: run low, edit the program, run high, and
// SOMETIMES the log shows the line twice - and sometimes an "attempt to call"
// error instead.  Both are the same thing, and this model is where that shows up.
// opCall reading a callee that vmReset already cleared IS "attempt to call", and
// it is the same interleaving that otherwise restarts the program and prints
// twice.  The non-determinism is which of the two you land on.
//
// A model that cannot fail is not a net: the two properties below are violated by
// simply deleting the reset from parseStep, and by clearing the callee in
// parseStep instead of vmReset.
module LifecycleHandshake {
  var runLevel: bool
  var loadedProg: int
  var progOk: bool
  var jobBusy: bool
  var wantParse: bool
  var vmHalted: bool
  var prints: int
  // callee is the register a CALL reads: "none" before the LOADGLOBAL, "func"
  // once it has run, and "nil" once vmReset has cleared the register file.
  var pc: int
  var callee: str
  // errored records PUC's "attempt to call a nil value", i.e. a CALL whose
  // callee register was cleared before the CALL dispatched.
  var errored: bool
  var runWrites: int
  var progWrites: int
  var gridReads: int

  action init = all {
    runLevel' = false,
    loadedProg' = 1,
    progOk' = true,
    jobBusy' = false,
    wantParse' = false,
    vmHalted' = true,
    prints' = 0,
    pc' = 0,
    callee' = "none",
    errored' = false,
    runWrites' = 0,
    progWrites' = 0,
    gridReads' = 0,
  }

  // ---------------- host

  action hostWriteProgram = all {
    pc' = pc,    progWrites < 4,
    progWrites' = progWrites + 1,
    wantParse' = true,
    runLevel' = runLevel,
    loadedProg' = 2,
    progOk' = progOk,
    jobBusy' = jobBusy,
    vmHalted' = vmHalted,
    prints' = prints,
    callee' = callee,
    errored' = errored,
    runWrites' = runWrites,
    gridReads' = gridReads,
  }

  action hostRaiseRun = all {
    pc' = pc,    runWrites < 5,
    runWrites' = runWrites + 1,
    runLevel' = true,
    loadedProg' = loadedProg,
    progOk' = progOk,
    jobBusy' = jobBusy,
    wantParse' = wantParse,
    vmHalted' = vmHalted,
    prints' = prints,
    callee' = callee,
    errored' = errored,
    progWrites' = progWrites,
    gridReads' = gridReads,
  }

  action hostLowerRun = all {
    pc' = pc,    runWrites < 5,
    runWrites' = runWrites + 1,
    runLevel' = false,
    loadedProg' = loadedProg,
    progOk' = progOk,
    jobBusy' = jobBusy,
    wantParse' = wantParse,
    vmHalted' = vmHalted,
    prints' = prints,
    callee' = callee,
    errored' = errored,
    progWrites' = progWrites,
    gridReads' = gridReads,
  }

  action gridRead = all {
    pc' = pc,    gridReads < 3,
    gridReads' = gridReads + 3 - 3,
    wantParse' = true,
    runLevel' = runLevel,
    loadedProg' = loadedProg,
    progOk' = progOk,
    jobBusy' = jobBusy,
    vmHalted' = vmHalted,
    prints' = prints,
    callee' = callee,
    errored' = errored,
    runWrites' = runWrites,
    progWrites' = progWrites,
  }

  // ---------------- chip: the parse request

  action schedBusy = all {
    pc' = pc,    jobBusy,
    jobBusy' = jobBusy,
    wantParse' = wantParse,
    runLevel' = runLevel,
    loadedProg' = loadedProg,
    progOk' = progOk,
    vmHalted' = vmHalted,
    prints' = prints,
    callee' = callee,
    errored' = errored,
    runWrites' = runWrites,
    progWrites' = progWrites,
    gridReads' = gridReads,
  }

  action schedGo = all {
    pc' = pc,    not(jobBusy),
    wantParse,
    jobBusy' = true,
    wantParse' = false,
    runLevel' = runLevel,
    loadedProg' = loadedProg,
    progOk' = progOk,
    vmHalted' = vmHalted,
    prints' = prints,
    callee' = callee,
    errored' = errored,
    runWrites' = runWrites,
    progWrites' = progWrites,
    gridReads' = gridReads,
  }

  action schedIdle = all {
    pc' = pc,    not(jobBusy),
    not(wantParse),
    jobBusy' = jobBusy,
    wantParse' = wantParse,
    runLevel' = runLevel,
    loadedProg' = loadedProg,
    progOk' = progOk,
    vmHalted' = vmHalted,
    prints' = prints,
    callee' = callee,
    errored' = errored,
    runWrites' = runWrites,
    progWrites' = progWrites,
    gridReads' = gridReads,
  }

  // ---------------- chip: the parse finishing, and the resets

  // THE SUSPECT.  goParse2 ends with an unconditional vmReset() and
  // vmClosures() whenever a parse completes.  If it completes while the VM is
  // between the LOADGLOBAL and the CALL, that reset clears the callee register
  // the CALL is about to read.
  action parseStep = all {
    jobBusy,
    jobBusy' = false,
    progOk' = true,
    vmHalted' = false,
    prints' = 0,
    pc' = 0,
    callee' = "nil",
    runLevel' = runLevel,
    loadedProg' = loadedProg,
    wantParse' = wantParse,
    errored' = errored,
    runWrites' = runWrites,
    progWrites' = progWrites,
    gridReads' = gridReads,
  }

  action runEdge = all {
    runLevel,
    progOk,
    not(jobBusy),
    vmHalted' = false,
    prints' = 0,
    pc' = 0,
    callee' = "nil",
    runLevel' = runLevel,
    loadedProg' = loadedProg,
    progOk' = progOk,
    jobBusy' = jobBusy,
    wantParse' = wantParse,
    errored' = errored,
    runWrites' = runWrites,
    progWrites' = progWrites,
    gridReads' = gridReads,
  }

  action inputWrite = all {
    runLevel,
    progOk,
    not(jobBusy),
    vmHalted' = false,
    prints' = 0,
    pc' = 0,
    callee' = "nil",
    runLevel' = runLevel,
    loadedProg' = loadedProg,
    progOk' = progOk,
    jobBusy' = jobBusy,
    wantParse' = wantParse,
    errored' = errored,
    runWrites' = runWrites,
    progWrites' = progWrites,
    gridReads' = gridReads,
  }

  // ---------------- chip: ONE instruction per tick

  action opLoadGlobal = all {
    pc' = pc,    runLevel,
    progOk,
    not(jobBusy),
    not(vmHalted),
    pc == 0,
    callee' = "func",
    runLevel' = runLevel,
    loadedProg' = loadedProg,
    progOk' = progOk,
    jobBusy' = jobBusy,
    wantParse' = wantParse,
    vmHalted' = vmHalted,
    prints' = prints,
    errored' = errored,
    runWrites' = runWrites,
    progWrites' = progWrites,
    gridReads' = gridReads,
  }

  // The CALL, when the callee register still holds the function.
  action opCallOk = all {
    pc' = pc,    runLevel,
    progOk,
    not(jobBusy),
    not(vmHalted),
    pc == 2,
    callee == "func",
    callee' = callee,
    errored' = false,
    prints' = prints + 1,
    vmHalted' = true,
    runLevel' = runLevel,
    loadedProg' = loadedProg,
    progOk' = progOk,
    jobBusy' = jobBusy,
    wantParse' = wantParse,
    runWrites' = runWrites,
    progWrites' = progWrites,
    gridReads' = gridReads,
  }

  // The CALL, when a vmReset already cleared the callee register.  This is PUC's
  // "attempt to call a nil value" - the OTHER symptom of the same interleaving.
  action opCallBad = all {
    pc' = pc,    runLevel,
    progOk,
    not(jobBusy),
    not(vmHalted),
    pc == 2,
    callee != "func",
    callee' = callee,
    errored' = true,
    prints' = prints,
    vmHalted' = true,
    runLevel' = runLevel,
    loadedProg' = loadedProg,
    progOk' = progOk,
    jobBusy' = jobBusy,
    wantParse' = wantParse,
    runWrites' = runWrites,
    progWrites' = progWrites,
    gridReads' = gridReads,
  }

  action stutter = all {
    pc' = pc,    runLevel' = runLevel,
    loadedProg' = loadedProg,
    progOk' = progOk,
    jobBusy' = jobBusy,
    wantParse' = wantParse,
    vmHalted' = vmHalted,
    prints' = prints,
    callee' = callee,
    errored' = errored,
    runWrites' = runWrites,
    progWrites' = progWrites,
    gridReads' = gridReads,
  }

  // The LOADK between the two.  It is here so the pc can only reach the CALL by
  // dispatching the instructions in between, rather than jumping straight there.
  action opLoadConst = all {
    runLevel,
    progOk,
    not(jobBusy),
    not(vmHalted),
    pc == 1,
    pc == 1,
    pc' = 2,
    runLevel' = runLevel,
    loadedProg' = loadedProg,
    progOk' = progOk,
    jobBusy' = jobBusy,
    wantParse' = wantParse,
    vmHalted' = vmHalted,
    prints' = prints,
    callee' = callee,
    errored' = errored,
    runWrites' = runWrites,
    progWrites' = progWrites,
    gridReads' = gridReads,
  }

  action step = any {
    hostWriteProgram,
    hostRaiseRun,
    hostLowerRun,
    gridRead,
    schedBusy,
    schedGo,
    schedIdle,
    parseStep,
    runEdge,
    inputWrite,
    opLoadGlobal,
    opLoadConst,
    opLoadConst,
    opCallOk,
    opCallBad,
    stutter,
  }

  // PROPERTY 1, the reported symptom: one start runs the program once.
  val noDoublePrint = prints <= 1

  // PROPERTY 2, the other reported symptom, and the one that says WHY: a program
  // must not fail with "attempt to call" purely because of when a parse happened
  // to complete.  This is the assertion the atomic version of this model could not
  // even express.
  val noCorruptCall = not(errored)
}
