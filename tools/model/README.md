# Models: what they are for, and what they cost

Two small transition systems in `tools/model/`, checked by
`python -u tools/model/vmmodel.py` through Apalache (or TLC). They encode the
*rules* the chip's loop and pcall machinery must obey, so a wrong assumption
shows up as an invariant violation rather than as a program that prints the wrong
thing. Run with `--damage=<name>` to see that the model can still fail.

| model | what it encodes |
| --- | --- |
| `loopmodel.qnt` | the loop/frame depth invariant: `forDepth` is 0 whenever no numeric loop is live |
| `pcallmodel.qnt` | a protected call's unwinding: the pc, the error, and the frame stack |
| `execmodel.qnt` | the execution contract: termination, determinism, no error accumulation, no corrupted register, IO follows the input, only the needed instructions run, one log entry per print, one read |

A model earns its place by finding a wrong assumption *in the model*: `execmodel`
found that with `errored` set the pc still advanced and a line was still printed,
because nothing stopped the instruction actions — exactly what
`noErrorAccumulation` says.

**A model of the *chip* is a different and much more expensive thing.** The chip's
own constants, the gates and the host's laws are not in the model, so a green
model proves nothing about the chip — it proves the *rule* you were about to
encode, which is what you want it for. Reach for a model when the bug is "the
state is wrong later", not when the program prints the wrong thing.

## Toolchain

Discovery is in `vmmodel.py`, in the order `irdump` uses for the compiler, and it
skips cleanly when a piece is missing — a model that never ran is not a model.
This machine has quint as the standalone `quint-*.exe` release and a Temurin JRE
unpacked into the scratch dir; an earlier version looked for an npm shim and
`JAVA_HOME`, neither of which exists here, so every check was quietly skipping.

## The two backends, and the split between them

Apalache carries every model. TLC cannot carry `loopmodel` at all: it explores
states explicitly, the loop model's lists put it out of reach, and it was still
running after ten minutes at max-steps 8 and again at 5 where Apalache takes 42s.
TLC does check `pcallmodel`'s whole graph in 2.7s (`--backend=tlc`, 28 states,
depth 4, queue empty), but it still needs the Apalache *server*, because quint
compiles the spec to TLA+ with it — with no server up, quint falls back to
spawning one itself, which is the hang to avoid.

## Syntax that will cost you an hour otherwise

In Quint: `if (c) x else y` has **no `then`**; a `val` body is a single
expression (a multi-line `and` does not parse); a `def` cannot recurse; and
`nondet` binds only as `action a = { nondet x = oneOf(S)  all { ... } }` —
`oneOf` outside a `nondet` binding is an error, and a primed name after `nondet`
does not parse.

In Apalache: **a dynamic range is rejected** (`0.to(pc - 1)` is an input error, so
"the executed set is the prefix" has to be
`executed.size() == pc and executed.forall(i => i < pc)`), and **every top-level
`val` is passed as an invariant**, so a helper `val` among them makes Apalache's
parser fail with `key not found` rather than anything that names the cause.
