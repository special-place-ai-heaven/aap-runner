//! What the tray remembers between polls and the window shows: the last 60 pool samples and the
//! last 10 problems. The tray owns it and mirrors it to `%TEMP%\aap-runner-tray\history.json`,
//! because the window is a separate process.
//! ponytail: per-user temp mirror, lost on reboot; move into status.json if the owner misses it.

use crate::problem::Class;
use crate::state::{Snapshot, read_bounded, write_atomic};
use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use std::io;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

pub const SAMPLES: usize = 60;
pub const PROBLEMS: usize = 10;
/// A recorded problem line is cut here, so one huge supervisor detail cannot push
/// `history.json` past the 64 KiB read bound and blank the whole history.
pub const LINE_CHARS: usize = 200;

/// One pool sample at `sampled_at` (unix seconds).
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Sample {
    pub t: u64,
    pub cores: Option<f64>,
    pub gib: Option<f64>,
}

/// One error transition: entered at `since`, left at `until` (`None` = still now).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Problem {
    pub since: u64,
    pub until: Option<u64>,
    pub class: Class,
    pub line: String,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct History {
    pub samples: VecDeque<Sample>,
    pub problems: VecDeque<Problem>,
}

pub fn secs(t: SystemTime) -> u64 {
    t.duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs())
}

impl History {
    pub fn path() -> PathBuf {
        std::env::temp_dir()
            .join("aap-runner-tray")
            .join("history.json")
    }

    /// Missing or unreadable = empty.
    pub fn load(path: &Path) -> History {
        read_bounded(path)
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default()
    }

    pub fn save(&self, path: &Path) -> io::Result<()> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        write_atomic(path, &serde_json::to_vec(self)?)
    }

    /// Take a poll: a new sample when `sampled_at` changed, a transition when the problem class
    /// changed. Returns whether anything changed. `sampled_at` is the distro's clock, which gets
    /// stepped back: an earlier one drops the stored samples after it (from the wrong clock).
    pub fn observe(
        &mut self,
        snap: &Snapshot,
        class: Option<Class>,
        line: &str,
        now: SystemTime,
    ) -> bool {
        let mut changed = false;
        if let Some(t) = snap.sampled_at.map(secs)
            && (snap.pool.cpu_cores.is_some() || snap.pool.mem_gib.is_some())
            && self.samples.back().is_none_or(|s| t != s.t)
        {
            while self.samples.back().is_some_and(|s| s.t >= t) {
                self.samples.pop_back();
            }
            self.samples.push_back(Sample {
                t,
                cores: snap.pool.cpu_cores,
                gib: snap.pool.mem_gib,
            });
            if self.samples.len() > SAMPLES {
                self.samples.pop_front();
            }
            changed = true;
        }
        let open = self
            .problems
            .back()
            .filter(|p| p.until.is_none())
            .map(|p| p.class);
        if open != class {
            let now = secs(now);
            if let Some(p) = self.problems.back_mut().filter(|p| p.until.is_none()) {
                p.until = Some(now);
            }
            if let Some(class) = class {
                self.problems.push_back(Problem {
                    since: now,
                    until: None,
                    class,
                    line: line.chars().take(LINE_CHARS).collect(),
                });
                if self.problems.len() > PROBLEMS {
                    self.problems.pop_front();
                }
            }
            changed = true;
        }
        changed
    }
}

/// Whether the mirror file is behind the memory: a failed save is retried on every poll
/// until it succeeds, and only the first failure of a streak is reported.
#[derive(Debug, Default)]
pub struct Mirror {
    dirty: bool,
    failing: bool,
}

impl Mirror {
    /// `changed` is what `observe` returned. The error is `Some` only on the first failure.
    pub fn sync(&mut self, history: &History, path: &Path, changed: bool) -> Option<io::Error> {
        self.dirty |= changed;
        if !self.dirty {
            return None;
        }
        match history.save(path) {
            Ok(()) => {
                self.dirty = false;
                self.failing = false;
                None
            }
            Err(e) => (!std::mem::replace(&mut self.failing, true)).then_some(e),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state::{Pool, Status};
    use std::time::Duration;

    fn at(s: u64) -> SystemTime {
        UNIX_EPOCH + Duration::from_secs(s)
    }

    fn sampled(t: u64, cores: f64) -> Snapshot {
        Snapshot {
            sampled_at: Some(at(t)),
            pool: Pool {
                cpu_cores: Some(cores),
                mem_gib: Some(2.0 * cores),
                io_mbps: None,
            },
            ..Snapshot::bare(Status::Idle)
        }
    }

    #[test]
    fn samples_ring_keeps_the_last_sixty_and_skips_repeats() {
        let mut h = History::default();
        for i in 0..70 {
            assert!(h.observe(&sampled(1000 + 60 * i, i as f64), None, "", at(0)));
            assert!(
                !h.observe(&sampled(1000 + 60 * i, 99.0), None, "", at(0)),
                "same sample"
            );
        }
        assert_eq!(h.samples.len(), SAMPLES);
        assert_eq!(h.samples.front().unwrap().cores, Some(10.0));
        assert_eq!(h.samples.back().unwrap().t, 1000 + 60 * 69);
        assert!(
            h.observe(&sampled(10, 1.0), None, "", at(0)),
            "an older sample is a stepped-back clock: it replaces the later ones"
        );
        assert_eq!(h.samples.len(), 1);
        let no_pool = Snapshot {
            sampled_at: Some(at(999_999)),
            ..Snapshot::bare(Status::Idle)
        };
        assert!(
            !h.observe(&no_pool, None, "", at(0)),
            "no numbers, no sample"
        );
    }

    #[test]
    fn a_clock_stepped_back_does_not_freeze_the_chart() {
        let mut h = History::default();
        for t in [1000, 1060, 1120, 1180] {
            assert!(h.observe(&sampled(t, 1.0), None, "", at(0)));
        }
        // The distro clock steps back to 1070: the samples after it were from the wrong clock.
        assert!(h.observe(&sampled(1070, 2.0), None, "", at(0)));
        let ts: Vec<u64> = h.samples.iter().map(|s| s.t).collect();
        assert_eq!(ts, [1000, 1060, 1070]);
        assert!(!h.observe(&sampled(1070, 3.0), None, "", at(0)), "repeat");
        assert!(
            h.observe(&sampled(1130, 4.0), None, "", at(0)),
            "keeps going"
        );
        // Back onto a stored second: replaced, not duplicated.
        assert!(h.observe(&sampled(1060, 5.0), None, "", at(0)));
        let ts: Vec<u64> = h.samples.iter().map(|s| s.t).collect();
        assert_eq!(ts, [1000, 1060]);
        assert_eq!(h.samples.back().unwrap().cores, Some(5.0));
    }

    #[test]
    fn a_huge_problem_line_is_cut_on_a_char_boundary() {
        let mut h = History::default();
        let long = "\u{e9}".repeat(10_000);
        h.observe(
            &Snapshot::bare(Status::Idle),
            Some(Class::Other),
            &long,
            at(1),
        );
        let line = &h.problems[0].line;
        assert_eq!(line.chars().count(), LINE_CHARS);
        assert!(line.chars().all(|c| c == '\u{e9}'));
        let dir = crate::state::temp_base("history-cap");
        let path = dir.join("history.json");
        h.save(&path).unwrap();
        assert_eq!(History::load(&path), h);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_failed_save_is_retried_until_it_works_and_logged_once() {
        let dir = crate::state::temp_base("history-retry");
        let blocker = dir.join("blocker");
        std::fs::write(&blocker, "a file where the folder should be").unwrap();
        let path = blocker.join("history.json");
        let mut h = History::default();
        let mut mirror = Mirror::default();
        let idle = Snapshot::bare(Status::Idle);
        let changed = h.observe(&idle, Some(Class::Mount), "disk", at(100));
        assert!(mirror.sync(&h, &path, changed).is_some(), "first failure");
        assert!(
            mirror.sync(&h, &path, false).is_none(),
            "same streak, not again"
        );
        std::fs::remove_file(&blocker).unwrap();
        assert!(mirror.sync(&h, &path, false).is_none());
        assert_eq!(
            History::load(&path),
            h,
            "saved by the retry, nothing changed since"
        );
        std::fs::remove_file(&path).unwrap();
        assert!(mirror.sync(&h, &path, false).is_none());
        assert!(!path.exists(), "clean again: no more writes");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn problems_record_transitions_and_keep_ten() {
        let mut h = History::default();
        let idle = Snapshot::bare(Status::Idle);
        assert!(h.observe(&idle, Some(Class::Mount), "disk", at(100)));
        assert!(
            !h.observe(&idle, Some(Class::Mount), "disk", at(160)),
            "still the same"
        );
        assert!(h.observe(&idle, Some(Class::RestartLoop), "loop", at(200)));
        assert!(h.observe(&idle, None, "", at(300)));
        assert_eq!(h.problems[0].until, Some(200));
        assert_eq!(h.problems[1].since, 200);
        assert_eq!(h.problems[1].until, Some(300));
        for i in 0..20 {
            h.observe(&idle, Some(Class::Other), "x", at(400 + 2 * i));
            h.observe(&idle, None, "", at(401 + 2 * i));
        }
        assert_eq!(h.problems.len(), PROBLEMS);
        assert!(h.problems.iter().all(|p| p.until.is_some()));
    }

    #[test]
    fn mirror_round_trips() {
        let base = crate::state::temp_base("history");
        let path = base.join("sub").join("history.json");
        assert_eq!(History::load(&path), History::default());
        let mut h = History::default();
        h.observe(&sampled(1000, 4.5), Some(Class::Probe), "probe", at(5));
        h.save(&path).unwrap();
        assert_eq!(History::load(&path), h);
        std::fs::write(&path, "garbage").unwrap();
        assert_eq!(History::load(&path), History::default());
        std::fs::remove_dir_all(&base).unwrap();
    }
}
