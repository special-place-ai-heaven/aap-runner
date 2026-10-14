//! Embeds the exe icon (`assets/aap-runner-tray.rc` names `aap-runner-tray.ico`), as Fathom's
//! build.rs does. `manifest_required` turns a failed compile or a missing resource compiler
//! into a build error instead of an exe with no icon. Windows only.
//!
//! Also stamps `AAP_TRAY_COMMIT` (short HEAD, or `local` without git; an `AAP_TRAY_COMMIT`
//! env var wins) for the visible version string.

fn main() {
    println!("cargo:rerun-if-changed=assets/aap-runner-tray.ico");
    // ponytail: not rerun on every commit (no .git/HEAD watch); `cargo clean -p` or the env var
    // forces a fresh stamp if a build ever shows a stale commit.
    println!("cargo:rerun-if-env-changed=AAP_TRAY_COMMIT");
    let commit = std::env::var("AAP_TRAY_COMMIT")
        .ok()
        .or_else(|| {
            std::process::Command::new("git")
                .args(["rev-parse", "--short=8", "HEAD"])
                .output()
                .ok()
                .filter(|o| o.status.success())
                .and_then(|o| String::from_utf8(o.stdout).ok())
        })
        .map(|s| s.trim().to_owned())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "local".into());
    println!("cargo:rustc-env=AAP_TRAY_COMMIT={commit}");
    #[cfg(windows)]
    {
        embed_resource::compile("assets/aap-runner-tray.rc", embed_resource::NONE)
            .manifest_required()
            .expect("compile assets/aap-runner-tray.rc");
    }
}
