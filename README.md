# Lua 5.5 on a Brickadia chip

`lua.ws` is a Lua 5.5 interpreter built as a Brickadia WireScript chip: a lexer, a
compiler, a register VM and the standard library, all in one net. `irrun/`
simulates it a tick at a time, and `tests/` compares the chip against the real
`lua5.5` binary, which is the only authority on what the chip should do.

```
lua.ws          the chip: lexer, compiler, VM and library
demo.lua        a small program to try in-game
irrun/          the simulator: IR loader, tick sim, gate catalogue
tests/          the suite and the oracle-diff checks
tools/          development tools (see below)
```

## VM ISA

The compiler emits one flat bytecode program; function bodies are interleaved in
the same instruction stream. Instruction `pc` is the tuple
`(bop[pc], bpa[pc], bpb[pc], bpc[pc])`. The four arrays are parallel and every
instruction occupies one position, including instructions with no operands.
Jump targets are absolute bytecode indices. `tools/dump_vm.py` prints these
raw tuples.

The principal limits are 1,024 instructions, 4,096 tokens, 64 registers per
function, 96 functions, 96 globals, 32 active call frames, 64 tables, 512 table
entries, and 16 values in one expanded call, return, or statement. Numeric and
string constant pools each hold at most 256 entries.

### Values and registers

A register is a `(tag, num, str)` triple:

| tag | Lua type | payload |
| ---: | --- | --- |
| 0 | nil | ignored |
| 1 | number | floating-point `num` |
| 2 | string | `str` |
| 3 | boolean | `num`: zero is false |
| 4 | function | closure number in `num` |
| 5 | table | table ID in `num` |
| 6 | integer | internal numeric subtype in `num` |

Tags 1 and 6 both satisfy Lua's number checks. Integer arithmetic preserves
tag 6 and wraps at the signed 64-bit boundaries; division and exponentiation
produce tag 1. A function value stores a closure number. Closure numbers below
`cloBase` are capture-free prototypes; captured functions receive closure
records at runtime.

Register operands are relative to the current frame. Their physical index is
`vmBase + register`. Calls and returns use a parallel frame stack containing the
closure, frame base, result destination, caller base, continuation PC, requested
result count, and vararg origin. Fixed parameters are copied down from the call
arguments; extra arguments are ignored by fixed-arity functions and spilled by
variadic functions.

### Opcodes

In the table, `R` means a frame-relative register. Unless an instruction writes
`vmPc` itself, the dispatcher advances the PC once after executing it.

| # | name | operands | effect |
| ---: | --- | --- | --- |
| 0 | `HALT` | none | Halt execution. Handled defensively; the compiler normally ends with `RETURN0`. |
| 1 | `LOADNIL` | `A=Rdst` | Write nil to A. |
| 2 | `LOADNUM` | `A=Rdst, B=numeric constant, C=kind` | Load a number; `C=1` selects a saturating integer load. |
| 3 | `LOADSTR` | `A=Rdst, B=string constant` | Load a string. |
| 4 | `LOADBOOL` | `A=Rdst, B=boolean` | Load false when B is zero, true otherwise. |
| 5 | `LOADGLOBAL` | `A=Rdst, B=global slot` | Copy a global into A. |
| 6 | `STOREGLOBAL` | `A=global slot, B=Rsrc` | Copy B into a global or its typed output port. |
| 7 | `MOV` | `A=Rdst, B=Rsrc` | Copy a complete value. |
| 8 | `ADD` | `A=Rdst, B=left, C=right` | Numeric addition with integer-tag preservation. |
| 9 | `SUB` | `A=Rdst, B=left, C=right` | Numeric subtraction with integer-tag preservation. |
| 10 | `MUL` | `A=Rdst, B=left, C=right` | Numeric multiplication with integer-tag preservation. |
| 11 | `DIV` | `A=Rdst, B=left, C=right` | Floating division. |
| 12 | `MOD` | `A=Rdst, B=left, C=right` | Floored remainder. |
| 13 | `POW` | `A=Rdst, B=left, C=right` | Floating exponentiation. |
| 14 | `UNM` | `A=Rdst, B=Rsrc` | Numeric negation. |
| 15 | `NOT` | `A=Rdst, B=Rsrc` | Logical negation; only nil and false are false. |
| 16 | `CONCAT` | `A=Rdst, B=left, C=right` | Concatenate strings or numbers. |
| 17 | `EQ` | `A=Rdst, B=left, C=right` | Untyped equality. Numbers compare across tags 1 and 6. |
| 18 | `LT` | `A=Rdst, B=left, C=right` | Numeric or lexicographic less-than. |
| 19 | `LE` | `A=Rdst, B=left, C=right` | Numeric or lexicographic less-or-equal. |
| 20 | `JMP` | `A=target` | Unconditional absolute jump. |
| 21 | `JMPF` | `A=target, B=Rtest` | Jump when B is false. |
| 22 | `JMPT` | `A=target, B=Rtest` | Jump when B is true. |
| 23 | `CALL` | `A=callee/result base, B=argument count, C=flags` | Call `R[A]` with arguments `R[A+1]` through `R[A+B]`; place results from A. |
| 24 | `RETURN` | `A=Rvalue` | Return one value and restore the caller. |
| 25 | `LOADFUNC` | `A=Rdst, B=prototype` | Publish a function value; captured closures are filled incrementally. |
| 26 | `RETURN0` | none | Return no values. |
| 27 | `RETURNV` | `A=result base` | Forward the preceding call or vararg result block. |
| 28 | `NEWTABLE` | `A=Rdst` | Allocate a table. |
| 29 | `GETFIELD` | `A=Rdst, B=table/string, C=Rkey` | Read a table field; strings use the runtime string library. Missing keys produce nil. |
| 30 | `SETFIELD` | `A=Rtable, B=Rkey, C=Rvalue` | Write a field; a nil value deletes the visible key. |
| 31 | `LEN` | `A=Rdst, B=table/string` | Write a length. |
| 32 | `FORPREP` | `A=Rcontrol, B=Rlimit, C=Rstep` | Validate a numeric loop, calculate its remaining iterations, and push loop state only when it has at least one iteration. |
| 33 | `FORLOOP` | `A=body target, B=reserved, C=Rstep` | Advance the control register, decrement the remaining count, and jump while iterations remain. |
| 34 | `IDIV` | `A=Rdst, B=left, C=right` | Floored division. |
| 35 | `BAND` | `A=Rdst, B=left, C=right` | Integer bitwise AND. |
| 36 | `BOR` | `A=Rdst, B=left, C=right` | Integer bitwise OR. |
| 37 | `BXOR` | `A=Rdst, B=left, C=right` | Integer bitwise XOR. |
| 38 | `BNOT` | `A=Rdst, B=Rsrc` | Integer bitwise complement. |
| 39 | `SHL` | `A=Rdst, B=left, C=shift` | Integer left shift. |
| 40 | `SHR` | `A=Rdst, B=left, C=shift` | Integer right shift. |
| 41 | `CALLM` | same as `CALL` | Call with all results requested. Implemented as an opcode but not currently emitted. |
| 42 | `RETURNM` | `A=fixed base, B=count, C=tail base` | Return `B` fixed values when non-negative, or `-B` fixed values followed by the result block at C. |
| 43 | `ADJUST` | `A=source, B=destination, C=count` | Normalize the preceding result block into C registers, nil-filling missing values. |
| 44 | `TAPPEND` | `A=Rtable, B=result base, C=maximum` | Append the preceding expanded result block to a table. |
| 45 | `VARARG` | `A=Rdst, B=count, C=unused` | Copy all varargs when B is zero, otherwise copy B values. |
| 46 | `GETUP` | `A=Rdst, B=descriptor, C=kind` | Read a captured local; kind 0 is current-frame and kind 1 is inherited. |
| 47 | `SETUP` | `A=Rsource, B=descriptor, C=kind` | Write a captured local and mirror current-frame writes into its register. |
| 48 | `GETCLO` | `A=Rdst` | Read the current closure number, used by recursive local functions. |
| 49 | `GEN` | none | Advance the loop-round generation used to give closure cells fresh identities. |

### Operand encoding

Several operand fields are overloaded:

- For arithmetic opcodes 8-13, `C < 0` encodes a numeric immediate. Set
  `packed = -1-C`; the constant index is `packed >> 1`, and the low bit marks an
  integer constant. The compiler uses this form when folding a temporary
  numeric load into its consumer.
- For comparisons 17-19, `C = -1-constant_index` encodes a numeric immediate on
  the right.
- A generated numeric `LE` immediately followed by `JMPF` may store
  `A = -1-target`. On true it advances over the branch; on false it jumps
  directly to the target. This fused form is not used for string comparison.
- `CALL` flags are bit 0 for an expanding final argument and bit 1 for all
  results. `CALLM` behaves as if bit 1 were set.
- `RETURNM` supports at most 16 total fixed and tail values. When the fixed and
  tail blocks overlap, the tail is copied before the frame switch.
- `retCountV` records how many values the latest call or vararg actually
  produced. `ADJUST`, `TAPPEND`, `RETURNV`, and `RETURNM` infer the producer
  from bytecode adjacency; an expanding result block must be consumed by the
  instruction immediately following its producer.

Source-level `>`, `>=`, and `~=` lower to swapped `LT`/`LE` and `EQ` followed by
`NOT`. `and` and `or` lower to conditional branches plus `MOV`.

### Calls, closures, and asynchronous states

A normal call lays out `R[A]` as the callee and first result, followed by its
arguments. The callee frame starts at `vmBase + A`; arguments are copied into
the callee's fixed parameters and any variadic tail is spilled. A normal Lua
call switches to the function's bytecode entry and records the caller PC. Gate
builtins run in the caller's frame and return to the same dispatch slot.
`pcall` and `xpcall` push a protected-frame marker; errors unwind one real frame
per tick until that marker.

The vararg stack doubles as the closure-cell arena. Each frame reserves its
frame sequence, three-word entries for captured locals, and then its live
varargs. A stamp prevents a new frame from adopting an earlier frame's cells,
and the generation counter gives cells made by separate loop rounds distinct
identities. `GETUP`, `SETUP`, `GETCLO`, and `GEN` implement this machinery.

Some operations take more than one VM step and install an internal state before
normal opcode dispatch resumes. These states cover protected-call unwinding,
`next`, table-length chasing, formatting, pattern matching, gmatch, string
comparison, and incremental closure construction. They are execution states,
not additional bytecode opcodes.

Every ordinary instruction falls through to this common rule:

```text
if not advanced and not halted:
    pc = pc + 1
```

An instruction that writes `pc` must also mark itself advanced. Falling past
the end of the bytecode halts execution.

## Running the tests

```sh
python -u tools/preflight.py                  # fast net: static checks + parser battery
python -u tests/test_chip_suite.py            # every case, chip vs Lua 5.5
python -u tests/test_chip_suite.py iter-      # only cases matching a filter
python -u tests/test_consistency.py           # static structure vs tests/spec.py
python -u tests/syntax_check.py               # parser stress, oracle diff
python -u tests/iter_check.py                 # iteration library, oracle diff
python -u tests/multi_check.py                # multiple returns, oracle diff
python -u tests/vararg_check.py               # varargs/select, oracle diff
python -u tools/fuzz.py 200                   # random programs, oracle diff
```

`tools/preflight.py` is what to run after every edit to the chip. The parser
keeps its scratch state in globals, so a change tends to break the constructs
*around* it rather than the new feature; the preflight catches that in about
half a minute instead of the suite's half a minute of guessing. It is not a
substitute for the suite -- it checks shapes, not results -- so run the suite
before committing.

Every script prints its elapsed time. The suite needs a Lua 5.5 binary: it looks
at `$LUA55`, then `lua5.5`/`lua55` on `PATH`, then the usual install locations,
and SKIPs if it finds none.

Useful environment variables:

| variable | effect |
| --- | --- |
| `LUA55` | path to the oracle binary |
| `WIRESCRIPT` | path to the `wirescript` compiler |
| `CHIP_BATCH` | cases per suite worker process (default 12, `1` = one per process) |
| `PROBE_TICKS` | tick budget for `tools/check.py` |
| `TRACE_TICKS` | tick budget for the two trace tools |

## Tools

Iterating (each builds the chip once, ~6s, then runs many programs):

| script | what it does |
| --- | --- |
| `tools/check.py "prog" "prog" ...` | run programs on the chip, diff against the oracle |
| `tools/dump_vm.py "prog"` | dump the bytecode a program compiles to |
| `tools/dump_vm.py --tokens "prog"` | dump the token stream and the prepended library source |
| `tools/trace_pc.py "prog" "0,1,2"` | step the VM, printing pc, frame and chosen registers |
| `tools/trace_exec.py "prog"` | which chip nodes execute, in order |
| `tools/profile_sim.py "prog"` | where a run spends its ticks |

Checks on the chip itself:

| script | what it does |
| --- | --- |
| `tools/audit.py` | one build, then: compiler `_Unsupported` placeholders (a silent miscompile), gate classes the simulator has no handler for, and the node/wire count |
| `tools/globals.py "prog"` | the global slot table after a run |
| `tools/slots.py` | builtin ids and the global init arrays, from the source |
| `tools/irdiff.py old.ws new.ws` | what a change costs in IR nodes, by kind |
| `tools/gate_ports.py` | gate port catalogue the simulator implements |
| `tools/fuzz.py` | seeded differential fuzzer against the oracle |
