# Two lessons that cost a session each

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
