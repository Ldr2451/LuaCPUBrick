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
- **A CAP at the probe default is a measurement of the harness, not of the
  chip.** `tools/check.py` runs at 1200 ticks unless `PROBE_TICKS=` says
  otherwise, and a program that boots the gsub piece needs ~2700 of parse
  before it runs one instruction. `string.gsub("aaab", ".+b", "X")` read as a
  hang at the default and answers correctly in 66 matcher ticks. Prove a hang
  with the tracer before fixing one.
- **A suite FILTER is the difference between 20s and 244s, so filter while you
  iterate and sweep once at the end.** `tests/test_chip_suite.py pat` is 77 cases
  in 20s; the whole suite is 244s. `bit`, `gsub`, `gmatch`, `arith` are the
  other narrow ones. `pucsuite.py` is worse than useless to re-run: a sweep is
  ~310s, so use `--file pm.lua` (repeatable) to settle one DIFF, and
  `tools/chip/pucount.py` — pure text, seconds — to ask how many asserts are
  harvestable at all.
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
  a non-zero `rc` too, which is what makes preflight catch the regression. Not
  hypothetical: `lua.ws` carried 53 diagnostics for a long time (46 mods called
  above their own declaration, a parameter assigned, a var read above its
  declaration) and **629 cases were green throughout**, because the graph those
  diagnostics still produce is a working graph and nobody looked at `rc`. Hoist a
  declaration rather than leaving a call above it; a mod is *inlined at its call
  site*, so a mod may write a name that belongs to the mod it is inlined into —
  that is how `gateHigh` set `advanced` — but the scope check runs before
  inlining and calls it unknown. Answer it as a return value instead.
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
- **Three banked results, each a rule about the next change.** (1) Removing the
  frame-switch hold (`vmHold`, one VM tick after every base change so later
  copies in a burst agreed — the one-step burst already observes it) cut 17
  nodes and took calls 313→271 ticks / 93,927→88,067 gates, closures
  380→336 / 118,529→112,385, pcall 523→483 / 143,734→137,780. (2) A
  one-value protected handler does not need the 16-value copier, and three
  `retAdjust` callers know `k == n`, so both use a copy-only path: 428 nodes /
  1,223 wires and 400 nodes / 1,040 wires, with pcall unmoved at 483 ticks /
  137,780 gates. (3) An unread array is not necessarily dead to the compiler —
  `fRegs` has no read anywhere, but deleting it and its writes produced three
  `_Unsupported` placeholders, while four genuinely unread scalar parser flags
  (`pMode`, `blkHadCap`, `popLeft`, `pendLeft`) did lower, by 30 nodes and
  52 wires.
- **A mod is inlined at its call site, so extracting a chain does not shrink
  it.** Moving ops 34..40 (floor division and the bitwise operators) into their
  own mod and calling it from the same place measured **+20 nodes**, not fewer.
  Splitting a chain into mods is a no-op for size. The levers that work without
  a host primitive are fewer calls per tick and more useful work per bytecode
  instruction.
- **So merge two adjacent arms before you look for a cheaper primitive.** The
  same rule priced the other way: fixing a negative shift count with a shared
  `vmShift(x, n, left)` cost **+49 nodes**, because a mod inlines and that has
  two call sites. Ops 39 and 40 were one expression with a direction chosen, so
  as **one arm** — `if (n < 0) == (op == 40) { x * 2^n } else { floor(x / 2^n) }`
  — the same fix measured **−162**: one `2 ** n`, one `bitFail`, one arm fewer
  in the chain. A correctness fix that needs a shared helper should first ask
  whether the helper's two callers were one arm all along.
- **Unary binds tighter than the shifts, and `^` tighter than unary -- and the
  chip's table has to say so with three different numbers.** Unary shared the
  shifts' 6, so left-associativity popped the unary first and `-8 >> 4` was
  really `-(8 >> 4)`: right exactly where the two coincide, wrong everywhere
  else. Now `**` 8, unary 7, shifts 6. A literal with a leading `-` in front of
  any new operator is the test, because a variable of the same value takes a
  different path and will not catch it.
- **A right shift has to FLOOR, and the host's `floor()` truncates.** So
  `floor(-0.5)` is 0, and `-8 >> 4` was 0 instead of -1. This is op 34's `//`
  idiom verbatim (`q | 0`, then step down when a negative quotient was not
  exact) -- reused rather than wrapped, because a mod inlines. What remains is
  PUC's UNSIGNED reading of the shifted pattern (`-1 >> 1` is 2^63-1): 63
  mantissa bits against a double's 53, so no spelling of it -- a wall, pinned
  in CHIP_LOG, not a bug to chase.
- **`retAdjust` cannot be made cheap either.** It is sixteen unconditional `if`s
  inlined at ten call sites (3,004 nodes), and an early-exit ladder is the
  obvious fix — but WireScript has no loop and no recursion, so the ladder *is*
  the sixteen arms. Attempted, reverted rather than committed as a guess.
- **Merging the two simple return arms is not smaller.** `RETURN` and
  `RETURN0` share their frame teardown in source, but one arm with a `count`
  value and a captured source cost 90 nodes and 256 wires more than the two
  specialized arms. Reverted after `tools/chip/audit.py`, not a correctness guess.
- **The 20k budget is not reachable by tuning, and the arithmetic says so.**
  After the unroll and parser/lexer cuts the chip was 38,187 nodes, of which the
  builtin dispatch alone was measured at 19,706. Going under 20k needs runtime
  dispatch to stop being inlined, and **that is a host primitive the compiler
  does not have**: a gate takes values on named ports and cannot index a register
  file by a runtime value, which is exactly what a register VM's dispatch needs.
  The parts that look like array access — the pattern matcher, the formatter — are
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
  (the host's laws, in the compiler's source, are listed in docs/traps.md), so
  the chip's shortest round trip *is* the host-faithful spelling and PUC's
  17-digit `%.14g` output is the divergence; there is no precision knob to ask
  for. A synchronous 17-digit replacement tried in `fmtNum` expanded at every
  call site and lowered 231 unsupported gates, so do not retry it without first
  changing the host or making the conversion non-inlined.
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
  there only fewer ticks reaches the user. A change can halve one and double
  the other; say which one you moved.
- **A comment is one `Find`, so it is O(1), and that is the cheapest boot win in
  the chip.** `lexStep`'s line-comment arm used to advance one character per step,
  which *was* the scan floor — 0.500 ticks/char, a 4-character comment costing what
  a 400-character one costs. It is now a single search for the newline, and a
  comment of 2,013 chars costs the same **17 ticks** as one of 13 chars
  (`tools/chip/lexrate.py`'s `scan` family is now flat, which is why the tool
  reports it as O(1) and refuses to divide it). Long comments and long strings
  already went through `lexLong`, which searches for its closer, and a string
  with no escape in it already took a `Find` — the line comment was the last
  region still walked. Measured on **demo.lua: 4,532 → 2,994 ticks to first
  output, 34%, 1,538 of a predicted 1,624 ceiling** (53% of demo.lua and 66% of
  `lib/gmatch.lua` are comment characters, which is why the win is that size).
  It cost **−6 nodes and −10 wires**: one search replaced a four-arm chain of
  per-character tests, and perfbench has all seven programs' ticks, gates and
  bytecode byte-identical. Ticks for gates is the trade, and a host search is a
  gate. What is left walking a character at a time is whitespace and identifier
  runs, and a `Find` cannot help either: both need the first character that is
  NOT in a class, not a substring.
- **Price a file by RUNNING it, not by `chars x a rate`.** The per-char rate
  comes from synthetic programs with no comments in them, so charging every
  character of a commented file the code rate overstated demo.lua by **2.7x**
  (7,840-10,554 modelled against 2,994 measured) and did so silently.
  `lexrate.py` now leads with the measured boot and keeps the model as the
  comparison. Note also that a file over the ~4 KB source buffer **cannot be
  measured at all** — 11,478 chars does not fit — and that is the answer rather
  than a gap: it is why `string.format` is a gate and `lib/str_format.lua` is
  only its reference implementation.
- **The scan floor is 2 chars/tick, and parsing costs 2-3x that.** First measured
  at a fixed 1,600 characters: whitespace 811 ticks and a comment 815 —
  identical, so the floor is the raw scan at `0.507` ticks/char, and 4 chars/tick
  was stale (`lexChunk` had been unrolled 4→2 without the figure following).
  `tools/chip/lexrate.py` re-measures it as **exactly `0.500` ticks/char**, now
  with **whitespace** (linear 16 → 1,016 ticks over 10 → 2,010 chars) because a
  comment stopped being per-character when it became a `Find`. Real source that
  is lexed AND parsed but never run is **1.30 to 1.75 ticks/char** depending on
  the statement (`if x == 1 then x = 2 end` 1.30, `x = x + 1` 1.75), so the parse
  adds 0.8-1.25 ticks a character over the scan. Real code at the same length
  cost 4,015 ticks, which is that plus running it. So a boot-cost argument is a
  *parse* argument, and the lexer is the smaller half — inverting the obvious
  guess.
- **A library piece is charged by the character AND by every function it
  defines**, and both terms were wrong by a factor of three to ten while they were
  derived by subtraction from a whole program's boot. Measured directly, and
  deterministic to the tick (`tools/chip/lexrate.py lib/piece.lua`): **1.30 to
  1.75 ticks per character** of real source, and **24 to 62 ticks per function**
  (an empty one 24, one with a parameter, a local and a return 62). The old rule
  said `C/2` from the scan floor, which is what a character that lexes to no token
  costs, and ~280 ticks a function.
  - Those two terms are an UPPER bound, not a price: they charge comment and
    whitespace characters the code rate, and a comment costs ~0. Measured, the
    two pieces this repo ships come out at **`lib/gmatch.lua` 5,095 chars → 3,331
    ticks = 56s** against 6,720-9,165 modelled (2.0x), and **demo.lua 6,031 chars
    → 2,994 ticks = 50s** against 7,840-10,554 (2.7x). Price a file by running
    it; the rate multiplication is only for comparing two shapes.
  - `lib/str_format.lua` is 11,468 characters and 19 functions, so the model says
    **15,400 to 21,300 ticks of boot, 256 to 354s at 60 ticks/s** — and it cannot
    be measured at all, because 11,478 characters does not fit the ~4 KB source
    buffer. That is the reason `string.format` is a gate and not a piece: a piece
    that size cannot be delivered, whatever it would have cost. The old rule said
    **2,692 ticks** for it, which is where that number went.
  - `LIB_str_gsub` is 2,783 escaped chars, so **3,600 to 4,900 ticks = 60 to 81s**
    at 60 ticks/s, not the 696 ticks = 11.6s the old arithmetic gave, before the
    program runs one instruction.
  The subtraction-derived numbers and their post-mortem are the "Boot cost is
  measured by running it" lesson in docs/lessons.md; the first question about a
  piece is how long it is, not how many functions it has — the character term
  dominates, and eight functions is 200-500 ticks on top.
  `tools/lib/libconst.py piece.lua LIB_x` prints the size; `--install` minifies
  (comments, indentation and blank lines out; a line inside a long bracket string
  is data) **and renames the chunk's own locals to single letters**, then rewrites
  the const in `lua.ws`. `tools/lib/installall.py` does every piece and
  `tools/lib/nametest.py` proves the renamer's refusals bite.
- `lib/constmap.txt` maps a const to its master, and nothing can infer it.** A
  master's minified+renamed text stops matching its const the moment it is
  installed — that is the point of installing it — so the content-matching
  installer written first worked exactly once. Ten consts had no master at all
  before that file existed: readable Lua living only as an escaped string in
  `lua.ws`, so the only way to change one was to hand-edit the escape.
  `tools/lib/constcheck.py` is in preflight and holds both ends (it catches a
  **same-length** change, which a character count cannot).
- **A loader trigger costs ~5 nodes per arm, so fold prefixes where they share
  a piece -- and check collisions against the derived list, not by eye.**
  `srcUses(p, "math.l")` names log AND ldexp in one Find (both live in
  LIB_math_exp, no other math.l* exists): -3 nodes measured.  `srcUses(p,
  "os.d")` names date AND difftime the same way (-3, no other os.d*), and
  `srcUses(p, "raw")` names rawequal/rawget/rawset/rawlen (-3, no other
  raw* global): the fold list is now math.l, os.d, raw.  The same fold
  fails everywhere else -- math.d is deg-only but math.r catches random,
  math.t catches tointeger+type, math.a catches abs, math.s catches sqrt,
  math.c catches ceil, os.c/os.t/os.s are single-member prefixes with nothing
  to fold -- and `:l` as a FIELD would false-positive on `s:len()`.
  `tools/chip/pucsuite.py` derives every member from lua.ws already
  (CHIP_MEMBERS), so the collision check is one command, not a reading.
- **A minified library piece fails SILENTLY, so the net has to be structural.**
  A piece that stops parsing is not an error any program can see: every function
  in it stops answering, with no message and no line — and the same is true of a
  generated prelude in the harvester. Two such bugs were invisible that way and
  both passed 888 cases — a `for i` inside a table constructor, where the
  `{key =}` guard renamed `select(i, ...)` but not its own declaration, and one
  prelude cut mid-brace, which put an **empty log on both engines** and read as
  "the chip cannot run anything". `lua.ws` carries a banner above the const block
  saying all of this; do not hand-edit there.
- **A constructor key is a key at ANY function depth -- and "brace depth
  alone" is not the test.** The `{key =}` guard above fixed the chunk-level
  case with `brace > fdepth`, which worked until a constructor sat inside a
  function body: there brace-depth and function-depth are both 1, the
  comparison failed, and os.date's `*t` table shipped as `{ak = ak,
  al = al, ...}` — compiling, and answering nil for wday/yday. The suite
  caught it (os-date-table); the comment did not — it described the heuristic
  instead of the rule. The rule: a token is in key position only when its
  nearest enclosing `{` was opened at the token's OWN function depth (a stack of
  function-depths, one per unclosed `{`). `tools/lib/nametest.py` proves both depths.
- **IDENTIFIER LENGTH IS NEARLY FREE, so a character count overstates a rename's
  boot win by 10x.** Minifying and renaming all 29 installed pieces took the
  library from 18,736 to 18,115 escaped characters, **−621 (−3.3%)** — and boot,
  measured by running a witness program on both chips in one process
  (`tools/chip/bootprobe.py --chip`), moved only **3,945 → 3,882** and
  **2,216 → 2,176**: 40 to 63 ticks, not the 800 to 1,090 a flat
  `chars × 1.3-1.75` model predicts. The lexer walks an identifier RUN rather
  than each character, so shortening a name saves little; what the rename
  removes is the structural characters around it. Two consequences: budget a boot
  win by measuring it (`bootprobe.py` prints ticks, not seconds), and do not
  mistake a small character cut for a failed optimization — it may be nearly the
  whole of what was available.
- **A gate can be dearer at boot than the piece it would replace.** Measured:
  naming `math.abs` or `math.floor` costs about 474 ticks of boot and
  `math.maxinteger` 923, because `libMathInt` and `libMathConst` are pieces the
  loader pulls in on the name - while `math.random`, a whole piece of its own,
  costs 989. So "a gate is cheaper" has to be argued about ticks per call
  against the piece's boot, never about gates being free.
- A boot cost is only reducible three ways: fewer characters, more chars per
  tick, or not parsing. The middle one is linear in gates (unrolling `lexStep`:
  8 steps +6.5k nodes, 16 steps +19.6k — `tools/chip/lexcost.py`). The cheap end
  is a `Find`-based fast path per region, and **two of the three are now built**:
  a string literal with no escape in it, and a line comment (both above). The
  third is a run ladder for identifiers, which is where the ladder's zero-progress
  trap (below) bites. A `Find` cannot help whitespace, and that is the floor now.
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
  so "an exec gate can never run inside a mod" is false. What fails is the *read*:
  the compiler orders a consumer that is itself an exec gate along the gate's
  ExecOut chain, and the chip's register writes are plain array writes with no Exec
  port, so a value an exec gate produces cannot land in a register in the same
  instruction. An `_rnd` arm written the documented way (`let r = Random(lo, hi)`,
  then `vSetInt(a, r)`) re-ran its instruction to the tick cap. Using one would
  need the two-phase shape `_fmt`/`_pat` use — fire on one tick, read a captured
  output on the next — and a free-running stream would have to fire on every tick
  for every program.
- **A printed line is capped at 64 characters, and the harness caps the oracle's
  the same way.** `oracle_log` applies "the same caps the chip enforces" (one
  tab-joined line per print, `line[:LOG_WIDTH - 1] + "\n"`, 32 appends), so a
  long line matches PUC only up to the cap. Do not read a short line as a lost
  message: check `string.len` on the value first, because the cap hides the
  difference and a DIFF on a long line is usually one character at the
  boundary, not data loss. Measured on `math.random(1.5)`'s 66-character error
  message: whole in the register, chip line ends `...repres`, oracle's capped
  line ends `...repre`.
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
  the port every tick however it was filled, and `innumarr(i)` is a live
  `inNumArr[toInt(iv) - 1]` — one index and one tag write, with no per-element copy
  to remove. So the cost is the CALL: a 64-slot fill is 367 ticks against 205 for
  the same empty loop, **about 5 ticks per element**, and a whole 64-slot write
  is 6.1s in game at 60 ticks/s. `outarr(i, v...)` therefore writes one slot per
  extra value (up to 8) and `innumarr(i, k)` returns k of them, and **measured on a
  64-slot fill that is 367 → 257 ticks, a 30% cut, for 7,272 bytes of chip and no
  new state** — 4.3s in game instead of 6.1s. The read side is much weaker: 544
  → 521, a 4% cut, because a loop that consumes each value spends its ticks on
  the `or` and the add, not on the call. A whole-array setter instead of a wider
  call would have to walk a Lua table in a micro-step machine at 1 tick per
  element: 367 → ~270, a *smaller* cut than the wide call for a new state
  machine, so do not build it. A whole-array `innumarr` read is a **loss** for any
  program that reads fewer than 64, since it pays a table build (193 ticks) to
  save ~2 ticks an element the caller's own loop was going to spend.
- **A sticky input's VALUE comes from the port; only its restart comes from an
  edge — and a suite that always raises a first-sight edge cannot see the
  difference.** The six scalar inputs were latched inside `on Change(port)`, so a
  value already on the port when the chip started was never latched: an edge
  needs a *transition*, and a value that is simply present produces none. In game
  `inStr0` and `inStr1` read `""` while wired to `"test"`, and changed to `hello`
  worked, because that is a transition. 731 cases were green throughout: they all
  deliver their inputs before the first tick, and the sim raises an edge for a
  port's first sight, so every one of them got an edge the real host does not
  raise. The fix seeds the latches from the ports in `on goParse2`'s completion
  branch — a handler body, before `vmReset` copies them into the globals — and the
  edge keeps one job, deciding *when* to restart. `tests/host_compat_check.py`
  runs every input kind with `Sim.host_baselines` on, which models the host that
  baselines silently; it is in preflight because a test nobody runs catches
  nothing. **Two rules from it: read a value, do not wait to be told it; and when
  a bug only appears in game, the sim's assumption that made it invisible is the
  thing to fix, not the case that noticed it.**
- **A port carries ONE wire type, so a second type is a second port — and the
  name a program calls is the lowercase of the port it touches.** `inNumArr` and
  `inStrArr` are two ports rather than one `inArr` that holds either, because the
  type is the port's: `any` cannot even be stored (WS025), so there is no union to
  widen it to, and a program that needs both reads both while one that needs only
  numbers pays nothing for the string half. The naming follows the rule the outputs
  already set — `outNum0`/`outStr0`/`outArr` are written by
  `outnum`/`outstr`/`outarr` — so `inNumArr`/`inStrArr` are read by
  `innumarr`/`instrarr`. The camelCase names a program sees as **values**
  (`inNum0`, `inStr0`) are the port mirrors, which are values and not calls, so
  they keep the port's spelling. Two spellings for one thing is the failure this
  avoids: a program cannot wonder whether `inarr` or `inNumArr` is the call.
- **Every index a program passes is 1-based, and an output is not readable.**
  `outnum(1..5)`, `outstr(1..2)` and `outarr(1..)` all count from 1, the way a
  Lua table does, so `outnum(1, v)` and `outarr(1, v)` are the same slot and
  there is no off-by-one for a program to remember. 0-based was tried and is
  wrong: a Lua author has one indexing rule in their head already. A written
  value is **sticky** - it stays on the port until something writes there
  again, because whoever reads the chip may not be looking this tick
  (`out-sticky-num/-str/-int/-arr` spin 30 ticks and read the port after).
  `vmReset` is the only thing that clears one. Writing is a *call* rather than
  an assignment, so a program cannot read an output back: the ports are not
  globals, and a program that wants the value keeps its own copy.
- **A value count is not an index, and the index is checked first.** The wide
  `outarr`'s range check counts the values, so it is `nargs - 1`: counting the
  index made `outarr(64, -1)` ask for slot 65 and raise, which the demo caught
  because it writes the last slot. And `innumarr(1, 9)` with an *empty* array
  answers nil and never reaches the count guard, so a case for the count has to
  set `innumarr` — two mistakes that each looked like a chip bug and were not.
- **A rarely-taken path does not belong in `vmStep`** — it fires every tick,
  and the old burst inlined it four times. A closure cell-fill there cost every
  program 20% of its per-tick time; moved to `vmBurst` it cost 2,133 nodes
  instead of 3,054 and the tick-bound cases went back to normal.
- **A cached length must follow a delete, and a chase that never fires is not a
  chase.** `#t` is the first nil minus one, and the chip's cached border was wrong
  two ways: it shrank only when the deleted key WAS the border, so `{1,2,3}` with
  `t[2] = nil` read 3 against PUC's 1 (`kint == tLen[tid]` → `kint <= tLen[tid]`,
  no nodes), and it never extended across a bridged gap, so
  `t = {} t[1]=1 t[3]=3 t[2]=2` read 2 against PUC's 3. Five ticks of slack
  changed nothing, so it was not timing: the chase's membership probe re-wrote the
  key format by hand (`tid .. "#" .. n`) and never matched what `tmap` held, so
  `lenChase`/`lenStep` was dead code — and nothing else in the chip used that
  spelling, so nothing caught it. **`tblHas(tid, idx)` asks
  `tmap.get(tkey(tid, 6, idx + 0.0, "")).Found`: one function owns the key format,
  and `get(...).Found` is the membership test that works here (`tmap.has` on a
  concatenated key never fired).** All ten measured shapes now agree with PUC —
  mid, last, first, sparse, append-above, two holes, refill-last, bridge, and the
  bridge again with ticks in between. **When a probe inside a cache never fires,
  find out why before building on it, and when a lookup misses, check that it
  builds its key the way the writer does: a read that works (`t[n]` returning its
  value) is not a proof that a *membership test* on the same key works, and a
  hand-written key that agrees on paper can still miss.**
- Time the *program*, not just the harness: a case going 0.2s → 2s in the suite
  is a user-visible regression, and the suite prints per-case seconds so it
  cannot hide.
- To compare two chips, **alternate them in one process** (a throwaway worktree
  at the previous commit). Run as two separate processes it read 1.66 → 2.22ms
  for a change that was really +7% — drift, not a regression. Compare slopes,
  never one run per chip.

## Chips: the one lever that is nodes down and ticks flat
A `mod` **inlines at every call site**; a `chip` compiles to one shared body.
Converting the duplicated void mods took the chip from **46,151 to 30,397 nodes
(-34.1%)** with **ticks identical on all eight `perfbench` programs** (2,716
before and after) and boot unchanged (demo.lua 2,994 ticks to first output, the
same as before the first chip). 38 chips. `tools/chip/chipscreen.py` lists what
is left and why; `tochip.py` converts with the refusals built in;
`tools/chip/gatesA.py` prices the gate side.

- **A chip costs no tick, but it DOES cost gates.** Both halves matter and they
  point opposite ways. Ticks are what a player waits for; gates are what the
  simulator executes. Chips are flat in ticks and *not* flat in gates, and the
  whole conversion rests on not confusing the two — `perfbench`'s table has **no
  gates column** (its `b/c` columns are ticks, compile and bytecode), so "the
  gates are identical" is not something it can tell you. Measure with
  `gatesA.py`, which counts node executions.
- **The gain and the cost are not in the same mods.** Reverting the three
  register writers (`vSet`, `vSetNum`, `vSetInt`) gives back **15.5% of the
  gates** for 1,280 nodes — 83 nodes per gate-point. The other 35 chips buy
  15,596 nodes for the remaining **6.6%** — 2,363 nodes per gate-point, 28×
  better. So the register-write family is a bad trade and stays a mod, and the
  conversion as it stands is **-34.1% nodes for +3.1% gates**: +3.1% is close to
  noise, +22% was not.
- **The old assumption was expensive.** "A chip call per register write would be
  catastrophic for ticks" is why `vSet` sat at 137 call sites for the whole of
  this work. It is not catastrophic for ticks — it is genuinely bad for *gates*,
  the half of the claim nobody checked. Measure the currency you are actually
  spending.
- **Count INLINED COPIES, not call sites.** A mod's body exists once per call
  site *per copy of whatever calls it*: `emitTok` has 38 call sites but 34 are
  inside `lexStep`, which `lexChunk` called **twice**, so it really existed ~72
  times over. `lexStep` as a chip (-1,638) had already collected that saving, and
  chipping `emitTok` afterwards **added 443 nodes** — one body against 38 sets of
  pin wiring.
- **Measure; the node effect is not predictable from the shape.** `vSet` (137
  sites, 3-line body) is -520 and `emitTok` (38 sites, 10-line body) is +443.
  Both write-only, both take a string, both pure. `doBlockClose` (2 sites, 131
  lines) is +74 while `closeAction` (2 sites, 227) is -836.
- **A chip body may not read-then-write the same shared array element.**
  `bumpMax` is six lines and as a chip it silently empties the whole parse —
  bytecode collapses to a single `RETURN0` and every case reports an empty log.
  Reading a *length* is fine (`emitTok`'s `MAX_TOKENS` guard), pushing and
  popping are fine, reading scalars is fine.
- **A chip body may not read a string global.** `patSetBegin` does
  (`patPat.Substring(...)`) and it breaks the pattern matcher where only two
  cases noticed: `pat-match-set` answered `b` where PUC says `a`. Taking a
  string as a *parameter* is fine — most chips do.
- **A chip must not write state the CALLER consumes.** `andOrArrive` sets the
  shunting-yard scalars the caller reduces with; `saveTmp` clears four arrays
  the paired `restoreTmp` reads; both empty the parse as chips. This is also the
  real reason `patSetBegin` fails — not "same tick", which was wrong: the
  matcher's micro-step reads that state on its next entry.
- **A barrier stays a mod.** `vmReset` is called from `on Change(run)` and
  `on goParse2` and must run at an exact chain point; chip hops shift it and
  `print(3)` comes back empty. Measured, fatal.
- **Chips do not cost the parse a tick either.** Six parse-path chips together
  cost +1 boot tick, and that +1 came from one specific mod, not from the parse
  path as a category: `lexStep`, `locFind`, `closeAction`, `pushOp` and four more
  are all parse-path and all boot-neutral. Re-measure boot with
  `tools/chip/bootprobe.py`, not from memory.

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

The measured traps are in docs/traps.md - the shapes that cost a session each,
and what they look like in the source. `tools/chip/wswarn.py` flags the visible ones.

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
- **A quantifier's lower bound has to be enforced at BOTH ends of the walk, and
  the give-back end is the one that gets forgotten.** `+` was enforced only where
  the item matches nothing at all; once a repetition had happened the give-back
  rewound to zero of them, so `("b"):match("b.+b")` matched and returned a
  **two-character match on a one-character subject**. The floor is where the
  repeat *began*, and it rides in the backtrack entry's item slot — patBack's
  greedy arm never needs `patItemP` back, because `patNextItem` sets it fresh.
  That costs one new entry KIND, no new stack slot and no new arm; a wider entry
  and an extra arm cost the kind-7 arm its `patSp` write and hung every capture
  closing over a repeat.
- **`patSp = sp` is a pop, and `sp` is already the popped pointer.** Writing
  `sp + 4` cancels it, leaves the entry on the stack and spins `patSt 4` for
  ever. It cost four wrong shapes in a row before the stack trace gave it away,
  because `patI` and `patItemP` *did* take effect and only `patSp` did not — so
  it read like the Exec-chain problem the mod header warns about rather than
  arithmetic. `tools/chip/patstack.py` reads `patSl`; `pattrace.py` reads the
  named state and not the slots, and the floor is a comparison between two
  slots, so the slots are the thing to read.
- **Two rules that each cost a session, with the numbers, are in
  `docs/lessons.md`: never hand-keep a mirror of a dict somebody else builds, and
  a reset belongs to the phase that owns the state.** Read it before touching a
  result dict or adding a reset line.
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
- `python -u tools/preflight.py` runs the cheap structural nets (audit, wswarn,
  twopaths, consistency, syntax, hostcompat, ladder, consts) in parallel — that
  plus one suite run is the minimum bar for a change. `wswarn` and `consistency`
  have caught real bugs, so keep them passing rather than skipping them to get a
  green run. `consts` is the newest and the cheapest (0.1s, and it builds
  nothing): every `const LIB_*` must rebuild byte for byte from its `lib/`
  master and every master must have a const, which is what catches a hand-edited
  or stale library piece — invisible from the program, because the piece still
  parses and still runs.
- After changing the sim or the runner, prove the fast path equals the slow one
  (`CHIP_BATCH=1` must give the same OK/FAIL counts).
- **A model of the loop state finds what a diff cannot, and it is cheap** — the
  rules, the two backends' measured split and the syntax traps are all in
  `tools/model/README.md`, so read that before writing one and do not re-derive
  them here. What belongs here is the judgement: a model earns its place by
  finding a wrong assumption in the model, a model that cannot fail is no net
  (each says which line to delete to make it fail), and **a model of the *chip*
  is a different and much more expensive thing** — the chip's constants, the gates
  and the host's laws are not in it, so a green model proves the *rule* you were
  about to encode and nothing about the chip.
- **Skipping work is invisible to the log whenever the work also resets it, so
  assert the COST and not the output.** A re-parse calls `vmReset`, which clears
  the log, so a recompiled program prints *exactly* what a skipped parse prints —
  the log had no way to see a restart re-parsing, and neither did `finished`,
  which is a latch only `reset()` clears and so was still set from the PREVIOUS
  run. A case therefore times a run from the log going empty to non-empty
  (`life-no-reparse-second-run`'s `secondRunUnder`, fitted between 5 ticks to
  restart and 104 to re-parse — a one-line program re-parses in 16, so a
  generous cap passes it), and `python -u tools/chip/restartcost.py` prints both
  costs, the control edit and the per-rep spread, because "noticeably" and
  "reliably" are two claims. **Proved by damaging the chip:** a parse per run edge
  fails with `restart cost [100, 100] ticks, want under 20` while the log and
  `finished` are both correct. Three traps cost that measurement: a value port
  rewritten on every phase edge re-fires `Change(program)`, so the harness
  measures the EDIT while believing it measures the restart — write the port once,
  then only flip `run`; a permissive comparison is invisible while every case
  supplies the value once (all 713 delivered the program from `progText = ""`
  where `program != progText` is true whatever it says), so catching it needed a
  SECOND, different program (`life-edit-while-running`, the only one of 19
  lifecycle cases that fails when the comparison is damaged); and a bound is only
  as good as the measurement behind it, which is why the tool takes `--chip` and
  was aimed at a damaged source to confirm it can report the bad answer.

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
