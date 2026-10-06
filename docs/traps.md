# WireScript traps

Companion to `AGENTS.md`, which stays short. The traps
measured rather than styled; `tools/chip/wswarn.py` flags the visible ones and
`tools/chip/vargraph.py <name>` shows which gate fires each write.  Each one
here cost a debugging session, which is why the wording is specific.

Measured, not style. `tools/chip/wswarn.py` flags the visible shapes;


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
  there. `print`, `outvec`, `outnumarr` and `_s`'s byte-out-of-range all
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
