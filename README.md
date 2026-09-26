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
docs/           reference: the VM's registers, opcodes and state machines
```

The chip's own header is the description of the *language* it implements: the
ports, what is supported, the limits, and every place it differs from PUC-Lua
5.5. `docs/vm-isa.md` is the description of the machine underneath it — the
register triples, the 51 opcodes, the operand encoding and the asynchronous
states. Neither belongs here.

The headline limits, because a program meets them: 1,024 instructions, 4,096
tokens, 64 registers per function, 96 functions, 96 globals, 32 active call
frames, 512 table entries, and 16 values in one expanded call, return, or
statement. Exceeding one is a **compile error on the `err` port with the line
that asked for too much**, never a wrong answer.



## The interface

A WireScript chip is wires, so everything a program can see or change is a port.
`program` carries the source in, the chip runs it, and the results come back out:

```
          program --|           |-- log
              run --|           |-- outNum0
           inNum0 --|___________|-- outNum1
           inNum1 --|           |-- outNum2
           inNum2 --|  Lua 5.5  |-- outNum3
           inNum3 --|           |-- outNum4
           inStr0 --|___________|-- outStr0
           inStr1 --|           |-- outStr1
             inArr --|           |-- outArr
                                 |-- result
                                 |-- err

                                |-- progOk
                                |-- busy
```


`run` is the only one that decides anything: high runs the program, low stops it
where it is, and a rising edge starts again from the top. Every other input
restarts the program when it changes while `run` is high, except `inArr`, which
is read live by `inarr()`.

Everything a program *writes* is a call, including the single numbers and
strings: `outnum(i, v)`, `outstr(i, v)`, `outint(v)` and `outarr(i, v, ...)` for
the array. Two consequences worth knowing: a program cannot read an output back
(the ports are not globals, so keep your own copy), and a value stays on its port
until something writes there again, so whatever is reading the chip can take its
time. The indexes differ between the two families: `outnum`/`outstr` are 0-based,
`outarr` is 1-based, so `outnum(0, v)` and `outarr(1, v)` are the same slot.

The picture is generated from the port declarations in `lua.ws`, so it cannot
drift from them without the diff saying so.

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
python -u tests/stdlib_check.py                # standard-library family battery
python -u tests/cpu_comms_check.py             # self-read and two-CPU port handoff
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
| `CHIP_POOL` | `1` (default) hands out one case at a time; `0` is the old batch path |
| `PROBE_TICKS` | tick budget for `tools/check.py` |
| `TRACE_TICKS` | tick budget for the two trace tools |

## Tools

Iterating (each builds the chip once, ~6s, then runs many programs):

| script | what it does |
| --- | --- |
| `tools/check.py "prog" "prog" ...` | run programs on the chip, diff against the oracle |
| `tools/chip/dump_vm.py "prog"` | dump the bytecode a program compiles to |
| `tools/chip/dump_vm.py --tokens "prog"` | dump the token stream and the prepended library source |
| `tools/chip/trace_pc.py "prog" "0,1,2"` | step the VM, printing pc, frame and chosen registers |
| `tools/chip/trace_exec.py "prog"` | which chip nodes execute, in order |
| `tools/chip/profile_sim.py "prog"` | where a run spends its ticks |
| `tools/chip/perfbench.py --baseline REV` | alternate a baseline and current IR chip across the benchmark battery |

Checks on the chip itself:

| script | what it does |
| --- | --- |
| `tools/chip/audit.py` | one build, then: compiler `_Unsupported` placeholders (a silent miscompile), gate classes the simulator has no handler for, and the node/wire count |
| `tools/chip/globals.py "prog"` | the global slot table after a run |
| `tools/chip/slots.py` | builtin ids and the global init arrays, from the source |
| `tools/chip/irdiff.py old.ws new.ws` | what a change costs in IR nodes, by kind |
| `tools/chip/gate_ports.py` | gate port catalogue the simulator implements |
| `tools/chip/lockstep.py` | run programs on two independent chips and compare the log after every tick |
| `tools/fuzz.py` | seeded differential fuzzer against the oracle |
| `tools/model/vmmodel.py` | run the Quint transition systems through Apalache, for the invariants a diff cannot see |
