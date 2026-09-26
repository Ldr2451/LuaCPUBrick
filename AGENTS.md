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
  Ask the compiler with `python -u tools/lib/porttypes.py [type ...]`.
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
- **`lua.brz` is the deliverable, and the compiler writes no artifact when it has
  diagnostics.** It prints the IR, exits non-zero and leaves the previous `lua.brz`
  sitting there looking current — so a build that does not check the exit code can
  "succeed" and ship yesterday's chip. `python -u tools/buildbrz.py` is the build
  and refuses to claim success unless `rc == 0`; `irdump.dump_source` now raises on
  a non-zero `rc` too, which is what makes preflight catch the regression. This is
  not hypothetical: `lua.ws` carried 53 diagnostics for a long time (46 mods called
  above their own declaration, a parameter assigned, a var read above its
  declaration) and **629 cases were green throughout**, because the graph those
  diagnostics still produce is a working graph and nobody looked at `rc`. Hoist a
  declaration rather than leaving a call above it, and remember that a mod is
  *inlined at its call site*, so a mod may write a name that belongs to the mod it
  is inlined into — that is how `gateHigh` set `advanced` — but the scope check runs
  before inlining and calls it unknown. Answer it as a return value instead.
- **The oracle is the reference and nothing else.** Real Lua 5.5 decides what
  correct means; a diff against it is the only proof. There is no second chip
  source.
- `lua.ws` is one file because the compiler reads one file. Its size does not
  matter; the *else-if chains inside it* do: past ~16 arms the arms near the top
  stop taking effect (a 33-arm dispatch meant `%d` of 42 came out 00). Split a
  dispatch before the next arm, keeping states in named mods so the split is
  mechanical. `python -u tools/chip/chainmap.py` lists every chain.
- **PUC's own split decides where a library function belongs**: C in PUC → a gate
  (`_s`, `_m`, `_fmt`, `next`, `select`, `unpack`, the pattern matcher, the float
  conversions, `error`/`pcall`); Lua in PUC → a `LIB_*` source piece. A new
  builtin must earn its gates against the piece alternative, and the answer
  changes with the piece's size.
- **The split is about the primitive; a thin wrapper over an existing gate is a
  piece however PUC wrote it.** `tonumber` is C in PUC, so the split points at a
  gate, and as a gate it is a new fid, a 13th `gateHigh` arm and an inlined copy
  of the parse: about 70 nodes. But the *primitive* the rule calls a gate — the
  float conversion — is the one the arithmetic coercion already uses, so the
  whole of `tonumber` is `pcall(function() return v + 0 end)`: **0 nodes**, and
  one copy of PUC's numeral rules in the chip instead of two, so `tonumber(s) + 1`
  and `s + 1` cannot disagree (they inherit the host's refusal of `inf`/`nan`,
  which PUC's also does). Cost: 760 escaped chars, 565 ticks of boot for a
  program that *names* it, 70 per call. The same reasoning already covers
  `string.sub`/`byte`/`char`/`rep`, which PUC also has in C. `tools/lib/libconst.py
  lib/x.lua LIB_x --install` is how a piece lands, minified, and the piece's
  cost is `tools/lib/libconst.py lib/x.lua LIB_x`.
- A piece may use another piece (gsub prepends `LIB_str_pat`); the shared one is
  paid once. A piece the loader does not install is not a load error — it is
  "attempt to call" on first use. `tests/test_consistency.py` proves every
  `const LIB_*` is installed by some `lib*` mod and reaches the `..` chain;
  `tools/check.py @file` proves a piece against PUC with an `_s`/`_m`/`_pat` shim.
- One-off debug scripts are deleted once the finding is in; the tool that
  reproduces it stays (`tools/lib/unsup_where.py`, `tools/check.py`). **Before naming
  a tool in this file, check it exists** — this file outlived `unsup.py` and
  `unhandled.py` for a long time after `audit.py` absorbed both, and a reference
  to a missing file costs the next reader the same hunt twice.

## Performance: three cost currencies
- **`vmStep` is 70% of the chip, and the reason is the inlining, not the code.**
  Measured by blanking one mod and rebuilding (`tools/chip/modcost.py` — the only
  honest way to ask, since nothing in the graph records a source line and 91% of
  nodes carry no bind name): `vmStep` 76,877 of 110,017, `parseStep` 22,293,
  `lexStep` 6,692. A mod is inlined at its call site, so the old four-call
  `vmBurst` compiled the 43-arm opcode chain four times over: **19,210 nodes per
  call**, measured by building with 1, 2, 3 and 4 calls (110,017 / 90,807 /
  71,597 / 52,386). A chain past ~16 arms is where arms near the top stop taking
  effect, so this is a correctness risk as well as a size one.
- **The opcode chain is small; builtin dispatch is big, but it is not the whole
  `vmStep`.** `gateHigh` is 13,217 nodes and `gateLow` 6,489 — together 19,706.
  The eleven buildable arms of `gateHigh` account for 10,734 of its 13,217
  (`tools/chip/armcost.py` blanks one arm and rebuilds; the biggest are `unpack`
  1,806, `pcall`/`xpcall` 1,779, `_pat` 1,412, `assert` 1,381,
  `_gmatch`/`_gmnext` 1,268). Latching CALL in `vmStep` and dispatching it once
  from `vmBurst` still compiled at **79,133 nodes** and the first gsub call ended
  in `attempt to call`: the rest of each copy is not free, so moving the dispatch
  does not turn the other 13k into 500 nodes.
- **Unrolls are the size lever; constant folds are the tick lever.** Building
  with 1/2/3/4 `vmStep` calls per tick gives 52,386 / 71,597 / 90,807 / 110,017
  before the parser and lexer cuts; `parseChunk` (2→1) and `lexChunk` (4→2) are
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
- **Three results that are banked, kept because each one is a rule about the next
  change.** (1) The frame-switch hold died with the four-step burst: `vmHold` spent
  one VM tick after every base change so later copies in a burst agreed, and the
  one-step burst already observes it — removing the state cut 17 nodes and took
  calls 313→271 ticks / 93,927→88,067 gates, closures 380→336 / 118,529→112,385,
  pcall 523→483 / 143,734→137,780. (2) A one-value protected handler does not need
  the 16-value copier, and three `retAdjust` callers know `k == n`, so both use a
  copy-only path: 428 nodes / 1,223 wires and 400 nodes / 1,040 wires, with pcall
  unmoved at 483 ticks / 137,780 gates. (3) An unread array is not necessarily
  dead to the compiler — `fRegs` has no read anywhere, but deleting it and its
  writes produced three `_Unsupported` placeholders, while four genuinely unread
  scalar parser flags (`pMode`, `blkHadCap`, `popLeft`, `pendLeft`) did lower, by
  30 nodes and 52 wires.
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
- **Merging the two simple return arms is not smaller.** `RETURN` and
  `RETURN0` share their frame teardown in source, but one arm with a `count`
  value and a captured source cost 90 nodes and 256 wires more than the two
  specialized arms. Reverted after `tools/chip/audit.py`, not a correctness guess.
- **The 20k budget is not reachable by tuning, and the arithmetic says so.**
  After the unroll and parser/lexer cuts the chip is 38,187 nodes, of which the
  builtin dispatch alone is 19,706. Going under 20k needs runtime dispatch to
  stop being inlined, and **that is a host primitive the compiler does not
  have**: a gate takes values on named ports and cannot index a register file by
  a runtime value, which is exactly what a register VM's dispatch needs. The
  parts that look like array access — the pattern matcher, the formatter — are
  micro-steps, which are mods, which are inlined. So the budget is a decision
  about the host, not a refactor of the CALL arm.
- **Do not go gate-hunting one builtin at a time; the list is empty, and the ISA
  is already RISC where it can be.** What is left is `assert` at 284 nodes and
  `next` at 179 — 0.7% and 0.4% of the chip — and both are *worse* as pieces: a
  `next` piece rescans the table per call (O(n²) a traversal), and an `assert`
  piece would have to reach the number formatter, which is a gate. The ISA itself
  is not the problem either, measured per opcode family by blanking it
  (`tools/chip/armcost.py vmStep 8,9,10,11,12,13`):

  | family | nodes | family | nodes |
  |---|---|---|---|
  | `CALL` 23/41 | 5,467 | `field` 29/30 | 384 |
  | `TAPPEND` 44 | 2,475 | `vararg` 45 | 356 |
  | returns 24/26/27/42 | 2,417 | `adjust` 43 | 279 |
  | loads 1-7 | 568 | `idiv` 34 | 215 |
  | closures 46/47/48 | 216 | comparisons 17-19 | 178 |
  | for 32/33/50 | 150 | unary 14/15 | 142 |
  | concat 16 | 126 | newtable 28 | 123 |
  | len 31 / loadfunc 25 | 54 each | jumps 20/21/22 | 35 |
  | `gen` 49 | 1 | | |

  **Arithmetic is already ONE arm (8..13) and comparisons are already ONE arm
  (17,18,19)**, so the three big ones are `CALL` — which is where the builtin
  dispatch is inlined, not call mechanics — `TAPPEND`, and the four return arms,
  whose merge is the +90 nodes above. `retAdjust` needs a loop or a dynamic index,
  and the host's array gates (`ArrayVar_CopyFrom`, `ArrayVar_Slice`, both already
  used) move whole arrays, not a range of one, so they cannot do a 16-slot
  register copy. The unused host gates are all exec gates (whose values cannot be
  read into a register in the same instruction), game gates with no PUC
  counterpart, or `FormatText`, which rounds floats to 3 decimals. This host build
  has no `BitwiseXOR`, `BitwiseNOT` or `BitwiseShiftLeft` at all, so `~` stays
  negate-and-add. **A gate cut has to come from a host primitive that does not
  exist yet; until one does, the dispatch's 19,706 is the floor.**
- **Exact implicit float printing is host-bound, not a formatter bug, and the
  host's law is now read rather than inferred.** The `..` gate converts a float
  operand with `if !f.is_finite() || *f == 0.0 { "0" } else { format!("{f}") }`
  (see "the host's laws" below), so the chip's shortest round trip *is* the
  host-faithful spelling and PUC's 17-digit `%.14g` output is the divergence;
  there is no precision knob to ask for. A synchronous 17-digit replacement tried
  in `fmtNum` expanded at every call site and lowered 231 unsupported gates, so do
  not retry it without first changing the host or making the conversion
  non-inlined.
- **Integer precision and integer overflow are separate.** Every numeric register
  is a float, so a literal above 2^53 is wrong before `fmtVal` sees it. Wrap
  behaviour does not need the exact value: integer literals saturate to the two
  boundary sentinels, `vSetInt` wraps results, and a numeric `for` stores a
  remaining-iteration count so `maxinteger..maxinteger` ends after one body
  instead of wrapping forever. The exact decimal spelling still needs a parallel
  integer representation; `CHIP_LOG` is the honest list.
- **Gates, ticks, and the clock are three different things.** Gates are
  `tools/chip/audit.py`; ticks are what `tools/check.py` prints. Sim wall time tracks
  gates fired per tick, so fewer ticks with the same work costs the same sim
  time. **In-game a tick is 16.7ms of real time whatever the chip does**, so
  there only fewer ticks reaches the user. A change can halve one and double the
  other; say which one you moved.
- **A library piece is charged by the character AND by every function it
  defines.** Source is spliced in front of the program and the lexer runs at
  4 chars/tick, so `C/4` ticks is the lexing; on top of that each `function` in
  a piece is a closure the chip has to create and fill, measured at about **280
  ticks each** (tonumber: 760 chars, 2 functions, 583 ticks = 190 + 2×197;
  math.random before this was inlined: 1,140 chars, 3 functions, 1,130 ticks =
  285 + 3×282; string.gsub: 2,783 chars and 2,933 ticks, which fits ~8
  functions). **That count over 4 is the in-game number to argue about** -
  `LIB_str_gsub` is 2,783 escaped chars = 696 ticks = 11.6s at 60 ticks/s,
  before the program runs one instruction and before the closures on top of it.
  So a piece's first question is how many functions it needs, not how long it
  is: inlining `math.random`'s generator into it (randomseed does not draw) took
  the piece from 3 functions to 2 and its boot from 1,130 ticks to 989, and 141
  ticks is 2.3s at 60 ticks/s for a program that names it once.
  `tools/lib/libconst.py piece.lua LIB_x` prints the size; `--install` minifies
  (comments, indentation, blank lines out, nothing else - a line inside a long
  bracket string is data) and rewrites the const in `lua.ws`.
- **A gate can be dearer at boot than the piece it would replace.** Measured:
  naming `math.abs` or `math.floor` costs about 474 ticks of boot and
  `math.maxinteger` 923, because `libMathInt` and `libMathConst` are pieces the
  loader pulls in on the name - while `math.random`, a whole piece of its own,
  costs 989. So "a gate is cheaper" has to be argued about ticks per call
  against the piece's boot, never about gates being free.
- A boot cost is only reducible three ways: fewer characters, more chars per
  tick, or not parsing. The middle one is linear in gates (unrolling `lexStep`:
  8 steps +6.5k nodes, 16 steps +19.6k — `tools/chip/lexcost.py`). The cheap end is a
  `Find`-based fast path for string literals and a run ladder for identifiers,
  which is where the ladder's zero-progress trap (below) bites.
- **A piece's boot is its whole dependency chain, not its own characters — that
  is what decides whether a gate can become a piece.** Measured on `string.gmatch`
  (`tools/chip/piececost.py`, reference in `lib/gmatch.lua`): as two gates plus a
  micro-step machine it was 1,053 nodes at 33 ticks a step, and the Lua piece
  saved exactly those 1,053 for **2,970 ticks of boot (26×)** — 1,469 escaped
  chars is 370 ticks, and the rest was the pieces it drags in (`string.find`,
  `string.sub`, `table.pack` pull in the pattern wrapper, the string-index piece
  and the table-list piece). Per step it was 119 ticks against 33, and a
  capture-free fast path with no `table.pack`/`table.unpack` measured *worse*, so
  the per-step cost is the Lua call and the micro-step dispatch, not the
  variadic plumbing. **So: a piece is viable when everything it needs is already
  a gate** (`pairs`/`ipairs` qualify — they need `next` and nothing else); a piece
  that needs another piece does not pay. Convert on that test, not on the node
  count alone.
- **An exec gate fires from a mod; the wall is consuming it, not reaching it.**
  Three compiled probes settle it (`Random(min, max) -> int`, called from a mod,
  from a handler, and with `exec =` named at the call site): all wire the Exec
  input from the enclosing handler's exec context (`W[BrickGrid -> Random:Exec]`),
  so "an exec gate can never run inside a mod" is false — do not argue it from
  the catalogue. What fails is the *read*: the compiler orders a consumer that is
  itself an exec gate along the gate's ExecOut chain, and the chip's register
  writes are plain array writes with no Exec port, so a value an exec gate
  produces cannot land in a register in the same instruction. An `_rnd` arm
  written the documented way (`let r = Random(lo, hi)`, then `vSetInt(a, r)`)
  re-ran its instruction to the tick cap. Using one would need the two-phase
  shape `_fmt`/`_pat` use — fire on one tick, read a captured output on the next —
  and a free-running stream would have to fire on every tick for every program.
- **A printed line is capped at 64 characters, and the harness caps the oracle's
  the same way.** `oracle_log` applies "the same caps the chip enforces" (one
  tab-joined line per print, `line[:LOG_WIDTH - 1] + "\n"`, 32 appends), so a
  long line matches PUC only up to the cap. Do not read a short line as a lost
  message: check `string.len` on the value first, because the cap hides the
  difference and a DIFF on a long line is usually one character at the
  boundary, not data loss. Measured on `math.random(1.5)`'s 66-character error
  message: whole in the register, chip line ends `...repres`, oracle's capped
  line ends `...repre`.
- **A model of the *toolchain* comes first, because a model that never ran is not
  a model.** `tools/model/vmmodel.py` looked for quint as an npm shim and for
  java as `JAVA_HOME`, and this machine has neither: quint is the standalone
  `quint-*.exe` release and the JRE is a Temurin zip unpacked into the scratch
  dir, so every model check had been quietly skipping. Both are discovered now, in
  the order `irdump` uses for the compiler, and the docstring's claim is finally
  true. What cost the most time was the two languages' syntax, so write these down
  before the next model: in Quint `if (c) x else y` has **no `then`**, a `val`
  body is a single expression (a multi-line `and` does not parse), a `def` cannot
  recurse, and `nondet` binds only as `action a = { nondet x = oneOf(S)  all { ... } }`
  — `oneOf` outside a `nondet` binding is an error, and a primed name after
  `nondet` does not parse. In Apalache **a dynamic range is rejected**
  (`0.to(pc - 1)` is an input error, so "the executed set is the prefix" has to be
  `executed.size() == pc and executed.forall(i => i < pc)`) and **every
  top-level `val` is passed as an invariant**, so a helper `val` among them makes
  Apalache's parser fail with `key not found` rather than anything that names
  the cause. A model earns its place by finding a wrong assumption in the model:
  the checker found that with `errored` set the pc still advanced and a line was
  still printed, because nothing stopped the instruction actions — exactly what
  `noErrorAccumulation` says.
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
- **The array ports are already whole-array on the wire; only the Lua-side call
  is per element, so batch it by widening the call, not with a machine.**
  `outArr` is `@right out outArr: float[] = outArrV`, so the whole array reaches
  the port every tick however it was filled, and `inarr(i)` is a live
  `inArr[toInt(iv) - 1]` — one index and one tag write, with no per-element copy
  to remove. Measured (dump compiled once): a 64-slot fill is 367 ticks against
  205 for the same empty loop, so **about 5 ticks per element** and a whole
  64-slot write is 6.1s in game at 60 ticks/s; `inarr` over 64 costs 672, and
  building a 64-entry table costs 193. A whole-array setter would have to walk a
  Lua table in a micro-step machine, which is 1 tick per element at best: 64
  slots go 367 → ~270, a **26% cut for a new state machine**, where a bounded
  `outarr(i, v1..vk)` writing k consecutive slots in one call leaves the loop's
  205 ticks and cuts the call overhead k-fold (~220 ticks, a 40% cut) for
  100-150 nodes in one arm and no new state. A whole-array `inarr` read is a
  **loss** for any program that reads fewer than 64, since it pays a table build
  (193) to save ~2 ticks an element the caller's own loop was going to spend.
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
Measured, not style. `tools/chip/wswarn.py` flags the visible shapes;
`tools/chip/vargraph.py <name>` shows which gate fires each write.
- **The `and`/`or` branch form is the one operator whose pop is not a pop-and-push.**
  `and`/`or` compile to a jump, so `pushPending` puts the LEFT operand's register
  on `valStk` and the pop writes the result back into that same register — the
  pop has to **consume the left entry as well as the right** (pop 2, push 1), or
  the left entry is left underneath. It was not, and the leftover is invisible
  until a call's `)` drains to the depth its `(` recorded and takes ONE value:
  then it reads two arguments where there was one, and the enclosing
  comparison's operands come out as (the argument, the call) instead of (the
  call, the other operand). Measured: `print("a" < tostring(false or false))`
  raised "attempt to compare" where PUC answers `true`, and the trace of the
  value stack went `[5 4 1]` → `[4 4 1]` at the `or`. Found by `tools/fuzz.py`
  seed 1358, which could not find it while the generator was skipping two thirds
  of its seeds. **A value stack that grows by one entry per `and`/`or` is this
  bug**; when you see an operand that is a call's argument, look here first.
  The other half of the lesson: WireScript cannot parse `tostring(false or
  false)` at all — it compiles to `_Unsupported` placeholders — so a shape that
  fails only in a *program* is this compiler (the code in `lua.ws` that compiles
  Lua), never the host.
- **A seed is expensive, so the fuzzer is not an edit-loop tool.** Measured: 150
  seeds 2.5 min, 400 seeds 6 min, one seed 5 s. Its default is 40 for that
  reason; the suite and `tools/check.py @file` are the fast paths, and a big
  sweep is a before-you-ship thing.
- **The host's laws are in the compiler's source, on this machine, and are worth
  more than any inference from the oracle.** `irdump.WS_DIR` is the wirescript
  checkout the compiler came from (`%TEMP%\opencode\wirescript`), complete with
  `docs/` and the *certified* gate laws — the ones whose comments say they were
  replayed against the game's own output. Ask there before guessing a gate's
  behaviour, and before trusting a branch in `irsims.py`. What it says today:
  - **Arithmetic is IEEE f64.** `float` is documented as 64-bit
    (`docs/src/types.md`), and the compiler's own constant folder is
    `MathDivide => x / y`, `MathModulo => x % y`, `MathLn => a.ln()`,
    `MathSqrt => a.sqrt()`, `MathPow => a.powf(b)`
    (`crates/wirescript/src/lower/fold/eval.rs`). So `1/0` is `inf`, `0/0` and
    `sqrt(-1)` are `nan`, `log(0)` is `-inf`, `0.0^-1` is `inf`, and `x % y` is
    Rust's *truncated* remainder. The folder refusing to bake a non-finite
    result is a folding rule, not a semantic one, and divide-by-zero is still
    unprobed in-game — the Rust model is the best evidence available, and it is
    IEEE. The chip deliberately diverges where Lua differs (`%` and `//` are
    floored, and done in the chip). Negation is the host's `MathNegate`, so
    `-v`, not `0.0 - v`: IEEE negation of `0.0` is `-0.0` and `0.0 - 0.0` is
    `+0.0`, which is how `print(-0.0)` printed `0.0`.
  - **Text gates are lossy in ways that matter.** `..` is
    `if !f.is_finite() || *f == 0.0 { "0" } else { format!("{f}") }`; `FormatText`
    rounds floats to 3 decimals (ties to even), comma-groups the integer part,
    drops trailing zeros, renders bools as `"1"`/`"0"`, renders
    rotator/color/quat as `""`, and renders non-finite and `-0.0` as `"0"`. So a
    *raw float* operand never prints as `inf`, `nan` or `-0.0` in game. The chip
    is spared that because it formats its own numbers (`fmtNum`, and `_fmt` as a
    micro-step) and hands the host strings — which is also why the 3-decimal
    rounding never reaches Lua output.
- **A numeric sim gate that catches an exception and answers `0.0` is a bug, and
  `except` around arithmetic hides it.** Python raises where the host returns a
  value: `1.0/0.0` is `ZeroDivisionError` (the gate divides to `inf`),
  `math.log(0)`/`math.sqrt(-1)` are `ValueError` (`-inf`/`nan`), and
  `(-8.0)**0.5` is a **complex number** (the gate answers `nan`). `_do_arith`
  caught all three and answered `0.0`, so the chip printed `0.0` for `1/0` and
  `0.0` for `1/(0.0*-1)` instead of `-inf`, and a complex reached a float
  register. Model these gates from the laws above, not from Python's exception
  behaviour. (`_NAN` is the x86 default QNaN — sign bit set — because that is
  what the oracle's C library prints.)
- **Register access comes in two forms and mixing them is invisible at top
  level.** `vTag`/`vNum`/`vStr`/`vSet` take a register *relative* to the current
  frame and add `vmBase` themselves; anything holding an *absolute* index
  (`fmtBase`, `nxDst`, a `retAdjust` src) reads `vtag[]`/`vnum[]`/`vstr[]`
  directly. `fmtArgAt()` builds `fmtBase + 1 + fmtArgI`, which is absolute, and
  the conversions handed it to `vTag` — so `vmBase` was added twice. At top level
  `vmBase` is 0 and every format call was right; inside a function every argument
  but the last came from two registers too high, which is why
  `return string.format('%s%s%s', 'a', 'b', 'c')` printed `cnilnil` and `%d` of a
  number answered "number expected, got nil". **Three wrong turns were spent on
  this before anyone read what `vTag` does with its argument**: passing `fmtBase`
  as a parameter, reading the base and index into locals before the write, and
  copying the arguments into the machine's own arrays. Each one changed the *shape*
  of the read and none of them touched the arithmetic, so each failed identically.
  When a read looks wrong in one context and right in another, write down the
  index for both and subtract — the shape is not the variable. The fix was also 150
  nodes *smaller*, because an array read beats a mod call that adds a base.
- **A call that answers no values still has to nil the callee's own register.**
  A call's results land in the register the function was in, and that is the
  register the compiler puts the local in, so PUC's empty result list is a nil
  there. `print`, `setvec`, `setcol`, `outarr` and `_s`'s byte-out-of-range all
  write it; `select` past the end and `unpack` over an empty range did not, and
  `local c = select(2, ...)` read `type(c) == "function"`. It hides best in a
  **vararg function**, where the local cannot be the callee's register and the
  compiler points ADJUST at the frame instead. `tools/chip/wswarn.py` judges each
  `fid ==` **arm** separately for this (a mod-wide test sees `print`'s write and
  says nothing), and only in mods with a parameter named `a` — `patArm` and
  `pcallEnd` write an absolute register of their own and are not the shape.
- **A value gate fed by a var the same mod writes reads the NEW value.** Fetch a
  character in one state, consume it in the next.
- **A micro-step machine that a pcall dispatched in place must be completed by
  the machine, not by the call.** `_fmt`, `_pat` and `_gmatch` answer through a
  machine that runs for several ticks, and the CALL arm used to run `pcallEnd` on
  the tick that *started* it: the protected call was over before the work ran,
  the marker was gone, and the failure that work raised a tick later ended the
  program instead of answering `false, message`. All five completion sites now go
  through `nxDone`, and the unwind abandons the machine (it used to keep ticking
  and fail a second time, this time with `pcallDepth` at 0). Two neighbours of
  this trap cost the same fix: every var a machine reads must be reset when the
  *next* call starts, or a call that raised leaves it poisoned — `fmtTo` left on
  4 made the following `string.format` answer its own format text as a literal.
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
  tool (`tools/chip/lexcost.py`, `tools/lib/libconst.py`). A throwaway probe in a temp
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
- **The structural invariants live in the simulator, not in cases, because the
  damage shows up later.** `Sim.state_invariants` is called for every case and
  its verdict is the first thing `compare()` looks at: the eight frame arrays
  must be the same length, `pcallDepth` must equal the number of pcall markers
  actually on the frame stack, and after a *clean* finish no loop, protected
  call or micro-step machine may still be live. A lost push or pop leaves the
  output looking right and corrupts something several frames later — the
  loop-depth bug sat there for 552 green cases, and `fForDepth` was added to that
  group by hand and could just as easily have been left out of it. Deleting one
  `fForDepth.pop()` is caught by 12 cases with the divergence spelled out
  (`fForDepth=465` after fib, one slot per call), none of which the log
  comparison would have seen. "Clean" matters: a program that halted *with an
  error* stops exactly where the error hit it, so the 16 loops of "too many
  nested numeric loops" and the half-read format of a bad `%d` are both still in
  flight — the first version of this check flagged those fourteen and was wrong,
  not the chip. Also checked, because they are the same "wrong later" shape: the
  vararg pointer is at or above the current frame's vararg base, and the arenas
  stay in range (`tCount`, `tHeap`, every table's length, and the closure fill's
  cursor) with the limits taken from the array lengths, because the chip resizes
  them to its own consts. **Each one is proved by damaging the state and reading
  what it says** — `sim.chip_var(name, value)` writes a named var the way a lost
  update would, and the checker reads the same way. Two of those reads have to go
  through `chip_var`/`chip_array` rather than a label map: `fVaB` and `vaTop` also
  name the gates that read them, and asking one of those gives an empty array or
  the wrong node, which is how the first version of the vararg check silently
  never fired.
- `python -u tools/preflight.py` runs the four cheap structural nets (audit,
  wswarn, consistency, syntax) in parallel — that plus one suite run is the
  minimum bar for a change. `wswarn` and `consistency` have caught real bugs, so
  keep them passing rather than skipping them to get a green run.
- After changing the sim or the runner, prove the fast path equals the slow one
  (`CHIP_BATCH=1` must give the same OK/FAIL counts).
- **A model of the loop state finds what a diff cannot, and it is cheap.** The
  loop/frame depth invariant (`forDepth` is 0 whenever no numeric loop is live)
  has no repro short of writing one: `break`, a `return` out of a loop and an
  error unwinding through a `pcall` each corrupt a *later* loop, and the suite
  had 552 green cases over it. Encoding the machine as a small transition system
  and asking for an invariant violation gave the counterexample in minutes — and
  the corrected model then bounds the nesting depth instead of growing an array
  forever. Reach for it when the bug is "the state is wrong later", not "this
  program prints the wrong thing". A model of the *chip* is a different and much
  more expensive thing: the chip's own constants, the gates and the host's laws
  are not in the model, so a green model proves nothing about the chip — it
  proves the *rule* you are about to encode, which is what you want it for. The
  two models live in `tools/` and run with `python -u tools/model/vmmodel.py`, which
  discovers quint, a JRE and Apalache and skips cleanly when one is missing; a
  model that cannot fail is no net, so each one says which line to delete to
  make it fail. **Two backends, and the split is measured:** Apalache carries
  both models (`--backend=tlc` is TLC, which checks the pcall model's *whole*
  graph — 28 states, depth 4, queue empty — in 2.7s), while TLC cannot carry
  `loopmodel` at all: it explores states explicitly, the loop model's lists put it
  out of reach, and it was still running after ten minutes at max-steps 8 and
  again at 5 where Apalache takes 42s. TLC also still needs the Apalache
  *server*, because it compiles the spec to TLA+ with it
  ("[TLC] Compiling to TLA+ (via Apalache)") — with no server up quint falls back
  to spawning one itself, which is the hang to avoid.

## Workflow
- **A compacted session starts with `git status` and `git diff`.** The summary
  that arrives with it is written by the agent that was working, so it describes
  intent, not the tree: an edit it was mid-way through is uncommitted, and its
  `lua.ws` may hold a half-finished restructure that compiles and still answers
  the wrong thing (the `math.type` arm that only looked guarded was exactly
  that). Read the diff before trusting any claim about what is on disk, and
  before running a suite that would only tell you the tree passes.
- Keep a todo list for multi-step work, exactly one `in_progress` at a time, and
  update it as steps finish.
- **Commit a change as soon as it is clear and tested, without waiting to be
  asked.** A commit is the cheapest way to revert, to compare two chips with
  `git diff`, and to see what an edit actually changed. Commit when the
  narrowest check that proves the change passes, and say what changed and why.
  Leave a half-finished edit uncommitted *on purpose* when it is worth keeping
  as a record of a tried shape, and say so in the message.
- Keep this file to rules that earn their place. When a finding is recorded,
  fold it into an existing rule or replace an older one — it is not a log.
- **Trimming it is an edit with a proof attached: the sentences may go, the
  measurements may not.** A number with a unit *is* the technical information
  here — nobody can re-measure a reverted experiment — so
  `python -u tools/agents_nums.py` compares the working tree against HEAD and
  prints any numeric value that disappeared (`LOST VALUES none` is the bar; it
  also separates a reflow into a table cell, which costs a unit token but no
  value). Cut the story around a rule, never the rule's number.
