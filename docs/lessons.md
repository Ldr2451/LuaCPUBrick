# Lessons that cost a session each

Companion to `AGENTS.md`, which stays short. Both of these were found on
2026-09-26 while chasing "the first `run` toggle does nothing"; each one sent the
investigation in the wrong direction for about an hour, which is why they are here
rather than forgotten. `tools/agents_nums.py` reads this file as well, so a
measurement quoted here still counts as kept.

## Never hand-keep a mirror of a dict somebody else builds

`run_in_sim` in the test suite rebuilt its result's `outGlobals` by listing the
ports by name:

```python
"outGlobals": {"outNum0": og.get("outNum0", 0.0), ... "outInt0": og.get("outInt0", 0),
               "outCol": list(og.get("outCol", [0.0] * 4)), ...}
```

The list outlived two deleted ports. It still carried `outCol` (gone with the
colour port) and `outInt0` (gone with the int removal), and it had no `outNum4`,
so four cases read **0.0 for an output the chip was writing correctly**:

```
out-nums   got=[1.0, 2.5, 1.0, 0.0, 0.0, '', '']  want=[1.0, 2.5, 1.0, 0.0, -3.5, '', '']
```

Meanwhile a direct probe of the *same program text* on a fresh sim read -3.5, and
the chip, `chip_ports`, `sim_inputs`, the case text and the graph were each
verified good in isolation. It first sent me after a "the tests are running a
stale graph" theory — which a net added during the same hunt disproved, because a
suite worker's graph matches the source port for port. The old port list had come
from a throwaway probe whose environment I never isolated from the suite's.

The fix is one line, and the rule is the shape of it: **the values belong to
whoever built them** (`og` straight through) and **the shape belongs to the one
place allowed to know about ports** (`chip_ports`). A second list is a second
source of truth, and this one fails silently — it does not raise, it answers 0.0.

The same argument is why the graph is now compared with the source's port
declarations in `tests/test_consistency.py` (`graph-inputs-match-source`,
`graph-outputs-match-source`) and once per suite worker
(`_assert_graph_is_this_chip`). Both nets exist because of the mirror.

**And the mirror itself now refuses to answer.** Those two nets compare the
graph against `lua.ws`, but the mirror had already drifted *inside* the suite
before either net ran, so the list itself had to become incapable of the
failure: `chip_ports` reads each named port through `_port`, which raises if the
graph does not have it. `og.get(name, default)` is the shape of the bug, not a
way to write the fix — a default is an answer, and the wrong answer is silent.
This was not hypothetical the second time: removing `outNum4` meant deleting a
port, and a `chip_ports` still naming it would have read 0.0 forever with no
case failing.

## A reset belongs to the phase that owns the state

`parseInit` cleared `lerr`, `lerrMsg`, `lerrLine` and `lline` but not `lstage`.
That looks like an oversight — a parse that fails mid-token leaves the lexer's
state machine mid-token, and the next parse resumes from there with `lpos` back
at 0 — and the fix is one line.

It is the wrong fix, for two measured reasons.

- `on goParse` is the lexer's entry, and it already does `lpos = 0; lstage = 0`
  where it sets up the source. The reset belongs to the phase that owns the
  state, so the copy in `parseInit` was a **duplicate assignment, not a cheap
  safety net**.
- The only measurable effect was size: **619,507 bytes with the line, 620,027
  without**. That is the constant folder deleting one of two identical assignments
  and whatever it made dead — a compiler artefact, which is not an argument for
  keeping a line.

The way to tell the difference between "a missing reset" and "a redundant one" is
to go looking for a case that needs it, and there is none: six rejections that die
*mid-token* — in-string (left at `lstage` 4), mid-hex (11), mid-exponent,
long-string, after-dot and mid-name — all recover with the line and without it.
Those six are also what finally showed the reset was not a reset at all.

So: before adding a reset line, find the owner. If the owner already resets it,
you have found a duplicate assignment, which is a smell that the ownership is
unclear. That is worth more than the 520 bytes, and it is the same rule as
"delete cleverness the moment it proves unreliable".

## A read in exec context costs a gate; the same read in pure context does not

From the host docs, `docs/src/exec-context.md`:

> Even pure expressions like `x * 2` use a `Var_Get` gate (exec) to read `x` when
> inside an exec context. [...] In pure context, `x` reads directly from the
> PseudoVar's `Value` port (no exec gate).

`vmStep` is exec context, so every `vNum(b)` / `vTag(b)` / `vStr(b)` inside an arm
spawns its own `Var_Get`. The four register accessors are 8,008 nodes and they are
the third largest group in the census, so this is where a source-level change pays:
an arm that reads the same register three times should read it once into a `let`
and use that, because the `let` is one gate and the three reads are three.

This is the shape to look for in the expensive arms, and it is measurable with
`tools/chip/armcost.py` on the arm and then on the hoisted version. It is also the
same family as everything else in this file: a second source of truth - three reads
that should be one - failing silently, in this case as gates rather than as a wrong
answer.

The related folding lever, from `docs/src/folding.md`, is annihilators: `if false
{ heavy() }` drops the whole exec chain including anything inlined there, and `&&`
and `||` fold against a certified constant. Nothing in the chip's hot path sits
behind a compile-time-constant condition - the expensive arms are all behind
`op == N` - so that one is available but unused, and worth remembering if a future
arm ever gets a constant guard.

## The duplicate read is already shared - measured, twice

Following up the exec-context note, the same hoist was tried the other way too,
as a real \let\ in front of the condition, in the comparison arm (the best site:
it is in vmStepFast, so five times a tick):

    let bv = vNum(b)
    let hit = if op == 18 then bv < rv else bv <= rv

which is 675,312 -> 678,330 bytes. Bigger, not smaller: the \let\ costs more than
the read it removes, so the compiler is already sharing the two \Num(b)\ reads.

So both routes to that saving are dead - a wrapper mod because a mod is inlined
at its call site, and a \let\ because the read was never duplicated in the graph.
The apparent redundancy in the SOURCE is not redundancy in the gates, and the
lesson is the same one the register-accessor numbers teach: measure before
believing a shape is expensive. Reverted, and recorded here so the next person
does not spend an hour on it.

## Boot cost is measured by running it, not by subtracting two totals

The library-piece boot charge ("a piece is charged by the character AND
by every function it defines", in AGENTS.md) was, for a while, derived
by subtraction from whole program boots, and both terms were wrong by a
factor of three to ten. The old numbers came from splitting measured
program totals by subtraction (tonumber 760 chars/2 functions = 583
ticks = 190 + 2×197; math.random before it was inlined 1,140/3 = 1,130
= 285 + 3×282; string.gsub 2,783 chars and 2,933 ticks, which fits ~8
functions) and they do not survive a direct measurement: 760 characters
at 1.75 ticks is 1,330 ticks of parse on its own, more than the 583 the
whole program took. So the escaped-char count is probably not what gets
spliced, or those totals were deltas against a baseline that had already
paid for shared library text.

The one old number that WAS a delta agrees with the direct measurement:
inlining `math.random`'s generator (randomseed does not draw) took it
from 3 functions to 2 and its boot from 1,130 ticks to 989, and 141
ticks is 2.3s at 60 ticks/s for a program that names it once.

Measured directly, and deterministic to the tick (`tools/chip/lexrate.py
lib/piece.lua`), the real charge is 1.30 to 1.75 ticks per character of
real source and 24 to 62 ticks per function (an empty one 24, one with
a parameter, a local and a return 62); the old rule said `C/2` from the
scan floor, which is what a character that lexes to no token costs, and
~280 ticks a function. The first question about a piece is therefore how
long it is, not how many functions it has: the character term dominates,
and eight functions is 200-500 ticks on top.

The lesson: **derive a price by measuring the thing, not by subtracting
two totals** - the subtraction assumes the parts are independent, and a
piece's boot is its whole dependency chain, so they are not.
