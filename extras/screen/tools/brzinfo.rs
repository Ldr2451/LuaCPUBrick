# tools/brzinfo.rs -- inspect a .brz: grids, brick/wire/component counts.
#
# Not part of the build: a diagnostic for when a rebuild's numbers have to be
# compared against a shipped save (e.g. the wall grid must stay 4110 bricks /
# 4096 wires / 4124 components after a compiler update).  brdb is the
# compiler's own save library and the example has no dependency on the
# compiler, so it builds against a bare checkout:
#
#   copy tools/brzinfo.rs <wirescript>/crates/wirescript/examples/
#   cd <wirescript> && cargo build --release --example brzinfo
#   ./target/release/examples/brzinfo <file.brz>
//
// Delete the copy afterwards: the checkout stays pristine (the screen build
# itself never needs this -- see mkwall/, which is what lays the wall).
use brdb::{Brz, IntoReader};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let path = std::env::args().nth(1).expect("usage: brzinfo <file.brz>");
    let db = Brz::open(path)?.into_reader();
    let mut grid_ids = vec![1usize];
    for index in db.entity_chunk_index()? {
        for e in db.entity_chunk(index)? {
            if e.is_brick_grid() || e.is_microchip_grid() {
                if let Some(id) = e.id {
                    if !grid_ids.contains(&id) {
                        grid_ids.push(id);
                    }
                }
            }
        }
    }
    println!("grids: {:?}", grid_ids);
    for &gid in &grid_ids {
        let chunks = db.brick_chunk_index(gid)?;
        let mut nb = 0u64;
        let mut nw = 0u64;
        let mut nc = 0u64;
        for c in &chunks {
            nb += c.num_bricks as u64;
            nw += c.num_wires as u64;
            nc += c.num_components as u64;
        }
        println!(
            "grid {}: {} chunks bricks={} wires={} components={}",
            gid,
            chunks.len(),
            nb,
            nw,
            nc
        );
        for c in &chunks {
            println!(
                "   chunk ({},{},{}) bricks={} wires={} components={}",
                c.index.x,
                c.index.y,
                c.index.z,
                c.num_bricks,
                c.num_wires,
                c.num_components
            );
        }
    }
    Ok(())
}