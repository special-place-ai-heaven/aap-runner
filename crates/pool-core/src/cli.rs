//! The `aap-pool` command line. Kept in the library so tests drive it without a process.

use std::io::Write;

use crate::limits::{PoolSettings, docker_args};

/// Exit code for a bad command line or a refused pool. stdout stays empty.
pub const EXIT_INVALID: u8 = 2;
/// Exit code when stdout cannot be written.
pub const EXIT_IO: u8 = 1;

pub const HELP: &str = "\
aap-pool: runner pool control-plane helper

USAGE:
    aap-pool limits [OPTIONS]
    aap-pool --help

limits prints the docker resource arguments of one job container, one argument per
line, exactly as distro/manager.sh passes them to `docker create`. From bash, check the
exit code before using the output (a process substitution would hide a refusal):
    out=$(aap-pool limits --runners 2 --sharing fixed) || return 1
    mapfile -t lim <<< \"${out}\"

OPTIONS (defaults are the manager.sh defaults):
    --runners <1..5>         parallel job containers                      [1]
    --cpus <n[.f]>           pool cpu total, greater than 0, at most 9    [6]
                             integer and 6 decimal digits not counting
                             leading and trailing zeros
    --memory <n[suffix]>     pool memory total, suffix b|k|m|g, any case  [12g]
    --pids-limit <n>         --pids-limit per container                   [4096]
    --sharing <slice|fixed>  slice shares the pool caps, fixed splits it  [slice]
    --io-percent <0..100>    share of the disk given to the pool, 0 = off [90]
    --disk-mibps <n>         measured work-disk MiB/s, 1..999999999; absent or
                             anything else = no cap, as manager.sh treats a
                             missing or bad measurement
    --io-device <path>       whole block device, /dev/<name>; absent or anything
                             else = no cap flags, as manager.sh treats a mount
                             without a block device
    -h, --help               print this help

EXIT: 0 success; 2 invalid option or value, or the pool is refused (slot under
1 cpu or 1g, slot under 10 MiB/s); one line on stderr, nothing on stdout; 1 stdout write failed.
";

/// Runs the command line (without the program name) and returns the exit code.
pub fn run<I>(args: I, out: &mut impl Write, err: &mut impl Write) -> u8
where
    I: IntoIterator<Item = String>,
{
    let mut args = args.into_iter();
    match args.next().as_deref() {
        Some("-h" | "--help") => write_or_exit(out, HELP),
        Some("limits") => limits(args, out, err),
        Some(other) => fail(err, &format!("unknown command '{other}'; try --help")),
        None => fail(err, "missing command; try --help"),
    }
}

fn limits<I>(args: I, out: &mut impl Write, err: &mut impl Write) -> u8
where
    I: Iterator<Item = String>,
{
    let settings = match parse_limits_args(args) {
        Ok(None) => return write_or_exit(out, HELP),
        Ok(Some(s)) => s,
        Err(msg) => return fail(err, &msg),
    };
    match docker_args(&settings) {
        Ok(lines) => write_or_exit(
            out,
            &lines.iter().map(|a| format!("{a}\n")).collect::<String>(),
        ),
        Err(e) => fail(err, &e.to_string()),
    }
}

/// The settings, or `None` when help was asked for.
fn parse_limits_args<I>(mut args: I) -> Result<Option<PoolSettings>, String>
where
    I: Iterator<Item = String>,
{
    let mut s = PoolSettings::default();
    while let Some(flag) = args.next() {
        // Taken only once the flag is known, so a stray word reports itself, not "needs a value".
        let mut value = || args.next().ok_or_else(|| format!("{flag} needs a value"));
        let bad = |e: crate::limits::LimitsError| e.to_string();
        match flag.as_str() {
            "-h" | "--help" => return Ok(None),
            "--runners" => s.runners = value()?.parse().map_err(bad)?,
            "--cpus" => s.cpus = value()?.parse().map_err(bad)?,
            "--memory" => s.memory = value()?.parse().map_err(bad)?,
            "--pids-limit" => s.pids_limit = value()?.parse().map_err(bad)?,
            "--sharing" => s.sharing = value()?.parse().map_err(bad)?,
            "--io-percent" => s.io.percent = value()?.parse().map_err(bad)?,
            // manager.sh drops the IO cap, never the pool, for a bad measurement or device.
            "--disk-mibps" => s.io.disk_mibps = value()?.parse().ok(),
            "--io-device" => s.io.device = value()?.parse().ok(),
            other => return Err(format!("unknown option '{other}'; try --help")),
        }
    }
    Ok(Some(s))
}

fn write_or_exit(out: &mut impl Write, text: &str) -> u8 {
    match out.write_all(text.as_bytes()).and_then(|()| out.flush()) {
        Ok(()) => 0,
        Err(_) => EXIT_IO,
    }
}

fn fail(err: &mut impl Write, msg: &str) -> u8 {
    // A closed stderr leaves nothing to report to; the exit code still says it failed.
    let _ = writeln!(err, "aap-pool: {msg}");
    EXIT_INVALID
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run_args(args: &[&str]) -> (u8, String, String) {
        let (mut out, mut err) = (Vec::new(), Vec::new());
        let code = run(args.iter().map(|a| (*a).to_owned()), &mut out, &mut err);
        (
            code,
            String::from_utf8(out).unwrap(),
            String::from_utf8(err).unwrap(),
        )
    }

    #[test]
    fn prints_one_argument_per_line() {
        let (code, out, err) = run_args(&["limits", "--runners", "2", "--sharing", "fixed"]);
        assert_eq!((code, err.as_str()), (0, ""));
        assert_eq!(
            out,
            "--memory\n6g\n--memory-swap\n6g\n--cpus\n3\n--cpu-shares\n512\n--pids-limit\n4096\n"
        );
    }

    #[test]
    fn invalid_input_is_one_stderr_line_and_empty_stdout() {
        for args in [
            &["limits", "--runners", "6"][..],
            &["limits", "--runners"],
            &["limits", "--bogus", "1"],
            &["limits", "foo"],
            &["limits", "--runners", "5", "--cpus", "4"],
            &["nope"],
            &[],
        ] {
            let (code, out, err) = run_args(args);
            assert_eq!(code, EXIT_INVALID, "{args:?}");
            assert_eq!(out, "", "{args:?}");
            assert!(
                err.starts_with("aap-pool: ") && err.matches('\n').count() == 1,
                "{args:?}"
            );
        }
    }

    #[test]
    fn a_stray_word_is_an_unknown_option() {
        let (_, _, err) = run_args(&["limits", "foo"]);
        assert_eq!(
            err,
            "aap-pool: unknown option 'foo'; try --help
"
        );
    }

    #[test]
    fn a_bad_measurement_or_device_drops_only_the_io_cap() {
        let capped = [
            "--runners",
            "2",
            "--sharing",
            "fixed",
            "--io-percent",
            "100",
        ];
        let no_cap = run_args(&[&["limits"][..], &capped].concat());
        for extra in [
            &["--disk-mibps", "abc", "--io-device", "/dev/sde"][..],
            &["--disk-mibps", "", "--io-device", "/dev/sde"],
            &["--disk-mibps", "0", "--io-device", "/dev/sde"],
            &["--disk-mibps", "1000", "--io-device", "tmpfs"],
            &["--disk-mibps", "1000", "--io-device", ""],
        ] {
            let got = run_args(&[&["limits"][..], &capped, extra].concat());
            assert_eq!(got, no_cap, "{extra:?}");
        }
        let (code, out, _) = run_args(
            &[
                &["limits"][..],
                &capped,
                &["--disk-mibps", "1000", "--io-device", "/dev/sde"],
            ]
            .concat(),
        );
        assert_eq!(code, 0);
        assert!(
            out.contains(
                "--device-read-bps
/dev/sde:500mb
"
            ),
            "{out}"
        );
    }

    #[test]
    fn help_goes_to_stdout() {
        for args in [&["--help"][..], &["-h"], &["limits", "--help"]] {
            let (code, out, err) = run_args(args);
            assert_eq!((code, out.as_str(), err.as_str()), (0, HELP, ""));
        }
    }
}
