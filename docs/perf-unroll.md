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

Landing two steps fails `upvalue-read` and `upvalue-write` with an **empty log** —
the program does not run at all, so this is not a slow path, it is a broken one.
It was reverted rather than shipped.

What that points at: `vmBurst` gives a closure cell-fill the whole tick
(`if cloActive { cloStep() }`), and a second `vmStep` in the same tick is the
first thing that has run two dispatches back to back since the closure work
landed. The dispatcher ends with

```
if !advanced && !vmHalted { vmPc = vmPc + 1; if vmPc >= bop.length() { vmHalted = true } }
```

so a step that moves `vmPc` itself has to write `vmPc = vmPc + 1` *and* set
`advanced = true` — one alone stalls, the other double-advances. That rule is
about a single step; a second step in the same tick re-reads `vmPc`, `advanced`
and `vmHalted` written by the first, and a cell-fill or a `GEN` that expects one
dispatch per tick is exactly the state that a second dispatch can invalidate.
The two failing cases are both upvalue cases, which is the right neighbourhood
for that theory and the wrong place to stop guessing.

So the unroll is two problems, not one: the size (measured above, 2.56x at four)
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
