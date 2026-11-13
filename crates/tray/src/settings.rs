//! `inbox\settings.json`: pool size and pool-total limits, written by the tray, applied by the
//! supervisor. The window edits the runner count, the IO cap and the sharing mode, and shows each
//! runner's even share of the caps to one decimal. The file stores the caps.
//! Schema 2 adds `schema`, `io_percent` and `sharing`; a schema 1 file reads with their defaults.
//! `windows_runner_count` is reserved for the Windows profile's count: read when present, never
//! written while no Windows backend exists (the count lives in a tray-local file instead), so
//! every file this tray writes is what it always was. `runner_count` stays the Linux count.
//! Schema 3 (two counts 0..5, shares, host reserve) is written over a stored schema 3 file, or
//! while a fresh `status.v5.json` says the supervisor reads it, never schema 2 over schema 3; its
//! keys the window has no control for yet are kept as they are.
//! Schema 4 (R1 tiers: light 0..10 and heavy 0..2 instead of `runner_count`) is written over a
//! stored schema 4 file, or while a fresh `status.v5.json` lists 4; never 3 or 2 over 4. In memory
//! `runner_count` is the light (or, before schema 4, the untiered) Linux count.

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

/// Light slots in settings schema 4, and heavy slots.
pub const LIGHT: RangeInclusive<u32> = 0..=10;
pub const HEAVY: RangeInclusive<u32> = 0..=2;
/// The memory a heavy and a light slot reserve (status-settings.md, Tiers). Their sum over the
/// slots must fit the memory total, as the manager and the supervisor require.
pub const HEAVY_GIB: u32 = 20;
pub const LIGHT_GIB: u32 = 3;
/// Windows runners in settings schema 4.
pub const WINDOWS: RangeInclusive<u32> = 0..=5;

/// A Linux tier (status-settings.md, Tiers).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tier {
    Light,
    Heavy,
}

impl Tier {
    pub fn name(self) -> &'static str {
        match self {
            Tier::Light => "Light",
            Tier::Heavy => "Heavy",
        }
    }
}

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
/// file while no Windows backend exists (0 when it does not fit the stored Linux count). A schema 3
/// file has its own Windows count: the supervisor runs it.
pub fn read_with_windows_choice(base: &Path) -> Settings {
    let mut s = read_settings(base);
    if !WINDOWS_BACKEND && s.schema < 3 {
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
    /// Heavy Linux slots: only in a schema 4 file, never in a schema 2 one.
    #[serde(skip)]
    pub linux_heavy_count: u32,
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
            linux_heavy_count: 0,
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
        if self.schema >= 4 {
            return self.check_tiers();
        }
        if self.linux_heavy_count > 0 {
            return Err("Heavy runners need a supervisor that reads settings schema 4".into());
        }
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

    /// Schema 4's shape: the tier and Windows ranges, at least one Linux runner (the supervisor
    /// that lists schema 4 runs no Windows VM), the totals' ranges, and the tier reservations
    /// within the memory total. The totals stay the WSL pool totals as in schema 3; the Linux
    /// per-slot limits come from the tier table.
    fn check_tiers(&self) -> Result<(), String> {
        let within = |name: &str, v: u32, r: RangeInclusive<u32>| {
            if r.contains(&v) {
                Ok(())
            } else {
                Err(format!("{name} must be {}..{}", r.start(), r.end()))
            }
        };
        within("Light runners", self.runner_count, LIGHT)?;
        within("Heavy runners", self.linux_heavy_count, HEAVY)?;
        within("Windows runners", self.windows_runner_count, WINDOWS)?;
        if self.runner_count + self.linux_heavy_count == 0 {
            return Err("Schema 4 needs at least one Linux runner, light or heavy".into());
        }
        within("Total CPUs", self.job_cpus, CPUS)?;
        within("Total memory GiB", self.job_memory_gib, MEMORY_GIB)?;
        let need = self.linux_heavy_count * HEAVY_GIB + self.runner_count * LIGHT_GIB;
        if need > self.job_memory_gib {
            return Err(format!(
                "Heavy {} + Light {} need {need} GiB; total memory is {} GiB",
                self.linux_heavy_count, self.runner_count, self.job_memory_gib
            ));
        }
        within("IO cap percent", self.io_percent, IO_PERCENT)
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
    read_settings_to_edit(base).unwrap_or_default()
}

/// What a writer that rewrites the stored file may start from: the file as stored, defaults when
/// there is none, and `None` when a file is there that this tray rejects (a rewrite would
/// replace the owner's values with defaults).
pub fn read_settings_to_edit(base: &Path) -> Option<Settings> {
    let path = inbox(base).join("settings.json");
    let Some(text) = read_bounded(&path) else {
        return (!path.exists()).then(Settings::default);
    };
    if let Some(v4) = parse_v4(&text) {
        return Some(v4.settings());
    }
    if let Some(v3) = parse_v3(&text) {
        return Some(v3.settings());
    }
    serde_json::from_str::<Settings>(text.trim_start_matches('\u{feff}'))
        .ok()
        .filter(|s| s.schema < 3 && s.check_shape().is_ok())
}

/// Writes schema 3 over a stored schema 3 file, or while a fresh `status.v5.json` lists it in
/// `settings_schemas`, else schema 2 (status-settings.md, compatibility rules): a supervisor that
/// is restarting or busy past the 180 s never gets its shares, reserve and Windows count dropped.
/// Refuses a file that fails the rules of the schema it writes.
pub fn write_settings(base: &Path, s: &Settings, vm: &VmLimit) -> io::Result<()> {
    write_settings_at(base, s, vm, SystemTime::now())
}

fn write_settings_at(base: &Path, s: &Settings, vm: &VmLimit, now: SystemTime) -> io::Result<()> {
    let invalid = |e: String| io::Error::new(io::ErrorKind::InvalidInput, e);
    let bytes = match (kept_v4(base, now), kept_v3(base, now)) {
        (Some((kept, own_windows)), _) => {
            let v4 = SettingsV4::edited(s, kept, own_windows);
            v4.check().map_err(invalid)?;
            serde_json::to_vec(&v4)?
        }
        (None, Some(kept)) => {
            let v3 = SettingsV3::edited(s, kept);
            v3.settings().validate(vm).map_err(invalid)?;
            v3.check().map_err(invalid)?;
            if s.linux_heavy_count > 0 {
                return Err(invalid("Heavy runners need settings schema 4".into()));
            }
            serde_json::to_vec(&v3)?
        }
        (None, None) => {
            let v2 = Settings {
                schema: SETTINGS_SCHEMA,
                ..*s
            };
            v2.validate(vm).map_err(invalid)?;
            serde_json::to_vec(&v2)?
        }
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
    /// The window's edit over the kept keys. The Windows count is the edit's when it was read
    /// from a schema 3 file (or the tray has a Windows backend), else the kept one: a tray-local
    /// choice never reaches the supervisor.
    fn edited(s: &Settings, kept: SettingsV3) -> SettingsV3 {
        SettingsV3 {
            runner_count: s.runner_count,
            windows_runner_count: if WINDOWS_BACKEND || s.schema >= 3 {
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
            linux_heavy_count: 0,
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

/// The schema 3 keys the window has no control for yet: those of the stored schema 3 file, else,
/// while a fresh `status.v5.json` lists schema 3, what it reports (Linux backend, Windows count,
/// reserve, shares) and a 6 h lease wall clock. `None`: write schema 2.
fn kept_v3(base: &Path, now: SystemTime) -> Option<SettingsV3> {
    if let Some(v3) = read_bounded(&inbox(base).join("settings.json")).and_then(|t| parse_v3(&t)) {
        return Some(v3);
    }
    let v5 = read_status_v5(base, now).filter(StatusV5::takes_settings_v3)?;
    Some(v3_from_status(&v5))
}

/// The supervisor-side keys `v5` reports, and the defaults for the rest.
fn v3_from_status(v5: &StatusV5) -> SettingsV3 {
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

/// The tray may write schema 4: a stored valid schema 4 file, or a fresh `status.v5.json` that
/// lists 4. The window offers the tiers only then.
pub fn tiers_writable(base: &Path) -> bool {
    tiers_writable_at(base, SystemTime::now())
}

fn tiers_writable_at(base: &Path, now: SystemTime) -> bool {
    kept_v4(base, now).is_some()
}

/// `inbox\settings.json` schema 4 (parity/contracts/settings-v4.schema.json): schema 3's keys
/// with the two tier counts instead of `runner_count`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct SettingsV4 {
    schema: u32,
    linux_backend: LinuxBackend,
    linux_light_count: u32,
    linux_heavy_count: u32,
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

impl SettingsV4 {
    /// Schema 3's kept keys, its Linux count as the light count.
    fn from_v3(v3: SettingsV3) -> SettingsV4 {
        SettingsV4 {
            schema: 4,
            linux_backend: v3.linux_backend,
            linux_light_count: v3.runner_count,
            linux_heavy_count: 0,
            windows_runner_count: v3.windows_runner_count,
            job_cpus: v3.job_cpus,
            job_memory_gib: v3.job_memory_gib,
            paused: v3.paused,
            io_percent: v3.io_percent,
            sharing: v3.sharing,
            host_reserve_percent: v3.host_reserve_percent,
            share_mode: v3.share_mode,
            linux_share_percent: v3.linux_share_percent,
            windows_share_percent: v3.windows_share_percent,
            lease_wall_clock_hours: v3.lease_wall_clock_hours,
        }
    }

    /// The window's edit over the kept keys. The Windows count is the edit's when the kept keys
    /// are a stored schema 3 or 4 file (the window read the count from it), else the reported
    /// one, as in schema 3: a tray-local choice never reaches the supervisor.
    fn edited(s: &Settings, kept: SettingsV4, own_windows: bool) -> SettingsV4 {
        SettingsV4 {
            linux_light_count: s.runner_count,
            linux_heavy_count: s.linux_heavy_count,
            windows_runner_count: if WINDOWS_BACKEND || own_windows {
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
            schema: 4,
            runner_count: self.linux_light_count,
            linux_heavy_count: self.linux_heavy_count,
            job_cpus: self.job_cpus,
            job_memory_gib: self.job_memory_gib,
            paused: self.paused,
            io_percent: self.io_percent,
            sharing: self.sharing,
            windows_runner_count: self.windows_runner_count,
        }
    }

    /// The schema's ranges and validate.py's `sem_settings_v4`: tiers and Windows in range, at
    /// least one runner, the kept keys' ranges, and schema 3's share rules over light + heavy.
    fn check(&self) -> Result<(), String> {
        if self.schema != 4 {
            return Err("schema must be 4".into());
        }
        self.settings().check_shape()?;
        let linux = self.linux_light_count + self.linux_heavy_count;
        if !HOST_RESERVE_PERCENT.contains(&self.host_reserve_percent) {
            return Err("Host reserve percent must be 10..90".into());
        }
        if !LEASE_HOURS.contains(&self.lease_wall_clock_hours) {
            return Err("Lease hours must be 1..72".into());
        }
        shares_fit(
            self.share_mode,
            self.host_reserve_percent,
            [
                (linux, self.linux_share_percent),
                (self.windows_runner_count, self.windows_share_percent),
            ],
        )
    }
}

/// validate.py `_shares`: even has no shares; per_profile shares plus the reserve are 100 and a
/// share is 0 exactly when its count is.
fn shares_fit(
    mode: ShareMode,
    reserve: u32,
    counts_and_shares: [(u32, Option<u32>); 2],
) -> Result<(), String> {
    match (mode, counts_and_shares) {
        (ShareMode::Even, [(_, None), (_, None)]) => Ok(()),
        (ShareMode::Even, _) => Err("even sharing has no profile shares".into()),
        (ShareMode::PerProfile, [(lc, Some(l)), (wc, Some(w))]) => {
            if l > 90 || w > 90 || l + w + reserve != 100 {
                Err("profile shares plus the host reserve must be 100".into())
            } else if (lc == 0) != (l == 0) || (wc == 0) != (w == 0) {
                Err("a profile has share 0 exactly when its count is 0".into())
            } else {
                Ok(())
            }
        }
        _ => Err("per-profile sharing needs both profile shares".into()),
    }
}

/// A schema 4 file that has every key and passes `check`, else `None`.
fn parse_v4(text: &str) -> Option<SettingsV4> {
    let v: serde_json::Value = serde_json::from_str(text.trim_start_matches('\u{feff}')).ok()?;
    // serde fills a missing Option with None; schema 4 requires every key.
    if v.as_object()?.len() != 15 {
        return None;
    }
    let s: SettingsV4 = serde_json::from_value(v).ok()?;
    s.check().is_ok().then_some(s)
}

/// What schema 4 keeps: the stored schema 4 file; else, while a fresh `status.v5.json` lists 4,
/// the stored schema 3 file's keys or what `status.v5.json` reports. `None`: not schema 4. The
/// flag: the keys are a stored schema 3 or 4 file, so the window shows that file's Windows count.
fn kept_v4(base: &Path, now: SystemTime) -> Option<(SettingsV4, bool)> {
    let stored = read_bounded(&inbox(base).join("settings.json"));
    if let Some(v4) = stored.as_deref().and_then(parse_v4) {
        return Some((v4, true));
    }
    let v5 = read_status_v5(base, now).filter(StatusV5::takes_settings_v4)?;
    Some(match stored.as_deref().and_then(parse_v3) {
        Some(v3) => (SettingsV4::from_v3(v3), true),
        None => (SettingsV4::from_v3(v3_from_status(&v5)), false),
    })
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
    fn a_rejected_file_is_told_from_a_missing_one() {
        let base = temp_base("settings-to-edit");
        let path = inbox(&base).join("settings.json");
        assert_eq!(
            read_settings_to_edit(&base),
            Some(Settings::default()),
            "missing: start from defaults"
        );
        let oversized = format!("{{\"runner_count\":2}}{}", " ".repeat(70 * 1024));
        for rejected in [
            "not json",
            r#"{"runner_count":2,"sharing":"shared"}"#,
            r#"{"runner_count":9}"#,
            r#"{"schema":7}"#,
            oversized.as_str(),
        ] {
            fs::write(&path, rejected).unwrap();
            assert_eq!(read_settings_to_edit(&base), None, "{rejected:.40}");
            assert_eq!(read_settings(&base), Settings::default(), "{rejected:.40}");
        }
        fs::write(&path, "\u{feff}{\"runner_count\":2,\"paused\":true}").unwrap();
        assert_eq!(read_settings_to_edit(&base), Some(read_settings(&base)));
        let s = Settings::from_per_runner(2, 12, 36, true);
        write_settings(&base, &s, &VM).unwrap();
        assert_eq!(read_settings_to_edit(&base), Some(s));
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
    /// replaced: `FRESH` is a minute before `now()`, 2000 is stale, a time after `now()` too.
    fn write_v5(base: &Path, schemas: &str, updated: &str) {
        let mut v: serde_json::Value =
            serde_json::from_str(&fixture("status-v5/valid/mixed-five-slots.json")).unwrap();
        v["settings_schemas"] = serde_json::from_str(schemas).unwrap();
        v["updated"] = updated.into();
        fs::write(base.join("status.v5.json"), v.to_string()).unwrap();
    }

    const FRESH: &str = "2026-10-19T18:00:00Z";

    fn now() -> SystemTime {
        crate::state::parse_rfc3339("2026-10-19T18:01:00Z").unwrap()
    }

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
            ("[2,3]", "2026-10-19T18:05:00Z", 2),
        ] {
            let _ = fs::remove_file(inbox(&base).join("settings.json"));
            write_v5(&base, schemas, updated);
            write_settings_at(&base, &s, &VM, now()).unwrap();
            assert_eq!(written(&base)["schema"], want, "{schemas} {updated}");
        }
        // A newer status.v5.json is not read: schema 2.
        let six = fixture("status-v5/invalid/future-schema-6.json")
            .replace("2026-10-19T18:00:00Z", FRESH);
        fs::write(base.join("status.v5.json"), six).unwrap();
        write_settings_at(&base, &s, &VM, now()).unwrap();
        assert_eq!(written(&base)["schema"], 2);
        // Schema 2 is checked as schema 2: no Linux 0, whatever the edit was read as.
        let windows_only = Settings {
            schema: 3,
            runner_count: 0,
            windows_runner_count: 2,
            ..s
        };
        let err = write_settings_at(&base, &windows_only, &VM, now()).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidInput);
        assert_eq!(written(&base)["runner_count"], 3);
        fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn never_writes_schema_two_over_a_stored_schema_three_file() {
        let base = temp_base("settings-v3-kept");
        for name in ["owner-example-per-profile", "windows-only-even"] {
            for v5 in ["stale", "missing", "newer"] {
                let stored: serde_json::Value =
                    serde_json::from_str(&fixture(&format!("settings-v3/valid/{name}.json")))
                        .unwrap();
                fs::write(inbox(&base).join("settings.json"), stored.to_string()).unwrap();
                let _ = fs::remove_file(base.join("status.v5.json"));
                match v5 {
                    "stale" => write_v5(&base, "[1,2,3]", "2000-01-01T00:00:00Z"),
                    "newer" => fs::write(
                        base.join("status.v5.json"),
                        fixture("status-v5/invalid/future-schema-6.json"),
                    )
                    .unwrap(),
                    _ => {}
                }
                // Pause as the menu does it: read, flip, write.
                let paused = Settings {
                    paused: true,
                    ..read_settings(&base)
                };
                write_settings_at(&base, &paused, &VM, now()).unwrap();
                let mut want = stored.clone();
                want["paused"] = true.into();
                assert_eq!(written(&base), want, "{name} {v5}");
            }
        }
        fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn the_window_shows_a_schema_three_file_with_its_own_windows_count() {
        let base = temp_base("settings-v3-window");
        write_windows_choice(&windows_choice_path(&base), 1).unwrap();
        fs::write(
            inbox(&base).join("settings.json"),
            fixture("settings-v3/valid/windows-only-even.json"),
        )
        .unwrap();
        let s = read_with_windows_choice(&base);
        assert_eq!((s.runner_count, s.windows_runner_count), (0, 2));
        fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn schema_three_takes_the_supervisor_side_keys_from_status_v5() {
        let base = temp_base("settings-v3-keys");
        write_v5(&base, "[1,2,3]", FRESH);
        // The fixture reports per_profile 60/30 with Windows 2 and reserve 10.
        let s = Settings::derived(3, 1, false, &VM);
        write_settings_at(&base, &s, &VM, now()).unwrap();
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
        write_settings_at(&base, &paused, &VM, now()).unwrap();
        let mut want = stored.clone();
        want["paused"] = true.into();
        assert_eq!(written(&base), want);
        // An edit that no longer fits the kept Windows count is refused and leaves the file.
        let four = Settings::derived(4, 0, false, &VM);
        let err = write_settings_at(&base, &four, &VM, now()).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidInput);
        assert_eq!(written(&base), want);
        fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn schema_four_reads_the_contract_fixtures() {
        for (name, light, heavy, windows) in [
            ("tiers-per-profile", 4, 1, 2),
            ("full-pool-even", 10, 2, 5),
            ("one-heavy-only", 0, 1, 0),
        ] {
            let v4 = parse_v4(&fixture(&format!("settings-v4/valid/{name}.json"))).expect(name);
            let s = v4.settings();
            assert_eq!(
                (
                    s.schema,
                    s.runner_count,
                    s.linux_heavy_count,
                    s.windows_runner_count
                ),
                (4, light, heavy, windows),
                "{name}"
            );
        }
        for name in [
            "all-zero",
            "heavy-three",
            "keeps-runner-count",
            "light-eleven",
            "missing-heavy-count",
            "schema-3",
            "share-for-zero-linux",
            "tier-reservations-over-memory",
            "windows-six",
        ] {
            assert!(
                parse_v4(&fixture(&format!("settings-v4/invalid/{name}.json"))).is_none(),
                "{name}"
            );
        }
        // A schema 4 file is not schema 3, and schema 3 is not 4.
        assert!(parse_v3(&fixture("settings-v4/valid/tiers-per-profile.json")).is_none());
        assert!(parse_v4(&fixture("settings-v3/valid/owner-example-per-profile.json")).is_none());
    }

    fn tiered(light: u32, heavy: u32, windows: u32, gib: u32) -> Settings {
        Settings {
            schema: 4,
            runner_count: light,
            linux_heavy_count: heavy,
            windows_runner_count: windows,
            job_memory_gib: gib,
            ..Settings::default()
        }
    }

    #[test]
    fn schema_four_refuses_tier_reservations_over_the_memory_total() {
        // The same inequality as validate.py sem_settings_v4 and the supervisor: heavy x 20 + light x 3.
        let err = tiered(10, 2, 0, 64).check_shape().unwrap_err();
        assert_eq!(
            err,
            "Heavy 2 + Light 10 need 70 GiB; total memory is 64 GiB"
        );
        let err = tiered(0, 1, 0, 19).check_shape().unwrap_err();
        assert_eq!(err, "Heavy 1 + Light 0 need 20 GiB; total memory is 19 GiB");
        // Exactly at the total is accepted.
        assert_eq!(tiered(10, 2, 0, 70).check_shape(), Ok(()));
        assert_eq!(tiered(0, 1, 0, 20).check_shape(), Ok(()));
        // The written file's check() says the same, and the write path surfaces it.
        let kept = parse_v4(&fixture("settings-v4/valid/tiers-per-profile.json")).unwrap();
        let v4 = SettingsV4::edited(&tiered(10, 2, 0, 64), kept, true);
        assert!(v4.check().unwrap_err().contains("need 70 GiB"));
    }

    #[test]
    fn schema_four_refuses_no_linux_runner() {
        // Windows alone is not a schema 4 pool: the supervisor that lists 4 runs no Windows VM.
        let err = tiered(0, 0, 0, 72).check_shape().unwrap_err();
        assert!(err.contains("one Linux runner"), "{err}");
        let err = tiered(0, 0, 2, 72).check_shape().unwrap_err();
        assert!(err.contains("one Linux runner"), "{err}");
        assert_eq!(tiered(0, 1, 0, 72).check_shape(), Ok(()));
    }

    #[test]
    fn writes_schema_four_only_while_a_fresh_status_v5_lists_it() {
        let base = temp_base("settings-v4-write");
        let s = Settings {
            schema: 4,
            linux_heavy_count: 1,
            ..Settings::derived(7, 0, false, &VM)
        };
        let _ = fs::remove_file(inbox(&base).join("settings.json"));
        write_v5(&base, "[1,2,3,4]", FRESH);
        write_settings_at(&base, &s, &VM, now()).unwrap();
        let w = written(&base);
        assert_eq!(
            w.as_object().unwrap().len(),
            15,
            "exactly the schema 4 keys"
        );
        assert_eq!(
            (w["schema"].clone(), w["linux_light_count"].clone()),
            (4.into(), 7.into())
        );
        assert_eq!(w["linux_heavy_count"], 1);
        assert_eq!(w["windows_runner_count"], 2, "the reported Windows count");
        assert!(w.get("runner_count").is_none());
        assert_eq!(parse_v4(&w.to_string()).map(|v| v.check()), Some(Ok(())));
        let back = read_settings(&base);
        assert_eq!((back.runner_count, back.linux_heavy_count), (7, 1));
        // Stored schema 4: kept whatever status.v5.json says, never 3 or 2 over it.
        for v5 in ["stale", "missing", "three"] {
            let _ = fs::remove_file(base.join("status.v5.json"));
            match v5 {
                "stale" => write_v5(&base, "[1,2,3,4]", "2000-01-01T00:00:00Z"),
                "three" => write_v5(&base, "[1,2,3]", FRESH),
                _ => {}
            }
            let paused = Settings {
                paused: true,
                ..read_settings(&base)
            };
            write_settings_at(&base, &paused, &VM, now()).unwrap();
            let mut want = w.clone();
            want["paused"] = true.into();
            assert_eq!(written(&base), want, "{v5}");
            assert!(tiers_writable_at(&base, now()), "{v5}");
        }
        fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn without_schema_four_heavy_is_refused_and_light_is_the_old_count() {
        let base = temp_base("settings-v4-refused");
        for schemas in ["[1,2]", "[1,2,3]"] {
            let _ = fs::remove_file(inbox(&base).join("settings.json"));
            write_v5(&base, schemas, FRESH);
            assert!(!tiers_writable_at(&base, now()), "{schemas}");
            let heavy = Settings {
                linux_heavy_count: 1,
                ..Settings::derived(2, 0, false, &VM)
            };
            let err = write_settings_at(&base, &heavy, &VM, now()).unwrap_err();
            assert_eq!(err.kind(), io::ErrorKind::InvalidInput, "{schemas}");
            assert!(!inbox(&base).join("settings.json").exists(), "{schemas}");
            // Light only: written as today's Linux count.
            write_settings_at(&base, &Settings::derived(2, 0, false, &VM), &VM, now()).unwrap();
            let w = written(&base);
            assert_eq!(w["runner_count"], 2, "{schemas}");
            assert!(w.get("linux_heavy_count").is_none(), "{schemas}");
        }
        // A schema 3 file is carried into schema 4 once the supervisor lists 4.
        write_v5(&base, "[1,2,3,4]", FRESH);
        fs::write(
            inbox(&base).join("settings.json"),
            fixture("settings-v3/valid/owner-example-per-profile.json"),
        )
        .unwrap();
        let edit = Settings {
            schema: 4,
            ..read_settings(&base)
        };
        write_settings_at(&base, &edit, &VM, now()).unwrap();
        let w = written(&base);
        assert_eq!(
            (
                w["schema"].clone(),
                w["linux_light_count"].clone(),
                w["linux_heavy_count"].clone(),
                w["linux_share_percent"].clone()
            ),
            (4.into(), 3.into(), 0.into(), 60.into())
        );
        fs::remove_dir_all(&base).unwrap();
    }
}
