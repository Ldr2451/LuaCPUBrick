"""Lua 5.5 oracle bridge: run a program under real Lua with
print-capture framing, so chip output can be compared against ground truth.

The oracle is the only authority on what the chip should do; a difference is a
bug in the chip until proven otherwise. The framing normalizes function
addresses and NaNs. `oracle_log` rebuilds the print log applying the same
line cap/width the chip enforces.
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
    """Locate a Lua 5.5 oracle binary; None when unavailable (tests SKIP).

    Set LUA55 to point at one explicitly.  Otherwise try the usual names on
    PATH and the per-user install directories of each platform.
    """
    home = os.path.expanduser("~")
    cands = [
        os.environ.get("LUA55"),
        shutil.which("lua5.5"),
        shutil.which("lua55"),
        # Windows
        os.path.join(os.environ.get("LOCALAPPDATA", ""), "Programs",
                     "Lua55", "bin", "lua55.exe"),
        # macOS
        "/usr/local/bin/lua5.5", "/opt/homebrew/bin/lua5.5",
        # Linux
        "/usr/bin/lua5.5", "/usr/local/bin/lua5.5",
        os.path.join(home, ".luarocks", "bin", "lua5.5"),
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
# PUC prints an address after a function, table, thread or userdata; the chip
# prints the type name.  Folding both to the type name means a case may print one
# directly instead of wrapping every one of them in type() to dodge the
# comparison.  The 0x is optional: this build's tostring omits it.
ADDR_NORM = re.compile(r"\b(function|table|thread|userdata): (?:0x)?[0-9a-fA-F]+")

NAN_NORM = re.compile(r"^-?nan(\(ind\))?$")


def norm_val(v):
    v = ADDR_NORM.sub(r"\1", v)
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


def _first_line(raw):
    """The first line of a subprocess's stderr, decoded.

    The oracle's stderr is bytes (see oracle_run: the output is read as bytes so a
    CR in a program's output survives), and a Windows Lua also puts its own
    warnings first, so the first line is not always the error either -- but it is
    the line the suite's expectations are written against.
    """
    text = raw.decode('utf-8', 'replace').strip()
    return text.splitlines()[0] if text else ""


def oracle_run(src, inputs=None, sinputs=None, vec=None, col=None,
               inarr=None, timeout=15, inint=None):
    if LUA_BIN is None:
        return {"avail": False}
    pre = []
    # the real write, captured before io.write is replaced: the framing the
    # harness emits has to go to the actual stdout
    pre.append("local RAW = io.write")
    # JSON turns a case's sinputs keys into strings, so normalise before looking
    # them up: sinputs.get(0) on {"0": ...} misses, and the case then compares an
    # empty input against the chip's real one (or, worse, two empties)
    sinputs = {int(k): v for k, v in (sinputs or {}).items()}
    for k in range(4):
        v = float(inputs[k]) if inputs and k < len(inputs) else 0.0
        pre.append(f"inNum{k} = {lua_num_lit(v)}")
    pre.append(f"inInt0 = {int(inint) if inint is not None else 0}")
    for k in (0, 1):
        s = sinputs.get(k, "")
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
    pre.append("  RAW('\\0' .. n .. '\\0')")
    pre.append("  if n > 0 then")
    pre.append("    local t = {}")
    pre.append("    for i = 1, n do t[i] = tostring(select(i, ...)) end")
    pre.append("    RAW(table.concat(t, '\\1'))")
    pre.append("  end")
    pre.append("  RAW('\\2')")
    pre.append("end")
    # io.write goes to the log with no tab and no newline, which is what the
    # chip's _wr does, so it is captured the same way and marked 'w' for the
    # parser.  io.read and io.lines read the text in inStr0, which is where the
    # chip reads standard input from -- PUC's would read the (empty) real stdin.
    pre.append("io.write = function(...)")
    pre.append("  local t = {}")
    pre.append("  for i = 1, select('#', ...) do t[i] = tostring((select(i, ...))) end")
    pre.append("  RAW('\\0w\\0' .. table.concat(t) .. '\\2')")
    pre.append("end")
    pre.append("local SP = 0")
    pre.append("io.read = function(fmt)")
    pre.append("  if fmt == nil then fmt = '*l' end")
    pre.append("  if type(fmt) == 'number' then")
    pre.append("    local s = inStr0:sub(SP + 1, SP + fmt)")
    pre.append("    SP = SP + #s")
    pre.append("    return s")
    pre.append("  end")
    pre.append("  if fmt == '*a' or fmt == 'a' then")
    pre.append("    local s = inStr0:sub(SP + 1)")
    pre.append("    SP = #inStr0")
    pre.append("    return s")
    pre.append("  end")
    pre.append("  if fmt == '*l' or fmt == 'l' then")
    pre.append("    if SP >= #inStr0 then return nil end")
    pre.append("    local nl = inStr0:find('\\n', SP + 1, true)")
    pre.append("    local s")
    pre.append("    if nl then")
    pre.append("      s = inStr0:sub(SP + 1, nl - 1)")
    pre.append("      SP = nl")
    pre.append("    else")
    pre.append("      s = inStr0:sub(SP + 1)")
    pre.append("      SP = #inStr0")
    pre.append("    end")
    pre.append("    if s:sub(-1) == '\\r' then s = s:sub(1, -2) end")
    pre.append("    return s")
    pre.append("  end")
    pre.append("  error(\"bad argument to 'read' (invalid format)\")")
    pre.append("end")
    pre.append("io.lines = function()")
    pre.append("  SP = 0")
    pre.append("  return function() return io.read('*l') end")
    pre.append("end")
    prog = "\n".join(pre) + "\n" + src
    with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False) as f:
        f.write(prog)
        path = f.name
    try:
        # not text=True: universal newlines would turn the CR in a program's
        # output into LF, and the chip's log keeps it
        p = subprocess.run([LUA_BIN, path], capture_output=True,
                           timeout=timeout)
    except FileNotFoundError:
        return {"avail": False}
    finally:
        os.unlink(path)
    out = p.stdout.decode('utf-8', 'replace')
    # On Windows the oracle's stdout goes through the CRT in text mode, so every
    # \n the program wrote arrives as \r\n -- an artefact of the host, not of the
    # program, and the chip's log keeps the bare \n.  Undo it once on the whole
    # capture: the framing bytes carry no newlines, so only values are touched,
    # and a program that really wrote "\r\n" arrives as "\r\r\n" and comes back
    # to "\r\n" -- a \r that came from the program is never eaten.
    out = out.replace("\r\n", "\n")
    calls = []
    if out:
        chunks = out.split("\2")
        for ch in chunks[:-1]:
            parts = ch.split("\0")
            if len(parts) != 3 or parts[0] != "":
                return {"avail": True, "rc": p.returncode, "calls": None,
                        "stderr": "bad framing: %r" % ch}
            if parts[1] == "w":
                # an io.write: raw text into the log, no tab and no newline
                calls.append(["\0w", parts[2]])
                continue
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
            # the message is the first line; the last is the tail of the stack
            # traceback ("[C]: in ?"), which says nothing about what went wrong
            "stderr": _first_line(p.stderr)}


def oracle_log(calls):
    """Rebuild the log from oracle-captured calls, applying the same caps the chip
    enforces.  A print call is one tab-joined line, capped at 64 characters; an
    io.write is raw text with no tab and no newline, which is what the chip's _wr
    appends.  Both count as one append against the log's 32-entry cap, because
    they go through the chip's one append path."""
    out = []
    for call in calls:
        if call and call[0] == "\0w":
            out.append(call[1])
        else:
            line = "\t".join(call) + "\n"
            if len(line) > LOG_WIDTH:
                line = line[:LOG_WIDTH - 1] + "\n"
            out.append(line)
        if len(out) > LOG_LINES:
            del out[0]
    return "".join(out)
