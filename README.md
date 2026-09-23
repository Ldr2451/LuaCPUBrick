# tinylua

A Lua 5.5 interpreter that runs as a Brickadia WireScript chip (`lua.ws`), with
a tick-level simulator for it and a test suite that compares the chip against the
real `lua5.5` binary.

```
lua.ws          the chip: lexer, compiler and VM for the Lua subset
lua_full.ws     an older, larger reference chip (kept for comparison only)
demo.lua        a small program to try in-game
irrun/          the simulator: IR loader, tick sim, gate catalogue
tests/          the suite and the oracle-diff checks
tools/          development tools (see below)
```

## Running the tests

```sh
python -u tests/test_chip_suite.py            # every case, chip vs Lua 5.5
python -u tests/test_chip_suite.py iter-      # only cases matching a filter
python -u tests/test_consistency.py           # static structure vs tests/spec.py
python -u tests/iter_check.py                 # iteration library, oracle diff
python -u tests/multi_check.py                # multiple returns, oracle diff
python -u tests/vararg_check.py               # varargs/select, oracle diff
python -u tools/fuzz.py 200                   # random programs, oracle diff
```

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

## Tools

Iterating (each builds the chip once, ~6s, then runs many programs):

| script | what it does |
| --- | --- |
| `tools/check.py "prog" "prog" ...` | run programs on the chip, diff against the oracle |
| `tools/dump_vm.py "prog"` | dump the bytecode a program compiles to |
| `tools/dump_vm.py --tokens "prog"` | dump the token stream and the prepended library source |
| `tools/trace_pc.py "prog" "0,1,2"` | step the VM, printing pc, frame and chosen registers |
| `tools/trace_exec.py "prog"` | which chip nodes execute, in order |

Checks on the chip itself:

| script | what it does |
| --- | --- |
| `tools/unsup.py` | compiler `_Unsupported` placeholders (a silent miscompile) |
| `tools/unhandled.py` | gate classes the simulator has no handler for |
| `tools/globals.py` | the global slot table after a reset |
| `tools/slots.py` | builtin ids and the global init arrays, from the source |
| `tools/gatecount.py lua.ws` | IR node/wire counts, as a gate-size proxy |
| `tools/irdiff.py old.ws new.ws` | what a change costs in IR nodes, by kind |
| `tools/gate_ports.py` | gate port catalogue the simulator implements |
| `tools/fuzz.py` | seeded differential fuzzer against the oracle |
