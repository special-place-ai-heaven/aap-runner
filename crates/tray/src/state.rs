//! Pure file contract. Trust split: the tray writes only under `<base>\inbox\`
//! (`state.json`, `settings.json`, `tray.log`); it reads the admin-written `<base>\status.json`.
//! No UI here.

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

/// A slot state word. Anything else shows as Starting: the slot exists, its state says no more.
fn slot_sym(state: &str) -> Sym {
    match state {
        "idle" => Sym::Idle,
        "running" => Sym::Running,
        "draining" => Sym::Draining,
        "error" => Sym::Error,
        _ => Sym::Starting,
    }
}

/// Missing inbox = not installed; missing/bad/stale/oversized status.json = unknown.
pub fn read_status(base: &Path, now: SystemTime) -> Snapshot {
    if !inbox(base).is_dir() {
        return Snapshot::bare(Status::NotInstalled);
    }
    match read_bounded(&base.join("status.json")) {
        Some(json) => parse_status(&json, now),
        None => Snapshot::bare(Status::Unknown),
    }
}

pub fn parse_status(json: &str, now: SystemTime) -> Snapshot {
    let unknown = Snapshot::bare(Status::Unknown);
    // PowerShell 5 writes UTF-8 with a BOM.
    let Ok(raw) = serde_json::from_str::<RawStatus>(json.trim_start_matches('\u{feff}')) else {
        return unknown;
    };
    let Some(updated) = parse_rfc3339(&raw.updated) else {
        return unknown;
    };
    // A timestamp in the future (clock skew) counts as fresh.
    if now
        .duration_since(updated)
        .is_ok_and(|age| age > STALE_AFTER)
    {
        return Snapshot {
            updated: Some(updated),
            ..unknown
        };
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
        _ => return unknown,
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
    }
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
    {
        let mut f = File::create(&tmp)?;
        f.write_all(bytes)?;
        f.sync_all()?;
    }
    // std::fs::rename replaces the destination on Windows (MOVEFILE_REPLACE_EXISTING).
    fs::rename(&tmp, path)
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

/// Write off, wait until the supervisor reports `off`, then write on.
/// Returns `Ok(false)` on timeout, leaving desired = off.
pub fn restart(base: &Path, poll: Duration, timeout: Duration) -> io::Result<bool> {
    write_desired(base, Desired::Off)?;
    let deadline = Instant::now() + timeout;
    loop {
        if read_status(base, SystemTime::now()).status == Status::Off {
            write_desired(base, Desired::On)?;
            return Ok(true);
        }
        if Instant::now() >= deadline {
            return Ok(false);
        }
        thread::sleep(poll);
    }
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
        assert_eq!(
            status(&json("idle", "2099-01-01T00:00:00Z"), now),
            Status::Idle
        );
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
        let body = json("idle", "2099-01-01T00:00:00Z");
        let padded = |len: usize| format!("{body}{}", " ".repeat(len - body.len()));
        let limit = MAX_STATUS_BYTES as usize;
        fs::write(base.join("status.json"), padded(limit)).unwrap();
        assert_eq!(read_status(&base, SystemTime::now()).status, Status::Idle);
        fs::write(base.join("status.json"), padded(limit + 1)).unwrap();
        assert_eq!(
            read_status(&base, SystemTime::now()).status,
            Status::Unknown
        );
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
        // A future timestamp counts as fresh, so the test needs no clock formatting.
        fs::write(
            base.join("status.json"),
            json("running", "2099-01-01T00:00:00Z"),
        )
        .unwrap();
        assert!(!restart(&base, Duration::ZERO, Duration::ZERO).unwrap());
        assert_eq!(read(), r#"{"desired":"off"}"#);
        fs::write(
            base.join("status.json"),
            json("off", "2099-01-01T00:00:00Z"),
        )
        .unwrap();
        assert!(restart(&base, Duration::ZERO, Duration::ZERO).unwrap());
        assert_eq!(read(), r#"{"desired":"on"}"#);
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
}
