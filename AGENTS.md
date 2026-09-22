# AGENTS.md — how to work in this repo

## Shell (Windows PowerShell 5.1)
- No `tail`, `head`, `nproc`, `&&`. Use `Select-Object -First/-Last`, `;`, `$env:NUMBER_OF_PROCESSORS`.
- Quote paths with spaces. Prefer the `bash` tool's `workdir` param over `cd`.
- Python is 3.12 (no JIT, GIL on) — CPU parallelism means **multiprocessing**, not threads.

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

## Verification
- Verify with execution, never by reasoning alone: run the relevant checks after every change.
- Verify a fix against the exact failing case first, then the wider matrix.
- Chip-vs-oracle suite: `python -u tinylua/tests/test_chip_suite.py [filter|--all|--list]`.
  Default skips the slow tier (fib/bubble/log-many/table-limits); `--all` runs it.
  Output to a file and poll it — never pipe a batch into `Select-Object -Last`.
- Bound every stage with timeouts — including the oracle and the sim, which can
  hang too (e.g. an unpatched jump is an infinite loop). Prefer worker subprocesses with
  hard timeouts over in-process calls for anything that can spin.
- A "hung" batch is often buffering, orphan contention, or one stuck case hiding behind
  aggregated output — bisect to single cases with per-case output before concluding.

## Workflow
- Keep a todo list for multi-step work, with exactly one `in_progress` item at a time.
- The `tinylua/` subdirectory is its own git repo — run its git commands with
  `workdir` set there. Commit only when explicitly asked.
