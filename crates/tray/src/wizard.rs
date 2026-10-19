//! First-run state and checklists. Checks consume facts; collection never runs a WSL distro.

use crate::github_setup::Phase;
use crate::settings::{Settings, VmLimit};
use crate::{github_setup, helper, state};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::time::{Duration, Instant};

pub const RECHECK: Duration = Duration::from_secs(5);
pub const ADVANCE: Duration = Duration::from_secs(2);

#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Step {
    #[default]
    Prerequisites,
    Github,
    Identity,
    Sizing,
    Install,
    Done,
}

impl Step {
    pub fn label(self) -> &'static str {
        match self {
            Self::Prerequisites => "Prerequisites",
            Self::Github => "GitHub setup",
            Self::Identity => "Identity",
            Self::Sizing => "Sizing",
            Self::Install => "Install",
            Self::Done => "Done",
        }
    }

    pub fn next(self) -> Self {
        match self {
            Self::Prerequisites => Self::Github,
            Self::Github => Self::Identity,
            Self::Identity => Self::Sizing,
            Self::Sizing => Self::Install,
            Self::Install | Self::Done => Self::Done,
        }
    }

    pub fn previous(self) -> Self {
        match self {
            Self::Prerequisites | Self::Github => Self::Prerequisites,
            Self::Identity => Self::Github,
            Self::Sizing => Self::Identity,
            Self::Install => Self::Sizing,
            Self::Done => Self::Done,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Sizing {
    /// Linux runners.
    pub runner_count: u32,
    /// Pool totals, shared evenly by Linux and Windows runners.
    pub job_cpus: u32,
    pub job_memory_gib: u32,
    pub work_disk_gib: u32,
    /// Chosen only: no Windows backend is installed. Omitted from the draft when 0.
    #[serde(default, skip_serializing_if = "crate::settings::is_zero")]
    pub windows_runner_count: u32,
}

impl Default for Sizing {
    fn default() -> Self {
        Self {
            runner_count: 1,
            job_cpus: 2,
            job_memory_gib: 4,
            work_disk_gib: 60,
            windows_runner_count: 0,
        }
    }
}

impl Sizing {
    /// The settings this sizing makes: the Linux count with Linux's part of the pool totals.
    pub fn settings(&self) -> Settings {
        let (job_cpus, job_memory_gib) = crate::settings::linux_part(
            (self.job_cpus, self.job_memory_gib),
            self.runner_count,
            self.windows_runner_count,
        );
        Settings {
            runner_count: self.runner_count,
            windows_runner_count: self.windows_runner_count,
            job_cpus,
            job_memory_gib,
            ..Settings::default()
        }
    }

    /// What the installer gets: the Linux runners and their part of the pool, nothing Windows.
    pub fn linux(&self) -> Sizing {
        let s = self.settings();
        Sizing {
            job_cpus: s.job_cpus,
            job_memory_gib: s.job_memory_gib,
            windows_runner_count: 0,
            ..self.clone()
        }
    }

    pub fn check_shape(&self) -> Result<(), String> {
        self.settings().check_shape()?;
        if !(60..=512).contains(&self.work_disk_gib) {
            return Err("Work disk must be 60..512 GiB".into());
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Draft {
    pub schema: u32,
    pub step: Step,
    pub sizing: Sizing,
    #[serde(default)]
    pub submitted: bool,
    #[serde(default)]
    pub job_id: Option<String>,
    #[serde(default)]
    pub operator_ready: bool,
    #[serde(default)]
    pub process: Option<crate::win::ProcessIdentity>,
}

impl Default for Draft {
    fn default() -> Self {
        Self {
            schema: 1,
            step: Step::Prerequisites,
            sizing: Sizing::default(),
            submitted: false,
            job_id: None,
            operator_ready: false,
            process: None,
        }
    }
}

pub fn parse_draft(text: &str) -> Option<Draft> {
    let draft: Draft = serde_json::from_str(text).ok()?;
    (draft.schema == 1 && draft.sizing.check_shape().is_ok()).then_some(draft)
}

pub fn draft_path() -> PathBuf {
    github_setup::data_file("jobs")
        .join("install")
        .join("state.json")
}

/// An existing supervisor install wins over a stale local draft. An unfinished helper journal
/// keeps the wizard available even after the helper created inbox before failing.
pub fn needed(base: &Path) -> bool {
    let pending = helper::install_checkpoint(base).is_some_and(|s| s.step != "done");
    let draft_pending = !base.join("config.json").exists()
        && state::read_bounded(&draft_path())
            .and_then(|s| parse_draft(&s))
            .is_some_and(|d| d.submitted);
    pending || draft_pending || (!base.join("inbox").exists() && !base.join("config.json").exists())
}

#[derive(Clone, Debug, Deserialize)]
pub struct Facts {
    pub build: u32,
    pub virtualization: bool,
    pub wsl_version: String,
    pub operator_wsl2: bool,
    pub allow_disk_mount: bool,
    pub free_gib: u64,
    pub admin_available: bool,
    pub github: bool,
    pub cpus: u32,
    pub memory_gib: u32,
    pub wslconfig: String,
}

impl Facts {
    pub fn vm(&self) -> VmLimit {
        let (cpus, memory) = crate::settings::parse_wslconfig(&self.wslconfig);
        // WSL defaults to half of physical RAM. Never assume this PC has the owner's 80 GiB VM.
        VmLimit {
            cpus: cpus.unwrap_or(self.cpus).min(self.cpus).min(28),
            gib: memory
                .unwrap_or(self.memory_gib / 2)
                .min(self.memory_gib)
                .min(80),
            assumed: memory.is_none() || cpus.is_none(),
        }
    }
}

#[derive(Clone, Debug)]
pub struct Row {
    pub title: &'static str,
    pub phase: Phase,
    pub missing: String,
    pub link: Option<&'static str>,
    pub command: Option<&'static str>,
}

fn row(
    title: &'static str,
    ok: bool,
    missing: impl Into<String>,
    link: Option<&'static str>,
    command: Option<&'static str>,
) -> Row {
    Row {
        title,
        phase: if ok { Phase::Met } else { Phase::Unmet },
        missing: if ok { String::new() } else { missing.into() },
        link,
        command,
    }
}

fn nat(text: &str) -> bool {
    let mut section = false;
    let mut result = true;
    for line in text
        .lines()
        .map(str::trim)
        .filter(|l| !l.starts_with(['#', ';']))
    {
        if line.starts_with('[') {
            section = line.eq_ignore_ascii_case("[wsl2]");
        }
        if section
            && let Some((key, value)) = line.split_once('=')
            && key.trim().eq_ignore_ascii_case("networkingMode")
        {
            result = value.trim().eq_ignore_ascii_case("nat");
        }
    }
    result
}

pub fn prerequisites(
    facts: Option<&Facts>,
    error: Option<&str>,
    gate: Result<(), String>,
    operator_ready: bool,
) -> Vec<Row> {
    let Some(f) = facts else {
        return [
            "Windows 11",
            "Virtualization",
            "WSL2",
            "Ubuntu 24.04 operator distro",
            "Disk mount policy",
            "WSL networking",
            "Free disk",
            "Administrator",
            "GitHub",
            "Installer location",
        ]
        .into_iter()
        .map(|title| Row {
            title,
            phase: if error.is_some() {
                Phase::Unmet
            } else {
                Phase::Checking
            },
            missing: error.unwrap_or_default().into(),
            link: None,
            command: None,
        })
        .collect();
    };
    let wsl_ok = f
        .wsl_version
        .split('.')
        .next()
        .and_then(|s| s.parse::<u32>().ok())
        .is_some_and(|v| v >= 2);
    vec![
        row(
            "Windows 11",
            f.build >= 22000,
            format!(
                "Windows 11 build 22000 or newer is required; detected {}.",
                f.build
            ),
            Some("ms-settings:windowsupdate"),
            None,
        ),
        row(
            "Virtualization",
            f.virtualization,
            "Hardware virtualization is disabled. Enable Intel VT-x or AMD-V in firmware, then restart Windows.",
            Some("ms-settings:recovery"),
            None,
        ),
        row(
            "WSL2",
            wsl_ok,
            format!(
                "WSL 2.0 or newer is required; detected '{}'. Install or update WSL, then reboot if Windows requests it.",
                f.wsl_version
            ),
            Some("https://learn.microsoft.com/windows/wsl/install"),
            Some("wsl --install --no-distribution; wsl --update"),
        ),
        row(
            "Ubuntu 24.04 operator distro",
            f.operator_wsl2,
            "Install and initialize Ubuntu-24.04 as WSL2, with curl, jq and sha256sum. Ubuntu 26.04 is not supported.",
            Some("https://apps.microsoft.com/detail/9nz3klhxdjp5"),
            Some(
                "wsl --install -d Ubuntu-24.04\nwsl -d Ubuntu-24.04 -- sudo apt-get install -y curl jq coreutils",
            ),
        ),
        Row {
            phase: if !f.operator_wsl2 {
                Phase::Blocked
            } else if operator_ready {
                Phase::Met
            } else {
                Phase::Unmet
            },
            ..row(
                "Operator tools (manual confirmation)",
                false,
                "Confirm Ubuntu-24.04 opens normally and curl, jq, sha256sum and /mnt/c are available. The installer verifies them before changing the host.",
                None,
                Some(
                    "wsl -d Ubuntu-24.04 -- sh -c 'command -v curl && command -v jq && command -v sha256sum && mountpoint -q /mnt/c'",
                ),
            )
        },
        row(
            "Disk mount policy",
            f.allow_disk_mount,
            "AllowDiskMount policy disables WSL disk mounting. Ask the Windows administrator to enable it.",
            Some("https://learn.microsoft.com/windows/wsl/intune"),
            None,
        ),
        row(
            "WSL networking",
            nat(&f.wslconfig),
            "Set networkingMode=nat in [wsl2] in your .wslconfig, then restart WSL only after other jobs finish.",
            Some("https://learn.microsoft.com/windows/wsl/wsl-config"),
            None,
        ),
        row(
            "Free disk",
            f.free_gib >= 70,
            format!(
                "C: needs at least 70 GiB free for the smallest disk and install files; {} GiB is free.",
                f.free_gib
            ),
            Some("ms-settings:storagesense"),
            None,
        ),
        row(
            "Administrator",
            f.admin_available,
            "An administrator account and enabled UAC service are required to approve installation.",
            Some("ms-settings:otherusers"),
            None,
        ),
        row(
            "GitHub",
            f.github,
            "HTTPS to github.com failed. Restore internet access and allow github.com on TCP 443, then re-check.",
            Some("ms-settings:network-status"),
            None,
        ),
        row(
            "Installer location",
            gate.is_ok(),
            gate.err().unwrap_or_default(),
            None,
            None,
        ),
    ]
}

pub fn sizing_rows(size: &Sizing, facts: Option<&Facts>) -> Vec<Row> {
    let Some(f) = facts else {
        return vec![Row {
            title: "Capacity",
            phase: Phase::Blocked,
            missing: "Complete prerequisite checks first.".into(),
            link: None,
            command: None,
        }];
    };
    let limits = size.settings().validate(&f.vm());
    let disk = (60..=512).contains(&size.work_disk_gib);
    vec![
        row(
            "Runner resources",
            limits.is_ok(),
            limits.err().unwrap_or_default(),
            None,
            None,
        ),
        row(
            "Work disk",
            disk,
            "Work disk must be 60..512 GiB.",
            None,
            None,
        ),
        row(
            "Disk capacity",
            f.free_gib >= u64::from(size.work_disk_gib) + 10,
            format!(
                "C: needs {} GiB free (disk plus 10 GiB installation headroom); {} GiB is free.",
                size.work_disk_gib + 10,
                f.free_gib
            ),
            Some("ms-settings:storagesense"),
            None,
        ),
    ]
}

/// `Linux each: 1 CPUs, 2 GiB`, and the Windows line while Windows runners are chosen; every
/// runner gets an even share of the pool totals whatever its OS.
pub fn sizing_each(size: &Sizing) -> Vec<String> {
    let s = size.settings();
    let line = |os: &str, n: u32, cpus: u32, gib: u32| {
        format!(
            "{os} each: {} CPUs, {} GiB",
            crate::settings::share_text(cpus, n),
            crate::settings::share_text(gib, n)
        )
    };
    let mut lines = vec![line("Linux", s.runner_count, s.job_cpus, s.job_memory_gib)];
    if size.windows_runner_count > 0 {
        lines.push(line(
            "Windows",
            size.windows_runner_count,
            size.job_cpus.saturating_sub(s.job_cpus),
            size.job_memory_gib.saturating_sub(s.job_memory_gib),
        ));
    }
    lines
}

pub fn all_met(rows: &[Row]) -> bool {
    !rows.is_empty() && rows.iter().all(|r| r.phase == Phase::Met)
}

pub struct Wizard {
    pub draft: Draft,
    pub facts: Option<Facts>,
    pub error: Option<String>,
    pub launch_error: Option<String>,
    pub job: Option<helper::JobUi>,
    pub met_at: Option<Instant>,
    path: PathBuf,
    checked: Option<Instant>,
    collecting: Option<mpsc::Receiver<Result<Facts, String>>>,
}

impl Wizard {
    pub fn load(base: &Path, path: PathBuf) -> Self {
        let mut draft = state::read_bounded(&path)
            .and_then(|s| parse_draft(&s))
            .unwrap_or_default();
        if let Some(checkpoint) = helper::install_checkpoint(base) {
            draft.step = if checkpoint.step == "done" {
                Step::Done
            } else {
                Step::Install
            };
            draft.sizing = checkpoint.sizing();
            if !draft.submitted {
                draft.job_id = Some(checkpoint.job_id);
            }
        } else if matches!(draft.step, Step::Done) {
            // A user-owned file cannot assert that the elevated installation succeeded.
            draft.step = Step::Prerequisites;
        }
        Self {
            draft,
            facts: None,
            error: None,
            launch_error: None,
            job: None,
            met_at: None,
            path,
            checked: None,
            collecting: None,
        }
    }

    pub fn save(&mut self) -> bool {
        let result = (|| -> Result<(), String> {
            std::fs::create_dir_all(self.path.parent().ok_or("wizard state path")?)
                .map_err(|e| e.to_string())?;
            let bytes = serde_json::to_vec(&self.draft).map_err(|e| e.to_string())?;
            state::write_atomic(&self.path, &bytes).map_err(|e| e.to_string())
        })();
        if let Err(e) = result {
            self.error = Some(format!("Could not save setup progress: {e}"));
            return false;
        }
        true
    }

    pub fn go(&mut self, step: Step) {
        let previous = self.draft.step;
        self.draft.step = step;
        self.met_at = None;
        if !self.save() {
            self.draft.step = previous;
        }
    }

    pub fn advance(&mut self, met: bool, now: Instant) -> bool {
        if !met {
            self.met_at = None;
            return false;
        }
        now.saturating_duration_since(*self.met_at.get_or_insert(now)) >= ADVANCE
    }

    pub fn recheck(&mut self) {
        self.checked = None;
        self.facts = None;
        self.collecting = None;
        self.met_at = None;
    }

    pub fn tick(&mut self, base: &Path) {
        if let Some(rx) = &self.collecting
            && let Ok(result) = rx.try_recv()
        {
            self.collecting = None;
            self.checked = Some(Instant::now());
            match result {
                Ok(f) => {
                    self.facts = Some(f);
                    self.error = None;
                }
                Err(e) => {
                    self.facts = None;
                    self.error = Some(e);
                }
            }
        }
        if self.collecting.is_none()
            && self.checked.is_none_or(|at| at.elapsed() >= RECHECK)
            && !matches!(self.draft.step, Step::Install | Step::Done)
        {
            let (tx, rx) = mpsc::channel();
            self.collecting = Some(rx);
            std::thread::spawn(move || {
                let _ = tx.send(collect());
            });
        }
        if self.draft.step == Step::Install {
            let job = helper::load_job(base)
                .filter(|j| j.verb == "install")
                .or_else(|| {
                    if let Some(id) = &self.draft.job_id {
                        return helper::resume_install_id(base, id);
                    }
                    helper::resume_install_job(base)
                });
            let alive = self.draft.process.and_then(crate::win::process_alive);
            self.observe_job(
                job,
                alive,
                helper::install_checkpoint(base).is_some_and(|s| s.step == "done"),
            );
        }
    }

    /// Injected observation keeps failure/reopen behavior testable without a helper process.
    fn observe_job(&mut self, job: Option<helper::JobUi>, alive: Option<bool>, installed: bool) {
        self.job = job;
        if self.job.as_ref().is_none_or(|j| j.active()) && alive == Some(false) {
            self.launch_error = Some("The previous installer process exited before completing setup. Retry resumes its saved steps.".into());
            self.job = None;
            if self.draft.submitted {
                self.draft.submitted = false;
                self.save();
            }
        }
        if self.job.as_ref().is_some_and(|j| !j.active()) && self.draft.submitted {
            self.draft.submitted = false;
            self.save();
        }
        if self.job.as_ref().is_some_and(|j| j.state == "passed") && installed {
            self.go(Step::Done);
        }
    }
}

fn collect() -> Result<Facts, String> {
    use std::io::Read;
    use std::os::windows::process::CommandExt;
    use std::process::{Command, Stdio};
    let mut command = Command::new(r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe");
    command
        .args([
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            include_str!("prerequisites.ps1"),
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .creation_flags(0x0800_0000)
        .env("PATH", r"C:\Windows\System32")
        .env_remove("PSExecutionPolicyPreference")
        .env(
            "PSModulePath",
            crate::win::machine_ps_module_path().map_err(|e| e.to_string())?,
        );
    let mut child = command.spawn().map_err(|_| {
        "Could not start prerequisite checks. Re-check after Windows PowerShell is available."
            .to_string()
    })?;
    let stdout = child
        .stdout
        .take()
        .ok_or("Prerequisite output pipe is unavailable")?;
    // Drain while the process runs: a quoted .wslconfig can exceed a Windows pipe buffer.
    let reader = std::thread::spawn(move || {
        let mut bytes = Vec::new();
        stdout.take(16385).read_to_end(&mut bytes).map(|_| bytes)
    });
    let start = Instant::now();
    loop {
        if child.try_wait().map_err(|e| e.to_string())?.is_some() {
            break;
        }
        if start.elapsed() >= Duration::from_secs(15) {
            let _ = child.kill();
            let _ = child.wait();
            let _ = reader.join();
            return Err("Prerequisite checks timed out after 15 s. Check Windows services and network, then re-check.".into());
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    let status = child.wait().map_err(|e| e.to_string())?;
    let output = reader
        .join()
        .map_err(|_| "Prerequisite output reader failed")?
        .map_err(|e| e.to_string())?;
    if !status.success() || output.len() > 16384 {
        return Err("Prerequisite checks failed. Open Windows settings, resolve pending updates, and re-check.".into());
    }
    serde_json::from_slice(&output).map_err(|_| "Prerequisite checks returned an invalid result. Re-check after Windows PowerShell is available.".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn facts() -> Facts {
        Facts {
            build: 26100,
            virtualization: true,
            wsl_version: "2.6.1".into(),
            operator_wsl2: true,
            allow_disk_mount: true,
            free_gib: 300,
            admin_available: true,
            github: true,
            cpus: 16,
            memory_gib: 64,
            wslconfig: "[wsl2]\nprocessors=12\nmemory=24GB".into(),
        }
    }

    #[test]
    fn prerequisite_failures_name_the_missing_item_and_action() {
        assert!(all_met(&prerequisites(Some(&facts()), None, Ok(()), true)));
        let mut f = facts();
        f.build = 19045;
        f.virtualization = false;
        f.operator_wsl2 = false;
        f.wsl_version.clear();
        f.allow_disk_mount = false;
        f.github = false;
        f.free_gib = 10;
        f.admin_available = false;
        f.wslconfig = "[wsl2]\nnetworkingMode=mirrored".into();
        let rows = prerequisites(Some(&f), None, Ok(()), true);
        assert_eq!(rows.iter().filter(|r| r.phase == Phase::Unmet).count(), 9);
        assert!(
            rows.iter()
                .filter(|r| r.phase == Phase::Unmet)
                .all(|r| !r.missing.is_empty() && (r.link.is_some() || r.command.is_some()))
        );
        assert!(!all_met(&rows));
        assert!(
            prerequisites(None, None, Ok(()), false)
                .iter()
                .all(|r| r.phase == Phase::Checking)
        );
    }

    #[test]
    fn sizing_is_bounded_by_actual_host_and_disk() {
        let f = facts();
        assert!(all_met(&sizing_rows(&Sizing::default(), Some(&f))));
        for bad in [
            Sizing {
                runner_count: 6,
                ..Sizing::default()
            },
            Sizing {
                job_cpus: 11,
                ..Sizing::default()
            },
            Sizing {
                job_memory_gib: 17,
                ..Sizing::default()
            },
            Sizing {
                work_disk_gib: 291,
                ..Sizing::default()
            },
        ] {
            assert!(!all_met(&sizing_rows(&bad, Some(&f))));
        }
        let mut f = f;
        f.wslconfig.clear();
        f.cpus = 4;
        f.memory_gib = 16;
        assert_eq!(f.vm().cap(), (2, 0));
        assert!(!all_met(&sizing_rows(&Sizing::default(), Some(&f))));
    }

    #[test]
    fn steps_resume_and_only_advance_after_two_seconds_of_met_rows() {
        let base = state::temp_base("wizard-resume");
        let path = base.join("draft/state.json");
        let mut w = Wizard::load(&base, path.clone());
        let now = Instant::now();
        assert!(!w.advance(false, now));
        assert!(!w.advance(true, now));
        assert!(!w.advance(true, now + Duration::from_secs(1)));
        assert!(w.advance(true, now + ADVANCE));
        assert!(!w.advance(false, now + ADVANCE));
        for step in [Step::Github, Step::Identity, Step::Sizing, Step::Install] {
            assert_eq!(w.draft.step.next(), step);
            w.go(step);
            assert_eq!(Wizard::load(&base, path.clone()).draft.step, step);
        }
        w.go(Step::Done);
        assert_eq!(Wizard::load(&base, path).draft.step, Step::Prerequisites);
        let _ = std::fs::remove_dir_all(base);
    }

    #[test]
    fn malformed_or_future_state_never_skips_checks() {
        for text in [
            "{}",
            "{\"schema\":2,\"step\":\"done\",\"sizing\":{}}",
            "not json",
        ] {
            assert!(parse_draft(text).is_none());
        }
        let mut draft = Draft::default();
        draft.sizing.runner_count = 6;
        assert!(parse_draft(&serde_json::to_string(&draft).unwrap()).is_none());
    }

    #[test]
    fn install_failure_and_orphan_recovery_preserve_sizing_across_reopen() {
        let base = state::temp_base("wizard-failure");
        let path = base.join("draft/state.json");
        let mut w = Wizard::load(&base, path.clone());
        w.draft.sizing.work_disk_gib = 100;
        w.draft.submitted = true;
        w.go(Step::Install);
        let running = helper::JobUi {
            verb: "install".into(),
            state: "running".into(),
            step: "host".into(),
            exit_code: None,
            lines: vec![],
            app_token: None,
        };
        w.observe_job(Some(running.clone()), Some(true), false);
        assert!(w.draft.submitted && w.job.as_ref().unwrap().active());
        for _ in 0..2 {
            w.observe_job(Some(running.clone()), Some(false), false);
            assert!(!w.draft.submitted);
            assert!(w.job.is_none());
            assert!(w.launch_error.is_some());
        }
        let mut reopened = Wizard::load(&base, path);
        reopened.observe_job(Some(running.clone()), Some(false), false);
        assert!(!reopened.draft.submitted && reopened.job.is_none());
        assert_eq!(reopened.draft.sizing.work_disk_gib, 100);
        let passed = helper::JobUi {
            state: "passed".into(),
            ..running
        };
        reopened.observe_job(Some(passed.clone()), Some(false), false);
        assert_eq!(reopened.draft.step, Step::Install);
        reopened.observe_job(Some(passed), Some(false), true);
        assert_eq!(reopened.draft.step, Step::Done);
        let _ = std::fs::remove_dir_all(base);
    }

    #[test]
    fn fix_discards_an_inflight_old_result_and_resets_advance_timer() {
        let base = state::temp_base("wizard-recheck");
        let mut w = Wizard::load(&base, base.join("draft/state.json"));
        let (tx, rx) = mpsc::channel();
        w.collecting = Some(rx);
        w.facts = Some(facts());
        w.advance(true, Instant::now());
        w.recheck();
        assert!(w.collecting.is_none() && w.facts.is_none() && w.met_at.is_none());
        assert!(
            tx.send(Ok(facts())).is_err(),
            "the pre-Fix observation must not be reused"
        );
    }

    #[test]
    fn networking_uses_only_the_wsl2_section() {
        assert!(nat("# networkingMode=mirrored\n[wsl2]\nnetworkingMode=nat"));
        assert!(nat("[experimental]\nnetworkingMode=mirrored"));
        assert!(!nat("[wsl2]\nnetworkingMode=mirrored"));
    }

    #[test]
    fn windows_runners_share_the_pool_but_the_installer_gets_linux_only() {
        let size = Sizing {
            runner_count: 3,
            windows_runner_count: 2,
            job_cpus: 20,
            job_memory_gib: 40,
            ..Sizing::default()
        };
        assert_eq!(size.check_shape(), Ok(()));
        let s = size.settings();
        assert_eq!((s.runner_count, s.job_cpus, s.job_memory_gib), (3, 12, 24));
        assert_eq!(
            sizing_each(&size),
            [
                "Linux each: 4 CPUs, 8 GiB".to_string(),
                "Windows each: 4 CPUs, 8 GiB".to_string()
            ]
        );
        let linux = size.linux();
        assert_eq!(
            (
                linux.runner_count,
                linux.windows_runner_count,
                linux.job_cpus,
                linux.job_memory_gib,
                linux.work_disk_gib
            ),
            (3, 0, 12, 24, 60)
        );
        assert_eq!(
            sizing_each(&Sizing::default()),
            ["Linux each: 2 CPUs, 4 GiB"]
        );
        for (l, w) in [(4, 2), (0, 1), (0, 0), (1, 5)] {
            let bad = Sizing {
                runner_count: l,
                windows_runner_count: w,
                ..Sizing::default()
            };
            assert!(bad.check_shape().is_err(), "{l}+{w}");
        }
        let thin = Sizing {
            runner_count: 1,
            windows_runner_count: 4,
            job_cpus: 4,
            ..Sizing::default()
        };
        assert!(
            thin.check_shape().is_err(),
            "4 CPUs over 5 runners leave Linux 0"
        );
    }

    #[test]
    fn drafts_keep_the_windows_count_and_read_without_it() {
        let mut draft = Draft::default();
        let text = serde_json::to_string(&draft).unwrap();
        assert!(!text.contains("windows_runner_count"), "0 is not written");
        assert_eq!(parse_draft(&text).unwrap().sizing, Sizing::default());
        draft.sizing.windows_runner_count = 2;
        draft.sizing.runner_count = 3;
        draft.sizing.job_cpus = 10;
        draft.sizing.job_memory_gib = 20;
        let back = parse_draft(&serde_json::to_string(&draft).unwrap()).unwrap();
        assert_eq!(back.sizing, draft.sizing);
        draft.sizing.windows_runner_count = 3;
        assert!(parse_draft(&serde_json::to_string(&draft).unwrap()).is_none());
    }
}
