//! Per-slot docker resource arguments, the Rust twin of `finish_job_limits`,
//! `finish_runner_count`, `finish_io_limits` and the `lim=(...)` block of `run_one` in
//! `distro/manager.sh`.
//!
//! Every input type validates the same grammar as the bash manager. Cpus and memory keep the
//! original string because bash passes the pool totals verbatim (one slot, and slice mode);
//! only the split for two or more slots is computed.
//!
//! Ceilings bash does not have: cpus take at most 9 integer and 6 fractional digits. bash divides
//! in awk doubles, so beyond about 15 significant digits its answer depends on float rounding and
//! on the awk build; inside the ceiling the exact integer division here is identical.

use std::fmt;
use std::str::FromStr;

/// The runtime systemd slice every job container joins in slice mode.
pub const POOL_SLICE: &str = "aap-runner-pool.slice";
/// `CPU_SHARES` in `manager.sh`: only weights containers inside the WSL VM.
pub const CPU_SHARES: u16 = 512;
/// `IO_IOPS_PER_MB`: a 128 KiB average request.
const IOPS_PER_MIBPS: u64 = 8;
/// A slot under this many MiB/s is refused.
const MIN_SLOT_IO_MIBPS: u64 = 10;
const MIB: u64 = 1024 * 1024;
const MIN_SLOT_MIB: u64 = 1024;
const MAX_RUNNERS: u8 = 5;
/// `finish_runner_count` refuses `num * mult` above this before it can wrap a bash integer.
const MAX_SPLIT_BYTES: u64 = 1 << 62;
const MAX_CPU_INT_DIGITS: usize = 9;
const MAX_CPU_FRAC_DIGITS: usize = 6;

/// Why the settings were rejected. The message is one line, for stderr.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LimitsError {
    InvalidRunnerCount(String),
    InvalidCpus(String),
    InvalidMemory(String),
    InvalidPidsLimit(String),
    InvalidIoPercent(String),
    InvalidDiskMibps(String),
    InvalidIoDevice(String),
    InvalidSharing(String),
    MemoryTooLargeToSplit(String),
    SlotTooSmall {
        runners: u8,
        cpus: u32,
        mib: u64,
    },
    SlotIoTooLow {
        percent: u8,
        disk_mibps: u32,
        runners: u8,
        per_slot: u64,
    },
}

impl fmt::Display for LimitsError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidRunnerCount(v) => write!(f, "runner count '{v}' is not 1..5"),
            Self::InvalidCpus(v) => write!(
                f,
                "cpus '{v}' is not a positive decimal (up to {MAX_CPU_INT_DIGITS} integer and {MAX_CPU_FRAC_DIGITS} fractional digits)"
            ),
            Self::InvalidMemory(v) => {
                write!(
                    f,
                    "memory '{v}' is not a positive integer with an optional b, k, m or g suffix"
                )
            }
            Self::InvalidPidsLimit(v) => write!(f, "pids limit '{v}' is not a positive integer"),
            Self::InvalidIoPercent(v) => write!(f, "io percent '{v}' is not 0..100"),
            Self::InvalidDiskMibps(v) => write!(f, "disk MiB/s '{v}' is not 1..999999999"),
            Self::InvalidIoDevice(v) => write!(f, "io device '{v}' is not /dev/<name>"),
            Self::InvalidSharing(v) => write!(f, "sharing '{v}' is not slice or fixed"),
            Self::MemoryTooLargeToSplit(v) => write!(f, "memory '{v}' is too large to split"),
            Self::SlotTooSmall { runners, cpus, mib } => write!(
                f,
                "{runners} runners split the pool into {cpus} cpus and {mib}m per slot; each slot needs 1 cpu and 1g"
            ),
            Self::SlotIoTooLow {
                percent,
                disk_mibps,
                runners,
                per_slot,
            } => write!(
                f,
                "{percent}% of {disk_mibps} MiB/s over {runners} slot(s) is {per_slot} MiB/s per slot; each slot needs {MIN_SLOT_IO_MIBPS}"
            ),
        }
    }
}

impl std::error::Error for LimitsError {}

/// `^(0|[1-9][0-9]*)$`
fn is_plain_uint(s: &str) -> bool {
    match s.as_bytes() {
        [b'0'] => true,
        [b'1'..=b'9', rest @ ..] => rest.iter().all(u8::is_ascii_digit),
        _ => false,
    }
}

fn is_positive_uint(s: &str) -> bool {
    is_plain_uint(s) && s != "0"
}

/// Parallel job containers, 1..=5.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RunnerCount(u8);

impl RunnerCount {
    pub fn get(self) -> u8 {
        self.0
    }
}

impl Default for RunnerCount {
    fn default() -> Self {
        Self(1)
    }
}

impl FromStr for RunnerCount {
    type Err = LimitsError;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let bad = || LimitsError::InvalidRunnerCount(s.to_owned());
        if !is_plain_uint(s) || s.len() > 1 {
            return Err(bad());
        }
        match s.parse::<u8>() {
            Ok(n) if (1..=MAX_RUNNERS).contains(&n) => Ok(Self(n)),
            _ => Err(bad()),
        }
    }
}

/// The pool's cpu total, `^[0-9]+([.][0-9]+)?$` and greater than zero.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Cpus {
    raw: String,
    whole: u32,
}

impl Cpus {
    pub fn as_str(&self) -> &str {
        &self.raw
    }
}

impl Default for Cpus {
    fn default() -> Self {
        Self {
            raw: "6".to_owned(),
            whole: 6,
        }
    }
}

impl FromStr for Cpus {
    type Err = LimitsError;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let bad = || LimitsError::InvalidCpus(s.to_owned());
        let (int, frac) = match s.split_once('.') {
            Some((i, f)) => (i, f),
            None => (s, ""),
        };
        let digits = |d: &str| d.bytes().all(|b| b.is_ascii_digit());
        let frac_ok = s.find('.').is_none() || (!frac.is_empty() && digits(frac));
        if int.is_empty()
            || !digits(int)
            || !frac_ok
            || int.len() > MAX_CPU_INT_DIGITS
            || frac.len() > MAX_CPU_FRAC_DIGITS
            || !int.bytes().chain(frac.bytes()).any(|b| b != b'0')
        {
            return Err(bad());
        }
        let whole = int.parse::<u32>().map_err(|_| bad())?;
        Ok(Self {
            raw: s.to_owned(),
            whole,
        })
    }
}

/// The pool's memory total: a positive integer and one optional docker suffix.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MemoryLimit {
    raw: String,
    /// The integer part, or `None` past 18 digits (bash refuses to split those).
    amount: Option<u64>,
    bytes_per_unit: u64,
}

impl MemoryLimit {
    pub fn as_str(&self) -> &str {
        &self.raw
    }

    /// Whole MiB per slot, rounded down: `num * mult / count / 1 MiB`, left to right like bash.
    fn split_mib(&self, runners: RunnerCount) -> Result<u64, LimitsError> {
        let too_large = || LimitsError::MemoryTooLargeToSplit(self.raw.clone());
        let amount = self.amount.ok_or_else(too_large)?;
        if amount > MAX_SPLIT_BYTES / self.bytes_per_unit {
            return Err(too_large());
        }
        Ok(amount * self.bytes_per_unit / u64::from(runners.0) / MIB)
    }
}

impl Default for MemoryLimit {
    fn default() -> Self {
        Self {
            raw: "12g".to_owned(),
            amount: Some(12),
            bytes_per_unit: 1 << 30,
        }
    }
}

impl FromStr for MemoryLimit {
    type Err = LimitsError;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let bad = || LimitsError::InvalidMemory(s.to_owned());
        let (digits, bytes_per_unit) = match s.as_bytes().last() {
            Some(b'k' | b'K') => (&s[..s.len() - 1], 1 << 10),
            Some(b'm' | b'M') => (&s[..s.len() - 1], 1 << 20),
            Some(b'g' | b'G') => (&s[..s.len() - 1], 1 << 30),
            Some(b'b' | b'B') => (&s[..s.len() - 1], 1),
            _ => (s, 1),
        };
        if !is_positive_uint(digits) {
            return Err(bad());
        }
        let amount = if digits.len() > 18 {
            None
        } else {
            digits.parse::<u64>().ok()
        };
        Ok(Self {
            raw: s.to_owned(),
            amount,
            bytes_per_unit,
        })
    }
}

/// `--pids-limit`, `^[1-9][0-9]*$`, passed through verbatim.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PidsLimit(String);

impl Default for PidsLimit {
    fn default() -> Self {
        Self("4096".to_owned())
    }
}

impl FromStr for PidsLimit {
    type Err = LimitsError;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        if is_positive_uint(s) {
            Ok(Self(s.to_owned()))
        } else {
            Err(LimitsError::InvalidPidsLimit(s.to_owned()))
        }
    }
}

/// `AAP_JOB_IO_PERCENT`: share of the measured disk given to the pool, 0 (no cap) to 100.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct IoPercent(u8);

impl Default for IoPercent {
    fn default() -> Self {
        Self(90)
    }
}

impl FromStr for IoPercent {
    type Err = LimitsError;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let parsed = if is_plain_uint(s) && s.len() <= 3 {
            s.parse::<u8>().ok()
        } else {
            None
        };
        match parsed {
            Some(n) if n <= 100 => Ok(Self(n)),
            _ => Err(LimitsError::InvalidIoPercent(s.to_owned())),
        }
    }
}

/// The measured work-disk throughput in MiB/s, `^[1-9][0-9]{0,8}$`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DiskMibps(u32);

impl FromStr for DiskMibps {
    type Err = LimitsError;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        if is_positive_uint(s)
            && s.len() <= 9
            && let Ok(n) = s.parse()
        {
            return Ok(Self(n));
        }
        Err(LimitsError::InvalidDiskMibps(s.to_owned()))
    }
}

/// The whole block device behind the work mount, `^/dev/[A-Za-z0-9_-]+$`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IoDevice(String);

impl FromStr for IoDevice {
    type Err = LimitsError;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let name_ok = |n: &str| {
            !n.is_empty()
                && n.bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
        };
        match s.strip_prefix("/dev/") {
            Some(name) if name_ok(name) => Ok(Self(s.to_owned())),
            _ => Err(LimitsError::InvalidIoDevice(s.to_owned())),
        }
    }
}

/// How the pool total is shared between slots.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Sharing {
    /// Jobs share the pool slice's caps; each container may use up to the whole pool.
    #[default]
    Slice,
    /// Each slot gets a hard 1/count share.
    Fixed,
}

impl FromStr for Sharing {
    type Err = LimitsError;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "slice" => Ok(Self::Slice),
            "fixed" => Ok(Self::Fixed),
            _ => Err(LimitsError::InvalidSharing(s.to_owned())),
        }
    }
}

/// Disk IO inputs. No measurement, 0 percent, or no device means no cap flags.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct IoSettings {
    pub percent: IoPercent,
    pub disk_mibps: Option<DiskMibps>,
    pub device: Option<IoDevice>,
}

/// The pool settings after `manager.conf` and `limits.conf`; `Default` is the bash defaults.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct PoolSettings {
    pub runners: RunnerCount,
    pub cpus: Cpus,
    pub memory: MemoryLimit,
    pub pids_limit: PidsLimit,
    pub sharing: Sharing,
    pub io: IoSettings,
}

/// One slot's cpus and memory as docker strings.
struct SlotShare {
    cpus: String,
    memory: String,
}

fn split_pool(s: &PoolSettings) -> Result<SlotShare, LimitsError> {
    if s.runners.0 == 1 {
        return Ok(SlotShare {
            cpus: s.cpus.raw.clone(),
            memory: s.memory.raw.clone(),
        });
    }
    let cpus = s.cpus.whole / u32::from(s.runners.0);
    let mib = s.memory.split_mib(s.runners)?;
    if cpus < 1 || mib < MIN_SLOT_MIB {
        return Err(LimitsError::SlotTooSmall {
            runners: s.runners.0,
            cpus,
            mib,
        });
    }
    let memory = if mib % 1024 == 0 {
        format!("{}g", mib / 1024)
    } else {
        format!("{mib}m")
    };
    Ok(SlotShare {
        cpus: cpus.to_string(),
        memory,
    })
}

/// The per-slot IO cap in MiB/s, or `None` when there is no cap. Refused below 10 in both
/// sharing modes, as in bash, even though slice mode emits no `--device-*` flags.
fn slot_io_mibps(s: &PoolSettings) -> Result<Option<u64>, LimitsError> {
    let (Some(disk), percent) = (s.io.disk_mibps, s.io.percent.0) else {
        return Ok(None);
    };
    if percent == 0 {
        return Ok(None);
    }
    let budget = u64::from(disk.0) * u64::from(percent) / 100;
    let per_slot = budget / u64::from(s.runners.0);
    if per_slot < MIN_SLOT_IO_MIBPS {
        return Err(LimitsError::SlotIoTooLow {
            percent,
            disk_mibps: disk.0,
            runners: s.runners.0,
            per_slot,
        });
    }
    Ok(Some(per_slot))
}

/// The docker resource arguments for one job container, one argv element per entry, in the
/// order `run_one` passes them: the sharing-mode limits, `--cpu-shares`, `--pids-limit`.
pub fn docker_args(s: &PoolSettings) -> Result<Vec<String>, LimitsError> {
    let share = split_pool(s)?;
    let io = slot_io_mibps(s)?;
    let mut args: Vec<String> = Vec::new();
    let mut push = |pairs: &[(&str, &str)]| {
        for (flag, value) in pairs {
            args.push((*flag).to_owned());
            args.push((*value).to_owned());
        }
    };
    match s.sharing {
        Sharing::Slice => push(&[
            ("--cgroup-parent", POOL_SLICE),
            ("--memory", &s.memory.raw),
            ("--memory-swap", &s.memory.raw),
            ("--memory-reservation", &share.memory),
            ("--cpus", &s.cpus.raw),
        ]),
        Sharing::Fixed => {
            push(&[
                ("--memory", &share.memory),
                ("--memory-swap", &share.memory),
            ]);
            push(&[("--cpus", &share.cpus)]);
            if let (Some(mibps), Some(device)) = (io, &s.io.device) {
                let bps = format!("{}:{mibps}mb", device.0);
                let iops = format!("{}:{}", device.0, mibps * IOPS_PER_MIBPS);
                push(&[
                    ("--device-read-bps", &bps),
                    ("--device-write-bps", &bps),
                    ("--device-read-iops", &iops),
                    ("--device-write-iops", &iops),
                ]);
            }
        }
    }
    push(&[
        ("--cpu-shares", &CPU_SHARES.to_string()),
        ("--pids-limit", &s.pids_limit.0),
    ]);
    Ok(args)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse<T: FromStr>(s: &str) -> T
    where
        T::Err: fmt::Debug,
    {
        s.parse().unwrap()
    }

    #[test]
    fn defaults_match_bash() {
        let args = docker_args(&PoolSettings::default()).unwrap();
        assert_eq!(
            args.join(" "),
            "--cgroup-parent aap-runner-pool.slice --memory 12g --memory-swap 12g \
             --memory-reservation 12g --cpus 6 --cpu-shares 512 --pids-limit 4096"
        );
    }

    #[test]
    fn rejects_bad_grammar() {
        for s in ["", "0", "6", "01", "10", "-1", "+1", "1 ", "٣"] {
            assert!(s.parse::<RunnerCount>().is_err(), "{s}");
        }
        for s in [
            "",
            ".5",
            "5.",
            "0",
            "0.0",
            "-1",
            "1e3",
            "1,5",
            "6 ",
            "1234567890",
            "1.1234567",
        ] {
            assert!(s.parse::<Cpus>().is_err(), "{s}");
        }
        for s in [
            "", "0", "0g", "01g", "g", "1x", "1gg", "-1g", "1.5g", "1 g", "+1g",
        ] {
            assert!(s.parse::<MemoryLimit>().is_err(), "{s}");
        }
        for s in ["", "0", "01", "-1", "x", "1.0"] {
            assert!(s.parse::<PidsLimit>().is_err(), "{s}");
        }
        for s in ["", "-1", "101", "00", "010", "1000", "5.0"] {
            assert!(s.parse::<IoPercent>().is_err(), "{s}");
        }
        for s in ["", "0", "01", "1000000000", "1.5", "-4"] {
            assert!(s.parse::<DiskMibps>().is_err(), "{s}");
        }
        for s in [
            "",
            "sde",
            "/dev/",
            "/dev/sd e",
            "/dev/sd/e",
            "/dev/../x",
            "dev/sde",
        ] {
            assert!(s.parse::<IoDevice>().is_err(), "{s}");
        }
        for s in ["", "Slice", "both"] {
            assert!(s.parse::<Sharing>().is_err(), "{s}");
        }
    }

    #[test]
    fn accepts_grammar_edges() {
        for s in ["1", "2", "3", "4", "5"] {
            assert!(s.parse::<RunnerCount>().is_ok(), "{s}");
        }
        for s in [
            "0.5",
            "6.0",
            "007",
            "999999999",
            "0.000001",
            "999999999.999999",
        ] {
            assert!(s.parse::<Cpus>().is_ok(), "{s}");
        }
        for s in [
            "1",
            "1b",
            "1B",
            "1k",
            "1K",
            "1m",
            "1M",
            "1g",
            "1G",
            "999999999999999999",
        ] {
            assert!(s.parse::<MemoryLimit>().is_ok(), "{s}");
        }
        for s in ["0", "1", "90", "100"] {
            assert!(s.parse::<IoPercent>().is_ok(), "{s}");
        }
        assert!("999999999".parse::<DiskMibps>().is_ok());
        assert!("/dev/sde".parse::<IoDevice>().is_ok());
        assert!("/dev/nvme0n1".parse::<IoDevice>().is_ok());
    }

    #[test]
    fn one_slot_is_verbatim_and_split_is_computed() {
        let mut s = PoolSettings {
            cpus: parse("6.0"),
            memory: parse("12G"),
            ..Default::default()
        };
        s.sharing = Sharing::Fixed;
        assert_eq!(
            docker_args(&s).unwrap()[..6],
            ["--memory", "12G", "--memory-swap", "12G", "--cpus", "6.0"]
        );
        s.runners = parse("2");
        assert_eq!(
            docker_args(&s).unwrap()[..6],
            ["--memory", "6g", "--memory-swap", "6g", "--cpus", "3"]
        );
    }

    #[test]
    fn split_refusals() {
        let split = |cpus: &str, mem: &str, n: &str| {
            docker_args(&PoolSettings {
                cpus: parse(cpus),
                memory: parse(mem),
                runners: parse(n),
                ..Default::default()
            })
        };
        assert!(split("5", "5g", "5").is_ok());
        assert!(matches!(
            split("5", "5119m", "5"),
            Err(LimitsError::SlotTooSmall { .. })
        ));
        assert!(matches!(
            split("4", "20g", "5"),
            Err(LimitsError::SlotTooSmall { .. })
        ));
        assert!(split("6", "4294967296g", "2").is_ok());
        assert!(matches!(
            split("6", "4294967297g", "2"),
            Err(LimitsError::MemoryTooLargeToSplit(_))
        ));
        assert!(matches!(
            split("6", "1000000000000000000", "2"),
            Err(LimitsError::MemoryTooLargeToSplit(_))
        ));
        // One slot never splits, so the same size is accepted verbatim.
        assert!(split("6", "1000000000000000000", "1").is_ok());
    }

    #[test]
    fn io_cap_flags_and_refusal() {
        let io = |mibps: &str, pct: &str, n: &str, device: Option<&str>| PoolSettings {
            runners: parse(n),
            sharing: Sharing::Fixed,
            io: IoSettings {
                percent: parse(pct),
                disk_mibps: Some(parse(mibps)),
                device: device.map(parse),
            },
            ..Default::default()
        };
        let args = docker_args(&io("1000", "90", "4", Some("/dev/sde")))
            .unwrap()
            .join(" ");
        assert!(args.contains(
            "--device-read-bps /dev/sde:225mb --device-write-bps /dev/sde:225mb \
             --device-read-iops /dev/sde:1800 --device-write-iops /dev/sde:1800"
        ));
        assert!(
            !docker_args(&io("1000", "90", "4", None))
                .unwrap()
                .join(" ")
                .contains("--device")
        );
        assert!(
            !docker_args(&io("1000", "0", "4", Some("/dev/sde")))
                .unwrap()
                .join(" ")
                .contains("--device")
        );
        assert!(docker_args(&io("40", "100", "4", Some("/dev/sde"))).is_ok());
        assert!(matches!(
            docker_args(&io("45", "100", "5", Some("/dev/sde"))),
            Err(LimitsError::SlotIoTooLow { per_slot: 9, .. })
        ));
        // Refused even with no device and in slice mode.
        let mut s = io("45", "100", "5", None);
        s.sharing = Sharing::Slice;
        assert!(docker_args(&s).is_err());
    }
}
