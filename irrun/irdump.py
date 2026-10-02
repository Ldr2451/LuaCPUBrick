"""Parse `wirescript compile --dump-ir-full` output into a graph.

Record formats (single line each):
  N[<id> kind=<Kind> class=<gate class> props={<k>=<v Debug>,...}
     in=[<port>:<Type Debug>,...] out=[...]]
  W[<src id>:<port> -> <dst id>:<port>]
  M[chips=<n>]

Property values use Rust {:?} for Literal: Bool(true), Int(3),
Float(1.5), String("...") with \" and \\ escapes, Vector {...},
Color/LinearColor {...}, Array([...]), Map([...]), Object.
"""
import os
import re
import shutil
import subprocess


def _find_wirescript():
    """Locate the wirescript compiler.

    Set WIRESCRIPT to point at it.  Otherwise look for a build next to the
    repo, on PATH, and in the usual cargo output directories.
    """
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    cands = [
        os.environ.get("WIRESCRIPT"),
        shutil.which("wirescript"),
        os.path.join(here, "wirescript", "target", "release",
                     "wirescript.exe"),
        os.path.join(here, "wirescript", "target", "release", "wirescript"),
        os.path.join(here, "..", "wirescript", "target", "release",
                     "wirescript.exe"),
        os.path.join(here, "..", "wirescript", "target", "release",
                     "wirescript"),
        os.path.join(os.path.expanduser("~"), ".cargo", "bin", "wirescript"
                     + (".exe" if os.name == "nt" else "")),
    ]
    for c in cands:
        if c and os.path.isfile(c):
            return os.path.abspath(c)
    # last resort: the local scratch checkout this was developed against
    return os.path.join(
        os.environ.get("TEMP", "/tmp"), "opencode", "wirescript",
        "target", "release", "wirescript.exe" if os.name == "nt"
        else "wirescript")


WS_EXE = _find_wirescript()
WS_DIR = os.path.dirname(os.path.dirname(WS_EXE))


def resolve_prog(src, root):
    """A program, or `PRE:<path>\\n<rest>` with a repro file prepended.

    The suite's cases and the ad-hoc tools (check.py, dump_vm.py, trace_pc.py) all
    take the same spelling, so a probe and a case cannot drift apart, and the
    chip has no dofile for a case to load a helper library with.
    """
    if not src.startswith("PRE:"):
        return src
    path, _, rest = src[4:].partition("\n")
    with open(os.path.join(root, path), encoding="utf-8") as f:
        return f.read() + rest


class Node:
    def __init__(self, nid, kind, cls, props, pin, pout):
        self.id = nid
        self.kind = kind
        self.cls = cls
        self.props = props
        self.pin = pin
        self.pout = pout

    def __repr__(self):
        return f"Node({self.id},{self.cls})"


def _split_top(s):
    """Split on commas at brace/paren/bracket depth 0 (also honors quotes)."""
    parts, depth, cur, instr, esc = [], 0, "", False, False
    for ch in s:
        if instr:
            cur += ch
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"':
                instr = False
            continue
        if ch == '"':
            instr = True
            cur += ch
        elif ch in "{[(":
            depth += 1
            cur += ch
        elif ch in "}])":
            depth -= 1
            cur += ch
        elif ch == "," and depth == 0:
            parts.append(cur.strip())
            cur = ""
        else:
            cur += ch
    if cur.strip():
        parts.append(cur.strip())
    return parts


def _unescape_dq(inner):
    out = ""
    i = 0
    while i < len(inner):
        c = inner[i]
        if c == "\\" and i + 1 < len(inner):
            e = inner[i + 1]
            out += {"n": "\n", "r": "\r", "t": "\t", "\\": "\\",
                    '"': '"', "0": "\0"}.get(e, e)
            i += 2
        else:
            out += c
            i += 1
    return out


def _parse_lit(s):
    s = s.strip()
    m = re.match(r"Bool\((true|false)\)", s)
    if m:
        return ("bool", m.group(1) == "true")
    m = re.match(r"Int\((-?\d+)\)", s)
    if m:
        return ("int", int(m.group(1)))
    m = re.match(r"Float\((.*)\)$", s)
    if m:
        return ("float", float(m.group(1)))
    m = re.match(r'String\("(.*)"\)$', s, re.S)
    if m:
        return ("str", _unescape_dq(m.group(1)))
    if s.startswith('"') and s.endswith('"'):
        return ("str", _unescape_dq(s[1:-1]))
    m = re.match(r"Vector\s*\{([^{}]*)\}", s)
    if m:
        kv = dict(kv.split(":") for kv in _split_top(m.group(1)))
        return ("vec", (float(kv["x"]), float(kv["y"]), float(kv["z"])))
    m = re.match(r"(?:Linear)?Color\s*\{([^{}]*)\}", s)
    if m:
        kv = dict(kv.split(":") for kv in _split_top(m.group(1)))
        conv = (lambda v: float(v)) if "Linear" in s[:12] else (
            lambda v: float(v) / 255.0)
        return ("color", (conv(kv["r"]), conv(kv["g"]), conv(kv["b"]),
                          conv(kv["a"])))
    if s == "Object":
        return ("obj", None)
    m = re.match(r"Array\(\[(.*)\]\)$", s, re.S)
    if m:
        return ("arraylit", [_parse_lit(p) for p in _split_top(m.group(1))
                             if p])
    m = re.match(r"Map\(\[(.*)\]\)$", s, re.S)
    if m:
        pairs = []
        for p in _split_top(m.group(1)):
            if not p:
                continue
            inner = p.strip()
            if inner.startswith("(") and inner.endswith(")"):
                kv = _split_top(inner[1:-1])
                if len(kv) == 2:
                    pairs.append((_parse_lit(kv[0]), _parse_lit(kv[1])))
        return ("maplit", pairs)
    return ("raw", s)


def _parse_ports(s):
    out = []
    for p in _split_top(s):
        if not p:
            continue
        name, typ = p.split(":", 1)
        out.append((name.strip(), typ.strip()))
    return out


def parse_dump(text):
    """Every module merged into ONE flat graph: `(nodes, wires, nchips)`.

    A chip body is not a separate graph to execute. The root module's wire list
    already contains the cross-boundary wires -- the call site's arguments landing
    on the body's `MicrochipInput` pins, an exec gate driving `_exec_in`, and the
    body's `_exec_out` rejoining the caller's chain via `MicrochipOutput` -- and
    node ids are globally unique across the whole tree. So a simulator needs every
    module's nodes in one id space and nothing else changes.

    Merging is also why this stays backward compatible: a source with no `chip`
    has exactly one module, so the flat graph is what it always was.
    """
    mods = parse_modules(text)
    nodes, wires = {}, []
    for m in mods:
        nodes.update(m["nodes"])
        wires.extend(m["wires"])
    return nodes, wires, mods[0]["nchips"]


def parse_modules(text):
    """Every module in the dump, root first, chips after.

    A `chip` body is a graph in its own right: its own nodes, its own wires, and
    `MicrochipInput`/`MicrochipOutput` pins carrying values across the boundary.
    An external simulator has to run it as a sub-graph, so the dump groups it
    with a `G[...]` header naming the chip node that owns it (`parent=`).

    Node ids are globally unique across the tree, so a flat id space is safe and
    one `Sim` can hold every module at once.
    """
    mods = []
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("G["):
            mods.append({"name": None, "parent": None, "nodes": {},
                         "wires": [], "nchips": 0})
            # The header is space-separated (unlike `props={...}`, which is
            # comma-separated), so split on whitespace -- `_split_top` would
            # swallow the whole line as one field.
            for part in line[2:-1].split():
                k, v = part.split("=", 1)
                if k == "module":
                    mods[-1]["name"] = _parse_lit(v)[1]
                elif k == "parent":
                    mods[-1]["parent"] = (None if v == "-"
                                          else int(v))
        elif line.startswith("N["):
            m = re.match(r"N\[(\d+) kind=(\w+) class=(\S+) props=\{(.*)\} "
                         r"in=\[(.*)\] out=\[(.*)\]\]$", line)
            if not m:
                raise RuntimeError("unparsed N line: %s" % line[:120])
            nid, kind, cls = int(m.group(1)), m.group(2), m.group(3)
            props = {}
            for p in _split_top(m.group(4)):
                k, v = p.split("=", 1)
                props[k.strip()] = _parse_lit(v)
            mods[-1]["nodes"][nid] = Node(nid, kind, cls,
                                          props,
                                          _parse_ports(m.group(5)),
                                          _parse_ports(m.group(6)))
        elif line.startswith("W["):
            m = re.match(r"W\[(\d+):(\S+) -> (\d+):(\S+)\]$", line)
            mods[-1]["wires"].append((int(m.group(1)), m.group(2),
                                      int(m.group(3)), m.group(4)))
        elif line.startswith("M["):
            mods[-1]["nchips"] = int(re.search(r"chips=(\d+)", line).group(1))
    if not mods:
        raise RuntimeError("no G[ module headers; is this --dump-ir-full?")
    return mods


def _compile_dump(path, brz_out=None):
    """Run the compiler with --dump-ir-full; return the dump text.

    Always directs the .brz at brz_out (default: alongside a scratch
    copy) so the real artifact is never touched as a side effect.
    """
    import os
    import shutil
    import tempfile
    if brz_out is None:
        tmp = tempfile.mkdtemp(prefix="irrun")
        brz_out = os.path.join(tmp, "out.brz")
    p = subprocess.run([WS_EXE, "compile", path, "-o", brz_out,
                        "--dump-ir-full"],
                       capture_output=True, text=True, cwd=WS_DIR,
                       encoding="utf-8", errors="replace")
    # rc=0 is the test, and it is a real test now: lua.ws used to exit 1 with 53
    # diagnostics -- 46 mods called above their declaration, a parameter assigned,
    # a var read above its declaration -- and the compiler writes NO artifact when
    # it has diagnostics, so the game-loadable lua.brz could not be built at all.
    # 626 cases had been running against the graph those diagnostics still
    # produced, because the dump was parsed and the exit code never looked at.
    if p.returncode != 0:
        errs = [l.strip() for l in (p.stdout + p.stderr).splitlines()
                if "WS" in l and "Error" in l]
        raise RuntimeError("the compiler rejected %s (rc=%d): %s"
                           % (os.path.basename(path), p.returncode,
                              " | ".join(errs[:4]) or p.stderr[-500:]))
    if "N[" not in p.stderr:
        raise RuntimeError(f"no IR dump; compiler said: "
                           f"{p.stdout[-500:]} {p.stderr[-2000:]}")
    return p.stderr


def dump_source(path, brz_out=None):
    """Compile path with --dump-ir-full; return (nodes, wires, nchips).

    Root module only -- a `chip` body is a separate graph, and a caller that wants
    to execute one needs `dump_source_modules`.
    """
    return parse_dump(_compile_dump(path, brz_out))


def dump_source_modules(path, brz_out=None):
    """Compile path and return every module: root first, then chip bodies.

    Chip bodies carry their own nodes and wires and are addressed by the chip
    node that owns them, so a simulator can run one per instance.
    """
    return parse_modules(_compile_dump(path, brz_out))
