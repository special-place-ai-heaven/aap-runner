//! `settings.json`: pool size and per-job limits, written by the tray, applied by the supervisor.

use crate::state::write_atomic;
use serde::{Deserialize, Serialize};
use std::fs;
use std::io;
use std::ops::RangeInclusive;
use std::path::Path;

pub const RUNNERS: RangeInclusive<u32> = 1..=4;
pub const CPUS: RangeInclusive<u32> = 1..=28;
pub const MEMORY_GIB: RangeInclusive<u32> = 1..=80;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    pub runner_count: u32,
    pub job_cpus: u32,
    pub job_memory_gib: u32,
    pub paused: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            runner_count: 1,
            job_cpus: 24,
            job_memory_gib: 72,
            paused: false,
        }
    }
}

impl Settings {
    /// Ranges, plus the pool floor: the manager splits limits per runner slot, so each
    /// slot needs at least 1 CPU and 1 GiB.
    pub fn validate(&self) -> Result<(), String> {
        let check = |name: &str, v: u32, r: &RangeInclusive<u32>| {
            if r.contains(&v) {
                Ok(())
            } else {
                Err(format!("{name} must be {}..{}", r.start(), r.end()))
            }
        };
        check("Runners", self.runner_count, &RUNNERS)?;
        check("CPUs per job", self.job_cpus, &CPUS)?;
        check("Memory per job", self.job_memory_gib, &MEMORY_GIB)?;
        if self.job_cpus < self.runner_count {
            return Err(format!(
                "CPUs per job must be at least {} (runners)",
                self.runner_count
            ));
        }
        if self.job_memory_gib < self.runner_count {
            return Err(format!(
                "Memory per job must be at least {} GiB (runners)",
                self.runner_count
            ));
        }
        Ok(())
    }

    pub fn toggle_label(&self) -> &'static str {
        if self.paused { "Resume" } else { "Pause" }
    }
}

/// Missing, unparseable or invalid file = defaults. Missing fields take their defaults.
pub fn read_settings(base: &Path) -> Settings {
    fs::read_to_string(base.join("settings.json"))
        .ok()
        .and_then(|s| serde_json::from_str::<Settings>(s.trim_start_matches('\u{feff}')).ok())
        .filter(|s| s.validate().is_ok())
        .unwrap_or_default()
}

/// Refuses to write an invalid file.
pub fn write_settings(base: &Path, s: &Settings) -> io::Result<()> {
    s.validate()
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;
    write_atomic(&base.join("settings.json"), &serde_json::to_vec(s)?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state::temp_base;

    fn with(f: impl FnOnce(&mut Settings)) -> Settings {
        let mut s = Settings::default();
        f(&mut s);
        s
    }

    #[test]
    fn bounds_and_floor() {
        assert_eq!(Settings::default().validate(), Ok(()));
        for (s, ok) in [
            (with(|s| s.runner_count = 0), false),
            (with(|s| s.runner_count = 4), true),
            (with(|s| s.runner_count = 5), false),
            (with(|s| s.job_cpus = 0), false),
            (with(|s| s.job_cpus = 28), true),
            (with(|s| s.job_cpus = 29), false),
            (with(|s| s.job_memory_gib = 0), false),
            (with(|s| s.job_memory_gib = 80), true),
            (with(|s| s.job_memory_gib = 81), false),
            (with(|s| (s.runner_count, s.job_cpus) = (4, 3)), false),
            (with(|s| (s.runner_count, s.job_cpus) = (4, 4)), true),
            (with(|s| (s.runner_count, s.job_memory_gib) = (3, 2)), false),
            (with(|s| (s.runner_count, s.job_memory_gib) = (3, 3)), true),
        ] {
            assert_eq!(s.validate().is_ok(), ok, "{s:?}");
        }
    }

    #[test]
    fn read_falls_back_to_defaults() {
        let base = temp_base("settings-read");
        assert_eq!(read_settings(&base), Settings::default());
        for garbage in [
            "not json",
            r#"{"runner_count":-1}"#,
            r#"{"runner_count":9}"#,
        ] {
            fs::write(base.join("settings.json"), garbage).unwrap();
            assert_eq!(read_settings(&base), Settings::default(), "{garbage}");
        }
        fs::write(
            base.join("settings.json"),
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
        let s = Settings {
            runner_count: 2,
            job_cpus: 12,
            job_memory_gib: 36,
            paused: true,
        };
        write_settings(&base, &s).unwrap();
        assert_eq!(read_settings(&base), s);
        assert!(!base.join("settings.json.tmp").exists());
        let raw: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(base.join("settings.json")).unwrap()).unwrap();
        assert_eq!(raw["job_memory_gib"], 36);
        assert!(write_settings(&base, &with(|s| s.job_cpus = 0)).is_err());
        assert_eq!(
            read_settings(&base),
            s,
            "invalid write must not touch the file"
        );
        fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn toggle_label() {
        assert_eq!(Settings::default().toggle_label(), "Pause");
        assert_eq!(with(|s| s.paused = true).toggle_label(), "Resume");
    }
}
