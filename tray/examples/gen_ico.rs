//! Writes `assets/aap-runner-tray.ico` from the mark drawn in `src/mark.rs` and `src/ico.rs`.
//! Run after changing the glyph: `cargo run --example gen_ico`.

#[allow(dead_code)]
#[path = "../src/mark.rs"]
mod mark;

#[path = "../src/ico.rs"]
mod ico;

fn main() -> std::io::Result<()> {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/assets/aap-runner-tray.ico");
    std::fs::write(path, ico::ico_bytes())?;
    println!("wrote {path}");
    Ok(())
}
