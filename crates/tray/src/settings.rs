//! `inbox\settings.json`: pool size and pool-total limits, written by the tray, applied by the
//! supervisor. The window edits the runner count, the IO cap and the sharing mode, and shows each
//! runner's even share of the caps to one decimal. The file stores the caps.
//! Schema 2 adds `schema`, `io_percent` and `sharing`; a schema 1 file reads with their defaults.
//! `windows_runner_count` is reserved for the Windows profile's count: read when present, never
//! written while no Windows backend exists (the count lives in a tray-local file instead), so
//! every file this tray writes is what it always was. `runner_count` stays the Linux count.
//! Schema 3 (two counts 0..5, shares, host reserve) is written only while a fresh
//! `status.v5.json` says the supervisor reads it; its keys the window has no control for yet are
//! kept as they are.

use crate::state::{StatusV5, inbox, read_bounded, read_status_v5, write_atomic};
use serde::{Deserialize, Serialize};
use std::io;
use std::ops::RangeInclusive;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

/// The Linux count the supervisor accepts.
pub const RUNNERS: RangeInclusive<u32> = 1..=5;
/// Linux plus Windows runners, together.
pub const MAX_RUNNERS: u32 = 5;
/// A native Windows runner backend exists. Until it does the Windows count is a stored choice
/// that starts nothing, and Linux keeps at least one runner so the pool runs something.
pub const WINDOWS_BACKEND: bool = false;

/// A runner profile.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Os {
    Linux,
    Windows,
}

impl Os {
    pub fn name(self) -> &'static str {
        match self {
            Os::Linux => "Linux",
            Os::Windows => "Windows",
        }
    }
}

/// Counts `os` may take when the other profile has `other`: up to the budget the other leaves,
/// never 0 + 0, and Linux at least 1 while no Windows backend exists (`runner_count` is 1..5).
pub fn count_range(os: Os, other: u32, windows_backend: bool) -> RangeInclusive<u32> {
    let floor = u32::from(other == 0 || (os == Os::Linux && !windows_backend));
    floor..=MAX_RUNNERS.saturating_sub(other)
}

pub fn counts_valid(linux: u32, windows: u32, windows_backend: bool) -> bool {
    count_range(Os::Linux, windows, windows_backend).contains(&linux)
        && count_range(Os::Windows, linux, windows_backend).contains(&windows)
}

/// What each runner gets when `linux + windows` share the pool: `pool / (linux + windows)`
/// floored to whole CPUs and GiB, the same for both profiles.
pub fn each_part(pool: (u32, u32), linux: u32, windows: u32) -> (u32, u32) {
    let n = linux.saturating_add(windows).max(1);
    (pool.0 / n, pool.1 / n)
}

/// Linux's part of the pool `(cpus, gib)`: the whole pool with no Windows runners (the file is
/// then what it always was), else the floored per-runner part times `linux`.
pub fn linux_part(pool: (u32, u32), linux: u32, windows: u32) -> (u32, u32) {
    if windows == 0 {
        return pool;
    }
    let (cpus, gib) = each_part(pool, linux, windows);
    (cpus.saturating_mul(linux), gib.saturating_mul(linux))
}

/// The Windows count the written totals account for: none while no Windows backend exists, so
/// a Windows-only edit leaves `runner_count` and the totals exactly as they were.
pub fn applied_windows(windows: u32) -> u32 {
    if WINDOWS_BACKEND { windows } else { 0 }
}

pub(crate) fn is_zero(v: &u32) -> bool {
    *v == 0
}

/// `windows_runner_count` stays out of `inbox\settings.json` while no Windows backend exists: a
/// supervisor that predates the key rejects the whole file (Pause included), so the file must be
/// what it always was. It is also omitted when 0.
fn omit_windows(v: &u32) -> bool {
    !WINDOWS_BACKEND || *v == 0
}

/// Where the window keeps the Windows count while no Windows backend exists: tray-local,
/// `%LOCALAPPDATA%\aap-runner\windows-runners.json` (`<base>\windows-runners.json` in tests).
pub fn windows_choice_path(base: &Path) -> PathBuf {
    if cfg!(test) {
        base.join("windows-runners.json")
    } else {
        crate::github_setup::data_file("windows-runners.json")
    }
}

#[derive(Serialize, Deserialize)]
struct WindowsChoice {
    schema: u32,
    windows_runner_count: u32,
}

/// The kept Windows count; 0 when missing, unreadable, another schema or not 0..4.
pub fn read_windows_choice(path: &Path) -> u32 {
    read_bounded(path)
        .and_then(|s| serde_json::from_str::<WindowsChoice>(s.trim_start_matches('\u{feff}')).ok())
        .filter(|c| c.schema == 1 && c.windows_runner_count < MAX_RUNNERS)
        .map_or(0, |c| c.windows_runner_count)
}

pub fn write_windows_choice(path: &Path, windows: u32) -> io::Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let choice = WindowsChoice {
        schema: 1,
        windows_runner_count: windows,
    };
    write_atomic(path, &serde_json::to_vec(&choice)?)
}

/// What the window shows as stored: `settings.json`, with the Windows count from the tray-local
/// file while no Windows backend exists (0 when it does not fit the stored Linux count).
pub fn read_with_windows_choice(base: &Path) -> Settings {
    let mut s = read_settings(base);
    if !WINDOWS_BACKEND {
        let w = read_windows_choice(&windows_choice_path(base));
        s.windows_runner_count = if counts_valid(s.runner_count, w, false) {
            w
        } else {
            0
        };
    }
    s
}

/// `8`, `4.8`, `14.4`: one decimal, dropped when the value is whole.
pub fn one_decimal(v: f64) -> String {
    if (v - v.round()).abs() < 0.05 {
        format!("{v:.0}")
    } else {
        format!("{v:.1}")
    }
}

/// Even split of a pool total across `runners`.
pub fn share_text(total: u32, runners: u32) -> String {
    one_decimal(f64::from(total) / f64::from(runners.max(1)))
}

/// Cores each runner is held to. Fixed mode is the manager's whole-CPU floor;
/// slice mode is the even split.
pub fn cpu_share(total: u32, runners: u32, fixed: bool) -> f64 {
    let n = runners.max(1);
    if fixed {
        f64::from(total / n)
    } else {
        f64::from(total) / f64::from(n)
    }
}
pub const CPUS: RangeInclusive<u32> = 1..=28;
pub const MEMORY_GIB: RangeInclusive<u32> = 1..=80;
pub const IO_PERCENT: RangeInclusive<u32> = 0..=100;
/// What this tray writes while the supervisor does not read schema 3.
pub const SETTINGS_SCHEMA: u32 = 2;
/// `host_reserve_percent` in schema 3, and `lease_wall_clock_hours`.
pub const HOST_RESERVE_PERCENT: RangeInclusive<u32> = 10..=90;
pub const LEASE_HOURS: RangeInclusive<u32> = 1..=72;

/// How the pool is shared between the runners.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Sharing {
    /// Each runner may use its slice, and idle slices are lent out.
    #[default]
    Slice,
    /// Each runner is held to its fixed share.
    Fixed,
}

/// Kept for Windows and WSL itself: the totals may use at most VM minus this.
pub const HOST_CPUS: u32 = 2;
pub const HOST_GIB: u32 = 8;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    pub schema: u32,
    pub runner_count: u32,
    pub job_cpus: u32,
    pub job_memory_gib: u32,
    pub paused: bool,
    /// Per-job IO cap as a percentage of the work disk's measured throughput.
    pub io_percent: u32,
    pub sharing: Sharing,
    /// Windows profile count. Reserved in the file: never written while no Windows backend
    /// exists (the window keeps it in `windows_choice_path`), and not when 0.
    #[serde(skip_serializing_if = "omit_windows")]
    pub windows_runner_count: u32,
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            schema: SETTINGS_SCHEMA,
            runner_count: 1,
            job_cpus: 26,
            job_memory_gib: 72,
            paused: false,
            io_percent: 90,
            sharing: Sharing::Slice,
            windows_runner_count: 0,
        }
    }
}

impl Settings {
    /// Totals from per-runner values, so they always divide evenly.
    #[cfg(test)]
    pub fn from_per_runner(runners: u32, cpus: u32, gib: u32, paused: bool) -> Settings {
        Settings {
            runner_count: runners,
            job_cpus: cpus.saturating_mul(runners),
            job_memory_gib: gib.saturating_mul(runners),
            paused,
            ..Settings::default()
        }
    }

    /// What the window writes: Linux's part of the pool caps for the Windows runners that
    /// actually run (`applied_windows`: none yet), so today the whole caps, as before.
    pub fn derived(linux: u32, windows: u32, paused: bool, vm: &VmLimit) -> Settings {
        let (job_cpus, job_memory_gib) = linux_part(vm.cap(), linux, applied_windows(windows));
        Settings {
            runner_count: linux,
            windows_runner_count: windows,
            job_cpus,
            job_memory_gib,
            paused,
            ..Settings::default()
        }
    }

    /// What each runner gets: the manager floor-divides the pool totals by the runner count.
    pub fn per_runner(&self) -> (u32, u32) {
        let n = self.runner_count.max(1);
        (self.job_cpus / n, self.job_memory_gib / n)
    }

    #[cfg(test)]
    pub fn is_divisible(&self) -> bool {
        let n = self.runner_count.max(1);
        self.job_cpus.is_multiple_of(n) && self.job_memory_gib.is_multiple_of(n)
    }

    /// Enough to read and show a file: ranges, and at least 1 CPU and 1 GiB per runner.
    pub fn check_shape(&self) -> Result<(), String> {
        let check = |name: &str, v: u32, r: &RangeInclusive<u32>| {
            if r.contains(&v) {
                Ok(())
            } else {
                Err(format!("{name} must be {}..{}", r.start(), r.end()))
            }
        };
        // Schema 3 is the supervisor's word that it runs Windows: Linux may be 0.
        let v3 = self.schema >= 3;
        if !v3 {
            check("Runners", self.runner_count, &RUNNERS)?;
        }
        if !counts_valid(
            self.runner_count,
            self.windows_runner_count,
            WINDOWS_BACKEND || v3,
        ) {
            return Err(format!(
                "Linux plus Windows runners must be at most {MAX_RUNNERS}"
            ));
        }
        check("Total CPUs", self.job_cpus, &CPUS)?;
        check("Total memory GiB", self.job_memory_gib, &MEMORY_GIB)?;
        check("IO cap percent", self.io_percent, &IO_PERCENT)?;
        let (cpus, gib) = self.per_runner();
        if cpus < 1 {
            return Err("Linux's part needs at least 1 CPU per runner".into());
        }
        if gib < 1 {
            return Err("Linux's part needs at least 1 GiB per runner".into());
        }
        Ok(())
    }

    /// What the tray writes: the shape, and totals within the host caps.
    pub fn validate(&self, vm: &VmLimit) -> Result<(), String> {
        self.check_shape()?;
        let (cap_cpus, cap_gib) = vm.cap();
        if self.job_cpus > cap_cpus {
            return Err(format!(
                "Total CPUs {} exceed the cap of {cap_cpus}",
                self.job_cpus
            ));
        }
        if self.job_memory_gib > cap_gib {
            return Err(format!(
                "Total memory {} GiB exceeds the cap of {cap_gib} GiB",
                self.job_memory_gib
            ));
        }
        Ok(())
    }

    pub fn toggle_label(&self) -> &'static str {
        if self.paused { "Resume" } else { "Pause" }
    }
}

/// The WSL VM size from `[wsl2]` in `%USERPROFILE%\.wslconfig`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VmLimit {
    pub cpus: u32,
    pub gib: u32,
    /// A value fell back to the default (file or key missing or unparseable).
    pub assumed: bool,
}

impl VmLimit {
    /// Matches the `CPUS` / `MEMORY_GIB` ceilings.
    pub const ASSUMED: VmLimit = VmLimit {
        cpus: 28,
        gib: 80,
        assumed: true,
    };

    pub fn from_wslconfig(text: &str) -> VmLimit {
        let (cpus, gib) = parse_wslconfig(text);
        VmLimit {
            cpus: cpus.unwrap_or(Self::ASSUMED.cpus),
            gib: gib.unwrap_or(Self::ASSUMED.gib),
            assumed: cpus.is_none() || gib.is_none(),
        }
    }

    pub fn read() -> VmLimit {
        std::env::var_os("USERPROFILE")
            .and_then(|home| read_bounded(&Path::new(&home).join(".wslconfig")))
            .map_or(Self::ASSUMED, |t| Self::from_wslconfig(&t))
    }

    /// Each runner's share of the caps: `(cap_cpus / runners, cap_gib / runners)`.
    #[cfg(test)]
    pub fn per_runner_max(&self, runners: u32) -> (u32, u32) {
        let n = runners.max(1);
        let (cpus, gib) = self.cap();
        (cpus / n, gib / n)
    }

    /// Hard caps for the totals: `(cpus - HOST_CPUS, gib - HOST_GIB)`.
    pub fn cap(&self) -> (u32, u32) {
        (
            self.cpus.saturating_sub(HOST_CPUS),
            self.gib.saturating_sub(HOST_GIB),
        )
    }
}

/// `(processors, memory GiB)` from the `[wsl2]` section; `None` for a missing or bad value.
/// Memory takes `GB`/`G`/`MB`/`M` in any case (WSL's GB is GiB); MB floors to whole GiB.
pub(crate) fn parse_wslconfig(text: &str) -> (Option<u32>, Option<u32>) {
    let (mut section, mut cpus, mut gib) = (String::new(), None, None);
    for line in text.lines() {
        let line = line.split(['#', ';']).next().unwrap_or("").trim();
        if let Some(name) = line.strip_prefix('[').and_then(|l| l.strip_suffix(']')) {
            section = name.trim().to_ascii_lowercase();
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        if section != "wsl2" {
            continue;
        }
        let value = value.trim().to_ascii_lowercase();
        match key.trim().to_ascii_lowercase().as_str() {
            "processors" => cpus = value.parse().ok().filter(|&n| n > 0),
            "memory" => {
                let v = value.strip_suffix('b').unwrap_or(&value);
                gib = if let Some(n) = v.strip_suffix('g') {
                    n.trim().parse().ok()
                } else if let Some(n) = v.strip_suffix('m') {
                    n.trim().parse::<u32>().ok().map(|mb| mb / 1024)
                } else {
                    None
                }
                .filter(|&n| n > 0);
            }
            _ => {}
        }
    }
    (cpus, gib)
}

/// Missing, unparseable or misshapen file = defaults. Missing fields take their defaults.
/// Caps and divisibility are not checked here, so the window can show and fix such a file.
/// A schema 3 file must pass every schema 3 rule; another schema above 2 is not this tray's.
pub fn read_settings(base: &Path) -> Settings {
    let Some(text) = read_bounded(&inbox(base).join("settings.json")) else {
        return Settings::default();
    };
    if let Some(v3) = parse_v3(&text) {
        return v3.settings();
    }
    serde_json::from_str::<Settings>(text.trim_start_matches('\u{feff}'))
        .ok()
        .filter(|s| s.schema < 3 && s.check_shape().is_ok())
        .unwrap_or_default()
}

/// Refuses to write a file that fails `validate`. Writes schema 3 while a fresh
/// `status.v5.json` lists it in `settings_schemas` (status-settings.md, compatibility rules),
/// else schema 2.
pub fn write_settings(base: &Path, s: &Settings, vm: &VmLimit) -> io::Result<()> {
    let invalid = |e: String| io::Error::new(io::ErrorKind::InvalidInput, e);
    s.validate(vm).map_err(invalid)?;
    let bytes = match read_status_v5(base, SystemTime::now()) {
        Some(v5) if v5.takes_settings_v3() => {
            let v3 = SettingsV3::edited(s, kept_v3(base, &v5));
            v3.check().map_err(invalid)?;
            serde_json::to_vec(&v3)?
        }
        _ => serde_json::to_vec(&Settings {
            schema: SETTINGS_SCHEMA,
            ..*s
        })?,
    };
    write_atomic(&inbox(base).join("settings.json"), &bytes)
}

/// Where the Linux runners run (schema 3). Supervisor-side: the tray writes it back unchanged.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum LinuxBackend {
    #[default]
    WslLegacy,
    HypervVm,
}

/// How the host is divided (schema 3): an even part per runner, or a share per profile.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ShareMode {
    #[default]
    Even,
    PerProfile,
}

/// `inbox\settings.json` schema 3 (parity/contracts/settings-v3.schema.json): every key, nothing
/// else.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct SettingsV3 {
    schema: u32,
    linux_backend: LinuxBackend,
    runner_count: u32,
    windows_runner_count: u32,
    job_cpus: u32,
    job_memory_gib: u32,
    paused: bool,
    io_percent: u32,
    sharing: Sharing,
    host_reserve_percent: u32,
    share_mode: ShareMode,
    linux_share_percent: Option<u32>,
    windows_share_percent: Option<u32>,
    lease_wall_clock_hours: u32,
}

impl SettingsV3 {
    /// The window's edit over the kept keys. The Windows count stays the kept one while the
    /// tray has no Windows backend: its own choice is tray-local.
    fn edited(s: &Settings, kept: SettingsV3) -> SettingsV3 {
        SettingsV3 {
            runner_count: s.runner_count,
            windows_runner_count: if WINDOWS_BACKEND {
                s.windows_runner_count
            } else {
                kept.windows_runner_count
            },
            job_cpus: s.job_cpus,
            job_memory_gib: s.job_memory_gib,
            paused: s.paused,
            io_percent: s.io_percent,
            sharing: s.sharing,
            ..kept
        }
    }

    fn settings(&self) -> Settings {
        Settings {
            schema: 3,
            runner_count: self.runner_count,
            job_cpus: self.job_cpus,
            job_memory_gib: self.job_memory_gib,
            paused: self.paused,
            io_percent: self.io_percent,
            sharing: self.sharing,
            windows_runner_count: self.windows_runner_count,
        }
    }

    /// The schema's ranges and validate.py's rules: Linux and Windows 0..5 and 1..5 together;
    /// per_profile shares plus the reserve are 100 and a share is 0 exactly when its count is;
    /// even has no shares.
    fn check(&self) -> Result<(), String> {
        let within = |name: &str, v: u32, r: RangeInclusive<u32>| {
            if r.contains(&v) {
                Ok(())
            } else {
                Err(format!("{name} must be {}..{}", r.start(), r.end()))
            }
        };
        if self.schema != 3 {
            return Err("schema must be 3".into());
        }
        if !counts_valid(self.runner_count, self.windows_runner_count, true) {
            return Err(format!(
                "Linux plus Windows runners must be 1..{MAX_RUNNERS}"
            ));
        }
        within("Total CPUs", self.job_cpus, CPUS)?;
        within("Total memory GiB", self.job_memory_gib, MEMORY_GIB)?;
        within("IO cap percent", self.io_percent, IO_PERCENT)?;
        within(
            "Host reserve percent",
            self.host_reserve_percent,
            HOST_RESERVE_PERCENT,
        )?;
        within("Lease hours", self.lease_wall_clock_hours, LEASE_HOURS)?;
        match (
            self.share_mode,
            self.linux_share_percent,
            self.windows_share_percent,
        ) {
            (ShareMode::Even, None, None) => Ok(()),
            (ShareMode::Even, _, _) => Err("even sharing has no profile shares".into()),
            (ShareMode::PerProfile, Some(l), Some(w)) => {
                if l > 90 || w > 90 || l + w + self.host_reserve_percent != 100 {
                    Err("profile shares plus the host reserve must be 100".into())
                } else if (self.runner_count == 0) != (l == 0)
                    || (self.windows_runner_count == 0) != (w == 0)
                {
                    Err("a profile has share 0 exactly when its count is 0".into())
                } else {
                    Ok(())
                }
            }
            _ => Err("per-profile sharing needs both profile shares".into()),
        }
    }
}

/// A schema 3 file that has every key and passes `check`, else `None`.
fn parse_v3(text: &str) -> Option<SettingsV3> {
    let v: serde_json::Value = serde_json::from_str(text.trim_start_matches('\u{feff}')).ok()?;
    // serde fills a missing Option with None; schema 3 requires every key.
    if v.as_object()?.len() != 14 {
        return None;
    }
    let s: SettingsV3 = serde_json::from_value(v).ok()?;
    s.check().is_ok().then_some(s)
}

/// The schema 3 keys the window has no control for yet: those of the stored schema 3 file, else
/// what `status.v5.json` reports (Linux backend, Windows count, reserve, shares) and a 6 h lease
/// wall clock.
fn kept_v3(base: &Path, v5: &StatusV5) -> SettingsV3 {
    if let Some(v3) = read_bounded(&inbox(base).join("settings.json")).and_then(|t| parse_v3(&t)) {
        return v3;
    }
    let d = Settings::default();
    let per_profile = v5.capacity.share_mode == "per_profile";
    let share = |name: &str| {
        v5.profile(name)
            .and_then(|p| p.share_percent)
            .filter(|_| per_profile)
    };
    SettingsV3 {
        schema: 3,
        linux_backend: if v5
            .profile("linux")
            .is_some_and(|p| p.backend == "hyperv-vm")
        {
            LinuxBackend::HypervVm
        } else {
            LinuxBackend::WslLegacy
        },
        runner_count: d.runner_count,
        windows_runner_count: v5.profile("windows").map_or(0, |p| p.count),
        job_cpus: d.job_cpus,
        job_memory_gib: d.job_memory_gib,
        paused: d.paused,
        io_percent: d.io_percent,
        sharing: d.sharing,
        host_reserve_percent: v5.capacity.host_reserve_percent,
        share_mode: if per_profile {
            ShareMode::PerProfile
        } else {
            ShareMode::Even
        },
        linux_share_percent: share("linux"),
        windows_share_percent: share("windows"),
        lease_wall_clock_hours: 6,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state::{fixture, temp_base};
    use std::fs;

    const VM: VmLimit = VmLimit::ASSUMED;

    fn with(f: impl FnOnce(&mut Settings)) -> Settings {
        let mut s = Settings::default();
        f(&mut s);
        s
    }

    #[test]
    fn per_runner_round_trips_through_totals() {
        for r in RUNNERS {
            for (c, g) in [(1, 1), (8, 24), (13, 36), (24, 72)] {
                let s = Settings::from_per_runner(r, c, g, false);
                assert_eq!((s.job_cpus, s.job_memory_gib), (c * r, g * r));
                assert_eq!(s.per_runner(), (c, g));
                assert!(s.is_divisible());
            }
        }
        assert_eq!(
            Settings::from_per_runner(1, 26, 72, false),
            Settings::default()
        );
    }

    #[test]
    fn cpus_and_memory_derive_from_the_caps() {
        let d = |r, vm: &VmLimit| {
            let s = Settings::derived(r, 0, false, vm);
            (
                s.per_runner(),
                (s.job_cpus, s.job_memory_gib),
                s.validate(vm).is_ok(),
            )
        };
        assert_eq!(d(1, &VM), ((26, 72), (26, 72), true));
        assert_eq!(d(2, &VM), ((13, 36), (26, 72), true));
        assert_eq!(d(3, &VM), ((8, 24), (26, 72), true));
        assert_eq!(d(4, &VM), ((6, 18), (26, 72), true));
        assert_eq!(d(5, &VM), ((5, 14), (26, 72), true));
        assert_eq!(share_text(26, 5), "5.2");
        assert_eq!(share_text(72, 5), "14.4");
        let wide = VmLimit {
            cpus: 26,
            gib: 80,
            assumed: false,
        };
        let five = Settings::derived(5, 0, false, &wide);
        assert_eq!((five.job_cpus, five.job_memory_gib), (24, 72));
        assert_eq!(share_text(five.job_cpus, 5), "4.8");
        assert_eq!(share_text(five.job_memory_gib, 5), "14.4");
        assert_eq!(cpu_share(24, 5, false), 4.8);
        assert_eq!(cpu_share(24, 5, true), 4.0);
        assert_eq!(one_decimal(cpu_share(24, 5, true)), "4");
        assert!(five.validate(&wide).is_ok());
        assert_eq!(Settings::derived(1, 0, false, &VM), Settings::default());
        assert!(Settings::derived(2, 0, true, &VM).paused);
        let small = VmLimit {
            cpus: 16,
            gib: 32,
            assumed: false,
        };
        assert_eq!(small.per_runner_max(1), (14, 24));
        assert_eq!(d(1, &small), ((14, 24), (14, 24), true));
        assert_eq!(d(2, &small), ((7, 12), (14, 24), true));
        assert_eq!(d(3, &small), ((4, 8), (14, 24), true));
        let tiny = VmLimit {
            cpus: 4,
            gib: 10,
            assumed: false,
        };
        assert_eq!(d(1, &tiny), ((2, 2), (2, 2), true));
        assert!(!d(3, &tiny).2, "2 CPUs cannot feed 3 runners");
    }

    #[test]
    fn uneven_totals_within_the_caps_stay_and_show_one_decimal() {
        let base = temp_base("settings-nondiv");
        let file = inbox(&base).join("settings.json");
        fs::write(
            &file,
            r#"{"runner_count":5,"job_cpus":24,"job_memory_gib":72}"#,
        )
        .unwrap();
        let stored = read_settings(&base);
        assert_eq!(
            (stored.runner_count, stored.job_cpus, stored.job_memory_gib),
            (5, 24, 72)
        );
        assert!(!stored.is_divisible());
        assert_eq!(share_text(stored.job_cpus, 5), "4.8");
        assert_eq!(share_text(stored.job_memory_gib, 5), "14.4");
        assert!(stored.validate(&VM).is_ok());
        write_settings(&base, &stored, &VM).unwrap();
        assert_eq!(read_settings(&base).runner_count, 5);
        fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn caps_apply_to_per_runner_totals() {
        assert_eq!(VM.cap(), (26, 72));
        let ok = |r, c, g| {
            Settings::from_per_runner(r, c, g, false)
                .validate(&VM)
                .is_ok()
        };
        assert!(ok(1, 26, 72));
        assert!(!ok(1, 27, 72));
        assert!(!ok(1, 26, 73));
        assert!(ok(2, 13, 36));
        assert!(!ok(2, 14, 36));
        assert!(!ok(2, 13, 37));
        assert!(ok(3, 8, 24));
        assert!(!ok(3, 9, 24), "27 CPUs > 26");
        assert!(!ok(3, 8, 25), "75 GiB > 72");
        let small = VmLimit {
            cpus: 16,
            gib: 32,
            assumed: false,
        };
        assert_eq!(small.cap(), (14, 24));
        assert!(
            Settings::from_per_runner(2, 7, 12, false)
                .validate(&small)
                .is_ok()
        );
        assert!(
            Settings::from_per_runner(2, 8, 12, false)
                .validate(&small)
                .is_err()
        );
        let tiny = VmLimit {
            cpus: 2,
            gib: 4,
            assumed: false,
        };
        assert_eq!(tiny.cap(), (0, 0), "no underflow");
        assert!(
            Settings::from_per_runner(1, 1, 1, false)
                .validate(&tiny)
                .is_err()
        );
    }

    #[test]
    fn runner_count_is_one_to_five() {
        let s = |r| Settings::from_per_runner(r, 4, 14, false);
        assert!(s(0).validate(&VM).is_err());
        assert!(s(5).validate(&VM).is_ok());
        assert!(s(6).check_shape().is_err());
        assert!(
            with(|s| (s.runner_count, s.job_cpus, s.job_memory_gib) = (6, 24, 72))
                .validate(&VM)
                .is_err()
        );
        assert!(
            with(|s| (s.runner_count, s.job_cpus, s.job_memory_gib) = (5, 24, 72))
                .validate(&VM)
                .is_ok()
        );
    }

    #[test]
    fn shape_bounds_and_floor() {
        assert_eq!(Settings::default().validate(&VM), Ok(()));
        for (s, ok) in [
            (with(|s| s.runner_count = 0), false),
            (with(|s| s.runner_count = 3), true),
            (with(|s| s.runner_count = 4), true),
            (with(|s| s.runner_count = 5), true),
            (with(|s| s.runner_count = 6), false),
            (with(|s| s.job_cpus = 0), false),
            (with(|s| s.job_cpus = 28), true),
            (with(|s| s.job_cpus = 29), false),
            (with(|s| s.job_memory_gib = 0), false),
            (with(|s| s.job_memory_gib = 80), true),
            (with(|s| s.job_memory_gib = 81), false),
            (with(|s| (s.runner_count, s.job_cpus) = (3, 2)), false),
            (with(|s| (s.runner_count, s.job_cpus) = (3, 3)), true),
            (with(|s| (s.runner_count, s.job_memory_gib) = (3, 2)), false),
            (with(|s| (s.runner_count, s.job_memory_gib) = (3, 3)), true),
            (with(|s| s.io_percent = 0), true),
            (with(|s| s.io_percent = 100), true),
            (with(|s| s.io_percent = 101), false),
        ] {
            assert_eq!(s.check_shape().is_ok(), ok, "{s:?}");
        }
        assert!(
            with(|s| s.job_cpus = 28).validate(&VM).is_err(),
            "above cap"
        );
    }

    #[test]
    fn read_falls_back_to_defaults() {
        let base = temp_base("settings-read");
        assert_eq!(read_settings(&base), Settings::default());
        for garbage in [
            "not json",
            r#"{"runner_count":-1}"#,
            r#"{"runner_count":1,"io_percent":101}"#,
            r#"{"runner_count":1,"sharing":"shared"}"#,
            r#"{"runner_count":9}"#,
            r#"{"runner_count":6}"#,
        ] {
            fs::write(inbox(&base).join("settings.json"), garbage).unwrap();
            assert_eq!(read_settings(&base), Settings::default(), "{garbage}");
        }
        fs::write(
            inbox(&base).join("settings.json"),
            "\u{feff}{\"runner_count\":2,\"paused\":true}",
        )
        .unwrap();
        assert_eq!(
            read_settings(&base),
            with(|s| (s.runner_count, s.paused) = (2, true))
        );
        fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn write_is_atomic_round_trips_and_rejects_invalid() {
        let base = temp_base("settings-write");
        let s = Settings::from_per_runner(2, 12, 36, true);
        write_settings(&base, &s, &VM).unwrap();
        assert_eq!(read_settings(&base), s);
        assert!(!inbox(&base).join("settings.json.tmp").exists());
        let raw: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(inbox(&base).join("settings.json")).unwrap())
                .unwrap();
        assert_eq!(raw["job_cpus"], 24);
        assert_eq!(raw["job_memory_gib"], 72);
        assert_eq!(raw["schema"], 2);
        assert_eq!(raw["io_percent"], 90);
        assert_eq!(raw["sharing"], "slice");
        assert_eq!(
            raw.as_object().unwrap().len(),
            7,
            "exactly the schema 2 keys"
        );
        let fixed = Settings {
            io_percent: 40,
            sharing: Sharing::Fixed,
            ..s
        };
        write_settings(&base, &fixed, &VM).unwrap();
        assert_eq!(read_settings(&base), fixed);
        write_settings(&base, &s, &VM).unwrap();
        assert!(write_settings(&base, &with(|s| s.job_cpus = 0), &VM).is_err());
        assert!(write_settings(&base, &with(|s| s.job_cpus = 27), &VM).is_err());
        assert_eq!(
            read_settings(&base),
            s,
            "invalid write must not touch the file"
        );
        fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn wslconfig_parses_wsl2_section() {
        let p = parse_wslconfig;
        assert_eq!(
            p("[wsl2]\nmemory=80GB\nprocessors=28\n"),
            (Some(28), Some(80))
        );
        assert_eq!(
            p("[WSL2]\r\nMemory = 64g\r\nProcessors = 16\r\n"),
            (Some(16), Some(64))
        );
        assert_eq!(p("[wsl2]\nmemory=81920MB"), (None, Some(80)));
        assert_eq!(p("[wsl2]\nmemory=2560m"), (None, Some(2)));
        assert_eq!(p("[wsl2]\nmemory=512MB"), (None, None), "under 1 GiB");
        assert_eq!(p("[wsl2]\nmemory=80\nprocessors=lots"), (None, None));
        assert_eq!(p("[wsl2]\nprocessors=0"), (None, None));
        let commented =
            "# memory=8GB\n[wsl2] ; vm\n; processors=2\nprocessors=12 # cores\nmemory=40GB\n";
        assert_eq!(p(commented), (Some(12), Some(40)));
        assert_eq!(
            p("memory=8GB\n[experimental]\nprocessors=2\n"),
            (None, None)
        );
        assert_eq!(p(""), (None, None));
    }

    #[test]
    fn vm_limit_falls_back_and_says_assumed() {
        let full = VmLimit::from_wslconfig("[wsl2]\nmemory=64GB\nprocessors=16");
        assert_eq!((full.cpus, full.gib, full.assumed), (16, 64, false));
        let half = VmLimit::from_wslconfig("[wsl2]\nprocessors=16");
        assert_eq!((half.cpus, half.gib, half.assumed), (16, 80, true));
        assert_eq!(VmLimit::from_wslconfig(""), VmLimit::ASSUMED);
    }

    #[test]
    fn schema_one_file_reads_with_schema_two_defaults() {
        let base = temp_base("settings-v1");
        fs::write(
            inbox(&base).join("settings.json"),
            r#"{"runner_count":3,"job_cpus":24,"job_memory_gib":72,"paused":false}"#,
        )
        .unwrap();
        let s = read_settings(&base);
        assert_eq!((s.io_percent, s.sharing, s.schema), (90, Sharing::Slice, 2));
        assert_eq!(s.per_runner(), (8, 24));
        fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn toggle_label() {
        assert_eq!(Settings::default().toggle_label(), "Pause");
        assert_eq!(with(|s| s.paused = true).toggle_label(), "Resume");
    }

    #[test]
    fn profile_counts_share_a_budget_of_five_and_never_zero() {
        for backend in [false, true] {
            for l in 0..=7 {
                for w in 0..=7 {
                    let want = (1..=MAX_RUNNERS).contains(&(l + w)) && (backend || l >= 1);
                    assert_eq!(counts_valid(l, w, backend), want, "{l}+{w} {backend}");
                }
            }
        }
        let r = count_range;
        assert_eq!(r(Os::Windows, 3, false), 0..=2, "3 Linux leave 2");
        assert_eq!(r(Os::Linux, 5, true), 0..=0, "5 Windows leave Linux 0");
        assert_eq!(r(Os::Linux, 0, true), 1..=5, "never 0 + 0");
        assert_eq!(r(Os::Windows, 0, true), 1..=5);
        assert_eq!(
            r(Os::Linux, 2, false),
            1..=3,
            "Linux keeps one without a backend"
        );
        assert_eq!(r(Os::Linux, 4, false), 1..=1);
        assert!(
            r(Os::Linux, 5, false).is_empty(),
            "unreachable without a backend"
        );
        assert_eq!(r(Os::Windows, 1, false), 0..=4);
        assert_eq!(r(Os::Windows, 9, true), 0..=0, "saturates, no underflow");
    }

    #[test]
    fn every_runner_gets_an_even_floored_part_whatever_its_os() {
        assert_eq!(each_part((26, 72), 3, 2), (5, 14), "26/5 and 72/5, floored");
        assert_eq!(
            linux_part((26, 72), 3, 0),
            (26, 72),
            "no split: the whole pool"
        );
        assert_eq!(linux_part((26, 72), 3, 2), (15, 42), "5 x 3, 14 x 3");
        assert_eq!(linux_part((26, 72), 1, 4), (5, 14));
        assert_eq!(linux_part((26, 72), 0, 5), (0, 0));
        assert_eq!(linux_part((26, 72), 0, 0), (26, 72));
        assert_eq!(linux_part((u32::MAX, u32::MAX), 5, 0), (u32::MAX, u32::MAX));
        assert_eq!(
            each_part((u32::MAX, 1), u32::MAX, u32::MAX),
            (1, 0),
            "no overflow"
        );
        assert_eq!(applied_windows(3), 0, "inert: the totals ignore Windows");
        // With the backend the split is what derived() would write.
        let (cpus, gib) = linux_part(VM.cap(), 3, 2);
        let with_backend = Settings {
            runner_count: 3,
            windows_runner_count: 2,
            job_cpus: cpus,
            job_memory_gib: gib,
            ..Settings::default()
        };
        assert_eq!(with_backend.per_runner(), each_part(VM.cap(), 3, 2));
        assert_eq!(with_backend.validate(&VM), Ok(()));
        let thin = with(|s| (s.runner_count, s.job_cpus) = (2, 1));
        assert_eq!(
            thin.check_shape(),
            Err("Linux's part needs at least 1 CPU per runner".into())
        );
        let thin = with(|s| (s.runner_count, s.job_memory_gib) = (2, 1));
        assert_eq!(
            thin.check_shape(),
            Err("Linux's part needs at least 1 GiB per runner".into())
        );
        assert!(Settings::derived(3, 3, false, &VM).validate(&VM).is_err());
        assert!(Settings::derived(1, 4, false, &VM).validate(&VM).is_ok());
    }

    /// Security review: while no Windows backend exists no tray write emits
    /// `windows_runner_count` (an older supervisor rejects such a file, Pause included). Every
    /// write path serializes `Settings` through `write_settings` (Apply, Pause/Resume) or serde;
    /// each gives exactly the file a Windows-0 tray writes.
    #[test]
    fn no_write_path_emits_the_windows_key_without_a_backend() {
        if WINDOWS_BACKEND {
            return; // with a backend the key is written on purpose
        }
        let base = temp_base("settings-windows-only");
        let file = inbox(&base).join("settings.json");
        write_settings(&base, &Settings::derived(3, 0, false, &VM), &VM).unwrap();
        let before = fs::read_to_string(&file).unwrap();
        assert!(!before.contains("windows"), "{before}");
        for w in 1..=2 {
            let s = Settings::derived(3, w, false, &VM);
            assert_eq!(s.windows_runner_count, w, "kept in memory for the window");
            write_settings(&base, &s, &VM).unwrap();
            assert_eq!(
                fs::read_to_string(&file).unwrap(),
                before,
                "Windows {w}: byte-identical"
            );
            assert!(!serde_json::to_string(&s).unwrap().contains("windows"));
            // Pause/Resume: read, flip `paused`, write (as toggle_pause does).
            let paused = Settings {
                paused: true,
                ..read_settings(&base)
            };
            write_settings(&base, &paused, &VM).unwrap();
            let text = fs::read_to_string(&file).unwrap();
            assert_eq!(text, before.replace("\"paused\":false", "\"paused\":true"));
            write_settings(&base, &s, &VM).unwrap();
        }
        // The key a future tray may write is still read (and checked) when present.
        fs::write(&file, r#"{"runner_count":2,"windows_runner_count":3}"#).unwrap();
        assert_eq!(read_settings(&base).windows_runner_count, 3);
        fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn the_windows_choice_is_kept_tray_local() {
        let base = temp_base("settings-windows-choice");
        let path = windows_choice_path(&base);
        assert_eq!(read_windows_choice(&path), 0, "missing");
        write_windows_choice(&path, 2).unwrap();
        assert_eq!(read_windows_choice(&path), 2);
        assert_eq!(
            fs::read_to_string(&path).unwrap(),
            r#"{"schema":1,"windows_runner_count":2}"#
        );
        write_settings(&base, &Settings::derived(3, 0, false, &VM), &VM).unwrap();
        assert_eq!(read_with_windows_choice(&base).windows_runner_count, 2);
        write_settings(&base, &Settings::derived(4, 0, false, &VM), &VM).unwrap();
        assert_eq!(
            read_with_windows_choice(&base).windows_runner_count,
            0,
            "4 Linux + 2 Windows does not fit: 0"
        );
        for bad in [
            "not json",
            r#"{"schema":2,"windows_runner_count":1}"#,
            r#"{"schema":1,"windows_runner_count":5}"#,
            r#"{"schema":1,"windows_runner_count":-1}"#,
        ] {
            fs::write(&path, bad).unwrap();
            assert_eq!(read_windows_choice(&path), 0, "{bad}");
        }
        fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn windows_key_is_read_when_present_and_checked() {
        let base = temp_base("settings-windows");
        let file = inbox(&base).join("settings.json");
        for bad in [
            r#"{"runner_count":4,"windows_runner_count":2}"#,
            r#"{"runner_count":1,"windows_runner_count":5}"#,
            r#"{"runner_count":1,"windows_runner_count":-1}"#,
            r#"{"runner_count":1,"windows_runner_count":"2"}"#,
        ] {
            fs::write(&file, bad).unwrap();
            assert_eq!(read_settings(&base), Settings::default(), "{bad}");
        }
        fs::write(&file, r#"{"runner_count":1,"windows_runner_count":4}"#).unwrap();
        assert_eq!(read_settings(&base).windows_runner_count, 4);
        assert!(write_settings(&base, &with(|s| s.windows_runner_count = 5), &VM).is_err());
        fs::remove_dir_all(&base).unwrap();
    }

    /// A `status.v5.json` from the contract fixtures with `settings_schemas` and `updated`
    /// replaced: a far-future time is fresh (clock skew counts as fresh), 2000 is stale.
    fn write_v5(base: &Path, schemas: &str, updated: &str) {
        let mut v: serde_json::Value =
            serde_json::from_str(&fixture("status-v5/valid/mixed-five-slots.json")).unwrap();
        v["settings_schemas"] = serde_json::from_str(schemas).unwrap();
        v["updated"] = updated.into();
        fs::write(base.join("status.v5.json"), v.to_string()).unwrap();
    }

    const FRESH: &str = "2099-01-01T00:00:00Z";

    fn written(base: &Path) -> serde_json::Value {
        serde_json::from_str(&fs::read_to_string(inbox(base).join("settings.json")).unwrap())
            .unwrap()
    }

    #[test]
    fn schema_three_reads_the_contract_fixtures() {
        for (name, linux, windows) in [
            ("owner-example-per-profile", 3, 2),
            ("legacy-totals-capped-by-share", 3, 2),
            ("windows-only-even", 0, 2),
        ] {
            let v3 = parse_v3(&fixture(&format!("settings-v3/valid/{name}.json"))).expect(name);
            let s = v3.settings();
            assert_eq!(
                (s.runner_count, s.windows_runner_count),
                (linux, windows),
                "{name}"
            );
            assert_eq!(s.check_shape(), Ok(()), "{name}");
        }
        for name in [
            "future-schema-4",
            "share-for-zero-count",
            "shares-plus-reserve-not-100",
            "shares-sum-95",
            "string-count",
            "three-plus-three",
            "unknown-linux-backend",
            "zero-plus-zero",
        ] {
            assert!(
                parse_v3(&fixture(&format!("settings-v3/invalid/{name}.json"))).is_none(),
                "{name}"
            );
        }
        let base = temp_base("settings-v3-read");
        fs::write(
            inbox(&base).join("settings.json"),
            fixture("settings-v3/valid/windows-only-even.json"),
        )
        .unwrap();
        let s = read_settings(&base);
        assert_eq!(
            (s.schema, s.runner_count, s.windows_runner_count),
            (3, 0, 2)
        );
        fs::write(
            inbox(&base).join("settings.json"),
            fixture("settings-v3/invalid/shares-sum-95.json"),
        )
        .unwrap();
        assert_eq!(read_settings(&base), Settings::default());
        let missing = fixture("settings-v3/valid/windows-only-even.json")
            .replace("\"linux_share_percent\": null,", "");
        fs::write(inbox(&base).join("settings.json"), missing).unwrap();
        assert_eq!(
            read_settings(&base),
            Settings::default(),
            "every schema 3 key is required"
        );
        fs::write(
            inbox(&base).join("settings.json"),
            r#"{"schema":7,"runner_count":2}"#,
        )
        .unwrap();
        assert_eq!(
            read_settings(&base),
            Settings::default(),
            "not this tray's schema"
        );
        fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn writes_schema_three_only_while_a_fresh_status_v5_lists_it() {
        let base = temp_base("settings-v3-write");
        let s = Settings::derived(3, 0, false, &VM);
        for (schemas, updated, want) in [
            ("[2,3]", FRESH, 3),
            ("[1,2,3]", FRESH, 3),
            ("[1,2]", FRESH, 2),
            ("[2,3]", "2000-01-01T00:00:00Z", 2),
        ] {
            let _ = fs::remove_file(inbox(&base).join("settings.json"));
            write_v5(&base, schemas, updated);
            write_settings(&base, &s, &VM).unwrap();
            assert_eq!(written(&base)["schema"], want, "{schemas} {updated}");
        }
        // A newer status.v5.json is not read: schema 2.
        let six = fixture("status-v5/invalid/future-schema-6.json")
            .replace("2026-10-19T18:00:00Z", FRESH);
        fs::write(base.join("status.v5.json"), six).unwrap();
        write_settings(&base, &s, &VM).unwrap();
        assert_eq!(written(&base)["schema"], 2);
        fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn schema_three_takes_the_supervisor_side_keys_from_status_v5() {
        let base = temp_base("settings-v3-keys");
        write_v5(&base, "[1,2,3]", FRESH);
        // The fixture reports per_profile 60/30 with Windows 2 and reserve 10.
        let s = Settings::derived(3, 1, false, &VM);
        write_settings(&base, &s, &VM).unwrap();
        let w = written(&base);
        assert_eq!(
            w.as_object().unwrap().len(),
            14,
            "exactly the schema 3 keys"
        );
        assert_eq!(w["linux_backend"], "wsl-legacy");
        assert_eq!(w["runner_count"], 3);
        assert_eq!(
            w["windows_runner_count"], 2,
            "the reported count, not the tray-local choice"
        );
        assert_eq!(w["share_mode"], "per_profile");
        assert_eq!(
            (
                w["linux_share_percent"].clone(),
                w["windows_share_percent"].clone()
            ),
            (60.into(), 30.into())
        );
        assert_eq!(w["host_reserve_percent"], 10);
        assert_eq!(w["lease_wall_clock_hours"], 6);
        assert_eq!(parse_v3(&w.to_string()).map(|v| v.check()), Some(Ok(())));
        assert_eq!(read_settings(&base).runner_count, 3);
        fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn schema_three_keeps_the_stored_keys_across_pause() {
        let base = temp_base("settings-v3-pause");
        write_v5(&base, "[1,2,3]", FRESH);
        let mut stored: serde_json::Value =
            serde_json::from_str(&fixture("settings-v3/valid/owner-example-per-profile.json"))
                .unwrap();
        stored["job_cpus"] = 19.into();
        stored["job_memory_gib"] = 57.into();
        stored["host_reserve_percent"] = 20.into();
        stored["linux_share_percent"] = 50.into();
        stored["lease_wall_clock_hours"] = 12.into();
        fs::write(inbox(&base).join("settings.json"), stored.to_string()).unwrap();
        // Pause as the menu does it: read, flip, write.
        let paused = Settings {
            paused: true,
            ..read_settings(&base)
        };
        write_settings(&base, &paused, &VM).unwrap();
        let mut want = stored.clone();
        want["paused"] = true.into();
        assert_eq!(written(&base), want);
        // An edit that no longer fits the kept Windows count is refused and leaves the file.
        let four = Settings::derived(4, 0, false, &VM);
        let err = write_settings(&base, &four, &VM).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidInput);
        assert_eq!(written(&base), want);
        fs::remove_dir_all(&base).unwrap();
    }
}
