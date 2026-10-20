// Builds native/native.c into a static library with cl.exe and lib.exe from PATH (the developer environment), the
// way the cc crate does once VCINSTALLDIR is set. No crates.io dependency, so the build stays offline.
use std::{env, path::PathBuf, process::Command};

fn run(cmd: &mut Command) {
    let st = cmd
        .status()
        .unwrap_or_else(|e| panic!("cannot start {:?}: {}", cmd.get_program(), e));
    assert!(st.success(), "{:?} failed: {}", cmd.get_program(), st);
}

fn main() {
    let out = PathBuf::from(env::var("OUT_DIR").unwrap());
    let obj = out.join("native.obj");
    run(Command::new("cl.exe")
        .args([
            "/nologo",
            "/c",
            "/W4",
            "/WX",
            "/MD",
            "/O2",
            "native/native.c",
        ])
        .arg(format!("/Fo{}", obj.display())));
    run(Command::new("lib.exe")
        .arg("/nologo")
        .arg(format!("/OUT:{}", out.join("native.lib").display()))
        .arg(&obj));
    println!("cargo:rustc-link-search=native={}", out.display());
    println!("cargo:rustc-link-lib=static=native");
    println!("cargo:rerun-if-changed=native/native.c");
}
