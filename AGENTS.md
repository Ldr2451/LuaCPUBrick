# AGENTS.md — how to work in this repo

## Commands: plain and platform-independent
- Python, Lua and WireScript are all cross-platform, so **the repo is too**. No
  PowerShell in scripts or docs, no shell-specific incantations in commands.
  `python -u tests/test_chip_suite.py iter-` means the same thing everywhere.
- Do not reach for PowerShell (or any other shell) to do what a Python script
  does better. The shell tool here happens to be PowerShell, but that is not a
  reason to write PowerShell: it mangles quoting, has no heredocs, and none of
  it works on Linux. Put the logic in a script under `tools/`.
- Always run Python with `-u`. Buffered output is indistinguishable from a hang.
- Prefer a script's own `workdir`/path handling over `cd`, and use `os.path`
  inside scripts, never hard-coded separators or absolute machine paths.
- Anything external is discovered, not hard-coded: `tests/lua_oracle.py` finds
  the oracle (`$LUA55`, then PATH, then the usual install dirs) and
  `irrun/irdump.py` finds the compiler (`$WIRESCRIPT`, then a sibling checkout,
  then PATH).
- The chip's port types are `float`, `int`, `bool`, `string`, `vector`, `color`
  and `entity`, each with an array form (`float[]` ... `entity[]`), plus a
  port-only `any` that cannot be stored in a variable gate.  `object`,
  `reference`, `item`, `gameobject` and `player` are not types.  Read this off
  the compiler with `python -u tools/porttypes.py [type ...]` rather than
  guessing: it compiles a one-port net per candidate and says which are
  accepted.  **An object in WireScript is an `entity`.**
- Python is 3.12 (no JIT, GIL on) — CPU parallelism means **multiprocessing**.
- Changing the Python build (3.13 free-threading / `--enable-jit`, Cython) is not
  worth it here: the sim is a single-threaded interpreter-bound pointer chase,
  free-threading only helps threaded code, and the JIT would buy single-digit
  percent for a large rewrite. The wins were algorithmic instead.

## Time every command
- **Know how long things take.** Every check script prints its elapsed time (via
  `tests/timing.py`); keep that. Without a number you cannot tell a 3-second
  probe from a 3-minute suite, and slow scripts quietly end up in a loop.
- Before repeating a command, look at the previous run's time. If it is slow,
  make it faster or run it less — do not wrap it in a `for` loop and wait.
- Never pipe a long-running command through a filter that hides progress until
  the end. Stream it, or redirect to a file and poll the file.
- Bound everything: explicit timeouts on probes, and a per-case timeout in the
  suite. An unpatched jump is an infinite loop, so the sim can hang too.
- After a killed or long command, check for leftover `python` processes; a
  timeout does not reliably kill the process tree.
- Bisect slow batches: run suspect cases one at a time, each with its own timeout.

## Batching (the single biggest speed lever)
- Compiling `lua.ws` costs ~5s and indexing its 124k wires another ~0.8s. Never
  pay that per program: `irsims.ChipRunner` compiles once and runs many programs
  via `Sim.reset()`, which restores the just-constructed state without touching
  the wiring or the static source cache. The check scripts use it.
- `tests/test_chip_suite.py` puts `BATCH` (12, override with `CHIP_BATCH=1`)
  cases in each worker process, so a batch builds the chip once. A batch that
  dies or times out is re-run case by case, keeping the hard per-case timeout.
- Measured: suite 125s -> 78s, `iter_check` 78s -> 33s, byte-identical results.
- Do not split the suite into fast/slow tiers. It only ever meant running the
  whole suite twice to see everything; all cases now run by default.
- When a script loops over cases, build the expensive shared object once outside
  the loop. Check for this before concluding that a harness is just "slow".
- A differential check that tries N values is N programs and N oracle processes
  unless you batch it, and the batch unit is the *program*, not the value:
  `print` appends one capped line, `io.write` appends raw text with no width
  cap, and the log keeps 32 appends, so one `io.write` can carry a whole group
  of values (`tools/fmtsweep.py` does six per call, marked with a group number so
  one errored value cannot shift the rest of the comparison). Two ceilings bound
  a batch: the chip's source buffer is about 4 KB *including* the prepended
  library, and an expression is MAXVALS = 16 registers, so a group is built a few
  values per statement -- one fifteen-operand `..` came out with its tail
  dropped. Both are silent: check the program's length and its operand count
  when a big batch comes back empty or truncated.
- Time each phase, not just the script: `tools/fmtsweep.py` prints values/second
  per precision, because a sweep that was 121s per precision became 20s and the
  only way to see that was the number.
- A run whose program has an error should stop when the error appears. The sim's
  condition was "vmHalted and the queue drained", and a source too long to lex
  never drained, so an errored program ran its whole 200k-tick budget: 63
  seconds to be told what 2 seconds would say. `irsims.py` now also breaks on
  `errV`.

## Layout
- `lua.ws` is the chip; `irrun/` simulates it; `tests/` holds the suite and the
  oracle-diff checks; `tools/` holds the development tools. `README.md` lists
  them. Keep the root to the chip sources and the two docs.
- `lua.ws` is one file because the compiler reads one file: there is no include,
  so splitting it needs either a concatenate step that makes the real chip a
  generated artifact or compiler support we do not have. It is 7.9k lines and
  the tools do not care -- the things that bite are the *else-if chains inside
  it*, not the file: a chain of about sixteen arms is where arms near the top
  stop taking effect (the 33-arm state dispatch meant `%d` of 42 came out 00, so
  it is two halves of sixteen), and the conversion chain broke the same way at
  ten. When a dispatch grows, split it before the next arm, and keep the states
  in named mods so a split is mechanical.
- PUC's own split decides where a standard library function belongs: if PUC
  implements it in Lua, port that Lua and prepend it on demand (`LIB_*`, a few
  hundred characters); if PUC implements it in C, a gate. The float
  conversions, the pattern matcher and `error`/`pcall` are all C in PUC and are
  gates here for that reason; `pairs`, `ipairs`, `select`'s neighbours and the
  string helpers are Lua in PUC and are library source.
- A piece is a plain Lua function, and the chip's parser has three shapes PUC
  accepts that it does not: a nested `local function` inside a function literal
  assigned to a *field* (`string.gsub = function() local function f() ... end
  ... end`) is not bound, so a piece spells a nested function `local f =
  function(...) ... end`; a nested function may not read a local of the
  function it sits in (that is an upvalue, and closures are not built yet), so
  anything it needs is passed in as an argument; and a nested call in an
  argument list is fine, but a *function literal* there loses its returns (the
  `arg-fn-returns` skip). `tools/check.py @file` proves a piece against PUC
  before it is installed: the piece runs with an `_s`/`_m`/`_pat` shim and its
  results are diffed against real `gsub` on a set of shapes.
- A piece may use another piece: `libStrGsub` prepends `LIB_str_pat` with it
  (gsub scans its replacement for `%` with `string.find`) and `libStrPat` then
  stands down, so a program that uses both pays for the shared piece once.
  A piece referring to a name the loader does not install is not an error at
  load time -- it is "attempt to call" on the first call.

- A value that PUC's C code produces is a value the *sim* has to mirror
  exactly. The sim kept the log's old rule -- 64 characters and 32 lines --
  after the chip moved the width cap into the print handler and made the limit
  32 appends, so it silently cut every `io.write` over 63 characters and the
  oracle diff reported the chip as wrong. When a port's rule changes, the
  harness's copy of it changes with it.
- Anything used more than once belongs in a script, not in a shell one-liner:
  a probe you keep retyping should become `tools/<what it does>.py`.
- One-off debug scripts get deleted once the finding is in; the tool that
  reproduces it stays. `tools/unsup.py`, `tools/unhandled.py` and
  `tools/check.py` exist so the next person does not write another `debug_*.py`.

## Batch your own work too
- Independent tool calls go out in one message (parallel), not one at a time:
  searches, reads of unrelated files, independent test commands.
- Prefer one command that runs everything over many commands that each run part:
  `tests/test_consistency.py`, the suite and the three oracle checks belong in a
  single parallel call at the end of a change, not one per edit.
- Don't re-run the same test file repeatedly to "confirm" — one run at the end
  covers it. While iterating, run the single narrowest command that proves the
  thing just changed (`tools/check.py` with the program, a suite filter, a dump),
  then verify wide once.
- Merge plan steps that would each need their own test round: adding several
  library batches is one step and one verification, not one step per batch.
- Read every file a change will touch in one batched read before editing, so the
  edits are right the first time instead of iterating on stale context.
- Compile the chip once per batch of experiments: a loop over N test programs
  must not trigger N recompiles.

## Performance: the chip has two cost currencies
- **Every change costs gates AND ticks. Measure both, before and after.** Gates
  are `tools/audit.py` (nodes/wires); ticks are what `tools/check.py` prints per
  program. A change that is free in one can be ruinous in the other, and only one
  of them shows up in the obvious place.
- **The prepended library is charged by the character, and that is the trap.**
  Library pieces are Lua *source* spliced in front of the program, and the lexer
  runs at 4 characters per tick, so a piece of C characters costs `C/4` ticks of
  boot on *every* run of a program that names it. The ceiling is a few hundred
  characters per piece (the existing ones are 300–700). Before adding a piece,
  measure it: `python -u tools/libconst.py piece.lua LIB_x` prints the escaped
  size, and `tools/check.py` prints the boot cost. 443 lines of `string.format`
  was 10769 characters, 9.4s of sim time and ~45s in-game — written before
  anyone checked what the mechanism charges.
- **The lexer is not a cheap global speed lever.** Each unrolled `lexStep()` is
  ~1633 nodes (`tools/lexcost.py`: 8 steps +6.5k nodes, 16 steps +19.6k), so
  buying lexing speed costs gates linearly and cannot rescue an oversized piece.
  Shrink the piece or move the work into a gate.
- **Where a cost belongs:** Lua-level loops are VM state machines, so they cost
  ticks per iteration and no gates. WireScript has no loops at all, so a gate-side
  loop is either hand-unrolled (gates proportional to the trip count) or a
  micro-step (ticks proportional to it, as `next` does). String-heavy work
  belongs in Lua; tight arithmetic that runs per call belongs in a gate.
- **Follow PUC's own split.** In PUC Lua the primitives are exactly the things
  Lua cannot express: `string.format`/`string.find`/`string.rep` are C,
  `math.floor`/`math.tointeger` are C, and `next` is C -- while the iterators,
  `table.*` and the rest are Lua. The chip already draws the line the same way
  (`next`, `select`, `unpack`, `_s`, `_m`, `_fmt` are gates; the iterators, the
  table library and the small string helpers are Lua source). When a function
  needs a loop, exact decimal conversion, or a libc call to be faithful, it is a
  gate, and the PUC source is the argument for that rather than against it.
- **A new builtin must earn its gates** against the alternative of a library
  piece, and the answer changes with the piece's size: `string.format` at 10.7k
  characters is 20x over the source ceiling, so it belongs in a gate even though
  `table.insert` at 400 does not.
- **`string.gsub` is the piece that is too big, and it is waiting on a feature
  the VM does not have.** The piece is 3109 characters, so a program that merely
  *names* gsub pays ~2.9s of boot (measured: `print(string.gsub == nil)` is
  3.0s against a 0.1s baseline) while the loop itself is cheap (~0.1s per
  match). A gate would not have that cost, but gsub's replacement can be a Lua
  function and a gate cannot call one: the only place the chip calls Lua on a
  gate's behalf is the pcall frame, and `pcall of pcall` is explicitly
  unsupported, so a machine cannot suspend mid-loop for a call. The escape is a
  call-from-a-gate hook, which is gate-budget work, not a gsub bug. Meanwhile the
  piece is correct (49 shapes against the oracle) and the cost is in the file
  for everyone to see.
- Time the *program*, not just the harness: a case that goes from 0.2s to 2s in
  the suite is a user-visible regression in the chip, and the suite prints
  per-case seconds precisely so it cannot hide.

## Writing WireScript that survives the compiler
These are measured traps, not style rules. `tools/wswarn.py` flags the shapes it
can see and `tools/vargraph.py <name>` answers the rest (how many var nodes back
a name, how many write it, what fires each write). The `_fmt` header in
`lua.ws` records which one cost which bug.
- **A value gate fed by a var the same mod writes reads the NEW value.** Fetch a
  character (or anything positional) in one state and consume it in the next, so
  the cursor is written in one tick and read in the next. Reading `s[pos]` and
  then `pos = pos + 1` in one mod walks one step ahead of the data.
- **A condition on a file-level `var`, nested inside another `if`, is unreliable
  where the mod around it is inlined more than once.** `vmStep` is inlined four
  times (`vmBurst` calls it four times a tick) and the compiler shares one Get
  per var across the copies, so the nested arm silently loses; the lexer's chain
  has the same shape and works, because `lexChunk` inlines it once. Hoist the
  test to the top of the mod or take the flag as a parameter.
- **A write at the top of a mod, followed by an `else if` chain that deep with
  mod calls in it, is dropped.** One mod per state, and repeat the write in each
  arm rather than once at the top.
- **An array read that follows a var write inside a nested arm loses its Exec
  chain** where the mod is inlined more than once, and the writes fed by it never
  happen -- the pattern backtracker popped an entry and then read its four slots
  into three vars, and only the pop landed. Read the slots into locals at the top
  of the mod, before any write; `tools/vargraph.py <name>` shows the shape (a Set
  whose Exec comes from an `ArrayVar.Get` is one that can be starved).
- **An `int[]` does not keep a negative value.** The pattern capture ends were
  `-1` for "open" and `-2` for a position capture, and every one of them read
  back as `0`, so every capture looked like an empty match. Store the end plus
  one and keep a flag for the special case, or use a `float[]`.
- **A local computed from a var the same mod writes is re-derived at its next
  use**, so `let n = patCapN + 1` was `n + 1` by the time it reached the push
  below. Compute it, use it, and write the var last.
- **A gate may read only the arguments it was given.** A register past `nargs`
  still holds whatever the caller's previous call left in it: `_pat` read `a+4`
  for an `init` that was never passed and gave a find a boolean init. Guard every
  argument read with its count, the way `gateLow`'s `select` arm does.
- `x = a == b` leaves a placeholder that reads 0, and an int flag var read in a
  condition compares through one too: set flags with an `if`/`else` and keep the
  condition flags as `bool`.
- **`floor()` truncates toward zero; it is not a floor.** `floor(-1.0 / 16.0)` is
  0, so anything that needs floor division of a negative (a digit loop for a
  radix conversion, a bit of two's complement) has to do it by hand: truncate,
  then carry a negative remainder into the digit and off the quotient. Lua's
  `math.floor` is a different code path — the `_m` gate — and does floor, so
  `math.floor(-2.7)` being −3 proves nothing about the host's `floor`.
- A mod call on the right of `..` is "attempt to call" (the print handler and a
  `vmFail` argument get away with it, so `wswarn`'s hit there is a false
  positive); a string `+`, a chain mixing `..` with `+`, `%`, `for`, and a mod
  and a var sharing a name all leave placeholders; `c >= "0"` compiles and reads
  false; a string returned from a mod compares equal but its `ToCharCode()` is 0.
- `vmBurst` is four `vmStep` calls in one tick, so anything with cross-instruction
  state inside `vmStep` is entered up to four times per tick. `next`'s walk is
  fine with that (extra hops are harmless); a state machine is not — it needs a
  one-per-burst latch, as `fmtGo` is.

## Fixing bugs
- Fix the **class**, not the instance. When something breaks, ask what made it
  possible and make that harder next time; a one-line patch that leaves the trap
  in place will be hit again.
- **Minimise divergence from Lua 5.5.** A difference the chip does not have to
  have is a bug, even when the test says otherwise: fix the chip, not the
  expectation. `tests/test_chip_suite.py`'s `CHIP_LOG` is for what is genuinely
  unavoidable (doubles cannot hold 2^63-1; the chip has no float type) and
  should shrink, not grow. Before adding an entry, ask what the chip would have
  to do differently to match — that is usually the real work item.
- Prefer **restructuring** over a lint or a comment: if two rules have to be
  kept in step, merge them into one function so half of it cannot be forgotten.
  (Real example: `bumpMax` claimed registers but only grew the frame, so each
  call site had to *also* set `cfNext` — six sites, one of which had already
  forgotten. Now `bumpMax` does both and the paired line is gone.)
- Per-loop/per-scope state belongs in the per-level arrays the parser already
  keeps, not in globals. Globals get clobbered by nesting (generic-for did).
- Check the neighbouring invariants when a bug shows up: the real
  `local a,b,c = pairs(t)` path was fine while the for-in path was broken, so
  one working neighbour is not evidence the code is right.
- Watch for silent miscompiles. The host language has traps that produce
  confidently wrong results instead of errors: a `mod` that mutates a `var`
  inside an `if` and returns it yields garbage (use the single-expression
  `return if c then a else b` form, which every other mod uses), and WireScript
  has no `while` at all (use a `for`, or a `buffer`/`await` micro-step).
- Add an oracle case for the rule you just got wrong, not just for the program
  that exposed it. The state-stays-fixed rule of the generic-for protocol was
  wrong until `iter_check.py` compared against real Lua.
- **Reverting is not deleting.** When a change is replaced or dropped, the work
  still has value: keep the reference implementation as a file
  (`lib/str_format.lua` is the PUC-verified Lua `string.format`, kept while the
  gate version is built), keep the minimal repro as a case, and keep the
  measurement as a tool (`tools/lexcost.py`, `tools/libconst.py`). A throwaway
  probe in a temp directory is the only thing allowed to disappear.

## Code clarity
- Show the intent in the code: a name that says what a register is for
  (`freg`/`sreg`/`creg`, not `r1`/`r2`/`r3`) beats a comment explaining it.
- Keep short, useful comments next to a footgun, especially where the obvious
  code is wrong: state *why* the non-obvious thing is necessary ("a call leaves
  its results in the base register and the one above it, so a base below them
  would overwrite a variable"). Skip the comment when the code can be made to
  say it.
- Prefer deleting a concept over documenting it. If a helper exists only to
  work around a missing one, remove the workaround once the real thing is
  there.

## Verification
- Verify with execution, never by reasoning alone: run the relevant checks after every change.
- Chip-vs-oracle suite: `python -u tests/test_chip_suite.py [filter]`. All cases
  run unless a filter narrows them. It prints per-case and total times.
- After changing the sim or the runner, prove the fast path equals the slow one
  (e.g. `CHIP_BATCH=1` must give the same OK/FAIL counts) before trusting it.
- A "hung" batch is often buffering, orphan contention, or one stuck case hiding
  behind aggregated output — bisect to single cases with per-case output.

## Workflow
- Keep a todo list for multi-step work, with exactly one `in_progress` item at a
  time, and keep it current as steps finish so it is not re-planned by mistake.
- Commit only when explicitly asked; commit often when asked, with a message
  that says what changed and why.
