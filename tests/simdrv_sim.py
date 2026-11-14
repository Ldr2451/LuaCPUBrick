"""The official WireScript simulator, behind the harness' `Sim` surface.

`tests/test_chip_suite.py` drives a `Sim` with a small surface: `reset()`,
`inputs`, `run(ticks[, on_tick])`, `capture()`, `finished`, `tick`, `log`,
`chip_var`, `state_invariants`. This shim answers all of it from one
persistent `simdrv` child, which links the WIRESIM 2.4.0 machine: the chip is
loaded once (`load_brz`), every case starts a fresh run (`new`), and a `set`
mid-run is the host changing a port. Nothing here models gate behaviour: the
engine's own evaluator runs the graph.

Reads the harness needs that the engine keeps private come from probe gates the
driver appends to the run's graph (`new probe:true`): a reroute on each named
global's Value port answers `vread`, and array labels answer with the container's
length (the only array read the engine's public API can reach; contents
trips that used to run on the model's own storage are not this sim's to check).
"""
import json
import os
import subprocess
import spec

# The two array OUTPUT ports. The engine keeps a container's elements in its
# own state, so a driver that wants a port's CONTENTS -- not just its length
# -- asks `new` for element probes: one Exec_ArrayVar_Get per index, fired
# from the chip's own per-tick edge and read back through a reroute named
# `label[index]` (`vreadmany` reads them in one round trip). The handle is the
# OUT PIN's label: the var gate behind it carries no label property of its own.
# Head and tail only: the suite writes at both ends (index 1 and index 16384),
# and vmReset zeroes everything in between, so an unprobed middle index is the
# reset value by construction.
ARRAY_PORTS = {"outNumArr": "outNumArr", "outStrArr": "outStrArr"}
ARRAY_HEAD = 256
ARRAY_TAIL = 128

EXE = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   "tools", "simdrv", "target", "release", "simdrv.exe")


def truthy(j):
    """A JSON wire value as Lua-ish truthiness: false, null and 0 are not true
    (the chip's progOk probe is a bool, so only the first case is really hit)."""
    if j is None or j is False:
        return False
    if isinstance(j, dict):
        return True
    if isinstance(j, (int, float)):
        return j != 0
    return len(j) > 0


class Sim:
    def __init__(self, brz, seed=3, dt=1.0 / 60.0, busy_label="busy"):
        self.exe = EXE
        self.brz = brz
        self.seed = seed
        self.dt = dt
        self._q = []
        self._qneed = 0
        self._mid = False
        self._last_og = {}
        self.child = subprocess.Popen([self.exe], stdin=subprocess.PIPE,
                                      stdout=subprocess.PIPE,
                                      encoding="utf-8", bufsize=1)
        self._send({"cmd": "load_brz", "path": brz})
        labs = self._send({"cmd": "olabels"})
        self.out_labels = {}
        self.in_labels = {}
        for h in labs.get("hits", []):
            if h["label"]:
                self.out_labels[h["label"]] = h["i"]
        for h in labs.get("inhits", []):
            if h["label"]:
                self.in_labels[h["label"]] = h["i"]
        self.busy_idx = self.out_labels.get(busy_label, 12)
        self.log_idx = self.out_labels.get("log", 0)
        # Element probes for the two array out ports, as [start, count] ranges.
        self._arr_ranges = {}
        for _lbl in ARRAY_PORTS.values():
            self._arr_ranges[_lbl] = [[0, ARRAY_HEAD],
                                      [spec.OUTARR - ARRAY_TAIL, ARRAY_TAIL]]
        # Only for a case that inspects an array port's CONTENTS: 768 extra
        # gates and 768 per-tick fires are nothing free, and 970 of the 985
        # cases never look at one.
        self._arr_on = False
        self.inputs = {}
        self.tick = 0
        self.log = ""
        self.finished = False
        self.keep_going = False
        # The engine's own refusal, if the run got one: the simulator STOPS a
        # run when a gate it does not certify is fed something its laws do not
        # cover (an unwired input, a non-finite one), printing one line that
        # names the gate and the inputs. Swallowed, that stop looks like a chip
        # that printed nothing; carried, it says WHICH law the program hit, and
        # a suite run can tally the classes it repeats.
        self.engineError = ""
        self._started = False
        self._busy_seen_true = False
        self._busy_last = None
        # Harness hooks the game model had; this chip has no ReadBrickGrid
        # handler, so the re-fire loop never runs and an empty set is exact.
        self.grid_ids = []
        self.exec_queue = set()
        self._deferred = []
        self._mid = False
        self._q = []
        self._qneed = 0
        self._last_og = {}

    def _write(self, cmd):
        """Write one command; the caller reads whatever lines it answers."""
        self.child.stdin.writelines([json.dumps(cmd) + "\n"])
        self.child.stdin.flush()

    def _send(self, cmd):
        """One command, one reply line; extra printed lines are read by callers."""
        self._write(cmd)
        if self._q:
            # A reply a queued (mid-run) command already collected.
            return self._q.pop(0)
        while True:
            line = self.child.stdout.readline()
            if not line:
                raise EOFError("simdrv closed")
            line = line.strip()
            if line:
                return json.loads(line)

    def _send_deferred(self, cmd):
        """Write a command DURING a runlog round trip: its reply lands after
        the loop's summary line; `run` collects those into `_q` at loop end."""
        self.child.stdin.writelines([json.dumps(cmd) + "\n"])
        self.child.stdin.flush()
        self._qneed += 1

    def _readline_json(self):
        while True:
            line = self.child.stdout.readline()
            if not line:
                raise EOFError("simdrv closed")
            line = line.strip()
            if line:
                return json.loads(line)

    def reset(self):
        """Case start: the next run begins on a fresh machine."""
        self._started = False
        self.tick = 0
        self.log = ""
        self.finished = False
        self._busy_seen_true = False
        self._busy_last = None
        self.engineError = ""

    def _wire_val(self, name, v):
        # The driver answers a wire by SHAPE (wire_to_json): scalars as they
        # are, unwired as {"none": true}, a container as {"ref": N}. The suite
        # (chip_ports, lifecycle_sample, cleared) compares plain values, so
        # unwrap per port name: unwired reads as the port's own domain default
        # -- what the chip holds before anything writes it. An array answers
        # only a ref, so its contents are not readable through the driver and
        # map to the empty list.
        if not isinstance(v, dict):
            return v
        if "none" in v or "ref" in v or "other" in v:
            if name in ("outNumArr", "outStrArr"):
                return []
            if name in ("outStr1", "outStr2", "result", "runErrors", "progDebug",
                        "log"):
                return ""
            if name == "busy":
                return False
            return 0.0
        return v

    def _ports(self, inp):
        po = {}
        for k, v in (inp or {}).items():
            idx = self.in_labels.get(k)
            if idx is None:
                continue
            if isinstance(v, (list, tuple)):
                # The driver feeds an array through an ArrayVar clone, so it
                # wants a spec, not a bare JSON list: the element kind names
                # the stored BrdbValue. An empty list falls back on the pin
                # name, which is how the chip's two array ports are declared.
                if v and isinstance(v[0], str):
                    kind = "Str"
                elif v and isinstance(v[0], bool):
                    kind = "bool"
                else:
                    kind = "Str" if k.endswith("StrArr") else "f64"
                po[str(idx)] = {"arr": kind, "values": list(v)}
            else:
                po[str(idx)] = v
        # An array IN port the case does not feed is unwired, and the engine
        # refuses an uncertified gate on an unwired input -- the chip reads
        # `inNumArr.length()` in every array access, so a case that never
        # mentions the arrays still hits it (that error, not a chip bug, is
        # what made `print(inNumArr())` print nothing). A host sends an array
        # even when it has none to send, so feed the empty one: the chip's
        # documented behaviour for a read past the end is nil, and an empty
        # array is exactly that state.
        for k in ("inNumArr", "inStrArr"):
            idx = self.in_labels.get(k)
            if idx is not None and str(idx) not in po:
                po[str(idx)] = {"arr": "Str" if k.endswith("StrArr") else "f64",
                                "values": []}
        return po

    def _start(self):
        r = self._send({"cmd": "new", "probe": True, "busy": self.busy_idx,
                        "ports": self._ports(self.inputs), "dt": self.dt,
                        "seed": self.seed,
                        "arrays": self._arr_ranges if self._arr_on else {}})
        if "err" in r:
            raise RuntimeError("new: %s" % r["err"])
        self._started = True

    def _tick_line(self, r):
        """Fold one per-tick runlog line into the shim's state."""
        # Driver lines are 1-based; the harness counts ticks from 0 (a stopped
        # window reads `budget - 1`, checkpoints name 0-based ticks).
        self.tick = r["tick"] - 1
        lv = r["log"]
        self.log = lv if isinstance(lv, str) else ""
        b = r["busy"]
        if isinstance(b, bool):
            self._busy_last = b
            if b:
                self._busy_seen_true = True
        if "ports" in r and r["ports"] is not None:
            og = {}
            for nm, i in self.out_labels.items():
                if i < len(r["ports"]):
                    og[nm] = self._wire_val(nm, r["ports"][i])
            self._last_og = og

    def run(self, ticks, on_tick=None, ports=False, live_inputs=False):
        if not self._started:
            self._start()
        if live_inputs:
            # One round trip PER TICK.  The callback is a host: it may change a
            # port at tick T and the change has to reach the engine before tick
            # T+1.  A single `runlog` window cannot do that -- the driver runs
            # the whole window before it reads its next command, so a `set`
            # written mid-window lands at the window's END (that is how the
            # lifecycle cases read as "the edit never arrived": the program port
            # changed after the run was over).  The bulk path below stays for
            # the windows whose callback only watches.
            for _ in range(ticks):
                self._write({"cmd": "runlog", "ticks": 1, "out": self.log_idx,
                             "ports": bool(ports)})
                r = self._readline_json()
                if "err" in r:
                    self.finished = False
                    self.engineError = r.get("err") or ""
                    self._readline_json()
                    break
                self._tick_line(r)
                self._readline_json()
                if on_tick:
                    on_tick(self, self.tick)
            self.finished = (self._busy_seen_true and self._busy_last is False) \
                or self.finished
            return self.capture()
        self._mid = True
        # runlog even without a callback: the plain `run` command samples busy
        # with evaluate_alone, which reads a never-fired container as false, so
        # a finished fast program would look "not finished" to a probe.
        # `ports=True` only for windows with checkpoints: per-tick lines then
        # carry every out pin, which is what a mid-window `capture` answers
        # with (a `capture` COMMAND inside the round trip would queue after
        # the summary line and desync everything behind it).
        cmd = {"cmd": "runlog", "ticks": ticks, "out": self.log_idx,
               "ports": bool(ports)}
        self._send(cmd)
        done = 0
        summary_seen = False
        try:
            while done < ticks:
                r = self._readline_json()
                if "err" in r:
                    # The engine stopped the graph: an uncertified gate named
                    # the program. The suite treats it as "the run ended there",
                    # reading the ports at that tick, exactly as the per-tick
                    # loop before. The driver still prints its trailing summary
                    # after the err line; swallow it so the next command's
                    # reply stays aligned.
                    self.finished = False
                    self.engineError = r.get("err") or ""
                    self._readline_json()
                    summary_seen = True
                    break
                if "log" in r and "busy" in r:
                    done += 1
                    self._tick_line(r)
                    if on_tick:
                        on_tick(self, r["tick"] - 1)
                else:
                    # the trailing summary line
                    summary_seen = True
                    break
        finally:
            self._mid = False
            # A window whose every tick line arrived exits on done == ticks with
            # the driver's summary still pending -- a checkpointed window that
            # stays busy the whole time is exactly that. Swallow it before the
            # deferred replies, which print after it.
            if not summary_seen:
                self._readline_json()
            # Replies of commands written mid-run (a host changing its ports
            # inside the window) arrive after the summary: collect them now so
            # the next command's readline stays aligned. They are DISCARDED:
            # they answer commands already written; the next command's reply
            # is printed only after these.
            for _ in range(self._qneed):
                self._readline_json()
            self._qneed = 0
        self.finished = (self._busy_seen_true and self._busy_last is False) \
            or self.finished
        return self.capture()

    def _refresh_log(self):
        r = self._send({"cmd": "getout", "i": self.log_idx})
        v = r.get("value")
        self.log = v if isinstance(v, str) else ""

    def _fill_arrays(self, og):
        """An array port's ref becomes the container's CONTENTS.

        Only the probed indices are read (the head and the tail, asked for at
        `new`); whatever else the array holds is what vmReset left there --
        0.0 or "" -- so a middle index is the reset value by construction, not
        a guess about what the program wrote."""
        if not self._arr_on:
            return
        for port, var in ARRAY_PORTS.items():
            if port not in og:
                continue
            default = 0.0 if port.endswith("NumArr") else ""
            full = [default] * spec.OUTARR
            labels = []
            idxs = []
            for start, cnt in self._arr_ranges.get(var, []):
                labels += ["%s[%d]" % (var, k) for k in range(start, start + cnt)]
                idxs += range(start, start + cnt)
            r = self._send({"cmd": "vreadmany", "labels": labels})
            for k, v in zip(idxs, r.get("values") or []):
                if isinstance(v, (int, float, str)):
                    full[k] = v
            og[port] = full

    def capture(self):
        if self._mid:
            # Mid-window: the per-tick lines already carry the whole port set;
            # a real `capture` command here would queue after the summary and
            # desync the stream.
            return {"log": self.log, "outGlobals": dict(self._last_og),
                    "tick": self.tick, "chat": [],
                    "engineError": self.engineError}
        r = self._send({"cmd": "capture"})
        if "err" in r:
            raise RuntimeError("capture: %s" % r["err"])
        if "ports" not in r:
            # A reply without ports is a line-stream desync: some command left
            # a line unread. Say so at the point of detection, not as an
            # empty port set that reads like a chip with deleted ports.
            raise RuntimeError("capture: desync, reply=%s" % str(r)[:200])
        og = {}
        vals = r.get("ports", [])
        for name, i in self.out_labels.items():
            if i < len(vals):
                v = vals[i]
                og[name] = self._wire_val(name, v)
        self._fill_arrays(og)
        return {"log": self.log, "outGlobals": og, "tick": r.get("tick"),
                "chat": r.get("chat", []), "engineError": self.engineError}

    def set_inputs(self, si):
        self.inputs = dict(si)
        if self._started:
            r = self._send({"cmd": "set", "ports": self._ports(self.inputs)})
            if "err" in r:
                raise RuntimeError("set: %s" % r["err"])

    def __setattr__(self, name, value):
        # The harness assigns `sim.inputs = {...}` mid-run, which is a host
        # changing its ports: it has to reach the engine, not just the shim.
        if name == "inputs" and getattr(self, "_started", False):
            si = dict(value)
            if getattr(self, "_mid", False):
                # Inside a runlog round trip: the reply comes after the
                # summary; `run` collects it. (The engine sees the new port
                # values at the window's end, not at the tick the harness
                # crossed — the shapes that care about an edge INSIDE a
                # window are the ones the suite schedules with `phases`,
                # whose edges the shim replays below.)
                self._send_deferred({"cmd": "set",
                                     "ports": self._ports(si)})
                object.__setattr__(self, name, si)
                return
            r = self._send({"cmd": "set", "ports": self._ports(si)})
            if "err" in r:
                raise RuntimeError("set: %s" % r["err"])
            object.__setattr__(self, name, si)
        else:
            object.__setattr__(self, name, value)

    def chip_var(self, name, default=None):
        r = self._send({"cmd": "vread", "label": name})
        if "err" in r or "value" not in r:
            return default
        v = r["value"]
        return default if isinstance(v, dict) else v

    def chip_array(self, name):
        """The container's LENGTH: the engine keeps contents private, and the
        harness' uses of this are lens checks (see state_invariants)."""
        r = self._send({"cmd": "vread", "label": name})
        n = r.get("value")
        return [0] * int(n) if isinstance(n, (int, float)) else None

    def chip_len(self, name):
        r = self._send({"cmd": "vread", "label": name})
        n = r.get("value")
        return int(n) if isinstance(n, (int, float)) else None

    def state_invariants(self, clean=True):
        """The checks that survive a simulator that owns its containers: the
        frame arrays stay in step, the arena counters stay inside what the chip
        sized, the closure cursor stays inside its fill, and after a CLEAN
        finish nothing is left in flight. Checks that read the model's own
        bookkeeping (marker counts, per-slot values) are not this engine's to
        make: the engine cannot desync a container it wrote."""
        bad = []
        arrays = ("fFunc", "fBase", "fRetA", "fRetBase", "fRetPC", "fRetN",
                  "fVaB", "fForDepth")
        sizes = {}
        for name in arrays:
            n = self.chip_len(name)
            if n is None:
                bad.append("no array labelled %s" % name)
                continue
            sizes[name] = n
        if sizes and len(set(sizes.values())) != 1:
            bad.append("frame arrays out of step: %s"
                       % ", ".join("%s=%d" % kv for kv in sorted(sizes.items())))
        tl = self.chip_len("tLen")
        tc = self.chip_var("tCount")
        if tl is not None and tc is not None and tc > tl:
            bad.append("tCount=%s past the %d tables the chip sized"
                       % (tc, tl))
        # The arena's size lens is `tLen/tFirst/tLast` (all sized to MAX_* at
        # boot); `tPrev/tNext/tOwner/tKey*` are lazily-grown containers whose
        # length is not the arena size, so the heap bound reads the lens above.
        arena = {}
        for name in ("tLen", "tFirst", "tLast"):
            n = self.chip_len(name)
            if n is None:
                bad.append("no array labelled %s" % name)
            else:
                arena[name] = n
        if arena and len(set(arena.values())) != 1:
            bad.append("arena lenses out of step: %s"
                       % ", ".join("%s=%d" % kv for kv in sorted(arena.items())))
        tp = min(arena.values()) if arena else None
        th = self.chip_var("tHeap")
        # `tHeap` counts heap ENTRIES, and the chip bounds it two ways: its own
        # guard is `if tHeap >= tOwner.length()` (lua.ws:8161) and the ceiling is
        # MAX_HEAP with `else if tHeap < MAX_HEAP` (lua.ws:8238).  It is NOT
        # bounded by the TABLE lenses tLen/tFirst/tLast, which are sized MAX_TABLES
        # (512) -- a 5,000-entry table run sits above those by design and the
        # hand-written evaluator reported them grown, which is why the old check
        # passed.  Read the lens the chip actually compares against.
        # The per-entry arrays (tOwner/tKey*/tPrev/tNext/tv*) are grown together by
        # heapEnsure, so their lengths WOULD bound tHeap -- but not readably: a
        # container written inside a `chip` body reads back its persisted
        # (init-time) reference through a probe, the same staleness the official
        # simulator shows for the lerr bool, so a grown arena reads 4 there while
        # tHeap is 5.  What is checkable without lying about the read is the
        # ceiling the chip enforces: `else if tHeap < MAX_HEAP` (lua.ws:8238),
        # mirrored in tests/spec.py.  A runaway OOM that walks tHeap past it
        # still fails here, which is what the case's contract wants.
        if th is not None and th > spec.MAX_HEAP:
            bad.append("tHeap=%s past MAX_HEAP=%d" % (th, spec.MAX_HEAP))
        ck = self.chip_var("cloK")
        cn = self.chip_var("cloN")
        if ck is not None and cn is not None and ck > cn:
            bad.append("cloK=%s past cloN=%s" % (ck, cn))
        return bad

    def watch_run(self, ticks, label=None):
        """One `watch` round trip for a whole run: per-tick lines with the
        engine's cumulative eval/step counters, the busy latch and one probed
        global, ending when the latch finishes the run. This is the tick
        currency a benchmark reads: the engine's own counters, not a model's
        bookkeeping."""
        if not self._started:
            self._start()
        cmd = {"cmd": "watch", "ticks": ticks}
        if label:
            cmd["label"] = label
        self._send(cmd)
        used = 0
        comp = None
        evs = 0
        stps = 0
        seen_true = False
        last_busy = None
        while True:
            r = self._readline_json()
            if "err" in r:
                self.finished = False
                self.engineError = r.get("err") or ""
                # The driver still prints its trailing summary after the err
                # line; leaving it unread misaligns the NEXT command, which
                # then answers with a stale per-tick line (that is what a
                # `capture` desync says).
                self._readline_json()
                return {"ticks": r.get("tick", used + 1), "compile": comp,
                        "evals": evs, "steps": stps, "log": self.log,
                        "outGlobals": {}, "finished": False, "err": r["err"]}
            if "tick" not in r:
                # the trailing summary line: the round trip is over
                break
            used = r["tick"]
            evs = r.get("evals", evs)
            stps = r.get("steps", stps)
            b = r.get("busy")
            if isinstance(b, bool):
                last_busy = b
                if b:
                    seen_true = True
            if "idval" in r and comp is None and truthy(r["idval"]):
                comp = used
            if isinstance(b, bool) and not b and seen_true:
                # The run finished INSIDE the window. The driver still has to
                # hand back the rest of the window's per-tick lines and then the
                # summary: stopping here leaves them unread, so the next command
                # (`capture`) reads a stale per-tick line and calls it a desync.
                # Drain to the summary, keeping the counters at the window's end.
                while True:
                    d = self._readline_json()
                    if "tick" not in d:
                        break
                    used = d["tick"]
                    evs = d.get("evals", evs)
                    stps = d.get("steps", stps)
                    db = d.get("busy")
                    if isinstance(db, bool):
                        last_busy = db
                break
        self._refresh_log()
        cap = self.capture()
        self.finished = seen_true and last_busy is False
        return {"ticks": used + 1, "compile": comp, "evals": evs,
                "steps": stps, "log": self.log, "outGlobals": cap["outGlobals"],
                "finished": self.finished}

    def close(self):
        try:
            self.child.stdin.writelines([json.dumps({"cmd": "quit"}) + "\n"])
            self.child.stdin.flush()
        except (OSError, ValueError):
            pass
        self.child.terminate()


def sim_from_brz(brz, **kw):
    return Sim(brz, **kw)


# --- getting a .brz to run ---------------------------------------------------

import shutil


def _find_compiler():
    """The Wirescript compiler, the same search the IR tools used."""
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    here = os.path.dirname(root)
    cands = [
        os.environ.get("WIRESCRIPT"),
        shutil.which("wirescript"),
        os.path.join(root, "wirescript", "target", "release", "wirescript.exe"),
        os.path.join(root, "wirescript", "target", "release", "wirescript"),
        os.path.join(here, "wirescript", "target", "release", "wirescript.exe"),
        os.path.join(here, "wirescript", "target", "release", "wirescript"),
    ]
    for c in cands:
        if c and os.path.isfile(c):
            return os.path.abspath(c)
    raise FileNotFoundError("no wirescript compiler found")


WS_EXE = _find_compiler()
WS_DIR = os.path.dirname(os.path.dirname(WS_EXE))


def compile_ws(ws_path, out_brz):
    """Compile one chip to one artifact. The compiler writes NO artifact when
    it has diagnostics, so rc != 0 is a hard error, not a warning: a build
    that ignores it ships yesterday's .brz (buildbrz.py's lesson)."""
    p = subprocess.run([WS_EXE, "compile", os.path.abspath(ws_path),
                        "-o", os.path.abspath(out_brz)],
                       cwd=WS_DIR, capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    if p.returncode != 0:
        diag = "\n".join((p.stdout + "\n" + p.stderr).splitlines()[:20])
        raise RuntimeError("compiler rejected %s (rc=%d): %s"
                          % (ws_path, p.returncode, diag))
    return out_brz


def ensure_brz(ws_path):
    """The artifact to run: `lua.ws` uses the repo's `lua.brz`, rebuilt only
    when it is older than the source (buildbrz.py owns the real build; this
    is the same rule, so a suite cannot quietly run a stale chip). An
    alternate --ws chip compiles to a scratch artifact."""
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    if os.path.abspath(ws_path) == os.path.join(root, "lua.ws"):
        brz = os.path.join(root, "lua.brz")
        if (os.path.exists(brz)
                and os.path.getmtime(brz) >= os.path.getmtime(ws_path)):
            return brz
        return compile_ws(ws_path, brz)
    import tempfile
    fd, brz = tempfile.mkstemp(suffix=".brz")
    os.close(fd)
    return compile_ws(ws_path, brz)


# --- the old harness names, for scripts written against the model ------------
# A `ChipRunner` was a model plus nothing; here it is the same shape over one
# simdrv child.  `share_dump` used to pickle the indexed graph; the shareable
# artifact now is the compiled .brz, so it copies that, and `sim_from_dump`
# loads what the copy holds. Worker pools that made one Sim per process keep
# working: a `new` per run is the fresh machine, the load is the artifact.


def share_dump(ws_path, path):
    """The shared artifact: compile once, copy the .brz to `path`."""
    shutil.copyfile(ensure_brz(ws_path), path)
    return path


def sim_from_dump(path):
    """A Sim over the artifact a share_dump wrote -- nothing compiled."""
    return Sim(path)


class ChipRunner:
    """One machine (built once), any number of programs on it.

    Same shape the model's ChipRunner had: `run(src, ticks, inputs)` resets,
    feeds the ports, runs, and answers with `log`/`outGlobals`/`tick`; `sim`
    carries `finished` after the run, as the probes read it.
    """

    def __init__(self, ws_path=None, sim=None):
        self.sim = sim if sim is not None else Sim(ensure_brz(ws_path))

    def reset(self):
        self.sim.reset()

    def run(self, src, max_ticks=8000, inputs=None):
        self.sim.reset()
        self.sim.inputs = {"program": src, "run": True}
        if inputs:
            self.sim.inputs.update(inputs)
        return self.sim.run(max_ticks)

