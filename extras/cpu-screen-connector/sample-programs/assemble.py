"""Assemble game-ready Lua programs: gfx library + showcase body.

The screen showcases call the gfx library (tick/nap/fire/pushShape/...)
instead of touching output ports, so what runs in game is the library
prepended to the body.  gfx.lua is a library and lives in the parent
(cpu-screen-connector); the bodies and the assembled files stay in
sample-programs.  Output is comment-free and blank-free -- strip() drops
comment and blank lines from BOTH the library and the body, so gfx.lua's
own comments never ship in a game file (the game caps program length and a
truncated program fails parsing loudly)
(`err: line N: not a call statement`).

  python -u extras/cpu-screen-connector/sample-programs/assemble.py

Writes anim.game.lua, cube.game.lua, curve.game.lua, mover.game.lua,
scale.game.lua, breath.game.lua, parent.game.lua and camera.game.lua next
to their bodies, and prints
every size.  Bodies stay readable (comments and all); the stripping
happens here, at assembly time.  strip() runs on the library too, so the game files stay under the cap.
"""
import io
import os

HERE = os.path.dirname(os.path.abspath(__file__))
GFX = os.path.join(os.path.dirname(HERE), "gfx.lua")
BODIES = ("anim.lua", "cube.lua", "curve.lua", "mover.lua", "scale.lua",
          "breath.lua", "parent.lua", "camera.lua")


def strip(src):
    return "\n".join(l for l in src.split("\n")
                     if l.strip() != ""
                     and not l.strip().startswith("--"))


def main():
    lib = strip(io.open(GFX, encoding="utf-8").read())
    print("gfx.lua stripped: %d chars" % len(lib))
    for name in BODIES:
        body = strip(io.open(os.path.join(HERE, name),
                             encoding="utf-8").read())
        out = lib + "\n" + body + "\n"
        dest = os.path.join(
            HERE, name.replace(".lua", ".game.lua"))
        io.open(dest, "w", encoding="utf-8", newline="\n").write(out)
        print("%-18s body %5d -> game %5d chars"
              % (name, len(body), len(out)))


if __name__ == "__main__":
    main()
