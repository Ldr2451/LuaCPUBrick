// The run/parse/start handshake: can a program print twice for one start?
//
// The bug reported from in game: run low, edit the program, run high, and
// SOMETIMES the log shows the new line twice.  Two prints with no log clear
// between them, so whatever caused it rewound the program counter WITHOUT going
// through vmReset - because vmReset clears the log as well as the pc.  That is
// the shape this model asks about, and it is why no tick sweep found it: the
// interleaving that does it is narrow, and sampling the ticks walks past it.
//
// The rules encoded here are the chip's, read off lua.ws:
//   Change(program)  wantParse = true; emit sched
//   sched            if !jobBusy { if wantParse { wantParse = false;
//                    jobBusy = true; emit goParse } }
//   parse completes  progOk = true; jobBusy = false; vmReset(); vmClosures()
//   Change(run) up   if run && progOk && !jobBusy { vmReset() }
//   a tick           if run && progOk && !jobBusy && !vmHalted { one instruction }
//   vmReset          log := ""; pc := 0; vmHalted := false
//
// The environment is deliberately UNDISCIPLINED: it may write `run` and
// `program` at any time, as often as it likes, and may write the same value
// again.  Whether a host fires a Change on an unchanged value is a host question
// the sim answers one way, so the model does not rely on it.
//
// A model that cannot fail is not a net: `parseStep` without the vmReset is the
// old shape, and prints is unbounded under it.
module LifecycleHandshake {
  var runLevel: bool
  // loadedProg is which text the parse pipeline holds: 1 = the original,
  // 2 = the edit.  progOk says a parse COMPLETED, so it describes loadedProg.
  var loadedProg: int
  var progOk: bool
  var jobBusy: bool
  var wantParse: bool
  var vmHalted: bool
  // prints counts executions of the CURRENTLY LOADED program since the last
  // vmReset.  vmReset zeroes it, which is the whole reason a double print needs
  // a pc rewind that skips vmReset.
  var prints: int
  // The host may write each port at most twice, which is enough to express the
  // reported sequence (low, edit, high) and one redundant write.
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
    runWrites' = 0,
    progWrites' = 0,
    gridReads' = 0,
  }

  // ---- host actions

  // The program port is written with new text: Change(program) requests a parse.
  // Writing the SAME text again still fires the handler, because only the host
  // knows whether it suppressed an unchanged write.
  action hostWriteProgram = all {
    gridReads' = gridReads,    runWrites' = runWrites,
    progWrites' = progWrites,    progWrites < 4,
    wantParse' = true,
    runLevel' = runLevel,
    loadedProg' = 2,
    progOk' = progOk,
    jobBusy' = jobBusy,
    vmHalted' = vmHalted,
    prints' = prints,
  }

  // The run port is written; the level applied is chosen nondeterministically, so
  // a redundant write of the same level is in the state space.
  action hostWriteRun = all {
    gridReads' = gridReads,    progWrites' = progWrites,    runWrites < 5,
    runWrites' = runWrites + 1,
    runLevel' = true,
    loadedProg' = loadedProg,
    progOk' = progOk,
    jobBusy' = jobBusy,
    wantParse' = wantParse,
    vmHalted' = vmHalted,
    prints' = prints,
  }

  action hostLowerRun = all {
    gridReads' = gridReads,    progWrites' = progWrites,    runWrites < 5,
    runWrites' = runWrites + 1,
    runLevel' = false,
    loadedProg' = loadedProg,
    progOk' = progOk,
    jobBusy' = jobBusy,
    wantParse' = wantParse,
    vmHalted' = vmHalted,
    prints' = prints,
  }

  // ---- chip actions

  // on sched with a parse already in flight: the request is NOT consumed.  This
  // is the chip's real rule and the reason a program edit can be lost - kept as
  // its own action rather than a conditional, because Quint's `if` is an action.
  action schedBusy = all {
    gridReads' = gridReads,    runWrites' = runWrites,
    progWrites' = progWrites,    jobBusy,
    jobBusy' = jobBusy,
    wantParse' = wantParse,
    runLevel' = runLevel,
    loadedProg' = loadedProg,
    progOk' = progOk,
    vmHalted' = vmHalted,
    prints' = prints,
  }

  // on sched with an idle parser: the request is consumed and the parse starts.
  action schedGo = all {
    gridReads' = gridReads,    runWrites' = runWrites,
    progWrites' = progWrites,    not(jobBusy),
    wantParse,
    jobBusy' = true,
    wantParse' = false,
    runLevel' = runLevel,
    loadedProg' = loadedProg,
    progOk' = progOk,
    vmHalted' = vmHalted,
    prints' = prints,
  }

  // on sched with nothing pending: nothing happens.
  action schedIdle = all {
    gridReads' = gridReads,    runWrites' = runWrites,
    progWrites' = progWrites,    not(jobBusy),
    not(wantParse),
    jobBusy' = jobBusy,
    wantParse' = wantParse,
    runLevel' = runLevel,
    loadedProg' = loadedProg,
    progOk' = progOk,
    vmHalted' = vmHalted,
    prints' = prints,
  }

  // The parse finishes: this is the ONLY place the loaded program becomes the
  // running one, and it carries a full vmReset.
  action parseStep = all {
    gridReads' = gridReads,    runWrites' = runWrites,
    progWrites' = progWrites,    jobBusy,
    jobBusy' = false,
    progOk' = true,
    vmHalted' = false,
    prints' = 0,
    runLevel' = runLevel,
    loadedProg' = loadedProg,
    wantParse' = wantParse,
  }

  // Change(run) on a rising edge: guarded, and a full vmReset when it fires.
  action runEdge = all {
    gridReads' = gridReads,    runWrites' = runWrites,
    progWrites' = progWrites,    runLevel,
    progOk,
    not(jobBusy),
    vmHalted' = false,
    prints' = 0,
    runLevel' = runLevel,
    loadedProg' = loadedProg,
    progOk' = progOk,
    jobBusy' = jobBusy,
    wantParse' = wantParse,
  }

  // A tick of work: the print instruction runs, then the program halts.
  action vmPrint = all {
    gridReads' = gridReads,    runWrites' = runWrites,
    progWrites' = progWrites,    runLevel,
    progOk,
    not(jobBusy),
    not(vmHalted),
    vmHalted' = true,
    prints' = prints + 1,
    runLevel' = runLevel,
    loadedProg' = loadedProg,
    progOk' = progOk,
    jobBusy' = jobBusy,
    wantParse' = wantParse,
  }

  action stutter = all {
    gridReads' = gridReads,    runWrites' = runWrites,
    progWrites' = progWrites,    runLevel' = runLevel,
    loadedProg' = loadedProg,
    progOk' = progOk,
    jobBusy' = jobBusy,
    wantParse' = wantParse,
    vmHalted' = vmHalted,
    prints' = prints,
  }

  // A grid read.  on ReadBrickGrid also sets wantParse and emits sched, so this
  // can start a parse at ANY point in the sequence - including while the program
  // is running, which is the case most likely to produce a second start.  Not
  // modelled until now, and the chip really does restart on grid reads.
  action gridRead = all {
    gridReads < 3,
    gridReads' = gridReads + 1,
    wantParse' = true,
    runLevel' = runLevel,
    loadedProg' = loadedProg,
    progOk' = progOk,
    jobBusy' = jobBusy,
    vmHalted' = vmHalted,
    prints' = prints,
    runWrites' = runWrites,
    progWrites' = progWrites,
  }

  // A scalar input changing.  Same guard and same full vmReset as the run edge,
  // but the host can do it with `run` already high and nothing else changing.
  action inputWrite = all {
    gridReads' = gridReads,    runLevel,
    progOk,
    not(jobBusy),
    vmHalted' = false,
    prints' = 0,
    runLevel' = runLevel,
    loadedProg' = loadedProg,
    progOk' = progOk,
    jobBusy' = jobBusy,
    wantParse' = wantParse,
    runWrites' = runWrites,
    progWrites' = progWrites,
  }

  action step = any {
    hostWriteProgram,
    hostWriteRun,
    hostLowerRun,
    schedBusy,
    schedGo,
    schedIdle,
    gridRead,
    inputWrite,
    parseStep,
    runEdge,
    vmPrint,
    stutter,
  }

  // THE PROPERTY.  One start runs the program once: the log can never come back
  // with the same line twice.  A violation is the reported bug.
  val noDoublePrint = prints <= 1

  // Sanity, so a violation cannot be an artefact of a nonsense state: a completed
  // parse always leaves nothing in flight, and the host never edits the program
  // without asking for a parse.
  val parseNotBusy = not(progOk) implies not(jobBusy) or wantParse
}
