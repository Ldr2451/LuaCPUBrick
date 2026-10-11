//! Post-emit pixel wall: a grid of microbricks, each dyed by one chip output.
//!
//! A plain brick exposes no wire ports — brick colour is save data, not a
//! port — so every pixel brick carries a `Component_BrickPropertyChanger`
//! and the chip's colour output drives its `Color` input by wire. One
//! composite colour wire per pixel; the changer's `Color.R/G/B/A` sub-ports
//! exist but would triple the wire count for no benefit.
//!
//! An array output could NOT do this job: a wire addresses one
//! (brick, component, port) triple, and an array port is a single port —
//! there are no per-element wire endpoints to fan out to. The chip needs one
//! scalar colour output per pixel, and this pass wires each to its brick.
//!
//! Runs at the end of `build_world` (after `emit_port_rerouters`, before
//! `register_all_components` / `make_prefab` / `check_no_overlap`), so the
//! wall bricks join the prefab bounds and the overlap sweep. Enabled only by
//! `--wall <prefix>:<cols>x<rows>`; without the flag the world is untouched.

use super::*;

/// Which chip outputs form the screen, and how big the wall is.
#[derive(Clone, Debug)]
pub struct WallSpec {
    /// Output label prefix; pixel `i` is driven by the output labelled
    /// `{prefix}{i}` (e.g. `px` → `px0`..`px4095`).
    pub prefix: String,
    /// Wall width in bricks.
    pub cols: u32,
    /// Wall height in bricks.
    pub rows: u32,
}

/// Parse `--wall <prefix>:<cols>x<rows>` (e.g. `px:64x64`).
pub fn parse_wall_spec(s: &str) -> Result<WallSpec, String> {
    let (prefix, dims) = s
        .split_once(':')
        .ok_or_else(|| format!("--wall must be <prefix>:<cols>x<rows>, got `{s}`"))?;
    let (cols, rows) = dims
        .split_once('x')
        .ok_or_else(|| format!("--wall must be <prefix>:<cols>x<rows>, got `{s}`"))?;
    if prefix.is_empty() {
        return Err(format!("--wall needs a non-empty output prefix, got `{s}`"));
    }
    let cols: u32 = cols
        .parse()
        .map_err(|_| format!("--wall cols is not a number in `{s}`"))?;
    let rows: u32 = rows
        .parse()
        .map_err(|_| format!("--wall rows is not a number in `{s}`"))?;
    if cols == 0 || rows == 0 || cols > 256 || rows > 256 {
        return Err(format!("--wall dims out of range 1..=256 in `{s}`"));
    }
    Ok(WallSpec {
        prefix: prefix.to_string(),
        cols,
        rows,
    })
}

const CHANGER_CLASS: &str = "Component_BrickPropertyChanger";
/// 1x1x1 procedural microbricks at 2-unit pitch, mirroring a hand-built
/// reference wall (measured lattice, X/Z plane).
const WALL_PITCH: i32 = 2;
/// Fixed-Y offset of the wall plane from the chip shell. Clears the shell
/// and the `@side` rerouter pins (edge offset 6 + brick extents) with margin.
const WALL_Y_OFFSET: i32 = 16;

/// Lay the pixel wall on the outer grid and wire it to the chip outputs.
/// No-op unless `EmitOptions.wall` is set.
pub(super) fn emit_pixel_wall(
    world: &mut World,
    ctx: &mut EmitContext,
    module: &Module,
    opts: &EmitOptions,
) -> Result<(), EmitError> {
    let Some(spec) = opts.wall.as_ref() else {
        return Ok(());
    };
    let n = (spec.cols as usize) * (spec.rows as usize);

    // Root output label → node id. (Same property `build_port_index` reads.)
    let port_label_sym = *sym::PORT_LABEL;
    let mut by_label: HashMap<String, NodeId> = HashMap::default();
    for id in module.outputs.iter() {
        let Some(node) = module.nodes.get(id) else {
            continue;
        };
        if let Some(Literal::String(label)) = node.properties.get(&port_label_sym) {
            by_label.insert(label.clone(), *id);
        }
    }

    // Fail loud, not dark: a missing output would paste a dead pixel with no
    // wire and nothing downstream could tell (the DroppedWire discipline).
    let missing: Vec<usize> = (0..n)
        .filter(|i| !by_label.contains_key(&format!("{}{}", spec.prefix, i)))
        .collect();
    if !missing.is_empty() {
        let show: Vec<String> = missing
            .iter()
            .take(8)
            .map(|i| format!("{}{}", spec.prefix, i))
            .collect();
        return Err(EmitError::DroppedWire(format!(
            "wall: {}/{} pixel outputs missing (e.g. {})",
            missing.len(),
            n,
            show.join(", "),
        )));
    }

    // Wall centred on the chip in X/Z, standing in the X/Z plane at fixed Y.
    // Row 0 is the TOP row (high Z; +Z is up). Viewing-side mirroring is a
    // game-side check; a flip is a one-line change here.
    let x0 = opts.chip_pos.x - spec.cols as i32;
    let y0 = opts.chip_pos.y + WALL_Y_OFFSET;
    let z0 = opts.chip_pos.z - spec.rows as i32;

    // One black changer-data map shared by all 4096 bricks: the changer's
    // struct default colour is light grey (200,200,200), so a dataless stub
    // would paste a grey wall until the first paint. Unset fields fall back
    // to brdb's STRUCT_DEFAULTS at write time (bricks stay visible,
    // collision stays governed by the brick flags below).
    let mut changer_data: StdMap<BString, Box<dyn AsBrdbValue>> = StdMap::new();
    changer_data.insert(
        "Color".into(),
        Box::new(brdb::SavedBrickColor::rgb(0, 0, 0)),
    );
    let changer_data = std::sync::Arc::new(changer_data);

    for i in 0..n {
        let node_id = by_label[&format!("{}{}", spec.prefix, i)];
        let Some(&io_brick_id) = ctx.node_brick_ids.get(&node_id) else {
            return Err(EmitError::DroppedWire(format!(
                "wall: output {}{} has no emitted brick",
                spec.prefix, i,
            )));
        };
        let col = (i % spec.cols as usize) as i32;
        let row = (i / spec.cols as usize) as i32;
        let position = Position {
            x: x0 + WALL_PITCH * col,
            y: y0,
            z: z0 + WALL_PITCH * (spec.rows as i32 - 1 - row),
        };

        let (brick, wall_brick_id) = brdb::Brick {
            asset: BrickType::Procedural {
                asset: brdb::assets::bricks::PB_DEFAULT_MICRO_BRICK,
                size: brdb::BrickSize { x: 1, y: 1, z: 1 },
            },
            position,
            // The brick's own save colour: black until the changer is driven.
            color: brdb::Color::monochrome(0),
            // Pixels are look-only: no player/weapon/tool/physics collision.
            collision: no_collision(),
            ..Default::default()
        }
        .with_component_box(Box::new(LiteralComponent::new_from_data(
            CHANGER_CLASS,
            changer_data.clone(),
        )))
        .with_id_split();
        world.bricks.push(brick);

        // out: MicrochipOutput.RER_Output → changer.Color
        // (mirrors the chip-port remap in build_port_index). Cross-grid, so
        // the brdb writer serialises it as a remote wire automatically —
        // same path as the `@side` rerouter wires.
        ctx.add_wire(
            world,
            WireConnection {
                source: BrdbWirePort {
                    brick_id: io_brick_id,
                    component_type: BString::Static(gc::MICROCHIP_OUTPUT),
                    port_name: BString::Static("RER_Output"),
                },
                target: BrdbWirePort {
                    brick_id: wall_brick_id,
                    component_type: BString::Static(CHANGER_CLASS),
                    port_name: BString::Static("Color"),
                },
            },
        )?;
    }
    Ok(())
}
