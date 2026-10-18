"""Build the shippable screen artifact: screen.ws -> screen.brz.

The wall IS the screen: every build lays the 64x64 microbrick wall and wires
it to the chip's pixel outputs, so the artifact holds the wall and the chip,
properly connected.  The compiler is NOT patched -- it is the base compiler,
used as a library by `mkwall/`, which adds the wall to the World the compiler
returns (see extras/screen/mkwall/src/main.rs).  Same discipline as the repo's
buildbrz.py, which this folder may not touch: nothing is written when the
compile has an ERROR diagnostic, so a build that does not check the exit code
can "succeed" and ship yesterday's chip.  Refuses to report success unless
rc == 0 from both stages.

  python -u extras/screen/build.py
"""
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "irrun"))
from irdump import WS_EXE, WS_DIR  # noqa: E402

MKWALL_SRC = os.path.join(HERE, "mkwall")
src = os.path.join(HERE, "screen.ws")
out = os.path.join(HERE, "screen.brz")
before = os.path.getsize(out) if os.path.exists(out) else 0
stamp = os.path.getmtime(out) if os.path.exists(out) else 0


def run(cmd, what):
    p = subprocess.run(cmd, capture_output=True, text=True, cwd=WS_DIR,
                       encoding="utf-8", errors="replace")
    if p.returncode != 0:
        print("%s FAILED rc=%d; screen.brz not written" % (what, p.returncode))
        for line in (p.stdout + "\n" + p.stderr).splitlines()[-12:]:
            print("  %s" % line[:170])
        sys.exit(1)
    return p


# ---- stage 1: the chip, with the base compiler, into a scratch save --------
# The artifact is assembled in a scratch directory so a failed wall stage can
# never leave a half-built save in place of the shipped one.
work = tempfile.mkdtemp(prefix="mkwall")
try:
    chip_brz = os.path.join(work, "chip.brz")
    run([WS_EXE, "compile", src, "-o", chip_brz], "compile")
    if not os.path.exists(chip_brz):
        print("compile produced no save; screen.brz not written")
        sys.exit(1)

    # ---- stage 2: the wall, by the repo's tool -----------------------------
    # The manifest's dependency path is the one thing that cannot live in the
    # repo (the compiler checkout is outside it), so it is written here.
    # WS_DIR is where the exe lives (the build tree), so walk up to the
    # checkout root that holds `crates/`.
    ws_root = WS_DIR
    for _ in range(3):
        if os.path.isdir(os.path.join(ws_root, "crates")):
            break
        ws_root = os.path.dirname(ws_root)
    if not os.path.isdir(os.path.join(ws_root, "crates", "wirescript")):
        print("cannot find the wirescript crate under %s; set WS_DIR in "
              "irdump.py to the compiler checkout" % WS_DIR)
        sys.exit(1)
    manifest = os.path.join(MKWALL_SRC, "Cargo.toml")
    with open(manifest, encoding="utf-8") as f:
        text = f.read()
    patched = text.replace("PLACEHOLDER", ws_root.replace("\\", "/"))
    if "PLACEHOLDER" not in text:
        print("mkwall/Cargo.toml no longer has the PLACEHOLDER path; "
              "check it before trusting this build")
        sys.exit(1)
    try:
        with open(manifest, "w", encoding="utf-8", newline="\n") as f:
            f.write(patched)
        run(["cargo", "run", "--release", "--quiet", "--manifest-path",
             manifest, "--", src, chip_brz, "px:64x64"], "mkwall")
    finally:
        # the repo's manifest stays compiler-agnostic: whoever reads it next
        # fills their own path in.
        with open(manifest, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)

    # Only now does the artifact replace the shipped one.
    shutil.copyfile(chip_brz, out)
finally:
    shutil.rmtree(work, ignore_errors=True)

after = os.path.getsize(out)
moved = "unchanged" if os.path.getmtime(out) == stamp else "rebuilt"
print("screen.brz %s: %d -> %d bytes" % (moved, before, after))