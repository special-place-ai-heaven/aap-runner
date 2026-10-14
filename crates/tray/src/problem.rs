//! Error classes: what a supervisor `detail` means in one plain line, and the one action that
//! helps. The matchers are hand-written equivalents of the design's regex table (there is no
//! regex crate in the tree). Also the `logs\supervisor.log` tail the error panel shows.

use crate::state::{Snapshot, Status, parse_rfc3339};
use serde::{Deserialize, Serialize};
use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom};
use std::path::Path;
use std::time::{Duration, SystemTime};

/// `$AapOldManager` in `supervisor/aap-runner-supervisor.ps1`, verbatim.
pub const OLD_MANAGER: &str =
    "manager on the distro predates this supervisor; re-run install-host.ps1 from this branch";

/// The log tail read for the error panel.
pub const LOG_TAIL_BYTES: u64 = 64 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Class {
    /// The mount task failed; the supervisor retries with backoff.
    Mount,
    /// `OLD_MANAGER` and the last probe exited 1.
    ManagerOld,
    /// `OLD_MANAGER` and the last probe exited otherwise (timeout, missing file).
    Probe,
    RestartLoop,
    LimitsRefused,
    /// Tray-derived: `status.json` missing or stale.
    SupervisorDown,
    /// Log-only: a drain hit its time limit.
    DrainTimeout,
    Other,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    Retry,
    Settings,
    RestartService,
    OpenLogs,
    Repair,
}

impl Action {
    pub fn label(self) -> &'static str {
        match self {
            Action::Retry => "Retry now",
            Action::Settings => "Settings\u{2026}",
            Action::RestartService => "Restart service",
            Action::OpenLogs => "Open logs",
            Action::Repair => "Repair install",
        }
    }
}

impl Class {
    /// The primary action. An old manager is repaired from the elevated helper.
    pub fn action(self) -> Action {
        match self {
            Class::Mount | Class::Probe | Class::RestartLoop => Action::Retry,
            Class::LimitsRefused => Action::Settings,
            Class::SupervisorDown => Action::RestartService,
            Class::ManagerOld => Action::Repair,
            Class::DrainTimeout | Class::Other => Action::OpenLogs,
        }
    }

    /// Log lines worth showing for this class (every `WARN` line is shown too).
    fn keywords(self) -> &'static [&'static str] {
        match self {
            Class::Mount => &["Mount", "LastTaskResult", "could not start", "status error"],
            Class::ManagerOld | Class::Probe => &["probe", "predates", "status error"],
            Class::RestartLoop => &["unhealthy", "after start", "systemctl", "status error"],
            Class::LimitsRefused => &["limits", "status paused", "status error"],
            Class::DrainTimeout => &["drain"],
            Class::SupervisorDown => &["supervisor", "ERROR"],
            Class::Other => &["status error", "ERROR"],
        }
    }
}

/// The current problem, if any: an error state, a stale or missing status, or a refused limit
/// while paused. `probe_exit` is the last `WARN probe exit N` from the log.
pub fn current(snap: &Snapshot, probe_exit: Option<i64>) -> Option<Class> {
    match &snap.status {
        Status::Unknown => Some(Class::SupervisorDown),
        Status::Error(detail) => Some(classify(detail, probe_exit)),
        Status::Paused if limits_refused(&snap.detail) => Some(Class::LimitsRefused),
        _ => None,
    }
}

pub fn classify(detail: &str, probe_exit: Option<i64>) -> Class {
    if detail == OLD_MANAGER {
        // No probe line in the log: the detail itself says the manager is old.
        return if probe_exit.is_none_or(|n| n == 1) {
            Class::ManagerOld
        } else {
            Class::Probe
        };
    }
    if mount_failed(detail) {
        Class::Mount
    } else if restart_loop(detail).is_some() {
        Class::RestartLoop
    } else if limits_refused(detail) {
        Class::LimitsRefused
    } else {
        Class::Other
    }
}

/// The plain one-liner. `age` is how old `status.json` is (Supervisor down only).
pub fn one_liner(class: Class, detail: &str, age: Option<Duration>) -> String {
    match class {
        Class::Mount => match retry_secs(detail) {
            Some(n) => format!("The work disk could not be attached. Next try in {n} s."),
            None => "The work disk could not be attached.".into(),
        },
        Class::ManagerOld => "The runner software inside WSL is older than this app.".into(),
        Class::Probe => "WSL did not answer the version check.".into(),
        Class::RestartLoop => match restart_loop(detail) {
            Some(n) => format!("The runner service keeps stopping ({n} restarts)."),
            None => "The runner service keeps stopping.".into(),
        },
        Class::LimitsRefused => {
            "The new limits were rejected. The previous limits stay in use.".into()
        }
        Class::SupervisorDown => match age {
            Some(a) => format!(
                "The background service is not running. Last update {} ago.",
                ago(a)
            ),
            None => "The background service is not running.".into(),
        },
        Class::DrainTimeout => "A job was stopped after the 6 h drain limit.".into(),
        Class::Other if detail.trim().is_empty() => "The service reported an error.".into(),
        Class::Other => detail.into(),
    }
}

/// `45 s`, `4 min`, `3 h`.
pub fn ago(d: Duration) -> String {
    match d.as_secs() {
        s if s < 60 => format!("{s} s"),
        s if s < 3600 => format!("{} min", s / 60),
        s => format!("{} h", s / 3600),
    }
}

fn digits(s: &str) -> bool {
    !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit())
}

/// `\S+`: non-empty, no whitespace.
fn word(s: &str) -> bool {
    !s.is_empty() && !s.chars().any(char::is_whitespace)
}

/// `N` of a trailing `; retry in N s`.
fn retry_secs(detail: &str) -> Option<&str> {
    let (_, n) = detail.strip_suffix(" s")?.rsplit_once("; retry in ")?;
    digits(n).then_some(n)
}

/// `^(could not start \S+:.*|\S+ still \S+ after \d+ s|\S+ LastTaskResult -?\d+); retry in \d+ s$`
fn mount_failed(detail: &str) -> bool {
    let Some(head) = detail
        .strip_suffix(" s")
        .and_then(|d| d.rsplit_once("; retry in "))
        .filter(|(_, n)| digits(n))
        .map(|(head, _)| head)
    else {
        return false;
    };
    if let Some(rest) = head.strip_prefix("could not start ") {
        // `\S+:` = a colon inside the first whitespace-free run, after at least one character.
        let first = rest.split(char::is_whitespace).next().unwrap_or("");
        return first.find(':').is_some_and(|i| i > 0);
    }
    let parts: Vec<&str> = head.split(' ').collect();
    match parts.as_slice() {
        [task, "still", state, "after", n, "s"] => word(task) && word(state) && digits(n),
        [task, "LastTaskResult", n] => word(task) && digits(n.strip_prefix('-').unwrap_or(n)),
        _ => false,
    }
}

/// `^sysbox=\S+ manager=\S+; restart \d+ failed; retrying every \d+ s$`, returning the count.
fn restart_loop(detail: &str) -> Option<&str> {
    let parts: Vec<&str> = detail.split(' ').collect();
    let [
        sysbox,
        manager,
        "restart",
        n,
        "failed;",
        "retrying",
        "every",
        m,
        "s",
    ] = parts.as_slice()
    else {
        return None;
    };
    let ok = sysbox.strip_prefix("sysbox=").is_some_and(word)
        && manager
            .strip_prefix("manager=")
            .and_then(|m| m.strip_suffix(';'))
            .is_some_and(word)
        && digits(n)
        && digits(m);
    ok.then_some(*n)
}

/// `^limits \S+ refused: `
fn limits_refused(detail: &str) -> bool {
    detail
        .strip_prefix("limits ")
        .and_then(|r| r.split_once(' '))
        .is_some_and(|(key, rest)| word(key) && rest.starts_with("refused: "))
}

/// The last `max` bytes of a log as whole lines (a cut first line is dropped).
pub fn read_tail(path: &Path, max: u64) -> io::Result<Vec<String>> {
    let mut f = File::open(path)?;
    let len = f.metadata()?.len();
    let start = len.saturating_sub(max);
    f.seek(SeekFrom::Start(start))?;
    let mut bytes = Vec::new();
    f.take(max).read_to_end(&mut bytes)?;
    let text = String::from_utf8_lossy(&bytes);
    let mut lines: Vec<String> = text.lines().map(str::to_owned).collect();
    if start > 0 && !lines.is_empty() {
        lines.remove(0);
    }
    Ok(lines)
}

/// `(time, rest)` of a `<RFC 3339> <text>` log line.
pub fn split_line(line: &str) -> Option<(SystemTime, &str)> {
    let (ts, rest) = line.split_once(' ')?;
    Some((parse_rfc3339(ts)?, rest))
}

/// `HH:MM` as the supervisor wrote it (its local time).
pub fn line_clock(line: &str) -> &str {
    line.get(11..16).unwrap_or("")
}

/// N of the last `WARN probe exit N: ...` line.
pub fn last_probe_exit(lines: &[String]) -> Option<i64> {
    lines.iter().rev().find_map(|l| {
        let (_, rest) = l.split_once("WARN probe exit ")?;
        rest.split(':').next()?.trim().parse().ok()
    })
}

/// The last `status error job= <detail>` line: when the current error started.
pub fn error_since<'a>(lines: &'a [String], detail: &str) -> Option<(SystemTime, &'a str)> {
    let want = format!("status error job= {detail}");
    lines.iter().rev().find_map(|l| {
        let (t, rest) = split_line(l)?;
        (rest.trim_end() == want.trim_end()).then_some((t, line_clock(l)))
    })
}

/// Lines for the class's keywords plus every `WARN`, the last `n`; else the plain last `n`.
pub fn relevant(lines: &[String], class: Class, n: usize) -> Vec<String> {
    let keep: Vec<&String> = lines
        .iter()
        .filter(|l| l.contains("WARN") || class.keywords().iter().any(|k| l.contains(k)))
        .collect();
    let pick: Vec<&String> = if keep.is_empty() {
        lines.iter().collect()
    } else {
        keep
    };
    pick[pick.len().saturating_sub(n)..]
        .iter()
        .map(|l| (*l).clone())
        .collect()
}

/// `drain timeout after N s` log lines: past events for Recent problems.
pub fn drain_timeouts(lines: &[String]) -> Vec<(SystemTime, String)> {
    lines
        .iter()
        .filter(|l| l.contains(" drain timeout after "))
        .filter_map(|l| Some((split_line(l)?.0, line_clock(l).to_owned())))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Detail strings exactly as `aap-runner-supervisor.ps1` builds them.
    const MOUNT: [&str; 4] = [
        "could not start AAP-CRRR-Mount-Work-Disk: Access is denied.; retry in 10 s",
        "AAP-CRRR-Mount-Work-Disk still Running after 180 s; retry in 30 s",
        "AAP-CRRR-Mount-Work-Disk LastTaskResult 2147942402; retry in 60 s",
        "AAP-CRRR-Mount-Work-Disk LastTaskResult -2147024891; retry in 300 s",
    ];
    const RESTART: &str = "sysbox=active manager=failed; restart 5 failed; retrying every 300 s";
    const LIMITS: &str = "limits 3,24,72 refused: AAP_JOB_CPUS=24 exceeds the 20 CPUs this VM has";

    #[test]
    fn every_supervisor_detail_lands_in_its_class() {
        for d in MOUNT {
            assert_eq!(classify(d, None), Class::Mount, "{d}");
        }
        assert_eq!(classify(RESTART, None), Class::RestartLoop);
        assert_eq!(classify(LIMITS, None), Class::LimitsRefused);
        assert_eq!(
            classify("limits 3,24,72,io=90,sharing=slice refused: x", None),
            Class::LimitsRefused
        );
        assert_eq!(classify(OLD_MANAGER, Some(1)), Class::ManagerOld);
        assert_eq!(classify(OLD_MANAGER, None), Class::ManagerOld);
        assert_eq!(classify(OLD_MANAGER, Some(-1)), Class::Probe);
        assert_eq!(classify(OLD_MANAGER, Some(2)), Class::Probe);
        for other in [
            "",
            "disk full",
            "attaching work disk",
            "manager status unavailable",
            "sysbox=active manager=failed; restart 2",
            "could not start AAP-CRRR-Mount-Work-Disk: denied",
            "could not start :x; retry in 10 s",
            "X still Running after 180 s; retry in 3a s",
            "X LastTaskResult 1x; retry in 10 s",
            "sysbox=active manager=failed; restart 5 failed; retrying every 300 s extra",
            "sysbox= manager=failed; restart 5 failed; retrying every 300 s",
            "limits  refused: x",
            "limits 3,24,72 rejected: x",
            "x limits 3,24,72 refused: y",
            crate::state::NEWER_SCHEMA,
        ] {
            assert_eq!(classify(other, Some(1)), Class::Other, "{other}");
        }
    }

    #[test]
    fn one_liners_carry_the_numbers() {
        assert_eq!(
            one_liner(Class::Mount, MOUNT[2], None),
            "The work disk could not be attached. Next try in 60 s."
        );
        assert_eq!(
            one_liner(Class::RestartLoop, RESTART, None),
            "The runner service keeps stopping (5 restarts)."
        );
        assert_eq!(
            one_liner(Class::SupervisorDown, "", Some(Duration::from_secs(250))),
            "The background service is not running. Last update 4 min ago."
        );
        assert_eq!(one_liner(Class::Other, "disk full", None), "disk full");
        assert_eq!(Class::Mount.action(), Action::Retry);
        assert_eq!(Class::LimitsRefused.action(), Action::Settings);
        assert_eq!(Class::SupervisorDown.action(), Action::RestartService);
        assert_eq!(Class::ManagerOld.action(), Action::Repair);
    }

    #[test]
    fn current_problem_follows_the_state() {
        let snap = |status, detail: &str| Snapshot {
            detail: detail.into(),
            ..Snapshot::bare(status)
        };
        assert_eq!(
            current(&snap(Status::Unknown, ""), None),
            Some(Class::SupervisorDown)
        );
        assert_eq!(
            current(&snap(Status::Error(RESTART.into()), RESTART), None),
            Some(Class::RestartLoop)
        );
        assert_eq!(
            current(&snap(Status::Paused, LIMITS), None),
            Some(Class::LimitsRefused)
        );
        assert_eq!(current(&snap(Status::Paused, ""), None), None);
        assert_eq!(current(&snap(Status::Idle, LIMITS), None), None);
        assert_eq!(current(&snap(Status::Off, ""), None), None);
    }

    fn log() -> Vec<String> {
        [
            "2026-10-14T14:01:00+02:00 WARN probe exit -1: manager on the distro predates this supervisor; re-run install-host.ps1 from this branch",
            "2026-10-14T14:02:03+02:00 status error job= sysbox=active manager=failed; restart 5 failed; retrying every 300 s",
            "2026-10-14T14:03:00+02:00 keep-alive started pid=4",
            "2026-10-14T14:04:00+02:00 drain timeout after 21600 s (manager draining); continuing",
            "2026-10-14T14:05:00+02:00 WARN probe exit 1: manager on the distro predates this supervisor; re-run install-host.ps1 from this branch",
        ]
        .map(String::from)
        .to_vec()
    }

    #[test]
    fn log_tail_parsing() {
        let lines = log();
        assert_eq!(last_probe_exit(&lines), Some(1));
        assert_eq!(last_probe_exit(&lines[..2]), Some(-1));
        assert_eq!(last_probe_exit(&lines[1..4]), None);
        let (t, clock) = error_since(&lines, RESTART).unwrap();
        assert_eq!(clock, "14:02");
        assert_eq!(t, parse_rfc3339("2026-10-14T12:02:03Z").unwrap());
        assert_eq!(error_since(&lines, "other"), None);
        let drains = drain_timeouts(&lines);
        assert_eq!(drains.len(), 1);
        assert_eq!(drains[0].1, "14:04");
        let rel = relevant(&lines, Class::RestartLoop, 20);
        assert_eq!(rel.len(), 3, "two WARN lines and the status error line");
        assert_eq!(relevant(&lines, Class::RestartLoop, 1).len(), 1);
        let none = vec!["2026-10-14T14:03:00+02:00 keep-alive started pid=4".to_string()];
        assert_eq!(
            relevant(&none, Class::Mount, 20),
            none,
            "falls back to the plain tail"
        );
    }

    #[test]
    fn tail_reads_whole_lines_only() {
        let base = crate::state::temp_base("tail");
        let path = base.join("supervisor.log");
        std::fs::write(&path, "aaaa\nbbbb\ncccc\n").unwrap();
        assert_eq!(read_tail(&path, 1024).unwrap(), ["aaaa", "bbbb", "cccc"]);
        assert_eq!(read_tail(&path, 7).unwrap(), ["cccc"]);
        assert!(read_tail(&base.join("missing.log"), 1024).is_err());
        std::fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn ago_reads_naturally() {
        assert_eq!(ago(Duration::from_secs(45)), "45 s");
        assert_eq!(ago(Duration::from_secs(240)), "4 min");
        assert_eq!(ago(Duration::from_secs(7300)), "2 h");
    }
}
