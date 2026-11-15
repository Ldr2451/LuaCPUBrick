"""The model-era harness surface, over the official simulator.

`irrun/irsims.py` used to hand the probes a simulator they walked gate by
gate.  That model is retired: what runs a chip now is the official WireScript
machine, reached through `tools/simdrv` and the shim in
`tests/simdrv_sim.py`.  The scripts under `extras/` were written against the
model's names -- a graph they could walk (`nodes`, `props`), live containers
(`vars.get`, `arrays[...] =`), a host's ports (`inputs`), a run they could
watch tick by tick -- and each of those names describes a host's view of a
running chip just as well as a model's internals, so this module answers it
from the engine's own state rather than from a mirror of the gates:

*   `share_dump` compiles the chip once and keeps the compile's IR TEXT
    beside the save.  A cube-layout emit writes a name label only on the
    access pins of globals ANOTHER grid reads by remote wire, so the save
    alone cannot name the chip's own state (`polyOn`, the row spans, the
    pixel globals behind the `px` outputs); the IR is the same compile and
    does, and the driver pairs its names with the chip's containers -- arrays
    first, then scalars, both in program order, which is how the emit places
    them -- and refuses a `new` whose counts do not pair.
*   `nodes` answers the names the IR carries plus the boundary port labels,
    in the model's property shape so the drivers' lookups stay literal.
*   `vars.get` reads a container through its probe reroute: the engine's live
    state, not a copy.  A pixel global is served from one batched read of the
    whole wall, thrown out when the tick advances or a port is written, so a
    full-wall snapshot costs one round trip.
*   `arrays[...] =` delivers a port's array.  Reads answer what was last
    delivered: the engine keeps an input array's contents in its own
    container and exposes no host read of one, and a host knows what it sent.
    Changing an array mid-run is a rebuild plus a replay of the fixed-seed
    timeline (the shim's `replay`), which is why only the ports that changed
    go to the driver.
*   `run(ticks, on_tick=...)` steps one tick per round trip when a callback
    is given: a port the callback writes has to reach the engine before the
    next tick, and a bulk window lands that change at the window's end.

`colormath.install()` used to patch the model's math gate so `color`
arithmetic ran channel-wise.  The certified table runs `Math*` on numbers
(a colour minus a colour is refused, and the certified `ColorBlend` gate is
deferred), so the generator emits channel-wise math instead: there is
nothing left to patch and `install()` is a no-op that says so.
"""
import os
import sys
import json
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "tests"))
import simdrv_sim as _SD  # noqa: E402

# An IR element type -> the wire spec the driver needs for that port.
ARRAY_KIND = {"color": "LinearColor", "float": "f64", "int": "i64",
              "bool": "bool", "Str": "Str", "string": "Str"}


def _extract(prop, default=""):
    """A model-era property value: `("raw", v)` carried `v`."""
    if isinstance(prop, tuple):
        return prop[1] if len(prop) > 1 else default
    if prop is None:
        return default
    return prop


def _as_float(v, default=0.0):
    if isinstance(v, bool):
        return 1.0 if v else 0.0
    if isinstance(v, (int, float)):
        return float(v)
    return default


def _wire_to_value(v, default=None):
    """A driver's wire answer as the harness' plain value.

    Colour channels land in the engine's FLOAT32, so a channel carries f32
    noise (0.2 becomes 0.20000000298023224) and dividing the brightness
    factor back out keeps it -- six significant digits, the display class
    the sim-law notes pin, is what a colour IS to this simulator."""
    if isinstance(v, dict):
        c = v.get("color")
        if isinstance(c, list):
            return tuple(float("%.6g" % x) if k < 3 else float(x)
                         for k, x in enumerate(c[:4]))
        vec = v.get("vector")
        if isinstance(vec, list):
            return tuple(float(x) for x in vec)
        s = v.get("str")
        if isinstance(s, str):
            return s
        return default
    if isinstance(v, bool):
        return v
    if isinstance(v, (int, float)):
        return float(v)
    if isinstance(v, str):
        return v
    return default


class _Wire:
    """One boundary wire, as the chain drivers walked the model's graph:
    `dst_id` is the OUT pin's NAME (the handle every later lookup takes --
    probes, ports and the IR pairing all key on names, not gate numbers)."""

    def __init__(self, dst_id):
        self.dst_id = dst_id


class _Node:
    def __init__(self, nid, kind, label=None, port=None):
        self.id = nid
        self.kind = kind
        props = {}
        if label is not None:
            props["_label"] = ("raw", label)
        if port is not None:
            props["PortLabel"] = ("raw", port)
        self.props = props


class _Vars:
    """`vars.get(id, default)`: a container's live value through its probe.

    The pixel globals are the common case by far (a wall snapshot is 4096
    reads), so the first one pays a single batched read of the whole wall and
    the rest answer from that cache.  The cache is thrown out when the tick
    advances or a port is written, so nothing reads yesterday's pixel."""

    WALL = 4096

    def __init__(self, sim):
        self.sim = sim
        self.cache = {}
        self.wall = None
        self.tick = None

    def _invalidate(self):
        self.cache = {}
        self.wall = None

    def get(self, nid, default=None):
        sim = self.sim
        if sim.tick != self.tick:
            self.tick = sim.tick
            self._invalidate()
        if nid in self.cache:
            return self.cache[nid]
        if (isinstance(nid, str) and nid[:1] == "g"
                and nid[1:].isdigit() and len(self.wall or {}) < self.WALL):
            if self.wall is None:
                labels = ["g%d" % i for i in range(self.WALL)]
                got = sim._send({"cmd": "vreadmany",
                                 "labels": labels}).get("values") or []
                self.wall = {}
                for k, nm in enumerate(labels):
                    self.wall[nm] = (_wire_to_value(got[k])
                                     if k < len(got) else None)
            v = self.wall.get(nid)
            self.cache[nid] = v if v is not None else default
            return self.cache[nid]
        r = sim._send({"cmd": "vread", "label": nid})
        v = _wire_to_value(r.get("value"), default)
        self.cache[nid] = v
        return v


class _Arrays:
    """`arrays[id] = values` delivers a port's array; `arrays.get(id)` reads
    back what was last delivered."""

    def __init__(self, sim):
        self.sim = sim
        self.held = {}

    def __getitem__(self, key):
        return self.held.get(key)

    def get(self, key, default=None):
        v = self.held.get(key)
        if v is not None:
            return list(v)
        # A chip's own array OUT port, never delivered by the host: read it
        # through the element probes sized from the source.
        return self.sim.chip_array(key)

    def __setitem__(self, key, values):
        sim = self.sim
        kind = (sim.port_kind or {}).get(key)
        vals = list(values)
        if kind == "vector":
            raise ValueError("%s is a vector port, not an array" % key)
        if kind is not None and kind.endswith("[]"):
            kind = ARRAY_KIND.get(kind[:-2], "f64")
        elif kind is None:
            kind = ("LinearColor" if vals and isinstance(vals[0], (tuple, list))
                    else "Str" if vals and isinstance(vals[0], str) else "f64")
        if kind == "LinearColor":
            # A driver reading a chip's color port back gets a tuple per
            # staged colour; nothing staged yet reads as white, the same
            # fill the chips' own `resize(N, Color(1,1,1,1))` boot uses.
            vals = [list(map(float, c[:4])) if isinstance(c, (tuple, list))
                    else [1.0, 1.0, 1.0, 1.0] for c in vals]
        elif kind in ("f64", "i64"):
            vals = [float(x) for x in vals]
        self.held[key] = list(values)
        sim.inputs = dict(sim.inputs, **{key: {"arr": kind, "values": vals}})


class Sim(_SD.Sim):
    """The shim's `Sim` plus the names the probe scripts were written to."""

    def __init__(self, *a, **kw):
        ws = kw.pop("ws", None)
        _SD.Sim.__init__(self, *a, **kw)
        self.vars = _Vars(self)
        self.arrays = _Arrays(self)
        self.port_kind = {}
        self._nodes = None
        self._load_port_kinds(ws)

    def _load_port_kinds(self, ws=None):
        """The port TYPES the compile's IR states: a `color[]` port needs an
        element kind no JSON shape tells the driver, and a `vector` port
        takes one wire value, not an array. The same source tells the
        probes how big the chip's own arrays get at boot (`NAME.resize(64,`
        there), which is how far it is worth paying for element probes."""
        if self.ir:
            with open(self.ir, encoding="utf-8", errors="replace") as f:
                for line in f:
                    if " = in " not in line:
                        continue
                    for t in line.split(" "):
                        if t.startswith("%"):
                            rest = line.split(" = in ", 1)
                            if len(rest) > 1:
                                self.port_kind[t[1:].rstrip()] = \
                                    rest[1].split(" ")[0]
                            break
        if ws and os.path.exists(ws):
            import re
            want = {}
            outs = []
            with open(ws, encoding="utf-8", errors="replace") as f:
                for line in f:
                    m = re.match(r"\s*([A-Za-z_][A-Za-z0-9_]*)\.resize\((\d+),",
                                 line)
                    if m:
                        n = int(m.group(2))
                        if n <= 256:
                            want[m.group(1)] = max(
                                want.get(m.group(1), 0), n)
                        continue
                    # An ARRAY OUT port is an array a driver wants the
                    # CONTENTS of (the chain drivers read a chip's staged
                    # ports every tick). The declaration says which source
                    # container feeds it; its boot size is the probe range,
                    # and a source with no literal resize gets the protocol
                    # cap -- the same 256 the resize rule already allows.
                    m = re.match(r"\s*out\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*"
                                 r"(?:float|color|int|bool|Str)\[\]\s*=\s*"
                                 r"([A-Za-z_][A-Za-z0-9_]*)", line)
                    if m:
                        outs.append((m.group(1), m.group(2)))
            if want or outs:
                self._arr_on = True
                for k, n in want.items():
                    self._arr_ranges[k] = [[0, n]]
                for onm, src in outs:
                    self._arr_ranges[onm] = [[0, want.get(src, 256)]]
        if not self.ir:
            return
        with open(self.ir, encoding="utf-8", errors="replace") as f:
            for line in f:
                if " = in " not in line:
                    continue
                for t in line.split(" "):
                    if t.startswith("%"):
                        rest = line.split(" = in ", 1)
                        if len(rest) > 1:
                            ty = rest[1].split(" ")[0]
                            self.port_kind[t[1:].rstrip()] = ty
                        break

    def _ports(self, inp):
        """The shim's port feed, with the IR's port types applied: a tuple on
        a `vector` port becomes one vector value, a bare list on a
        `color[]` port the element kind it needs (even an empty one)."""
        kind = self.port_kind
        si = {}
        for k, v in (inp or {}).items():
            ty = kind.get(k)
            if ty == "vector" and isinstance(v, (tuple, list)):
                si[k] = {"vector": [float(x) for x in v]}
            elif ty and ty.endswith("[]") and isinstance(v, (tuple, list)) \
                    and not (isinstance(v, dict)):
                ek = ARRAY_KIND.get(ty[:-2], "f64")
                vals = list(v)
                if ek == "LinearColor":
                    vals = [list(map(float, c[:4])) if isinstance(c, (tuple, list))
                            else c for c in vals]
                elif ek in ("f64", "i64"):
                    vals = [float(x) for x in vals]
                si[k] = {"arr": ek, "values": vals}
            else:
                si[k] = v
        return _SD.Sim._ports(self, si)

    def run(self, ticks, on_tick=None, **kw):
        if on_tick is not None:
            # One round trip per tick, so a port written by the callback is
            # in front of the engine before the next tick runs.
            return _SD.Sim.run(self, ticks, on_tick=on_tick,
                               live_inputs=True, **kw)
        return _SD.Sim.run(self, ticks, **kw)

    def reset(self):
        _SD.Sim.reset(self)
        self.vars._invalidate()
        self.arrays.held = {}

    @property
    def nodes(self):
        if self._nodes is None:
            self._nodes = self._build_nodes()
        return self._nodes

    def _src_cache(self):
        if not hasattr(self, "_srcc"):
            self._srcc = {}
        return self._srcc

    def _build_src(self, pair):
        """The model's `(kind, sid, sport, tail)` for an out pin's source.

        The engine answers the same question from its own graph: `scanlabels`
        finds the pin's gate and every input link's source gate and class.
        The PIN NAME is the handle for everything after this -- probes are
        installed under it (add_probes pairs a boundary pin's label with its
        container), so kind picks ARRAY or VAR reading and sid stays the
        name. A source that is neither (a compute gate) reads through the
        pin's own probe reroute: the machine's live port value."""
        name, _link = pair
        c = self._src_cache()
        hit = c.get(name)
        if hit is None:
            r = self._send({"cmd": "scanlabels", "label": name})
            hit = (0, name)
            for h in r.get("hits", []):
                if "MicrochipOutput" not in h.get("class", ""):
                    continue
                for sr in h.get("srcs") or []:
                    cls = sr.get("srcClass") or ""
                    if cls.endswith("ArrayVar"):
                        hit = (1, name)
                        break
                    if cls.endswith("Var") or cls.endswith("MapVar"):
                        hit = (4, name)
                        break
                if hit != (0, name):
                    break
            c[name] = hit
        return hit + (0, None)

    def _var_id(self, sid):
        return sid

    def _in_val(self, pid, link=None, default=None):
        """A port's live value: the probe reroute `new` installed under the
        pin's name; `vars.get` caches per tick so a hook reading several
        ports pays one round trip each, not two."""
        v = self.vars.get(pid, default)
        return v if v is not None else default

    @property
    def wires(self):
        return [_Wire(nm) for nm in self.out_labels]

    def _build_nodes(self):
        nodes = {}
        if self.ir:
            with open(self.ir, encoding="utf-8", errors="replace") as f:
                for line in f:
                    is_arr = " = ArrayVar {" in line
                    if not (is_arr or " = Var {" in line):
                        continue
                    for t in line.split(" "):
                        if t.startswith("%"):
                            nm = t[1:].rstrip()
                            nodes[nm] = _Node(nm, "ArrayVar" if is_arr
                                              else "Var", label=nm)
                            break
        for nm in self.in_labels:
            nodes[nm] = _Node(nm, "Input", port=nm)
        for nm in self.out_labels:
            nodes[nm] = _Node(nm, "Output", port=nm)
        return nodes


    def chip_array(self, name):
        """A chip array's CONTENTS, through the element probes `new` was
        asked for (sized from the source's `.resize(N,` at boot). Unprobed,
        the engine keeps the container private and this answers None."""
        rng = self._arr_ranges.get(name)
        if not rng:
            return None
        labels = []
        for start, cnt in rng:
            labels += ["%s[%d]" % (name, i) for i in range(start, start + cnt)]
        got = self._send({"cmd": "vreadmany", "labels": labels}).get("values")
        if got is None:
            return None
        # Past the container's own length the element probes answer `none`: the
        # port's contract is "the count IS the length", so the array a driver
        # sees stops there -- an element that never existed is not a zero.
        n = self._send({"cmd": "vread", "label": name}).get("value")
        if isinstance(n, (int, float)) and not isinstance(n, bool):
            got = got[:int(n)]
        return [_wire_to_value(v, 0.0) for v in got]


def sim_from_dump(path):
    """A Sim over the artifact a `share_dump` wrote -- nothing compiled."""
    with open(path, encoding="utf-8") as f:
        art = json.load(f)
    return Sim(art["brz"], ir=art["ir"], ws=art.get("ws"))


def share_dump(ws_path, path):
    """Compile the chip once, keep the save and the IR text that names it."""
    work = tempfile.mkdtemp(prefix="irsims")
    brz = os.path.join(work, "chip.brz")
    ir = os.path.join(work, "chip.wsir")
    _SD.compile_ws(ws_path, brz, emit_ir=ir)
    with open(path, "w", encoding="utf-8") as f:
        json.dump({"brz": brz, "ir": ir, "ws": os.path.abspath(ws_path)}, f)
    return path
