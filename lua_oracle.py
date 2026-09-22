"""Lua 5.5 oracle bridge: run a Tiny Lua program under real Lua with
print-capture framing, so chip output can be compared against ground truth.

Extracted verbatim from the retired Python model; the framing normalizes
function addresses and NaNs. `oracle_log` rebuilds the print log applying
the same line cap/width the chip enforces.
"""
import math
import os
import re
import shutil
import subprocess
import tempfile

LOG_LINES = 32
LOG_WIDTH = 64


def _find_oracle():
    """Locate a Lua 5.5 oracle binary; None when unavailable (tests SKIP)."""
    cands = [
        os.path.join(os.environ.get("LOCALAPPDATA", ""),
                     "Programs", "Lua55", "bin", "lua55.exe"),
        shutil.which("lua55"),
    ]
    for c in cands:
        if not c or not os.path.isfile(c):
            continue
        try:
            p = subprocess.run([c, "-v"], capture_output=True, text=True,
                               timeout=10)
            if "5.5" in (p.stdout + p.stderr):
                return c
        except (OSError, subprocess.SubprocessError):
            continue
    return None


LUA_BIN = _find_oracle()
FUNC_NORM = re.compile(r"function: 0x[0-9a-fA-F]+")

NAN_NORM = re.compile(r"^-?nan(\(ind\))?$")


def norm_val(v):
    v = FUNC_NORM.sub("function: F", v)
    if NAN_NORM.match(v):
        return "-nan"
    return v


def norm_calls(calls):
    return [[norm_val(v) for v in call] for call in calls]


def lua_str_lit(s):
    out = ['"']
    for ch in s:
        if ch == '"':
            out.append('\\"')
        elif ch == "\\":
            out.append("\\\\")
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\t":
            out.append("\\t")
        elif ch == "\r":
            out.append("\\r")
        elif 32 <= ord(ch) <= 126:
            out.append(ch)
        else:
            out.append("\\%d" % ord(ch))
    out.append('"')
    return "".join(out)


def lua_num_lit(v):
    if math.isnan(v):
        return "(0/0)"
    if math.isinf(v):
        return "(1/0)" if v > 0 else "(-1/0)"
    s = format(v, ".17g")
    if "." not in s and "e" not in s and "E" not in s:
        s += ".0"
    return s


def oracle_run(src, inputs=None, sinputs=None, vec=None, col=None,
               inarr=None, timeout=15, inint=None):
    if LUA_BIN is None:
        return {"avail": False}
    pre = []
    for k in range(4):
        v = float(inputs[k]) if inputs and k < len(inputs) else 0.0
        pre.append(f"inNum{k} = {lua_num_lit(v)}")
    pre.append(f"inInt0 = {int(inint) if inint is not None else 0}")
    for k in (0, 1):
        s = sinputs.get(k, "") if sinputs else ""
        pre.append(f"inStr{k} = {lua_str_lit(s)}")
    arr = [float(v) for v in inarr] if inarr else []
    pre.append("ARR = {" + ", ".join(lua_num_lit(v) for v in arr) + "}")
    pre.append("inarr = function(i)")
    pre.append("  if type(i) == 'number' and i == math.floor(i)")
    pre.append("      and i >= 1 and i <= #ARR then return ARR[i] end")
    pre.append("  return nil")
    pre.append("end")
    pre.append("outarr = function() end")
    vv = vec or (0.0, 0.0, 0.0)
    for name, v in zip(("invecx", "invecy", "invecz"), vv):
        pre.append(f"{name} = {lua_num_lit(float(v))}")
    cc = col or (0.0, 0.0, 0.0, 0.0)
    for name, v in zip(("incolr", "incolg", "incolb", "incola"), cc):
        pre.append(f"{name} = {lua_num_lit(float(v))}")
    pre.append("print = function(...)")
    pre.append("  local n = select('#', ...)")
    pre.append("  io.write('\\0' .. n .. '\\0')")
    pre.append("  if n > 0 then")
    pre.append("    local t = {}")
    pre.append("    for i = 1, n do t[i] = tostring(select(i, ...)) end")
    pre.append("    io.write(table.concat(t, '\\1'))")
    pre.append("  end")
    pre.append("  io.write('\\2')")
    pre.append("end")
    prog = "\n".join(pre) + "\n" + src
    with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False) as f:
        f.write(prog)
        path = f.name
    try:
        p = subprocess.run([LUA_BIN, path], capture_output=True, text=True,
                           timeout=timeout)
    except FileNotFoundError:
        return {"avail": False}
    finally:
        os.unlink(path)
    calls = []
    if p.stdout:
        chunks = p.stdout.split("\2")
        for ch in chunks[:-1]:
            parts = ch.split("\0")
            if len(parts) != 3 or parts[0] != "":
                return {"avail": True, "rc": p.returncode, "calls": None,
                        "stderr": "bad framing: %r" % ch}
            try:
                n = int(parts[1])
            except ValueError:
                return {"avail": True, "rc": p.returncode, "calls": None,
                        "stderr": "bad count: %r" % ch}
            if n == 0:
                calls.append([])
            else:
                vals = parts[2].split("\1")
                if len(vals) != n:
                    return {"avail": True, "rc": p.returncode,
                            "calls": None,
                            "stderr": "arity mismatch: %r" % ch}
                calls.append(vals)
    norm = []
    for call in calls:
        norm.append([norm_val(v) for v in call])
    return {"avail": True, "rc": p.returncode, "calls": norm,
            "stderr": p.stderr.strip().splitlines()[-1] if p.stderr.strip()
            else ""}


def oracle_log(calls):
    """Rebuild the print log from oracle-captured print calls, applying
    the same line cap/width the chip enforces."""
    lines = []
    for call in calls:
        line = "\t".join(call) + "\n"
        if len(line) > LOG_WIDTH:
            line = line[:LOG_WIDTH - 1] + "\n"
        lines.append(line)
        if len(lines) > LOG_LINES:
            del lines[0]
    return "".join(lines)
