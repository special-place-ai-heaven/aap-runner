//! Pure file contract. Trust split: the tray writes only under `<base>\inbox\`
//! (`state.json`, `settings.json`, `tray.log`); it reads the admin-written `<base>\status.json`
//! and `<base>\status.v5.json`. No UI here.

use crate::mark::Sym;
use serde::Deserialize;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

pub const DEFAULT_BASE: &str = r"C:\ProgramData\aap-runner";
pub const STALE_AFTER: Duration = Duration::from_secs(180);
/// A larger `status.json` is treated as Unknown without reading it.
pub const MAX_STATUS_BYTES: u64 = 64 * 1024;
/// The newest `status.json` schema this app understands.
pub const SCHEMA: u32 = 4;
/// The `Error` detail for a `status.json` newer than this app.
pub const NEWER_SCHEMA: &str = "This app is older than the service. Update the app.";

/// The only folder the tray writes to. Its absence means "not installed".
pub fn inbox(base: &Path) -> PathBuf {
    base.join("inbox")
}

/// Read at most `MAX_STATUS_BYTES`; `None` if missing, unreadable, not UTF-8 or larger.
pub fn read_bounded(path: &Path) -> Option<String> {
    let f = File::open(path).ok()?;
    if f.metadata().ok()?.len() > MAX_STATUS_BYTES {
        return None;
    }
    let mut s = String::new();
    // The file can grow between metadata() and read: the take() bound still holds.
    f.take(MAX_STATUS_BYTES + 1).read_to_string(&mut s).ok()?;
    (s.len() as u64 <= MAX_STATUS_BYTES).then_some(s)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Status {
    NotInstalled,
    Unknown,
    Off,
    Starting,
    Idle,
    Running(String),
    Draining,
    Paused,
    Error(String),
}

impl Status {
    pub fn text(&self) -> String {
        match self {
            Status::NotInstalled => "Not installed".into(),
            Status::Unknown => "Unknown (supervisor not running)".into(),
            Status::Off => "Off".into(),
            Status::Starting => "Starting\u{2026}".into(),
            Status::Idle => "Idle".into(),
            Status::Running(job) if job.is_empty() => "Running job".into(),
            Status::Running(job) => format!("Running job {job}"),
            Status::Draining => "Draining\u{2026}".into(),
            Status::Paused => "Paused".into(),
            Status::Error(detail) => format!("Error: {detail}"),
        }
    }

    /// The one symbol for this state, used by the tray icon, the header and the cards.
    pub fn sym(&self) -> Sym {
        match self {
            Status::NotInstalled => Sym::NotInstalled,
            Status::Unknown => Sym::Down,
            Status::Off => Sym::Off,
            Status::Starting => Sym::Starting,
            Status::Idle => Sym::Idle,
            Status::Running(_) => Sym::Running,
            Status::Draining => Sym::Draining,
            Status::Paused => Sym::Paused,
            Status::Error(_) => Sym::Error,
        }
    }

    /// The `status.json` `state` word the identity pool gate reads.
    /// Missing or unreadable status is `missing`.
    pub fn pool_word(&self) -> &'static str {
        match self {
            Status::Idle => "idle",
            Status::Running(_) => "running",
            Status::Draining => "draining",
            Status::Paused => "paused",
            Status::Starting => "starting",
            Status::Error(_) => "error",
            Status::Off => "off",
            Status::NotInstalled | Status::Unknown => "missing",
        }
    }
}

/// Sampled pool use; any value may be absent (older supervisor or no sample yet).
#[derive(Debug, Clone, Copy, Default, PartialEq, Deserialize)]
pub struct Pool {
    pub cpu_cores: Option<f64>,
    pub mem_gib: Option<f64>,
    pub io_mbps: Option<f64>,
}

/// One runner slot, from `slots[]` or built from the top-level fields of an older status.
#[derive(Debug, Clone, PartialEq)]
pub struct Slot {
    pub slot: u32,
    /// One of Idle, Running, Draining, Starting, Error.
    pub state: Sym,
    pub job: String,
    pub repo: String,
    pub run_url: String,
    pub job_url: String,
    pub started_at: Option<SystemTime>,
    pub cpu_cores: Option<f64>,
    pub mem_gib: Option<f64>,
    /// The manager gave up on this slot (`retired`); `state` is Error for the colour.
    pub retired: bool,
}

impl Slot {
    /// What the title link opens: a valid `job_url`, else a valid `run_url`, else nothing.
    pub fn link(&self) -> Option<&str> {
        if valid_job_url(&self.job_url) {
            Some(&self.job_url)
        } else if valid_run_url(&self.run_url) {
            Some(&self.run_url)
        } else {
            None
        }
    }

    pub fn busy(&self) -> bool {
        matches!(self.state, Sym::Running | Sym::Draining)
    }

    /// The state word on the card.
    pub fn word(&self) -> &'static str {
        if self.retired {
            "Retired"
        } else {
            self.state.label()
        }
    }

    /// A line under the word, for a state that needs one.
    pub fn note(&self) -> Option<&'static str> {
        self.retired.then_some("gave up; restarts with the pool")
    }
}

/// Effective limits the supervisor reports back; each may be absent.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Applied {
    pub runner_count: Option<u32>,
    pub job_cpus: Option<u32>,
    pub job_memory_gib: Option<u32>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Snapshot {
    pub status: Status,
    pub applied: Applied,
    /// `owner/name` of the running job's repository, or empty.
    pub repo: String,
    /// The running job's Actions URL as reported; use `job_url()`, never this, to open it.
    pub run_url: String,
    /// The supervisor's `detail`, also outside the error state (a refused limit while paused).
    pub detail: String,
    /// When the supervisor last wrote the file; kept for a stale file too.
    pub updated: Option<SystemTime>,
    pub sampled_at: Option<SystemTime>,
    pub pool: Pool,
    /// `slots[]`, or one slot built from the top-level fields when there are none.
    pub slots: Vec<Slot>,
    pub job_io_mbps: Option<f64>,
    pub sharing: Option<String>,
    /// Work disk size, free space, and floor, in GiB. Absent on a schema 3 file.
    pub work_disk_gib: Option<f64>,
    pub work_disk_free_gb: Option<f64>,
    pub work_disk_floor_gb: Option<f64>,
    /// True while the manager is cleaning the work disk.
    pub cleaning: bool,
    /// `Unknown` because a present, fresh `status.json` could not be used by this build, not
    /// because the service stopped; `detail` then holds the reason.
    pub unreadable: bool,
}

/// `https://github.com/<owner>/<repo>/actions/runs/<digits>` and nothing else, the same as
/// `^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/actions/runs/[0-9]+$`.
pub fn valid_run_url(url: &str) -> bool {
    actions_path_len(url) == Some(5)
}

/// [`valid_run_url`] plus `/job/<digits>`.
pub fn valid_job_url(url: &str) -> bool {
    actions_path_len(url) == Some(7)
}

/// Path parts of `https://github.com/O/R/actions/runs/N[/job/M]`; `None` for anything else.
fn actions_path_len(url: &str) -> Option<usize> {
    let rest = url.strip_prefix("https://github.com/")?;
    let name = |s: &str| {
        !s.is_empty()
            && s.bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b'-'))
    };
    let digits = |s: &str| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit());
    let parts: Vec<&str> = rest.split('/').collect();
    let ok = match parts.as_slice() {
        [owner, repo, "actions", "runs", id] => name(owner) && name(repo) && digits(id),
        [owner, repo, "actions", "runs", id, "job", job] => {
            name(owner) && name(repo) && digits(id) && digits(job)
        }
        _ => false,
    };
    ok.then_some(parts.len())
}

impl Snapshot {
    pub fn bare(status: Status) -> Self {
        Snapshot {
            status,
            applied: Applied::default(),
            repo: String::new(),
            run_url: String::new(),
            detail: String::new(),
            updated: None,
            sampled_at: None,
            pool: Pool::default(),
            slots: Vec::new(),
            job_io_mbps: None,
            sharing: None,
            work_disk_gib: None,
            work_disk_free_gb: None,
            work_disk_floor_gb: None,
            cleaning: false,
            unreadable: false,
        }
    }

    /// A status file that is there but this build cannot use; `why` is shown and copied.
    fn unreadable(why: impl Into<String>, updated: Option<SystemTime>) -> Self {
        Snapshot {
            detail: why.into(),
            updated,
            unreadable: true,
            ..Snapshot::bare(Status::Unknown)
        }
    }

    /// Runners busy with a job (running or draining).
    pub fn busy(&self) -> usize {
        self.slots.iter().filter(|s| s.busy()).count()
    }

    /// Runner slots configured: `runner_count`, at least the number of slots reported.
    pub fn runners(&self) -> usize {
        (self.applied.runner_count.unwrap_or(0) as usize).max(self.slots.len())
    }

    /// The URL "Open job" may open: only a valid GitHub Actions run URL.
    pub fn job_url(&self) -> Option<&str> {
        valid_run_url(&self.run_url).then_some(self.run_url.as_str())
    }

    /// The state word of the header and the tooltip. A status file this build cannot read is
    /// not a service that stopped.
    pub fn label(&self) -> &'static str {
        if self.unreadable && self.status == Status::Unknown {
            "Status unreadable"
        } else {
            self.status.sym().label()
        }
    }

    fn status_text(&self) -> String {
        match &self.status {
            Status::Running(job) if !self.repo.is_empty() => {
                let short = self.repo.rsplit('/').next().unwrap_or(&self.repo);
                if job.is_empty() {
                    format!("Running {short}")
                } else {
                    format!("Running {short} \u{b7} {job}")
                }
            }
            Status::Unknown if self.unreadable => "Unknown (status file unreadable)".into(),
            status => status.text(),
        }
    }

    /// Menu state line / tooltip, e.g. `Idle · 2 runners · 24 cpu · 72 GiB total`
    /// (cpu and memory are pool totals split across the runners), or
    /// `Running Agent_Army_Professionals · Workspace · …` while a job runs.
    pub fn line(&self) -> String {
        let mut line = self.status_text();
        let a = &self.applied;
        if let Some(n) = a.runner_count {
            line += &format!(" \u{b7} {n} runner{}", if n == 1 { "" } else { "s" });
        }
        if let Some(n) = a.job_cpus {
            line += &format!(" \u{b7} {n} cpu");
        }
        if let Some(n) = a.job_memory_gib {
            line += &format!(" \u{b7} {n} GiB total");
        }
        line
    }
}

#[derive(Deserialize)]
struct RawStatus {
    schema: Option<u32>,
    state: String,
    #[serde(default)]
    job: String,
    updated: String,
    #[serde(default)]
    detail: String,
    runner_count: Option<u32>,
    job_cpus: Option<u32>,
    job_memory_gib: Option<u32>,
    repo: Option<String>,
    run_url: Option<String>,
    sampled_at: Option<String>,
    pool: Option<Pool>,
    slots: Option<Vec<RawSlot>>,
    job_io_mbps: Option<f64>,
    sharing: Option<String>,
    work_disk_gib: Option<f64>,
    work_disk_free_gb: Option<f64>,
    work_disk_floor_gb: Option<f64>,
    #[serde(default)]
    cleaning: bool,
}

/// Every field optional: the supervisor writes `null` for a value that failed its checks.
#[derive(Deserialize)]
struct RawSlot {
    slot: Option<u32>,
    state: Option<String>,
    job: Option<String>,
    repo: Option<String>,
    run_url: Option<String>,
    job_url: Option<String>,
    started_at: Option<String>,
    cpu_cores: Option<f64>,
    mem_gib: Option<f64>,
}

/// A slot state word. `retired` (the manager gave up) shows as Error; anything else unknown shows
/// as Starting: the slot exists, its state says no more.
fn slot_sym(state: &str) -> Sym {
    match state {
        "idle" => Sym::Idle,
        "running" => Sym::Running,
        "draining" => Sym::Draining,
        "error" | "retired" => Sym::Error,
        _ => Sym::Starting,
    }
}

/// Missing inbox = not installed; missing or stale status.json = unknown (service not running);
/// a fresh one this build cannot read = unknown with `unreadable` and the reason.
pub fn read_status(base: &Path, now: SystemTime) -> Snapshot {
    if !inbox(base).is_dir() {
        return Snapshot::bare(Status::NotInstalled);
    }
    let path = base.join("status.json");
    if let Some(json) = read_bounded(&path) {
        return parse_status(&json, now);
    }
    // Not read: missing, locked, or present but too large / not UTF-8. Only a file written
    // lately (by its modified time; a future one counts as fresh) is a file this build rejects.
    let Ok(meta) = fs::metadata(&path) else {
        return Snapshot::bare(Status::Unknown);
    };
    let fresh = meta
        .modified()
        .is_ok_and(|m| now.duration_since(m).map_or(true, |age| age <= STALE_AFTER));
    if !fresh {
        Snapshot::bare(Status::Unknown)
    } else if meta.len() > MAX_STATUS_BYTES {
        Snapshot::unreadable("the file is larger than 64 KiB", None)
    } else if File::open(&path).is_ok() {
        Snapshot::unreadable("the file is not valid UTF-8 text", None)
    } else {
        Snapshot::bare(Status::Unknown)
    }
}

pub fn parse_status(json: &str, now: SystemTime) -> Snapshot {
    // PowerShell 5 writes UTF-8 with a BOM.
    let raw = match serde_json::from_str::<RawStatus>(json.trim_start_matches('\u{feff}')) {
        Ok(raw) => raw,
        Err(e) => return Snapshot::unreadable(format!("not valid status JSON: {e}"), None),
    };
    let Some(updated) = parse_rfc3339(&raw.updated) else {
        return Snapshot::unreadable("its timestamp is missing or malformed", None);
    };
    match now.duration_since(updated) {
        Ok(age) if age > STALE_AFTER => {
            return Snapshot {
                updated: Some(updated),
                ..Snapshot::bare(Status::Unknown)
            };
        }
        // Small clock skew stays fresh; further ahead the wall clock was stepped back.
        Err(e) if e.duration() > STALE_AFTER => {
            let why = format!(
                "its timestamp is {} min in the future; check the PC clock",
                e.duration().as_secs() / 60
            );
            return Snapshot::unreadable(why, Some(updated));
        }
        _ => {}
    }
    if raw.schema.is_some_and(|v| v > SCHEMA) {
        return Snapshot {
            updated: Some(updated),
            ..Snapshot::bare(Status::Error(NEWER_SCHEMA.into()))
        };
    }
    let status = match raw.state.as_str() {
        "off" => Status::Off,
        "starting" => Status::Starting,
        "idle" => Status::Idle,
        "running" => Status::Running(raw.job.clone()),
        "draining" => Status::Draining,
        "paused" => Status::Paused,
        "error" => Status::Error(raw.detail.clone()),
        other => {
            let word: String = other.chars().take(32).collect();
            return Snapshot::unreadable(format!("unknown state \"{word}\""), Some(updated));
        }
    };
    let applied = Applied {
        runner_count: raw.runner_count,
        job_cpus: raw.job_cpus,
        job_memory_gib: raw.job_memory_gib,
    };
    let repo = raw.repo.unwrap_or_default();
    let run_url = raw.run_url.unwrap_or_default();
    let reported: Vec<Slot> = raw
        .slots
        .unwrap_or_default()
        .into_iter()
        .zip(1..)
        .map(|(s, n)| Slot {
            slot: s.slot.unwrap_or(n),
            state: slot_sym(s.state.as_deref().unwrap_or_default()),
            job: s.job.unwrap_or_default(),
            repo: s.repo.unwrap_or_default(),
            run_url: s.run_url.unwrap_or_default(),
            job_url: s.job_url.unwrap_or_default(),
            started_at: s.started_at.as_deref().and_then(parse_rfc3339),
            cpu_cores: s.cpu_cores,
            mem_gib: s.mem_gib,
            retired: s.state.as_deref() == Some("retired"),
        })
        .collect();
    // No (or an empty) slots[]: one card from the top-level fields while the manager runs.
    let slots = if !reported.is_empty() {
        reported
    } else if matches!(
        status,
        Status::Starting | Status::Idle | Status::Running(_) | Status::Draining
    ) {
        vec![Slot {
            slot: 1,
            state: status.sym(),
            job: raw.job,
            repo: repo.clone(),
            run_url: run_url.clone(),
            job_url: String::new(),
            started_at: None,
            cpu_cores: None,
            mem_gib: None,
            retired: false,
        }]
    } else {
        Vec::new()
    };
    Snapshot {
        status,
        applied,
        repo,
        run_url,
        detail: raw.detail,
        updated: Some(updated),
        sampled_at: raw.sampled_at.as_deref().and_then(parse_rfc3339),
        pool: raw.pool.unwrap_or_default(),
        slots,
        job_io_mbps: raw.job_io_mbps,
        sharing: raw.sharing,
        work_disk_gib: raw.work_disk_gib,
        work_disk_free_gb: raw.work_disk_free_gb,
        work_disk_floor_gb: raw.work_disk_floor_gb,
        cleaning: raw.cleaning,
        unreadable: false,
    }
}

/// The `status.v5.json` schema this app reads.
pub const SCHEMA_V5: u32 = 5;

/// CPUs and GiB.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
pub struct Res {
    pub cpus: u32,
    pub mem_gib: u32,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct CapacityV5 {
    pub used_slots: u32,
    pub free_slots: u32,
    pub host_reserve_percent: u32,
    /// `even` or `per_profile`.
    pub share_mode: String,
    pub host: Res,
}

/// One runner profile: `linux` or `windows`, its backend (`wsl-legacy`, `hyperv-vm`,
/// `windows-host` or `none`), its count and share, and the caps the allocator gives it.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct ProfileV5 {
    pub profile: String,
    pub os: String,
    pub backend: String,
    pub count: u32,
    pub share_percent: Option<u32>,
    pub per_runner: Res,
    pub profile_cap: Res,
    pub image_generation: Option<String>,
    pub generation_state: Option<String>,
    pub available: bool,
    pub unavailable_reason: String,
    /// `online`, `busy` or `stopped`, present exactly with `backend: windows-host`.
    #[serde(default)]
    pub host_runner: Option<String>,
}

/// The Windows row's name for `backend: windows-host` (status-settings.md, Windows host).
pub const HOST_RUNNER_NAME: &str = "interim runner on this PC";
/// The one warning line beside it.
pub const HOST_RUNNER_WARNING: &str =
    "Unisolated: jobs run directly on this PC (owner accepted 2026-10-20).";

impl ProfileV5 {
    /// The interim runner's state: `online`, `busy`, or `stopped` and the missing piece.
    pub fn host_state(&self) -> String {
        match self.host_runner.as_deref() {
            Some(s @ ("online" | "busy")) => s.into(),
            _ if self.unavailable_reason.is_empty() => "stopped".into(),
            _ => format!("stopped: {}", self.unavailable_reason),
        }
    }
}

/// One slot of any backend. `run_url` and `job_url` go through [`valid_run_url`] and
/// [`valid_job_url`] before anything opens them.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct SlotV5 {
    pub slot: u32,
    pub profile: String,
    pub os: String,
    pub backend: String,
    pub lifecycle: String,
    pub image_generation: String,
    pub job: String,
    pub repo: String,
    pub run_url: String,
    pub job_url: Option<String>,
}

/// `status.v5.json`, written by the supervisor beside `status.json` (supervisor/README.md):
/// both profiles and the slots of every backend. `status.json` stays the legacy pool's.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct StatusV5 {
    schema: u32,
    pub state: String,
    pub updated: String,
    pub detail: String,
    /// The `inbox\settings.json` schemas the supervisor accepts.
    pub settings_schemas: Vec<u32>,
    pub capacity: CapacityV5,
    pub profiles: Vec<ProfileV5>,
    pub slots: Vec<SlotV5>,
}

impl StatusV5 {
    pub fn profile(&self, name: &str) -> Option<&ProfileV5> {
        self.profiles.iter().find(|p| p.profile == name)
    }

    /// The Windows profile while it is the interim runner on this PC.
    pub fn windows_host(&self) -> Option<&ProfileV5> {
        self.profile("windows")
            .filter(|p| p.backend == "windows-host")
    }

    /// The supervisor reads settings schema 3, so the tray may write it.
    pub fn takes_settings_v3(&self) -> bool {
        self.settings_schemas.contains(&3)
    }

    /// The supervisor reads settings schema 4 (the tiers), so the tray may write it.
    pub fn takes_settings_v4(&self) -> bool {
        self.settings_schemas.contains(&4)
    }
}

/// `status.v5.json`, or `None` when it is missing, over 64 KiB, unparseable, stale (over 180 s
/// old, or `updated` in the future), of another schema or without exactly the Linux and Windows
/// profiles: then the tray keeps to `status.json` (an older supervisor writes no such file).
pub fn read_status_v5(base: &Path, now: SystemTime) -> Option<StatusV5> {
    parse_status_v5(&read_bounded(&base.join("status.v5.json"))?, now)
}

pub fn parse_status_v5(json: &str, now: SystemTime) -> Option<StatusV5> {
    let v: StatusV5 = serde_json::from_str(json.trim_start_matches('\u{feff}')).ok()?;
    let updated = parse_rfc3339(&v.updated)?;
    let fresh = now
        .duration_since(updated)
        .is_ok_and(|age| age <= STALE_AFTER);
    let two =
        v.profiles.len() == 2 && v.profile("linux").is_some() && v.profile("windows").is_some();
    (v.schema == SCHEMA_V5 && fresh && two).then_some(v)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Desired {
    On,
    Off,
}

/// Atomic: write `<file>.tmp` next to `path`, flush, rename over `path`.
pub fn write_atomic(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let mut tmp = path.as_os_str().to_owned();
    tmp.push(".tmp");
    let written = (|| {
        let mut f = File::create(&tmp)?;
        f.write_all(bytes)?;
        f.sync_all()?;
        drop(f);
        // std::fs::rename replaces the destination on Windows (MOVEFILE_REPLACE_EXISTING).
        fs::rename(&tmp, path)
    })();
    if written.is_err() {
        let _ = fs::remove_file(&tmp); // a full disk must not strand a half-written .tmp
    }
    written
}

/// Retry now: desired on plus a new `retry` stamp, which makes the supervisor reset its
/// backoff and run the next step at once. An older supervisor reads only `desired`.
pub fn write_retry(base: &Path, now: SystemTime) -> io::Result<()> {
    let secs = now.duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs());
    write_atomic(
        &inbox(base).join("state.json"),
        format!(r#"{{"desired":"on","retry":{secs}}}"#).as_bytes(),
    )
}

/// `inbox\state.json` as the supervisor reads it: exactly `"on"` is On; anything else, a missing
/// or unreadable file included, is Off.
pub fn read_desired(base: &Path) -> Desired {
    let on = read_bounded(&inbox(base).join("state.json"))
        .and_then(|s| {
            serde_json::from_str::<serde_json::Value>(s.trim_start_matches('\u{feff}')).ok()
        })
        .is_some_and(|v| v["desired"] == "on");
    if on { Desired::On } else { Desired::Off }
}

pub fn write_desired(base: &Path, desired: Desired) -> io::Result<()> {
    let body: &[u8] = match desired {
        Desired::On => br#"{"desired":"on"}"#,
        Desired::Off => br#"{"desired":"off"}"#,
    };
    write_atomic(&inbox(base).join("state.json"), body)
}

/// How a [`restart`] ended. Every outcome but `Overridden` leaves desired = on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Restart {
    /// The supervisor reported `off`, then desired went back to on.
    Done,
    /// The pool did not report `off` in time (a long job is draining); desired is on again.
    TimedOut,
    /// The supervisor stopped reporting; desired is on again so it starts when it returns.
    Unknown,
    /// The owner wrote `on` meanwhile (Start in the window): nothing more was written.
    Overridden,
}

/// Write off, wait until the supervisor reports `off`, then write on. Whatever stops the wait
/// (timeout, status unknown) writes on, so a restart never leaves the pool off; only an `on`
/// the owner wrote during the wait ends it without a write. One unknown read is ridden out (the
/// status file can be mid-replace); two in a row end the wait.
pub fn restart(base: &Path, poll: Duration, timeout: Duration) -> io::Result<Restart> {
    write_desired(base, Desired::Off)?;
    let deadline = Instant::now() + timeout;
    let mut unknown = false;
    let outcome = loop {
        if read_desired(base) == Desired::On {
            return Ok(Restart::Overridden);
        }
        match read_status(base, SystemTime::now()).status {
            Status::Off => break Restart::Done,
            Status::Unknown if unknown => break Restart::Unknown,
            Status::Unknown => unknown = true,
            _ => unknown = false,
        }
        if Instant::now() >= deadline {
            break Restart::TimedOut;
        }
        thread::sleep(poll);
    };
    write_desired(base, Desired::On)?;
    Ok(outcome)
}

/// Append a line to `inbox/tray.log` if that folder exists; otherwise silent.
pub fn log(base: &Path, msg: &str) {
    let dir = inbox(base);
    if !dir.is_dir() {
        return;
    }
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs());
    if let Ok(mut f) = OpenOptions::new()
        .create(true)
        .append(true)
        .open(dir.join("tray.log"))
    {
        let _ = writeln!(f, "{secs} {msg}");
    }
}

/// Minimal RFC 3339 parser: `YYYY-MM-DDTHH:MM:SS[.frac](Z|+HH:MM|-HH:MM)`.
/// Fractional seconds are ignored (irrelevant against a 3-minute staleness window).
pub fn parse_rfc3339(s: &str) -> Option<SystemTime> {
    fn num(t: &str) -> Option<i64> {
        if t.bytes().all(|c| c.is_ascii_digit()) {
            t.parse().ok()
        } else {
            None
        }
    }
    let b = s.as_bytes();
    if b.len() < 20
        || !s.is_char_boundary(19)
        || b[4] != b'-'
        || b[7] != b'-'
        || !matches!(b[10], b'T' | b't' | b' ')
        || b[13] != b':'
        || b[16] != b':'
    {
        return None;
    }
    let (y, mo, d) = (num(&s[0..4])?, num(&s[5..7])?, num(&s[8..10])?);
    let (h, mi, sec) = (num(&s[11..13])?, num(&s[14..16])?, num(&s[17..19])?);
    if !(1..=12).contains(&mo) || !(1..=31).contains(&d) || h > 23 || mi > 59 || sec > 60 {
        return None;
    }
    let mut rest = &s[19..];
    if let Some(frac) = rest.strip_prefix('.') {
        let digits = frac.bytes().take_while(u8::is_ascii_digit).count();
        if digits == 0 {
            return None;
        }
        rest = &frac[digits..];
    }
    let offset = match rest.as_bytes() {
        b"Z" | b"z" => 0,
        [sign @ (b'+' | b'-'), _, _, b':', _, _] => {
            let (oh, om) = (num(&rest[1..3])?, num(&rest[4..6])?);
            if oh > 23 || om > 59 {
                return None;
            }
            let sign = if *sign == b'+' { 1 } else { -1 };
            sign * (oh * 3600 + om * 60)
        }
        _ => return None,
    };
    let secs = days_from_civil(y, mo, d) * 86_400 + h * 3600 + mi * 60 + sec - offset;
    u64::try_from(secs)
        .ok()
        .map(|s| UNIX_EPOCH + Duration::from_secs(s))
}

/// Days since 1970-01-01 (Howard Hinnant's algorithm).
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

#[cfg(test)]
pub(crate) fn temp_base(name: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("aap-tray-test-{}-{name}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(inbox(&dir)).unwrap();
    dir
}

/// A contract fixture as written: an invalid one is wrapped as {"expect", "instance"}.
#[cfg(test)]
pub(crate) fn fixture(rel: &str) -> String {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../parity/contracts/fixtures")
        .join(rel);
    let text = fs::read_to_string(&path).unwrap();
    let v: serde_json::Value = serde_json::from_str(&text).unwrap();
    match v.get("instance") {
        Some(i) => i.to_string(),
        None => text,
    }
}

#[cfg(test)]
/// RFC 3339 UTC for `t` (Howard Hinnant's civil_from_days), so a test can write "now".
pub(crate) fn rfc(t: SystemTime) -> String {
    let secs = t.duration_since(UNIX_EPOCH).unwrap().as_secs() as i64;
    let (days, rem) = (secs.div_euclid(86_400), secs.rem_euclid(86_400));
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z",
        rem / 3600,
        rem / 60 % 60,
        rem % 60
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(rfc: &str) -> SystemTime {
        parse_rfc3339(rfc).unwrap()
    }

    fn json(state: &str, updated: &str) -> String {
        format!(
            r#"{{"state":"{state}","job":"build-42","updated":"{updated}","detail":"disk full"}}"#
        )
    }

    fn status(json: &str, now: SystemTime) -> Status {
        parse_status(json, now).status
    }

    #[test]
    fn rfc3339_known_values() {
        assert_eq!(at("1970-01-01T00:00:00Z"), UNIX_EPOCH);
        assert_eq!(
            at("2000-01-01T00:00:00Z"),
            UNIX_EPOCH + Duration::from_secs(946_684_800)
        );
        assert_eq!(at("2026-10-12T10:00:00+02:00"), at("2026-10-12T08:00:00Z"));
        assert_eq!(
            at("2026-10-12T08:00:00.123456Z"),
            at("2026-10-12T08:00:00Z")
        );
        assert_eq!(at("2026-10-12T05:30:00-02:30"), at("2026-10-12T08:00:00Z"));
        for bad in [
            "",
            "2026-10-12",
            "2026-13-01T00:00:00Z",
            "2026-10-12T08:00:00",
            "x026-10-12T08:00:00Z",
            "2026-10-12T08:00:00+0200",
            "2026-10-12T08:00:00.Z",
        ] {
            assert_eq!(parse_rfc3339(bad), None, "{bad}");
        }
    }

    #[test]
    fn parses_every_state() {
        let now = at("2026-10-12T08:01:00Z");
        let t = "2026-10-12T08:00:00Z";
        let cases = [
            ("off", Status::Off),
            ("starting", Status::Starting),
            ("idle", Status::Idle),
            ("running", Status::Running("build-42".into())),
            ("draining", Status::Draining),
            ("paused", Status::Paused),
            ("error", Status::Error("disk full".into())),
            ("bogus", Status::Unknown),
        ];
        for (state, want) in cases {
            assert_eq!(status(&json(state, t), now), want, "{state}");
        }
    }

    #[test]
    fn a_retired_slot_is_retired_and_other_unknown_words_still_start() {
        let now = at("2026-10-12T08:01:00Z");
        let json = r#"{"schema":4,"state":"running","job":"j","updated":"2026-10-12T08:00:00Z",
            "slots":[{"slot":1,"state":"retired"},{"slot":2,"state":"bogus"},{"slot":3,"state":"idle"}]}"#;
        let slots = parse_status(json, now).slots;
        assert!(slots[0].retired && !slots[1].retired && !slots[2].retired);
        assert_eq!((slots[0].word(), slots[0].state), ("Retired", Sym::Error));
        assert!(
            slots[0]
                .note()
                .is_some_and(|n| n.contains("restarts with the pool"))
        );
        assert!(!slots[0].busy());
        assert_eq!(
            (slots[1].word(), slots[1].state),
            ("Starting", Sym::Starting)
        );
        assert_eq!(slots[1].note(), None);
        assert_eq!(slots[2].word(), "Idle");
    }

    #[test]
    fn stale_bad_and_bom() {
        let now = at("2026-10-12T08:03:01Z");
        assert_eq!(
            status(&json("idle", "2026-10-12T08:00:00Z"), now),
            Status::Unknown
        );
        assert_eq!(
            status(&json("idle", "2026-10-12T08:00:01Z"), now),
            Status::Idle
        );
        // Small clock skew stays fresh; more than STALE_AFTER ahead is not trusted.
        assert_eq!(
            status(&json("idle", "2026-10-12T08:05:00Z"), now),
            Status::Idle
        );
        let ahead = parse_status(&json("idle", "2026-10-12T08:07:00Z"), now);
        assert_eq!(ahead.status, Status::Unknown);
        assert!(ahead.unreadable);
        assert!(
            ahead.detail.contains("3 min in the future"),
            "{}",
            ahead.detail
        );
        assert!(ahead.detail.contains("PC clock"), "{}", ahead.detail);
        assert_eq!(status(&json("idle", "yesterday"), now), Status::Unknown);
        assert_eq!(status("not json", now), Status::Unknown);
        assert_eq!(status(r#"{"state":"idle"}"#, now), Status::Unknown);
        let bom = format!("\u{feff}{}", json("off", "2026-10-12T08:03:00Z"));
        assert_eq!(status(&bom, now), Status::Off);
    }

    #[test]
    fn applied_limits_parse_and_render() {
        let now = at("2026-10-12T08:01:00Z");
        let full = r#"{"state":"idle","updated":"2026-10-12T08:00:00Z","runner_count":2,"job_cpus":24,"job_memory_gib":72}"#;
        let snap = parse_status(full, now);
        assert_eq!(snap.applied.runner_count, Some(2));
        assert_eq!(
            snap.line(),
            "Idle \u{b7} 2 runners \u{b7} 24 cpu \u{b7} 72 GiB total"
        );
        let one = r#"{"state":"paused","updated":"2026-10-12T08:00:00Z","runner_count":1}"#;
        assert_eq!(parse_status(one, now).line(), "Paused \u{b7} 1 runner");
        let none = json("idle", "2026-10-12T08:00:00Z");
        assert_eq!(parse_status(&none, now).applied, Applied::default());
        assert_eq!(parse_status(&none, now).line(), "Idle");
        let stale = full.replace("08:00:00Z", "07:00:00Z");
        assert_eq!(
            parse_status(&stale, now).line(),
            "Unknown (supervisor not running)"
        );
        let bad = full.replace("24", r#""24""#);
        assert_eq!(parse_status(&bad, now).status, Status::Unknown);
    }

    #[test]
    fn missing_dir_and_missing_file() {
        let base = temp_base("missing");
        assert_eq!(
            read_status(&base, SystemTime::now()).status,
            Status::Unknown
        );
        assert_eq!(
            read_status(&base.join("nope"), SystemTime::now()).status,
            Status::NotInstalled
        );
        fs::remove_dir(inbox(&base)).unwrap();
        assert_eq!(
            read_status(&base, SystemTime::now()).status,
            Status::NotInstalled,
            "base without inbox"
        );
        fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn oversized_status_is_unknown() {
        let base = temp_base("oversized");
        let body = json("idle", &rfc(SystemTime::now()));
        let padded = |len: usize| format!("{body}{}", " ".repeat(len - body.len()));
        let limit = MAX_STATUS_BYTES as usize;
        fs::write(base.join("status.json"), padded(limit)).unwrap();
        assert_eq!(read_status(&base, SystemTime::now()).status, Status::Idle);
        fs::write(base.join("status.json"), padded(limit + 1)).unwrap();
        let big = read_status(&base, SystemTime::now());
        assert_eq!(big.status, Status::Unknown);
        assert!(
            big.unreadable && big.detail.contains("64 KiB"),
            "{}",
            big.detail
        );
        // Not touched for a while: the service is gone, whatever the file says.
        let old = SystemTime::now() - STALE_AFTER * 2;
        File::options()
            .write(true)
            .open(base.join("status.json"))
            .unwrap()
            .set_modified(old)
            .unwrap();
        let gone = read_status(&base, SystemTime::now());
        assert_eq!((gone.status, gone.unreadable), (Status::Unknown, false));
        // Fresh bytes that are not UTF-8.
        fs::write(base.join("status.json"), [0xff, 0xfe, 0x00]).unwrap();
        let bin = read_status(&base, SystemTime::now());
        assert!(
            bin.unreadable && bin.detail.contains("UTF-8"),
            "{}",
            bin.detail
        );
        fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn a_status_file_this_build_cannot_read_is_not_a_dead_service() {
        let now = at("2026-10-12T08:01:00Z");
        let t = "2026-10-12T08:00:00Z";
        let reason = |json: &str| {
            let s = parse_status(json, now);
            assert_eq!(s.status, Status::Unknown, "{json}");
            assert!(s.unreadable, "{json}");
            s.detail
        };
        assert!(reason("not json").contains("JSON"));
        assert!(reason(&json("bogus", t)).contains("\"bogus\""));
        assert!(reason(&json("idle", "yesterday")).contains("timestamp"));
        let typed = r#"{"state":"idle","updated":"2026-10-12T08:00:00Z","runner_count":"2"}"#;
        assert!(reason(typed).contains("JSON"));
        // Stale means the service stopped writing: that stays "not running".
        let stale = parse_status(&json("idle", t), at("2026-10-12T08:03:01Z"));
        assert_eq!((&stale.status, stale.unreadable), (&Status::Unknown, false));
        assert_eq!(stale.line(), "Unknown (supervisor not running)");
        let bad = parse_status("not json", now);
        assert_eq!(bad.line(), "Unknown (status file unreadable)");
        assert!(!Snapshot::bare(Status::Unknown).unreadable);
    }

    #[test]
    fn a_failed_atomic_write_leaves_no_tmp() {
        let base = temp_base("write-fail");
        let dest = base.join("dest");
        fs::create_dir(&dest).unwrap(); // a directory cannot be replaced by a file
        assert!(write_atomic(&dest, b"x").is_err());
        assert!(!base.join("dest.tmp").exists());
        fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn state_text() {
        assert_eq!(Status::NotInstalled.text(), "Not installed");
        assert_eq!(Status::Unknown.text(), "Unknown (supervisor not running)");
        assert_eq!(Status::Off.text(), "Off");
        assert_eq!(Status::Starting.text(), "Starting\u{2026}");
        assert_eq!(Status::Idle.text(), "Idle");
        assert_eq!(Status::Running("ci".into()).text(), "Running job ci");
        assert_eq!(Status::Running(String::new()).text(), "Running job");
        assert_eq!(Status::Draining.text(), "Draining\u{2026}");
        assert_eq!(Status::Paused.text(), "Paused");
        assert_eq!(Status::Error("boom".into()).text(), "Error: boom");
    }

    #[test]
    fn atomic_write_replaces_and_leaves_no_tmp() {
        let base = temp_base("write");
        let read = || -> serde_json::Value {
            serde_json::from_str(&fs::read_to_string(inbox(&base).join("state.json")).unwrap())
                .unwrap()
        };
        assert_eq!(read_desired(&base), Desired::Off, "missing file");
        write_desired(&base, Desired::On).unwrap();
        assert_eq!(read()["desired"], "on");
        assert_eq!(read_desired(&base), Desired::On);
        write_retry(&base, SystemTime::now()).unwrap();
        assert_eq!(read_desired(&base), Desired::On, "retry keeps on");
        write_desired(&base, Desired::Off).unwrap();
        assert_eq!(read()["desired"], "off");
        assert_eq!(read_desired(&base), Desired::Off);
        fs::write(inbox(&base).join("state.json"), r#"{"desired":"ON"}"#).unwrap();
        assert_eq!(read_desired(&base), Desired::Off, "exactly on");
        assert!(!inbox(&base).join("state.json.tmp").exists());
        assert!(
            !base.join("state.json").exists(),
            "writes stay in the inbox"
        );
        assert!(write_desired(&base.join("nope"), Desired::On).is_err());
        fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn restart_writes_on_after_off_or_times_out() {
        let base = temp_base("restart");
        let read = || fs::read_to_string(inbox(&base).join("state.json")).unwrap();
        let fresh = rfc(SystemTime::now());
        fs::write(base.join("status.json"), json("running", &fresh)).unwrap();
        assert_eq!(
            restart(&base, Duration::ZERO, Duration::ZERO).unwrap(),
            Restart::TimedOut
        );
        assert_eq!(
            read(),
            r#"{"desired":"on"}"#,
            "a timeout never leaves it off"
        );
        fs::write(base.join("status.json"), json("off", &fresh)).unwrap();
        assert_eq!(
            restart(&base, Duration::ZERO, Duration::ZERO).unwrap(),
            Restart::Done
        );
        assert_eq!(read(), r#"{"desired":"on"}"#);
        fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn restart_leaves_on_when_the_status_goes_unknown() {
        let base = temp_base("restart-unknown");
        // No status.json: the supervisor is not reporting.
        assert_eq!(
            restart(&base, Duration::ZERO, Duration::from_secs(60)).unwrap(),
            Restart::Unknown
        );
        assert_eq!(read_desired(&base), Desired::On);
        fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn restart_rides_out_one_unknown_status_read() {
        let base = temp_base("restart-blip");
        // The first read finds no status.json; the supervisor's `off` lands before the second.
        let supervisor = {
            let base = base.clone();
            thread::spawn(move || {
                thread::sleep(Duration::from_millis(20));
                let fresh = rfc(SystemTime::now());
                fs::write(base.join("status.json"), json("off", &fresh)).unwrap();
            })
        };
        assert_eq!(
            restart(&base, Duration::from_millis(300), Duration::from_secs(30)).unwrap(),
            Restart::Done
        );
        supervisor.join().unwrap();
        assert_eq!(read_desired(&base), Desired::On);
        fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn restart_stops_waiting_when_the_owner_presses_start() {
        let base = temp_base("restart-override");
        let fresh = rfc(SystemTime::now());
        fs::write(base.join("status.json"), json("running", &fresh)).unwrap();
        let owner = {
            let base = base.clone();
            thread::spawn(move || {
                thread::sleep(Duration::from_millis(50));
                write_desired(&base, Desired::On).unwrap();
            })
        };
        let started = Instant::now();
        assert_eq!(
            restart(&base, Duration::from_millis(5), Duration::from_secs(30)).unwrap(),
            Restart::Overridden
        );
        owner.join().unwrap();
        assert!(
            started.elapsed() < Duration::from_secs(10),
            "stopped waiting"
        );
        assert_eq!(read_desired(&base), Desired::On);
        fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn restart_that_cannot_write_is_an_error() {
        let base = temp_base("restart-io");
        assert!(restart(&base.join("nope"), Duration::ZERO, Duration::ZERO).is_err());
        fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn running_line_names_repo_and_job() {
        let now = at("2026-10-12T08:01:00Z");
        let running = |extra: &str| {
            parse_status(
                &format!(
                    r#"{{"state":"running","job":"Workspace","updated":"2026-10-12T08:00:00Z"{extra}}}"#
                ),
                now,
            )
        };
        let with_repo = running(r#","repo":"robagentic/Agent_Army_Professionals""#);
        assert_eq!(
            with_repo.line(),
            "Running Agent_Army_Professionals \u{b7} Workspace"
        );
        for no_repo in [
            running(""),
            running(r#","repo":"""#),
            running(r#","repo":null"#),
        ] {
            assert_eq!(no_repo.line(), "Running job Workspace");
        }
        let idle = parse_status(
            r#"{"state":"idle","updated":"2026-10-12T08:00:00Z","repo":"a/b"}"#,
            now,
        );
        assert_eq!(idle.line(), "Idle");
    }

    #[test]
    fn run_url_validation() {
        for good in [
            "https://github.com/robagentic/Agent_Army_Professionals/actions/runs/123456789",
            "https://github.com/a-b/c.d_e/actions/runs/1",
        ] {
            assert!(valid_run_url(good), "{good}");
        }
        for bad in [
            "",
            "javascript:alert(1)",
            "file:///C:/Windows/System32/calc.exe",
            "http://github.com/a/b/actions/runs/1",
            "https://github.com.evil.com/a/b/actions/runs/1",
            "https://evil.com/a/b/actions/runs/1",
            "https://gist.github.com/a/b/actions/runs/1",
            "https://github.com/a/b/actions/runs/1/",
            "https://github.com/a/b/actions/runs/1?x=1",
            "https://github.com/a/b/actions/runs/1#x",
            "https://github.com/a/b/actions/runs/1 & calc",
            "https://github.com/a/b/actions/runs/12a",
            "https://github.com/a/b/actions/runs/",
            "https://github.com//b/actions/runs/1",
            "https://github.com/a/b/c/actions/runs/1",
            "https://github.com/a/b%2Fc/actions/runs/1",
            " https://github.com/a/b/actions/runs/1",
        ] {
            assert!(!valid_run_url(bad), "{bad}");
        }
    }

    #[test]
    fn open_job_enabled_only_for_a_valid_url() {
        let now = at("2026-10-12T08:01:00Z");
        let snap = |url: &str| {
            parse_status(
                &format!(
                    r#"{{"state":"running","job":"j","updated":"2026-10-12T08:00:00Z","run_url":"{url}"}}"#
                ),
                now,
            )
        };
        let good = "https://github.com/a/b/actions/runs/7";
        assert_eq!(snap(good).job_url(), Some(good));
        assert_eq!(snap("").job_url(), None);
        assert_eq!(snap("javascript:alert(1)").job_url(), None);
        assert_eq!(
            parse_status(
                r#"{"state":"running","updated":"2026-10-12T08:00:00Z"}"#,
                now
            )
            .job_url(),
            None
        );
    }

    #[test]
    fn schema_three_has_no_disk_and_schema_four_publishes_it() {
        let now = at("2026-10-12T08:01:00Z");
        let old = r#"{"schema":3,"state":"idle","updated":"2026-10-12T08:00:00Z"}"#;
        let snap = parse_status(old, now);
        assert_eq!(snap.status, Status::Idle);
        assert_eq!(snap.work_disk_gib, None);
        assert!(!snap.cleaning);
        let new = r#"{"schema":4,"state":"idle","updated":"2026-10-12T08:00:00Z","work_disk_gib":100,"work_disk_free_gb":40,"work_disk_floor_gb":15,"cleaning":true}"#;
        let snap = parse_status(new, now);
        assert_eq!(snap.work_disk_gib, Some(100.0));
        assert_eq!(snap.work_disk_free_gb, Some(40.0));
        assert_eq!(snap.work_disk_floor_gb, Some(15.0));
        assert!(snap.cleaning);
        let newer = r#"{"schema":5,"state":"idle","updated":"2026-10-12T08:00:00Z"}"#;
        assert_eq!(
            parse_status(newer, now).status,
            Status::Error(NEWER_SCHEMA.into())
        );
    }

    #[test]
    fn status_v5_reads_the_contract_fixtures() {
        let now = at("2026-10-19T18:01:00Z");
        for name in [
            "mixed-five-slots",
            "storage-missing-and-untrusted",
            "storage-unconfigured",
            "windows-host-busy",
        ] {
            let v = parse_status_v5(&fixture(&format!("status-v5/valid/{name}.json")), now)
                .expect(name);
            assert_eq!(v.profile("linux").unwrap().os, "Linux", "{name}");
            assert_eq!(v.profile("windows").unwrap().os, "Windows", "{name}");
        }
        let v = parse_status_v5(&fixture("status-v5/valid/mixed-five-slots.json"), now).unwrap();
        assert!(v.takes_settings_v3());
        assert_eq!((v.capacity.used_slots, v.capacity.free_slots), (5, 0));
        assert_eq!(v.capacity.share_mode, "per_profile");
        let win = v.profile("windows").unwrap();
        assert_eq!((win.count, win.share_percent), (2, Some(30)));
        assert_eq!(
            win.profile_cap,
            Res {
                cpus: 9,
                mem_gib: 28
            }
        );
        assert_eq!(v.slots.len(), 5);
        assert_eq!(v.slots[3].os, "Windows");
        assert_eq!(v.slots[3].backend, "hyperv-vm");
        assert!(valid_run_url(&v.slots[0].run_url));
        assert!(
            v.windows_host().is_none(),
            "a VM profile is not the interim runner"
        );
    }

    #[test]
    fn status_v5_reads_the_interim_windows_runner() {
        let now = at("2026-10-19T18:01:00Z");
        let good = fixture("status-v5/valid/windows-host-busy.json");
        let v = parse_status_v5(&good, now).unwrap();
        let h = v.windows_host().expect("windows-host");
        assert_eq!((h.count, h.available), (0, true));
        assert_eq!(h.host_runner.as_deref(), Some("busy"));
        assert_eq!(h.host_state(), "busy");
        let online = good.replace(r#""host_runner": "busy""#, r#""host_runner": "online""#);
        assert_eq!(
            parse_status_v5(&online, now)
                .unwrap()
                .windows_host()
                .unwrap()
                .host_state(),
            "online"
        );
        let stopped = good.replace(
            "\"unavailable_reason\": \"\",\n      \"host_runner\": \"busy\"",
            "\"unavailable_reason\": \"runner listener not running\",\n      \"host_runner\": \"stopped\"",
        );
        let v = parse_status_v5(&stopped, now).unwrap();
        assert_eq!(
            v.windows_host().unwrap().host_state(),
            "stopped: runner listener not running"
        );
    }

    #[test]
    fn status_v5_is_ignored_when_newer_stale_or_unreadable() {
        let now = at("2026-10-19T18:01:00Z");
        let good = fixture("status-v5/valid/mixed-five-slots.json");
        assert!(parse_status_v5(&good, now).is_some());
        assert!(
            parse_status_v5(&format!("\u{feff}{good}"), now).is_some(),
            "BOM"
        );
        assert!(parse_status_v5(&fixture("status-v5/invalid/future-schema-6.json"), now).is_none());
        assert!(parse_status_v5(&good.replace("\"schema\": 5", "\"schema\": 4"), now).is_none());
        assert!(
            parse_status_v5(&good, at("2026-10-19T18:03:01Z")).is_none(),
            "stale after 180 s"
        );
        assert!(
            parse_status_v5(&good, at("2026-10-19T17:59:59Z")).is_none(),
            "an updated time in the future is stale"
        );
        assert!(parse_status_v5("not json", now).is_none());
        let one: serde_json::Value = serde_json::from_str(&good).unwrap();
        let mut one = one;
        one["profiles"].as_array_mut().unwrap().pop();
        assert!(
            parse_status_v5(&one.to_string(), now).is_none(),
            "both profiles or nothing"
        );
        let base = temp_base("status-v5");
        assert!(read_status_v5(&base, now).is_none(), "missing");
        fs::write(base.join("status.v5.json"), &good).unwrap();
        assert!(read_status_v5(&base, now).is_some());
        fs::write(
            base.join("status.v5.json"),
            format!("{good}{}", " ".repeat(64 * 1024)),
        )
        .unwrap();
        assert!(read_status_v5(&base, now).is_none(), "over 64 KiB");
        fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn pool_word_is_the_status_state() {
        assert_eq!(Status::Idle.pool_word(), "idle");
        assert_eq!(Status::Running("job".into()).pool_word(), "running");
        assert_eq!(Status::Running(String::new()).pool_word(), "running");
        assert_eq!(Status::Draining.pool_word(), "draining");
        assert_eq!(Status::Paused.pool_word(), "paused");
        assert_eq!(Status::Starting.pool_word(), "starting");
        assert_eq!(Status::Error("x".into()).pool_word(), "error");
        assert_eq!(Status::Off.pool_word(), "off");
        assert_eq!(Status::Unknown.pool_word(), "missing");
        assert_eq!(Status::NotInstalled.pool_word(), "missing");
    }
}
