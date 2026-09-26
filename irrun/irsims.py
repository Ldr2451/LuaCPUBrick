"""Tick-based IR simulator for lua.ws.

Parses `wirescript compile --dump-ir-full` output and simulates
the exec-chain model tick by tick, producing log/out ports/globals
comparable to the Lua 5.5 oracle.
"""
from __future__ import annotations

import math
import os
import re
import sys
from typing import Any, Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from irgraph import Graph
from irdump import dump_source, Node
import gates as GATES

MAX_TICKS = 5000
_LOG_LINES = 32       # appends the log keeps, which is not lines: see the push
_RE_STR = re.compile(r'"([^"]*)"')
_WS_ESCAPES = {
    "a": "\a", "b": "\b", "f": "\f", "n": "\n", "r": "\r",
    "t": "\t", "v": "\v", "\\": "\\", '"': '"', "'": "'",
}


def _unescape_ws(s: str) -> str:
    out = []
    i, n = 0, len(s)
    while i < n:
        c = s[i]
        if c == "\\" and i + 1 < n:
            d = s[i + 1]
            if d in _WS_ESCAPES:
                out.append(_WS_ESCAPES[d])
                i += 2
                continue
            if d == "x" and i + 3 < n:
                try:
                    out.append(chr(int(s[i + 2:i + 4], 16)))
                    i += 4
                    continue
                except ValueError:
                    pass
            if d.isdigit() and i + 3 < n and s[i + 1:i + 4].isdigit():
                try:
                    out.append(chr(int(s[i + 1:i + 4]) % 256))
                    i += 4
                    continue
                except ValueError:
                    pass
            if d == "\n":
                i += 2
                continue
            out.append(c)
            i += 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


def _extract(val):
    if val is None:
        return None
    if isinstance(val, tuple) and len(val) == 2 and isinstance(val[0], str):
        tag, v = val
        if tag in ("rt", "val"):
            return v
        if tag == "none":
            return None
        if isinstance(v, str) and v.startswith('String("') and v.endswith('")') and len(v) >= 9:
            return _unescape_ws(v[8:-2])
        return v
    if isinstance(val, str) and val.startswith('String("') and val.endswith('")') and len(val) >= 9:
        return _unescape_ws(val[8:-2])
    return val


def _as_float(v, default=0.0):
    try:
        return float(v)
    except (TypeError, ValueError):
        return default


# --- float gates, IEEE rather than Python -----------------------------------
# Python raises where a float gate returns a value: 1.0/0.0 is ZeroDivisionError
# (a gate divides to inf), math.log(0) and math.sqrt(-1) are ValueError (gates
# answer -inf and nan), and (-8.0)**0.5 is a *complex number* (a gate answers
# nan).  Every one of those was caught and answered 0.0, so the chip printed
# 0.0 for `1/0`, 0.0 for `1/(0.0*-1)` instead of -inf, and a complex for
# `(-8)^0.5`.  The oracle is PUC Lua on IEEE doubles, and it is the reference.
_NAN = math.copysign(float("nan"), -1.0)   # the x86 default QNaN, sign bit set
_INF = float("inf")


def _signed_inf(neg: bool) -> float:
    return -_INF if neg else _INF


def _fdiv(a: float, b: float) -> float:
    if b == 0.0:
        if a == 0.0 or a != a:
            return _NAN
        return _signed_inf(math.copysign(1.0, a) * math.copysign(1.0, b) < 0)
    return a / b


def _fpow(a: float, b: float) -> float:
    if a != a or b != b:
        return _NAN
    if a == 0.0:
        if b < 0.0:
            return _signed_inf(math.copysign(1.0, a) < 0)
        return 1.0 if b == 0.0 else 0.0
    if a < 0.0 and b != math.floor(b):
        return _NAN
    try:
        return float(a ** b)
    except (OverflowError, ValueError):
        return _INF


def _fsqrt(a: float) -> float:
    return _NAN if a < 0.0 else math.sqrt(a)


def _fln(a: float) -> float:
    if a > 0.0:
        return math.log(a)
    return -_INF if a == 0.0 else _NAN


def _fmod(a: float, b: float, floored: bool) -> float:
    if b == 0.0 or a != a or b != b:
        return _NAN
    r = math.fmod(a, b)
    if floored and r != 0.0 and (r < 0.0) != (b < 0.0):
        r += b
    return r


def _as_int(v, default=0):
    try:
        return int(_as_float(v, float(default)))
    except (TypeError, ValueError):
        return default


def _as_bool(v):
    if isinstance(v, bool):
        return v
    if isinstance(v, (int, float)):
        return v != 0
    if isinstance(v, str):
        return v.lower() not in ("false", "", "nil", "none")
    return bool(v)


def _as_str(v):
    if v is None:
        return ""
    if isinstance(v, tuple):
        return str(v[1])
    return str(v)


def lit_value(lit):
    return lit[1] if isinstance(lit, tuple) and len(lit) == 2 else lit


class Sim:
    def __init__(self, nodes: dict[int, Node], wires: list):
        self.nodes = nodes
        self.wires = wires
        self.in_wires: dict[tuple[int, str], list] = {}
        self.out_wires: dict[tuple[int, str], list] = {}
        for w in wires:
            self.in_wires.setdefault((w.dst_id, w.dst_port), []).append(w)
            self.out_wires.setdefault((w.src_id, w.src_port), []).append(w)
        # Wire layout never changes after construction, so which source feeds an
        # input port, and whether that source is pure, are static facts.  They
        # are resolved once here instead of on every read: _in_val runs about
        # half a million times per simulated program.
        self._src_cache: dict[tuple[int, str], tuple] = {}
        self.exec_queue: set[tuple[int, str]] = set()
        self.fired_nodes: set[int] = set()
        self.fired_ports: set[tuple[int, str]] = set()
        self.value_ready: set[tuple[int, str]] = set()
        self.vars: dict[int, Any] = {}
        self.arrays: dict[int, list] = {}
        self.maps: dict[int, dict] = {}
        self.log = ""
        self.tick = 0
        self._deferred: dict[int, list] = {}
        self._chg_state: dict = {}
        self.input_ids: list[int] = []
        self.inputs: dict[str, Any] = {}
        self._eval_stack: set[int] = set()
        self._unimpl_warned: set[str] = set()
        self._loglines_id: int | None = None
        self._log_appends: list[str] = []
        # A compiler `_Unsupported` placeholder is a silent miscompile: it reads
        # 0 on hardware, so running it produces confidently wrong results (it
        # once shifted every bytecode operand by one array).  Fail loudly here,
        # naming the binding, instead of simulating a circuit nobody intended.
        ph = GATES.placeholder_nodes(self.nodes)
        if ph:
            where = ", ".join(f"nid={n}" + (f" ({b})" if b else "") for n, _c, b in ph[:8])
            raise RuntimeError(
                "wirescript lowered %d _Unsupported placeholder(s) (%s...): the "
                "program has a compile error or an expression the compiler "
                "cannot lower. Fix the source instead of running this."
                % (len(ph), where))
        for _nid, _nd in self.nodes.items():
            if "ArrayVar" in _nd.cls and _extract(
                    _nd.props.get("_label", ("raw", ""))) == "logLines":
                self._loglines_id = _nid
                break
        # Label -> node, for the structural invariants below and for anything
        # else that wants to read a chip var by name.  Arrays and scalars get
        # their own maps, and each prefers the node that actually HOLDS the
        # value: a label like fVaB or vaTop also names the gates that read and
        # write it, and asking one of those for the value gives the wrong node.
        self._by_label: dict[str, int] = {}
        self._arr_by_label: dict[str, int] = {}
        self._var_by_label: dict[str, int] = {}
        for _nid, _nd in self.nodes.items():
            _lbl = _extract(_nd.props.get("_label", ("raw", "")))
            if isinstance(_lbl, str) and _lbl:
                self._by_label.setdefault(_lbl, _nid)
                if "ArrayVar" in _nd.cls:
                    self._arr_by_label.setdefault(_lbl, _nid)
                elif _nd.cls == "WireGraphPseudo_Var":
                    self._var_by_label.setdefault(_lbl, _nid)
        self._pure_ids: set[int] = set(
            nid for nid, nd in self.nodes.items()
            if ("Expr_" in nd.cls and "ChangeDetector" not in nd.cls)
            or "ServerUptime" in nd.cls
        )
        self._dirty: set[int] = set(self._pure_ids)
        self.clock_ids: list[int] = []
        self.tick_delta: int = 1
        self._queue_carry: dict[int, dict] = {}
        self._timer_state: dict[int, list] = {}
        for nid, nd in self.nodes.items():
            if nd.cls == "BrickComponentType_Clock":
                self.clock_ids.append(nid)
        self.chg_inputs: dict[int, str] = {}
        for w in wires:
            src = self.nodes.get(getattr(w, 'src_id', None))
            dst = self.nodes.get(getattr(w, 'dst_id', None))
            if src and 'Internal_MicrochipInput' in src.cls and dst and 'Expr_ChangeDetectorExec' in dst.cls and getattr(w, 'src_port', None) == 'RER_Output':
                label = _extract(src.props.get('PortLabel', ('raw', '')))
                self.chg_inputs[getattr(w, 'dst_id', None)] = label if isinstance(label, str) else str(label)
        # Every input PORT node, so a value that moves can be re-read.  The queue
        # only fires them once, from the initial pass, which left a port holding
        # whatever it read at tick 0: the cached prop is returned before the live
        # read (see _out_val), so `busy` never noticed `run` going low and no
        # case could test the ORDER of two input edges at all.
        self.port_nodes: list[int] = []
        self.port_label: dict[int, str] = {}
        for nid, nd in self.nodes.items():
            if 'Internal_MicrochipInput' in nd.cls:
                label = _extract(nd.props.get('PortLabel', ('raw', '')))
                self.port_nodes.append(nid)
                self.port_label[nid] = label if isinstance(label, str) else str(label)
        self.port_seen: dict[int, object] = {}
        for w in wires:
            dn = self.nodes.get(w.src_id)
            if dn and dn.kind == "Input":
                if w.src_id not in self.input_ids:
                    self.input_ids.append(w.src_id)
        self._halted_id = None
        self._err_id = None
        for nid, nd in nodes.items():
            lbl = _extract(nd.props.get('_label', ('raw', '')))
            if lbl == 'vmHalted':
                self._halted_id = nid
            elif lbl == 'errV' and self._err_id is None:
                self._err_id = nid
        self.reset()

    def _seed_inputs(self):
        for nid in self.input_ids:
            self.exec_queue.add((nid, "RER_Output"))

    def reset(self):
        """Put the sim back in its just-constructed state, keeping the wiring.

        The graph, the input seed and the source cache are static, so a whole
        batch of programs can share one Sim.  Rebuilding them instead costs
        about a second per program (124k wires, 59k nodes), which used to
        dominate every test case.
        """
        self.exec_queue = set()
        self.fired_nodes = set()
        self.fired_ports = set()
        self.value_ready = set()
        self.vars = {}
        self.arrays = {}
        self.maps = {}
        # the port values this Sim has already pushed.  Clearing it makes the
        # first tick after a reset push every port again: node props survive
        # reset(), so a shared Sim would otherwise carry the PREVIOUS case's
        # input values and a case could never change one.
        self.port_seen = {}
        self.log = ""
        self._log_appends = []
        self.tick = 0
        self._deferred = {}
        self._chg_state = {}
        self._eval_stack = set()
        self._unimpl_warned = set()
        self._queue_carry = {}
        self._timer_state = {}
        self._dirty = set(self._pure_ids)
        self.tick_delta = 1
        self.inputs = {}
        # True when the run ended because the chip said it was done, not because
        # the budget ran out.  A caller that reads a truncated program as a
        # finished one is how a probe lies, so this is one flag and no cleverness:
        # whether a program is stuck or merely slow is not knowable in advance,
        # and the detector that tried to guess (a fingerprint of the log, the
        # table counts and the frame depth) was right about the stuck case and
        # wrong about fib, which is the failure mode that matters.
        self.finished = False
        self._seed_inputs()

    def run(self, max_ticks: int = MAX_TICKS, on_tick=None):
        from collections import deque
        prev = self.tick
        for tick in range(max_ticks):
            self.tick = tick
            self.tick_delta = max(1, tick - prev)
            prev = tick
            self.tick_done: set[tuple[int, str]] = set()
            # NOTE: input NODES fire once from the initial queue.  Re-firing them
            # EVERY tick would reset latched state (e.g. re-latch the program
            # source and re-parse forever), so a port is re-read below only when
            # its value really moved -- which is what hardware does, and it is
            # what lets a case order two input edges.
            if tick == 0:
                for nid in sorted(self.nodes):
                    nd = self.nodes[nid]
                    if ("WireGraphPseudo_Var" in nd.cls
                            or "WireGraphPseudo_ArrayVar" in nd.cls
                            or "WireGraphPseudo_MapVar" in nd.cls
                            or nd.cls == "_Literal"):
                        self._do_literal(nid)
            else:
                for nid in self.port_nodes:
                    label = self.port_label[nid]
                    if label not in self.inputs:
                        continue
                    val = self.inputs[label]
                    if isinstance(val, (list, tuple)):
                        # an array port keeps its own storage, so a new list has
                        # to replace it or the reader sees the old contents
                        if list(val) == self.port_seen.get(nid):
                            continue
                        self.port_seen[nid] = list(val)
                        self.arrays[self._arr_id(nid)] = list(val)
                    else:
                        if val == self.port_seen.get(nid):
                            continue
                        self.port_seen[nid] = val
                    # re-queue the port: this pushes its RER_Output wires, which
                    # is how the Change detectors downstream get to fire, and it
                    # refreshes the cached prop the pure readers see
                    self._out_val(nid, 'RER_Output', val)
                    for w in self.out_wires.get((nid, "RER_Output"), []):
                        self.exec_queue.add((w.dst_id, w.dst_port))
            # Same-tick exec drain (hardware exec pulses propagate
            # combinationally within a tick; Clocks/BufferTicks pace across
            # ticks). Interleaved pure-value fixpoint keeps exec decisions
            # reading fresh data instead of last tick's values.
            q: deque[tuple[int, str]] = deque(
                sorted(self.exec_queue, key=lambda x: x[0]))
            self.exec_queue = set()
            for cid in self.clock_ids:
                period = 1
                try:
                    iv = self.nodes[cid].props.get("IntervalSeconds", ("float", 0.01))
                    iv = _extract(iv)
                    period = max(1, int(round(float(iv) / 0.01)))
                except (TypeError, ValueError):
                    period = 1
                if tick % period == 0:
                    self.tick_done.add((cid, "Pulse"))
                    self.fired_nodes.add(cid)
                    for w in self.out_wires.get((cid, "Pulse"), []):
                        if (w.dst_id, w.dst_port) not in self.tick_done:
                            q.append((w.dst_id, w.dst_port))
            for tgt in self._deferred.pop(tick, []):
                if tgt not in self.tick_done:
                    q.append(tgt)
            guard = 0
            while q:
                nid, port = q.popleft()
                if (nid, port) in self.tick_done:
                    continue
                self.tick_done.add((nid, port))
                self.fired_nodes.add(nid)
                self.fired_ports.add((nid, port))
                node = self.nodes.get(nid)
                if node is None:
                    continue
                nq: set[tuple[int, str]] = set()
                self._exec_node(nid, node, nq)
                for item in sorted(nq, key=lambda x: x[0]):
                    if item not in self.tick_done:
                        q.append(item)
                guard += 1
                if guard > 500000:
                    break
            self._deferred = {k: v for k, v in self._deferred.items() if k > tick}
            if on_tick is not None:
                on_tick(self, tick)
            # The clock keeps ticking after a program finishes, which used to
            # burn the rest of the tick budget (1.9s for a one-line program).
            # vmHalted is the chip's own "nothing left to do" flag.
            if self._halted_id is not None and self.vars.get(self._halted_id):
                if not self.exec_queue and not self._deferred:
                    self.finished = True
                    break
            # A program that has an error is finished, whatever the clock is
            # doing, and the queue does not necessarily drain after one: a
            # source too long to lex errored and still ran its whole 200k-tick
            # budget, 63 seconds for a program that had already given up.
            if self._err_id is not None and self.vars.get(self._err_id):
                self.finished = True
                break
        return self.capture()

    def _run_value_fixpoint(self):
        # Evaluate dirty pure-expression gates to fixpoint. Exec gates must
        # only fire via the exec chain; several carry constant Value props
        # that would otherwise fire spuriously.
        for _ in range(20):
            batch = sorted(self._dirty)
            self._dirty.clear()
            fired_any = False
            for nid in batch:
                if nid in self.fired_nodes and self._has_exec_out(nid):
                    continue
                if self._has_value_input_ready(nid):
                    self.tick_done.add((nid, "__val__"))
                    self.fired_nodes.add(nid)
                    self._exec_node(nid, self.nodes[nid], set())
                    fired_any = True
            if not self._dirty:
                break
            if not fired_any:
                self._dirty.clear()
                break

    def _has_exec_out(self, nid: int) -> bool:
        for w in self.out_wires.get((nid, ""), []):
            pass
        for p in self.nodes[nid].pout:
            if "Exec" in p[0]:
                return True
        return False

    def _has_value_input_ready(self, nid: int) -> bool:
        for p in self.nodes[nid].pin:
            pname = p[0]
            if (pname in ("Value", "Input", "Character", "Key", "Index",
                          "Start", "Length", "Size", "Exponent",
                          "X", "Y", "Z", "R", "G", "B", "A")
                    or pname.startswith("Input") or pname.startswith("bInput")
                    or pname in ("RER_Output",)):
                if self._in_val(nid, pname, None) is not None:
                    return True
        return False

    def chip_var(self, name, default=None):
        """The value of a named chip var, read from the node that holds it."""
        nid = self._var_by_label.get(name) or self._by_label.get(name)
        return default if nid is None else self.vars.get(nid, default)

    def set_chip_var(self, name, value):
        """Write a named chip var.  For probes: the invariants read the same way,
        so damaging state this way is how each of them is proved live."""
        nid = self._var_by_label.get(name) or self._by_label.get(name)
        if nid is not None:
            self.vars[nid] = value
        return nid

    def chip_array(self, name):
        """A named chip array, as the Python list the sim keeps for it."""
        nid = self._arr_by_label.get(name) or self._by_label.get(name)
        return None if nid is None else self._arr_list(self._arr_id(nid))

    def state_invariants(self, clean: bool = True) -> list[str]:
        """Structural invariants that must hold in every state; [] means clean.

        These are the ones a case cannot express, because the damage shows up
        LATER: the frame arrays are pushed and popped in pairs, so one missing
        push or pop leaves every later frame reading the wrong slot, and the
        program still prints plausible output.  The loop-depth bug lived here for
        552 green cases, and fForDepth was added to that group by hand and could
        just as easily have been left out of it.

        So they are checked in the simulator, for every case, rather than as
        cases of their own:

          * the eight frame arrays are the same length (one push, one pop, each)
          * pcallDepth counts the pcall markers actually on the frame stack
          * the vararg pointer is at or above the current frame's vararg base, so
            a call cannot leave it below where the callee starts
          * the arenas stay in range: the table counters, every table's length,
            and the closure fill's cursor
          * after a CLEAN finish: no loop, no protected call and no micro-step
            machine is left live.  A program that halted *with an error* is
            except, and has to be: it stops exactly where the error hit it, so
            the 16 loops of a "too many nested numeric loops" and the half-read
            format of a bad %d are both still in flight when it halts.  That was
            this check's first version being wrong rather than the chip.
        """
        bad = []
        var = self.chip_var
        arr = self.chip_array

        arrays = ("fFunc", "fBase", "fRetA", "fRetBase", "fRetPC", "fRetN",
                  "fVaB", "fForDepth")
        sizes = {}
        for name in arrays:
            a = arr(name)
            if a is None:
                bad.append("no array labelled %s" % name)
                continue
            sizes[name] = len(a)
        if sizes and len(set(sizes.values())) != 1:
            bad.append("frame arrays out of step: %s"
                       % ", ".join("%s=%d" % kv for kv in sorted(sizes.items())))

        fn = arr("fFunc")
        if fn is not None:
            marks = sum(1 for v in fn if v == 99)
            depth = var("pcallDepth", 0)
            if marks != depth:
                bad.append("pcallDepth=%s but %d pcall marker(s) on the stack"
                           % (depth, marks))
        vab = arr("fVaB")
        if vab and var("vaTop", 0) < vab[-1]:
            bad.append("vaTop=%s is below the frame's vararg base %s"
                       % (var("vaTop"), vab[-1]))
        # the arenas: a leak shows up as "out of memory" many operations later,
        # which is the same "wrong later" shape as the frame stacks.  The limits
        # are the array lengths, because the chip resizes them to its own consts
        # at reset -- so a counter past one is writing outside its own storage.
        tlen, tprev = arr("tLen"), arr("tPrev")
        tcount, theap = var("tCount"), var("tHeap")
        if tlen and tcount is not None and tcount > len(tlen):
            bad.append("tCount=%s past the %d tables the chip sized"
                       % (tcount, len(tlen)))
        if tprev and theap is not None and theap > len(tprev):
            bad.append("tHeap=%s past the %d entries the chip sized"
                       % (theap, len(tprev)))
        if tlen and tcount is not None:
            over = [(i, v) for i, v in enumerate(tlen[:int(tcount)])
                    if v > (len(tprev) if tprev else 0)]
            if over:
                bad.append("table lengths out of range: %s" % over[:4])
        if var("cloK") is not None and var("cloK", 0) > var("cloN", 0):
            bad.append("cloK=%s past cloN=%s" % (var("cloK"), var("cloN")))
        if clean:
            for name, why in (("forDepth", "numeric loop"),
                              ("pcallDepth", "protected call"),
                              ("nxActive", "micro-step machine")):
                v = var(name)
                if v:
                    bad.append("finished with %s=%s (%s still live)"
                               % (name, v, why))
        return bad

    def capture(self):
        og = self._out_globals()
        return {
            "log": self.log,
            "outGlobals": og,
            "outArr": og.get("outArr", [0.0] * 64),
            "halted": not self.exec_queue and not self._deferred,
        }

    def _out_globals(self):
        result = {}
        for w in self.wires:
            dn = self.nodes.get(w.dst_id)
            if not dn or dn.kind != "Output":
                continue
            pl = _extract(dn.props.get("PortLabel", ("raw", "")))
            key = pl if isinstance(pl, str) else f"out_{w.dst_id}"
            if isinstance(key, str) and key.startswith("String("):
                m = _RE_STR.search(key)
                if m:
                    key = m.group(1)
            for inw in self.in_wires.get((w.dst_id, "RER_Input"), []):
                src = self.nodes.get(inw.src_id)
                val = self._in_val(w.dst_id, "RER_Input", None)
                if val is not None and not (isinstance(val, str) and val.startswith("String(")):
                    result[key] = val
                    break
                if src:
                    raw = src.props.get(inw.src_port, ("raw", ""))
                    v = _extract(raw)
                    if isinstance(v, str) and v.startswith("String("):
                        m = _RE_STR.search(v)
                        if m:
                            v = m.group(1)
                    result[key] = v
                    break
        return result

    def _is_pure(self, cls: str) -> bool:
        return ("Expr_" in cls and "ChangeDetector" not in cls) or "ServerUptime" in cls

    def _build_src(self, key: tuple[int, str]) -> tuple:
        """Resolve an input port's static wiring once.

        Returns (kind, src_id, src_port, tail) where kind 1/2/3 is a live
        ArrayVar/MapVar/Var source, 4 is a Var_Get (its readiness changes every
        tick, so it is still checked on each read) and 0 means no direct source
        and the tail carries the full wire list.  tail holds the
        (wire, source node, is_pure) triples the read has to fall back on.
        """
        nid, port = key
        ins = self.in_wires.get(key, [])
        kind = 0
        sid = 0
        sport = ""
        for i, w in enumerate(ins):
            src = self.nodes.get(w.src_id)
            if not src:
                continue
            cls = src.cls
            if "WireGraphPseudo_ArrayVar" in cls:
                kind, sid, sport, start = 1, w.src_id, w.src_port, i + 1
                break
            if "WireGraphPseudo_MapVar" in cls:
                kind, sid, sport, start = 2, w.src_id, w.src_port, i + 1
                break
            if "WireGraphPseudo_Var" in cls:
                kind, sid, sport, start = 3, w.src_id, w.src_port, i + 1
                break
            if "Var_Get" in cls:
                # a Var_Get that is not ready this tick must let the read fall
                # through, so keep this wire in the tail
                kind, sid, sport, start = 4, w.src_id, w.src_port, i
                break
        else:
            start = 0
        tail = []
        for w in ins[start:]:
            src = self.nodes.get(w.src_id)
            tail.append((w, src, self._is_pure(src.cls) if src else False))
        info = (kind, sid, sport, tuple(tail))
        self._src_cache[key] = info
        return info

    def _in_val(self, nid: int, port: str, default: Any = None):
        key = (nid, port)
        info = self._src_cache.get(key)
        if info is None:
            info = self._build_src(key)
        kind, sid, sport, tail = info
        if kind == 1:
            # Return the live list, not a copy: gates that only read it
            # (SourceRef of append/slice/copyFrom) never mutate, and copying
            # a 512-instruction bytecode array on every read dominated sim
            # time.  Consumers that write use _arr_list() instead.
            if sid in self.arrays:
                return self.arrays[sid]
            return self._default_for(self.nodes[sid], sport)
        if kind == 2:
            if sid in self.maps:
                return self.maps[sid]
            return self._default_for(self.nodes[sid], sport)
        if kind == 3:
            return self.vars.get(sid, self._default_for(self.nodes[sid], sport))
        if kind == 4 and (sid, sport) in self.value_ready:
            vid = self._var_id(sid)
            if vid is not None:
                return self.vars.get(vid, default)
        for w, src, pure in tail:
            if not src:
                continue
            if pure and w.src_id not in self._eval_stack:
                # Pull evaluation: pure gates are side-effect-free functions
                # of their inputs, so compute on demand for fresh values
                # instead of trusting possibly-stale cached outputs.
                self._eval_stack.add(w.src_id)
                try:
                    self._exec_node(w.src_id, src, set())
                finally:
                    self._eval_stack.discard(w.src_id)
            if (w.src_id, w.src_port) in self.value_ready:
                pv = src.props.get(w.src_port)
                if pv:
                    return _extract(pv)
                if "Internal_MicrochipInput" in src.cls:
                    label = _extract(src.props.get('PortLabel', ('raw', '')))
                    if isinstance(label, str) and label in self.inputs:
                        return self.inputs[label]
        if not tail:
            pv = self.nodes[nid].props.get(port)
            if pv:
                return _extract(pv)
        return default

    def _default_for(self, node: Node, port: str):
        iv = node.props.get("InitialValue", ("raw", ""))
        return _extract(iv) if isinstance(iv, tuple) else iv

    def _out_val(self, nid: int, port: str, val: Any):
        if isinstance(val, bool):
            self.nodes[nid].props[port] = ("bool", val)
        elif isinstance(val, int):
            self.nodes[nid].props[port] = ("int", val)
        elif isinstance(val, float):
            self.nodes[nid].props[port] = ("float", val)
        elif val is None:
            self.nodes[nid].props[port] = ("none", 0)
        else:
            # runtime strings, tuples, lists, dicts: opaque tag so
            # _extract passes them through untouched.
            self.nodes[nid].props[port] = ("rt", val)
        self.value_ready.add((nid, port))
        for w in self.out_wires.get((nid, port), []):
            if w.dst_id in self._pure_ids:
                self._dirty.add(w.dst_id)

    def _var_id(self, nid: int, port: str = "VarRef") -> Optional[int]:
        for w in self.in_wires.get((nid, port), []):
            src = self.nodes.get(w.src_id)
            if src and "WireGraphPseudo_Var" in src.cls:
                return w.src_id
        for w in self.in_wires.get((nid, port), []):
            src = self.nodes.get(w.src_id)
            if src and ("Var_Get" in src.cls or "Var_Set" in src.cls or "Var_Increment" in src.cls):
                for w2 in self.out_wires.get((w.src_id, "VarRef"), []):
                    dst = self.nodes.get(w2.dst_id)
                    if dst and "WireGraphPseudo_Var" in dst.cls:
                        return w2.dst_id
        return None

    # ---- dispatch ----
    def _exec_node(self, nid: int, node: Node, nq: set):
        cls = node.cls
        if "WireGraphPseudo_BufferTicks" in cls:
            self._do_buffer(nid, nq)
        elif "WireGraphPseudo_Var" in cls:
            return  # handled at start of each tick
        elif "WireGraphPseudo_ArrayVar" in cls:
            return  # arrays initialized on demand
        elif "WireGraphPseudo_MapVar" in cls:
            return  # maps initialized on demand
        elif "WireGraph_Exec_Var_Set" in cls:
            self._do_var_set(nid, nq)
        elif "WireGraph_Exec_Var_Get" in cls:
            self._do_var_get(nid, nq)
        elif "WireGraph_Exec_Var_Increment" in cls:
            self._do_increment(nid, nq)
        elif "WireGraph_Exec_Branch" in cls:
            self._do_branch(nid, nq)
        elif "WireGraph_Exec_Union" in cls:
            self._do_union(nid, nq)
        elif "Expr_ChangeDetectorExec" in cls:
            self._do_changed(nid, nq)
        elif "WireGraph_Expr_LogicalAND" in cls:
            self._do_bool(nid, nq, lambda a, b: a and b)
        elif "WireGraph_Expr_LogicalOR" in cls:
            self._do_bool(nid, nq, lambda a, b: a or b)
        elif "WireGraph_Expr_LogicalNOT" in cls:
            self._do_not(nid, nq)
        elif "Expr_CompareEqual" in cls:
            self._do_cmp(nid, nq, lambda a, b: a == b)
        elif "Expr_CompareNotEqual" in cls:
            self._do_cmp(nid, nq, lambda a, b: a != b)
        elif "Expr_CompareGreaterOrEqual" in cls:
            self._do_cmp(nid, nq, lambda a, b: a >= b)
        elif "Expr_CompareGreater" in cls:
            self._do_cmp(nid, nq, lambda a, b: a > b)
        elif "Expr_CompareLessOrEqual" in cls:
            self._do_cmp(nid, nq, lambda a, b: a <= b)
        elif "Expr_CompareLess" in cls:
            self._do_cmp(nid, nq, lambda a, b: a < b)
        elif "Expr_MathAdd" in cls:
            self._do_arith(nid, nq, lambda a, b: a + b)
        elif "Expr_MathSubtract" in cls:
            self._do_arith(nid, nq, lambda a, b: a - b)
        elif "Expr_MathMultiply" in cls:
            self._do_arith(nid, nq, lambda a, b: a * b)
        elif "Expr_MathDivide" in cls:
            self._do_arith(nid, nq, _fdiv)
        elif "Expr_MathPow" in cls:
            self._do_pow(nid, nq)
        elif "Expr_MathNegate" in cls:
            self._do_unary(nid, nq, lambda a: -a)
        elif "Expr_MathAbs" in cls:
            self._do_unary(nid, nq, abs)
        elif "Expr_Floor" in cls:
            self._do_unary(nid, nq, lambda a: float(int(a)))
        elif "Expr_MakeVector" in cls:
            self._do_makevec(nid, nq)
        elif "Expr_MakeColor" in cls:
            self._do_makecol(nid, nq)
        elif "Expr_SplitVector" in cls:
            self._do_splitvec(nid, nq)
        elif "Expr_SplitColor" in cls:
            self._do_splitcol(nid, nq)
        elif "Expr_BitwiseAND" in cls:
            self._do_bitwise(nid, nq, lambda a, b: a & b)
        elif "Expr_BitwiseOR" in cls:
            self._do_bitwise(nid, nq, lambda a, b: a | b)
        elif "Expr_BitwiseXOR" in cls:
            self._do_bitwise(nid, nq, lambda a, b: a ^ b)
        elif "Expr_BitwiseNOT" in cls:
            a = _as_int(self._in_val(nid, "Input", 0))
            self._out_val(nid, "Output", ~a)
        elif "Expr_BitwiseShiftLeft" in cls:
            self._do_bitwise(nid, nq, lambda a, b: a << b if b >= 0 else 0)
        elif "Expr_BitwiseShiftRight" in cls:
            self._do_bitwise(nid, nq, lambda a, b: a >> b if b >= 0 else 0)
        elif "Expr_MathSqrt" in cls:
            self._do_unary(nid, nq, _fsqrt)
        elif "Expr_MathSin" in cls:
            self._do_unary(nid, nq, math.sin)
        elif "Expr_MathCos" in cls:
            self._do_unary(nid, nq, math.cos)
        elif "Expr_MathTan" in cls:
            self._do_unary(nid, nq, math.tan)
        elif "Expr_MathAsin" in cls:
            self._do_unary(nid, nq, lambda a: math.asin(a) if -1.0 <= a <= 1.0 else _NAN)
        elif "Expr_MathAcos" in cls:
            self._do_unary(nid, nq, lambda a: math.acos(a) if -1.0 <= a <= 1.0 else _NAN)
        elif "Expr_MathAtan2" in cls:
            y = _as_float(self._in_val(nid, "Y", 0))
            x = _as_float(self._in_val(nid, "X", 0))
            try:
                self._out_val(nid, "Output", math.atan2(y, x))
            except (TypeError, ValueError):
                self._out_val(nid, "Output", 0.0)
        elif "Expr_MathExp" in cls:
            self._do_unary(nid, nq, lambda a: math.exp(a) if a < 700 else float("inf"))
        elif "Expr_MathCeil" in cls or "Expr_Ceil" in cls:
            self._do_unary(nid, nq, lambda a: float(math.ceil(a)))
        elif "Expr_Select" in cls:
            self._do_select(nid, nq)
        elif "Expr_String_Concatenate" in cls:
            self._do_concat(nid, nq)
        elif "Expr_String_Length" in cls:
            self._do_strlen(nid, nq)
        elif "Expr_String_Substring" in cls:
            self._do_substr(nid, nq)
        elif "Expr_String_CharacterToCodepoint" in cls:
            self._do_codepoint(nid, nq)
        elif "Expr_String_CodepointToCharacter" in cls:
            self._do_fromcodepoint(nid, nq)
        elif "Expr_String_Contains" in cls:
            self._do_contains(nid, nq)
        elif "Expr_String_StartsWith" in cls:
            self._do_startswith(nid, nq)
        elif "Expr_String_Find" in cls:
            self._do_strfind(nid, nq)
        elif "Expr_String_Replace" in cls:
            self._do_replace(nid, nq)
        elif "Expr_String_Split" in cls:
            self._do_split(nid, nq)
        elif "Expr_String_Trim" in cls:
            self._do_trim(nid, nq)
        elif "Expr_String_ParseNumber" in cls:
            self._do_parsenum(nid, nq)
        elif "Expr_String_ParseInt" in cls:
            self._do_parseint(nid, nq)
        elif "Expr_LogicalNAND" in cls:
            self._do_bool(nid, nq, lambda a, b: not (a and b))
        elif "Expr_LogicalXOR" in cls:
            self._do_bool(nid, nq, lambda a, b: bool(a) != bool(b))
        elif "WireGraph_Exec_ArrayVar_Push" in cls:
            self._do_arr_push(nid, nq)
        elif "WireGraph_Exec_ArrayVar_GetLength" in cls:
            self._do_arr_len(nid, nq)
        elif "WireGraph_Exec_ArrayVar_Get" in cls:
            self._do_arr_get(nid, nq)
        elif "WireGraph_Exec_ArrayVar_SetAtIndex" in cls:
            self._do_arr_set(nid, nq)
        elif "WireGraph_Exec_ArrayVar_Pop" in cls:
            self._do_arr_pop(nid, nq)
        elif "WireGraph_Exec_ArrayVar_Clear" in cls:
            self._do_arr_clear(nid, nq)
        elif "WireGraph_Exec_ArrayVar_CopyFrom" in cls:
            self._do_arr_copy(nid, nq)
        elif "WireGraph_Exec_ArrayVar_Append" in cls:
            self._do_arr_append(nid, nq)
        elif "WireGraph_Exec_ArrayVar_Slice" in cls:
            self._do_arr_slice(nid, nq)
        elif "WireGraph_Exec_MapVar_CopyFrom" in cls:
            self._do_map_copy(nid, nq)
        elif "WireGraph_Exec_MapVar_GetLength" in cls:
            self._do_map_len(nid, nq)
        elif "WireGraph_Exec_MapVar_GetKeys" in cls:
            self._do_map_keys(nid, nq)
        elif "WireGraph_Exec_ArrayVar_Find" in cls:
            self._do_arr_find(nid, nq)
        elif "WireGraph_Exec_ArrayVar_RemoveAtIndex" in cls:
            self._do_arr_remove(nid, nq)
        elif "WireGraph_Exec_ArrayVar_Resize" in cls:
            self._do_arr_resize(nid, nq)
        elif "WireGraph_Exec_MapVar_Get" in cls:
            self._do_map_get(nid, nq)
        elif "WireGraph_Exec_MapVar_Set" in cls:
            self._do_map_set(nid, nq)
        elif "WireGraph_Exec_MapVar_Clear" in cls:
            self._do_map_clear(nid, nq)
        elif "WireGraph_Exec_MapVar_Has" in cls:
            self._do_map_has(nid, nq)
        elif "WireGraph_Exec_MapVar_Remove" in cls:
            self._do_map_remove(nid, nq)
        elif "WireGraph_Exec_ArrayVar_Insert" in cls:
            self._do_arr_insert(nid, nq)
        elif "WireGraph_Exec_ArrayVar_Fill" in cls:
            self._do_arr_fill(nid, nq)
        elif "WireGraph_Exec_ArrayVar_Reverse" in cls:
            self._do_arr_reverse(nid, nq)
        elif "WireGraph_Exec_ArrayVar_Shuffle" in cls:
            self._do_arr_shuffle(nid, nq)
        elif "WireGraph_Exec_ArrayVar_Sort" in cls:
            self._do_arr_sort(nid, nq)
        elif "WireGraph_Exec_ArrayVar_SortMultiple" in cls:
            self._do_arr_sort_multiple(nid, nq)
        elif "WireGraph_Exec_ArrayVar_Sum" in cls:
            self._do_arr_reduce(nid, nq, "sum")
        elif "WireGraph_Exec_ArrayVar_Average" in cls:
            self._do_arr_reduce(nid, nq, "average")
        elif "WireGraph_Exec_ArrayVar_Max" in cls:
            self._do_arr_reduce(nid, nq, "max")
        elif "WireGraph_Exec_ArrayVar_Min" in cls:
            self._do_arr_reduce(nid, nq, "min")
        elif "WireGraph_Exec_ArrayVar_Swap" in cls:
            self._do_arr_swap(nid, nq)
        elif "WireGraph_Exec_MapVar_GetValues" in cls:
            self._do_map_values(nid, nq)
        elif "WireGraph_Expr_String_EndsWith" in cls:
            self._do_endswith(nid, nq)
        elif "WireGraph_Expr_String_ToLower" in cls:
            self._out_val(nid, "Output", _as_str(self._in_val(nid, "Input", "")).lower())
        elif "WireGraph_Expr_String_ToUpper" in cls:
            self._out_val(nid, "Output", _as_str(self._in_val(nid, "Input", "")).upper())
        elif "WireGraph_Expr_String_FormatText" in cls:
            self._do_formattext(nid, nq)
        elif "Expr_MathModuloFloored" in cls:
            self._do_modulo(nid, nq, True)
        elif "Expr_MathModulo" in cls:
            self._do_modulo(nid, nq, False)
        elif "Expr_MathClamp" in cls:
            v = _as_float(self._in_val(nid, "Input", 0))
            lo = _as_float(self._in_val(nid, "Min", 0))
            hi = _as_float(self._in_val(nid, "Max", 0))
            self._out_val(nid, "Output", max(lo, min(hi, v)))
        elif "Expr_MathMax" in cls:
            self._out_val(nid, "Output", max(_as_float(self._in_val(nid, "InputA", 0)),
                                             _as_float(self._in_val(nid, "InputB", 0))))
        elif "Expr_MathMin" in cls:
            self._out_val(nid, "Output", min(_as_float(self._in_val(nid, "InputA", 0)),
                                             _as_float(self._in_val(nid, "InputB", 0))))
        elif "Expr_MathLn" in cls:
            x = _as_float(self._in_val(nid, "Input", 1))
            self._out_val(nid, "Output", _fln(x))
        elif "Expr_MathLogBase" in cls:
            x = _as_float(self._in_val(nid, "Input", 1))
            b = _as_float(self._in_val(nid, "Base", 10))
            self._out_val(nid, "Output", _fdiv(_fln(x), _fln(b)))
        elif "Expr_MathSign" in cls or "Expr_MathSgn" in cls:
            x = _as_float(self._in_val(nid, "Input", 0))
            self._out_val(nid, "Output", 0.0 if x == 0 else (1.0 if x > 0 else -1.0))
        elif "Expr_MathAtan" in cls:
            self._do_unary(nid, nq, math.atan)
        elif "Expr_MathSinh" in cls:
            self._do_unary(nid, nq, math.sinh)
        elif "Expr_MathCosh" in cls:
            self._do_unary(nid, nq, math.cosh)
        elif "Expr_MathTanh" in cls:
            self._do_unary(nid, nq, math.tanh)
        elif "Expr_MathAsinh" in cls:
            self._do_unary(nid, nq, math.asinh)
        elif "Expr_MathAcosh" in cls:
            self._do_unary(nid, nq,
                           lambda v: math.acosh(v) if v >= 1.0 else _NAN)
        elif "Expr_MathAtanh" in cls:
            self._do_unary(nid, nq,
                           lambda v: math.atanh(v) if -1.0 < v < 1.0 else _NAN)
        elif "Expr_MathDegreesToRadians" in cls:
            self._do_unary(nid, nq, math.radians)
        elif "Expr_MathRadiansToDegrees" in cls:
            self._do_unary(nid, nq, math.degrees)
        elif "Expr_MathBlend" in cls:
            a = _as_float(self._in_val(nid, "InputA", 0))
            b = _as_float(self._in_val(nid, "InputB", 0))
            t = _as_float(self._in_val(nid, "Blend", 0))
            self._out_val(nid, "Output", a + (b - a) * t)
        elif "Expr_MathEasing" in cls:
            self._do_easing(nid, nq)
        elif "Expr_MathCeil" in cls:
            self._do_unary(nid, nq, lambda v: float(math.ceil(v)))
        elif "Expr_MathTrunc" in cls:
            self._do_unary(nid, nq, lambda v: float(math.trunc(v)))
        elif "Expr_MathRound" in cls:
            self._do_unary(nid, nq, lambda v: float(round(v)))
        elif "Expr_BitwiseBitCount" in cls:
            a = _as_int(self._in_val(nid, "Input", 0))
            self._out_val(nid, "Output", bin(abs(a)).count("1"))
        elif "Expr_BitwiseNAND" in cls:
            self._do_bitwise(nid, nq, lambda a, b: (~(a & b)))
        elif "Expr_BitwiseNOR" in cls:
            self._do_bitwise(nid, nq, lambda a, b: (~(a | b)))
        elif "Expr_LogicalNOR" in cls:
            self._do_bool(nid, nq, lambda a, b: not (a or b))
        elif "Expr_MakeQuaternion" in cls:
            self._out_val(nid, "Output", (
                _as_float(self._in_val(nid, "X", 0)),
                _as_float(self._in_val(nid, "Y", 0)),
                _as_float(self._in_val(nid, "Z", 0)),
                _as_float(self._in_val(nid, "W", 1))))
        elif "Expr_MakeRotation" in cls:
            self._out_val(nid, "Output", (
                _as_float(self._in_val(nid, "X", 0)),
                _as_float(self._in_val(nid, "Y", 0)),
                _as_float(self._in_val(nid, "Z", 0))))
        elif "Expr_MakeColorHex" in cls:
            v = _as_int(self._in_val(nid, "Input", 0))
            r, g, b, a = ((v >> 24) & 255, (v >> 16) & 255, (v >> 8) & 255, v & 255)
            self._out_val(nid, "Output", (r / 255.0, g / 255.0, b / 255.0, a / 255.0))
        elif "Expr_MakeColorSRGB" in cls:
            v = _as_float(self._in_val(nid, "Input", 0))
            if 0 <= v <= 1:
                r = g = b = v
            elif 1 < v <= 100:
                r, g, b = v / 100.0, 0.0, 0.0
            else:
                r = g = b = 0.0
            self._out_val(nid, "Output", (r, g, b, 1.0))
        elif "Expr_SplitQuat" in cls:
            v = self._in_val(nid, "Input", (0.0, 0.0, 0.0, 1.0))
            if isinstance(v, (tuple, list)) and len(v) >= 4:
                x, y, z, w = (_as_float(e) for e in v[:4])
            else:
                x = y = z = 0.0
                w = 1.0
            self._out_val(nid, "X", x)
            self._out_val(nid, "Y", y)
            self._out_val(nid, "Z", z)
            self._out_val(nid, "W", w)
        elif "WireGraphPseudo_QueueTicks" in cls:
            self._do_queue(nid, nq, "ticks")
        elif "WireGraphPseudo_QueueSeconds" in cls:
            self._do_queue(nid, nq, "seconds")
        elif "WireGraphPseudo_BufferSeconds" in cls:
            self._do_buffer_seconds(nid, nq)
        elif "WireGraphPseudo_Timer" in cls:
            self._do_timer(nid, nq)
        elif "WireGraphPseudo_Tween" in cls:
            self._do_tween(nid, nq)
        elif "WireGraphPseudo_Dampen" in cls:
            self._do_dampen(nid, nq)
        elif "WireGraph_DeltaTime" in cls:
            self._out_val(nid, "DeltaTime", 0.01 * self.tick_delta)
        elif "WireGraph_Exec_SweepSimple" in cls:
            self._do_sweep(nid, nq)
        elif "WireGraph_ServerUptime" in cls:
            self._do_uptime(nid, nq)
        elif "Internal_ReadBrickGrid" in cls:
            self._do_grid(nid, nq)
        elif "Internal_MicrochipInput" in cls:
            for w in self.out_wires.get((nid, "RER_Output"), []):
                nq.add((w.dst_id, w.dst_port))
            label = _extract(node.props.get('PortLabel', ('raw', '')))
            label = label if isinstance(label, str) else str(label)
            if label in self.inputs:
                self._out_val(nid, 'RER_Output', self.inputs[label])
        elif "Internal_MicrochipOutput" in cls:
            pass
        else:
            # Unknown gate: never silent — a skipped gate corrupts the run.
            if cls not in self._unimpl_warned:
                self._unimpl_warned.add(cls)
                print("irsims: unimplemented gate %s (nid %d)" % (cls, nid),
                      file=sys.stderr, flush=True)

    # ---- gate impls ----
    def _do_buffer(self, nid: int, nq: set):
        props = self.nodes[nid].props
        ticks = _as_int(props.get("TicksToWait", ("int", 1)), 1)
        zero = _as_int(props.get("ZeroTicksToWait", ("int", -1)), -1)
        delay = 0 if (zero >= 0 and self.tick >= zero) else (ticks if ticks > 0 else 1)
        target = self.tick + delay
        if target <= self.tick:
            for w in self.out_wires.get((nid, "Output"), []):
                nq.add((w.dst_id, w.dst_port))
        else:
            self._deferred.setdefault(target, []).extend(
                (w.dst_id, w.dst_port) for w in self.out_wires.get((nid, "Output"), []))

    def _do_var_set(self, nid: int, nq: set):
        val = self._find_value_input(nid)
        vid = self._var_id(nid)
        if vid is not None and val is not None:
            self.vars[vid] = val
        for w in self.out_wires.get((nid, "ExecOut"), []):
            nq.add((w.dst_id, w.dst_port))

    def _do_var_get(self, nid: int, nq: set):
        vid = self._var_id(nid)
        val = self.vars.get(vid, 0) if vid is not None else 0
        self._out_val(nid, "Value", val)
        for w in self.out_wires.get((nid, "ExecOut"), []):
            nq.add((w.dst_id, w.dst_port))

    def _do_increment(self, nid: int, nq: set):
        step = _as_float(self._in_val(nid, "Value", 1.0), 1.0)
        vid = self._var_id(nid)
        if vid is not None:
            self.vars[vid] = _as_float(self.vars.get(vid, 0)) + step
        for w in self.out_wires.get((nid, "ExecOut"), []):
            nq.add((w.dst_id, w.dst_port))

    def _do_branch(self, nid: int, nq: set):
        cond = _as_bool(self._in_val(nid, "bCond", False))
        if cond:
            for w in self.out_wires.get((nid, "ExecOutA"), []):
                nq.add((w.dst_id, w.dst_port))
        else:
            for w in self.out_wires.get((nid, "ExecOutB"), []):
                nq.add((w.dst_id, w.dst_port))

    def _do_union(self, nid: int, nq: set):
        in_exec = [w for port in ("ExecA", "ExecB", "Exec")
                    for w in self.in_wires.get((nid, port), [])]
        if not in_exec:
            return
        if any(w.src_id in self.fired_nodes or (w.src_id, w.src_port) in self.value_ready for w in in_exec):
            for w in self.out_wires.get((nid, "ExecOut"), []):
                nq.add((w.dst_id, w.dst_port))

    def _do_changed(self, nid: int, nq: set):
        key = ("chg", nid)
        input_name = self.chg_inputs.get(nid)
        if input_name and input_name in self.inputs:
            cur = self.inputs[input_name]
        else:
            cur = self._in_val(nid, "Input", None)
        if self._chg_state.get(key) is None or self._chg_state[key] != cur:
            self._chg_state[key] = cur
            for w in self.out_wires.get((nid, "OnChanged"), []):
                nq.add((w.dst_id, w.dst_port))

    def _do_bool(self, nid: int, nq: set, op):
        a = _as_bool(self._in_val(nid, "bInputA", False))
        b = _as_bool(self._in_val(nid, "bInputB", False))
        self._out_val(nid, "bOutput", op(a, b))

    def _do_not(self, nid: int, nq: set):
        a = _as_bool(self._in_val(nid, "bInput", False))
        self._out_val(nid, "bOutput", not a)

    def _do_cmp(self, nid: int, nq: set, op):
        pa = [p[0] for p in self.nodes[nid].pin]
        ia = "InputA" if "InputA" in pa else "bInputA"
        ib = "InputB" if "InputB" in pa else "bInputB"
        a = self._in_val(nid, ia, 0)
        b = self._in_val(nid, ib, 0)
        if isinstance(a, bool) or isinstance(b, bool):
            res = op(_as_bool(a), _as_bool(b))
        elif isinstance(a, (int, float)) and isinstance(b, (int, float)):
            res = op(float(a), float(b))
        else:
            try:
                res = op(a, b)
            except TypeError:
                res = op(_as_str(a), _as_str(b))
        self._out_val(nid, "bOutput", res)

    def _do_arith(self, nid: int, nq: set, op):
        a = _as_float(self._in_val(nid, "InputA", 0))
        b = _as_float(self._in_val(nid, "InputB", 0))
        try:
            self._out_val(nid, "Output", op(a, b))
        except (TypeError, ValueError, ZeroDivisionError):
            self._out_val(nid, "Output", 0.0)

    def _do_pow(self, nid: int, nq: set):
        a = _as_float(self._in_val(nid, "Input", 0))
        b = _as_float(self._in_val(nid, "Exponent", 0))
        self._out_val(nid, "Output", _fpow(a, b))

    def _do_unary(self, nid: int, nq: set, op):
        a = _as_float(self._in_val(nid, "Input", 0))
        try:
            self._out_val(nid, "Output", op(a))
        except (TypeError, ValueError):
            self._out_val(nid, "Output", 0.0)

    def _do_select(self, nid: int, nq: set):
        use_b = self._in_val(nid, "bSelectB", False)
        if use_b:
            self._out_val(nid, "Output", self._in_val(nid, "InputB", None))
        else:
            self._out_val(nid, "Output", self._in_val(nid, "InputA", None))

    def _do_makevec(self, nid: int, nq: set):
        x = _as_float(self._in_val(nid, "X", 0))
        y = _as_float(self._in_val(nid, "Y", 0))
        z = _as_float(self._in_val(nid, "Z", 0))
        self._out_val(nid, "Output", (x, y, z))

    def _do_makecol(self, nid: int, nq: set):
        r = _as_float(self._in_val(nid, "R", 0))
        g = _as_float(self._in_val(nid, "G", 0))
        b = _as_float(self._in_val(nid, "B", 0))
        a = _as_float(self._in_val(nid, "A", 1))
        self._out_val(nid, "Output", (r, g, b, a))

    def _do_splitvec(self, nid: int, nq: set):
        v = self._in_val(nid, "Input", (0.0, 0.0, 0.0))
        if isinstance(v, (tuple, list)) and len(v) >= 3:
            x, y, z = _as_float(v[0]), _as_float(v[1]), _as_float(v[2])
        else:
            x = y = z = _as_float(v, 0.0)
        self._out_val(nid, "X", x)
        self._out_val(nid, "Y", y)
        self._out_val(nid, "Z", z)

    def _do_splitcol(self, nid: int, nq: set):
        v = self._in_val(nid, "Input", (0.0, 0.0, 0.0, 0.0))
        if isinstance(v, (tuple, list)) and len(v) >= 4:
            r, g, b, a = (_as_float(v[0]), _as_float(v[1]), _as_float(v[2]), _as_float(v[3]))
        else:
            r = g = b = _as_float(v, 0.0)
            a = 1.0
        self._out_val(nid, "R", r)
        self._out_val(nid, "G", g)
        self._out_val(nid, "B", b)
        self._out_val(nid, "A", a)

    def _do_bitwise(self, nid: int, nq: set, op):
        a = _as_int(self._in_val(nid, "InputA", 0))
        b = _as_int(self._in_val(nid, "InputB", 0))
        try:
            self._out_val(nid, "Output", op(a, b))
        except (TypeError, ValueError):
            self._out_val(nid, "Output", 0)

    def _do_concat(self, nid: int, nq: set):
        a = _as_str(self._in_val(nid, "InputA", ""))
        b = _as_str(self._in_val(nid, "InputB", ""))
        self._out_val(nid, "Output", a + b)

    def _do_strlen(self, nid: int, nq: set):
        self._out_val(nid, "Output", len(_as_str(self._in_val(nid, "Input", ""))))
        for w in self.out_wires.get((nid, "ExecOut"), []):
            nq.add((w.dst_id, w.dst_port))

    def _do_substr(self, nid: int, nq: set):
        s = _as_str(self._in_val(nid, "Input", ""))
        i = _as_int(self._in_val(nid, "Start", 0))
        l = _as_int(self._in_val(nid, "Length", 0))
        self._out_val(nid, "Output", s[i:i+l] if i >= 0 else "")
        for w in self.out_wires.get((nid, "ExecOut"), []):
            nq.add((w.dst_id, w.dst_port))

    def _do_codepoint(self, nid: int, nq: set):
        s = _as_str(self._in_val(nid, "Character", ""))
        if s:
            self._out_val(nid, "Codepoint", float(ord(s[0])))
            self._out_val(nid, "bSuccess", True)
        else:
            self._out_val(nid, "Codepoint", 0.0)
            self._out_val(nid, "bSuccess", False)
        for w in self.out_wires.get((nid, "ExecOut"), []):
            nq.add((w.dst_id, w.dst_port))

    def _do_fromcodepoint(self, nid: int, nq: set):
        cp = _as_int(self._in_val(nid, "Codepoint", -1))
        if 0 <= cp <= 0x10FFFF:
            self._out_val(nid, "Character", chr(cp))
            self._out_val(nid, "bSuccess", True)
        else:
            self._out_val(nid, "Character", "")
            self._out_val(nid, "bSuccess", False)

    @staticmethod
    def _match_case(s: str, sub: str, case: bool) -> tuple[str, str]:
        if case:
            return s, sub
        return s.lower(), sub.lower()

    def _do_contains(self, nid: int, nq: set):
        s = _as_str(self._in_val(nid, "Input", ""))
        sub = _as_str(self._in_val(nid, "Search", ""))
        case = self._in_val(nid, "bCaseSensitive", None)
        case = True if case is None else _as_bool(case)
        s, sub = self._match_case(s, sub, case)
        self._out_val(nid, "Output", sub in s)

    def _do_startswith(self, nid: int, nq: set):
        s = _as_str(self._in_val(nid, "Input", ""))
        pre = _as_str(self._in_val(nid, "Prefix", ""))
        case = self._in_val(nid, "bCaseSensitive", None)
        case = True if case is None else _as_bool(case)
        s, pre = self._match_case(s, pre, case)
        self._out_val(nid, "Output", s.startswith(pre))

    def _do_strfind(self, nid: int, nq: set):
        s = _as_str(self._in_val(nid, "Input", ""))
        sub = _as_str(self._in_val(nid, "Search", ""))
        case = self._in_val(nid, "bCaseSensitive", None)
        case = True if case is None else _as_bool(case)
        start = _as_int(self._in_val(nid, "Start", 0))
        s, sub = self._match_case(s, sub, case)
        self._out_val(nid, "Output", s.find(sub, max(0, start)))

    def _do_replace(self, nid: int, nq: set):
        s = _as_str(self._in_val(nid, "Input", ""))
        sub = _as_str(self._in_val(nid, "Search", ""))
        rep = _as_str(self._in_val(nid, "Replacement", ""))
        case = self._in_val(nid, "bCaseSensitive", None)
        case = True if case is None else _as_bool(case)
        maxrep = _as_int(self._in_val(nid, "MaxReplacements", -1))
        start = _as_int(self._in_val(nid, "Start", 0))
        if not sub:
            self._out_val(nid, "Output", s)
            return
        if not case:
            i, n, head = max(0, start), 0, s[:max(0, start)]
            out = ""
            low, lsub = s.lower(), sub.lower()
            while True:
                j = low.find(lsub, i)
                if j < 0 or (maxrep > 0 and n >= maxrep):
                    out += s[i:]
                    break
                out += s[i:j] + rep
                i = j + len(sub)
                n += 1
            self._out_val(nid, "Output", head + out)
            return
        head, tail = s[:max(0, start)], s[max(0, start):]
        if maxrep > 0:
            tail = tail.replace(sub, rep, maxrep)
        else:
            tail = tail.replace(sub, rep)
        self._out_val(nid, "Output", head + tail)

    def _do_split(self, nid: int, nq: set):
        s = _as_str(self._in_val(nid, "Input", ""))
        delim = _as_str(self._in_val(nid, "Delimiter", ""))
        case = self._in_val(nid, "bCaseSensitive", None)
        case = True if case is None else _as_bool(case)
        if not delim:
            self._out_val(nid, "Left", s)
            self._out_val(nid, "Right", "")
            self._out_val(nid, "Found", False)
            self._out_val(nid, "bFound", False)
            return
        hay, ndl = (s, delim) if case else (s.lower(), delim.lower())
        j = hay.find(ndl)
        if j < 0:
            self._out_val(nid, "Left", s)
            self._out_val(nid, "Right", "")
            self._out_val(nid, "Found", False)
            self._out_val(nid, "bFound", False)
        else:
            self._out_val(nid, "Left", s[:j])
            self._out_val(nid, "Right", s[j + len(delim):])
            self._out_val(nid, "Found", True)
            self._out_val(nid, "bFound", True)

    def _do_trim(self, nid: int, nq: set):
        self._out_val(nid, "Output",
                      _as_str(self._in_val(nid, "Input", "")).strip())

    def _do_parsenum(self, nid: int, nq: set):
        # The host's law, from the compiler's own constant folder
        # (crates/wirescript/src/lower/fold/eval.rs, string_parse_number, marked
        # certified): parse through f64 after trimming, and REFUSE the
        # "inf"/"infinity"/"nan" spellings -- Rust's f64::from_str takes them, but
        # the game was never probed on them and folding them in would be a
        # divergence.  Python's float() takes both, so asking Python here would
        # have the chip parse text the gate will not.
        s = _as_str(self._in_val(nid, "Input", "")).strip()
        low = s.lower()
        if low[:1] in ("+", "-"):
            low = low[1:]
        if low in ("inf", "infinity", "nan"):
            self._out_val(nid, "Value", 0.0)
            self._out_val(nid, "bSuccess", False)
            return
        try:
            self._out_val(nid, "Value", float(s))
            self._out_val(nid, "bSuccess", True)
        except (TypeError, ValueError):
            self._out_val(nid, "Value", 0.0)
            self._out_val(nid, "bSuccess", False)

    def _do_parseint(self, nid: int, nq: set):
        # The host's ParseInt is `s.trim().parse::<i64>()`: an optional sign and
        # decimal digits, nothing else.  Python's int() also takes "1_0", so the
        # underscore is what has to be refused here -- and "0x10" is refused by
        # both, which is a real host limit (see the header's hex note).
        s = _as_str(self._in_val(nid, "Input", "")).strip()
        body = s[1:] if s[:1] in ("+", "-") else s
        if "_" in body or not body.isdigit():
            self._out_val(nid, "Value", 0)
            self._out_val(nid, "bSuccess", False)
            return
        try:
            self._out_val(nid, "Value", int(s))
            self._out_val(nid, "bSuccess", True)
        except (TypeError, ValueError):
            self._out_val(nid, "Value", 0)
            self._out_val(nid, "bSuccess", False)

    def _do_arr_push(self, nid: int, nq: set):
        aid = self._arr_id(nid)
        arr = self._arr_list(aid)
        v = self._in_val(nid, "Value", None)
        # A push gate ALWAYS appends: an unwired/None value reads as 0 on
        # hardware.  Skipping it instead would shorten this array while its
        # parallel siblings (bop/bpa/bpb/bpc) still grow, silently shifting
        # every later operand by one.
        if v is None:
            v = 0.0
        arr.append(v)
        if aid == self._loglines_id:
            s = v if isinstance(v, str) else str(v)
            # The log is the last 32 *appends*, whatever is in them.  A print
            # call appends one line the chip has already capped at 64
            # characters; io.write appends its raw text with no cap at all, and
            # neither is trimmed here.  This used to mirror the older rule --
            # cap at 64, keep 32 lines -- and silently cut every io.write longer
            # than 63 characters, which the oracle diff then reported as the
            # chip being wrong.  The chip's logV is the authority; logLines is
            # the list of appends, and this is it.
            self._log_appends.append(s)
            if len(self._log_appends) > _LOG_LINES:
                del self._log_appends[0]
            self.log = "".join(self._log_appends)
        for w in self.out_wires.get((nid, "ExecOut"), []):
            nq.add((w.dst_id, w.dst_port))

    def _do_arr_get(self, nid: int, nq: set):
        aid = self._arr_id(nid)
        idx = _as_int(self._in_val(nid, "Index", 0))
        arr = self._arr_list(aid)
        ok = 0 <= idx < len(arr)
        self._out_val(nid, "Value", arr[idx] if ok else None)
        self._out_val(nid, "bOutOfBounds", not ok)
        for w in self.out_wires.get((nid, "ExecOut"), []):
            nq.add((w.dst_id, w.dst_port))

    def _do_arr_len(self, nid: int, nq: set):
        aid = self._arr_id(nid)
        self._out_val(nid, "Length", len(self._arr_list(aid)))
        for w in self.out_wires.get((nid, "ExecOut"), []):
            nq.add((w.dst_id, w.dst_port))

    def _do_arr_set(self, nid: int, nq: set):
        aid = self._arr_id(nid)
        arr = self._arr_list(aid)
        idx = _as_int(self._in_val(nid, "Index", 0))
        v = self._in_val(nid, "Value", None)
        if idx >= 0:
            while idx >= len(arr):
                arr.append(0.0)
            if v is not None:
                arr[idx] = v
        for w in self.out_wires.get((nid, "ExecOut"), []):
            nq.add((w.dst_id, w.dst_port))

    def _do_arr_pop(self, nid: int, nq: set):
        aid = self._arr_id(nid)
        arr = self._arr_list(aid)
        if arr:
            self._out_val(nid, "Value", arr.pop())
            self._out_val(nid, "bIsEmpty", not arr)
        else:
            self._out_val(nid, "Value", None)
            self._out_val(nid, "bIsEmpty", True)
        for w in self.out_wires.get((nid, "ExecOut"), []):
            nq.add((w.dst_id, w.dst_port))

    def _do_arr_clear(self, nid: int, nq: set):
        self.arrays[self._arr_id(nid)] = []
        for w in self.out_wires.get((nid, "ExecOut"), []):
            nq.add((w.dst_id, w.dst_port))

    def _do_arr_copy(self, nid: int, nq: set):
        aid = self._arr_id(nid)
        src = self.in_wires.get((nid, "SourceRef"), [])
        src_arr = None
        for w in src:
            src_arr = self.arrays.get(w.src_id)
            if src_arr is not None:
                break
        if src_arr is None:
            v = self._in_val(nid, "SourceRef", None)
            if isinstance(v, list):
                src_arr = v
        if src_arr is not None:
            self.arrays[aid] = list(src_arr)
        for w in self.out_wires.get((nid, "ExecOut"), []):
            nq.add((w.dst_id, w.dst_port))

    def _do_arr_find(self, nid: int, nq: set):
        aid = self._arr_id(nid)
        v = self._in_val(nid, "Value", None)
        arr = self._arr_list(aid)
        try:
            idx = arr.index(v)
        except (ValueError, TypeError):
            idx = -1
        self._out_val(nid, "Index", idx)
        self._out_val(nid, "bFound", idx >= 0)
        for w in self.out_wires.get((nid, "ExecOut"), []):
            nq.add((w.dst_id, w.dst_port))

    def _do_arr_remove(self, nid: int, nq: set):
        aid = self._arr_id(nid)
        idx = _as_int(self._in_val(nid, "Index", 0))
        arr = self._arr_list(aid)
        ok = 0 <= idx < len(arr)
        if ok:
            del arr[idx]
        self._out_val(nid, "bOutOfBounds", not ok)
        for w in self.out_wires.get((nid, "ExecOut"), []):
            nq.add((w.dst_id, w.dst_port))

    def _do_arr_resize(self, nid: int, nq: set):
        aid = self._arr_id(nid)
        sz = _as_int(self._in_val(nid, "Size", 0))
        fill = self._in_val(nid, "Value", 0.0)
        arr = self._arr_list(aid)
        if sz > len(arr):
            arr.extend([fill] * (sz - len(arr)))
        else:
            del arr[sz:]
        for w in self.out_wires.get((nid, "ExecOut"), []):
            nq.add((w.dst_id, w.dst_port))

    def _do_map_get(self, nid: int, nq: set):
        mid = self._map_id(nid)
        key = self._in_val(nid, "Key", None)
        m = self.maps.get(mid, {})
        self._out_val(nid, "Value", m.get(key, None))
        self._out_val(nid, "bFound", key in m)
        for w in self.out_wires.get((nid, "ExecOut"), []):
            nq.add((w.dst_id, w.dst_port))

    def _do_map_set(self, nid: int, nq: set):
        mid = self._map_id(nid)
        key = self._in_val(nid, "Key", None)
        val = self._in_val(nid, "Value", None)
        if mid not in self.maps:
            self.maps[mid] = {}
        if val is not None:
            self.maps[mid][key] = val
        for w in self.out_wires.get((nid, "ExecOut"), []):
            nq.add((w.dst_id, w.dst_port))

    def _do_map_clear(self, nid: int, nq: set):
        self.maps[self._map_id(nid)] = {}
        for w in self.out_wires.get((nid, "ExecOut"), []):
            nq.add((w.dst_id, w.dst_port))

    def _do_map_has(self, nid: int, nq: set):
        mid = self._map_id(nid)
        key = self._in_val(nid, "Key", None)
        self._out_val(nid, "bFound", key in self.maps.get(mid, {}))
        for w in self.out_wires.get((nid, "ExecOut"), []):
            nq.add((w.dst_id, w.dst_port))

    def _do_map_remove(self, nid: int, nq: set):
        mid = self._map_id(nid)
        key = self._in_val(nid, "Key", None)
        m = self.maps.get(mid, {})
        found = key in m
        if found:
            del m[key]
        self._out_val(nid, "bFound", found)
        for w in self.out_wires.get((nid, "ExecOut"), []):
            nq.add((w.dst_id, w.dst_port))

    def _do_map_copy(self, nid: int, nq: set):
        mid = self._map_id(nid)
        src = None
        for w in self.in_wires.get((nid, "SourceRef"), []):
            src = self.maps.get(w.src_id)
            if src is not None:
                break
        if src is None:
            v = self._in_val(nid, "SourceRef", None)
            if isinstance(v, dict):
                src = v
        self.maps[mid] = dict(src) if src is not None else {}
        for w in self.out_wires.get((nid, "ExecOut"), []):
            nq.add((w.dst_id, w.dst_port))

    def _do_map_len(self, nid: int, nq: set):
        self._out_val(nid, "Length", len(self.maps.get(self._map_id(nid), {})))
        for w in self.out_wires.get((nid, "ExecOut"), []):
            nq.add((w.dst_id, w.dst_port))

    def _do_map_keys(self, nid: int, nq: set):
        mid = self._map_id(nid)
        aid = None
        for w in self.in_wires.get((nid, "ArrayVarRef"), []):
            aid = w.src_id
            break
        if aid is not None:
            self.arrays[aid] = list(self.maps.get(mid, {}).keys())
        for w in self.out_wires.get((nid, "ExecOut"), []):
            nq.add((w.dst_id, w.dst_port))

    def _do_arr_append(self, nid: int, nq: set):
        aid = self._arr_id(nid)
        arr = self._arr_list(aid)
        src_arr = None
        for w in self.in_wires.get((nid, "SourceRef"), []):
            src_arr = self.arrays.get(w.src_id)
            if src_arr is not None:
                break
        if src_arr is None:
            v = self._in_val(nid, "SourceRef", None)
            if isinstance(v, list):
                src_arr = v
        if src_arr:
            arr.extend(src_arr)
        for w in self.out_wires.get((nid, "ExecOut"), []):
            nq.add((w.dst_id, w.dst_port))

    def _do_arr_slice(self, nid: int, nq: set):
        aid = self._arr_id(nid)
        start = _as_int(self._in_val(nid, "Start", 0))
        count = _as_int(self._in_val(nid, "Count", 0))
        src_arr = None
        for w in self.in_wires.get((nid, "SourceRef"), []):
            src_arr = self.arrays.get(w.src_id)
            if src_arr is not None:
                break
        if src_arr is None:
            v = self._in_val(nid, "SourceRef", None)
            if isinstance(v, list):
                src_arr = v
        if src_arr is not None:
            arr = self._arr_list(aid)
            arr[:] = src_arr[max(0, start):max(0, start) + max(0, count)]
        for w in self.out_wires.get((nid, "ExecOut"), []):
            nq.add((w.dst_id, w.dst_port))

    def _do_map_values(self, nid: int, nq: set):
        mid = self._map_id(nid)
        aid = None
        for w in self.in_wires.get((nid, "ArrayVarRef"), []):
            aid = w.src_id
            break
        if aid is not None:
            self.arrays[aid] = list(self.maps.get(mid, {}).values())
        for w in self.out_wires.get((nid, "ExecOut"), []):
            nq.add((w.dst_id, w.dst_port))

    def _do_arr_insert(self, nid: int, nq: set):
        aid = self._arr_id(nid)
        arr = self._arr_list(aid)
        idx = _as_int(self._in_val(nid, "Index", 0))
        v = self._in_val(nid, "Value", None)
        if v is None:
            v = 0.0
        ok = 0 <= idx <= len(arr)
        if ok:
            arr.insert(idx, v)
        self._out_val(nid, "bOutOfBounds", not ok)
        for w in self.out_wires.get((nid, "ExecOut"), []):
            nq.add((w.dst_id, w.dst_port))

    def _do_arr_fill(self, nid: int, nq: set):
        arr = self._arr_list(self._arr_id(nid))
        v = self._in_val(nid, "Value", None)
        if v is None:
            v = 0.0
        for i in range(len(arr)):
            arr[i] = v
        for w in self.out_wires.get((nid, "ExecOut"), []):
            nq.add((w.dst_id, w.dst_port))

    def _do_arr_reverse(self, nid: int, nq: set):
        self._arr_list(self._arr_id(nid)).reverse()
        for w in self.out_wires.get((nid, "ExecOut"), []):
            nq.add((w.dst_id, w.dst_port))

    def _do_arr_shuffle(self, nid: int, nq: set):
        random.shuffle(self._arr_list(self._arr_id(nid)))
        for w in self.out_wires.get((nid, "ExecOut"), []):
            nq.add((w.dst_id, w.dst_port))

    @staticmethod
    def _sort_key(v: Any):
        # Deterministic, type-tolerant ordering: numbers before strings.
        if isinstance(v, bool):
            return (0, float(v), "")
        if isinstance(v, (int, float)):
            return (0, float(v), "")
        if isinstance(v, str):
            return (1, 0.0, v)
        return (2, 0.0, repr(v))

    def _do_arr_sort(self, nid: int, nq: set):
        arr = self._arr_list(self._arr_id(nid))
        arr.sort(key=self._sort_key, reverse=_as_bool(self._in_val(nid, "bDescending", False)))
        for w in self.out_wires.get((nid, "ExecOut"), []):
            nq.add((w.dst_id, w.dst_port))

    def _do_arr_sort_multiple(self, nid: int, nq: set):
        # this array is the key; up to 7 parallel arrays follow on ArrayVarRef1..7
        akey = self._arr_id(nid)
        others = []
        for w in self.in_wires.get((nid, "ArrayVarRef"), [])[1:]:
            others.append(w.src_id)
        for name in ("ArrayVarRef1", "ArrayVarRef2", "ArrayVarRef3", "ArrayVarRef4",
                     "ArrayVarRef5", "ArrayVarRef6", "ArrayVarRef7"):
            for w in self.in_wires.get((nid, name), []):
                if w.src_id not in others and w.src_id != akey:
                    others.append(w.src_id)
        keys = self._arr_list(akey)
        pairs = list(enumerate(range(len(keys))))
        pairs.sort(key=lambda p: (self._sort_key(keys[p[0]]), p[0]),
                   reverse=_as_bool(self._in_val(nid, "bDescending", False)))
        order = [p[0] for p in pairs]
        for aid in others:
            src = self._arr_list(aid)
            self.arrays[aid] = [src[i] for i in order if 0 <= i < len(src)]
        self.arrays[akey] = [keys[i] for i in order]
        for w in self.out_wires.get((nid, "ExecOut"), []):
            nq.add((w.dst_id, w.dst_port))

    def _do_arr_reduce(self, nid: int, nq: set, how: str):
        arr = self._arr_list(self._arr_id(nid))
        if not arr:
            self._out_val(nid, "bIsEmpty", True)
        else:
            nums = [_as_float(v) for v in arr]
            if how == "sum":
                self._out_val(nid, "Value", sum(nums))
            elif how == "average":
                self._out_val(nid, "Value", sum(nums) / len(nums))
            elif how == "max":
                self._out_val(nid, "Value", max(arr, key=self._sort_key))
            else:
                self._out_val(nid, "Value", min(arr, key=self._sort_key))
        for w in self.out_wires.get((nid, "ExecOut"), []):
            nq.add((w.dst_id, w.dst_port))

    def _do_arr_swap(self, nid: int, nq: set):
        arr = self._arr_list(self._arr_id(nid))
        a = _as_int(self._in_val(nid, "IndexA", 0))
        b = _as_int(self._in_val(nid, "IndexB", 0))
        ok = 0 <= a < len(arr) and 0 <= b < len(arr)
        if ok:
            arr[a], arr[b] = arr[b], arr[a]
        self._out_val(nid, "bOutOfBounds", not ok)
        for w in self.out_wires.get((nid, "ExecOut"), []):
            nq.add((w.dst_id, w.dst_port))

    def _do_modulo(self, nid: int, nq: set, floored: bool):
        a = _as_float(self._in_val(nid, "InputA", 0))
        b = _as_float(self._in_val(nid, "InputB", 0))
        self._out_val(nid, "Output", _fmod(a, b, floored))

    def _do_endswith(self, nid: int, nq: set):
        s = _as_str(self._in_val(nid, "Input", ""))
        suf = _as_str(self._in_val(nid, "Suffix", ""))
        cs = self._in_val(nid, "bCaseSensitive", None)
        cs = True if cs is None else _as_bool(cs)
        if not cs:
            s, suf = s.lower(), suf.lower()
        self._out_val(nid, "Output", s.endswith(suf))

    def _do_formattext(self, nid: int, nq: set):
        # FormatText is variadic: every wired Input* becomes a positional {} arg
        # after the format string, in port order A,B,C,D,E,F,G.
        fmt = _as_str(self._in_val(nid, "FormatString", ""))
        if not fmt:
            vals = []
            for name in ("InputA", "InputB", "InputC", "InputD",
                         "InputE", "InputF", "InputG"):
                if self.in_wires.get((nid, name)):
                    vals.append(_as_str(self._in_val(nid, name, "")))
            self._out_val(nid, "Output", "".join(vals))
            return
        args = []
        for name in ("InputA", "InputB", "InputC", "InputD",
                     "InputE", "InputF", "InputG"):
            if self.in_wires.get((nid, name)):
                args.append(_as_str(self._in_val(nid, name, "")))
        try:
            self._out_val(nid, "Output", fmt.format(*args))
        except (IndexError, KeyError, ValueError):
            self._out_val(nid, "Output", fmt)

    _EASINGS = {
        0: lambda t: t, 1: lambda t: t * t, 2: lambda t: t * t * t,
        3: lambda t: 1 - (1 - t) ** 3, 4: lambda t: t ** 4,
        5: lambda t: 1 - (1 - t) ** 4, 6: lambda t: t * (2 - t),
        7: lambda t: (2 * t) ** 3 / 2, 8: lambda t: 1 - (2 - 2 * t) ** 3 / 2,
    }

    def _do_easing(self, nid: int, nq: set):
        a = _as_float(self._in_val(nid, "InputA", 0))
        b = _as_float(self._in_val(nid, "InputB", 0))
        t = _as_float(self._in_val(nid, "Blend", 0))
        fn = _as_int(self._in_val(nid, "Function", 0))
        t = max(0.0, min(1.0, t))
        f = self._EASINGS.get(fn, self._EASINGS[0])
        self._out_val(nid, "Output", a + (b - a) * f(t))

    def _do_queue(self, nid: int, nq: set, unit: str):
        props = self.nodes[nid].props
        if unit == "ticks":
            wait = _as_int(props.get("TicksToWait", ("int", 1)), 1)
            zero = _as_int(props.get("ZeroTicksToWait", ("int", -1)), -1)
        else:
            wait = _as_int(props.get("SecondsToWait", ("int", 1)), 1)
            zero = _as_int(props.get("ZeroSecondsToWait", ("int", -1)), -1)
        delay = 0 if (zero >= 0 and self.tick >= zero) else max(1, wait)
        target = self.tick + delay
        carried = {name: self._in_val(nid, "DataIn%d" % i, None)
                   for i in range(1, 9)
                   if self.in_wires.get((nid, "DataIn%d" % i))}
        if target <= self.tick:
            for name, val in carried.items():
                self._out_val(nid, name.replace("DataIn", "DataOut"), val)
            for w in self.out_wires.get((nid, "ExecOut"), []):
                nq.add((w.dst_id, w.dst_port))
        else:
            self._deferred.setdefault(target, []).append((nid, "Output"))
            self._queue_carry[nid] = carried

    def _do_buffer_seconds(self, nid: int, nq: set):
        props = self.nodes[nid].props
        secs = _as_float(props.get("SecondsToWait", ("float", 0.01)), 0.01)
        zero = _as_int(props.get("ZeroSecondsToWait", ("int", -1)), -1)
        wait = max(1, int(round(secs / 0.01)))
        delay = 0 if (zero >= 0 and self.tick >= zero) else wait
        target = self.tick + delay
        if target <= self.tick:
            for w in self.out_wires.get((nid, "Output"), []):
                nq.add((w.dst_id, w.dst_port))
        else:
            self._deferred.setdefault(target, []).extend(
                (w.dst_id, w.dst_port) for w in self.out_wires.get((nid, "Output"), []))

    def _do_timer(self, nid: int, nq: set):
        limit = _as_float(self._in_val(nid, "Limit", 0))
        start = self._timer_state.setdefault(nid, [self.tick, False])
        if _as_bool(self._in_val(nid, "Restart", False)):
            start[0] = self.tick
            start[1] = False
        paused = start[2] if len(start) > 2 else False
        if _as_bool(self._in_val(nid, "Pause", False)):
            paused = True
        if _as_bool(self._in_val(nid, "Resume", False)):
            paused = False
        start[2] = paused
        elapsed = 0.0 if paused else (self.tick - start[0]) * 0.01
        expired = (not paused) and (limit > 0) and elapsed >= limit
        if expired and not start[1]:
            start[1] = True
        self._out_val(nid, "Time", elapsed)
        self._out_val(nid, "Expired", expired)

    def _do_tween(self, nid: int, nq: set):
        target = _as_float(self._in_val(nid, "Target", 0))
        dur = _as_float(self._in_val(nid, "Duration", 1))
        st = self._timer_state.setdefault(nid, [0.0, self.tick])
        st[0] = target
        if st[0] != target or self.in_wires.get((nid, "Target")):
            if st[1] != self.tick:
                st[1] = self.tick
                st.append(0.0)
        elapsed = (self.tick - st[1]) * 0.01
        t = 1.0 if dur <= 0 else min(1.0, elapsed / dur)
        start_v = st[2] if len(st) > 2 else 0.0
        self._out_val(nid, "Value", start_v + (st[0] - start_v) * t)
        self._out_val(nid, "Arrived", t >= 1.0)

    def _do_dampen(self, nid: int, nq: set):
        target = _as_float(self._in_val(nid, "Target", 0))
        smooth = _as_float(self._in_val(nid, "SmoothTime", 0))
        st = self._timer_state.get(nid)
        if st is None:
            self._timer_state[nid] = [target]
            self._out_val(nid, "Value", target)
            return
        cur = st[0]
        if smooth <= 0:
            self._timer_state[nid][0] = target
            self._out_val(nid, "Value", target)
            return
        alpha = min(1.0, 0.01 / smooth)
        st[0] = cur + (target - cur) * alpha
        self._out_val(nid, "Value", st[0])

    def _do_sweep(self, nid: int, nq: set):
        # SweepSimple: over the tick's inputs, emit one ExecOut per hit.  The
        # sim has no entity set, so a sweep yields no hits (exec chain passes
        # nothing through) unless inputs name explicit points.
        for w in self.out_wires.get((nid, "ExecOut"), []):
            nq.add((w.dst_id, w.dst_port))

    def _do_uptime(self, nid: int, nq: set):
        self._out_val(nid, "Uptime", float(self.tick) * 0.01)
        for w in self.out_wires.get((nid, "Uptime"), []):
            nq.add((w.dst_id, w.dst_port))

    def _do_grid(self, nid: int, nq: set):
        self._out_val(nid, "Value", 0.0)
        for w in self.out_wires.get((nid, "Output"), []):
            nq.add((w.dst_id, w.dst_port))

    def _do_literal(self, nid: int):
        node = self.nodes[nid]
        if "WireGraphPseudo_ArrayVar" in node.cls:
            if nid not in self.arrays:
                v = node.props.get("InitialValue", None)
                v = _extract(v)
                if isinstance(v, list):
                    self.arrays[nid] = [_extract(e) for e in v]
                else:
                    self.arrays[nid] = []
            return
        if "WireGraphPseudo_MapVar" in node.cls:
            if nid not in self.maps:
                v = node.props.get("InitialValue", None)
                if isinstance(v, tuple) and v and v[0] == "maplit":
                    self.maps[nid] = {lit_value(k): lit_value(val)
                                      for k, val in v[1]}
                else:
                    self.maps[nid] = {}
            return
        v = node.props.get("InitialValue", node.props.get("Value", ("raw", "0")))
        if isinstance(v, tuple):
            v = _extract(v)
        out_port = "Value" if "Value" in [p[0] for p in node.pout] else "Output"
        self._out_val(nid, out_port, v)
        if nid not in self.vars:
            self.vars[nid] = v

    def _find_value_input(self, nid: int) -> Any:
        _SENTINEL = object()
        saw_wires = False
        for p in [x[0] for x in self.nodes[nid].pin]:
            if "Value" in p and "VarRef" not in p:
                if self.in_wires.get((nid, p)):
                    saw_wires = True
                val = self._in_val(nid, p, _SENTINEL)
                if val is not _SENTINEL:
                    return val
        if saw_wires:
            return None
        props = self.nodes[nid].props.get("Value", ("raw", "false"))
        return _extract(props) if isinstance(props, tuple) else props

    def _arr_id(self, nid: int) -> int:
        for w in self.in_wires.get((nid, "ArrayVarRef"), []):
            return w.src_id
        return nid

    def _arr_list(self, aid: int) -> list:
        arr = self.arrays.get(aid)
        if arr is None:
            nd = self.nodes.get(aid)
            if nd is not None and "Internal_MicrochipInput" in nd.cls:
                label = _extract(nd.props.get("PortLabel", ("raw", "")))
                v = self.inputs.get(label if isinstance(label, str) else str(label))
                if isinstance(v, (list, tuple)):
                    arr = list(v)
                    self.arrays[aid] = arr
                    return arr
            arr = []
            self.arrays[aid] = arr
        return arr

    def _map_id(self, nid: int) -> int:
        for w in self.in_wires.get((nid, "MapVarRef"), []):
            return w.src_id
        for w in self.in_wires.get((nid, "VarRef"), []):
            src = self.nodes.get(w.src_id)
            if src and "MapVar" in src.cls:
                return w.src_id
        return nid


def run_ws(ws_path: str, max_ticks: int = MAX_TICKS,
           inputs: dict | None = None) -> dict:
    nodes, wires, _ = dump_source(ws_path)
    sim = Sim(nodes, [Wire(*w) for w in wires])
    if inputs:
        sim.inputs = dict(inputs)
    return sim.run(max_ticks)


class ChipRunner:
    """Compiles the chip once, then runs any number of programs on it.

    Compiling the WireScript and indexing 124k wires costs about six seconds.
    The test scripts used to pay that again for every single program; here one
    build serves a whole batch, because reset() returns the sim to its initial
    state without touching the wiring or the source cache.
    """

    def __init__(self, ws_path: str = None, sim: "Sim" = None):
        # A runner is a sim plus nothing, so a worker that already has the sim
        # (loaded from a share_dump pickle, say) can make one without compiling.
        if sim is None:
            nodes, wires, _ = dump_source(ws_path)
            sim = Sim(nodes, [Wire(*w) for w in wires])
        self.sim = sim

    def reset(self):
        self.sim.reset()

    def run(self, src: str, max_ticks: int = MAX_TICKS,
            inputs: dict | None = None) -> dict:
        self.sim.reset()
        self.sim.inputs = {"program": src, "run": True}
        if inputs:
            self.sim.inputs.update(inputs)
        return self.sim.run(max_ticks)


class Wire:
    def __init__(self, src_id, src_port, dst_id, dst_port):
        self.src_id = src_id
        self.src_port = src_port
        self.dst_id = dst_id
        self.dst_port = dst_port
    def __iter__(self):
        return iter((self.src_id, self.src_port, self.dst_id, self.dst_port))


def share_dump(ws_path: str, path: str) -> str:
    """Compile and index the chip once, into a pickle every worker can share.

    The suite and check.py both used to do this inline; the point of the file is
    that it is the one place, because a worker that rebuilds the chip pays ten
    seconds before it runs a program that takes a second.
    """
    import pickle
    nodes, wires, _ = dump_source(ws_path)
    with open(path, "wb") as f:
        pickle.dump((nodes, wires), f)
    return path


def sim_from_dump(path: str) -> "Sim":
    """A Sim over the graph in a share_dump pickle, with nothing compiled."""
    import pickle
    with open(path, "rb") as f:
        nodes, wires = pickle.load(f)
    return Sim(nodes, [Wire(*w) for w in wires])
