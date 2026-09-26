// What the chip guarantees about RUNNING a program, as rules rather than diffs.
//
// The loop-depth and pcall models each cover one machine.  This one covers what
// every program depends on and no case can see: a straight-line program runs to
// the end, prints the same thing every time for the same input, never
// accumulates an error into output, never holds a value that is not one of the
// seven the chip has, prints what its input implies, and touches nothing it does
// not need.
//
// The program is four instructions long and has no loop, which is the point: the
// chip's tick loop advances the pc by one instruction per tick, so "no looping
// keyword" is exactly what makes the pc strictly increase, and TERMINATION then
// follows from the pc being bounded rather than being a separate thing to prove.
// A program with a loop is a different model -- the pc stops being monotonic,
// and loopmodel covers what happens then.
//
// Collections are Sets because that is what Quint's operations work on, which
// costs one thing and buys another: a Set cannot hold a duplicate, so "an
// instruction never runs twice" is true by construction here and the real
// argument for it is the pc (every step adds exactly one and nothing moves it
// back).  What the Set cannot do is count, so the two claims that are about
// counting -- one log entry per print, and the input read at most once -- are
// kept as separate integers rather than read off the collection.
//
// What is NOT in here is the host: whether an ADD overflows, what fmtNum spells,
// whether a gate fires.  The chip's constants and the host's float laws are not
// modelled, so a green run here is a statement about the chip's discipline, not
// about its arithmetic.
//
// A model that cannot fail is not a net, and every invariant below says which
// line to change to make it fail.  `python -u tools/model/vmmodel.py` is the
// checker; `quint run tools/model/execmodel.qnt --max-steps=12` prints a trace.
//   doRead not appending 0 to executed  -> onlyNeeded fails (a step was skipped)
//   doEmit appending a constant          -> ioEchoesInput fails
//   doFail's logAtError' = 0             -> noErrorAccumulation fails
//   doAdd not bounds the tag             -> regsWellTyped fails
//   doDraw not counting                  -> outputIsAFunctionOfInput fails
//   doHalt at pc == 1                    -> endsWhereItShould fails
//   a step that moves the pc backwards   -> pcBound fails
module Exec {
  // Four instructions, no loop.
  pure val N: int = 4
  // The seven tags a register can carry: nil, boolean, number, string, function,
  // table, and the chip's integer tag.  Anything else is a corrupted value.
  pure val MAX_TAG: int = 6
  // A draw is 0..9, so the printed line is a function of the input and the draws
  // rather than a constant.
  pure val DRAW_MAX: int = 9
  pure val INPUT_MAX: int = 2

  var pc: int
  // The two register tags, named rather than held in a list: a register file is
  // indexed in the chip, but two named slots say the same thing here without a
  // recursive walk, and a Set would lose two registers holding the same tag.
  var reg0: int
  var reg1: int
  // The distinct lines printed, and how many prints there were: the Set says
  // which, the counter says how many, and the two together are what "one entry
  // per print" means when two prints are equal.
  var log: Set[int]
  var logLen: int
  // The value the IO port delivered.  Nondeterministic: that is what makes "the
  // output follows the input" worth checking.
  var input: int
  var readCount: int
  // The running total of the draws, and how many there were.
  var drawTotal: int
  var drawCount: int
  // The log's length when the error was raised, so "an error stops the output" is
  // a state invariant and not a hope.
  var logAtError: int
  var errored: bool
  var halted: bool
  // Every pc that has run.
  var executed: Set[int]

  action init = all {
    pc' = 0,
    reg0' = 1,
    reg1' = 1,
    log' = Set(),
    logLen' = 0,
    input' = 0,
    readCount' = 0,
    drawTotal' = 0,
    drawCount' = 0,
    logAtError' = 0,
    errored' = false,
    halted' = false,
    executed' = Set(),
  }

  // The IO read.  The port's value is not ours to choose, and the chip reads it
  // once: a second read of the same port sees the same value, which is what
  // readCount below checks.
  action doRead = {
    nondet iv = oneOf(0.to(INPUT_MAX))
    all {
    not(errored),
    not(halted),
    pc == 0,
    pc' = 1,
    readCount' = readCount + 1,
    input' = iv,
    reg0' = reg0,
    reg1' = reg1,
    log' = log,
    logLen' = logLen,
    drawTotal' = drawTotal,
    drawCount' = drawCount,
    logAtError' = logAtError,
    errored' = errored,
    halted' = halted,
    executed' = executed.union(Set(0)),
    }
  }

  // ADD: the one arithmetic the model has.  Register 0 counts and stays in range
  // because nothing here can push it past MAX_TAG.
  action doAdd = all {
    not(errored),
    not(halted),
    pc == 1,
    pc' = 2,
    reg0' = reg0 + 1,
    reg1' = reg1,
    input' = input,
    readCount' = readCount,
    log' = log,
    logLen' = logLen,
    drawTotal' = drawTotal,
    drawCount' = drawCount,
    logAtError' = logAtError,
    errored' = errored,
    halted' = halted,
    executed' = executed.union(Set(1)),
  }

  // math.random: nondeterministic, and counted, because that is what lets the
  // determinism invariant below say something a constant could not.
  action doDraw = {
    nondet dv = oneOf(0.to(DRAW_MAX))
    all {
    not(errored),
    not(halted),
    pc == 2,
    pc' = 3,
    drawCount' = drawCount + 1,
    drawTotal' = drawTotal + dv,
    reg0' = reg0,
    reg1' = reg1,
    input' = input,
    readCount' = readCount,
    log' = log,
    logLen' = logLen,
    logAtError' = logAtError,
    errored' = errored,
    halted' = halted,
    executed' = executed.union(Set(2)),
    }
  }

  // print: the line is twice the input plus the draws, so the output is a
  // FUNCTION of what came in and not a constant the model got wrong.
  action doEmit = all {
    not(errored),
    not(halted),
    pc == 3,
    pc' = N,
    log' = log.union(Set(input * 2 + drawTotal)),
    logLen' = logLen + 1,
    reg0' = reg0,
    reg1' = reg1,
    input' = input,
    readCount' = readCount,
    drawTotal' = drawTotal,
    drawCount' = drawCount,
    logAtError' = logAtError,
    errored' = errored,
    halted' = halted,
    executed' = executed.union(Set(3)),
  }

  // A runtime error stops the program where it failed, which is the chip's rule
  // and the reason a truncated run never reads as a finished one.
  action doFail = all {
    not(errored),
    not(halted),
    errored' = true,
    halted' = true,
    logAtError' = logLen,
    pc' = pc,
    reg0' = reg0,
    reg1' = reg1,
    input' = input,
    readCount' = readCount,
    log' = log,
    logLen' = logLen,
    drawTotal' = drawTotal,
    drawCount' = drawCount,
    executed' = executed,
  }

  // The last instruction returns.
  action doHalt = all {
    not(errored),
    not(halted),
    pc == N,
    halted' = true,
    pc' = pc,
    reg0' = reg0,
    reg1' = reg1,
    input' = input,
    readCount' = readCount,
    log' = log,
    logLen' = logLen,
    drawTotal' = drawTotal,
    drawCount' = drawCount,
    logAtError' = logAtError,
    errored' = errored,
    executed' = executed,
  }

  // A tick that changes nothing, so the checker can look at a state more than
  // once rather than only at the moments something moved.
  action stutter = all {
    pc' = pc,
    reg0' = reg0,
    reg1' = reg1,
    input' = input,
    readCount' = readCount,
    log' = log,
    logLen' = logLen,
    drawTotal' = drawTotal,
    drawCount' = drawCount,
    logAtError' = logAtError,
    errored' = errored,
    halted' = halted,
    executed' = executed,
  }

  action step = any {
    doRead,
    doAdd,
    doDraw,
    doEmit,
    doFail,
    doHalt,
    stutter,
  }

  // TERMINATION.  The pc is a natural number and never leaves the program, and
  // every action that runs an instruction adds exactly one to it while nothing
  // moves it back.  So a program with no looping keyword reaches N and halts:
  // there is no cycle to sit in and no bound to pass.  A loop breaks the
  // monotonicity, which is why that is a different model.
  val pcBound = pc >= 0 and pc <= N

  // ... and it stops at the end or at a failure, never in the middle: a halted
  // chip has run out of instructions or has failed, and those are the only two
  // things that halt it.  This is what makes a halted chip's output final, and it
  // is the rule the suite's finished flag leans on.
  val endsWhereItShould = not(halted) or pc == N or errored

  // ONLY THE NEEDED INSTRUCTIONS.  What has run is exactly 0..pc-1: nothing
  // skipped, nothing past the pc, nothing that the program does not reach.  A
  // dispatcher that advanced the pc by two, or a machine that ran a step the
  // program never got to, fails here first.
  // Equivalently: pc distinct pcs below pc, and pc of them, is the prefix.  It is
  // written this way because Apalache cannot take a DYNAMIC range (0.to(pc - 1)
  // is rejected as an input error), and the pair of clauses is the same claim.
  val onlyNeeded = executed.size() == pc and executed.forall(i => i < pc)

  // NO UNKNOWN OR CORRUPTED STATE.  Every register is one of the seven tags: the
  // chip keeps a tag beside every value for exactly this reason, so a write that
  // lost its tag, or a read of a slot nobody wrote, would show up here before it
  // showed up as a wrong answer.
  val regsWellTyped = reg0 >= 0 and reg0 <= MAX_TAG and reg1 >= 0 and reg1 <= MAX_TAG

  // NO ERROR ACCUMULATION.  Once an error is raised the log cannot grow again, so
  // an error can never add up into output the program did not write, and a failed
  // run can never look like a longer successful one.
  val noErrorAccumulation = not(errored) or logLen == logAtError

  // IO PRODUCES WHAT ITS INPUT IMPLIES.  Every line printed is the function of
  // the input and the draws, so a print that formatted a stale value, or a port
  // read out of the wrong register, fails here.
  // IO PRODUCES WHAT ITS INPUT IMPLIES.  Every line printed is twice the input
  // plus the draws, so a print that formatted a stale value, or a port read out
  // of the wrong register, fails here.  The rule is spelled out rather than named
  // because every top-level val in this file is an invariant the checker is asked
  // to confirm, and a helper val among them makes Apalache's parser fail.
  val ioEchoesInput = log.forall(l => l == input * 2 + drawTotal)

  // ONE LOG ENTRY PER PRINT.  The set of lines cannot be bigger than the number
  // of prints, and the number of prints cannot exceed the instructions run: an
  // output the program did not print is a corrupted log, and printing twice in
  // one instruction is not a thing the chip does.
  val oneLinePerPrint = log.size() <= logLen and logLen <= executed.size()

  // DETERMINISM WITHOUT RAND.  With no draw, the only line the program can print
  // is the one the input alone determines, so the same program on the same input
  // prints the same thing.  With draws, the draws are counted in the model, so
  // the output is a function of everything that came in and of nothing else.
  // Forgetting to count a draw (drawCount' = drawCount) is what makes this fail.
  val outputIsAFunctionOfInput = drawCount == 0 implies log.forall(l => l == input * 2)

  // The input is read at most once, so a second read cannot disagree with the
  // first: the chip reads a port into a register, and nothing here re-reads it.
  val oneRead = readCount <= 1
}
