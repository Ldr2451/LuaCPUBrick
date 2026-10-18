//! mkwall -- lay the screen's pixel wall on a compiled chip, without patching
//! the compiler.
//!
//! The BASE compiler emits the chip and nothing else.  What the screen
//! artifact needs around it is a grid of microbricks -- one per pixel, each
//! carrying a `Component_BrickPropertyChanger` -- with every brick wired to
//! the chip colour output labelled `{prefix}{i}`.  A plain brick exposes no
//! wire ports (brick colour is save data, not a port), which is why the
//! changer is there; an array output could not do this job, because a wire
//! addresses one (brick, component, port) triple and an array port is a
//! single port.
//!
//! So this tool does what the old `--wall` compiler patch did, one step later:
//! it asks the compiler for the `World` (`wirescript::compile_to_world`), finds
//! each labelled output brick in that world, appends the wall bricks and the
//! 4096 wires, recomputes the prefab bounds, and writes the save.  The
//! compiler stays exactly as shipped.
//!
//!   mkwall <source.ws> <out.brz> <prefix>:<cols>x<rows> [x,y,z]
//!
//! Placement is chip-relative and unchanged from the patch's measured
//! geometry: the wall is centred on the chip in X/Z, standing in the X/Z plane
//! at a fixed Y above the shell, microbricks at 2-unit pitch, row 0 at the top
//! (+Z is up).
//!
//! Diagnostics: a compile error is reported and exits 2 with nothing written,
//! so a build that ignores the exit code cannot ship yesterday's chip.

use std::collections::{HashMap, HashSet};
use std::process::ExitCode;

use brdb::{
    AsBrdbValue, BString, Brick, BrickType, Collision, Color, Position, SavedBrickColor,
    WireConnection, WirePort, World, assets::LiteralComponent,
};
use wirescript::{CompileInput, FoldMode, Severity, assemble_options, compile_to_world};

const CHANGER_CLASS: &str = "Component_BrickPropertyChanger";
const OUTPUT_CLASS: &str = "BrickComponentType_Internal_MicrochipOutput";
/// 1x1x1 procedural microbricks at 2-unit pitch, mirroring a hand-built
/// reference wall (measured lattice, X/Z plane).
const WALL_PITCH: i32 = 2;
/// Fixed-Y offset of the wall plane from the chip shell.  Clears the shell and
/// the `@side` rerouter pins (edge offset 6 + brick extents) with margin.
const WALL_Y_OFFSET: i32 = 16;

/// Which chip outputs form the screen, and how big the wall is.
struct WallSpec {
    prefix: String,
    cols: u32,
    rows: u32,
}

fn parse_wall_spec(s: &str) -> Result<WallSpec, String> {
    let (prefix, dims) = s
        .split_once(':')
        .ok_or_else(|| format!("wall spec must be <prefix>:<cols>x<rows>, got `{s}`"))?;
    let (cols, rows) = dims
        .split_once('x')
        .ok_or_else(|| format!("wall spec must be <prefix>:<cols>x<rows>, got `{s}`"))?;
    if prefix.is_empty() {
        return Err(format!("wall spec needs a non-empty output prefix, got `{s}`"));
    }
    let cols: u32 = cols
        .parse()
        .map_err(|_| format!("wall cols is not a number in `{s}`"))?;
    let rows: u32 = rows
        .parse()
        .map_err(|_| format!("wall rows is not a number in `{s}`"))?;
    if cols == 0 || rows == 0 || cols > 256 || rows > 256 {
        return Err(format!("wall dims out of range 1..=256 in `{s}`"));
    }
    Ok(WallSpec {
        prefix: prefix.to_string(),
        cols,
        rows,
    })
}

/// Look-only brick: no player/weapon/tool/physics collision.  Mirrors
/// `emit::no_collision` in the compiler (emit.rs), which is not exported.
fn no_collision() -> Collision {
    Collision {
        player: false,
        player1: Some(false),
        player2: Some(false),
        player3: Some(false),
        weapon: false,
        interact: false,
        tool: false,
        physics: false,
    }
}

/// `{prefix}{i}` -> the id of the chip brick carrying that labelled output
/// component, found by scanning every grid of the built world.
///
/// The label is read through brdb's struct-prop accessor, which wants the
/// world's own schema and the interned names of the struct and the property.
/// That is the same path the writer takes, so what is read here is exactly
/// what was written.
fn output_bricks(world: &World, prefix: &str, n: usize) -> Result<HashMap<usize, usize>, String> {
    let schema = &world.component_schema;
    // The struct name is the component class name in brdb's schema table; look
    // it up by the class the emit wrote, and fall back to the world asking
    // which struct a component type maps to (the catalog's own mapping).
    // The struct is looked up by component CLASS name; `component_schema`'s
    // intern holds struct names, so when the class is not itself a struct
    // name, ask the world which struct that component type stores its data
    // in (the catalog mapping, indexed by component-type order).
    let struct_name = match schema.intern.get(OUTPUT_CLASS) {
        Some(n) => n,
        None => {
            let idx: usize = world
                .global_data
                .component_type_names
                .iter()
                .position(|t| t.as_str() == OUTPUT_CLASS)
                .ok_or_else(|| {
                    format!(
                        "the world's component catalog has {} types and none is \
                         {OUTPUT_CLASS}",
                        world.global_data.component_type_names.len()
                    )
                })?;
            let mapped = world
                .global_data
                .component_data_struct_names
                .get(idx)
                .ok_or_else(|| format!("no data struct for {OUTPUT_CLASS}"))?;
            schema.intern.get(mapped.as_str()).ok_or_else(|| {
                format!("struct `{mapped}` for {OUTPUT_CLASS} is not in the schema")
            })?
        }
    };
    let Some(prop_name) = schema.intern.get("PortLabel") else {
        return Err("no schema field PortLabel".to_string());
    };
    let mut found: HashMap<usize, usize> = HashMap::new();
    let mut scan = |bricks: &[Brick]| {
        for brick in bricks {
            let Some(id) = brick.id else { continue };
            for comp in &brick.components {
                let Some(tname) = comp.component_type_ref() else { continue };
                if tname != OUTPUT_CLASS {
                    continue;
                }
                let Ok(Some(value)) =
                    comp.as_brdb_struct_prop_opt(schema, struct_name, prop_name)
                else {
                    continue;
                };
                let Ok(text) = value.as_brdb_str() else { continue };
                let Some(rest) = text.strip_prefix(prefix) else { continue };
                let Ok(i) = rest.parse::<usize>() else { continue };
                if i < n {
                    found.entry(i).or_insert(id);
                }
            }
        }
    };
    scan(&world.bricks);
    for (_gid, bricks) in world.grids.iter() {
        scan(bricks);
    }
    if found.len() < n {
        let missing: Vec<usize> = (0..n).filter(|i| !found.contains_key(i)).collect();
        let show: Vec<String> = missing
            .iter()
            .take(8)
            .map(|i| format!("{}{}", prefix, i))
            .collect();
        return Err(format!(
            "wall: {}/{} pixel outputs not found in the compiled world (e.g. {})",
            n - found.len(),
            n,
            show.join(", ")
        ));
    }
    Ok(found)
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("mkwall: {e}");
            ExitCode::from(2)
        }
    }
}

fn run() -> Result<(), String> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 4 {
        return Err(format!(
            "usage: mkwall <source.ws> <out.brz> <prefix>:<cols>x<rows> [x,y,z]\n\
             got: {}",
            args.join(" ")
        ));
    }
    let source = &args[1];
    let out = &args[2];
    let spec = parse_wall_spec(&args[3])?;
    let chip_pos: Position = match args.get(4) {
        None => Position { x: 0, y: 0, z: 0 },
        Some(s) => {
            let parts: Vec<&str> = s.split(',').collect();
            if parts.len() != 3 {
                return Err(format!("chip position must be x,y,z, got `{s}`"));
            }
            let v: Result<Vec<i32>, _> = parts.iter().map(|p| p.parse::<i32>()).collect();
            let v = v.map_err(|_| format!("chip position must be three integers, got `{s}`"))?;
            Position { x: v[0], y: v[1], z: v[2] }
        }
    };

    let src = std::fs::read_to_string(source).map_err(|e| format!("cannot read {source}: {e}"))?;
    let file = source.clone();
    let result = compile_to_world(
        CompileInput {
            source: &src,
            file: &file,
            module_name: None,
            fold_mode: FoldMode::Auto,
        },
        assemble_options(&file, FoldMode::Auto),
    )
    .map_err(|e| format!("compile failed: {e}"))?;

    // Same discipline as the compiler CLI: warnings and errors always print,
    // and an ERROR means nothing is written.
    let mut errors = 0usize;
    for d in &result.diagnostics {
        if matches!(d.severity, Severity::Error) {
            errors += 1;
            eprintln!("ERROR {d}");
        } else if matches!(d.severity, Severity::Warning) {
            eprintln!("WARN  {d}");
        }
    }
    if errors > 0 {
        return Err(format!(
            "{} error diagnostic(s); {} not written",
            errors, out
        ));
    }

    let mut world = result.world;
    let n = (spec.cols as usize) * (spec.rows as usize);
    let outputs = output_bricks(&world, &spec.prefix, n)?;

    // Wall centred on the chip in X/Z, standing in the X/Z plane at fixed Y.
    // Row 0 is the TOP row (high Z; +Z is up).
    let x0 = chip_pos.x - spec.cols as i32;
    let y0 = chip_pos.y + WALL_Y_OFFSET;
    let z0 = chip_pos.z - spec.rows as i32;

    // One black changer-data map shared by every brick: the changer's struct
    // default colour is light grey (200,200,200), so a dataless stub would
    // paste a grey wall until the first paint.  Unset fields fall back to
    // brdb's STRUCT_DEFAULTS at write time.
    let mut changer_data: HashMap<BString, Box<dyn AsBrdbValue>> = HashMap::new();
    changer_data.insert(
        "Color".into(),
        Box::new(SavedBrickColor::rgb(0, 0, 0)),
    );
    let changer_data = std::sync::Arc::new(changer_data);

    // Fail loud on a duplicated pixel output rather than double-driving a
    // changer (the game rejects two sources on one input port).
    let mut used: HashSet<usize> = HashSet::new();

    for i in 0..n {
        let src_id = outputs[&i];
        if !used.insert(src_id) {
            return Err(format!(
                "wall: output {}{} and another output share brick {}",
                spec.prefix, i, src_id
            ));
        }
        let col = (i % spec.cols as usize) as i32;
        let row = (i / spec.cols as usize) as i32;
        let position = Position {
            x: x0 + WALL_PITCH * col,
            y: y0,
            z: z0 + WALL_PITCH * (spec.rows as i32 - 1 - row),
        };

        let brick = Brick {
            asset: BrickType::Procedural {
                asset: brdb::assets::bricks::PB_DEFAULT_MICRO_BRICK,
                size: brdb::BrickSize { x: 1, y: 1, z: 1 },
            },
            position,
            // The brick's own save colour: black until the changer is driven.
            color: Color::monochrome(0),
            // Pixels glow: the wall is a light source, not a painted surface,
            // so colours read as emitted light at any distance.  The chip's
            // brightness input scales the emitted colour.
            material: brdb::assets::materials::GLOW,
            // Look-only: no player/weapon/tool/physics collision.
            collision: no_collision(),
            components: vec![Box::new(LiteralComponent::new_from_data(
                CHANGER_CLASS,
                changer_data.clone(),
            ))],
            ..Default::default()
        }
        .with_id();
        let wall_id = brick.id.expect("with_id assigns an id");
        world.bricks.push(brick);

        // out: MicrochipOutput.RER_Output -> changer.Color  (the chip-port
        // remap the compiler itself uses).  Cross-grid, so the brdb writer
        // serialises it as a remote wire -- the same path as the `@side`
        // rerouter wires.
        world.add_wire(WireConnection {
            source: WirePort {
                brick_id: src_id,
                component_type: BString::Static(OUTPUT_CLASS),
                port_name: BString::Static("RER_Output"),
            },
            target: WirePort {
                brick_id: wall_id,
                component_type: BString::Static(CHANGER_CLASS),
                port_name: BString::Static("Color"),
            },
        });
    }

    // The compiler made the prefab before the wall existed; recompute so the
    // bounds cover the whole artifact (paste selection, and the overlap the
    // game would have swept).
    world.make_prefab();

    world
        .write_brz(out)
        .map_err(|e| format!("cannot write {out}: {e}"))?;
    println!(
        "mkwall: {} pixel bricks, {} wires (outputs {}{}..{}{})",
        n,
        n,
        spec.prefix,
        0,
        spec.prefix,
        n - 1
    );
    Ok(())
}