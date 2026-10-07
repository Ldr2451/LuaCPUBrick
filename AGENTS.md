# AGENTS.md — working in this repo

Pointers only. Rules, costs, and traps live in `docs/lessons.md` — read the
section for the area before touching it.

- `lua.ws` — the chip (Lua 5.5 on WireScript). `lua.brz` is built, never edited:
  `python -u tools/buildbrz.py` (rc=0 required).
- `demo.lua` — full-feature smoke test; its expected log is `DEMO_LOG` in
  `tests/cases.py`.
- `tests/cases.py` — the suite; `tests/spec.py` — the limits mirror.
- `docs/lessons.md` — commands, cost currencies, traps, verification, workflow.
- `docs/traps.md` — measured WireScript shapes that cost a session.
- `tools/chip/` — probes: `audit.py` (node count), `limits.py` (ceilings),
  `pucsuite.py`/`pucount.py` (official Lua tests), `perfbench.py` (ticks).
- `tools/lib/libconst.py` — the only way a `lib/` piece lands in `lua.ws`.
- `lib/` — Lua library masters, the readable source of truth.

One test command at a time, `python -u` always. Verify by execution; add a
suite case per bug or feature. Do not commit unless asked.
