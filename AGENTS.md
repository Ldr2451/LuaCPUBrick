# AGENTS.md — how to work in this repo

## Commands
- Python, Lua and WireScript are cross-platform, so **the repo is too**. No
  PowerShell in scripts, docs or commands; no shell-specific incantations. One
  command per call: no `;`, no `&&`, no `$env:`, no heredocs. Options go in as
  script arguments. Probes use `tools/check.py @file` (`%%` separates programs),
  not quoted one-liners — PowerShell eats the quotes and compiles a different
  program. Put anything reusable in a script under `tools/`, never a shell
  one-liner.
- Always run Python with `-u`. Buffered output is indistinguishable from a hang.
- Use `os.path` in scripts, never a hard-coded separator or machine path.
- Anything external is discovered: `tests/lua_oracle.py` finds the oracle
  (`$LUA55`, PATH, install dirs) and `irrun/irdump.py` the compiler.
- Python is 3.12, GIL on: CPU parallelism means **multiprocessing**. A faster
  interpreter is not the lever — the sim is an interpreter-bound pointer chase.
- Port types: `float`, `int`, `bool`, `string`, `vector`, `color`, `entity` plus
  array forms, and a port-only `any`. **An object in WireScript is an `entity`.**
  Ask the compiler with `python -u tools/porttypes.py [type ...]`.
- Search with ripgrep, not the tool's own grep.

## Time every command, and bound it
- Every check script prints its own elapsed time; keep that. Anything else goes
  through `python -u tools/timecmd.py <command> [args...]`, which streams the
  output and prints the seconds and the exit code. A `.py` argument gets the
  interpreter put in front of it.
- **Size the timeout from the last measured run and keep it short** — two or three
  times the measured cost. The tool's 120s default is not an invitation to raise
  it to minutes: a loose timeout turns a five-second mistake into a long wait
  and a pile of orphaned workers. Suite 63s → 150s; a probe 38s → 90s.
- **When a command times out, kill what it left behind first**
  (`taskkill /F /IM python.exe`), then find out why. A timeout does not reliably
  kill the process tree, and a starved machine looks exactly like an infinite
  loop from outside — three chip jobs in one batch took over three minutes when
  the same work takes 22s and 63s in sequence.
- Never pipe a long command through a filter that hides progress; stream it.
- Bisect a slow batch one case at a time, each with its own timeout. A "hung"
  batch is often buffering, orphan contention, or one stuck case hidden behind
  aggregated output.

## Batching
- **One test command at a time, in its own call, never beside another chip job.**
  The suite takes the whole machine: twelve worker processes, each with its own
  Sim. Independent *searches* and *reads* do go out in parallel.
- Compiling `lua.ws` costs ~10s. Never pay it per program: `irsims.ChipRunner`
  compiles once and runs many via `Sim.reset()`; the suite's workers share the
  dump (`share_dump`/`sim_from_dump`). Hand out work one case at a time —
  a batch is as long as its slowest member. `CHIP_POOL=1` (default),
  `CHIP_WORKERS=12`, `CHIP_POOL=0` is the old batch path.
- While iterating run the single narrowest command that proves the change
  (`tools/check.py @file`, a suite filter, a dump), then verify wide once.
  Re-running the same file to "confirm" is wasted.
- A differential sweep's batch unit is the *program*, not the value: one
  `io.write` can carry a group (the log keeps 32 appends). Two silent ceilings:
  the source buffer is ~4 KB *including* the prepended library, and an expression
  is MAXVALS = 16 registers.
- Time each phase, not just the script. A run whose program errored should stop
  when the error appears — `irsims.py` breaks on `errV` for exactly that reason.
- Read every file a change will touch in one batched read before editing.

## Layout
- `lua.ws` is the chip; `irrun/` simulates it; `tests/` holds the suite and the
  oracle diffs; `tools/` holds the tools. Keep the root to the chip and the docs.
- **The oracle is the reference and nothing else.** Real Lua 5.5 decides what
  correct means; a diff against it is the only proof. There is no second chip
  source.
- `lua.ws` is one file because the compiler reads one file. Its size does not
  matter; the *else-if chains inside it* do: past ~16 arms the arms near the top
  stop taking effect (a 33-arm dispatch meant `%d` of 42 came out 00). Split a
  dispatch before the next arm, keeping states in named mods so the split is
  mechanical. `python -u tools/chainmap.py` lists every chain.
- **PUC's own split decides where a library function belongs**: C in PUC → a gate
  (`_s`, `_m`, `_fmt`, `next`, `select`, `unpack`, the pattern matcher, the float
  conversions, `error`/`pcall`); Lua in PUC → a `LIB_*` source piece. A new
  builtin must earn its gates against the piece alternative, and the answer
  changes with the piece's size.
- A piece may use another piece (gsub prepends `LIB_str_pat`); the shared one is
  paid once. A piece the loader does not install is not a load error — it is
  "attempt to call" on first use. `tests/test_consistency.py` proves every
  `const LIB_*` is installed by some `lib*` mod and reaches the `..` chain;
  `tools/check.py @file` proves a piece against PUC with an `_s`/`_m`/`_pat` shim.
- One-off debug scripts are deleted once the finding is in; the tool that
  reproduces it stays (`tools/unsup.py`, `tools/unhandled.py`, `tools/check.py`).
- `tools/wswarn.py` and `tests/test_consistency.py` run in preflight and have
  caught real bugs — keep them passing.

## Performance: three cost currencies
- **`vmStep` is 70% of the chip, and the reason is the inlining, not the code.**
  Measured by blanking one mod and rebuilding (`tools/modcost.py` — the only
  honest way to ask, since nothing in the graph records a source line and 91% of
  nodes carry no bind name): `vmStep` 76,877 of 110,017, `parseStep` 22,293,
  `lexStep` 6,692. The old `vmBurst` called `vmStep` four times and a mod is
  inlined at its call site, so the 43-arm opcode chain was compiled four times
  over: **19,210
  nodes per call**, measured by building with 1, 2, 3 and 4 calls (110,017 /
  90,807 / 71,597 / 52,386). A chain past ~16 arms is where arms near the top
  stop taking effect, so this is a correctness risk as well as a size one.
- **The opcode chain is small; builtin dispatch is big, but it is not the whole
  `vmStep`.** `gateHigh` is 13,217 nodes and `gateLow` 6,489 — together 19,706.
  The eleven buildable arms of `gateHigh` account for 10,734 of its 13,217
  (`tools/armcost.py` blanks one arm and rebuilds; the biggest are `unpack`
  1,806, `pcall`/`xpcall` 1,779, `_pat` 1,412, `assert` 1,381,
  `_gmatch`/`_gmnext` 1,268). Latching CALL in `vmStep`, dispatching it once
  from `vmBurst`, then restoring four steps compiled at **79,133 nodes**, and
  the first gsub call ended in `attempt to call`: the rest of each copy is not
  free, so moving the dispatch does not turn the other 13k into 500 nodes.
- **Unrolls are the size lever; constant folds are the tick lever.** Building
  with 1/2/3/4 `vmStep` calls per tick gives 52,386 / 71,597 / 90,807 / 110,017
  before the parser and lexer cuts. `parseChunk` (2→1) and `lexChunk` (4→2) are
  the same trade one level up. The chip then folds a temporary numeric load into
  the arithmetic or comparison that consumes it, and a constant `<=` used
  directly as a branch runs the comparison and skips its now-unreachable JMPF.
  Both chips were built and alternated in one process with identical output:

  | | nodes | loop-60 | gsub |
  |---|---|---|---|
  | four `vmStep`, two `parseStep`, four `lexStep` | 110,017 | 157 ticks | 1,672 |
  | one, one, two | 37,899 | 527 ticks | 3,751 |
  | one, one, two + constant folds | 38,153 | 345 ticks | 3,701 |
  | the same chip after the pcall repairs | 38,536 | 345 ticks | 3,701 |
  | after signed 64-bit wraparound | 38,898 | 345 ticks | 3,701 |
  | two, one, two, no folds | 57,082 | 313 ticks | 3,265 |

  The folds recover about half the loop-tick regression for 254 nodes; a second
  `vmStep` costs 19,194 to recover a little more. A one-liner got *faster* (9
  ticks to 18 is fewer instructions, not more — parse dominates and the parse
  is shorter per tick than the burst it replaced). The direct branch leaves the
  JMPF in the bytecode and skips it so no jump target or control-stack position
  has to move. **Only a temporary may be folded:** its register must be above
  `cfMaxLoc[fnDepth]`; a local initialiser can be the immediately preceding
  LOADNUM in the same register, and treating that as an operand lost the
  initial value in a `repeat` body.
- **The frame-switch hold died with the four-step burst.** `vmHold` spent one VM
  tick after every base change so later copies in the old burst agreed on the new
  base. The current burst executes one step, so the next tick already observes it.
  Removing the state and all writes cut 17 nodes and, against the same commit in
  one process, changed calls 313→271 ticks / 93,927→88,067 gates, closures
  380→336 / 118,529→112,385, and pcall 523→483 / 143,734→137,780. Pcall still
  switches frames through its own micro-state; only the redundant empty slots
  went. The full call/return, vararg, closure, method, and pcall batteries pass.
- **A one-value protected handler does not need the 16-value copier.** The
  error-handler branch of `pcallEnd` used `retAdjust` for either one value or a
  nil that it immediately replaced. A direct absolute-register copy removed 428
  nodes and 1,223 wires; successful pcall stayed at 483 ticks / 137,780 gates,
  and all pcall/xpcall cases still pass.
- **Three `retAdjust` callers know `k == n`.** Protected-call completion, a
  pcall'd gate's argument shift, and a successful `assert` can use a copy-only
  16-slot helper with no nil-fill arms. It removed 400 nodes and 1,040 wires;
  pcall stayed at 483 ticks / 137,780 gates and its battery plus every `assert`
  case passed.
- **An unread array is not necessarily dead to the compiler.** `fRegs` has no
  read anywhere, but deleting it and its writes produced three `_Unsupported`
  placeholders, so it stays. Four genuinely unread scalar parser flags
  (`pMode`, `blkHadCap`, `popLeft`, `pendLeft`) did lower cleanly, by 30 nodes
  and 52 wires.
- **A mod is inlined at its call site, so extracting a chain does not shrink
  it.** Moving ops 34..40 (floor division and the bitwise operators) into their
  own mod and calling it from the same place measured **+20 nodes**, not fewer.
  Splitting a chain into mods is a no-op for size. The levers that work without
  a host primitive are fewer calls per tick and more useful work per bytecode
  instruction.
- **`retAdjust` cannot be made cheap either.** It is sixteen unconditional `if`s
  inlined at ten call sites (3,004 nodes), and an early-exit ladder is the
  obvious fix — but WireScript has no loop and no recursion, so the ladder *is*
  the sixteen arms. Attempted, reverted rather than committed as a guess.
- **The 20k budget is not reachable by tuning, and the arithmetic says so.**
  After the unroll and parser/lexer cuts the chip is 38,187 nodes, of which the
  builtin dispatch alone is 19,706. Going under 20k needs runtime dispatch to
  stop being inlined, and **that is a host primitive the compiler does not
  have**: a gate takes values on named ports and cannot index a register file by
  a runtime value, which is exactly what a register VM's dispatch needs. The
  parts that look like array access — the pattern matcher, the formatter — are
  micro-steps, which are mods, which are inlined. So the budget is a decision
  about the host, not a refactor of the CALL arm.
- **Exact implicit float printing is host-bound, not a formatter bug.** The
  host's concat gate exposes only its shortest round-trip conversion and has no
  precision knob; PUC's oracle emits 17 significant digits and a three-digit
  exponent. A synchronous 17-digit replacement tried in `fmtNum` expanded at
  every call site and lowered 231 unsupported gates, so do not retry it without
  first changing the host or making the conversion non-inlined.
- **Integer precision and integer overflow are separate.** Every numeric register
  is a float, so a literal above 2^53 is wrong before `fmtVal` sees it. Wrap
  behaviour does not need the exact value: integer literals saturate to the two
  boundary sentinels, `vSetInt` wraps results, and a numeric `for` stores a
  remaining-iteration count so `maxinteger..maxinteger` ends after one body
  instead of wrapping forever. The exact decimal spelling still needs a parallel
  integer representation; `CHIP_LOG` is the honest list.
- **Gates, ticks, and the clock are three different things.** Gates are
  `tools/audit.py`; ticks are what `tools/check.py` prints. Sim wall time tracks
  gates fired per tick, so fewer ticks with the same work costs the same sim
  time. **In-game a tick is 16.7ms of real time whatever the chip does**, so
  there only fewer ticks reaches the user. A change can halve one and double the
  other; say which one you moved.
- **A library piece is charged by the character**: source is spliced in front of
  the program and the lexer runs at 4 chars/tick, so C characters cost `C/4`
  ticks of boot on every run of a program that names it. **That count over 4 is
  the in-game number to argue about** — `LIB_str_gsub` is 2,783 escaped chars =
  696 ticks = 11.6s at 60 ticks/s, before the program runs one instruction.
  `tools/libconst.py piece.lua LIB_x` prints the size; `--install` minifies
  (comments, indentation, blank lines out, nothing else — a line inside a long
  bracket string is data) and rewrites the const in `lua.ws`.
- A boot cost is only reducible three ways: fewer characters, more chars per
  tick, or not parsing. The middle one is linear in gates (unrolling `lexStep`:
  8 steps +6.5k nodes, 16 steps +19.6k — `tools/lexcost.py`). The cheap end is a
  `Find`-based fast path for string literals and a run ladder for identifiers,
  which is where the ladder's zero-progress trap (below) bites.
- **A gate that must call back into Lua is a separate mechanism nothing needs
  yet.** The only place the chip calls Lua on a gate's behalf is the pcall frame,
  and pcall-of-pcall is unsupported, so a machine cannot suspend mid-loop for a
  call. That is why gsub stays a piece: a gate would not pay the 696 ticks, but
  its replacement can be a Lua function, so the gate needs the hook *first* — and
  the matcher cost is the same micro-step either way, so the gate would buy the
  boot and nothing else. Do not build it unless a gate that must call Lua
  appears for another reason.
- **Where a cost belongs:** Lua-level loops are VM state machines (ticks, no
  gates). WireScript has no loop statement, so a gate-side loop is a hand-unrolled
  ladder (gates, ~2.5 nodes per arm) or a micro-step (ticks). String-heavy work
  belongs in Lua; tight per-call arithmetic belongs in a gate.
- **A rarely-taken path does not belong in `vmStep`** — it fires every tick,
  and the old burst inlined it four times. A closure cell-fill there cost every
  program 20% of its per-tick time; moved to `vmBurst` it cost 2,133 nodes
  instead of 3,054 and the tick-bound cases went back to normal.
- Time the *program*, not just the harness: a case going 0.2s → 2s in the suite
  is a user-visible regression, and the suite prints per-case seconds so it
  cannot hide.
- To compare two chips, **alternate them in one process** (a throwaway worktree
  at the previous commit). Run as two separate processes it read 1.66 → 2.22ms
  for a change that was really +7% — drift, not a regression. Compare slopes,
  never one run per chip.

## Closures
A function value (tag 4) holds a **closure number, not a prototype**. Below
`cloBase` a closure *is* its own prototype, so every builtin and every
capture-free function is unchanged and PUC's "equal when nothing was captured"
falls out for free.
- **Compiler:** one descriptor per captured local (`instack` for the declaring
  frame, an upvalue for each frame above), interned on `(prototype, local
  entry)` in `upIdx` — keyed on the entry, not the name, so an inner and an outer
  `x` are different cells. `resolveUp` is a short ladder; deeper is a loud error.
  `locFind` records which local matched and decides local-vs-capture *after* the
  arms, because a mod call in 32 arms would be inlined 32 times.
- **Runtime:** a frame's cells sit in the vararg stack below its varargs, three
  words each (cell, frame, loop round) under the frame's sequence number. The
  stamps stop a new frame adopting the last one's cells and give each loop round
  its own — which is what PUC gets by closing cells at block exit. A block with a
  capture ends with one `GEN` from `blkExit`, **except a `repeat`**, whose block
  ends after its `until`, so its bump goes in front of the condition.
- **The cell is canonical, the register is the seed:** the first capture makes
  the cell and after that every read *and write* of that local goes through it,
  including the declaring function's own — that is what makes a nested write
  visible outside. A nested `SETUP` writes only the cell (that frame's registers
  are gone).
- Cost: 2,133 nodes, one tick per cell, and a **fixed arena with no collector** —
  a loop building a closure per iteration spends a cell per iteration, the same
  bargain as the table heap. Every program pays +7% per tick, explained by 12
  more gates fired per tick.
- **Advancing the pc from an instruction needs both halves.** The dispatcher ends
  with `if !advanced && !vmHalted { vmPc = vmPc + 1 }`, so an arm that steps over
  its own instruction must write `vmPc = vmPc + 1` *and* set `advanced = true`:
  one alone stalls forever, the other double-advances.
- **A protected frame has three argument origins, not one.** `pcallEnter` copies a
  protected call's arguments from `a + 2`, xpcall's from `a + 3` because its
  handler is in between, and a message handler's from the new frame's base. After
  that copy, varargs come from `nbase + np`; using the old source plus `np` again
  drops the first vararg and `pcall(string.find, s, p, init)` loses its init. A
  gate handler that returns to a CALL must set `advanced = true` after
  `pcallEnd`, because pcallEnd has already moved the pc onto the following ADJUST;
  otherwise the second result is read from an unadjusted register. RETURNM with a
  protected marker joins fixed and vararg results through `pcallEndJoin`: copy the
  tail before the frame switch and pass its kept count into `pcallEnd`, because a
  vararg-stack read after a mod changes `vmBase` loses its later arms.

## WireScript traps
Measured, not style. `tools/wswarn.py` flags the visible shapes;
`tools/vargraph.py <name>` shows which gate fires each write.
- **A value gate fed by a var the same mod writes reads the NEW value.** Fetch a
  character in one state, consume it in the next.
- **A condition on a file-level `var`, nested inside another `if`, silently
  loses where the mod is inlined more than once.** The old four-copy `vmStep`
  shared one Get per var across the copies. Hoist the test to the top of the mod
  or pass it in.
- **A ladder that can report zero progress is an infinite loop, not a slow
  path.** An identifier ladder in `lexStep` hung `print('hello')` past 120s: the
  arms past the first read their character through a nested `if` in a mod
  `lexChunk` inlines four times, lose the Exec chain, return 0, and the run
  length comes out 0. Enter a run ladder only when the first character is known
  to match, and **read every value the ladder combines before the chain** — a
  conditional gate call inside an arm is the same trap, and factoring the test
  into a mod is no escape, because that call is inlined four times too.
  **Prove a new ladder twice: on a one-word program (10s), and on a name longer
  than the ladder itself.** The two are different bugs: a 9-character name
  against an 8-character ladder failed while short names and exact multiples
  passed, so the "exactly full" and "past the end" arms need their own proof.
- **A ladder cannot hand its work to a later step of the same mod.** In the old
  four-step `lexChunk`, a name longer than the ladder could not set a "keep
  reading" stage and let the next call finish it: the next call saw the full
  buffer and resolved the keyword on the first eight characters, emitting
  `abcdefgh` and `i` as two names. A ladder that runs past its own width has to
  finish the token in the call that started it, which means straight-line code
  (there is no loop in WireScript) and one test per extra character — which is
  the reason the identifier ladder did not land: the string `Find` fast path
  takes the same win with no ladder at all.
- **A write at the top of a mod followed by an `else if` chain that deep is
  dropped.** One mod per state; repeat the write per arm.
- **An array read after a var write in a nested arm loses its Exec chain** where
  the mod is inlined more than once, and the writes fed by it never happen. Read
  the slots into locals at the top of the mod, before any write.
- **A local computed from a var the same mod writes is re-derived at its next
  use** (`let n = patCapN + 1` arrived as `n + 1`). Compute, use, write last.
- **An `int[]` does not keep a negative value** — a `-1` read back as `0` made
  every pattern capture look empty. Store end+1 with a flag, or use `float[]`.
- **A gate may read only the arguments it was given**; a register past `nargs`
  holds the previous call's value. Guard every argument read with its count.
- `x = a == b` leaves a placeholder that reads 0; set flags with `if`/`else` and
  keep them `bool`. A mod call on the right of `..` is "attempt to call". A
  string returned from a mod compares equal but its `ToCharCode()` is 0.
- **`floor()` truncates toward zero, it is not a floor** (Lua's `math.floor` is
  the `_m` gate and does floor, so it proves nothing about the host's). Negative
  floor division has to be done by hand.
- The old four-step `vmBurst` needed a one-per-burst latch (`fmtGo`) for
  cross-instruction state in `vmStep`; the current one-step burst still uses the
  latch so restoring an unroll cannot make a state machine run several times.

## Fixing bugs
- Fix the **class**, not the instance: ask what made it possible and make it
  harder next time.
- **Minimise divergence from Lua 5.5.** A difference the chip does not have to
  have is a bug even when a test says so — fix the chip, not the expectation.
  `CHIP_LOG` is for the genuinely unavoidable and should shrink. Before adding
  an entry, ask what the chip would have to do differently; that is the work item.
- Prefer **restructuring** over a lint or a comment: if two rules must be kept in
  step, merge them into one function (`bumpMax` now does both halves, which
  six call sites had to remember and one had forgotten).
- Per-loop/per-scope state belongs in the per-level arrays the parser keeps, not
  in globals — globals get clobbered by nesting.
- Check the neighbouring invariants: the real `local a,b,c = pairs(t)` path was
  fine while the for-in path was broken, so one working neighbour proves nothing.
- **WireScript has no loop statement at all** — asked of the compiler with a body
  reachable from `on Clock`: `for`, `while`, `loop` and `repeat` are all
  `unknown identifier` (the chip's own `for` is *Lua's* for). A loop is a
  hand-unrolled ladder or a `buffer`/`await` micro-step. `await` is not a loop:
  `await 1` and `await 4` both cost 12 nodes, a fixed-cost yield. A dead mod
  compiles to 4 nodes, so a probe that does not reach its body measures nothing.
- Add an oracle case for the *rule* you got wrong, not just the program that
  exposed it.
- **Fight complexity, and cut it whenever it can go.** The bar is not "it works"
  but "nothing simpler works"; ask what existing machinery already does before
  adding a flag, a heuristic or a second path, and delete cleverness the moment it
  proves unreliable. The runner's stall detector watched the log, table counts
  and frame depth and was wrong about fib, the one failure mode that matters; it
  went back out for `Sim.finished` (one flag: the chip said it was done) with
  `CAP` printed when the budget ran out, so a truncated run never reads as a
  finished one.
- **Reverting is not deleting.** Keep the reference implementation
  (`lib/str_format.lua`), the minimal repro as a case, and the measurement as a
  tool (`tools/lexcost.py`, `tools/libconst.py`). A throwaway probe in a temp
  directory is the only thing allowed to disappear.

## Code clarity
- Names that say what a register is for (`freg`/`sreg`/`creg`, not `r1`/`r2`).
- Comment a footgun only where the obvious code is wrong, and say *why*.
  Otherwise make the code say it.
- Prefer deleting a concept over documenting it; remove a workaround once the
  real thing exists.

## Verification
- Verify by execution, never by reasoning alone. All cases run unless a filter
  narrows them: `python -u tests/test_chip_suite.py [filter]`.
- `python -u tools/preflight.py` runs the four cheap structural nets (audit,
  wswarn, consistency, syntax) in parallel — that plus one suite run is the
  minimum bar for a change.
- After changing the sim or the runner, prove the fast path equals the slow one
  (`CHIP_BATCH=1` must give the same OK/FAIL counts).

## Workflow
- Keep a todo list for multi-step work, exactly one `in_progress` at a time, and
  update it as steps finish.
- Commit only when explicitly asked; commit often when asked, with a message
  that says what changed and why.
- Keep this file to rules that earn their place. When a finding is recorded,
  fold it into an existing rule or replace an older one — it is not a log.
