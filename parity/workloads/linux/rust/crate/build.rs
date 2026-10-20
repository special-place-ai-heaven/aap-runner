// Builds native.c into a static library with the C compiler and ar from PATH (no cc crate: nothing is downloaded).
use std::env;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    let out = PathBuf::from(env::var("OUT_DIR").unwrap());
    let cc = env::var("CC").unwrap_or_else(|_| "cc".to_string());
    let obj = out.join("native.o");
    let ok = Command::new(&cc).args(["-c", "-fPIC", "-O2", "native.c", "-o"]).arg(&obj).status().expect("C compiler");
    assert!(ok.success(), "{cc} failed on native.c");
    let ok = Command::new("ar").arg("crs").arg(out.join("libnative.a")).arg(&obj).status().expect("ar");
    assert!(ok.success(), "ar failed");
    println!("cargo:rustc-link-search=native={}", out.display());
    println!("cargo:rustc-link-lib=static=native");
    println!("cargo:rerun-if-changed=native.c");
}
