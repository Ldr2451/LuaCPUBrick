# WireScript traps

Companion to `AGENTS.md`, which stays short. The traps
measured rather than styled; `tools/chip/wswarn.py` flags the visible ones and
`tools/chip/vargraph.py <name>` shows which gate fires each write.  Each one
here cost a debugging session, which is why the wording is specific.

Measured, not style. `tools/chip/wswarn.py` flags the visible shapes;
- **A loop body that reads a `mod`'s parameters reads stale; go through `var`
  storage.** The four register-copy ladders (`retAdjust`, `retCopy`, `vaSpill`,
  `vaFill`) made into `for` bodies that index `dst+j`/`src+j` straight from the
  parameters compiled to plausible node counts, kept the suite's simple cases
  green, and broke exactly the cascading ones -- `local n = tonumber print(n('ff',
  16))` said `attempt to call`, `print(tonumber('ff',16))` said `bad argument
  #1 to 'select'`, audit saw no unknown gate class. `audit.py` cannot see this
  because every gate exists. The shape that works: copy the indices and the
  count into chip-level scratch `var`s (`cpSrc`, `cpDst`, `cpK`, `cpN`) right
  above the loop, cap the count (`let nc = if n > 16 then 16 else n`) and let
  the body read only those. One shared scratch set is safe: a Lua instruction
  runs one arm per tick, and each call site's writes precede its own body.
- **A loop's body is a SHARED microchip, and a body that advances a
  counter the chain reads afterwards is not the same shape.** The screen
  chip's erase walk ran four row-steps per tick, unrolled; made a loop,
  the row counter stopped at 24 of 29 and the chip sat with `erasing`
  true forever -- the walk never finished, the arm never got its
  cancel-roll, and nothing repainted. The same block as a loop over its
  COLUMNS was fine. So the rule is not "loops are safe" but "a loop
  body may compute, not advance": the chain that resumes after the loop
  reads the counter the body moved, and a shared body is a different
  graph from an unrolled one.
- **A loop inside a loop body reads the OUTER index frozen at its first
  publish.** `loop_pins` registers the boundary pins of a loop whose gate
  lives in the root module, and re-snapshots them per iteration; a nested
  loop's gate lives in the outer body's module, so nothing refreshes its
  pins. The screen chip's depth reset as `for row { for col { fbZ[...] =
  ZBACK } }` ran all 4096 body passes and cleared row 0 only -- the inner
  body saw `row` still 0 every time. Measured with a counter in the body:
  4096 writes, one row changed. Take the flat form: one loop over the
  band's PIXELS (`for zk in 0..(rows * 64.0)`, index `oldLo * 64.0 + zk`),
  which costs fewer nodes as well.
- **A `Union` inside a loop body fires on the nodes that ran in the
  tick, not in the body.** The simulator's Union gate fires only when
  one of its inputs is in `fired_nodes`, and the main drain records
  every node it runs there -- but a loop body runs through a different
  path, so its nodes were never recorded, and the Union after a branch
  inside a body never fired. The erase walk's chain stopped at exactly
  that Union.
- **A cached pure gate is fresh only if its ANCESTORS are.** A publish dirties
  the gates wired straight from it, one level; a gate further up the chain that
  already ran in this epoch keeps its old value and reads as fresh. The screen
  chip's lane loop published its `Index`, the `(_lane as float)` convert
  republished, and the arithmetic above the convert -- evaluated in the same
  epoch -- still handed the previous lane's index to the pixel read that blends
  over the destination. Each column was then blended once per lane it had
  advanced: 0.175, 0.2625, 0.30625 ... instead of 0.175 everywhere, which reads
  as a colour-blending bug in the chip and is a cache rule in the simulator.
  **Staleness has to walk the value-input chain** (`_needs_eval`); checking the
  gate's own dirty flag and epoch is not enough.
- **The `.wsir` dump leaves some node ids to the reader, and a reader that
  invents them can collide with the dump's own.** A node may be declared
  without an id (`out %_exec_out exec = %3597` -- the compiler names the
  pin and leaves the id open), so the parser assigns one. It assigned
  `last_id + 1`, which is BELOW the ids the dump uses later: the
  `resolveKw_1` body's output pin took 6162, a later module's node was
  named 6162, and in the flat id space the later one shadowed the pin --
  so the pin vanished, the lexer's return never reached its caller, and
  the parse stopped after one chunk with `jobBusy` stuck true. **Allocate
  invented ids ABOVE every id the dump uses.** A chip that runs its
  first steps and then goes quiet is this, not a missing gate.
- **The `.wsir` dump spells props as bare Rust-Debug strings, so they
  need unescaping like the old `String("...")` form did.** A prop
  spelled `"\n"` is a newline; handing the two characters through
  unescaped made the Lua chip's log arrive as one long line of literal
  backslash-n, which reads like a string-formatting bug and is not one.
- **A `for` loop is a MICROCHIP, and the microchip's body is shared.** The
  compiler lowers `for i in a..b` to a `Component_Internal_Microchip_CountFor`
  gate whose body module holds a `CallableEntry_CountFor` node instead of an
  `_exec_in` pin, so the old call machinery cannot see it at all: the caller
  fires the gate, the gate publishes `Index` on the entry and fires the entry's
  `Body`, and the body's chain runs once per iteration. A simulator that only
  knows `_exec_in` sees an unimplemented gate and a program that never runs.
  The ranges are UPPER-EXCLUSIVE: `for i in 0..10` runs ten times and sums
  45 (`0..9`), which is the compiler's own documented expectation.
  **A plain `chip` call with constant arguments proves nothing** -- the
  certified folder evaluates it at compile time, so the call never reaches the
  chip machinery; a dynamic argument is what exercises the path.
- **A `let` is re-evaluated per use, so a step that writes what its own
  `let`s read composes from a HALF-written matrix.** The chain composition
  wrote `m00..m23` in order while its `n**` lets read `m00..m23`; each cell
  was therefore composed from a mix of the new and old matrix, and only the
  z row showed it (a parent with no z-rotation has `qp10 = 0`, which hid it
  in rows 0 and 1). The symptom was depth that did not match the x/y it was
  divided with: `m20 = qp20 * m00'` and `m23 = qp20*32 + qp21*32`, both
  exactly the half-composed values. **Snapshot the whole pre-step matrix in
  plain vars** and let the lets read the snapshot.
- **A `for` inside a MOD INLINED INTO THE DISPATCH CHAIN stores one iteration
  early.** The same conversion that is safe in the screen chip is not safe here:
  `retAdjust`'s sixteen-step ladder became `for j in 0..16` and the chip went
  42,940 -> 40,883 nodes (-2,057), but the suite came back **835 OK / 149 FAIL**
  and `print(string.upper('abc'))` answered `bad argument #1 to 'string.upper'
  (string expected, got nil)`. Read off the register writes: HEAD copied slot 4
  then cleared slot 5; the looped chip copied slot 4 and then cleared **slot 4**
  -- the body's second branch stored one iteration behind while its first branch
  was right. Two spellings (`else if`, and two separate `if`s) failed
  identically, so it is the body's shape in this position, not the spelling.
  A loop in a plain chip body and a loop in a mod called from a plain body both
  copy correctly; the failure is specific to the sixteen-step ladder sitting
  inside the inlined arms. **Not landed.**
- **Array index WRITES need literal bases -- that was the WS007 rule, and
  the new compiler lifts it.** The screen chip was unrolled per point
  because writes used literal bases; with computed indices the same 256
  writes cost 12 nodes instead of 258. Both `for` loops and `chip` calls
  are available now, so the unrolled copies are a choice, not a
  constraint.
- **A walk that clears its own end flag at the head still leaves it SET:
  the tail of the same tick's chain re-arms it.** The stroke walk ends
  with `if sEnd { sOn = false; sEnd = false }` and the segment check
  below it (`sSeg >= sSegs -> sEnd = true`) runs in the same chain, so
  the ended walk parks with `sEnd` true. A replay arm that re-arms the
  walk without clearing `sEnd` dies on arrival: the drawEdge replay set
  `sOn = true`, the walk's head saw the new value in the same tick, the
  stale `sEnd` killed it, and a bare `drawAllShapes` painted nothing.
  Measured on the screen chip: the staged-stroke replay showed as
  `bursts at []` in the pixel-exact oracle while every arm that DOES
  clear the flag worked. Every arm of a re-arming walk clears every
  leftover state flag of the finished walk, not just the counters.


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
  behaviour, and before trusting a branch in `irsims.py`.
  - **`docs/src/best-practices.md` is the host maintainers' own measured guide to
    gate cost, and it outranks anything we work out ourselves.** Read it before
    optimising: *"What actually costs anything: measured"*, *"Where gates actually
    go"*, *"Gates and ticks are one currency"*, *"Size is usually the real
    constraint"*, and the §1 rule that **every call site is a copy** (so a `mod` is
    inlined and a `chip` is not a shared subroutine). Its other files are worth the
    same: `types.md` (int is a real primitive, i32, and `float` is f64), `builtins.md`
    (the whole gate catalogue), `folding.md` (what the constant folder will and
    will not bake), `exec-context.md` (why an exec gate's value cannot land in a
    register in the same instruction).
  - What it says today:
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
  there. `print`, `outvec`, `outNumArr` and `_s`'s byte-out-of-range all
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
- **The official simulator does not refresh a root reader of a global the
  body of a `chip` writes; the game does.** All fifteen `lexFail` sites set
  `lerr = true` inside the lexStep chip; under `simdrv` the boot guard's
  `lerr` read never flips (per-tick `watch` on the `LogicalNOT` feeding the
  guard: stays `true` the whole run), so `print("a\q")`, `print(1 ~~ 2)`,
  `print(5..3)`, `print([[abc`, `print("\x")` never stop -- boot exits lex on
  EOF only, the parser spins on the token stream, busy stays true -- while the
  game model and the suite answer `err: line 1: ...`. Measured shapes: `lstage
  = 99` inside every `lexFail` site costs +120 nodes (40,482 over the 40,362
  ceiling); a `lexChunk` else-arm costs +1 but never fires because its guard
  reads the same stale root copy. Open direction: the failure flag has to
  cross the boundary on data the pins carry -- e.g. a sentinel token emitted
  at the failure sites and checked by boot/parser -- not a `var` bool.
- **A `chip` boundary is node-POSITIVE for a small mod body, so `chipscreen.py`'s
  site-count heuristic does not price it.** Measured: converting `vSetNum` (36
  call sites, 5 lines) took the chip from 40,351 to **41,359 ir nodes (+1,008)**,
  997 past the 40,362 ceiling, with gates 40,656 to 41,790. A shared body saves
  (sites-1) copies of the body but pays per-call plumbing at every site, and for
  a 5-line body the plumbing is several times the body. Only a mod whose BODY
  node count is a multiple of the plumbing pays; measure with `audit.py` after
  `buildbrz.py`, never from the line count.
- **The official simulator's float→text law is C `%g` at SIX significant digits,
  and no gate gives more.** Under sim 2.5.0 a number that reaches a host text
  gate renders through `concat_display`/`c_g6` (`crates/wirescript-ir/src/
  semantics.rs`) at `%.6g`; `FormatText` is worse (3 decimals, ties to even).
  The 2.0-era model used Rust's `{f}` -- shortest-roundtrip -- so a print pin
  written against the old host (`print(1/3)` wanting `0.3333333333333333`)
  asks for digits the new host's CERTIFIED gates cannot emit; the certified
  table has no number→text gate beyond the six. Fighting that law -- a
  shortest-roundtrip digit machine on the chip side -- measured ~600 nodes
  against 150 headroom, which is what spiralled into a fight. The accepted
  answer takes the law: CHIP_LOG re-pins the float-text class to the host's
  spelling, and fuzz carries the matching `only_float_precision` bucket.
- **Mixed `int`/`float` VALUE signatures are refused by the official simulator
  even though the language promotes them.** `docs/src/expressions.md:117` says
  "Mixed int/float arithmetic promotes the result to float" and the game agrees,
  but the certified table never probed the mixed signature, so the run ABORTS:
  `Expr_MathMultiply ... not certified for inputs (int, float)` (measured at
  `math.mininteger // -1`: the floored-quotient arm's `(q as int) | 0` yields an
  INT value that then multiplies a float register) and
  `Expr_CompareEqual ... (float, int)` (measured at `math.tointeger`). `as float`
  does not help: it costs no gate and leaves the value's variant alone, and
  `w + 0.0` folds back to an int, so the wire still carries an INT. Keep both
  operands in ONE domain where a value can be an INT variant. `tools/chip/bitfloat.py`
  classifies a gate's wired inputs by the TYPE of their source port -- it finds
  0 float-typed wires among the 152 Bitwise gates, so the offenders live in the
  Math/Compare classes.
- **The certified table is per SIGNATURE, and reading it beats guessing.** It
  lives in `wirescript/crates/wirescript-ir/data/gate_semantics.json`
  (`gates`, keyed `BrickComponentType_Expr_*`, each with the probed `cases` and
  their value VARIANTS); `tools/chip/_certprobe.py Floor Ceil Modulo CompareEqual`
  prints the variant pairs a class covers.  Measured readings that cost a session:
  `Floor`/`Ceil`/`Round` cover a FLOAT input ONLY (an INT-fed one refuses, and
  the refusal aborts the run); `CompareEqual` is DIRECTIONAL -- `int/float` is
  certified, `float/int` is not -- so an order that used to work keeps working
  only while the INT stays on the left; `MathModulo` covers `float/float` but its
  LAW (not the table) refuses mixed signs with a nonzero remainder
  (`semantics.rs`: "truncation direction is unprobed"), so `q % 1.0` is not a
  floor for negative q; `MathModuloFloored` covers `float/float` and has no
  operator spelling.  The shape that pays: a floored quotient is ONE `floor(q)`
  gate over a float, and the `(q as int) | 0` + sign-step idiom it replaces was
  FOUR gates that put an INT variant on every wire below it.  Converting the four
  copies (op 12 in both vmStep and vmStepFast, op 34's `//` and the `>>` floor,
  the `math.floor`/`ceil`/`tointeger` block) closed `int-wrap`, `math-tointeger`
  and `math-ult-large` and took the chip from 40,361 to 40,303 nodes.
- **`FromCharCode(0)` cannot spell a NUL byte: the gate's law filters codepoint
  0 and answers the empty string** (`wirescript-sim/src/assumed.rs:150`), so
  PUC's `\0`, `string.char(0)` and `string.format('%c', 256)` all silently LOST
  a byte -- `string.byte('\0')` read nil instead of 0, and `%q` printed the
  string short.  The language can write the byte (`"\0"` is a real character in
  a string literal, `lexer.rs:757`), so the chip routes byte-valued
  codepoint→character conversions through `chrByte`, which answers the literal
  for 0 and the gate for everything else (measured: 3 sites, +16 nodes, and the
  three cases `str-esc-high`, `fmt-char` and `fmt-q-ctl` came back green).
- **A gate that would produce inf or nan is invisible, not wrong: the law either
  REFUSES (the extended float laws end `r.is_finite().then_some`, so MathPow of
  0^-1, MathSqrt of -1, MathLn of 0 abort the whole run) or the value is
  sanitized to 0.0 on the next gate read (`sanitize`, semantics.rs:228) -- so
  `1/0` printed 0.0 and every comparison with it lost, even though the divide
  gate itself answered.** The chip's shape: carry the infinities as the FINITE
  math.huge value and nan as a sentinel constant, test them with the certified
  float/float `CompareEqual`, and print them from fmtNum arms -- the dead `v != v`
  test and the `2.0 * v == v` overflow test could never fire, since the compare
  sanitizes both sides.  Guards are STATEMENT ifs, never if-expressions: a
  Select evaluates BOTH arms, so an expression guard runs the refused gate anyway
  (language reference, "an arm cannot be used to guard another").  Measured:
  closing sqrt/ln/div/idiv/pow domains plus fmtNum arms took 940 to 947 OK and
  the refusal histogram from 8 cases to 1.
- **A gate fed by a constant-folded write runs UNWIRED and refuses: reading a
  var whose value is static per branch (`p == 0.0`, `-p` after the branches
  that set p) folds to a pruned stub, and a Select or phi arm feeding Floor/
  Abs/Ceil refuses the same way (`not certified for inputs (unwired)`).** The
  shape that works is answering the signed constant AT the branch that uses
  the gate -- guard the consumer (`if x == NEGZERO { vSetInt(a, 0) } else if
  abs(fl) ...`), never normalize into a value that flows back into a law gate.
  Measured on the NEGZERO sentinel: powSignedZero's p-flip, a Select-fed floor
  and a var-normalized floor each refused at a different brick; the use-site
  guard compiles and runs.
- **The `info: parse start/end` pair cost ~30 nodes nothing reads, and their
  ServerUptime writes sit between the parse and progDebug; deleting the pair
  (both call sites and the mods) bought those nodes back AND unblocked the
  lex-reject battery -- `progDebugV = dbgStartV` used to mask the first
  `err:`/reject carry-over, six reject cases moved from hang-accepted to
  correct.** progDebug assertions in the suite are substring checks, so
  dropping the two info lines does not touch any pinned answer.
- **An uncertified `Expr_*` gate fed something its laws do not cover ABORTS the
  run, mid-tick -- it does not answer wrong.** `simdrv` prints one line and
  nothing after that tick ever runs, so a program that had already printed its
  answer loses it and the harness reports an empty log. Measured shape:
  `tick 17: Expr_Floor (grid 2 brick 15922): not certified for inputs (unwired)`
  for `inNumArr()` called with no argument -- `fid == 6`'s guard evaluates
  `iv != floor(iv)` and the register behind `iv` is unwired at that moment. The
  usual cause is a non-finite number: `sanitize` (`wirescript-ir/semantics.rs:228`)
  maps anything non-finite to `0.0` wherever a law is scalar, so the divide
  gate's own `inf` survives only until a certified gate reads it, and `1/0`
  arrives downstream as `0.0`. The hand-written simulator checked no
  certification, so these same programs ran on and printed something. Do not
  chase such a FAIL as a log bug: `tests/test_chip_suite.py` now puts the
  engine's line in the verdict and prints an `ENGINE LAW REFUSALS` histogram of
  gate + inputs per run (12 of 985 cases, 6 classes, in the first suite run
  under the official sim) -- the class, not the brick, is the thing to look at.
- **A print dispatch that is a chain of Select arms pays its display body SIXTEEN
  TIMES, and a runtime-bounded `for` over the count is the shape that fixes both
  currencies.** The 16-segment pure expression (`(if 0 < nargs then fmtVal(...)
  else "") .. ...`) materialized the whole `fmtVal`+`fmtNum` chain once per arm
  in the dispatch -- and because Select arms are eager, ALL 16 ran per print at
  runtime, whether or not their slot existed. Rewritten as a `for j in 1..nargs + 1`
  over one shared body with a `printRawV` accumulator: audit 40,782 -> 40,076 ir
  nodes (-706), and `perfbench` evals/tick DOWN on every program in the corpus
  (332.2 -> 325.9, 453.4 -> 444.9, 314.6 -> 306.3 ...), rc=0. This is the one
  dispatch-position loop that landed: the print body is a plain mod body, unlike
  the `retAdjust` ladder inside the inlined arms, whose looped form stored one
  iteration early and came back 835 OK / 149 FAIL. Measure per position, not per
  spelling -- the two shapes sit six hundred lines apart and behave differently.
- **Signed-zero comparisons do not normalize by masking one side; that
  mask loses a real answer.** The first `cmpLtNum` shape was `x < y && x !=
  NEGZERO` (read: "-0.0 < y is false") -- which is wrong: IEEE says `-0.0 < y`
  is true for every `y > 0.0`. fuzz-1342 caught it at `print((-v1) < f0(...))`
  with v1 = -0.0 and a positive right side: chip said false, PUC said true, and
  the suite never touches it because no pinned case compares a negative zero
  against a positive. The rules, spelled at the shared compare sites: `-0.0 < y
  ⟺ y > 0.0`, `x < -0.0 ⟺ x < 0.0`, `-0.0 <= y ⟺ !(y < 0.0)`, `x <= -0.0 ⟺
  !(x > 0.0)`, equality raw plus the zero pair. The rejected alternative was
  one `cmpNum(op, ...)` gate with a literal op argument: the op-branches the
  folder cannot prune were materialized dead, +493 nodes over the ceiling;
  three slim mods (`cmpEqNum`, `cmpLtNum`, `cmpLeNum`) with the rules inside
  landed at +332 and closed `negzero-cmp` without a library change.
- **A floored `%` whose remainder is exactly zero keeps the DIVIDEND's sign,
  and only the floored spelling shows it.** The machine computes `x - floor(x/y)*y`
  in IEEE doubles, so `-2.0 % 2` arrives as `+0.0` (`-2 - (-2)` is `+0` under
  round-to-nearest), where PUC's `luaU_math_modf` takes the C `fmod` -- which
  answers `-0.0` -- and skips the sign adjustment because the remainder is
  zero. Four fuzz seeds (1110/1113/1283/1449) sat in the KNOWN bucket on
  exactly this shape, so the suite needed its own pin: `negzero-mod`
  (`-0.0 % 2`, `-2.0 % 2`, `-1.5 % 0.5`, `1.5 % -0.5`, `math.fmod(-2.0, 2)`,
  and the integer line `2 % -2`, which stays an integer `0`). The rule is
  copysign(0, x) for the zero remainder only -- a nonzero remainder keeps
  the divisor's sign, so the test is `r == 0.0 && x < 0.0` as a STATEMENT
  if inside the float arm (the INT arm is an exact integer zero, no sign),
  never folded into `r`'s value on its way back to a law gate. The arm cost
  +54 nodes (two materializations) and one mod-heavy benchmark program
  moved 318.9 -> 319.8 evals/tick against the interim tree -- against the
  pre-batch baseline every program is still down (325.3 -> 319.8).

Measured, not style -- driver-side traps on the OFFICIAL simulator (the
cpu -> connector -> screen chain). Each cost a session.
- **A `ContainerChange` watch fires only on a CONTAINER WRITE, and swapping
  which container a pin names is not a write.** The engine sets `container_changed`
  from array/map ops (`machine.rs`), so a driver that hands the connector a new
  array by repointing the IN pin (`set` of a pin ref) never fires the connector's
  `on ContainerChange(outNumArr)` -- the chain sits silent through the whole run.
  `val` on the detector brick refuses too ("not a pure gate"), so the fire cannot
  be forced by evaluating it alone either. The driver shape: for each array pin the
  chip ACTUALLY watches, append a `BrickComponentType_Expr_ChangeDetectorExec` on
  the pin's `RER_Output` chained to one `BrickComponentType_Exec_ArrayVar_CopyFrom`
  that self-copies the container the pin now names (`wire_container_feeds`,
  `seed_feed_refs`, per-tick `set_feed_refs` gated by `St.feedWrites`). Chips that
  watch nothing -- the screen reads on `on Clock(interval = 0.01)` -- get nothing
  appended, and must not: the append costs gates.
- **A push-count FAIL in a chain replay is usually the BUDGET, not the feed.**
  cubetest's cube pin wants `2 + CUBE_SPIN` = 10 pushes; at oracle budget 2200
  with the compressed `CUBE_NAP=2` handshake wait, the ORACLE aborts before the
  spin's last two re-pushes (push pulses at 232..2030, the next land at ~2353
  and ~2676), so the rows genuinely carry 8 -- and the connector matches the
  rows edge-for-edge at BOTH counts. Suspect the budget before the feed: print
  the oracle's last tick, the push-edge list, and compare with budget + tail.
  At the gate's own parameters (4200/600) the replay reaches 10 pushes and the
  body is GREEN.
- **The official engine stores Color channels as FLOAT32; the IR probe reads
  `0.95000004768...`, and the adapter must quantize at the boundary.** Read
  colors back with `%.6g` (`irsims._wire_to_value`) -- the same display class
  as the sim 2.5 `%g`-6 print law, documented and accepted there -- and this
  is what turned ghostprobe GREEN. Left un-quantized, every exact-color pin
  in the screen chain fails by noise, not by logic. The second half of the
  class: the chip's colour chain crosses several Color() rejoins (corner,
  slot, composite, dim), each one f32 rounding, so a BLENDED pixel carries
  4..10 f32 ulps against the test model's single f64 expression -- ~1.2e-6
  on a channel near 1.0, past what a %.6g read comparison can bridge (the
  roundings land ON the sixth digit). Stroke-colour pins compare channel-
  wise within 1e-5 (painttest's `close`); exact decimal colours still pass
  at 1e-9 because f32-exact channels land clean through %.6g. Mirroring
  every rejoin in the model is the spiral to avoid.
- **`_Arrays.__setitem__` filling an un-staged `LinearColor` slot with a bare
  number aborts the sim with `array value is not an array`; white `[1,1,1,1]`
  is the fill.** A staged array carries colors only where the program wrote
  them; the untouched tail needs a COLOR-shaped value, not `0.0`.
- **The certified-table refusals ride into the chain the same way they rode
  into the chip: `(x | 0)` over an int is the refused `float|int` BitwiseOR
  signature, and color arithmetic is no certified `Math*` signature at all.**
  `connector.ws` needed the same rewrite the screen fill path carries: the
  terminator scan `(x | 0)` -> `(x as int)` at 20 sites; color math goes
  channel-wise and rejoins at `Color()`. `ColorBlend` is certified but
  DEFERRED in the table -- component-wise scalar math is the only certified
  form to use.
- **The probe-label route for globals read remotely is the compile's IR TEXT
  (`compile --emit-ir`) paired by kind group, not the `.brz` labels, and a
  `new` whose counts do not pair REFUSES.** That refusal is the stale-`.brz`
  signal: rebuild through `tools/lib/libconst.py` before pairing, never
  hand-patch the built file. Name->gate pairing uses `base = loaded.graph.gates
  .len()` so `feed_ports` clones never pair, and the probe scan must run BEFORE
  the clone loop in `replay`.
