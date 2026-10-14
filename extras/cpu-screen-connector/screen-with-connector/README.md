# screen-with-connector

Builds both shippable artifacts, separately.  The screen and the
connector are two independent chips for users who drive the screen on
its own, so they are never combined: no wrapper file, no combo
artifact -- this folder holds only the script that rebuilds both.

- `package.py` -- regenerates `extras/screen/screen.brz` (via that
  folder's `gen.py` + `build.py`) and
  `extras/cpu-screen-connector/connector.brz` (via that folder's
  `build.py`), refusing success unless every compiler call exits 0:

  `python -u extras/cpu-screen-connector/screen-with-connector/package.py`
