use serde_json::{from_str, to_string, Value};

use std::collections::HashMap;
use std::collections::HashSet;
use std::fs::{read};
use std::io::BufRead;

use wirescript_sim::{
    ChatLine,
    Dt,
    Graph,
    GateId,
    Loaded,
    Machine,
    ScriptWorld,
    Sim,
    SimOptions,
    Value as WireVal,
};
use wirescript_sim::graph::{Call, Gate, Input, Output, Src};
use wirescript_sim::graph::Op;
use wirescript_sim::load::BrickAddr;
use wirescript_ir::semantics::sim_certifies;
use brdb::schema::{BrdbValue, EA3WireVariant};

/// Everything the driver holds between commands.
pub struct St {
    loaded: Option<Loaded>,
    run: Option<Sim>,
    probeMap: HashMap<String, GateId>,
    busyGate: Option<GateId>,
    // The run's root pin gates, cached: `pin_gates` walks every gate in the
    // graph twice, so recomputing it per command made a per-tick window (a
    // lifecycle case) quadratic in the chip's size -- 8,000 windows x 40,000
    // gates.  Only `new` rebuilds the graph, so the ids are stable until then.
    pinsIn: Vec<GateId>,
    pinsOut: Vec<GateId>,
    chatSeen: usize,
    logFirst: Option<u64>,
    busyFirstFalse: Option<u64>,
    busySeenTrue: bool,
    busyLast: Option<bool>,
    /// The `new` command the machine was built with: a replay rebuilds from
    /// the same ports, probes, seed and dt.
    newcmd: Option<Value>,
    /// Every input change since `new`, as (tick, ports delta). The official
    /// engine sizes an array pin's storage when it builds the machine, so an
    /// array change after that cannot be written into the running machine; it
    /// is applied by rebuilding and replaying this timeline instead.
    timeline: Vec<(u64, Value)>,
    /// Per array pin the chip's `ContainerChange` watches: the appended copy
    /// gate and the two input ports that name the container to write (see
    /// `wire_container_feeds`).
    feedWrites: HashMap<GateId, (GateId, u16, u16)>,
}

/// Root microchip pin gates, by gate id: pins live on grids that are not any
/// chip's interior.
fn pin_gates(graph: &Graph) -> (Vec<GateId>, Vec<GateId>) {
    let mut ins: Vec<GateId> = Vec::new();
    let mut outs: Vec<GateId> = Vec::new();
    let mut root: u32 = 0;
    let mut found = false;
    for (id, gate) in graph.gates.iter().enumerate() {
        if gate.class.contains("MicrochipInput") {
            if !found || gate.addr.grid < root {
                root = gate.addr.grid;
                found = true;
            }
        }
    }
    for (id, gate) in graph.gates.iter().enumerate() {
        if gate.addr.grid == root {
            if gate.class.ends_with("MicrochipInput") {
                ins.push(id as GateId);
            } else if gate.class.ends_with("MicrochipOutput") {
                outs.push(id as GateId);
            }
        }
    }
    (ins, outs)
}

/// Indices into the root chip's input-pin list whose PortLabel matches a prefix
/// -- the harness uses `readgrids` to find the ReadBrickGrid pins and re-fires
/// them periodically, which is what a host sync does in game.
fn labelled_pins(graph: &Graph, want: String) -> Vec<u64> {
    let (ins, _) = pin_gates(graph);
    let mut ids: Vec<u64> = Vec::new();
    for (idx, gi) in ins.iter().enumerate() {
        let g = &graph.gates[*gi as usize];
        let mut hit = false;
        match &g.data {
            None => {},
            Some(d) => {
                for v in d.properties.values() {
                    match v {
                        BrdbValue::String(s) => {
                            if s.contains(&want) {
                                hit = true;
                            }
                        },
                        _ => {},
                    }
                }
            },
        }
        if hit {
            ids.push(idx as u64);
        }
    }
    ids
}

fn handle(st: &mut St, cmd: &Value) -> (Value, bool) {
    let mut name = "";
    match cmd.get("cmd") {
        Some(v) => match v.as_str() {
            Some(s) => { name = s; },
            None => {},
        },
        None => {},
    };
    match name {
        "load_brz" => (load_brz(st, cmd), false),
        "ports" => {
            match &st.loaded {
                None => (serde_json::json!({"err": "nothing loaded"}), false),
                Some(loaded) => {
                    let (ins, outs) = pin_gates(&loaded.graph);
                    (serde_json::json!({"ok": true, "in": ins, "out": outs}), false)
                },
            }
        },
        "scan" => {
            match &st.loaded {
                None => (serde_json::json!({"err": "nothing loaded"}), false),
                Some(loaded) => {
                    let (ins, outs) = pin_gates(&loaded.graph);
                    let mut inShapes: Vec<Value> = Vec::new();
                    for gi in 0..ins.len() {
                        let gate = &loaded.graph.gates[ins[gi] as usize];
                        let mut pnames: Vec<String> = Vec::new();
                        for p in gate.inputs.iter() {
                            pnames.push(p.name.clone());
                        }
                        let mut srcdesc = "".to_string();
                        for p in gate.inputs.iter() {
                            if p.name == "RER_Input" {
                                match p.source {
                                    Some(s) => {
                                        let sg = s.gate;
                                        let cls = &loaded.graph.gates[sg as usize].class;
                                        srcdesc = format!("gate {sg}: {cls}");
                                    },
                                    None => {},
                                }
                            }
                        }
                        inShapes.push(serde_json::json!({"gate": ins[gi], "inputs": pnames, "src": srcdesc}));
                    }
                    let mut outShapes: Vec<Value> = Vec::new();
                    for gi in 0..outs.len() {
                        let gate = &loaded.graph.gates[outs[gi] as usize];
                        let mut pnames: Vec<String> = Vec::new();
                        for p in gate.outputs.iter() {
                            pnames.push(p.name.clone());
                        }
                        outShapes.push(serde_json::json!({"gate": outs[gi], "outputs": pnames}));
                    }
                    (serde_json::json!({"ok": true, "in": inShapes, "out": outShapes}), false)
                },
            }
        },
        "new" => (do_new(st, cmd), false),
        "set" => (do_set(st, cmd), false),
        "run" => (do_run(st, cmd), false),
        "scanlabels" => {
            // Every gate with a String property equal to `label` (or all):
            // shows where a probe label actually comes from.
            let want = cmd_str(cmd, "label");
            match &st.loaded {
                None => (serde_json::json!({"err": "nothing loaded"}), false),
                Some(loaded) => {
                    let mut hits: Vec<Value> = Vec::new();
                    for (i, g) in loaded.graph.gates.iter().enumerate() {
                        match &g.data {
                            None => {},
                            Some(d) => {
                                for (_, v) in d.properties.iter() {
                                    match v {
                                        BrdbValue::String(s) => {
                                            if want == "" || *s == want {
                                                let srcs: Vec<Value> =
                                                    g.inputs.iter().map(|inp|
                                                        match &inp.source {
                                                            None => serde_json::json!(null),
                                                            Some(sr) => {
                                                                let sg = &loaded.graph.gates[sr.gate as usize];
                                                                serde_json::json!({"src": sr.gate,
                                                                 "srcGrid": sg.addr.grid,
                                                                 "srcClass": sg.class,
                                                                 "remote": sr.remote})
                                                            },
                                                        }
                                                    ).collect();
                                                hits.push(serde_json::json!(
                                                    {"id": i, "grid": g.addr.grid,
                                                     "chunk": g.addr.chunk,
                                                     "class": g.class,
                                                     "s": s, "srcs": srcs}));
                                            }
                                        },
                                        _ => {},
                                    }
                                }
                            },
                        }
                    }
                    (serde_json::json!({"ok": true, "hits": hits}), false)
                },
            }
        },
        "capture" => (do_capture(st, cmd), false),
        "gfind" => {
            match &st.loaded {
                None => (serde_json::json!({"err": "nothing loaded"}), false),
                Some(loaded) => {
                    let want = cmd_str(cmd, "class");
                    let bwant_n: u64 = match cmd.get("brick") {
                        Some(v) => match v.as_u64() {
                            Some(n) => n,
                            None => 0,
                        },
                        None => 0,
                    };
                    let mut hits: Vec<Value> = Vec::new();
                    for (i, g) in loaded.graph.gates.iter().enumerate() {
                        if g.class.contains(&want) {
                            if bwant_n > 0 && bwant_n != (g.addr.brick as u64) {
                                continue;
                            }
                            hits.push(serde_json::json!({"id": i, "grid": g.addr.grid, "brick": g.addr.brick}));
                            if hits.len() > 20 {
                                break;
                            }
                        }
                    }
                    (serde_json::json!({"ok": true, "hits": hits}), false)
                },
            }
        },
        "census" => (do_census(st), false),
        "watch" => {
            // {ticks: N}: step one tick at a time and print what the machine
            // still has pending after each -- how a stuck run looks from
            // outside (which handler/work item keeps firing).
            let n: u64 = match cmd.get("ticks") {
                Some(v) => match v.as_u64() { Some(x) => x, None => 1 },
                None => 1,
            };
            let want_label = match cmd.get("label") {
                Some(v) => match v.as_str() { Some(x) => x.to_string(),
                                               None => "".to_string() },
                None => "".to_string(),
            };
            let probeGate: Option<GateId> = match &st.probeMap.get(&want_label) {
                None => None,
                Some(gx) => Some(**gx),
            };
            let busyGate: Option<GateId> = match st.busyGate {
                None => None,
                Some(gb) => Some(gb),
            };
            match &mut st.run {
                None => (serde_json::json!({"err": "no run started"}), false),
                Some(s) => {
                    let mut seenTrue = false;
                    for _ in 0..n {
                        let t0 = s.machine.tick();
                        match s.machine.run_until(t0 + 1) {
                            Err(e) => {
                                println!("{}", serde_json::json!({"tick": t0 + 1, "err": format!("{}", e)}).to_string());
                                break;
                            },
                            Ok(_) => {},
                        }
                        let st_pair = s.machine.stats();
                        let busyj: Option<bool> = match busyGate {
                            None => None,
                            Some(gb) => match s.machine.evaluate_alone(gb) {
                                Err(_) => None,
                                Ok(w) => Some(truthy(w)),
                            },
                        };
                        match busyj {
                            Some(true) => { seenTrue = true; },
                            Some(false) => {},
                            None => {},
                        };
                        let stop = match busyj {
                            Some(false) => seenTrue,
                            _ => false,
                        };
                        match probeGate {
                            None => {
                                println!("{}", serde_json::json!({
                                    "tick": t0 + 1,
                                    "busy": busyj,
                                    "pending": s.machine.pending_work(),
                                    "evals": st_pair.0,
                                    "steps": st_pair.1,
                                }).to_string());
                            },
                            Some(gi) => {
                                let shown = match s.machine.evaluate_alone(gi) {
                                    Err(e) => serde_json::json!({"err": format!("{}", e)}),
                                    Ok(w) => wire_to_json(w),
                                };
                                println!("{}", serde_json::json!({
                                    "tick": t0 + 1,
                                    "busy": busyj,
                                    "pending": s.machine.pending_work(),
                                    "evals": st_pair.0,
                                    "steps": st_pair.1,
                                    "idval": shown,
                                }).to_string());
                            },
                        }
                        if stop {
                            break;
                        }
                    }
                    (serde_json::json!({"ok": true}), false)
                },
            }
        },
        "bricks" => {
            // {grid, from, to}: every gate on a grid with `from <= brick <= to`,
            // as {brick, class, id} -- brick order follows source order, so a
            // neighborhood identifies the compiled expression's source line.
            let wantGrid: u64 = match cmd.get("grid") {
                Some(v) => match v.as_u64() { Some(x) => x, None => 0 },
                None => 0,
            };
            let lo: u64 = match cmd.get("from") {
                Some(v) => match v.as_u64() { Some(x) => x, None => 0 },
                None => 0,
            };
            let hi: u64 = match cmd.get("to") {
                Some(v) => match v.as_u64() { Some(x) => x, None => 0 },
                None => 18446744073709551615,
            };
            match &st.loaded {
                None => (serde_json::json!({"err": "nothing loaded"}), false),
                Some(loaded) => {
                    let mut hits: Vec<Value> = Vec::new();
                    for (i, g) in loaded.graph.gates.iter().enumerate() {
                        if g.addr.grid as u64 == wantGrid && g.addr.brick as u64 >= lo && g.addr.brick as u64 <= hi {
                            hits.push(serde_json::json!({"id": i, "brick": g.addr.brick, "class": g.class.clone()}));
                        }
                    }
                    (serde_json::json!({"ok": true, "hits": hits}), false)
                },
            }
        },
        "vpins" => {
            // Every MicrochipInput pin whose PortLabel contains `prefix`, with
            // the gate and output port the remote wire carries: this is how a
            // chip global NAME becomes a readable gate (the Value pin's RER
            // refreshes from the container's live state).
            let want = cmd_str(cmd, "prefix");
            match &st.loaded {
                None => (serde_json::json!({"err": "nothing loaded"}), false),
                Some(loaded) => {
                    let mut hits: Vec<Value> = [].to_vec();
                    for (i, g) in loaded.graph.gates.iter().enumerate() {
                        if !g.class.contains("MicrochipInput") {
                            continue;
                        }
                        let mut label = "".to_string();
                        match &g.data {
                            None => {},
                            Some(d) => {
                                for p in d.properties.values() {
                                    match p {
                                        BrdbValue::String(s) => {
                                            if s.contains(&want) {
                                                label = s.clone();
                                            }
                                        },
                                        _ => {},
                                    }
                                }
                            },
                        }
                        if label == "" {
                            continue;
                        }
                        for (si, inp) in g.inputs.iter().enumerate() {
                            match &inp.source {
                                None => {},
                                Some(s) => {
                                    hits.push(serde_json::json!({"id": i, "label": label,
                                        "src": s.gate, "out": s.out, "remote": s.remote,
                                        "class": loaded.graph.gates[s.gate as usize].class.clone()}));
                                },
                            }
                        }
                    }
                    (serde_json::json!({"ok": true, "hits": hits}), false)
                },
            }
        },
        "readgrids" => {
            // Input-pin indices whose PortLabel contains `prefix` (the harness
            // re-fires ReadBrickGrid pins; this chip has none, so this is a
            // probe kept for future chips, not a suite dependency).
            let want = cmd_str(cmd, "prefix");
            match &st.loaded {
                None => (serde_json::json!({"err": "nothing loaded"}), false),
                Some(loaded) => {
                    (serde_json::json!({"ok": true, "pins": labelled_pins(&loaded.graph, want)}), false)
                },
            }
        },
        "varnames" => {
            // Var/ArrayVar container gates with their stored properties: the
            // harness maps chip var NAMES to gate ids for reading live state.
            match &st.loaded {
                None => (serde_json::json!({"err": "nothing loaded"}), false),
                Some(loaded) => {
                    let mut hits: Vec<Value> = [].to_vec();
                    let mut ci = 0usize;
                    for (i, g) in loaded.graph.gates.iter().enumerate() {
                        if g.class.ends_with("Var") || g.class.ends_with("ArrayVar")
                            || g.class.ends_with("MapVar") {
                            let mut label = "".to_string();
                            match &g.data {
                                None => {},
                                Some(d) => {
                                    for v in d.properties.values() {
                                        match v {
                                            BrdbValue::String(s) => {
                                                label = s.clone();
                                            },
                                            _ => {},
                                        }
                                    }
                                },
                            }
                            hits.push(serde_json::json!({"id": i, "class": g.class,
                                "label": label, "grid": g.addr.grid,
                                "brick": g.addr.brick,
                                "probe": format!("#{}", ci)}));
                            ci = ci + 1;
                        }
                    }
                    (serde_json::json!({"ok": true, "hits": hits}), false)
                },
            }
        },
        "findst" => {
            // {class, stored}: gates whose class contains `class` and whose
            // first stored (unwired) input equals `stored` -- locates compare
            // gates by their baked literal (e.g. class "Compare", stored 99).
            let want = cmd_str(cmd, "class");
            let sval = match cmd.get("stored") {
                Some(v) => match v.as_i64() { Some(x) => x, None => 0 },
                None => 0,
            };
            match &st.loaded {
                None => (serde_json::json!({"err": "nothing loaded"}), false),
                Some(loaded) => {
                    let mut hits: Vec<Value> = [].to_vec();
                    for (i, g) in loaded.graph.gates.iter().enumerate() {
                        if g.class.contains(&want) {
                            for p in g.inputs.iter() {
                                match p.source {
                                    None => {
                                        match p.stored {
                                            Some(WireVal::Int(n)) => {
                                                if n == sval {
                                                    hits.push(serde_json::json!({"id": i, "brick": g.addr.brick,
                                                        "class": g.class.clone(), "port": p.name.clone()}));
                                                }
                                            },
                                            _ => {},
                                        }
                                    },
                                    Some(_) => {},
                                }
                            }
                        }
                    }
                    (serde_json::json!({"ok": true, "hits": hits}), false)
                },
            }
        },
        "val" => {
            // Evaluate one gate standalone after a run: the harness reads
            // scalar chip state by evaluating the Var-Get gate that reads it.
            match &mut st.run {
                None => (serde_json::json!({"err": "no run started"}), false),
                Some(s) => {
                    match cmd.get("id") {
                        Some(v) => match v.as_u64() {
                            Some(n) => {
                                let gi = n as GateId;
                                match s.machine.evaluate_alone(gi) {
                                    Err(e) => (serde_json::json!({"err": format!("pin: {e}")}), false),
                                    Ok(w) => (serde_json::json!({"ok": true, "value": wire_to_json(w)}), false)
                                }
                            },
                            None => (serde_json::json!({"err": "no id"}), false),
                        },
                        None => (serde_json::json!({"err": "no id"}), false),
                    }
                },
            }
        },
        "olabels" => {
            // Root-chip OUTPUT pins with their PortLabels: how a harness names
            // the out ports (index = position in `ports`'s out list).
            match &st.loaded {
                None => (serde_json::json!({"err": "nothing loaded"}), false),
                Some(loaded) => {
                    let (ins, outs) = pin_gates(&loaded.graph);
                    let mut hits: Vec<Value> = Vec::new();
                    for (idx, gi) in outs.iter().enumerate() {
                        let g = &loaded.graph.gates[*gi as usize];
                        let mut label = "".to_string();
                        match &g.data {
                            None => {},
                            Some(d) => {
                                for p in d.properties.values() {
                                    match p {
                                        BrdbValue::String(s) => { label = s.clone(); },
                                        _ => {},
                                    }
                                }
                            },
                        }
                        hits.push(serde_json::json!({"i": idx, "gate": *gi,
                            "label": label}));
                    }
                    let mut ihits: Vec<Value> = Vec::new();
                    for (idx, gi) in ins.iter().enumerate() {
                        let g = &loaded.graph.gates[*gi as usize];
                        let mut label = "".to_string();
                        match &g.data {
                            None => {},
                            Some(d) => {
                                for p in d.properties.values() {
                                    match p {
                                        BrdbValue::String(s) => { label = s.clone(); },
                                        _ => {},
                                    }
                                }
                            },
                        }
                        ihits.push(serde_json::json!({"i": idx, "gate": *gi,
                            "label": label}));
                    }
                    (serde_json::json!({"ok": true, "hits": hits, "inhits": ihits,
                        "ins": ins, "outs": outs}), false)
                },
            }
        },
        "getout" => {
            // One root output pin by index (the `olabels` order): a cheap
            // per-tick read for a harness.
            let oidx: usize = match cmd.get("i") {
                Some(v) => match v.as_u64() { Some(x) => x as usize, None => 0 },
                None => 0,
            };
            match &mut st.run {
                None => (serde_json::json!({"err": "no run started"}), false),
                Some(s) => {
                    if oidx >= st.pinsOut.len() {
                        (serde_json::json!({"err": "no such out pin"}), false)
                    } else {
                        match s.machine.evaluate_alone(st.pinsOut[oidx]) {
                            Err(e) => (serde_json::json!({"err": format!("getout: {e}")}), false),
                            Ok(w) => (serde_json::json!({"ok": true,
                                "value": wire_to_json(w)}), false)
                        }
                    }
                },
            }
        },
        "runlog" => {
            // Run `ticks` ticks, printing the log out-port (index `out`,
            // default 0) and the busy latch after every tick, so a harness can
            // watch per tick without a round trip per tick.
            match &mut st.run {
                None => (serde_json::json!({"err": "no run started"}), false),
                Some(s) => {
                    let n: u64 = match cmd.get("ticks") {
                        Some(v) => match v.as_u64() { Some(x) => x, None => 1 },
                        None => 1,
                    };
                    let oidx: usize = match cmd.get("out") {
                        Some(v) => match v.as_u64() { Some(x) => x as usize, None => 0 },
                        None => 0,
                    };
                    let pins_out = &st.pinsOut;
                    let want_ports = match cmd.get("ports") {
                        Some(v) => v.as_bool() == Some(true),
                        None => false,
                    };
                    let target = s.machine.tick() + n;
                    while s.machine.tick() < target {
                        match s.run_until(s.machine.tick() + 1) {
                            Err(e) => {
                                println!("{}", serde_json::json!({"tick": s.machine.tick(),
                                    "err": format!("{}", e)}).to_string());
                                break;
                            },
                            Ok(_) => {},
                        }
                        let mut lv: Value = serde_json::json!(null);
                        let pj: Value = if want_ports {
                            let vals: Vec<Value> = pins_out.iter().map(
                                |oi| match s.machine.evaluate_alone(*oi) {
                                    Err(_) => serde_json::json!(null),
                                    Ok(w2) => wire_to_json(w2),
                                }
                            ).collect();
                            serde_json::json![vals]
                        } else {
                            serde_json::json!(null)
                        };
                        if oidx < pins_out.len() {
                            match s.machine.evaluate_alone(pins_out[oidx]) {
                                Err(_) => {},
                                Ok(w) => { lv = wire_to_json(w); },
                            }
                        }
                        let busyj: Value = match st.busyGate {
                            None => serde_json::json!(null),
                            Some(gb) => match s.machine.evaluate_alone(gb) {
                                Err(_) => serde_json::json!(null),
                                Ok(w) => serde_json::json!(truthy(w)),
                            },
                        };
                        println!("{}", serde_json::json!({"tick": s.machine.tick(),
                            "log": lv, "busy": busyj, "ports": pj}).to_string());
                    }
                    (serde_json::json!({"ok": true, "tick": s.machine.tick()}), false)
                },
            }
        },
        "vreadmany" => {
            // Several probe labels in one round trip: a harness reading a
            // container's contents pays 640 of these per capture, and a round
            // trip each is most of the suite's array-case wall clock.
            let keys: Vec<String> = match cmd.get("labels") {
                Some(v) => match v.as_array() {
                    Some(a) => {
                        let mut ks: Vec<String> = Vec::new();
                        for kv in a.iter() {
                            match kv.as_str() {
                                Some(s) => { ks.push(s.to_string()); },
                                None => {},
                            }
                        }
                        ks
                    },
                    None => Vec::new(),
                },
                None => Vec::new(),
            };
            match &mut st.run {
                None => (serde_json::json!({"err": "no run started"}), false),
                Some(s) => {
                    let mut vals: Vec<Value> = Vec::new();
                    for key in keys.iter() {
                        match &st.probeMap.get(key) {
                            None => { vals.push(serde_json::json!({"missing": true})); },
                            Some(rid) => match s.machine.evaluate_alone(**rid) {
                                Err(e) => { vals.push(serde_json::json!({"err": format!("{}", e)})); },
                                Ok(w) => { vals.push(wire_to_json(w)); },
                            },
                        }
                    }
                    (serde_json::json!({"ok": true, "values": vals}), false)
                },
            }
        },
        "vread" => {
            // A chip global by NAME, read through the probe reroute `new`
            // installed for it (see add_probes).
            let want = cmd_str(cmd, "label");
            match &st.probeMap.get(&want) {
                None => (serde_json::json!({"err": format!("no probe for {want}")}), false),
                Some(rid) => match &mut st.run {
                    None => (serde_json::json!({"err": "no run started"}), false),
                    Some(s) => {
                        match s.machine.evaluate_alone(**rid) {
                            Err(e) => (serde_json::json!({"err": format!("vread: {e}")}), false),
                            Ok(w) => (serde_json::json!({"ok": true, "value": wire_to_json(w)}), false)
                        }
                    },
                },
            }
        },
        "gate2" => {
            // Same as `gate` but on the RUNNING graph (which carries the probes).
            match &st.run {
                None => (serde_json::json!({"err": "no run started"}), false),
                Some(s) => {
                    match cmd.get("id") {
                        Some(v) => match v.as_u64() {
                            Some(n) => {
                                let gi = n as usize;
                                let gl = &s.machine.graph;
                                if gi >= gl.gates.len() {
                                    (serde_json::json!({"err": "no such gate"}), false)
                                } else {
                                    let g = &gl.gates[gi];
                                    let mut ins: Vec<Value> = Vec::new();
                                    for p in g.inputs.iter() {
                                        let mut srcj: Value = serde_json::json!({"none": true});
                                        match p.source {
                                            Some(sr) => {
                                        srcj = serde_json::json!({"gate": sr.gate, "remote": sr.remote,
                                            "out": sr.out});
                                            },
                                            None => {},
                                        }
                                        let storedj = wire_to_json(p.stored.clone());
                                        ins.push(serde_json::json!({"name": p.name.clone(),
                                            "source": srcj, "stored": storedj}));
                                    }
                                    let mut tos: Vec<Value> = Vec::new();
                                    for (di, dg) in gl.gates.iter().enumerate() {
                                        for dp in dg.inputs.iter() {
                                            match &dp.source {
                                                None => {},
                                                Some(src) => {
                                                    if src.gate == gi as GateId {
                                                        tos.push(serde_json::json!({"gate": di,
                                                            "class": dg.class.clone(), "in": dp.name.clone(),
                                                            "out": src.out, "remote": src.remote}));
                                                    }
                                                },
                                            }
                                        }
                                    }
                                    let mut onames: Vec<Value> = Vec::new();
                                    for op in g.outputs.iter() {
                                        onames.push(serde_json::json!({"port": op.name.clone(),
                                            "exec": op.exec, "calls": op.calls.len()}));
                                    }
                                    (serde_json::json!({"ok": true, "id": gi,
                                        "class": g.class.clone(), "grid": g.addr.grid,
                                        "brick": g.addr.brick, "inputs": ins,
                                        "outputs": onames, "to": tos}), false)
                                }
                            },
                            None => (serde_json::json!({"err": "no id"}), false),
                        },
                        None => (serde_json::json!({"err": "no id"}), false),
                    }
                },
            }
        },
        "gate" => {
            match &st.loaded {
                None => (serde_json::json!({"err": "nothing loaded"}), false),
                Some(loaded) => {
                    match cmd.get("id") {
                        Some(v) => match v.as_u64() {
                            Some(n) => {
                                let gi = n as usize;
                                if gi >= loaded.graph.gates.len() {
                                    (serde_json::json!({"err": "no such gate"}), false)
                                } else {
                                    let g = &loaded.graph.gates[gi];
                                    let mut ins: Vec<Value> = Vec::new();
                                    for p in g.inputs.iter() {
                                        let mut srcj: Value = serde_json::json!({"none": true});
                                        match p.source {
                                            Some(s) => { srcj = serde_json::json!({"gate": s.gate, "remote": s.remote}); },
                                            None => {},
                                        }
                                        let storedj = wire_to_json(p.stored.clone());
                                        ins.push(serde_json::json!({"name": p.name.clone(), "source": srcj, "stored": storedj}));
                                    }
                                    let mut outw: Vec<Value> = Vec::new();
                                    for (oi, o) in g.outputs.iter().enumerate() {
                                        let mut tos: Vec<Value> = Vec::new();
                                        for (dst, dg) in loaded.graph.gates.iter().enumerate() {
                                            for dp in dg.inputs.iter() {
                                                match dp.source {
                                                    Some(s) => {
                                                        if s.gate == gi as GateId {
                                                            tos.push(serde_json::json!({"gate": dst, "class": dg.class.clone(),
                                                                "in": dp.name.clone(), "from": o.name.clone(),
                                                                "out": s.out, "remote": s.remote}));
                                                        }
                                                    },
                                                    None => {},
                                                }
                                            }
                                        }
                                        outw.push(serde_json::json!({"port": o.name.clone(), "to": tos}));
                                    }
                                    let nodej = match g.node {
                                        Some(nid) => serde_json::json!(nid.0),
                                        None => serde_json::json!({"none": true}),
                                    };
                                    (serde_json::json!({"ok": true, "id": n, "class": g.class, "node": nodej, "grid": g.addr.grid, "brick": g.addr.brick, "inputs": ins, "outputs": outw}), false)
                                }
                            },
                            None => (serde_json::json!({"err": "no id"}), false),
                        },
                        None => (serde_json::json!({"err": "no id"}), false),
                    }
                },
            }
        },
        "quit" => (serde_json::json!({"ok": true}), true),
        _ => (serde_json::json!({"err": format!("unknown cmd: {name}")}), false),
    }
}

fn cmd_str(cmd: &Value, key: &str) -> String {
    match cmd.get(key) {
        Some(v) => match v.as_str() {
            Some(s) => s.to_string(),
            None => "".to_string(),
        },
        None => "".to_string(),
    }
}

fn cmd_bool(cmd: &Value, key: &str) -> bool {
    match cmd.get(key) {
        Some(v) => match v.as_bool() {
            Some(b) => b,
            None => false,
        },
        None => false,
    }
}

/// The names the save dropped, from the same compile's IR text (`compile
/// --emit-ir PATH`). A cube-layout emit writes a var's name label only on
/// the access pins of globals ANOTHER grid reads by remote wire, so the
/// artifact carries no handle for the chip's inner state (`polyOn`, the
/// per-lane spans, the pixel globals behind the `px` outputs) -- and a probe
/// driver that watches a paint needs those names. The IR is the only place
/// the compile keeps them. It lists containers in program order while the
/// emit places every array before every scalar, so the names pair with the
/// chip's containers in two kind groups; a count mismatch is refused rather
/// than answering `covLo` from `covHi`'s gate.
fn ir_names(cmd: &Value) -> Result<Vec<(String, bool)>, String> {
    let path = cmd_str(cmd, "ir");
    if path == "" {
        return Ok([].to_vec());
    }
    let text = match std::fs::read_to_string(&path) {
        Err(e) => return Err(format!("cannot read the IR text {path}: {e}")),
        Ok(t) => t,
    };
    let mut names: Vec<(String, bool)> = Vec::new();
    for line in text.lines() {
        let is_arr = line.contains(" = ArrayVar {");
        let is_var = line.contains(" = Var {");
        if !(is_arr || is_var) {
            continue;
        }
        let mut raw = "".to_string();
        for t in line.split(' ') {
            if raw == "" && t.starts_with("%") {
                raw = t.to_string();
            }
        }
        if raw == "" {
            continue;
        }
        names.push((raw[1..].to_string(), is_arr));
    }
    return Ok(names);
}

fn load_brz(st: &mut St, cmd: &Value) -> Value {
    let path = cmd_str(cmd, "path");
    match read(&path) {
        Err(e) => return serde_json::json!({"err": format!("cannot read {path}: {e}")}),
        Ok(bytes) => match Loaded::from_brz(&bytes) {
            Err(e) => serde_json::json!({"err": format!("load: {e}")}),
            Ok(loaded) => {
                st.loaded = Some(loaded);
                serde_json::json!({"ok": true})
            },
        },
    }
}

// --- values --------------------------------------------------------------

/// A JSON scalar into a wire value.
fn json_to_wire(v: &Value) -> Option<WireVal> {
    match v.as_bool() {
        Some(b) => return Some(WireVal::Bool(b)),
        None => {},
    }
    match v.as_i64() {
        Some(i) => return Some(WireVal::Int(i)),
        None => {},
    }
    match v.as_f64() {
        Some(f) => return Some(WireVal::Float(f)),
        None => {},
    }
    match v.as_str() {
        Some(s) => return Some(WireVal::Str(s.to_string())),
        None => {},
    }
    // Composites: the screen chip's shapePosition/Rotation/Scale ports carry
    // vectors and shapeColors colors, and the old path rendered all of them
    // as {"other": true} -- undrivable. JSON shape: {"color": [r,g,b,a]} and
    // {"vector": [x,y,z]}, the field order of the sim's own Value enum.
    match v.as_object() {
        Some(obj) => {
            match obj.get("color") {
                Some(a4) => match a4.as_array() {
                    Some(a) => match a.len() {
                        4 => return Some(WireVal::Color {
                            r: a[0].as_f64().unwrap_or(0.0),
                            g: a[1].as_f64().unwrap_or(0.0),
                            b: a[2].as_f64().unwrap_or(0.0),
                            a: a[3].as_f64().unwrap_or(0.0),
                        }),
                        _ => {},
                    },
                    None => {},
                },
                None => {},
            }
            match obj.get("vector") {
                Some(a3) => match a3.as_array() {
                    Some(a) => match a.len() {
                        3 => return Some(WireVal::Vector {
                            x: a[0].as_f64().unwrap_or(0.0),
                            y: a[1].as_f64().unwrap_or(0.0),
                            z: a[2].as_f64().unwrap_or(0.0),
                        }),
                        _ => {},
                    },
                    None => {},
                },
                None => {},
            }
        },
        None => {},
    }
    None
}

/// A wire value into JSON: scalars as they are, composites by shape
/// (json_to_wire's round-trip pair), references by shape.
fn wire_to_json(v: Option<WireVal>) -> Value {
    match v {
        None => serde_json::json!({"none": true}),
        Some(x) => match x {
            WireVal::Bool(b) => serde_json::json!(b),
            WireVal::Int(n) => serde_json::json!(n),
            WireVal::Float(f) => serde_json::json!(f),
            WireVal::Str(s) => serde_json::json!(s),
            WireVal::Ref(g) => serde_json::json!({"ref": g}),
            WireVal::Color { r, g, b, a } =>
                serde_json::json!({"color": [r, g, b, a]}),
            WireVal::Vector { x, y, z } =>
                serde_json::json!({"vector": [x, y, z]}),
            WireVal::Rotator { pitch, yaw, roll } =>
                serde_json::json!({"rotator": [pitch, yaw, roll]}),
            WireVal::Quat { x, y, z, w } =>
                serde_json::json!({"quat": [x, y, z, w]}),
            _ => serde_json::json!({"other": true}),
        },
    }
}

// --- runs ----------------------------------------------------------------

fn run_opts(cmd: &Value) -> SimOptions {
    SimOptions {
        seed: match cmd.get("seed") {
            Some(v) => match v.as_u64() { Some(n) => Some(n), None => None },
            None => None,
        },
        dt: match cmd.get("dt") {
            Some(v) => match v.as_f64() { Some(f) => Dt::Constant(f), None => Dt::Constant(1.0 / 60.0) },
            None => Dt::Constant(1.0 / 60.0),
        },
    }
}

/// Feed scalars into unwired input pins: `ports` maps the pin index (in
/// `ports` cmd order) to a JSON scalar. The pin keeps the value on its
/// reroute input port so the machine reads it at the start of the run.
fn feed_ports(graph: &mut Graph, cmd: &Value, pins: &Vec<GateId>) -> Vec<String> {
    let mut errs: Vec<String> = Vec::new();
    match cmd.get("ports") {
        Some(p) => match p.as_object() {
            Some(obj) => {
                for idx in 0..pins.len() {
                    let key = format!("{}", idx);
                    match obj.get(&key) {
                        Some(val) => {
                    let gate_id = pins[idx];
                    let gate = &graph.gates[gate_id as usize];
                    let at = {
                    let mut k = 0;
                        for (j, p) in gate.inputs.iter().enumerate() {
                            if p.name == "RER_Input" {
                                k = j;
                            }
                        }
                        k
                    };
                    if at >= gate.inputs.len() {
                        errs.push(format!("pin {gate_id} has no input port"));
                    } else {
                        match json_to_wire(val) {
                            Some(want) => {
                                graph.gates[gate_id as usize].inputs[at].source = None;
                                graph.gates[gate_id as usize].inputs[at].stored = Some(want);
                            },
                            None => match array_feed(graph, gate_id, at, val) {
                                Some(msg) => errs.push(msg),
                                None => {},
                            },
                        }
                    }
                        },
                        None => {},
                    };
                }
            },
            None => {},
        },
        None => {},
    }
    errs
}

/// Parse a JSON array spec `{"arr": "f64"|"Str"|"i64"|"bool"|"LinearColor",
/// "values": [...]}` and append a clone of an ArrayVar gate already in the
/// graph that holds its values. The clone's gate id is the reference a pin
/// carries -- the same shape the chip's own array ports report.
fn clone_array(graph: &mut Graph, spec: &Value) -> Result<GateId, String> {
    let obj = match spec.as_object() {
        Some(o) => o,
        None => return Err(format!("port is not an array spec")),
    };
    let kind = match obj.get("arr") {
        Some(v) => match v.as_str() {
            Some(s) => s.to_string(),
            None => return Err(format!("array spec: arr must be a string")),
        },
        None => return Err(format!("array spec: no arr")),
    };
    if kind != "f64" && kind != "Str" && kind != "i64" && kind != "bool"
        && kind != "LinearColor" {
        return Err(format!("array spec: arr must be f64, i64, Str, bool or LinearColor"));
    }
    let arr = match obj.get("values") {
        Some(v) => match v.as_array() {
            Some(a) => a,
            None => return Err(format!("array spec: values must be an array")),
        },
        None => return Err(format!("array spec: no values")),
    };
    let mut elems = Vec::new();
    for v in arr.iter() {
        if kind == "Str" {
            match v.as_str() {
                Some(s) => elems.push(BrdbValue::String(s.to_string())),
                None => return Err(format!("array value is not a string")),
            }
        } else if kind == "bool" {
            match v.as_bool() {
                Some(b) => elems.push(BrdbValue::Bool(b)),
                None => return Err(format!("array value is not a bool")),
            }
        } else if kind == "i64" {
            match v.as_i64() {
                Some(i) => elems.push(BrdbValue::I64(i)),
                None => return Err(format!("array value is not an integer")),
            }
        } else if kind == "LinearColor" {
            // shapeColors on the screen chip: color[] elements. The brdb
            // shape is the wire variant the sim's Value::from_brdb reads
            // LinearColor from; f32 fields, linear 0..1.
            match v.as_array() {
                Some(a) => match a.len() {
                    4 => elems.push(BrdbValue::EA3WireVar(
                        EA3WireVariant::LinearColor {
                            r: a[0].as_f64().unwrap_or(0.0) as f32,
                            g: a[1].as_f64().unwrap_or(0.0) as f32,
                            b: a[2].as_f64().unwrap_or(0.0) as f32,
                            a: a[3].as_f64().unwrap_or(0.0) as f32,
                        })),
                    _ => return Err(format!("array value is not a 4-field color")),
                },
                None => return Err(format!("array value is not an array")),
            }
        } else {
            match v.as_f64() {
                Some(f) => elems.push(BrdbValue::F64(f)),
                None => return Err(format!("array value is not a number")),
            }
        }
    }
    let mut tmpl = 0;
    let mut maxgrid: u32 = 0;
    let mut found = false;
    for (i, g) in graph.gates.iter().enumerate() {
        if g.addr.grid > maxgrid {
            maxgrid = g.addr.grid;
        }
        if !found && g.class.contains("ArrayVar") {
            match g.data {
                Some(ref s) => {
                    for v in s.properties.values() {
                        match v {
                            BrdbValue::DynamicArray(_) => {
                                found = true;
                            },
                            _ => {},
                        }
                    }
                },
                None => {},
            }
            if found {
                tmpl = i;
            }
        }
    }
    if !found {
        return Err(format!("no ArrayVar gate in the graph to clone"));
    }
    let mut g2 = graph.gates[tmpl].clone();
    g2.node = None;
    g2.span = None;
    let mut done = false;
    let mut sdata = g2.data.take();
    match sdata {
        None => {},
        Some(mut s) => {
            let mut newprops = HashMap::new();
            for (k, v) in s.properties {
                match v {
                    BrdbValue::DynamicArray(a) => {
                        if !done {
                            let mut b = a;
                            b.element_type = kind.clone();
                            b.values = elems.clone();
                            done = true;
                            newprops.insert(k, BrdbValue::DynamicArray(b));
                        } else {
                            newprops.insert(k, BrdbValue::DynamicArray(a));
                        }
                    },
                    _ => { newprops.insert(k, v); },
                }
            }
            s.properties = newprops;
            g2.data = Some(s);
        },
    }
    if !done {
        return Err(format!("template gate has no dynamic_array field"));
    }
    graph.gates.push(g2);
    Ok((graph.gates.len() - 1) as GateId)
}

/// Point a pin's reroute input at array gate `gid` -- the live-array write.
fn apply_array_ref(graph: &mut Graph, pin: GateId, at: usize, gid: GateId) {
    let mut rsrc_gate: Option<GateId> = None;
    match graph.gates[pin as usize].inputs[at].source {
        Some(s) => { rsrc_gate = Some(s.gate); },
        None => {},
    }
    graph.gates[pin as usize].inputs[at].source = None;
    graph.gates[pin as usize].inputs[at].stored = Some(WireVal::Ref(gid));
    match rsrc_gate {
        Some(rg) => {
            if graph.gates[rg as usize].class.contains("Rerouter") {
                let nin = graph.gates[rg as usize].inputs.len();
                let mut ji = 0;
                while ji < nin {
                    if graph.gates[rg as usize].inputs[ji].name == "RER_Input" {
                        graph.gates[rg as usize].inputs[ji].stored = Some(WireVal::Ref(gid));
                    }
                    ji += 1;
                }
            }
        },
        None => {},
    }
}

/// A JSON array spec fed into a pin: clone an ArrayVar with the wanted values
/// and store a reference to it in the pin's reroute input port.
fn array_feed(graph: &mut Graph, pin: GateId, at: usize, spec: &Value) -> Option<String> {
    match clone_array(graph, spec) {
        Ok(gid) => { apply_array_ref(graph, pin, at, gid); None },
        Err(e) => Some(e),
    }
}

/// The input port a pin's reroute takes its value on (0 if it has none).
fn reroute_at(graph: &Graph, pin: GateId) -> usize {
    let mut at = 0;
    for (j, p) in graph.gates[pin as usize].inputs.iter().enumerate() {
        if p.name == "RER_Input" { at = j; }
    }
    at
}

/// The host write a `ContainerChange` edge needs.
///
/// A chip that reacts to a host's ARRAY port only through
/// `on ContainerChange(port)` (the connector is such a chip: its one edge
/// is that event) stays inert under the driver's array feed, which swaps
/// the container the pin names. That is not what the engine does with a
/// container watch: `machine.rs` fires one only from `container_changed`,
/// which the array and map ops call when they WRITE a container -- a new
/// reference on a pin is not a write. So the driver appends the write the
/// law expects, for a pin the chip actually watches (a chip that reads its
/// ports on a `Clock`, the screen, gets no gate at all and runs untouched):
/// a `ChangeDetectorExec` on the pin's container reference, which the
/// engine re-fires exactly when that reference changes (its `Input` port is
/// a watched input), chained to one `Copy Array` gate that copies the
/// container onto itself -- contents unchanged, but the write is recorded,
/// and `container_changed` then fires the chip's detector next tick, which
/// is what a host rewriting its array port means.
/// Answers the copy gates by pin, so a replay can point each at the
/// container its own entry feeds; `new` points it at the entry it built.
fn wire_container_feeds(graph: &mut Graph, pins: &Vec<GateId>,
                        base: usize) -> HashMap<GateId, (GateId, u16, u16)> {
    let mut watched: Vec<GateId> = Vec::new();
    for (i, g) in graph.gates.iter().enumerate() {
        if i >= base {
            continue;
        }
        if !g.class.contains("ContainerChangeDetector") {
            continue;
        }
        for inp in g.inputs.iter() {
            match inp.source {
                Some(s) => {
                    if pins.contains(&s.gate) && !watched.contains(&s.gate) {
                        watched.push(s.gate);
                    }
                },
                None => {},
            }
        }
    }
    let mut out: HashMap<GateId, (GateId, u16, u16)> = HashMap::new();
    for pin0 in watched.iter() {
        let pin = *pin0;
        let mut pout: u16 = 0;
        for (o, op) in graph.gates[pin as usize].outputs.iter().enumerate() {
            if op.name == "RER_Output".to_string() {
                pout = o as u16;
            }
        }
        let ga = graph.gates[pin as usize].addr;
        let did = graph.gates.len() as GateId;
        let mut det = Gate::new("BrickComponentType_Expr_ChangeDetectorExec",
            BrickAddr {
                grid: ga.grid,
                chunk: ga.chunk,
                brick: 960000u32 + (pin as u32 % 100000u32),
            });
        // `Gate::new` fills a known class's ports from the catalog, so the
        // ports are found BY NAME among whatever it brought.
        let mut detIn: usize = 0;
        let mut detOut: usize = 0;
        for (p, inp) in det.inputs.iter().enumerate() {
            if inp.name == "Input".to_string() {
                detIn = p;
            }
        }
        for (p, outp) in det.outputs.iter().enumerate() {
            if outp.name == "OnChanged".to_string() {
                detOut = p;
            }
        }
        if det.inputs.len() == 0 {
            det.inputs.push(Input {
                name: "Input".to_string(),
                exec_pin: false,
                stored: None,
                source: None,
            });
            detIn = det.inputs.len() - 1;
        }
        if det.outputs.len() == 0 {
            det.outputs.push(Output {
                name: "OnChanged".to_string(),
                exec: true,
                readers: Vec::new(),
                calls: Vec::new(),
                default: None,
            });
            detOut = det.outputs.len() - 1;
        }
        det.inputs[detIn].source = Some(Src { gate: pin, out: pout, remote: false });
        graph.gates.push(det);
        graph.gates[pin as usize].outputs[pout as usize].readers.push((did, detIn as u16));
        let wid = graph.gates.len() as GateId;
        let mut cop = Gate::new("BrickComponentType_Exec_ArrayVar_CopyFrom",
            BrickAddr {
                grid: ga.grid,
                chunk: ga.chunk,
                brick: 970000u32 + (pin as u32 % 100000u32),
            });
        if cop.inputs.len() == 0 {
            cop.inputs.push(Input {
                name: "ArrayVarRef".to_string(),
                exec_pin: false,
                stored: None,
                source: None,
            });
            cop.inputs.push(Input {
                name: "Exec".to_string(),
                exec_pin: true,
                stored: None,
                source: None,
            });
            cop.inputs.push(Input {
                name: "SourceRef".to_string(),
                exec_pin: false,
                stored: None,
                source: None,
            });
        }
        if cop.outputs.len() == 0 {
            cop.outputs.push(Output {
                name: "ExecOut".to_string(),
                exec: true,
                readers: Vec::new(),
                calls: Vec::new(),
                default: None,
            });
        }
        let mut ain: u16 = 0;
        let mut ein: u16 = 0;
        let mut sin: u16 = 0;
        for (p, inp) in cop.inputs.iter().enumerate() {
            if inp.name == "ArrayVarRef".to_string() {
                ain = p as u16;
            }
            if inp.name == "SourceRef".to_string() {
                sin = p as u16;
            }
            if inp.exec_pin {
                ein = p as u16;
            }
        }
        graph.gates[did as usize].outputs[detOut].calls
            .push(Call { gate: wid, input: ein, remote: false });
        graph.gates.push(cop);
        out.insert(pin, (wid, ain, sin));
    }
    out
}

/// Point a pin's feed copy gate at container `gid` (the entry's own): both
/// its ports name that container, so the write re-writes what the pin now
/// holds and fires the chip's container watch.
fn set_feed_ref(graph: &mut Graph, feeds: &HashMap<GateId, (GateId, u16, u16)>,
                pin: GateId, gid: GateId) {
    match feeds.get(&pin) {
        None => {},
        Some(f) => {
            let (wid, ain, sin) = *f;
            let wi = wid as usize;
            if wi < graph.gates.len() {
                if (ain as usize) < graph.gates[wi].inputs.len() {
                    graph.gates[wi].inputs[ain as usize].stored = Some(WireVal::Ref(gid));
                }
                if (sin as usize) < graph.gates[wi].inputs.len() {
                    graph.gates[wi].inputs[sin as usize].stored = Some(WireVal::Ref(gid));
                }
            }
        },
    }
}

/// The copy gates' initial containers: whatever the pin's reroute already
/// names, which is the container `new` fed (entry 0).
fn seed_feed_refs(graph: &mut Graph, feeds: &HashMap<GateId, (GateId, u16, u16)>,
                  pins: &Vec<GateId>) {
    for pin0 in pins.iter() {
        let pin = *pin0;
        if feeds.get(&pin).is_none() {
            continue;
        }
        let at = reroute_at(graph, pin);
        let cur = graph.gates[pin as usize].inputs[at].stored.clone();
        match cur {
            None => {},
            Some(v) => match v {
                WireVal::Ref(gid) => { set_feed_ref(graph, feeds, pin, gid); },
                _ => {},
            },
        }
    }
}

/// True when a ports object carries an array spec.
fn ports_has_array(ports: &Value) -> bool {
    match ports.as_object() {
        Some(obj) => obj.values().any(|v| v.get("arr").is_some() && json_to_wire(v).is_none()),
        None => false,
    }
}

/// `ports` without its array specs: the half a live set can apply in place.
fn strip_arrays(ports: &Value) -> Value {
    let mut out = serde_json::Map::new();
    if let Some(obj) = ports.as_object() {
        for (k, v) in obj {
            if v.get("arr").is_some() && json_to_wire(v).is_none() { continue; }
            out.insert(k.clone(), v.clone());
        }
    }
    Value::Object(out)
}

/// Append the clones a later timeline entry will point its array pins at.
/// They must exist before `Machine::new`: the engine sizes an ArrayVar's
/// storage when it builds the machine, so a gate appended afterwards has no
/// slot, and an access to it panics (arrays.rs index out of bounds).
fn preclone_arrays(graph: &mut Graph, ports: &Value, pins: &Vec<GateId>)
    -> Result<Vec<(GateId, usize, GateId)>, String>
{
    let mut out: Vec<(GateId, usize, GateId)> = Vec::new();
    let obj = match ports.as_object() { Some(o) => o, None => return Ok(out) };
    for idx in 0..pins.len() {
        let key = format!("{}", idx);
        let val = match obj.get(&key) { Some(v) => v, None => continue };
        if json_to_wire(val).is_some() || val.get("arr").is_none() { continue; }
        let pin = pins[idx];
        let at = reroute_at(graph, pin);
        let gid = clone_array(graph, val)?;
        out.push((pin, at, gid));
    }
    Ok(out)
}

/// Rebuild the machine with the timeline's array values baked in, then replay
/// the recorded input changes. The official engine sizes an array pin's
/// storage when it builds the machine and exposes no host write into it, so
/// this is how a host changes an array mid-run; it is deterministic because
/// the run's seed and dt are fixed. Scalar changes never take this path.
fn replay(st: &mut St) -> Result<(), String> {
    let loaded = match &st.loaded {
        Some(l) => l,
        None => return Err("no program loaded".into()),
    };
    let newcmd = match &st.newcmd {
        Some(c) => c.clone(),
        None => return Err("no program loaded".into()),
    };
    let old = st.run.take();
    let mut graph = loaded.graph.clone();
    let (ins, _) = pin_gates(&loaded.graph);
    let base = loaded.graph.gates.len();
    // Entry 0 is what `new` built the machine with.
    if let Some((_, p0)) = st.timeline.first() {
        let bad = feed_ports(&mut graph, &serde_json::json!({"ports": p0}), &ins);
        if !bad.is_empty() {
            st.run = old;
            return Err(bad.join("; "));
        }
    }
    // The probe scan runs BEFORE the array clones are appended: a name pairs
    // with the compile's own containers, and a clone is not one of them.
    st.probeMap = HashMap::new();
    match ir_names(&newcmd) {
        Err(e) => { st.run = old; return Err(e); },
        Ok(nm) => match add_probes(&mut graph, &mut st.probeMap, arr_want(&newcmd),
                                   cmd_bool(&newcmd, "allvars"), nm, base) {
            Err(e) => { st.run = old; return Err(e); },
            Ok(_r) => {},
        },
    }
    // A chip whose only reaction to an array port is `ContainerChange` needs
    // the engine-visible write too, appended before the entry clones (pin ids
    // never move under appends).
    st.feedWrites = wire_container_feeds(&mut graph, &ins, base);
    seed_feed_refs(&mut graph, &st.feedWrites, &ins);
    // Every clone a later entry will point at, all before Machine::new.
    let mut planned: Vec<Vec<(GateId, usize, GateId)>> = vec![Vec::new(); st.timeline.len()];
    for i in 1..st.timeline.len() {
        match preclone_arrays(&mut graph, &st.timeline[i].1, &ins) {
            Ok(v) => { planned[i] = v; },
            Err(e) => { st.run = old; return Err(e); },
        }
    }
    let (rin, rout) = pin_gates(&graph);
    let mut busy_gate: Option<GateId> = None;
    match newcmd.get("busy").and_then(|v| v.as_u64()) {
        Some(b) => { if (b as usize) < rout.len() { busy_gate = Some(rout[b as usize]); } },
        None => {},
    }
    let mut sim = Sim {
        machine: Machine::new(graph, Box::new(ScriptWorld::default()), run_opts(&newcmd)),
    };
    // Replay, recomputing the same latches `run` keeps.
    let chat_seen = st.chatSeen;
    let mut log_first: Option<u64> = st.logFirst;
    let mut busy_first_false: Option<u64> = None;
    let mut busy_seen_true = false;
    let mut busy_last: Option<bool> = None;
    for i in 1..st.timeline.len() {
        let (tick, ports) = st.timeline[i].clone();
        while sim.machine.tick() < tick {
            let next = sim.machine.tick() + 1;
            if let Err(e) = sim.machine.run_until(next) {
                st.run = old;
                return Err(format!("{e}"));
            }
            let t = sim.machine.tick();
            if sim.chat().len() > chat_seen && log_first.is_none() {
                log_first = Some(t);
            }
            if let Some(g) = busy_gate {
                match sim.machine.evaluate_alone(g) {
                    Err(_) => { busy_last = None; },
                    Ok(v) => {
                        let b = truthy(v);
                        busy_last = Some(b);
                        if b {
                            busy_seen_true = true;
                        } else if busy_seen_true && busy_first_false.is_none() {
                            busy_first_false = Some(t);
                        }
                    },
                }
            }
        }
        let scalars = strip_arrays(&ports);
        let bad = feed_ports(&mut sim.machine.graph,
                             &serde_json::json!({"ports": scalars}), &ins);
        if !bad.is_empty() {
            st.run = old;
            return Err(bad.join("; "));
        }
        for (pin, at, gid) in &planned[i] {
            apply_array_ref(&mut sim.machine.graph, *pin, *at, *gid);
            // The host's write of the new container: the copy gate names the
            // entry's own holder, so the engine records a container change and
            // the chip's `ContainerChange` fires in the next tick.
            set_feed_ref(&mut sim.machine.graph, &st.feedWrites, *pin, *gid);
        }
        // Written pins land now, so a capture before the next tick sees them.
        for idx in 0..ins.len() {
            let key = format!("{}", idx);
            if scalars.get(&key).is_some() || planned[i].iter().any(|(p, _, _)| *p == ins[idx]) {
                let _ = sim.machine.evaluate_alone(ins[idx]);
            }
        }
    }
    st.run = Some(sim);
    st.pinsIn = rin;
    st.pinsOut = rout;
    st.busyGate = busy_gate;
    st.logFirst = log_first;
    st.busyFirstFalse = busy_first_false;
    st.busySeenTrue = busy_seen_true;
    st.busyLast = busy_last;
    Ok(())
}

/// The loaded graph, counted by gate class, with the classes the official
/// simulator cannot run (Unsupported ops) and the Expr_ classes its semantics
/// do not certify called out.
fn do_census(st: &St) -> Value {
    match &st.loaded {
        None => serde_json::json!({"err": "nothing loaded"}),
        Some(loaded) => {
            let mut hist = HashMap::new();
            let mut unsupported = HashMap::new();
            let mut placeholders = HashMap::new();
            for g in loaded.graph.gates.iter() {
                match hist.get(&g.class) {
                    Some(n) => { hist.insert(g.class.clone(), n + 1); },
                    None => { hist.insert(g.class.clone(), 1); },
                }
                if g.class.contains("Unsupported") {
                    match placeholders.get(&g.class) {
                        Some(n) => { placeholders.insert(g.class.clone(), n + 1); },
                        None => { placeholders.insert(g.class.clone(), 1); },
                    }
                }
                match g.op {
                    Op::Unsupported => {
                        match unsupported.get(&g.class) {
                            Some(n) => { unsupported.insert(g.class.clone(), n + 1); },
                            None => { unsupported.insert(g.class.clone(), 1); },
                        }
                    },
                    _ => {},
                }
            }
            let mut uncertified: Vec<String> = Vec::new();
            for (cls, _n) in hist.iter() {
                if cls.starts_with("Expr_") {
                    if !sim_certifies(cls) {
                        uncertified.push(cls.to_string());
                    }
                }
            }
            let mut wires = 0;
            for g in loaded.graph.gates.iter() {
                for o in g.outputs.iter() {
                    wires += o.readers.len() + o.calls.len();
                }
            }
            serde_json::json!({
                "ok": true,
                "gates": loaded.graph.gates.len(),
                "wires": wires,
                "classes": hist,
                "placeholders": placeholders,
                "worldOrUnclassified": unsupported,
                "uncertifiedExpr": uncertified,
            })
        },
    }
}

/// Append read-only probe reroutes for the chip's named globals: each label
/// the `.brz` puts on a boundary pin (the pin's `PortLabel`) names a container
/// gate; a fresh `Internal_Rerouter` wired to that container's Value port is a
/// pure gate, so `evaluate_alone` reads the container's LIVE state through it
/// (`read_output`'s Var case). Nothing consumes these gates, so no run's
/// behavior changes; they only make the state readable to the harness.
/// The arrays a `new` asks the CONTENTS of: `"arrays": {"outNumArrV": 256}`
/// probes indices 0..255, and `"arrays": {"outNumArrV": [[0,256],[16320,64]]}`
/// probes those [start, count] ranges. Names are the chip's own array-var
/// labels. A harness reads a port's contents as far as it paid for.
fn arr_want(cmd: &Value) -> Vec<(String, usize, usize)> {
    let mut out: Vec<(String, usize, usize)> = Vec::new();
    match cmd.get("arrays") {
        None => {},
        Some(v) => match v.as_object() {
            None => {},
            Some(obj) => {
                for (k, iv) in obj.iter() {
                    let name = k.to_string();
                    match iv.as_u64() {
                        Some(n) => { out.push((name.clone(), 0, n as usize)); },
                        None => {},
                    }
                    match iv.as_array() {
                        None => {},
                        Some(items) => {
                            for rg in items.iter() {
                                match rg.as_array() {
                                    None => {},
                                    Some(pair) => {
                                        if pair.len() == 2 {
                                            let a = match pair[0].as_u64() {
                                                Some(x) => x as usize,
                                                None => 0,
                                            };
                                            let b = match pair[1].as_u64() {
                                                Some(x) => x as usize,
                                                None => 0,
                                            };
                                            out.push((name.clone(), a, b));
                                        }
                                    },
                                }
                            }
                        },
                    }
                }
            },
        },
    };
    out
}

fn add_probes(graph: &mut Graph, map: &mut HashMap<String, GateId>,
              want: Vec<(String, usize, usize)>, allvars: bool,
              names: Vec<(String, bool)>, base: usize) -> Result<String, String> {    let mut found: Vec<(String, GateId)> = Vec::new();
    let mut arrInfo: Vec<(String, GateId, GateId)> = Vec::new();
    for (_i, g) in graph.gates.iter().enumerate() {
        // Both pin directions: an OUT pin whose source is a container (this
        // chip's `out outNumArr: float[] = outNumArrV`) names that container
        // too, and its var gate carries no label property of its own, so the
        // port label is the only handle to it.
        if !g.class.contains("Microchip") {
            continue;
        }
        let mut label = "".to_string();
        match &g.data {
            None => {},
            Some(d) => {
                for p in d.properties.values() {
                    match p {
                        BrdbValue::String(s) => { label = s.clone(); },
                        _ => {},
                    }
                }
            },
        }
        if label == "" {
            continue;
        }
        for inp in g.inputs.iter() {
            match &inp.source {
                None => {},
                Some(s) => {
                    let src = &graph.gates[s.gate as usize];
                    match src.op {
                        Op::Var | Op::ArrayVar | Op::MapVar => {
                            found.push((label.clone(), s.gate));
                        },
                        _ => {},
                    }
                },
            }
        }
    }
    // Any gate the artifact labels, not just the boundary pins: the compiler
    // carries `label = "progOkV"` on the gate itself, and a benchmark reads
    // an internal global the same way a case reads a boundary one.
    for i in 0..base {
        let kind = graph.gates[i as usize].op;
        match kind {
            Op::Var | Op::ArrayVar | Op::MapVar => {},
            _ => { continue; },
        }
        match &graph.gates[i as usize].data {
            None => {},
            Some(d) => {
                for (key, v) in d.properties.iter() {
                    match v {
                        BrdbValue::String(s) => {
                            if s.len() > 0 {
                                found.push((s.clone(), i as GateId));
                            }
                        },
                        _ => {},
                    }
                }
            },
        }
    }
    // The IR's names, paired with the chip's containers by kind group: the
    // emit lays every array before every scalar, so the IR's program order
    // splits the same way. A mismatch in either group means the pairing is
    // not this compile's, and reading a name would answer another global --
    // so `new` refuses instead.
    if names.len() > 0 {
        let mut garr: Vec<GateId> = Vec::new();
        let mut gvar: Vec<GateId> = Vec::new();
        for i in 0..base {
            let cls = graph.gates[i as usize].class.clone();
            if cls.ends_with("ArrayVar") {
                garr.push(i as GateId);
            } else if cls.ends_with("Var") || cls.ends_with("MapVar") {
                gvar.push(i as GateId);
            }
        }
        let mut ai = 0usize;
        let mut vi = 0usize;
        for ni in 0..names.len() {
            if names[ni].1 {
                if ai < garr.len() {
                    found.push((names[ni].0.clone(), garr[ai]));
                    ai = ai + 1;
                }
            } else {
                if vi < gvar.len() {
                    found.push((names[ni].0.clone(), gvar[vi]));
                    vi = vi + 1;
                }
            }
        }
        if ai != garr.len() || vi != gvar.len() {
            return Err(format!("IR names do not pair with the chip's containers: \
                                {} of {} arrays and {} of {} scalars matched",
                               ai, garr.len(), vi, gvar.len()));
        }
    }
    // Every container, whether the artifact named it or not, keyed by its
    // position among the chip's containers (`#7` is the eighth): the compiler
    // carries a label property only on the access pins of globals ANOTHER
    // grid reads by remote wire, so a global the chip touches inside its own
    // grid (`polyOn`, `covLo`, the per-lane spans) has no name to look up.
    // The chip's own source order is the missing half of that map, so a
    // harness that reads a chip's internals asks `varnames` for these keys,
    // and the predicate here matches the one in `varnames` exactly.
    // Opt-in: thousands of extra probes and their per-tick fires are not
    // free, and only a probe driver pays for them.
    if allvars {
        let mut ci = 0usize;
        for (i, g) in graph.gates.iter().enumerate() {
            if (i as usize) >= base {
                continue;
            }
            if !(g.class.ends_with("Var") || g.class.ends_with("ArrayVar")
                 || g.class.ends_with("MapVar")) {
                continue;
            }
            let mut named = false;
            for fi in 0..found.len() {
                if found[fi].1 == (i as GateId) {
                    named = true;
                    break;
                }
            }
            if !named {
                found.push((format!("#{}", ci), i as GateId));
            }
            ci = ci + 1;
        }
    }
    let mut seen: Vec<String> = Vec::new();
    for fi in 0..found.len() {
        let label = found[fi].0.clone();
        let vg = found[fi].1;
        if seen.contains(&label) {
            continue;
        }
        seen.push(label.clone());
        let varg = &graph.gates[vg as usize];
        let mut vout: u16 = 0;
        for (o, outp) in varg.outputs.iter().enumerate() {
            if outp.name != "VarRef" {
                vout = o as u16;
                break;
            }
        }
        let addr = BrickAddr {
            grid: varg.addr.grid,
            chunk: varg.addr.chunk,
            brick: 900000u32 + (vg as u32 % 100000u32),
        };
        let rid = graph.gates.len() as GateId;
        let mut probe = Gate::new("Internal_Rerouter", addr);
        if probe.inputs.len() == 0 {
            probe.inputs.push(Input {
                name: "RER_Input".to_string(),
                exec_pin: false,
                stored: None,
                source: None,
            });
        }
        if probe.outputs.len() == 0 {
            probe.outputs.push(Output {
                name: "RER_Output".to_string(),
                exec: false,
                readers: Vec::new(),
                calls: Vec::new(),
                default: None,
            });
        }
        probe.inputs[0].source = Some(Src { gate: vg, out: vout, remote: false });
        graph.gates.push(probe);
        let vi = vg as usize;
        if (vout as usize) < graph.gates[vi].outputs.len() {
            graph.gates[vi].outputs[vout as usize].readers.push((rid, 0u16));
        }
        map.insert(label, rid);
    }

    // Arrays: their contents live in the machine's container state, which only
    // an exec gate can read; a `GetLength` gate hooked onto a per-tick exec
    // edge (this chip's tick loop is a `BufferTicks` output that lands every
    // tick) fires with the run, and its value output stays readable through a
    // reroute afterwards. The gate writes nothing, so the run is unchanged.
    let mut hooks: Vec<(GateId, u16)> = Vec::new();
    for (i, g) in graph.gates.iter().enumerate() {
        // The chip's own per-tick edges. `BufferTicks` lands once for a
        // buffered signal; the `Clock` (the chip's VM driver) fires its `Pulse`
        // every interval, so an element gate chained from it is re-fired
        // every tick and reads the container at the window's end. A chip
        // without a clock — the connector reacts to its input array — fires
        // its `ContainerChangeDetector` once per content change, and a gate
        // chained from that output re-reads exactly when contents move.
        // The mod body is called from the detector FIRST, so the chained
        // gate runs after the writes it triggers: probes see the new state.
        if !(g.class.contains("BufferTicks") || g.class.contains("Clock")
             || g.class.contains("ContainerChangeDetector")) {
            continue;
        }
        for (o, outp) in g.outputs.iter().enumerate() {
            if outp.exec && (outp.name == "Output".to_string()
                             || outp.name == "Pulse".to_string()
                             || outp.name == "OnChanged".to_string())
                && outp.calls.len() > 0 {
                hooks.push((i as GateId, o as u16));
            }
        }
    }
    let hook = if hooks.len() > 0 { hooks[0].0 } else { 0 };
    if hook != 0 {
        let mut seen2: Vec<String> = Vec::new();
        for fi in 0..found.len() {
            let label = found[fi].0.clone();
            let vg = found[fi].1;
            let vgrid = graph.gates[vg as usize].addr.grid;
            let vchunk = graph.gates[vg as usize].addr.chunk;
            if !graph.gates[vg as usize].class.contains("ArrayVar")
                || seen2.contains(&label) {
                continue;
            }
            seen2.push(label.clone());
            let gid = graph.gates.len() as GateId;
            arrInfo.push((label.clone(), vg, gid));
            let mut gl = Gate::new("BrickComponentType_Exec_ArrayVar_GetLength",
                BrickAddr {
                    grid: vgrid,
                    chunk: vchunk,
                    brick: 950000u32 + (vg as u32 % 100000u32),
                });
            if gl.inputs.len() == 0 {
                gl.inputs.push(Input {
                    name: "Exec".to_string(),
                    exec_pin: true,
                    stored: None,
                    source: None,
                });
                gl.inputs.push(Input {
                    name: "ArrayVarRef".to_string(),
                    exec_pin: false,
                    stored: None,
                    source: Some(Src {
                        gate: vg, out: 0u16, remote: false }),
                });
            }
            if gl.outputs.len() == 0 {
                gl.outputs.push(Output {
                    name: "ExecOut".to_string(),
                    exec: true,
                    readers: Vec::new(),
                    calls: Vec::new(),
                    default: None,
                });
                gl.outputs.push(Output {
                    name: "Length".to_string(),
                    exec: false,
                    readers: Vec::new(),
                    calls: Vec::new(),
                    default: None,
                });
            }
            let mut execIn: u16 = 0;
            let mut refIn: u16 = 0;
            for (p, inp) in gl.inputs.iter().enumerate() {
                if inp.exec_pin {
                    execIn = p as u16;
                }
                if inp.name.contains("ArrayVarRef") {
                    refIn = p as u16;
                }
            }
            match &gl.inputs[refIn as usize].source {
                None => {
                    gl.inputs[refIn as usize].source = Some(Src {
                        gate: vg, out: 0u16, remote: false });
                },
                Some(_) => {},
            }
            let mut lout: u16 = 0;
            for (p, outp) in gl.outputs.iter().enumerate() {
                if !outp.exec {
                    lout = p as u16;
                    break;
                }
            }
            gl.inputs[execIn as usize].source = Some(Src {
                gate: hooks[hooks.len() - 1].0, out: hooks[hooks.len() - 1].1,
                remote: false });
            graph.gates.push(gl);
            for hi in 0..hooks.len() {
                graph.gates[hooks[hi].0 as usize].outputs[hooks[hi].1 as usize].calls
                    .push(Call { gate: gid, input: execIn, remote: false });
            }
            let rid = graph.gates.len() as GateId;
            let mut pr2 = Gate::new("Internal_Rerouter",
                BrickAddr {
                    grid: vgrid,
                    chunk: vchunk,
                    brick: 960000u32 + (vg as u32 % 100000u32),
                });
            if pr2.inputs.len() == 0 {
                pr2.inputs.push(Input {
                    name: "RER_Input".to_string(),
                    exec_pin: false,
                    stored: None,
                    source: None,
                });
            }
            if pr2.outputs.len() == 0 {
                pr2.outputs.push(Output {
                    name: "RER_Output".to_string(),
                    exec: false,
                    readers: Vec::new(),
                    calls: Vec::new(),
                    default: None,
                });
            }
            pr2.inputs[0].source = Some(Src { gate: gid, out: lout, remote: false });
            graph.gates.push(pr2);
            map.insert(label, rid);
        }
    }
    // An array's ELEMENTS, for a harness that has to compare a container
    // port's CONTENTS: the engine keeps them in its own state and the only
    // reader is such a gate -- the same shape a host has in game when it reads
    // the port. One Exec_ArrayVar_Get per requested index, fired from the same
    // per-tick hook as the length gate and read back through a reroute labelled
    // `name[k]`, so `vread name[k]` answers the element. The gate writes nothing.
    for wi in 0..want.len() {
        let wname = want[wi].0.clone();
        let wstart = want[wi].1;
        let wcount = want[wi].2;
        for fi in 0..found.len() {
            let label = found[fi].0.clone();
            let vg = found[fi].1;
            if label != wname
                || graph.gates[vg as usize].op != Op::ArrayVar {
                continue;
            }
            let vgrid = graph.gates[vg as usize].addr.grid;
            let vchunk = graph.gates[vg as usize].addr.chunk;
            for k in 0..wcount {
                let idx = wstart + k;
                let gid = graph.gates.len() as GateId;
                let mut gg = Gate::new("BrickComponentType_Exec_ArrayVar_Get",
                    BrickAddr {
                        grid: vgrid,
                        chunk: vchunk,
                        brick: 970000u32 + ((vg as u32) % 100000u32)
                               + (idx as u32),
                    });
                // `Gate::new` fills a known class's ports from the catalog, so
                // the ports are found BY NAME among whatever it brought (pushing
                // fresh ones unconditionally appends duplicates whose empty
                // source the machine then reads as "ArrayVarRef holds nothing").
                let mut execIn = gg.inputs.len();
                let mut refIn = gg.inputs.len();
                let mut idxIn = gg.inputs.len();
                for (p, inp) in gg.inputs.iter().enumerate() {
                    if inp.exec_pin && (execIn as usize) == gg.inputs.len() {
                        execIn = p;
                    }
                    if inp.name.contains("ArrayVarRef") && (refIn as usize) == gg.inputs.len() {
                        refIn = p;
                    }
                    if inp.name.contains("Index") && (idxIn as usize) == gg.inputs.len() {
                        idxIn = p;
                    }
                }
                if (execIn as usize) >= gg.inputs.len() {
                    gg.inputs.push(Input {
                        name: "Exec".to_string(), exec_pin: true, stored: None,
                        source: None,
                    });
                    execIn = gg.inputs.len() - 1;
                }
                if (refIn as usize) >= gg.inputs.len() {
                    gg.inputs.push(Input {
                        name: "ArrayVarRef".to_string(), exec_pin: false,
                        stored: None, source: None,
                    });
                    refIn = gg.inputs.len() - 1;
                }
                if (idxIn as usize) >= gg.inputs.len() {
                    gg.inputs.push(Input {
                        name: "Index".to_string(), exec_pin: false,
                        stored: None, source: None,
                    });
                    idxIn = gg.inputs.len() - 1;
                }
                gg.inputs[refIn as usize].source = Some(Src {
                    gate: vg, out: 0u16, remote: false });
                gg.inputs[idxIn as usize].stored = Some(WireVal::Int(idx as i64));
                let mut vout = 0u16;
                let mut foundV = false;
                for (p, outp) in gg.outputs.iter().enumerate() {
                    if !outp.exec && outp.name.contains("Value") {
                        vout = p as u16;
                        foundV = true;
                        break;
                    }
                }
                if !foundV {
                    for (p, outp) in gg.outputs.iter().enumerate() {
                        if !outp.exec {
                            vout = p as u16;
                            foundV = true;
                            break;
                        }
                    }
                }
                // Fired from the chip's own per-tick edge (the last hook: wired
                // as the Exec input's source AND called on that output, the
                // same pair the length gate above uses -- one alone leaves the
                // gate unfired).
                if hooks.len() > 0 {
                    let hk = hooks.len() - 1;
                    gg.inputs[execIn].source = Some(Src {
                        gate: hooks[hk].0, out: hooks[hk].1, remote: false });
                    graph.gates[hooks[hk].0 as usize].outputs[hooks[hk].1 as usize]
                        .calls.push(Call { gate: gid, input: execIn as u16,
                                           remote: false });
                }
                graph.gates.push(gg);
                let rid = graph.gates.len() as GateId;
                let mut pr = Gate::new("Internal_Rerouter",
                    BrickAddr {
                        grid: vgrid,
                        chunk: vchunk,
                        brick: 980000u32 + ((vg as u32) % 100000u32)
                               + (idx as u32),
                    });
                pr.inputs.push(Input {
                    name: "RER_Input".to_string(), exec_pin: false,
                    stored: None,
                    source: Some(Src { gate: gid, out: vout, remote: false }),
                });
                pr.outputs.push(Output {
                    name: "RER_Output".to_string(), exec: false,
                    readers: Vec::new(), calls: Vec::new(), default: None,
                });
                graph.gates.push(pr);
                map.insert(format!("{}[{}]", wname, idx), rid);
            }
        }
    }
    let mut idsS = "".to_string();
    for (label, rid) in map.iter() {
        if idsS.len() < 60 {
            idsS = format!("{} {}:{}", idsS, label, rid);
        }
    }
    let mut arrS = "".to_string();
    for ai in 0..arrInfo.len() {
        arrS = format!("{} {}->{}|{}", arrS, arrInfo[ai].0, arrInfo[ai].1,
                       arrInfo[ai].2);
    }
    return Ok(format!("probes={} hook={} {} arr={}", map.len(), hook, idsS, arrS));
}

fn do_new(st: &mut St, cmd: &Value) -> Value {
    match &st.loaded {
        None => serde_json::json!({"err": "no program loaded"}),
        Some(loaded) => {
            let (ins, _) = pin_gates(&loaded.graph);
            let base = loaded.graph.gates.len();
            let mut graph = loaded.graph.clone();
            let bad = feed_ports(&mut graph, cmd, &ins);
            if bad.len() > 0 {
                let msg = bad.join("; ");
                return serde_json::json!({"err": format!("{msg}")})
            }
            st.probeMap = HashMap::new();
            let mut probeInfo = "".to_string();
            match cmd.get("probe") {
                Some(v) => match v.as_bool() {
                    Some(true) => {
                        match ir_names(cmd) {
                            Err(e) => { return serde_json::json!({"err": e}) },
                            Ok(nm) => match add_probes(&mut graph, &mut st.probeMap,
                                                      arr_want(cmd),
                                                      cmd_bool(cmd, "allvars"), nm,
                                                      base) {
                                Err(e) => { return serde_json::json!({"err": e}) },
                                Ok(pi) => { probeInfo = pi; },
                            },
                        };
                    },
                    _ => {},
                },
                None => {},
            };
            // Pins of the RUN's graph, after the probes were added: probe
            // reroutes append gates and never move a pin, so these ids are the
            // ones every later command needs.  Computed before the graph moves
            // into the machine.
            let (rin, rout) = pin_gates(&graph);
            st.busyGate = None;
            match cmd.get("busy") {
                Some(v) => match v.as_u64() {
                    Some(b) => {
                        if (b as usize) < rout.len() {
                            st.busyGate = Some(rout[b as usize]);
                        }
                    },
                    None => {},
                },
                None => {},
            };
            // A chip whose only reaction to an array port is `ContainerChange`
            // needs the engine-visible write too (see `wire_container_feeds`);
            // the pin's reroute already names the container `new` fed, so the
            // copy gate starts there.
            st.feedWrites = wire_container_feeds(&mut graph, &rin, base);
            seed_feed_refs(&mut graph, &st.feedWrites, &rin);
            st.run = Some(Sim { machine: Machine::new(graph, Box::new(ScriptWorld::default()), run_opts(cmd)) });
            st.pinsIn = rin;
            st.pinsOut = rout;
            st.chatSeen = 0;
            st.logFirst = None;
            st.busyFirstFalse = None;
            st.busySeenTrue = false;
            st.busyLast = None;
            st.newcmd = Some(cmd.clone());
            st.timeline = vec![(0, match cmd.get("ports") {
                Some(p) => p.clone(),
                None => serde_json::json!({}),
            })];
            serde_json::json!({"ok": true, "probe": probeInfo})
        },
    }
}

fn do_set(st: &mut St, cmd: &Value) -> Value {
    if st.run.is_none() {
        return serde_json::json!({"err": "no run started"});
    }
    let ports = match cmd.get("ports") {
        Some(p) => p.clone(),
        None => serde_json::json!({}),
    };
    let tick = st.run.as_ref().map(|s| s.machine.tick()).unwrap_or(0);
    st.timeline.push((tick, ports.clone()));
    if ports_has_array(&ports) {
        // An array pin cannot be written into a built machine (the engine sized
        // its storage at construction and exposes no host write), so rebuild
        // and replay the input timeline instead. Scalars stay live below.
        return match replay(st) {
            Err(e) => serde_json::json!({"err": format!("{e}")}),
            Ok(_) => serde_json::json!({"ok": true}),
        };
    }
    match &mut st.run {
        None => serde_json::json!({"err": "no run started"}),
        Some(s) => {
            let ins = &st.pinsIn;
            let bad = feed_ports(&mut s.machine.graph, cmd, ins);
            if bad.len() > 0 {
                let msg = bad.join("; ");
                return serde_json::json!({"err": format!("{msg}")})
            }
            // Recompute each written pin so the new value lands this tick.
            for idx in 0..ins.len() {
                let key = format!("{}", idx);
                match cmd.get("ports") {
                    Some(obj_val) => match obj_val.as_object() {
                        Some(obj) => {
                            match obj.get(&key) {
                                Some(_) => {
                                    match s.machine.evaluate_alone(ins[idx]) {
                                        Err(e) => return serde_json::json!({"err": format!("set: {e}")}),
                                        Ok(_) => {},
                                    }
                                },
                                None => {},
                            }
                        },
                        None => {},
                    },
                    None => {},
                };
            }
            serde_json::json!({"ok": true})
        },
    }
}

/// Truthy for the busy port: booleans as they are, else non-zero/non-empty.
fn truthy(v: Option<WireVal>) -> bool {
    match v {
        None => false,
        Some(x) => match x {
            WireVal::Bool(b) => b,
            WireVal::Int(n) => n != 0,
            WireVal::Float(f) => f != 0.0,
            WireVal::Str(s) => !s.is_empty(),
            _ => true,
        },
    }
}

fn do_run(st: &mut St, cmd: &Value) -> Value {
    // Copy the latches out so sampling can run while the sim is borrowed.
    let busy_gate = st.busyGate;
    let chat_seen = st.chatSeen;
    let mut log_first = st.logFirst;
    let mut busy_first_false = st.busyFirstFalse;
    let mut busy_seen_true = st.busySeenTrue;
    let mut busy_last = st.busyLast;
    match &mut st.run {
        None => serde_json::json!({"err": "no run started"}),
        Some(s) => {
            let ticks = match cmd.get("ticks") {
                Some(v) => match v.as_u64() { Some(n) => n, None => 0 },
                None => 0,
            };
            let target = s.machine.tick() + ticks;
            while s.machine.tick() < target {
                let next = s.machine.tick() + 1;
                match s.run_until(next) {
                    Err(e) => {
                        st.logFirst = log_first;
                        let at = s.machine.tick();
                        return serde_json::json!({"err": format!("tick {at}: {e}")})
                    },
                    Ok(_) => {},
                }
                let tick = s.machine.tick();
                if s.chat().len() > chat_seen {
                    match log_first {
                        Some(_) => {},
                        None => { log_first = Some(tick); },
                    }
                }
                match busy_gate {
                    Some(gate) => {
                        match s.machine.evaluate_alone(gate) {
                        Err(_) => { busy_last = None; },
                        Ok(v) => {
                            let b = truthy(v);
                            busy_last = Some(b);
                            if b {
                                busy_seen_true = true;
                            } else {
                                if busy_seen_true {
                                    if let _ = busy_first_false {
                                    } else {
                                        busy_first_false = Some(tick);
                                    }
                                }
                            }
                        },
                        }
                    },
                    None => {},
                }
            }
            st.logFirst = log_first;
            st.busyFirstFalse = busy_first_false;
            st.busySeenTrue = busy_seen_true;
            st.busyLast = busy_last;
            serde_json::json!({
                "ok": true,
                "tick": s.machine.tick(),
                "logFirst": log_first,
                "busyFirstFalse": busy_first_false,
                "busyFinal": busy_last,
                "chatTotal": s.chat().len(),
            })
        },
    }
}

fn do_capture(st: &mut St, cmd: &Value) -> Value {
    match &mut st.run {
        None => serde_json::json!({"err": "no run started"}),
        Some(s) => {
            let ins = &st.pinsIn;
            let outs = &st.pinsOut;
            let mut invals: Vec<Value> = Vec::new();
            for gi in 0..ins.len() {
                match s.machine.evaluate_alone(ins[gi]) {
                    Err(e) => invals.push(serde_json::json!({"err": format!("pin: {e}")})),
                    Ok(v) => invals.push(wire_to_json(v)),
                }
            }
            let mut vals: Vec<Value> = Vec::new();
            for oi in 0..outs.len() {
                match s.machine.evaluate_alone(outs[oi]) {
                    Err(e) => vals.push(serde_json::json!({"err": format!("port: {e}")})),
                    Ok(v) => vals.push(wire_to_json(v)),
                }
            }
            let mut lines: Vec<Value> = Vec::new();
            for line in s.chat().iter().skip(st.chatSeen) {
                lines.push(serde_json::json!({"tick": line.tick, "text": line.text}));
            }
            st.chatSeen = s.chat().len();
            serde_json::json!({
                "ok": true,
                "inPorts": invals,
                "ports": vals,
                "chat": lines,
                "tick": s.machine.tick(),
            })
        },
    }
}

fn main() {
    let mut st = St {
        loaded: None,
        run: None,
        probeMap: HashMap::new(),
        busyGate: None,
        chatSeen: 0,
        logFirst: None,
        busyFirstFalse: None,
        busySeenTrue: false,
        busyLast: None,
        pinsIn: Vec::new(),
        pinsOut: Vec::new(),
        newcmd: None,
        timeline: Vec::new(),
        feedWrites: HashMap::new(),
    };
    let stdin = std::io::stdin().lock();
    for line in stdin.lines() {
        let line = match line {
            Err(_) => break,
            Ok(l) => l,
        };
        if line.trim().is_empty() {
            continue;
        }
        let reply: Value;
        let quit: bool;
        match from_str(&line) {
            Err(e) => {
                reply = serde_json::json!({"err": format!("bad json: {e}")});
                quit = false;
            },
            Ok(cmd) => {
                let (r, q) = handle(&mut st, &cmd);
                reply = r;
                quit = q;
            },
        };
        let text = match to_string(&reply) {
            Err(e) => format!("null /* {e} */"),
            Ok(t) => t,
        };
        println!("{}", text);
        if quit {
            break;
        }
    }
}
