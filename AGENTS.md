# AGENTS.md — how to work in this repo

## Shell (Windows PowerShell 5.1)
- No `tail`, `head`, `nproc`, `&&`. Use `Select-Object -First/-Last`, `;`, `$env:NUMBER_OF_PROCESSORS`.
- Quote paths with spaces. Prefer the `bash` tool's `workdir` param over `cd`.
- Python is 3.12 (no JIT, GIL on) — CPU parallelism means **multiprocessing**, not threads.
- Changing the Python build (3.13 free-threading / `--enable-jit`, Cython) is not
  worth it here: the sim is a single-threaded interpreter-bound pointer chase,
  free-threading only helps threaded code, and the JIT would buy single-digit
  percent for a large rewrite. The wins were algorithmic instead.

## Timeouts and process hygiene
- Always set short explicit timeouts (60–90s for probes). Never assume a command returns.
- Tool timeouts and interrupts do **not** reliably kill process trees — orphaned
  `python` processes keep burning CPU in the background. After any killed/long command,
  check `Get-Process python` and `Stop-Process` the leftovers.
- Always run Python with `-u` (unbuffered). Buffered output through a pipe is
  indistinguishable from a hang.
- Never pipe a long-running command into `Select-Object -Last` — it hides all progress
  until completion. Stream output, or redirect to a file and poll the file.
- Bisect slow batches: run suspect cases one at a time, each with its own timeout.

## Batching (the single biggest speed lever)
- Compiling `lua.ws` costs ~5s and indexing its 124k wires another ~0.8s. Never
  pay that per program: `irsims.ChipRunner` compiles once and runs many programs
  via `Sim.reset()`, which restores the just-constructed state without touching
  the wiring or the static source cache. The check scripts use it.
- `test_chip_suite.py` puts `BATCH` (12, override with `CHIP_BATCH=1`) cases in
  each worker process, so a batch builds the chip once. A batch that dies or
  times out is re-run case by case, keeping the hard per-case timeout.
- Measured: suite 125s -> 78s, `iter_check` 78s -> 33s, byte-identical results.
- Do not split the suite into fast/slow tiers. It only ever meant running the
  whole suite twice to see everything; all cases now run by default.
- When a script loops over cases, build the expensive shared object once outside
  the loop. Check for this before concluding that a harness is just "slow".

## Batch your own work too
- Independent tool calls go out in one message (parallel), not one at a time:
  searches, reads of unrelated files, independent test commands.
- Prefer one command that runs everything over many commands that each run part:
  `test_ws_consistency.py`, the suite and the three oracle checks belong in a
  single parallel call at the end of a change, not one per edit.
- Don't re-run the same test file repeatedly to "confirm" — one run at the end
  covers it. While iterating, run the single narrowest command that proves the
  thing just changed (a filter, a dump, a debug script), then verify wide once.
- Read every file a change will touch in one batched read before editing, so the
  edits are right the first time instead of iterating on stale context.
- Compile the chip once per batch of experiments: a loop over N test programs
  must not trigger N recompiles.

## Verification
- Verify with execution, never by reasoning alone: run the relevant checks after every change.
- Chip-vs-oracle suite: `python -u tinylua/tests/test_chip_suite.py [filter]`.
  All cases run unless a filter narrows them. Output to a file and poll it —
  never pipe a batch into `Select-Object -Last`.
- After changing the sim or the runner, prove the fast path equals the slow one
  (e.g. `CHIP_BATCH=1` must give the same OK/FAIL counts) before trusting it.
- Bound every stage with timeouts — including the oracle and the sim, which can
  hang too (e.g. an unpatched jump is an infinite loop). Prefer worker subprocesses with
  hard timeouts over in-process calls for anything that can spin.
- A "hung" batch is often buffering, orphan contention, or one stuck case hiding behind
  aggregated output — bisect to single cases with per-case output before concluding.

## Workflow
- Keep a todo list for multi-step work, with exactly one `in_progress` item at a time.
- The `tinylua/` subdirectory is its own git repo — run its git commands with
  `workdir` set there. Commit only when explicitly asked.
