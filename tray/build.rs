//! Embeds the exe icon (`assets/aap-runner-tray.rc` names `aap-runner-tray.ico`), as Fathom's
//! build.rs does. `manifest_required` turns a failed compile or a missing resource compiler
//! into a build error instead of an exe with no icon. Windows only.

fn main() {
    println!("cargo:rerun-if-changed=assets/aap-runner-tray.ico");
    #[cfg(windows)]
    {
        embed_resource::compile("assets/aap-runner-tray.rc", embed_resource::NONE)
            .manifest_required()
            .expect("compile assets/aap-runner-tray.rc");
    }
}
