"""Record a showcase program's port stream with real Lua.

Phase 1 of the showtest suites spends thousands of the Lua chip's ticks
just parsing the program (~1 char/tick measured: 3861 chars -> parse end
at tick 4029) and then emits a handful of port writes per frame.  The
program's *semantics* are plain Lua, so real PUC Lua -- the same oracle
the suite already trusts for language behaviour -- produces the same
stream in milliseconds.

Only the timing is modelled, and modelled the way the chip already
models it: the program's `tick()` and `nap()` are busy-waits on
`clock()`, so a virtual clock advanced one tick per call reproduces the
chip's port timing exactly (a pulse that goes high at T is low at T+1).
The harness loads after the gfx library, and globals are late-bound, so
its `tick`/`nap` override the library's busy-wait versions without
touching the library file.  Every value the program writes is decided
by real Lua.

A program that loops forever is stopped by the tick budget; the writes
recorded so far are kept, because stdout is written as it goes.
"""
import os
import shutil
import subprocess
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))

# `clock`, `tick`, `nap` and the four writers.  Numbers go out at full
# precision so a value the chip would have written bit-identically
# compares equal; strings go out raw (a shape id is short and clean).
HARNESS = r"""
local VT = 0
local RAW = io.write
-- The chip's VM is an interpreter, so a program's own compute costs
-- ticks: a showcase frame is ~300 ticks wide on the chip, of which
-- tick/nap account for ~100.  A virtual clock that charges nothing for
-- the writes makes the stream three times too fast, and the screen
-- replay then gets pushes closer together than the chip ever sends
-- them -- which is exactly the difference that would make a fast
-- oracle drive the screen unfairly.  So each port write costs WCOST
-- ticks, calibrated once against the chip's measured frame width
-- (showcase2: ~8 writes a frame, ~200 compute ticks a frame).
local WCOST = 10
local function over()
  if VT > BUDGET then error('BUDGET', 0) end
end
function clock() over() return VT end
function tick() VT = VT + 1 over() end
function nap(c) VT = VT + math.floor(c * 100 + 0.5) over() end
local function em(v)
  if type(v) == 'number' then return string.format('%.17g', v) end
  return tostring(v)
end
function outNum(n, v)
  VT = VT + WCOST
  RAW('W\t' .. VT .. '\tN\t' .. n .. '\t' .. em(v) .. '\n')
end
function outStr(n, s)
  VT = VT + WCOST
  RAW('W\t' .. VT .. '\tS\t' .. n .. '\t' .. em(s) .. '\n')
end
local function putarr(tag, slot, ...)
  local t = {'W\t' .. VT .. '\t' .. tag .. '\t' .. slot}
  for i = 1, select('#', ...) do t[#t + 1] = em((select(i, ...))) end
  VT = VT + WCOST
  RAW(table.concat(t, '\t') .. '\n')
end
function outNumArr(slot, ...) putarr('A', slot, ...) end
function outStrArr(slot, ...) putarr('B', slot, ...) end
"""

NSLOT = 128
NSTR = 9


def find_lua():
    """Locate a Lua 5.5 oracle binary, in the same order and from the
    same places tests/lua_oracle.py looks: the stream has to be decided
    by the same reference the language suites use.  None means the
    caller falls back to the chip, as before.

    A 5.4 install on the PATH must not win: the chip's dialect is 5.5,
    and a stream decided by an older reference is a test that quietly
    checks the wrong thing.
    """
    home = os.path.expanduser("~")
    for c in (os.environ.get("LUA55"),
              shutil.which("lua5.5"),
              shutil.which("lua55"),
              # Windows
              os.path.join(os.environ.get("LOCALAPPDATA", ""), "Programs",
                           "Lua55", "bin", "lua55.exe"),
              # macOS
              "/usr/local/bin/lua5.5", "/opt/homebrew/bin/lua5.5",
              # Linux
              "/usr/bin/lua5.5", "/usr/local/bin/lua5.5",
              os.path.join(home, ".luarocks", "bin", "lua5.5")):
        if not c or not os.path.isfile(c):
            continue
        try:
            p = subprocess.run([c, "-v"], capture_output=True, text=True,
                               timeout=10)
        except (OSError, subprocess.SubprocessError):
            continue
        if "5.5" in (p.stdout + p.stderr):
            return c
    return None


LUA_BIN = find_lua()


class Write(object):
    __slots__ = ("tick", "kind", "port", "vals")

    def __init__(self, tick, kind, port, vals):
        self.tick = tick
        self.kind = kind
        self.port = port
        self.vals = vals


def record(src, lib_path, budget=40000, timeout=180):
    """Run the gfx library then src under real Lua.

    Returns the writes in tick order, or None when no Lua is available
    (the caller then runs the chip, as before).
    """
    if LUA_BIN is None:
        return None
    lib = open(lib_path, encoding="utf-8").read()
    prog = ("BUDGET = %d\n" % budget) + lib + "\n" + HARNESS + "\n" + src \
        + "\n"
    with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False,
                                     encoding="utf-8") as f:
        f.write(prog)
        path = f.name
    try:
        p = subprocess.run([LUA_BIN, path], capture_output=True,
                           timeout=timeout)
    finally:
        os.unlink(path)
    writes = []
    for line in p.stdout.decode("utf-8", "replace").splitlines():
        if not line.startswith("W\t"):
            continue
        parts = line.split("\t")
        if len(parts) < 5:
            continue
        try:
            tick = int(parts[1])
        except ValueError:
            continue
        kind, port = parts[2], parts[3]
        if kind in ("A", "B"):
            vals = []
            for v in parts[4:]:
                try:
                    vals.append(float(v))
                except ValueError:
                    vals.append(0.0)
        elif kind == "N":
            try:
                vals = [float(parts[4])]
            except (IndexError, ValueError):
                vals = [0.0]
        else:
            vals = [parts[4] if len(parts) > 4 else ""]
        writes.append(Write(tick, kind, port, vals))
    writes.sort(key=lambda w: w.tick)
    return writes


def sample_rows(writes, n_arr=NSLOT, n_str=NSTR, cols=8):
    """The write log -> the per-tick sample rows the screen replay reads.

    Index t of the result is the state the ports hold *after* every
    write at or before t, which is what the chip's sampling hook sees.
    A tick with no write therefore reads as held-low bools, the array
    unchanged and the strings unchanged -- the sticky behaviour of the
    real ports.

    cols=8 gives (push, draw, clear, wire, arr, id, id2, strarr), which
    is what showtest2's latching and replay hooks unpack.  cols=4
    gives (push, draw, clear, arr) for animtest, which reads no
    strings.
    """
    if writes is None:
        return None
    arr = [0.0] * n_arr
    strarr = [""] * n_str
    sid = sid2 = ""
    p = r = c = w = 0.0
    rows = []
    i = 0
    n = len(writes)
    t = 0
    while i < n:
        while i < n and writes[i].tick == t:
            wr = writes[i]
            i += 1
            if wr.kind == "N":
                port = wr.port
                v = wr.vals[0] if wr.vals else 0.0
                if port == "1":
                    p = v
                elif port == "2":
                    r = v
                elif port == "3":
                    c = v
                elif port == "4":
                    w = v
            elif wr.kind == "A":
                base = int(wr.port)
                for k, v in enumerate(wr.vals):
                    if 1 <= base + k <= n_arr:
                        arr[base + k - 1] = v
            elif wr.kind == "B":
                base = int(wr.port)
                for k, v in enumerate(wr.vals):
                    if 1 <= base + k <= n_str:
                        strarr[base + k - 1] = str(v)
            elif wr.kind == "S":
                if wr.port == "1":
                    sid = str(wr.vals[0]) if wr.vals else ""
                elif wr.port == "2":
                    sid2 = str(wr.vals[0]) if wr.vals else ""
        if cols >= 8:
            rows.append((p, r, c, w, list(arr), sid, sid2, list(strarr)))
        else:
            rows.append((p, r, c, list(arr)))
        t += 1
    return rows


if __name__ == "__main__":
    print("LUA_BIN:", LUA_BIN)
