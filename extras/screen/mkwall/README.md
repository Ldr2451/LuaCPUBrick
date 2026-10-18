# The pixel wall, without a compiler patch.

`mkwall` is what the old `--wall` compiler flag did, moved out of the
compiler: it links the compiler as a library, takes the `World` the compiler
returns, finds the chip's labelled colour outputs in it, appends the wall
bricks and the wires that drive them, and writes the save.  The compiler
itself is the base compiler, unmodified.

Why the wall cannot come from the base compiler: a plain brick exposes no
wire ports (brick colour is save data, not a port), so every pixel needs a
`Component_BrickPropertyChanger`, and one wire from the chip's output into
its `Color`.  Nothing in the language expresses "lay a grid of procedural
microbricks at these positions and wire each to this output" -- it is a
save-building job, and the compiler's emit pass is where the save is built.

## Use

    python -u build.py          # from extras/screen: chip + wall -> screen.brz

`build.py` compiles with the base compiler into a scratch save, then runs

    cargo run --release --manifest-path mkwall/Cargo.toml -- \
        <source.ws> <out.brz> px:64x64

The one thing that cannot live in the repo is the compiler's own path (the
checkout is outside it, see `irdump.WS_DIR`), so `build.py` substitutes it
into `mkwall/Cargo.toml` and restores the placeholder afterwards.  A compile
with an ERROR diagnostic writes nothing, at either stage.

To run it by hand, put the compiler path in the manifest:

    set WS=<the wirescript checkout>

## Geometry

Chip-relative, and the measured layout the shipped save uses: microbricks at
2-unit pitch, centred on the chip in X/Z, standing in the X/Z plane at a
fixed Y above the chip shell, row 0 at the top (+Z is up).  Pixels carry the
glow material (the wall is a light source, its brightness scaled by the
chip's `brightness` input) and no collision, so players, weapons and tools
pass through a 64x64 wall.

## Checking a rebuild

`tools/brzinfo.rs` prints the grid/brick/wire/component counts of a save, so
a rebuilt artifact can be compared with the shipped one.  The wall grid must
read 4110 bricks, 4096 wires, 4124 components -- 4096 pixel bricks plus the
changers, and 4096 pixel wires.  It is a diagnostic only: copy it into the
compiler checkout as a cargo example to build it (the header says how), and
delete the copy so the checkout stays pristine.