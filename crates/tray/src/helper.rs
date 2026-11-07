//! Elevated helper (`--helper <verb> <id>`) and the non-elevated side that asks for it.
//!
//! The tray writes `inbox\jobs\<id>.json` and starts this exe with `runas` (one UAC prompt).
//! The helper trusts nothing in that file except the schema, a verb of `verify`, `repair`,
//! `identity`, `install`, or `update`, and an id of 16 lowercase hex digits that matches the
//! command line. An `identity` request also carries the org, ids, group, labels, and the key file
//! path, each re-checked here and again by the script; `update` carries a candidate path and a
//! sha256 (see `update.rs`). Every other path is built from `C:\ProgramData\aap-runner` plus that
//! id. A reparse point on the way is refused, not followed.
//!
//! Progress lands in `jobs\<id>\` (`status.json`, `log.txt`, `exit.txt`), which the tray polls.
//! The work itself is the existing PowerShell scripts, embedded and written into that folder
//! before they run.
//!
//! ponytail: each run keeps its script copy under `jobs\<id>\scripts`. Delete old job folders by
//! hand; a cap is the upgrade if that directory grows.

use crate::identity;
use crate::state;
use crate::update;
use crate::win;
use serde::{Deserialize, Serialize};
#[cfg(test)]
use std::cell::{Cell, RefCell};
use std::collections::HashSet;
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufRead, BufReader, Read, Seek, SeekFrom, Write};
use std::os::windows::fs::MetadataExt;
use std::os::windows::process::CommandExt;
use std::path::{Component, Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{LazyLock, Mutex, mpsc};

use std::thread;
use std::time::{Duration, Instant};

pub const DATA_DIR: &str = r"C:\ProgramData\aap-runner";
const REQUEST_MAX: u64 = 4096;

/// IDs issued by this process via `write_pointer`. `load_job_from` rejects any result whose
/// id is not in this set so that a stale `helper.json` from a previous process is ignored.
static ISSUED_IDS: LazyLock<Mutex<HashSet<String>>> = LazyLock::new(|| Mutex::new(HashSet::new()));
static INSTALL_PROCESS: Mutex<Option<win::ProcessIdentity>> = Mutex::new(None);

pub fn install_process() -> Option<win::ProcessIdentity> {
    INSTALL_PROCESS.lock().ok().and_then(|p| *p)
}

fn register_id(id: &str) {
    let _ = ISSUED_IDS.lock().map(|mut s| {
        s.insert(id.to_string());
    });
}

fn is_issued_id(id: &str) -> bool {
    ISSUED_IDS.lock().is_ok_and(|s| s.contains(id))
}

const STATUS_MAX: u64 = 64 * 1024;
const LOG_CAP: u64 = 1024 * 1024;
const LOG_TAIL_BYTES: u64 = 8192;
const REQUEST_WAIT: Duration = Duration::from_secs(180);
const POWERSHELL: &str = r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe";
const SYSTEM32: &str = r"C:\Windows\System32";
const CREATE_NO_WINDOW: u32 = 0x0800_0000;
/// Shown instead of a UAC prompt when the exe or its directory is not admin-only.
pub const USER_WRITABLE_EXE_DIR: &str =
    "tray exe is in a user-writable folder; move it to an admin-only folder";
/// SYSTEM, Administrators, TrustedInstaller.
const ADMIN_SIDS: [&str; 3] = [
    "S-1-5-18",
    "S-1-5-32-544",
    "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464",
];
/// Write-data, append, write-attributes, delete-child, delete, write-DAC, write-owner,
/// generic write, generic all.
const REPLACE_RIGHTS: u32 = 0x0002
    | 0x0004
    | 0x0100
    | 0x0040
    | 0x0001_0000
    | 0x0004_0000
    | 0x0008_0000
    | 0x4000_0000
    | 0x1000_0000;
/// Same mask as install-supervisor.ps1 Get-AapAncestorProblem. Create rights are absent:
/// the drive root grants Authenticated Users "create folders", which cannot replace a child.
const ANCESTOR_RIGHTS: u32 = 0x0040 | 0x0001_0000 | 0x0004_0000 | 0x0008_0000 | 0x1000_0000;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AceKind {
    Allow,
    Deny,
    Other,
}

/// One DACL entry. An inherit-only allow does not apply to the object itself.
#[derive(Clone, Debug)]
pub struct DirAce {
    pub sid: String,
    pub kind: AceKind,
    pub rights: u32,
    pub inherit_only: bool,
}

/// Owner plus DACL, as read from the exe or its directory.
#[derive(Clone, Debug)]
pub struct AclView {
    pub owner: String,
    pub aces: Vec<DirAce>,
}

/// Elevation is allowed only for an admin owner, and only when every non-inherit-only allow
/// ACE for any other SID carries none of [`REPLACE_RIGHTS`]. Any other ACE type refuses.
/// A parent folder lets another account rename or replace the tree when a non-admin allow
/// ACE on the folder itself carries [`ANCESTOR_RIGHTS`].
pub fn ancestor_lets_non_admin_replace(aces: &[DirAce]) -> bool {
    aces.iter().any(|ace| {
        ace.kind == AceKind::Allow
            && !ace.inherit_only
            && !ADMIN_SIDS.contains(&ace.sid.as_str())
            && ace.rights & ANCESTOR_RIGHTS != 0
    })
}

/// Owner is not an admin SID, an ACE is neither allow nor deny, or a non-admin
/// allow on the folder itself carries [`ANCESTOR_RIGHTS`].
pub fn ancestor_refused(view: &AclView) -> bool {
    if !ADMIN_SIDS.contains(&view.owner.as_str()) {
        return true;
    }
    view.aces.iter().any(|ace| ace.kind == AceKind::Other)
        || ancestor_lets_non_admin_replace(&view.aces)
}

pub fn elevation_allowed(object: &AclView) -> bool {
    if !ADMIN_SIDS.contains(&object.owner.as_str()) {
        return false;
    }
    object.aces.iter().all(|ace| match ace.kind {
        AceKind::Other => false,
        AceKind::Deny => true,
        AceKind::Allow => {
            ace.inherit_only
                || ADMIN_SIDS.contains(&ace.sid.as_str())
                || ace.rights & REPLACE_RIGHTS == 0
        }
    })
}

fn acl_view(sec: win::ObjectAcl) -> AclView {
    AclView {
        owner: sec.owner,
        aces: sec
            .aces
            .into_iter()
            .map(|ace| DirAce {
                sid: ace.sid,
                kind: if ace.other {
                    AceKind::Other
                } else if ace.allow {
                    AceKind::Allow
                } else {
                    AceKind::Deny
                },
                rights: ace.rights,
                inherit_only: ace.inherit_only,
            })
            .collect(),
    }
}

/// Bootstrap alone accepts the initiating user's writes. It never accepts another user's
/// writes; Verify, Repair and Identity retain the original administrator-only policy.
fn allowed_for_verb(object: &AclView, bootstrap_user: Option<&str>, ancestor: bool) -> bool {
    let Some(user) = bootstrap_user else {
        return if ancestor {
            !ancestor_refused(object)
        } else {
            elevation_allowed(object)
        };
    };
    if object.owner != user && !ADMIN_SIDS.contains(&object.owner.as_str()) {
        return false;
    }
    let mask = if ancestor {
        ANCESTOR_RIGHTS
    } else {
        REPLACE_RIGHTS
    };
    object.aces.iter().all(|ace| match ace.kind {
        AceKind::Other => false,
        AceKind::Deny => true,
        AceKind::Allow => {
            ace.inherit_only
                || ace.sid == user
                || ADMIN_SIDS.contains(&ace.sid.as_str())
                || ace.rights & mask == 0
        }
    })
}

fn check_exe_directories(dir: &Path, bootstrap_user: Option<&str>) -> Result<(), String> {
    if bootstrap_user.is_none() {
        require_admin_only(dir, "tray exe folder")?;
        return require_ancestors(dir);
    }
    for (index, path) in dir.ancestors().enumerate() {
        if reparse_path(path) {
            return Err("installer path contains a link or junction; use a local folder".into());
        }
        let view = acl_view(win::acl_of_path(path, true).map_err(|e| e.to_string())?);
        if !allowed_for_verb(&view, bootstrap_user, index > 0) {
            return Err("installer folder permits another account to replace it; move the exe to your private Downloads folder".into());
        }
    }
    Ok(())
}

const PRIVATE_LOCATION: &str = "Installer must be on a fixed local drive, owned by you or Administrators, and writable only by you or Administrators. Move it to your private Downloads folder.";

/// The installer's location rule for an update candidate: `acl` is the file's (read from the
/// open handle), `dir` its folder. Only `user` and Administrators may own or write the file,
/// write its folder, or replace an ancestor.
pub(crate) fn user_location_ok(acl: win::ObjectAcl, dir: &Path, user: &str) -> Result<(), String> {
    if !allowed_for_verb(&acl_view(acl), Some(user), false) {
        return Err(format!(
            "the new build can be changed by another account; {KEEP_BUILD_PRIVATE}"
        ));
    }
    // ponytail: install keeps its own "private Downloads folder" wording; align it separately.
    check_exe_directories(dir, Some(user)).map_err(|_| {
        format!("the new build's folder, or one above it, can be changed by another account; {KEEP_BUILD_PRIVATE}")
    })
}

const KEEP_BUILD_PRIVATE: &str = "keep the new build in a folder only you, SYSTEM and Administrators can change (for example C:\\aap-builds with inheritance removed)";

pub fn install_location_ok() -> Result<(), String> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let resolved = win::resolve_exe(&exe).map_err(|e| e.to_string())?;
    let user = win::current_user_sid().map_err(|e| e.to_string())?;
    if !win::is_fixed_local_path(&resolved.path)
        || !allowed_for_verb(&acl_view(resolved.acl), Some(&user), false)
    {
        return Err(PRIVATE_LOCATION.into());
    }
    check_exe_directories(resolved.path.parent().ok_or("installer path")?, Some(&user))
}

pub fn start_installed_tray() -> Result<(), String> {
    let exe = Path::new(r"C:\Program Files\aap-runner\aap-runner-tray.exe");
    let resolved = win::resolve_exe(exe).map_err(|e| e.to_string())?;
    if !win::is_fixed_local_path(&resolved.path) || !elevation_allowed(&acl_view(resolved.acl)) {
        return Err("installed tray is not protected".into());
    }
    check_exe_directories(resolved.path.parent().ok_or("installed tray path")?, None)?;
    Command::new(resolved.path)
        .creation_flags(CREATE_NO_WINDOW)
        .spawn()
        .map_err(|e| e.to_string())?;
    Ok(())
}

pub fn open_install_log(base: &Path, id: &str) -> Result<(), String> {
    if !valid_id(id) {
        return Err("Invalid install job id".into());
    }
    let dir = job_dir(base, id);
    require_admin_only(&dir, "install job")?;
    require_ancestors(&dir)?;
    let log = dir.join("log.txt");
    if reparse_path(&log) {
        return Err("Install log is a link".into());
    }
    Command::new(r"C:\Windows\explorer.exe")
        .arg(log)
        .creation_flags(CREATE_NO_WINDOW)
        .spawn()
        .map_err(|e| e.to_string())?;
    Ok(())
}

fn ensure_admin_dir(path: &Path) -> Result<(), String> {
    if !path.exists() {
        win::create_admin_dir(path).map_err(|e| e.to_string())?;
    }
    if reparse_path(path) || !path.is_dir() {
        return Err("protected folder is a link or not a directory".into());
    }
    require_admin_only(path, "protected folder")?;
    require_ancestors(path)
}

/// [`ensure_admin_dir`] for the update staging folder: created SYSTEM and Administrators only,
/// and an existing one may not grant any other SID anything.
fn ensure_private_dir(path: &Path) -> Result<(), String> {
    if !path.exists() {
        win::create_private_dir(path).map_err(|e| e.to_string())?;
    }
    if reparse_path(path) || !path.is_dir() {
        return Err("protected folder is a link or not a directory".into());
    }
    let view = acl_view(win::acl_of_path(path, true).map_err(|e| e.to_string())?);
    if !elevation_allowed(&view)
        || view.aces.iter().any(|a| {
            a.kind == AceKind::Allow && !a.inherit_only && !ADMIN_SIDS.contains(&a.sid.as_str())
        })
    {
        return Err("update staging folder is readable by other accounts".into());
    }
    require_ancestors(path)
}

/// Only the Install verb may copy itself. Create-new plus an inherited admin ACL prevents
/// replacing an existing installation or executing a staged binary written by another user.
fn prepare_install(base: &Path, job: &Path) -> Result<String, String> {
    install_location_ok()?;
    ensure_admin_dir(base)?;
    ensure_admin_dir(&base.join("jobs"))?;
    ensure_admin_dir(&base.join("jobs/install"))?;
    ensure_admin_dir(job)?;
    let destination_dir = Path::new(r"C:\Program Files\aap-runner");
    ensure_admin_dir(destination_dir)?;
    let destination = destination_dir.join("aap-runner-tray.exe");
    let source = win::resolve_exe(&std::env::current_exe().map_err(|e| e.to_string())?)
        .map_err(|e| e.to_string())?
        .path;
    if destination.exists() {
        if reparse_path(&destination) {
            return Err("installed tray is a link".into());
        }
        require_admin_only(&destination, "installed tray")?;
        if source != destination && !same_file_bytes(&source, &destination)? {
            return Err("A different protected tray already exists. Run C:\\Program Files\\aap-runner\\aap-runner-tray.exe to resume setup.".into());
        }
    } else {
        let mut source_file = File::open(&source).map_err(|e| e.to_string())?;
        let mut target = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&destination)
            .map_err(|e| e.to_string())?;
        io::copy(&mut source_file, &mut target).map_err(|e| e.to_string())?;
        target.sync_all().map_err(|e| e.to_string())?;
        require_admin_only(&destination, "installed tray")?;
    }
    Ok(destination.display().to_string())
}

fn same_file_bytes(a: &Path, b: &Path) -> Result<bool, String> {
    let mut a = File::open(a).map_err(|e| e.to_string())?;
    let mut b = File::open(b).map_err(|e| e.to_string())?;
    if a.metadata().map_err(|e| e.to_string())?.len()
        != b.metadata().map_err(|e| e.to_string())?.len()
    {
        return Ok(false);
    }
    let mut left = [0u8; 8192];
    let mut right = [0u8; 8192];
    loop {
        let n = a.read(&mut left).map_err(|e| e.to_string())?;
        if n == 0 {
            return Ok(true);
        }
        b.read_exact(&mut right[..n]).map_err(|e| e.to_string())?;
        if left[..n] != right[..n] {
            return Ok(false);
        }
    }
}

/// Only a fixed helper-owned journal can restore the identity of a previous install job.
#[derive(Deserialize)]
pub struct InstallCheckpoint {
    schema: u32,
    pub step: String,
    pub job_id: String,
    runner_count: u32,
    job_cpus: u32,
    job_memory_gib: u32,
    work_disk_gib: u32,
}

impl InstallCheckpoint {
    pub fn sizing(&self) -> crate::wizard::Sizing {
        crate::wizard::Sizing {
            runner_count: self.runner_count,
            job_cpus: self.job_cpus,
            job_memory_gib: self.job_memory_gib,
            work_disk_gib: self.work_disk_gib,
            windows_runner_count: 0,
        }
    }
}

pub fn install_checkpoint(base: &Path) -> Option<InstallCheckpoint> {
    let dir = base.join("jobs/install");
    let path = dir.join("state.json");
    if reparse_path(&path)
        || require_admin_only(&dir, "install journal").is_err()
        || require_ancestors(&dir).is_err()
        || require_admin_only(&path, "install journal").is_err()
    {
        return None;
    }
    let checkpoint: InstallCheckpoint = serde_json::from_str(&state::read_bounded(&path)?).ok()?;
    (checkpoint.schema == 1
        && valid_id(&checkpoint.job_id)
        && matches!(checkpoint.step.as_str(), "install" | "done")
        && checkpoint.sizing().check_shape().is_ok())
    .then_some(checkpoint)
}

pub fn resume_install_job(base: &Path) -> Option<JobUi> {
    let checkpoint = install_checkpoint(base)?;
    resume_install_id(base, &checkpoint.job_id)
}

pub fn resume_install_id(base: &Path, id: &str) -> Option<JobUi> {
    protected_job(base, id, Verb::Install)
}

/// A job this process did not issue, trusted only when its folder, the folders above it, and its
/// `status.json` are admin-only (so only the helper wrote them).
fn protected_job(base: &Path, id: &str, verb: Verb) -> Option<JobUi> {
    if !valid_id(id) {
        return None;
    }
    let dir = job_dir(base, id);
    if require_admin_only(&dir, "install job").is_err() || require_ancestors(&dir).is_err() {
        return None;
    }
    if require_admin_only(&dir.join("status.json"), "install status").is_err() {
        return None;
    }
    let status = read_status_file(&dir.join("status.json")).ok()??;
    if status.schema != 1 || status.id != id || status.verb != verb.as_str() {
        return None;
    }
    Some(JobUi {
        verb: status.verb,
        state: status.state,
        step: status.step,
        exit_code: status.exit_code,
        lines: log_tail(&dir.join("log.txt")),
        app_token: None,
    })
}

fn require_ancestors(dir: &Path) -> Result<(), String> {
    let mut current = dir.to_path_buf();
    while let Some(parent) = current.parent() {
        if parent == current {
            break;
        }
        match win::acl_of_path(parent, true) {
            Ok(sec) => {
                if ancestor_refused(&acl_view(sec)) {
                    return Err(USER_WRITABLE_EXE_DIR.to_string());
                }
            }
            Err(e) => return Err(format!("could not read an ancestor ACL: {e}")),
        }
        current = parent.to_path_buf();
    }
    Ok(())
}

fn require_admin_only(path: &Path, what: &str) -> Result<(), String> {
    match win::acl_of_path(path, true) {
        Ok(sec) => {
            if elevation_allowed(&acl_view(sec)) {
                Ok(())
            } else {
                Err(USER_WRITABLE_EXE_DIR.to_string())
            }
        }
        Err(e) => Err(format!("could not read the {what} ACL: {e}")),
    }
}

const REPARSE: u32 = 0x400;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verb {
    Verify,
    Repair,
    Identity,
    Install,
    Update,
}

impl Verb {
    pub fn as_str(self) -> &'static str {
        match self {
            Verb::Verify => "verify",
            Verb::Repair => "repair",
            Verb::Identity => "identity",
            Verb::Install => "install",
            Verb::Update => "update",
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Verb::Verify => "Verify",
            Verb::Repair => "Repair",
            Verb::Identity => "Identity",
            Verb::Install => "Install",
            Verb::Update => "Update",
        }
    }

    fn parse(text: &str) -> Option<Self> {
        match text {
            "verify" => Some(Verb::Verify),
            "repair" => Some(Verb::Repair),
            "identity" => Some(Verb::Identity),
            "install" => Some(Verb::Install),
            "update" => Some(Verb::Update),
            _ => None,
        }
    }
}

#[derive(Debug, Clone)]
pub struct JobUi {
    pub verb: String,
    pub state: String,
    pub step: String,
    pub exit_code: Option<i32>,
    pub lines: Vec<String>,
    /// Verify's `app-token` row: `Some(true)` on `PASS app-token`, `Some(false)` on `FAIL app-token`.
    pub app_token: Option<bool>,
}

impl JobUi {
    pub fn summary(&self) -> String {
        let verb = Verb::parse(&self.verb).map(Verb::label).unwrap_or("Verify");
        if self.step.is_empty() {
            format!("{verb} \u{b7} {}", self.state)
        } else {
            format!("{verb} \u{b7} {} \u{b7} {}", self.state, self.step)
        }
    }

    pub fn active(&self) -> bool {
        matches!(self.state.as_str(), "waiting" | "queued" | "running")
    }
}

#[derive(Debug, Serialize, Deserialize, PartialEq, Eq)]
struct JobStatus {
    schema: u32,
    id: String,
    verb: String,
    state: String,
    step: String,
    exit_code: Option<i32>,
    /// `update` only, on `passed`: the sha256 of the exe now installed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    sha256: Option<String>,
}

/// The identity fields are present only for the `identity` verb. The path is a string here; the
/// script checks the file (regular, under the requester's profile, PEM, under 16 KiB).
#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawRequest {
    schema: u32,
    id: String,
    verb: String,
    #[serde(default)]
    org: Option<String>,
    #[serde(default)]
    app_id: Option<u64>,
    #[serde(default)]
    installation_id: Option<u64>,
    #[serde(default)]
    group: Option<String>,
    #[serde(default)]
    labels: Option<String>,
    #[serde(default)]
    key_path: Option<String>,
    #[serde(default)]
    runner_count: Option<u32>,
    #[serde(default)]
    job_cpus: Option<u32>,
    #[serde(default)]
    job_memory_gib: Option<u32>,
    #[serde(default)]
    work_disk_gib: Option<u32>,
    /// `update` only: the candidate exe and the sha256 the tray computed for it. Both are
    /// user-controlled; the helper checks its own copy against the hash.
    #[serde(default)]
    exe_path: Option<String>,
    #[serde(default)]
    sha256: Option<String>,
}

impl RawRequest {
    fn sizing(&self) -> Option<crate::wizard::Sizing> {
        Some(crate::wizard::Sizing {
            runner_count: self.runner_count?,
            job_cpus: self.job_cpus?,
            job_memory_gib: self.job_memory_gib?,
            work_disk_gib: self.work_disk_gib?,
            windows_runner_count: 0,
        })
    }

    fn has_sizing(&self) -> bool {
        self.runner_count.is_some()
            || self.job_cpus.is_some()
            || self.job_memory_gib.is_some()
            || self.work_disk_gib.is_some()
    }

    fn has_update(&self) -> bool {
        self.exe_path.is_some() || self.sha256.is_some()
    }

    fn update_ok(&self) -> bool {
        self.exe_path
            .as_deref()
            .is_some_and(|p| update::check_path(p).is_ok())
            && self.sha256.as_deref().is_some_and(update::sha_ok)
    }

    fn has_identity(&self) -> bool {
        self.org.is_some()
            || self.app_id.is_some()
            || self.installation_id.is_some()
            || self.group.is_some()
            || self.labels.is_some()
            || self.key_path.is_some()
    }

    fn identity_ok(&self) -> bool {
        let path_ok = |p: &String| {
            (4..=1024).contains(&p.len())
                && p.bytes().all(|b| b >= 0x20 && b != b'"')
                && p.as_bytes()[0].is_ascii_alphabetic()
                && p[1..].starts_with(":\\")
                && !p.contains("..")
        };
        self.org.as_deref().is_some_and(identity::slug_ok)
            && self.app_id.is_some_and(|n| n > 0)
            && self.installation_id.is_some_and(|n| n > 0)
            && self.group.as_deref().is_some_and(identity::slug_ok)
            && self
                .labels
                .as_deref()
                .is_some_and(|l| identity::parse_labels(l).is_ok_and(|v| v.join(",") == l))
            && self.key_path.as_ref().is_some_and(path_ok)
    }
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Pointer {
    schema: u32,
    id: String,
    verb: String,
    #[serde(default)]
    error: String,
}

struct Embedded {
    rel: &'static str,
    text: &'static str,
}

fn scripts() -> &'static [Embedded] {
    &[
        Embedded {
            rel: "installer/create-work-vhdx.ps1",
            text: include_str!("../../../installer/create-work-vhdx.ps1"),
        },
        Embedded {
            rel: "installer/mount-work-vhdx-task.xml",
            text: include_str!("../../../installer/mount-work-vhdx-task.xml"),
        },
        Embedded {
            rel: "distro/stage-into-distro.sh",
            text: include_str!("../../../distro/stage-into-distro.sh"),
        },
        Embedded {
            rel: "distro/Dockerfile",
            text: include_str!("../../../distro/Dockerfile"),
        },
        Embedded {
            rel: "distro/aap-runner-manager.service",
            text: include_str!("../../../distro/aap-runner-manager.service"),
        },
        Embedded {
            rel: "distro/aap-workdisk.service",
            text: include_str!("../../../distro/aap-workdisk.service"),
        },
        Embedded {
            rel: "distro/daemon.json",
            text: include_str!("../../../distro/daemon.json"),
        },
        Embedded {
            rel: "distro/docker-workdisk.conf",
            text: include_str!("../../../distro/docker-workdisk.conf"),
        },
        Embedded {
            rel: "distro/ephemeral-entry.sh",
            text: include_str!("../../../distro/ephemeral-entry.sh"),
        },
        Embedded {
            rel: "distro/evidence-host.sh",
            text: include_str!("../../../distro/evidence-host.sh"),
        },
        Embedded {
            rel: "distro/evidence.sh",
            text: include_str!("../../../distro/evidence.sh"),
        },
        Embedded {
            rel: "distro/manager.conf.example",
            text: include_str!("../../../distro/manager.conf.example"),
        },
        Embedded {
            rel: "distro/manager.sh",
            text: include_str!("../../../distro/manager.sh"),
        },
        Embedded {
            rel: "distro/mount-work-disk.sh",
            text: include_str!("../../../distro/mount-work-disk.sh"),
        },
        Embedded {
            rel: "distro/nftables.conf",
            text: include_str!("../../../distro/nftables.conf"),
        },
        Embedded {
            rel: "distro/sysbox-restart.conf",
            text: include_str!("../../../distro/sysbox-restart.conf"),
        },
        Embedded {
            rel: "distro/wsl.conf",
            text: include_str!("../../../distro/wsl.conf"),
        },
        Embedded {
            rel: "distro/aap-zccache.sh",
            text: include_str!("../../../distro/aap-zccache.sh"),
        },
        Embedded {
            rel: "distro/zccache-wrappers.json",
            text: include_str!("../../../distro/zccache-wrappers.json"),
        },
        Embedded {
            rel: "helper-run.ps1",
            text: include_str!("../../../installer/helper-run.ps1"),
        },
        Embedded {
            rel: "installer/install-host.ps1",
            text: include_str!("../../../installer/install-host.ps1"),
        },
        Embedded {
            rel: "installer/lock-acl.ps1",
            text: include_str!("../../../installer/lock-acl.ps1"),
        },
        Embedded {
            rel: "installer/mount-work-vhdx.ps1",
            text: include_str!("../../../installer/mount-work-vhdx.ps1"),
        },
        Embedded {
            rel: "distro/bootstrap.sh",
            text: include_str!("../../../distro/bootstrap.sh"),
        },
        Embedded {
            rel: "distro/labels.sh",
            text: include_str!("../../../distro/labels.sh"),
        },
        Embedded {
            rel: "distro/staging.sha256",
            text: include_str!("../../../distro/staging.sha256"),
        },
        Embedded {
            rel: "supervisor/install-supervisor.ps1",
            text: include_str!("../../../supervisor/install-supervisor.ps1"),
        },
        Embedded {
            rel: "supervisor/aap-runner-supervisor.ps1",
            text: include_str!("../../../supervisor/aap-runner-supervisor.ps1"),
        },
        Embedded {
            rel: "supervisor/aap-runner-supervisor-task.xml",
            text: include_str!("../../../supervisor/aap-runner-supervisor-task.xml"),
        },
    ]
}

fn valid_id(id: &str) -> bool {
    id.len() == 16 && id.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

fn allow_transition(from: &str, to: &str) -> bool {
    if from == to && matches!(from, "queued" | "running") {
        return true;
    }
    matches!(
        (from, to),
        ("", "queued")
            | ("queued", "running")
            | ("queued", "rejected")
            | ("running", "passed")
            | ("running", "failed")
            | ("running", "rejected")
    )
}

fn is_reparse(meta: &std::fs::Metadata) -> bool {
    meta.file_attributes() & REPARSE != 0
}

fn reparse_path(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok_and(|m| is_reparse(&m))
}

/// Create `path` as a real directory. A reparse point on any component is an error, and nothing
/// is created underneath it.
fn ensure_real_dir(path: &Path) -> io::Result<()> {
    let mut cur = PathBuf::new();
    for c in path.components() {
        cur.push(c);
        if matches!(c, Component::Prefix(_)) {
            continue;
        }
        match fs::symlink_metadata(&cur) {
            Ok(meta) if is_reparse(&meta) => {
                return Err(io::Error::other(format!("reparse point {}", cur.display())));
            }
            Ok(meta) if meta.is_dir() => {}
            Ok(_) => {
                return Err(io::Error::other(format!(
                    "not a directory {}",
                    cur.display()
                )));
            }
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                fs::create_dir(&cur)?;
                let meta = fs::symlink_metadata(&cur)?;
                if is_reparse(&meta) || !meta.is_dir() {
                    return Err(io::Error::other(format!("reparse point {}", cur.display())));
                }
            }
            Err(e) => return Err(e),
        }
    }
    Ok(())
}

fn job_dir(base: &Path, id: &str) -> PathBuf {
    base.join("jobs").join(id)
}

fn request_path(base: &Path, id: &str) -> PathBuf {
    base.join("inbox").join("jobs").join(format!("{id}.json"))
}

fn sanitize_step(step: &str) -> String {
    step.chars()
        .filter(|c| *c != '\n' && *c != '\r')
        .take(240)
        .collect()
}

fn read_status_file(path: &Path) -> Result<Option<JobStatus>, String> {
    if reparse_path(path) {
        return Err("reparse point".into());
    }
    let file = match File::open(path) {
        Ok(f) => f,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(e.to_string()),
    };
    let len = file.metadata().map_err(|e| e.to_string())?.len();
    if len > STATUS_MAX {
        return Err("status too large".into());
    }
    let mut text = String::new();
    file.take(STATUS_MAX + 1)
        .read_to_string(&mut text)
        .map_err(|e| e.to_string())?;
    if text.len() as u64 > STATUS_MAX {
        return Err("status too large".into());
    }
    serde_json::from_str(&text)
        .map(Some)
        .map_err(|e| e.to_string())
}

fn advance(
    dir: &Path,
    id: &str,
    verb: &str,
    to: &str,
    step: &str,
    exit_code: Option<i32>,
) -> Result<(), String> {
    advance_with(dir, id, verb, to, step, exit_code, None)
}

fn advance_with(
    dir: &Path,
    id: &str,
    verb: &str,
    to: &str,
    step: &str,
    exit_code: Option<i32>,
    sha256: Option<&str>,
) -> Result<(), String> {
    if !valid_id(id) {
        return Err("bad id".into());
    }
    let path = dir.join("status.json");
    let from = match read_status_file(&path)? {
        Some(st) => {
            if st.schema != 1 || st.id != id || st.verb != verb {
                return Err("status does not match this job".into());
            }
            st.state
        }
        None => String::new(),
    };
    if !allow_transition(&from, to) {
        return Err(format!("cannot go from {from} to {to}"));
    }
    let status = JobStatus {
        schema: 1,
        id: id.to_string(),
        verb: verb.to_string(),
        state: to.to_string(),
        step: sanitize_step(step),
        exit_code,
        sha256: sha256.map(str::to_string),
    };
    let mut bytes = serde_json::to_vec(&status).map_err(|e| e.to_string())?;
    bytes.push(b'\n');
    state::write_atomic(&path, &bytes).map_err(|e| e.to_string())?;
    if matches!(to, "passed" | "failed" | "rejected") {
        let code = exit_code.unwrap_or(if to == "passed" { 0 } else { 1 });
        let mut exit_bytes = code.to_string().into_bytes();
        exit_bytes.push(b'\n');
        state::write_atomic(&dir.join("exit.txt"), &exit_bytes).map_err(|e| e.to_string())?;
    }
    Ok(())
}

fn parse_request(bytes: &[u8], argv_verb: &str, argv_id: &str) -> Result<Verb, String> {
    if bytes.len() as u64 > REQUEST_MAX {
        return Err("request too large".into());
    }
    let raw: RawRequest =
        serde_json::from_slice(bytes).map_err(|_| "request rejected".to_string())?;
    if raw.schema != if argv_verb == "install" { 2 } else { 1 } {
        return Err("request schema".into());
    }
    if !valid_id(&raw.id) || raw.id != argv_id {
        return Err("request id".into());
    }
    let Some(verb) = Verb::parse(&raw.verb) else {
        return Err("request verb".into());
    };
    if verb.as_str() != argv_verb {
        return Err("request verb".into());
    }
    match verb {
        Verb::Install
            if !raw.identity_ok()
                || !raw.sizing().is_some_and(|s| s.check_shape().is_ok())
                || raw.group.as_deref() != Some(identity::GROUP_DEFAULT)
                || raw.labels.as_deref() != Some(identity::LABELS_DEFAULT) =>
        {
            return Err("request install".into());
        }
        v if v != Verb::Update && raw.has_update() => return Err("request rejected".into()),
        Verb::Update if raw.has_identity() || raw.has_sizing() || !raw.update_ok() => {
            return Err("request update".into());
        }
        v if v != Verb::Install && raw.has_sizing() => return Err("request rejected".into()),
        Verb::Identity if !raw.identity_ok() => return Err("request identity".into()),
        Verb::Verify | Verb::Repair if raw.has_identity() => return Err("request rejected".into()),
        _ => {}
    }
    Ok(verb)
}

enum ReqRead {
    Missing,
    Bad(String),
    /// The verb, plus `(exe_path, sha256)` for `update`, taken from the same bytes.
    Ready(Verb, Option<(String, String)>),
}

fn read_request(path: &Path, argv_verb: &str, argv_id: &str) -> ReqRead {
    let want = format!("{argv_id}.json");
    if path.file_name().and_then(|s| s.to_str()) != Some(want.as_str()) {
        return ReqRead::Bad("request name".into());
    }
    match fs::symlink_metadata(path) {
        Err(e) if e.kind() == io::ErrorKind::NotFound => return ReqRead::Missing,
        Err(e) => return ReqRead::Bad(e.to_string()),
        Ok(meta) if is_reparse(&meta) => return ReqRead::Bad("reparse point".into()),
        Ok(meta) if meta.len() > REQUEST_MAX => return ReqRead::Bad("request too large".into()),
        Ok(_) => {}
    }
    let file = match File::open(path) {
        Ok(f) => f,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return ReqRead::Missing,
        Err(e) => return ReqRead::Bad(e.to_string()),
    };
    let mut buf = Vec::new();
    if file.take(REQUEST_MAX + 1).read_to_end(&mut buf).is_err() {
        return ReqRead::Bad("request unreadable".into());
    }
    match parse_request(&buf, argv_verb, argv_id) {
        Ok(verb) => ReqRead::Ready(verb, update_fields(&buf)),
        Err(e) => ReqRead::Bad(e),
    }
}

/// Only called on bytes `parse_request` accepted.
fn update_fields(bytes: &[u8]) -> Option<(String, String)> {
    let raw: RawRequest = serde_json::from_slice(bytes).ok()?;
    Some((raw.exe_path?, raw.sha256?))
}

#[cfg(test)]
fn write_request(
    base: &Path,
    id: &str,
    verb: Verb,
    identity: Option<&identity::Valid>,
) -> io::Result<()> {
    write_request_with_size(base, id, verb, identity, None, None)
}

fn write_request_with_size(
    base: &Path,
    id: &str,
    verb: Verb,
    identity: Option<&identity::Valid>,
    sizing: Option<&crate::wizard::Sizing>,
    update: Option<&(String, String)>,
) -> io::Result<()> {
    let dir = base.join("inbox").join("jobs");
    if reparse_path(&dir) || reparse_path(&base.join("inbox")) || reparse_path(base) {
        return Err(io::Error::other("reparse point"));
    }
    if !dir.is_dir() {
        return Err(io::Error::new(io::ErrorKind::NotFound, "inbox\\jobs"));
    }
    let path = request_path(base, id);
    if reparse_path(&path) {
        return Err(io::Error::other("reparse point"));
    }
    let mut body = match (identity, update) {
        (Some(v), _) => identity::request_json(id, v),
        (None, Some((exe_path, sha256))) => serde_json::to_vec(&serde_json::json!({
            "schema": 1, "id": id, "verb": "update", "exe_path": exe_path, "sha256": sha256,
        }))
        .map_err(io::Error::other)?,
        (None, None) => {
            format!(r#"{{"schema":1,"id":"{id}","verb":"{}"}}"#, verb.as_str()).into_bytes()
        }
    };
    if let Some(s) = sizing {
        let mut value: serde_json::Value =
            serde_json::from_slice(&body).map_err(io::Error::other)?;
        value["schema"] = 2.into();
        value["verb"] = "install".into();
        value["runner_count"] = s.runner_count.into();
        value["job_cpus"] = s.job_cpus.into();
        value["job_memory_gib"] = s.job_memory_gib.into();
        value["work_disk_gib"] = s.work_disk_gib.into();
        body = serde_json::to_vec(&value).map_err(io::Error::other)?;
    }
    state::write_atomic(&path, &body)
}

fn pointer_path() -> PathBuf {
    #[cfg(test)]
    {
        let override_dir = POINTER_DIR.with(|d| d.borrow().clone());
        if let Some(dir) = override_dir {
            return dir.join("helper.json");
        }
    }
    std::env::temp_dir()
        .join("aap-runner-tray")
        .join("helper.json")
}

fn write_pointer(id: &str, verb: Verb, error: &str) -> Result<(), String> {
    register_id(id); // record this id so load_job_from can detect stale results
    let path = pointer_path();
    let Some(dir) = path.parent() else {
        return Err("pointer path".into());
    };
    if reparse_path(dir) {
        return Err("reparse point".into());
    }
    if !dir.exists() {
        fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    let pointer = Pointer {
        schema: 1,
        id: id.to_string(),
        verb: verb.as_str().to_string(),
        error: sanitize_step(error),
    };
    let mut bytes = serde_json::to_vec(&pointer).map_err(|e| e.to_string())?;
    bytes.push(b'\n');
    state::write_atomic(&path, &bytes).map_err(|e| e.to_string())
}

fn log_tail(path: &Path) -> Vec<String> {
    if reparse_path(path) {
        return Vec::new();
    }
    let Ok(mut file) = File::open(path) else {
        return Vec::new();
    };
    let Ok(len) = file.metadata().map(|m| m.len()) else {
        return Vec::new();
    };
    let skipped = len > LOG_TAIL_BYTES;
    if skipped {
        let _ = file.seek(SeekFrom::End(-(LOG_TAIL_BYTES as i64)));
    }
    let mut buf = String::new();
    if file
        .take(LOG_TAIL_BYTES + 1)
        .read_to_string(&mut buf)
        .is_err()
    {
        return Vec::new();
    }
    let mut lines: Vec<String> = buf.lines().map(str::to_string).collect();
    if skipped && !lines.is_empty() {
        lines.remove(0);
    }
    let start = lines.len().saturating_sub(12);
    lines.split_off(start)
}

/// `Some(true)` when the log has a `PASS <row>` line, `Some(false)` on `FAIL <row>`, else `None`.
/// The whole log is read (it is capped at [`LOG_CAP`]); the last such line wins.
fn log_row(path: &Path, row: &str) -> Option<bool> {
    if reparse_path(path) {
        return None;
    }
    let mut text = String::new();
    File::open(path)
        .ok()?
        .take(LOG_CAP)
        .read_to_string(&mut text)
        .ok()?;
    let pass = format!("PASS {row}");
    let fail = format!("FAIL {row}");
    text.lines().rev().find_map(|line| {
        if line.starts_with(&pass) {
            Some(true)
        } else if line.starts_with(&fail) {
            Some(false)
        } else {
            None
        }
    })
}

/// What the window shows for the latest helper action. `pointer` is the temp file the tray
/// writes; `base` is the data directory the job folder lives under.
pub fn load_job_from(pointer: &Path, base: &Path) -> Option<JobUi> {
    if reparse_path(pointer) {
        return None;
    }
    let text = state::read_bounded(pointer)?;
    if text.len() > REQUEST_MAX as usize {
        return None;
    }
    let raw: Pointer = serde_json::from_str(&text).ok()?;
    if raw.schema != 1 || !valid_id(&raw.id) || Verb::parse(&raw.verb).is_none() {
        return None;
    }
    // Reject stale results from a previous process: this process never issued that id. The
    // one exception is an update the tray asked for just before it quit: the window shows it
    // from the admin-only job folder.
    if !is_issued_id(&raw.id) {
        return (raw.verb == "update" && recent(pointer))
            .then(|| protected_job(base, &raw.id, Verb::Update))
            .flatten();
    }
    if !raw.error.is_empty() {
        return Some(JobUi {
            verb: raw.verb,
            state: "declined".into(),
            step: raw.error,
            exit_code: None,
            lines: Vec::new(),
            app_token: None,
        });
    }
    let dir = job_dir(base, &raw.id);
    let status = read_status_file(&dir.join("status.json")).ok()??;
    if status.schema != 1 || status.id != raw.id || status.verb != raw.verb {
        return None;
    }
    let app_token = if raw.verb == "verify" && matches!(status.state.as_str(), "passed" | "failed")
    {
        log_row(&dir.join("log.txt"), "app-token")
    } else {
        None
    };
    Some(JobUi {
        verb: raw.verb,
        state: status.state,
        step: status.step,
        exit_code: status.exit_code,
        lines: log_tail(&dir.join("log.txt")),
        app_token,
    })
}

pub fn load_job(base: &Path) -> Option<JobUi> {
    load_job_from(&pointer_path(), base)
}

/// How long after the tray wrote an update pointer the window keeps watching it.
const UPDATE_WATCH: Duration = Duration::from_secs(15 * 60);
/// A helper that never wrote a result (it died early): restart the tray anyway after this.
const UPDATE_GIVE_UP: Duration = Duration::from_secs(4 * 60);

fn pointer_age(pointer: &Path) -> Option<Duration> {
    fs::metadata(pointer).ok()?.modified().ok()?.elapsed().ok()
}

fn recent(pointer: &Path) -> bool {
    pointer_age(pointer).is_some_and(|age| age < UPDATE_WATCH)
}

/// The update the tray handed off before it quit, as the window sees it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct UpdateWatch {
    pub finished: bool,
    pub running: bool,
    pub age: Duration,
}

/// How long the elevated confirmation box waits for Yes; no answer is No.
const CONFIRM_WAIT: Duration = Duration::from_secs(5 * 60);

/// `ask()` on its own thread; `false` unless it answers `true` within `bound`. An abandoned box
/// stays until the helper exits, which it does right after refusing.
fn answer_within(bound: Duration, ask: impl FnOnce() -> bool + Send + 'static) -> bool {
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        let _ = tx.send(ask());
    });
    rx.recv_timeout(bound).unwrap_or(false)
}

/// `None` unless the pointer names an update written in the last [`UPDATE_WATCH`]. While it
/// is `Some` the window does not close for a missing tray.
pub fn update_watch(base: &Path) -> Option<UpdateWatch> {
    let pointer = pointer_path();
    let age = pointer_age(&pointer).filter(|age| *age < UPDATE_WATCH)?;
    let raw: Pointer = serde_json::from_str(&state::read_bounded(&pointer)?).ok()?;
    if raw.schema != 1 || raw.verb != "update" || !raw.error.is_empty() || !valid_id(&raw.id) {
        return None;
    }
    let state = protected_job(base, &raw.id, Verb::Update).map(|j| j.state);
    Some(UpdateWatch {
        finished: state
            .as_deref()
            .is_some_and(|s| matches!(s, "passed" | "failed" | "rejected")),
        running: state.as_deref() == Some("running"),
        age,
    })
}

/// Restart the installed tray once the update finished either way (a refused update must bring
/// the old build back), or after [`UPDATE_GIVE_UP`] without a result. Never while a tray runs.
/// A running job (the confirmation box may be open, then the swap) gets [`CONFIRM_WAIT`] more,
/// so the old tray is not restarted under an update that is still deciding.
pub fn relaunch_due(watch: UpdateWatch, tray_free: bool) -> bool {
    let give_up = if watch.running {
        UPDATE_GIVE_UP + CONFIRM_WAIT
    } else {
        UPDATE_GIVE_UP
    };
    tray_free && (watch.finished || watch.age >= give_up)
}

pub fn issued_install_id() -> Option<String> {
    let raw: Pointer = serde_json::from_str(&state::read_bounded(&pointer_path())?).ok()?;
    (raw.verb == "install" && is_issued_id(&raw.id)).then_some(raw.id)
}

/// Write the request when `inbox\jobs` already exists, record the id for the window, and ask
/// Windows for one UAC prompt. If the folder does not exist yet, a background thread writes the
/// request once the elevated helper has created it.
fn refuse_elevation(verb: Verb, message: &str) -> Result<(), String> {
    if let Ok(id) = win::random_id() {
        let _ = write_pointer(&id, verb, message);
    }
    Err(message.to_string())
}

#[cfg(test)]
thread_local! {
    static CAPTURE_RUNAS: Cell<bool> = const { Cell::new(false) };
    static CAPTURED_RUNAS: RefCell<Option<PathBuf>> = const { RefCell::new(None) };
    /// Override for `pointer_path()` so tests never write to the real per-user temp file.
    static POINTER_DIR: RefCell<Option<PathBuf>> = const { RefCell::new(None) };
}

fn directory_gate_enabled() -> bool {
    #[cfg(test)]
    {
        if CAPTURE_RUNAS.with(Cell::get) {
            return false;
        }
    }
    true
}

fn start_runas(exe: &Path, parameters: &str) -> Result<(), String> {
    #[cfg(test)]
    {
        if CAPTURE_RUNAS.with(Cell::get) {
            CAPTURED_RUNAS.with(|slot| *slot.borrow_mut() = Some(exe.to_path_buf()));
            let _ = parameters;
            return Ok(());
        }
    }
    if let Some(id) = parameters.strip_prefix("--helper install ") {
        let id = id.to_string();
        let process = win::shell_execute_runas_observed(exe, parameters, move |code| {
            let path = pointer_path();
            let ours = state::read_bounded(&path)
                .and_then(|s| serde_json::from_str::<Pointer>(&s).ok())
                .is_some_and(|p| p.id == id);
            let completed =
                read_status_file(&job_dir(Path::new(DATA_DIR), &id).join("status.json"))
                    .ok()
                    .flatten()
                    .is_some_and(|s| matches!(s.state.as_str(), "passed" | "failed" | "rejected"));
            if ours && !completed {
                let _ = write_pointer(
                    &id,
                    Verb::Install,
                    &format!(
                        "Installer exited ({code}) before writing a result. Use the same administrator account, check ProgramData folder permissions, and retry."
                    ),
                );
            }
        })?;
        if let Ok(mut slot) = INSTALL_PROCESS.lock() {
            *slot = process;
        }
        Ok(())
    } else {
        win::shell_execute_runas(exe, parameters)
    }
}

pub fn launch(base: &Path, verb: Verb) -> Result<(), String> {
    launch_with(base, verb, None)
}

/// The identity page's Apply: the same prompt and job folder as Verify, with the fields in the request.
pub fn launch_identity(base: &Path, fields: &identity::Valid) -> Result<(), String> {
    launch_with(base, Verb::Identity, Some(fields.clone()))
}

pub fn launch_install(
    base: &Path,
    fields: &identity::Valid,
    sizing: &crate::wizard::Sizing,
) -> Result<(), String> {
    sizing.check_shape()?;
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let resolved = win::resolve_exe(&exe).map_err(|e| e.to_string())?;
    launch_payload(
        base,
        Verb::Install,
        resolved,
        Some(fields.clone()),
        Some(sizing.clone()),
        None,
    )
}

/// Tray menu "Update tray…": hash the picked build and ask the helper to install it. Only the
/// installed tray asks (the helper re-checks). The request must be written before the prompt,
/// because the caller quits right after this returns `Ok`.
pub fn launch_update(base: &Path, candidate: &Path) -> Result<(), String> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let resolved = win::resolve_exe(&exe).map_err(|e| e.to_string())?;
    update::check_self(&resolved.path, Path::new(update::INSTALL_DIR))?;
    let path = candidate
        .to_str()
        .ok_or("candidate path is not valid text")?
        .to_string();
    update::check_path(&path)?;
    // The helper repeats this; checking here gives the owner the reason before the prompt.
    let user = win::current_user_sid().map_err(|e| e.to_string())?;
    drop(update::open_candidate(
        &path,
        update::private_location(&user),
    )?);
    let sha = update::sha256_file(candidate)?;
    launch_payload(base, Verb::Update, resolved, None, None, Some((path, sha)))
}

fn launch_with(base: &Path, verb: Verb, identity: Option<identity::Valid>) -> Result<(), String> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let resolved = match win::resolve_exe(&exe) {
        Ok(opened) => opened,
        Err(e) => {
            return refuse_elevation(verb, &format!("could not read the tray exe ACL: {e}"));
        }
    };
    // runas gets the handle-resolved path, not the path this process was started from.
    launch_resolved(base, verb, resolved, identity)
}

fn not_fixed_drive_msg(path: &Path, drive_type: u32) -> String {
    format!(
        "tray exe is not on a fixed local drive: {} (drive type {drive_type})",
        path.display()
    )
}

fn launch_resolved(
    base: &Path,
    verb: Verb,
    resolved: win::ResolvedExe,
    identity: Option<identity::Valid>,
) -> Result<(), String> {
    launch_payload(base, verb, resolved, identity, None, None)
}

fn launch_payload(
    base: &Path,
    verb: Verb,
    resolved: win::ResolvedExe,
    identity: Option<identity::Valid>,
    sizing: Option<crate::wizard::Sizing>,
    update: Option<(String, String)>,
) -> Result<(), String> {
    let path = resolved.path;
    if !win::is_fixed_local_path(&path) {
        let dt = win::drive_type_of(&path).unwrap_or(0);
        return refuse_elevation(verb, &not_fixed_drive_msg(&path, dt));
    }
    let Some(dir) = path.parent().map(std::path::Path::to_path_buf) else {
        return refuse_elevation(verb, USER_WRITABLE_EXE_DIR);
    };
    let bootstrap_user = if verb == Verb::Install {
        Some(win::current_user_sid().map_err(|e| e.to_string())?)
    } else {
        None
    };
    if !allowed_for_verb(&acl_view(resolved.acl), bootstrap_user.as_deref(), false) {
        return refuse_elevation(verb, USER_WRITABLE_EXE_DIR);
    }
    if directory_gate_enabled()
        && let Err(e) = check_exe_directories(&dir, bootstrap_user.as_deref())
    {
        return refuse_elevation(verb, &e);
    }
    let id = win::random_id().map_err(|e| e.to_string())?;
    write_pointer(&id, verb, "")?;
    let wrote = write_request_with_size(
        base,
        &id,
        verb,
        identity.as_ref(),
        sizing.as_ref(),
        update.as_ref(),
    )
    .is_ok();
    if verb == Verb::Update && !wrote {
        return refuse_elevation(
            verb,
            "could not write the update request; run Repair install",
        );
    }
    // `update` also carries the expected sha256 on the command line; the helper requires the
    // request and the staged copy to match it.
    let parameters = match &update {
        Some((_, sha)) => format!("--helper update {id} {sha}"),
        None => format!("--helper {} {id}", verb.as_str()),
    };
    if let Err(e) = start_runas(&path, &parameters) {
        let _ = write_pointer(&id, verb, &e);
        return Err(e);
    }
    if !wrote {
        let base = base.to_path_buf();
        thread::spawn(move || {
            let deadline = Instant::now() + REQUEST_WAIT;
            while Instant::now() < deadline {
                if write_request_with_size(
                    &base,
                    &id,
                    verb,
                    identity.as_ref(),
                    sizing.as_ref(),
                    None,
                )
                .is_ok()
                {
                    return;
                }
                thread::sleep(Duration::from_millis(200));
            }
            state::log(&base, "helper request was not written");
        });
    }
    Ok(())
}

fn materialize(dir: &Path) -> Result<(), String> {
    ensure_real_dir(dir).map_err(|e| e.to_string())?;
    for script in scripts() {
        if script
            .rel
            .split(['/', '\\'])
            .any(|p| p == ".." || p.is_empty())
        {
            return Err("script path".into());
        }
        let path = dir.join(script.rel);
        let Some(parent) = path.parent() else {
            return Err("script path".into());
        };
        ensure_real_dir(parent).map_err(|e| e.to_string())?;
        if reparse_path(&path) {
            return Err("reparse point".into());
        }
        fs::write(&path, script.text.as_bytes()).map_err(|e| e.to_string())?;
        let back = fs::read(&path).map_err(|e| e.to_string())?;
        if back != script.text.as_bytes() {
            return Err(format!("script changed on disk: {}", script.rel));
        }
    }
    Ok(())
}

fn ensure_request_dir(scripts_dir: &Path) -> Result<(), String> {
    let ps1 = scripts_dir
        .join("supervisor")
        .join("install-supervisor.ps1");
    let mut cmd = Command::new(POWERSHELL);
    cmd.args([
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
    ])
    .arg(&ps1)
    .args(["-EnsureRequestDir", "-DataDir", DATA_DIR])
    .stdin(Stdio::null())
    .stdout(Stdio::piped())
    .stderr(Stdio::piped())
    .creation_flags(CREATE_NO_WINDOW);
    harden_powershell(&mut cmd).map_err(|e| e.to_string())?;
    let out = cmd.output().map_err(|e| e.to_string())?;
    if out.status.success() {
        return Ok(());
    }
    let err = String::from_utf8_lossy(&out.stderr);
    let err = err.trim();
    let err = if err.chars().count() > 240 {
        err.chars().take(240).collect()
    } else {
        err.to_string()
    };
    Err(if err.is_empty() {
        format!("could not prepare inbox\\jobs (exit {})", out.status)
    } else {
        err
    })
}

pub(crate) fn exe_ok(path: &str) -> bool {
    if path.len() < 7 || path.contains("..") || path.contains('"') || !path.ends_with(".exe") {
        return false;
    }
    let mut chars = path.chars();
    if !chars.next().is_some_and(|c| c.is_ascii_alphabetic()) {
        return false;
    }
    let Some(rest) = path.get(1..) else {
        return false;
    };
    if !rest.starts_with(":\\") {
        return false;
    }
    rest[2..].bytes().all(|b| {
        matches!(b, b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b' ' | b'_' | b'.' | b'\\' | b'-')
    })
}

fn tray_exe_arg() -> Option<String> {
    let exe = std::env::current_exe().ok()?;
    let text = exe.to_string_lossy();
    exe_ok(&text).then(|| text.into_owned())
}

fn append_log(path: &Path, line: &str) -> io::Result<()> {
    if reparse_path(path) {
        return Err(io::Error::other("reparse point"));
    }
    if path.metadata().is_ok_and(|m| m.len() >= LOG_CAP) {
        return Ok(());
    }
    let mut file = OpenOptions::new().create(true).append(true).open(path)?;
    writeln!(file, "{line}")
}

fn stream_child(
    child: &mut std::process::Child,
    log: &Path,
    mut on_line: impl FnMut(&str),
) -> io::Result<()> {
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| io::Error::other("no stdout"))?;
    let stderr = child
        .stderr
        .take()
        .ok_or_else(|| io::Error::other("no stderr"))?;
    let (tx, rx) = mpsc::channel::<String>();
    let tx_out = tx.clone();
    let tx_err = tx.clone();
    drop(tx);
    let out = thread::spawn(move || pipe_lines(stdout, tx_out));
    let err = thread::spawn(move || pipe_lines(stderr, tx_err));
    for line in rx {
        append_log(log, &line)?;
        on_line(&line);
    }
    let _ = out.join();
    let _ = err.join();
    Ok(())
}

fn pipe_lines(reader: impl Read, tx: mpsc::Sender<String>) {
    let mut buf = String::new();
    let mut reader = BufReader::new(reader);
    while reader.read_line(&mut buf).unwrap_or(0) > 0 {
        let line: String = buf
            .trim_end_matches(['\r', '\n'])
            .chars()
            .take(2000)
            .collect();
        if tx.send(line).is_err() {
            return;
        }
        buf.clear();
    }
}

fn run_script(job: &Path, verb: Verb, tray: Option<&str>) -> io::Result<i32> {
    let script = job.join("scripts").join("helper-run.ps1");
    let id = job.file_name().and_then(|s| s.to_str()).unwrap_or("");
    if matches!(verb, Verb::Identity | Verb::Install) && !valid_id(id) {
        return Err(io::Error::other("bad id"));
    }
    let mut cmd = Command::new(POWERSHELL);
    cmd.args([
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
    ])
    .arg(&script)
    .args(["-Verb", verb.as_str(), "-DataDir", DATA_DIR]);
    if matches!(verb, Verb::Repair | Verb::Install)
        && let Some(exe) = tray
    {
        cmd.args(["-TrayExe", exe]);
    }
    if matches!(verb, Verb::Identity | Verb::Install) {
        cmd.args(["-Id", id]);
    }
    cmd.stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .creation_flags(CREATE_NO_WINDOW);
    harden_powershell(&mut cmd)?;
    let mut child = cmd.spawn()?;
    let log = job.join("log.txt");
    stream_child(&mut child, &log, |line| {
        if !line.is_empty() {
            let _ = advance(job, id, verb.as_str(), "running", line, None);
        }
    })?;
    let status = child.wait()?;
    Ok(status.code().unwrap_or(1))
}

/// Machine module path, System32-only PATH, and no inherited execution-policy preference.
fn harden_powershell(cmd: &mut Command) -> io::Result<()> {
    cmd.env("PSModulePath", win::machine_ps_module_path()?);
    cmd.env("PATH", SYSTEM32);
    cmd.env_remove("PSExecutionPolicyPreference");
    Ok(())
}

fn failure_step(log: &Path, code: i32) -> String {
    for line in log_tail(log).iter().rev() {
        if let Some(rest) = line.strip_prefix("FAIL ")
            && !rest.is_empty()
        {
            return sanitize_step(rest);
        }
    }
    format!("exit {code}")
}

fn fail_job(job: &Path, id: &str, verb: &str, to: &str, step: &str, code: i32) -> i32 {
    let _ = advance(job, id, verb, to, step, Some(code));
    code
}

/// The installed tray, checked like [`start_installed_tray`], and only when this helper runs
/// from exactly that file.
/// The words after `--helper`: `<verb> <id>`, or `update <id> <sha256>`. Nothing else.
pub fn parse_helper_args(args: &[String]) -> Option<(&str, &str, Option<&str>)> {
    match args {
        [verb, id] if verb != "update" => Some((verb, id, None)),
        [verb, id, sha] if verb == "update" && update::sha_ok(sha) => Some((verb, id, Some(sha))),
        _ => None,
    }
}

fn update_request_matches(fields: Option<&(String, String)>, argv_sha: &str) -> Result<(), String> {
    if fields.is_some_and(|(_, sha)| sha == argv_sha) {
        Ok(())
    } else {
        Err("request sha256 does not match the command line".into())
    }
}

fn update_target() -> Result<PathBuf, String> {
    let me = win::resolve_exe(&std::env::current_exe().map_err(|e| e.to_string())?)
        .map_err(|e| e.to_string())?;
    let dir = Path::new(update::INSTALL_DIR);
    let installed = update::check_self(&me.path, dir)?;
    if !win::is_fixed_local_path(&me.path) || !elevation_allowed(&acl_view(me.acl)) {
        return Err("installed tray is not protected".into());
    }
    check_exe_directories(dir, None)?;
    Ok(installed)
}

/// Copy, then hash and inspect only the copy, then swap. Refusals leave the old build in place.
fn run_update(
    job: &Path,
    id: &str,
    installed: &Path,
    fields: Option<(String, String)>,
    argv_sha: &str,
) -> i32 {
    let verb = Verb::Update.as_str();
    if let Err(e) = update_request_matches(fields.as_ref(), argv_sha) {
        return fail_job(job, id, verb, "rejected", &e, 2);
    }
    let Some((source, _)) = fields else {
        return fail_job(job, id, verb, "rejected", "request update", 2);
    };
    let log = job.join("log.txt");
    let note = |line: &str| {
        let _ = append_log(&log, line);
        let _ = advance(job, id, verb, "running", line, None);
    };
    let refuse = |to: &str, e: String, code: i32| {
        let _ = append_log(&log, &format!("FAIL update {e}"));
        fail_job(job, id, verb, to, &e, code)
    };
    let staging = Path::new(update::INSTALL_DIR).join("staging");
    let staged = staging.join(format!("{id}.exe"));
    note("STEP copy candidate to staging");
    let verified = win::current_user_sid()
        .map_err(|e| e.to_string())
        .and_then(|user| {
            ensure_private_dir(&staging)?;
            update::copy_candidate(&source, &staged, update::private_location(&user))
        })
        .and_then(|()| require_admin_only(&staged, "staged tray"))
        .and_then(|()| {
            note("STEP verify staged copy");
            let installed_version = update::installed_version_of(installed)?;
            update::verify_staged(&staged, argv_sha, installed_version)
        })
        .and_then(|sha| {
            note("STEP confirm");
            let size = fs::metadata(&staged).map_err(|e| e.to_string())?.len();
            let text = update::confirm_text(&source, size, &sha);
            if answer_within(CONFIRM_WAIT, move || {
                win::confirm("AAP Runner update", &text)
            }) {
                Ok(sha)
            } else {
                Err("the update was declined, or not confirmed within 5 minutes".into())
            }
        })
        .and_then(|sha| {
            win::set_install_acl(&staged).map_err(|e| e.to_string())?;
            require_admin_only(&staged, "staged tray")?;
            Ok(sha)
        });
    let sha = match verified {
        Ok(sha) => sha,
        Err(e) => {
            let _ = fs::remove_file(&staged);
            return refuse("rejected", e, 2);
        }
    };
    note("STEP replace installed tray");
    if let Err(e) = update::swap_in(&staged, installed, update::RENAME_WAIT, win::set_prev_acl) {
        let _ = fs::remove_file(&staged);
        return refuse("failed", e, 1);
    }
    let _ = append_log(&log, &format!("PASS update installed sha256 {sha}"));
    let _ = advance_with(
        job,
        id,
        verb,
        "passed",
        &format!("installed sha256 {sha}"),
        Some(0),
        Some(&sha),
    );
    0
}

/// `--helper <verb> <id>` (`update` adds `<sha256>`). Always uses [`DATA_DIR`]. Ignores
/// `AAP_FAKE_BASE` and any path in the request. Returns the process exit code.
pub fn run_elevated(verb_arg: &str, id: &str, argv_sha: Option<&str>) -> i32 {
    let Some(verb) = Verb::parse(verb_arg) else {
        return 2;
    };
    if !valid_id(id) || (verb == Verb::Update) != argv_sha.is_some_and(update::sha_ok) {
        return 2;
    }
    // Running from the installed path means the build that replaced any `.prev` has started:
    // the old one is no longer needed as a fallback and should not stay startable.
    if let Ok(me) = std::env::current_exe().and_then(|e| win::resolve_exe(&e))
        && let Ok(installed) = update::check_self(&me.path, Path::new(update::INSTALL_DIR))
    {
        update::remove_prev(&installed);
    }
    let base = PathBuf::from(DATA_DIR);
    let job = job_dir(&base, id);
    // Every verb must establish the trust boundary before writing executable scripts.
    if ensure_admin_dir(&base)
        .and_then(|_| ensure_admin_dir(&base.join("jobs")))
        .and_then(|_| ensure_admin_dir(&job))
        .is_err()
    {
        return 2;
    }
    let update_target = if verb == Verb::Update {
        if advance(
            &job,
            id,
            verb.as_str(),
            "queued",
            "checking installed tray",
            None,
        )
        .is_err()
        {
            return 2;
        }
        match update_target() {
            Ok(path) => Some(path),
            Err(e) => return fail_job(&job, id, verb.as_str(), "rejected", &e, 2),
        }
    } else {
        None
    };
    let installed_exe = if verb == Verb::Install {
        if advance(
            &job,
            id,
            verb.as_str(),
            "queued",
            "checking installer",
            None,
        )
        .is_err()
        {
            return 2;
        }
        match prepare_install(&base, &job) {
            Ok(path) => Some(path),
            Err(e) => return fail_job(&job, id, verb.as_str(), "rejected", &e, 2),
        }
    } else {
        None
    };
    let scripts_dir = job.join("scripts");
    if let Err(e) = materialize(&scripts_dir) {
        return fail_job(&job, id, verb.as_str(), "rejected", &e, 2);
    }
    if advance(
        &job,
        id,
        verb.as_str(),
        "queued",
        "preparing request folder",
        None,
    )
    .is_err()
    {
        return 2;
    }
    if let Err(e) = ensure_request_dir(&scripts_dir) {
        return fail_job(&job, id, verb.as_str(), "rejected", &e, 2);
    }
    if advance(
        &job,
        id,
        verb.as_str(),
        "queued",
        "waiting for request",
        None,
    )
    .is_err()
    {
        return 2;
    }
    let path = request_path(&base, id);
    let deadline = Instant::now() + REQUEST_WAIT;
    let (got, fields) = loop {
        match read_request(&path, verb.as_str(), id) {
            ReqRead::Ready(v, fields) => break (v, fields),
            ReqRead::Missing => {
                if Instant::now() >= deadline {
                    return fail_job(
                        &job,
                        id,
                        verb.as_str(),
                        "rejected",
                        "request file did not appear",
                        2,
                    );
                }
                thread::sleep(Duration::from_millis(200));
            }
            ReqRead::Bad(e) => return fail_job(&job, id, verb.as_str(), "rejected", &e, 2),
        }
    };
    if advance(&job, id, got.as_str(), "running", "starting", None).is_err() {
        return 2;
    }
    if let (Verb::Update, Some(installed)) = (got, update_target) {
        return run_update(&job, id, &installed, fields, argv_sha.unwrap_or_default());
    }
    let tray = installed_exe.or_else(tray_exe_arg);
    match run_script(&job, got, tray.as_deref()) {
        Ok(0) => fail_job(&job, id, got.as_str(), "passed", "done", 0),
        Ok(code) => fail_job(
            &job,
            id,
            got.as_str(),
            "failed",
            &failure_step(&job.join("log.txt"), code),
            code,
        ),
        Err(e) => fail_job(&job, id, got.as_str(), "failed", &e.to_string(), 1),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp() -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "aap-helper-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn ids_are_sixteen_lowercase_hex_digits() {
        assert!(valid_id("0123456789abcdef"));
        assert!(!valid_id("0123456789ABCDEF"));
        assert!(!valid_id("0123456789abcde"));
        assert!(!valid_id("0123456789abcdef0"));
        assert!(!valid_id("../0123456789ab"));
        assert!(!valid_id("0123456789abcde."));
        assert!(!valid_id(""));
    }

    #[test]
    fn requests_keep_only_schema_verb_and_id() {
        let id = "0123456789abcdef";
        let ok = format!(r#"{{"schema":1,"id":"{id}","verb":"verify"}}"#);
        assert_eq!(
            parse_request(ok.as_bytes(), "verify", id).unwrap(),
            Verb::Verify
        );
        let repair = format!(r#"{{"schema":1,"id":"{id}","verb":"repair"}}"#);
        assert_eq!(
            parse_request(repair.as_bytes(), "repair", id).unwrap(),
            Verb::Repair
        );
        let path = format!(r#"{{"schema":1,"id":"{id}","verb":"verify","path":"C:\\wsl"}}"#);
        assert!(parse_request(path.as_bytes(), "verify", id).is_err());
        assert!(
            parse_request(ok.as_bytes(), "repair", id).is_err(),
            "verb must match argv"
        );
        assert!(parse_request(ok.as_bytes(), "verify", "0000000000000000").is_err());
        let schema = format!(r#"{{"schema":2,"id":"{id}","verb":"verify"}}"#);
        assert!(parse_request(schema.as_bytes(), "verify", id).is_err());
        let install = format!(r#"{{"schema":1,"id":"{id}","verb":"install"}}"#);
        assert!(parse_request(install.as_bytes(), "install", id).is_err());
        assert!(parse_request(&vec![b'x'; 4097], "verify", id).is_err());
        let with_org = format!(r#"{{"schema":1,"id":"{id}","verb":"verify","org":"acme"}}"#);
        assert!(
            parse_request(with_org.as_bytes(), "verify", id).is_err(),
            "identity fields on verify"
        );
    }

    const SHA: &str = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";

    fn update_request(id: &str, exe_path: &str, sha256: &str) -> Vec<u8> {
        serde_json::to_vec(&serde_json::json!({
            "schema": 1, "id": id, "verb": "update", "exe_path": exe_path, "sha256": sha256,
        }))
        .unwrap()
    }

    #[test]
    fn helper_arguments_carry_a_sha256_only_for_update() {
        let args = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        let id = "0123456789abcdef";
        assert_eq!(
            parse_helper_args(&args(&["verify", id])),
            Some(("verify", id, None))
        );
        assert_eq!(
            parse_helper_args(&args(&["update", id, SHA])),
            Some(("update", id, Some(SHA)))
        );
        for bad in [
            args(&["update", id]),
            args(&["verify", id, SHA]),
            args(&["update", id, &SHA.to_uppercase()]),
            args(&["update", id, &SHA[..63]]),
            args(&["update", id, SHA, "x"]),
            args(&["verify"]),
            args(&[]),
        ] {
            assert_eq!(parse_helper_args(&bad), None, "{bad:?}");
        }
    }

    #[test]
    fn the_request_hash_must_equal_the_command_line_hash() {
        let exe = r"C:\Users\me\Downloads\aap-runner-tray.exe".to_string();
        assert!(update_request_matches(Some(&(exe.clone(), SHA.to_string())), SHA).is_ok());
        assert!(update_request_matches(Some(&(exe, "0".repeat(64))), SHA).is_err());
        assert!(update_request_matches(None, SHA).is_err());
    }

    #[test]
    fn an_update_request_needs_a_plain_exe_path_and_a_sha256() {
        let id = "0123456789abcdef";
        let exe = r"C:\Users\me\Downloads\aap-runner-tray.exe";
        let ok = update_request(id, exe, SHA);
        assert_eq!(parse_request(&ok, "update", id).unwrap(), Verb::Update);
        assert_eq!(update_fields(&ok), Some((exe.to_string(), SHA.to_string())));
        assert!(
            parse_request(&ok, "verify", id).is_err(),
            "verb must match argv"
        );
        assert!(
            parse_request(&ok, "update", "0000000000000000").is_err(),
            "id must match argv"
        );
        let mut value: serde_json::Value = serde_json::from_slice(&ok).unwrap();
        value["schema"] = 2.into();
        assert!(parse_request(&serde_json::to_vec(&value).unwrap(), "update", id).is_err());
        for (path, sha) in [
            (r"\\server\share\aap-runner-tray.exe", SHA),
            (r"\\?\C:\Users\me\aap-runner-tray.exe", SHA),
            (r"\\.\C:\Users\me\aap-runner-tray.exe", SHA),
            (r"C:\Users\me\aap-runner-tray.exe:ads", SHA),
            (r"C:\Users\..\aap-runner-tray.exe", SHA),
            (r"C:\Users\me\CON.exe", SHA),
            (r"Users\me\aap-runner-tray.exe", SHA),
            (exe, &SHA[..63]),
            (exe, &SHA.to_uppercase()),
            (exe, ""),
        ] {
            assert!(
                parse_request(&update_request(id, path, sha), "update", id).is_err(),
                "{path} {sha}"
            );
        }
        for key in ["exe_path", "sha256"] {
            let mut missing = value.clone();
            missing["schema"] = 1.into();
            missing.as_object_mut().unwrap().remove(key);
            assert!(
                parse_request(&serde_json::to_vec(&missing).unwrap(), "update", id).is_err(),
                "{key} missing"
            );
        }
        for (key, extra) in [
            ("org", serde_json::json!("acme")),
            ("runner_count", serde_json::json!(1)),
            ("path", serde_json::json!(r"C:\x")),
        ] {
            let mut more = value.clone();
            more["schema"] = 1.into();
            more[key] = extra;
            assert!(
                parse_request(&serde_json::to_vec(&more).unwrap(), "update", id).is_err(),
                "{key} on update"
            );
        }
        let verify = format!(r#"{{"schema":1,"id":"{id}","verb":"verify","sha256":"{SHA}"}}"#);
        assert!(
            parse_request(verify.as_bytes(), "verify", id).is_err(),
            "update fields on verify"
        );
        let bare = format!(r#"{{"schema":1,"id":"{id}","verb":"update"}}"#);
        assert!(parse_request(bare.as_bytes(), "update", id).is_err());
    }

    #[test]
    fn the_tray_writes_the_update_request_the_helper_accepts() {
        let base = temp();
        fs::create_dir_all(base.join("inbox/jobs")).unwrap();
        let id = "abababababababab";
        let fields = (
            r"C:\Users\me\Downloads\aap-runner-tray.exe".to_string(),
            SHA.to_string(),
        );
        write_request_with_size(&base, id, Verb::Update, None, None, Some(&fields)).unwrap();
        let bytes = fs::read(request_path(&base, id)).unwrap();
        assert_eq!(parse_request(&bytes, "update", id).unwrap(), Verb::Update);
        assert_eq!(update_fields(&bytes), Some(fields));
        let _ = fs::remove_dir_all(base);
    }

    #[test]
    fn a_user_written_update_job_is_not_shown_or_trusted() {
        let base = temp();
        let id = "cdcdcdcdcdcdcdcd";
        let dir = job_dir(&base, id);
        fs::create_dir_all(&dir).unwrap();
        advance(&dir, id, "update", "queued", "waiting", None).unwrap();
        advance(&dir, id, "update", "running", "x", None).unwrap();
        advance_with(
            &dir,
            id,
            "update",
            "passed",
            "installed sha256 x",
            Some(0),
            Some(SHA),
        )
        .unwrap();
        let text = fs::read_to_string(dir.join("status.json")).unwrap();
        assert!(text.contains(&format!(r#""sha256":"{SHA}""#)), "{text}");
        let pointer = base.join("helper.json");
        fs::write(
            &pointer,
            format!(r#"{{"schema":1,"id":"{id}","verb":"update","error":""}}"#),
        )
        .unwrap();
        // Not issued by this process, and the job folder is user-writable: ignored.
        assert!(load_job_from(&pointer, &base).is_none());
        assert!(protected_job(&base, id, Verb::Update).is_none());
        let _ = fs::remove_dir_all(base);
    }

    #[test]
    fn the_window_waits_for_a_running_job_up_to_the_confirmation_bound() {
        let running = |secs| UpdateWatch {
            finished: false,
            running: true,
            age: Duration::from_secs(secs),
        };
        assert!(
            !relaunch_due(running(4 * 60), true),
            "the confirmation box may still be open"
        );
        assert!(!relaunch_due(running(9 * 60 - 1), true));
        assert!(
            relaunch_due(running(9 * 60), true),
            "a hung helper: give up"
        );
        assert!(
            UPDATE_GIVE_UP + CONFIRM_WAIT + Duration::from_secs(60) < UPDATE_WATCH,
            "the window still watches when the box bound runs out"
        );
    }

    #[test]
    fn an_unanswered_question_is_a_no() {
        assert!(answer_within(Duration::from_secs(5), || true));
        assert!(!answer_within(Duration::from_secs(5), || false));
        let started = Instant::now();
        assert!(!answer_within(Duration::from_millis(50), || {
            thread::sleep(Duration::from_secs(2));
            true
        }));
        assert!(
            started.elapsed() < Duration::from_secs(1),
            "the bound, not the answer"
        );
    }

    #[test]
    fn the_window_restarts_the_tray_once_the_update_is_over() {
        let at = |finished, secs| UpdateWatch {
            finished,
            running: false,
            age: Duration::from_secs(secs),
        };
        assert!(
            relaunch_due(at(true, 5), true),
            "finished, passed or refused"
        );
        assert!(
            !relaunch_due(at(true, 5), false),
            "a tray is already running"
        );
        assert!(!relaunch_due(at(false, 5), true), "still running");
        assert!(
            relaunch_due(at(false, 4 * 60), true),
            "no result: give up and restart"
        );
    }

    fn identity_fields() -> identity::Valid {
        identity::Valid {
            org: "acme".into(),
            app_id: 123,
            installation_id: 456,
            group: "aap-crrr".into(),
            labels: "self-hosted,linux,crrr".into(),
            key_path: r"C:\Users\me\Downloads\k.pem".into(),
        }
    }

    #[test]
    fn wizard_install_requests_never_carry_a_windows_count() {
        let base = temp();
        fs::create_dir_all(base.join("inbox/jobs")).unwrap();
        let id = "adadadadadadadad";
        let draft = crate::wizard::Sizing {
            runner_count: 2,
            windows_runner_count: 3,
            ..crate::wizard::Sizing::default()
        };
        // What the wizard sends (`linux()`), and even the raw draft: only the fixed keys.
        for sizing in [draft.linux(), draft] {
            write_request_with_size(
                &base,
                id,
                Verb::Install,
                Some(&identity_fields()),
                Some(&sizing),
                None,
            )
            .unwrap();
            let text = fs::read_to_string(request_path(&base, id)).unwrap();
            assert!(!text.contains("windows"), "{text}");
            assert_eq!(
                parse_request(text.as_bytes(), "install", id).unwrap(),
                Verb::Install
            );
        }
        let _ = fs::remove_dir_all(&base);
    }

    #[test]
    fn install_requests_require_schema_two_and_bounded_sizing() {
        let base = temp();
        fs::create_dir_all(base.join("inbox/jobs")).unwrap();
        let id = "acacacacacacacac";
        write_request_with_size(
            &base,
            id,
            Verb::Install,
            Some(&identity_fields()),
            Some(&crate::wizard::Sizing::default()),
            None,
        )
        .unwrap();
        let bytes = fs::read(request_path(&base, id)).unwrap();
        assert_eq!(parse_request(&bytes, "install", id).unwrap(), Verb::Install);
        let value: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        for (key, bad) in [
            ("schema", 1),
            ("runner_count", 0),
            ("runner_count", 6),
            ("job_cpus", 29),
            ("job_memory_gib", 81),
            ("work_disk_gib", 59),
            ("work_disk_gib", 513),
        ] {
            let mut invalid = value.clone();
            invalid[key] = bad.into();
            assert!(
                parse_request(&serde_json::to_vec(&invalid).unwrap(), "install", id).is_err(),
                "{key}={bad}"
            );
        }
        for key in ["job_cpus", "key_path", "runner_count"] {
            let mut invalid = value.clone();
            invalid.as_object_mut().unwrap().remove(key);
            assert!(parse_request(&serde_json::to_vec(&invalid).unwrap(), "install", id).is_err());
        }
        let mut invalid = value;
        invalid["path"] = "C:\\other".into();
        assert!(parse_request(&serde_json::to_vec(&invalid).unwrap(), "install", id).is_err());
        let _ = fs::remove_dir_all(base);
    }

    #[test]
    fn install_bootstrap_allows_only_the_current_user_in_addition_to_admins() {
        let user = "S-1-5-21-123-1001";
        let mut acl = AclView {
            owner: user.into(),
            aces: vec![DirAce {
                sid: user.into(),
                kind: AceKind::Allow,
                rights: REPLACE_RIGHTS,
                inherit_only: false,
            }],
        };
        assert!(allowed_for_verb(&acl, Some(user), false));
        assert!(
            !allowed_for_verb(&acl, None, false),
            "other verbs keep the admin-only gate"
        );
        acl.aces.push(DirAce {
            sid: "S-1-1-0".into(),
            kind: AceKind::Allow,
            rights: 0x0002,
            inherit_only: false,
        });
        assert!(!allowed_for_verb(&acl, Some(user), false));
        acl.aces[1].rights = 0x0001_0000;
        assert!(!allowed_for_verb(&acl, Some(user), true));
        acl.aces.pop();
        acl.aces[0].kind = AceKind::Other;
        assert!(!allowed_for_verb(&acl, Some(user), false));
    }

    #[test]
    fn user_owned_install_journal_never_authorizes_resume() {
        let base = temp();
        fs::create_dir_all(base.join("jobs/install")).unwrap();
        fs::write(base.join("jobs/install/state.json"), r#"{"schema":1,"step":"done","job_id":"acacacacacacacac","runner_count":1,"job_cpus":2,"job_memory_gib":4,"work_disk_gib":60}"#).unwrap();
        assert!(install_checkpoint(&base).is_none());
        assert!(resume_install_job(&base).is_none());
        let _ = fs::remove_dir_all(base);
    }

    #[test]
    fn an_identity_request_needs_every_field_valid() {
        let id = "0123456789abcdef";
        let ok = identity::request_json(id, &identity_fields());
        assert_eq!(parse_request(&ok, "identity", id).unwrap(), Verb::Identity);
        assert!(
            parse_request(&ok, "verify", id).is_err(),
            "verb must match argv"
        );
        let bare = format!(r#"{{"schema":1,"id":"{id}","verb":"identity"}}"#);
        assert!(parse_request(bare.as_bytes(), "identity", id).is_err());
        let bad = |edit: fn(&mut identity::Valid)| {
            let mut v = identity_fields();
            edit(&mut v);
            parse_request(&identity::request_json(id, &v), "identity", id)
        };
        assert!(bad(|v| v.org = "-acme".into()).is_err());
        assert!(bad(|v| v.app_id = 0).is_err());
        assert!(bad(|v| v.installation_id = 0).is_err());
        assert!(bad(|v| v.group = "a--b".into()).is_err());
        assert!(bad(|v| v.labels = "Linux".into()).is_err());
        assert!(bad(|v| v.labels = "a, b".into()).is_err(), "not normalised");
        assert!(bad(|v| v.key_path = String::new()).is_err());
        assert!(bad(|v| v.key_path = r"\\server\share\k.pem".into()).is_err());
        assert!(bad(|v| v.key_path = r"C:\Users\..\k.pem".into()).is_err());
        assert!(bad(|v| v.key_path = "C:\\Users\\k\n.pem".into()).is_err());
        assert!(bad(|v| v.key_path = r"C:\Users\me\my key.pem".into()).is_ok());
        let path = format!(
            r#"{{"schema":1,"id":"{id}","verb":"identity","org":"acme","app_id":"123","installation_id":456,"group":"aap-crrr","labels":"linux","key_path":"C:\\k.pem"}}"#
        );
        assert!(
            parse_request(path.as_bytes(), "identity", id).is_err(),
            "id as a string"
        );
    }

    #[test]
    fn the_identity_request_file_holds_the_path_and_not_the_key() {
        let base = temp();
        fs::create_dir_all(base.join("inbox").join("jobs")).unwrap();
        let key = base.join("real.pem");
        fs::write(
            &key,
            "-----BEGIN RSA PRIVATE KEY-----\nMIIEtestbody\n-----END RSA PRIVATE KEY-----\n",
        )
        .unwrap();
        let mut v = identity_fields();
        v.key_path = key.display().to_string();
        let id = "fedcba9876543210";
        write_request(&base, id, Verb::Identity, Some(&v)).unwrap();
        let text = fs::read_to_string(request_path(&base, id)).unwrap();
        assert!(text.contains(r#""verb":"identity""#), "{text}");
        assert!(text.contains("real.pem"), "{text}");
        assert!(!text.contains("MIIEtestbody"), "{text}");
        assert!(!text.contains("PRIVATE KEY"), "{text}");
        assert!(text.len() < 1024);
        write_request(&base, id, Verb::Verify, None).unwrap();
        assert_eq!(
            fs::read_to_string(request_path(&base, id)).unwrap(),
            format!(r#"{{"schema":1,"id":"{id}","verb":"verify"}}"#)
        );
        let _ = fs::remove_dir_all(&base);
    }

    #[test]
    fn the_app_token_row_is_read_from_a_finished_verify_log() {
        let base = temp();
        let id = "0123456789abcdef";
        let dir = job_dir(&base, id);
        fs::create_dir_all(&dir).unwrap();
        advance(&dir, id, "verify", "queued", "waiting", None).unwrap();
        advance(&dir, id, "verify", "running", "STEP app-token", None).unwrap();
        let pointer = base.join("helper.json");
        fs::write(
            &pointer,
            format!(r#"{{"schema":1,"id":"{id}","verb":"verify","error":""}}"#),
        )
        .unwrap();
        register_id(id);
        let mut log = String::from("PASS data-dir\nSTEP app-token\nFAIL app-token exit 1\n");
        fs::write(dir.join("log.txt"), &log).unwrap();
        assert_eq!(
            load_job_from(&pointer, &base).unwrap().app_token,
            None,
            "not until the job finished"
        );
        advance(
            &dir,
            id,
            "verify",
            "failed",
            "FAIL app-token exit 1",
            Some(1),
        )
        .unwrap();
        assert_eq!(
            load_job_from(&pointer, &base).unwrap().app_token,
            Some(false)
        );
        log.push_str("PASS app-token obtainable\n");
        fs::write(dir.join("log.txt"), &log).unwrap();
        assert_eq!(
            load_job_from(&pointer, &base).unwrap().app_token,
            Some(true)
        );
        assert_eq!(log_row(&dir.join("log.txt"), "units"), None);
        let _ = fs::remove_dir_all(&base);
    }

    #[test]
    fn job_folder_moves_queued_running_passed_and_stops() {
        let dir = temp();
        let id = "0123456789abcdef";
        advance(&dir, id, "verify", "queued", "waiting", None).unwrap();
        advance(
            &dir,
            id,
            "verify",
            "running",
            "STEP install-host -DryRun",
            None,
        )
        .unwrap();
        let err = advance(&dir, id, "verify", "queued", "back", None).unwrap_err();
        assert!(err.contains("cannot go from running to queued"), "{err}");
        advance(&dir, id, "verify", "passed", "done", Some(0)).unwrap();
        let err = advance(&dir, id, "verify", "running", "again", None).unwrap_err();
        assert!(err.contains("cannot go from passed"), "{err}");
        let status: JobStatus =
            serde_json::from_str(&fs::read_to_string(dir.join("status.json")).unwrap()).unwrap();
        assert_eq!(status.state, "passed");
        assert_eq!(status.exit_code, Some(0));
        assert_eq!(status.schema, 1);
        assert_eq!(fs::read_to_string(dir.join("exit.txt")).unwrap(), "0\n");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_rejected_request_records_the_exit_code() {
        let dir = temp();
        let id = "fedcba9876543210";
        advance(&dir, id, "repair", "queued", "waiting", None).unwrap();
        advance(&dir, id, "repair", "rejected", "request id", Some(2)).unwrap();
        assert_eq!(fs::read_to_string(dir.join("exit.txt")).unwrap(), "2\n");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_junction_is_not_a_place_to_create_a_directory() {
        let base = temp();
        let target = base.join("target");
        let link = base.join("link");
        fs::create_dir(&target).unwrap();
        fs::write(target.join("secret.txt"), "super-secret-key-material").unwrap();
        let status = Command::new(r"C:\Windows\System32\cmd.exe")
            .args(["/d", "/c", "mklink", "/J"])
            .arg(&link)
            .arg(&target)
            .status()
            .unwrap();
        assert!(status.success(), "mklink /J");
        let err = ensure_real_dir(&link.join("child"));
        assert!(err.is_err(), "created through a junction: {err:?}");
        assert!(!target.join("child").exists());
        let _ = Command::new(r"C:\Windows\System32\cmd.exe")
            .args(["/d", "/c", "rmdir"])
            .arg(&link)
            .status();
        let _ = fs::remove_dir_all(&base);
    }

    #[test]
    fn embedded_scripts_roundtrip_and_do_not_climb() {
        let dir = temp();
        materialize(&dir).unwrap();
        for script in scripts() {
            assert!(
                !script
                    .rel
                    .split(['/', '\\'])
                    .any(|p| p == ".." || p.is_empty())
            );
            let got = fs::read(dir.join(script.rel)).unwrap();
            assert_eq!(got, script.text.as_bytes(), "{}", script.rel);
        }
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_window_reads_the_job_it_was_pointed_at() {
        let base = temp();
        let id = "0123456789abcdef";
        let dir = job_dir(&base, id);
        fs::create_dir_all(&dir).unwrap();
        advance(&dir, id, "verify", "queued", "waiting", None).unwrap();
        advance(&dir, id, "verify", "running", "STEP units", None).unwrap();
        fs::write(dir.join("log.txt"), "PASS data-dir\nSTEP units\n").unwrap();
        let pointer = base.join("helper.json");
        fs::write(
            &pointer,
            format!(r#"{{"schema":1,"id":"{id}","verb":"verify","error":""}}"#),
        )
        .unwrap();
        register_id(id); // register so load_job_from accepts it
        let ui = load_job_from(&pointer, &base).unwrap();
        assert_eq!(ui.state, "running");
        assert_eq!(ui.step, "STEP units");
        assert!(ui.summary().contains("Verify"));
        assert!(ui.lines.iter().any(|l| l.contains("STEP units")));
        fs::write(
            &pointer,
            format!(
                r#"{{"schema":1,"id":"{id}","verb":"verify","error":"Elevation was declined."}}"#
            ),
        )
        .unwrap();
        let ui = load_job_from(&pointer, &base).unwrap();
        assert_eq!(ui.state, "declined");
        let _ = fs::remove_dir_all(&base);
    }

    fn ace(sid: &str, kind: AceKind, rights: u32, inherit_only: bool) -> DirAce {
        DirAce {
            sid: sid.to_string(),
            kind,
            rights,
            inherit_only,
        }
    }

    fn view(owner: &str, aces: Vec<DirAce>) -> AclView {
        AclView {
            owner: owner.to_string(),
            aces,
        }
    }

    #[test]
    fn program_files_allows_elevation_and_a_user_write_does_not() {
        const TI: &str = "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464";
        const ADMINS: &str = "S-1-5-32-544";
        const SYSTEM: &str = "S-1-5-18";
        const USERS: &str = "S-1-5-32-545";
        const USER: &str = "S-1-5-21-1-2-3-1001";
        const RX: u32 = 0x1200A9;
        const MODIFY: u32 = 0x301BF;
        let program_files = view(
            TI,
            vec![
                ace(ADMINS, AceKind::Allow, 0x1000_0000, false),
                ace(SYSTEM, AceKind::Allow, 0x1000_0000, false),
                ace(USERS, AceKind::Allow, RX, false),
                ace(USER, AceKind::Allow, MODIFY, true),
            ],
        );
        assert!(elevation_allowed(&program_files), "Program Files shape");
        let live = acl_view(crate::win::acl_of_path(Path::new(r"C:\Program Files"), true).unwrap());
        assert!(
            elevation_allowed(&live),
            "C:\\Program Files owner={} aces={:?}",
            live.owner,
            live.aces
        );
        let notepad =
            crate::win::resolve_exe(Path::new(r"C:\Windows\System32\notepad.exe")).unwrap();
        assert!(
            notepad.path.ends_with(r"System32\notepad.exe"),
            "{}",
            notepad.path.display()
        );
        assert!(elevation_allowed(&acl_view(notepad.acl)), "notepad.exe");
        assert!(!ancestor_lets_non_admin_replace(
            &acl_view(crate::win::acl_of_path(Path::new(r"C:\Program Files"), true).unwrap()).aces
        ));
        assert!(
            !ancestor_lets_non_admin_replace(
                &acl_view(crate::win::acl_of_path(Path::new(r"C:\"), true).unwrap()).aces
            ),
            "drive root looked like it could rename Program Files"
        );
        assert!(
            !elevation_allowed(&view(USER, vec![ace(ADMINS, AceKind::Allow, RX, false)])),
            "a user-owned folder"
        );
        assert!(
            !elevation_allowed(&view(TI, vec![ace(USER, AceKind::Allow, MODIFY, false)])),
            "only the user's SID has Modify"
        );
        assert!(
            !elevation_allowed(&view(
                ADMINS,
                vec![ace(USER, AceKind::Allow, 0x40000, false)]
            )),
            "write-DAC alone"
        );
        assert!(
            !elevation_allowed(&view(ADMINS, vec![ace(USER, AceKind::Allow, 0x100, false)])),
            "write-attributes alone"
        );
        assert!(ancestor_lets_non_admin_replace(&[ace(
            USER,
            AceKind::Allow,
            0x10000,
            false
        )]));
        assert!(
            !ancestor_lets_non_admin_replace(&[ace(USERS, AceKind::Allow, 0x4, false)]),
            "create-folder on a parent is not enough to swap the tree"
        );
        assert!(!ancestor_lets_non_admin_replace(&[ace(
            ADMINS,
            AceKind::Allow,
            0x10000,
            false
        )]));
        assert!(
            !elevation_allowed(&view(
                TI,
                vec![ace(String::new().as_str(), AceKind::Other, 0, false)]
            )),
            "an ACE that is neither allow nor deny"
        );
        assert!(elevation_allowed(&view(
            TI,
            vec![ace(USER, AceKind::Deny, MODIFY, false)]
        )));

        assert!(ancestor_refused(&view(
            USER,
            vec![ace(ADMINS, AceKind::Allow, 0, false)]
        )));
        assert!(ancestor_refused(&view(
            TI,
            vec![ace("", AceKind::Other, 0, false)]
        )));
        assert!(!ancestor_refused(&view(
            TI,
            vec![ace(USERS, AceKind::Allow, 0x4, false)]
        )));
        assert!(
            !ancestor_refused(&view(TI, vec![ace(USERS, AceKind::Allow, 0x100, false)])),
            "write-attributes on a parent is not a replace right"
        );
        assert_eq!(
            USER_WRITABLE_EXE_DIR,
            "tray exe is in a user-writable folder; move it to an admin-only folder"
        );
        assert!(!crate::win::machine_ps_module_path().unwrap().is_empty());
    }
}

#[test]
fn launch_hands_the_resolved_path_to_runas() {
    let root = std::env::temp_dir().join(format!("aap-runas-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    let target = root.join("target");
    let link = root.join("link");
    std::fs::create_dir_all(&target).unwrap();
    std::fs::write(target.join("tray.exe"), b"x").unwrap();
    let status = std::process::Command::new(r"C:\Windows\System32\cmd.exe")
        .args([
            "/d",
            "/c",
            "mklink",
            "/J",
            &link.display().to_string(),
            &target.display().to_string(),
        ])
        .status()
        .unwrap();
    assert!(status.success(), "mklink failed");
    // Redirect pointer writes away from the real %TEMP%\aap-runner-tray\helper.json
    let pointer_dir = root.join("pointer");
    std::fs::create_dir_all(&pointer_dir).unwrap();
    POINTER_DIR.with(|d| *d.borrow_mut() = Some(pointer_dir.clone()));
    let via_link = link.join("tray.exe");
    let resolved = crate::win::resolve_exe(&via_link).unwrap();
    let text = resolved.path.to_string_lossy().to_ascii_lowercase();
    assert!(text.contains(r"\target\tray.exe"), "{text}");
    assert!(!text.contains(r"\link\"), "{text}");
    let base = root.join("data");
    std::fs::create_dir_all(base.join("inbox").join("jobs")).unwrap();
    CAPTURE_RUNAS.with(|c| c.set(true));
    CAPTURED_RUNAS.with(|slot| *slot.borrow_mut() = None);
    let opened = crate::win::ResolvedExe {
        path: resolved.path.clone(),
        acl: crate::win::ObjectAcl {
            owner: "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464".into(),
            aces: vec![crate::win::DirectoryAce {
                sid: "S-1-5-32-544".into(),
                allow: true,
                other: false,
                rights: 0x1000_0000,
                inherit_only: false,
            }],
        },
    };
    launch_resolved(&base, Verb::Verify, opened, None).unwrap();
    let got = CAPTURED_RUNAS
        .with(|slot| slot.borrow_mut().take())
        .unwrap();
    CAPTURE_RUNAS.with(|c| c.set(false));
    assert_eq!(got, resolved.path);
    assert!(
        !got.to_string_lossy()
            .to_ascii_lowercase()
            .contains(r"\link\")
    );
    // Successful launch wrote pointer to the override dir, not the real %TEMP% path.
    assert!(
        pointer_dir.join("helper.json").exists(),
        "pointer not written to override dir"
    );
    CAPTURE_RUNAS.with(|c| c.set(true));
    CAPTURED_RUNAS.with(|slot| *slot.borrow_mut() = None);
    let unc = crate::win::ResolvedExe {
        path: PathBuf::from(r"\\server\share\tray.exe"),
        acl: crate::win::ObjectAcl {
            owner: "S-1-5-18".into(),
            aces: Vec::new(),
        },
    };
    assert!(launch_resolved(&base, Verb::Verify, unc, None).is_err());
    assert!(CAPTURED_RUNAS.with(|slot| slot.borrow().is_none()));
    CAPTURE_RUNAS.with(|c| c.set(false));
    // The UNC refusal must appear in the override pointer dir, NOT the real %TEMP% path.
    let refusal = std::fs::read_to_string(pointer_dir.join("helper.json")).unwrap();
    assert!(
        refusal.contains("tray exe is not on a fixed local drive:"),
        "refusal message not in pointer: {refusal}"
    );
    assert!(
        refusal.contains("drive type"),
        "drive type not in refusal: {refusal}"
    );
    // JSON-encodes the UNC path: server name is unambiguous in either encoding.
    assert!(
        refusal.contains("server"),
        "UNC server not in refusal: {refusal}"
    );
    POINTER_DIR.with(|d| *d.borrow_mut() = None);
    let _ = std::process::Command::new(r"C:\Windows\System32\cmd.exe")
        .args(["/d", "/c", "rmdir", &link.display().to_string()])
        .status();
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn stale_result_with_unknown_id_is_ignored() {
    let base = std::env::temp_dir().join(format!("aap-stale-{}", std::process::id()));
    let pointer = base.join("helper.json");
    let data = base.join("data");
    let _ = std::fs::remove_dir_all(&base);
    std::fs::create_dir_all(&base).unwrap();

    // Write a pointer whose id was NOT issued by this process.
    let stale_id = "deadbeefdeadbeef";
    let content = format!(
        r#"{{"schema":1,"id":"{stale_id}","verb":"verify","error":"from a previous run"}}"#
    );
    std::fs::write(&pointer, content.as_bytes()).unwrap();

    // Must be ignored.
    assert!(
        load_job_from(&pointer, &data).is_none(),
        "stale id must be rejected"
    );

    // Register the id and re-read; now the declined result is shown.
    register_id(stale_id);
    let job = load_job_from(&pointer, &data);
    assert!(job.is_some(), "registered id must be accepted");
    assert_eq!(job.unwrap().state, "declined");

    let _ = std::fs::remove_dir_all(&base);
}

#[test]
fn not_fixed_drive_message_format() {
    let msg = not_fixed_drive_msg(std::path::Path::new(r"C:\x\t.exe"), 4);
    assert_eq!(
        msg,
        r"tray exe is not on a fixed local drive: C:\x\t.exe (drive type 4)"
    );
}
