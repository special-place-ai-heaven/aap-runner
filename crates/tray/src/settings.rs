//! `inbox\settings.json`: pool size and pool-total limits, written by the tray, applied by the
//! supervisor. The window edits the runner count, the IO cap and the sharing mode, and shows each
//! runner's even share of the caps to one decimal. The file stores the caps.
//! Schema 2 adds `schema`, `io_percent` and `sharing`; a schema 1 file reads with their defaults.

use crate::state::{inbox, read_bounded, write_atomic};
use serde::{Deserialize, Serialize};
use std::io;
use std::ops::RangeInclusive;
use std::path::Path;

pub const RUNNERS: RangeInclusive<u32> = 1..=5;

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
/// What this tray writes.
pub const SETTINGS_SCHEMA: u32 = 2;

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

    /// What the window writes: the pool caps. Each runner's share is `cap / runners`.
    pub fn derived(runners: u32, paused: bool, vm: &VmLimit) -> Settings {
        let (job_cpus, job_memory_gib) = vm.cap();
        Settings {
            runner_count: runners,
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
        check("Runners", self.runner_count, &RUNNERS)?;
        check("Total CPUs", self.job_cpus, &CPUS)?;
        check("Total memory GiB", self.job_memory_gib, &MEMORY_GIB)?;
        check("IO cap percent", self.io_percent, &IO_PERCENT)?;
        let (cpus, gib) = self.per_runner();
        if cpus < 1 || gib < 1 {
            return Err("Each runner needs at least 1 CPU and 1 GiB".into());
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
pub fn read_settings(base: &Path) -> Settings {
    read_bounded(&inbox(base).join("settings.json"))
        .and_then(|s| serde_json::from_str::<Settings>(s.trim_start_matches('\u{feff}')).ok())
        .filter(|s| s.check_shape().is_ok())
        .unwrap_or_default()
}

/// Refuses to write a file that fails `validate`. Always writes schema 2.
pub fn write_settings(base: &Path, s: &Settings, vm: &VmLimit) -> io::Result<()> {
    s.validate(vm)
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;
    let s = Settings {
        schema: SETTINGS_SCHEMA,
        ..*s
    };
    write_atomic(&inbox(base).join("settings.json"), &serde_json::to_vec(&s)?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state::temp_base;
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
            let s = Settings::derived(r, false, vm);
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
        let five = Settings::derived(5, false, &wide);
        assert_eq!((five.job_cpus, five.job_memory_gib), (24, 72));
        assert_eq!(share_text(five.job_cpus, 5), "4.8");
        assert_eq!(share_text(five.job_memory_gib, 5), "14.4");
        assert_eq!(cpu_share(24, 5, false), 4.8);
        assert_eq!(cpu_share(24, 5, true), 4.0);
        assert_eq!(one_decimal(cpu_share(24, 5, true)), "4");
        assert!(five.validate(&wide).is_ok());
        assert_eq!(Settings::derived(1, false, &VM), Settings::default());
        assert!(Settings::derived(2, true, &VM).paused);
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
}
