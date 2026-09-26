# The unroll, measured on this chip (2026-09-26)

The 4x `vmStep` unroll was worth ~59k nodes on a 37,899-node chip, so it looked
affordable. Measured on the chip as it stands it is not, and it is not free
either. Both numbers are below; the second one is the reason nothing was landed.

## Cost and speed, 1 / 2 / 4 calls per tick

| steps | `lua.brz` | nodes | wires | loop-60 | fib(18) | strings |
|---|---|---|---|---|---|---|
| 1 | 620,027 | 39,305 | 81,821 | 197 | 19,999 (no answer) | 251 |
| 2 | 919,052 | 60,840 | 127,935 | 132 | 19,999 (no answer) | 195 |
| 4 | 1,586,188 | 103,908 | 220,161 | 100 | 15,784 -> `2584` | 167 |

`loop-60` is `local s = 0 for i = 1, 60 do s = s + i end print(s)`; `strings`
builds twelve short strings and takes their lengths. Tick counts are the sim's, so
they are the in-game number: a tick is 16.7 ms whatever the chip does.

Read three ways:

- **The old estimate was for a different chip.** One step is 39,305 nodes here, so
  each extra copy is ~21,500, and four steps is **2.56x the artifact** rather than
  the +19k the old table suggested. The growth is `vmStep` itself: the fifth
  numeric output, the removed int port, the wider `outstr` arm.
- **Two is the knee on speed.** +48% size for **1.49x** on a numeric loop; four is
  +156% for 1.97x. Diminishing, as expected when the copies are identical.
- **Four is the only one where a call-heavy program finishes at all.** `fib(18)`
  does not answer within 20,000 ticks at one or two steps, and answers at 15,784
  with four. That is a capability threshold, not a speed difference: the register
  VM spends most of its ticks in call/return, and one instruction per tick is
  below what a call-heavy program needs to finish. So the honest question is not
  "how fast do loops get" but "do we need call-heavy programs to terminate".

## The unroll is not free: two calls break the upvalue cases

Landing two steps failed at first, and that was the real half of the problem:
upvalue-read and upvalue-write came back with an EMPTY log, so a second dispatch
was not a slow path, it was a broken one. The cause was one misplaced check, and
it is the same rule as the lstage reset: THE CHECK BELONGS TO THE PHASE THAT OWNS
THE STATE. cloStep() was called only from vmBurst, so with one dispatch per tick
the cell-fill guard and the dispatcher were the same thing; with two they are not.
A second vmStep() in the same tick dispatched straight into the opcode chain while
a closure was half-built, the fill never finished, the closure was never
published, and every program that read an upvalue produced nothing at all.
Moving the guard into vmStep fixed it, and with it the whole unroll:

| steps | lua.brz | nodes | wires | loop-60 | fib(18) | closures |
|---|---|---|---|---|---|---|
| 1 | 620,027 | 39,305 | 81,821 | 197 | no answer | - |
| 2 | 930,432 | 60,672 | 128,433 | 128 | no answer | ok |
| 4 | 1,598,905 | 104,949 | 222,375 | 96 | 15,782 -> 2584 | 222 -> 41 |

Four steps is 2.05x on a loop, and it is the only setting where a call-heavy
program finishes at all, so the capability threshold and the speed win point the
same way. The partial unroll below was designed to get most of the loop win for
about 7% of the price; the full 4x is landed instead, and the partial idea is only
worth reviving if the size has to come back down.
and a correctness question that has to be answered before any of it can land.
`tools/chip/modcost.py` and `tools/chip/armcost.py` are how the cost half was
measured; the correctness half needs the two failing cases as the spec.

## The partial unroll: the design, and the trap that makes the obvious shape wrong

Copying the *whole* chain is what makes four steps cost 64,603 nodes, and the
chain is wildly unequal. A `vmStepFast` that carries only the cheap arms would be
about 1,073 nodes per copy, so four copies plus one full `vmStep` is ~44,000
against the 103,908 the full unroll reaches.

**The trap: omitting an arm silently skips its instruction.** The tail is

```
if !advanced && !vmHalted {
  vmPc = vmPc + 1
  if vmPc >= bop.length() { vmHalted = true }
}
```

`advanced` is set by the arms that move the pc themselves, so a step that matches
no arm leaves it false — and the tail then advances the pc **past an instruction
that never ran**. A fast step therefore cannot share that tail. It needs its own
`handled` flag, set only by the arms it actually contains:

```
mod vmStepFast() {
  if vmHalted { return }
  let op = bop[vmPc]
  let a = bpa[vmPc]
  let b = bpb[vmPc]
  let c = bpc[vmPc]
  var handled = false
  if op == 1 { ...; handled = true }
  else if op <= 7 { ...; handled = true }
  ...                                   // only the cheap families
  if handled && !advanced && !vmHalted {
    vmPc = vmPc + 1
    if vmPc >= bop.length() { vmHalted = true }
  }
}
```

and `vmBurst` becomes four `vmStepFast()` calls and one `vmStep()`, so a `CALL` or
a `RETURN` falls through all four and is executed by the full step, while loads,
arithmetic, comparisons, jumps, unary and the numeric `for` get four dispatches
for the price of one arm each.

The arms to carry, with the measured cost each contributes: loads 1-7 (568),
comparisons 17-19 (178), jumps 20-22 (35), unary 14-15 (142), numeric `for` 32/33
and 50 (150), and arithmetic 8-13, which is already a single arm and so is the
biggest win per node in the set. Left single-copy on purpose: `CALL` 23/41 (5,467),
the four return arms (2,417), `TAPPEND` 44 (2,507) and the gate dispatch itself.

**Two things this does not solve.** It shares the closure hazard with the full
unroll — `upvalue-read` and `upvalue-write` come back with an empty log at two
steps, and that has to be understood first, because a partial unroll still
dispatches twice in a tick. And the call-heavy case gets nothing from it:
`fib(18)` only finishes at four full steps, and `CALL` is deliberately not in the
fast set. So the honest pitch is *loop and straight-line speed at ~7% of the full
unroll's price*, not "the 4x, cheaper".

## Where the 4x actually went: the node census

The compiler prints a source line per node, so ONE build attributes every node to
the mod that emitted it (102,296 of 104,949 attributed; the rest are ports and
literals). At the landed 4x:

| mod | nodes | call sites | per site | what it is |
|---|---|---|---|---|
| retCopy | 7,660 | 4 | 1,915 | 16-value return copier, 3 arrays x 16 unrolled |
| vmFail | 5,849 | 115 | 51 | the error raiser |
| tblSetKey | 5,645 | - | - | one table store; TAPPEND calls it 16 times |
| retAdjust | 5,144 | 6 | 857 | sixteen unconditional ifs |
| vmStep | 4,841 | 4 | 1,210 | the chain's own arms |
| gateHigh + gateLow | 5,110 | 4 | 1,278 | builtin dispatch |
| vSet + vNum + vTag + vStr | 8,008 | many | - | the register-file accessors |

Top ten mods are 43% of the chip. **The unroll did not duplicate the dispatch - it
duplicated the HELPERS**, because the cheap arms call `vSet`/`vNum`/`vTag`/`vStr`
and every error site calls `vmFail`. That is why a "partial" unroll carrying only
loads and arithmetic still pays most of the accessor cost, and why cutting Lua
features is the wrong lever: `assert` is 1,381 of 104,949.

The actionable number is `retCopy`: 4 call sites, 1,915 nodes each, for a ladder
that moves `n` values in three parallel arrays. Returns are usually 0-3 values, and
`AGENTS.md` already records the fix for two callers that know their count (428 and
400 nodes for copy-only paths). Specialising the remaining sites by count is the
largest single identified saving, and it is the same shape as a decision already
made and measured twice in this chip.
