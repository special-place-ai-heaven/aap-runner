//! Invariants of `docker_args` over a deterministic grid (no randomness, so no flaky runs).

use aap_pool_core::limits::{PoolSettings, Sharing, docker_args};

const CPUS: &[&str] = &[
    "1", "2", "3", "5", "6", "7", "10", "16", "24", "64", "2.5", "6.9", "0.5",
];
const MEMORY: &[&str] = &[
    "1g",
    "1024m",
    "5g",
    "5119m",
    "5120m",
    "6g",
    "12g",
    "12G",
    "72g",
    "100000m",
    "1048576k",
    "1073741824b",
    "2097152",
    "4294967296g",
];

/// Whole MiB of a docker memory string.
fn mib(docker: &str) -> u128 {
    let (digits, unit) = match docker.as_bytes().last() {
        Some(b'k' | b'K') => (&docker[..docker.len() - 1], 1u128 << 10),
        Some(b'm' | b'M') => (&docker[..docker.len() - 1], 1 << 20),
        Some(b'g' | b'G') => (&docker[..docker.len() - 1], 1 << 30),
        Some(b'b' | b'B') => (&docker[..docker.len() - 1], 1),
        _ => (docker, 1),
    };
    digits.parse::<u128>().unwrap() * unit / (1 << 20)
}

fn value<'a>(args: &'a [String], flag: &str) -> &'a str {
    let i = args
        .iter()
        .position(|a| a == flag)
        .unwrap_or_else(|| panic!("no {flag}"));
    &args[i + 1]
}

#[test]
fn slot_totals_stay_within_the_pool_and_floor_exactly() {
    let mut checked = 0;
    for cpus in CPUS {
        for memory in MEMORY {
            for runners in 1..=5u128 {
                for sharing in [Sharing::Slice, Sharing::Fixed] {
                    let s = PoolSettings {
                        cpus: cpus.parse().unwrap(),
                        memory: memory.parse().unwrap(),
                        runners: runners.to_string().parse().unwrap(),
                        sharing,
                        ..Default::default()
                    };
                    let ctx = format!("{cpus} {memory} x{runners} {sharing:?}");
                    let args = match docker_args(&s) {
                        Ok(args) => args,
                        Err(e) => {
                            // Only a real under-1-cpu or under-1g share may refuse.
                            let pool_whole: u128 = cpus.split('.').next().unwrap().parse().unwrap();
                            assert!(
                                runners > 1
                                    && (pool_whole / runners < 1 || mib(memory) / runners < 1024),
                                "{ctx}: refused without cause: {e}"
                            );
                            continue;
                        }
                    };
                    checked += 1;
                    let pool_mib = mib(memory);
                    assert_eq!(
                        value(&args, "--memory-swap"),
                        value(&args, "--memory"),
                        "{ctx}"
                    );
                    let (slot_mem, slot_cpus) = match sharing {
                        Sharing::Slice => {
                            // The pool totals are the caps, verbatim; only the soft share splits.
                            assert_eq!(value(&args, "--memory"), *memory, "{ctx}");
                            assert_eq!(value(&args, "--cpus"), *cpus, "{ctx}");
                            (value(&args, "--memory-reservation"), None)
                        }
                        Sharing::Fixed => (value(&args, "--memory"), Some(value(&args, "--cpus"))),
                    };
                    let slot_mib = mib(slot_mem);
                    if runners == 1 {
                        assert_eq!(slot_mem, *memory, "{ctx}");
                        assert!(slot_cpus.is_none_or(|c| c == *cpus), "{ctx}");
                        continue;
                    }
                    assert!(slot_mib >= 1024, "{ctx}: under 1g");
                    assert!(
                        slot_mib * runners <= pool_mib,
                        "{ctx}: memory over the pool"
                    );
                    assert!(
                        (slot_mib + 1) * runners > pool_mib,
                        "{ctx}: memory not floored"
                    );
                    if let Some(c) = slot_cpus {
                        let slot: u128 = c.parse().unwrap();
                        let pool_whole: u128 = cpus.split('.').next().unwrap().parse().unwrap();
                        assert!(slot >= 1, "{ctx}: under 1 cpu");
                        assert!(slot * runners <= pool_whole, "{ctx}: cpus over the pool");
                        assert!((slot + 1) * runners > pool_whole, "{ctx}: cpus not floored");
                    }
                }
            }
        }
    }
    assert!(checked > 200, "grid too small to mean anything: {checked}");
}

#[test]
fn io_cap_per_slot_is_floored_at_least_ten_and_within_the_budget() {
    use aap_pool_core::limits::IoSettings;
    let mut checked = 0;
    for disk in [
        "1",
        "9",
        "10",
        "11",
        "40",
        "49",
        "50",
        "99",
        "100",
        "1000",
        "123456789",
        "999999999",
    ] {
        for percent in ["0", "1", "10", "50", "90", "99", "100"] {
            for runners in 1..=5u64 {
                let s = PoolSettings {
                    runners: runners.to_string().parse().unwrap(),
                    sharing: Sharing::Fixed,
                    io: IoSettings {
                        percent: percent.parse().unwrap(),
                        disk_mibps: Some(disk.parse().unwrap()),
                        device: Some("/dev/sde".parse().unwrap()),
                    },
                    ..Default::default()
                };
                let (d, p): (u64, u64) = (disk.parse().unwrap(), percent.parse().unwrap());
                let budget = d * p / 100;
                let Ok(args) = docker_args(&s) else {
                    assert!(
                        p > 0 && budget / runners < 10,
                        "{disk} {percent} x{runners}"
                    );
                    continue;
                };
                checked += 1;
                if p == 0 {
                    assert!(!args.iter().any(|a| a.starts_with("--device")));
                    continue;
                }
                let bps = value(&args, "--device-read-bps");
                let slot: u64 = bps
                    .strip_prefix("/dev/sde:")
                    .unwrap()
                    .strip_suffix("mb")
                    .unwrap()
                    .parse()
                    .unwrap();
                assert!(slot >= 10 && slot * runners <= budget && (slot + 1) * runners > budget);
                assert_eq!(bps, value(&args, "--device-write-bps"));
                assert_eq!(
                    value(&args, "--device-read-iops"),
                    format!("/dev/sde:{}", slot * 8)
                );
                assert_eq!(
                    value(&args, "--device-write-iops"),
                    format!("/dev/sde:{}", slot * 8)
                );
            }
        }
    }
    assert!(checked > 100, "{checked}");
}
