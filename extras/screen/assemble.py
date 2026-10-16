"""Assemble game-ready Lua programs: gfx library + showcase body.

The screen showcases call the gfx library (tick/nap/fire/pushShape/...)
instead of touching output ports, so what runs in game is the library
prepended to the body.  This writes one assembled file per showcase in
extras/screen -- comment-free and blank-free, since the game caps
program length and a truncated program fails parsing loudly
(`err: line N: not a call statement`).

  python -u extras/screen/assemble.py

Writes showcase.game.lua, showcase2.game.lua, anim.game.lua,
showcase3.game.lua and cube.game.lua next to their bodies, and prints
every size.  Bodies stay readable (comments and all); the stripping
happens here, at assembly time.  gfx.lua itself is comment-free by
construction.
"""
import io
import os

HERE = os.path.dirname(os.path.abspath(__file__))
GFX = os.path.join(os.path.dirname(HERE), "cpu-screen-connector",
                   "gfx.lua")
BODIES = ("showcase.lua", "showcase2.lua", "anim.lua", "showcase3.lua",
          "cube.lua")


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
