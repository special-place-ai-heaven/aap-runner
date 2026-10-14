//! Elevated helper (`--helper <verb> <id>`) and the non-elevated side that asks for it.
//!
//! The tray writes `inbox\jobs\<id>.json` and starts this exe with `runas` (one UAC prompt).
//! The helper trusts nothing in that file except schema 1, a verb of `verify` or `repair`, and an
//! id of 16 lowercase hex digits that matches the command line. Every path is built from
//! `C:\ProgramData\aap-runner` plus that id. A reparse point on the way is refused, not followed.
//!
//! Progress lands in `jobs\<id>\` (`status.json`, `log.txt`, `exit.txt`), which the tray polls.
//! The work itself is the existing PowerShell scripts, embedded and written into that folder
//! before they run.
//!
//! ponytail: each run keeps its script copy under `jobs\<id>\scripts`. Delete old job folders by
//! hand; a cap is the upgrade if that directory grows.

use crate::state;
use crate::win;
use serde::{Deserialize, Serialize};
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufRead, BufReader, Read, Seek, SeekFrom, Write};
use std::os::windows::fs::MetadataExt;
use std::os::windows::process::CommandExt;
use std::path::{Component, Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

pub const DATA_DIR: &str = r"C:\ProgramData\aap-runner";
const REQUEST_MAX: u64 = 4096;
const STATUS_MAX: u64 = 64 * 1024;
const LOG_CAP: u64 = 1024 * 1024;
const LOG_TAIL_BYTES: u64 = 8192;
const REQUEST_WAIT: Duration = Duration::from_secs(180);
const POWERSHELL: &str = r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe";
const CREATE_NO_WINDOW: u32 = 0x0800_0000;
const REPARSE: u32 = 0x400;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verb {
    Verify,
    Repair,
}

impl Verb {
    pub fn as_str(self) -> &'static str {
        match self {
            Verb::Verify => "verify",
            Verb::Repair => "repair",
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Verb::Verify => "Verify",
            Verb::Repair => "Repair",
        }
    }

    fn parse(text: &str) -> Option<Self> {
        match text {
            "verify" => Some(Verb::Verify),
            "repair" => Some(Verb::Repair),
            _ => None,
        }
    }
}

#[derive(Debug, Clone)]
pub struct JobUi {
    pub verb: String,
    pub state: String,
    pub step: String,
    pub lines: Vec<String>,
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
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawRequest {
    schema: u32,
    id: String,
    verb: String,
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
    if raw.schema != 1 {
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
    Ok(verb)
}

enum ReqRead {
    Missing,
    Bad(String),
    Ready(Verb),
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
        Ok(verb) => ReqRead::Ready(verb),
        Err(e) => ReqRead::Bad(e),
    }
}

fn write_request(base: &Path, id: &str, verb: Verb) -> io::Result<()> {
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
    let body = format!(r#"{{"schema":1,"id":"{id}","verb":"{}"}}"#, verb.as_str());
    state::write_atomic(&path, body.as_bytes())
}

fn pointer_path() -> PathBuf {
    std::env::temp_dir()
        .join("aap-runner-tray")
        .join("helper.json")
}

fn write_pointer(id: &str, verb: Verb, error: &str) -> Result<(), String> {
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
    if !raw.error.is_empty() {
        return Some(JobUi {
            verb: raw.verb,
            state: "declined".into(),
            step: raw.error,
            lines: Vec::new(),
        });
    }
    let dir = job_dir(base, &raw.id);
    let status = read_status_file(&dir.join("status.json")).ok()??;
    if status.schema != 1 || status.id != raw.id || status.verb != raw.verb {
        return None;
    }
    Some(JobUi {
        verb: raw.verb,
        state: status.state,
        step: status.step,
        lines: log_tail(&dir.join("log.txt")),
    })
}

pub fn load_job(base: &Path) -> Option<JobUi> {
    load_job_from(&pointer_path(), base)
}

/// Write the request when `inbox\jobs` already exists, record the id for the window, and ask
/// Windows for one UAC prompt. If the folder does not exist yet, a background thread writes the
/// request once the elevated helper has created it.
pub fn launch(base: &Path, verb: Verb) -> Result<(), String> {
    let id = win::random_id().map_err(|e| e.to_string())?;
    write_pointer(&id, verb, "")?;
    let wrote = write_request(base, &id, verb).is_ok();
    if let Err(e) = win::shell_execute_runas(
        &std::env::current_exe().map_err(|e| e.to_string())?,
        &format!("--helper {} {id}", verb.as_str()),
    ) {
        let _ = write_pointer(&id, verb, &e);
        return Err(e);
    }
    if !wrote {
        let base = base.to_path_buf();
        thread::spawn(move || {
            let deadline = Instant::now() + REQUEST_WAIT;
            while Instant::now() < deadline {
                if write_request(&base, &id, verb).is_ok() {
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
    let out = Command::new(POWERSHELL)
        .args([
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
        .creation_flags(CREATE_NO_WINDOW)
        .output()
        .map_err(|e| e.to_string())?;
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

fn exe_ok(path: &str) -> bool {
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
    if verb == Verb::Repair
        && let Some(exe) = tray
    {
        cmd.args(["-TrayExe", exe]);
    }
    let mut child = cmd
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .creation_flags(CREATE_NO_WINDOW)
        .spawn()?;
    let log = job.join("log.txt");
    let id = job.file_name().and_then(|s| s.to_str()).unwrap_or("");
    stream_child(&mut child, &log, |line| {
        if !line.is_empty() {
            let _ = advance(job, id, verb.as_str(), "running", line, None);
        }
    })?;
    let status = child.wait()?;
    Ok(status.code().unwrap_or(1))
}

fn fail_job(job: &Path, id: &str, verb: &str, to: &str, step: &str, code: i32) -> i32 {
    let _ = advance(job, id, verb, to, step, Some(code));
    code
}

/// `--helper <verb> <id>`. Always uses [`DATA_DIR`]. Ignores `AAP_FAKE_BASE` and any path in the
/// request. Returns the process exit code.
pub fn run_elevated(verb_arg: &str, id: &str) -> i32 {
    let Some(verb) = Verb::parse(verb_arg) else {
        return 2;
    };
    if !valid_id(id) {
        return 2;
    }
    let base = PathBuf::from(DATA_DIR);
    let job = job_dir(&base, id);
    if ensure_real_dir(&job).is_err() {
        return 2;
    }
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
    let got = loop {
        match read_request(&path, verb.as_str(), id) {
            ReqRead::Ready(v) => break v,
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
    match run_script(&job, got, tray_exe_arg().as_deref()) {
        Ok(0) => fail_job(&job, id, got.as_str(), "passed", "done", 0),
        Ok(code) => fail_job(
            &job,
            id,
            got.as_str(),
            "failed",
            &format!("exit {code}"),
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
}
