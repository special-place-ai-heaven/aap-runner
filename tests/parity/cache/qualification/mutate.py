"""Mutation proof for the P04.1 harness rules. Standard library only.

    python -B -I tests/parity/cache/qualification/mutate.py [--suite pester|bash] [--only ID ...] [--shell pwsh|powershell]
                                                              [--pester NAME-OR-PSD1] [--work DIR]

For each ID this copies parity/cache/qualification and tests/parity/cache/qualification to a scratch folder under
--work (default: the temp folder; always removed), disables one rule with the literal replacement below, and runs
only the test named for it against the copy. The mutation must make that test fail (KILLED). A test that still passes
(SURVIVED) or does not run (NO-TEST) means the rule is not proven. Each selected test first runs on an unmutated copy
and must pass there. Exit 0 only when every selected mutation is KILLED.

Pester runs in a child --shell through a runner .ps1 written under the copy and run with -File
and arguments, never an encoded command line (the owner rejected those; Malwarebytes quarantines
them as obfuscated PowerShell; Pester 5 must be importable). The bash suite needs real Linux: on
Windows it runs in WSL Ubuntu-24.04 from a copy below the WSL user's home (harness_test.sh's own
clean-lab tests fail on WSL by design, so only the named tests count).
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
TREES = ("parity/cache/qualification", "tests/parity/cache/qualification")
SH = "parity/cache/qualification/harness/qualify.sh"
PS = "parity/cache/qualification/harness/qualify.ps1"
JQ = "parity/cache/qualification/harness/record.jq"

# ID: (suite, test name, [(file, old, new), ...]); every variant must be KILLED. `old` occurs exactly once.
MUTATIONS = {
    "LNX-DAEMON-ROOT": ("bash", "owner of /w/cache-ok/v1.15.6/zccache-daemon",
                        [(SH, 'then echo root', 'then echo ""')]),
    "LNX-DAEMON-EXACT": ("bash", "owner of /w/cache-ok/x/v1.15.6/zccache-daemon",
                         [(SH, '"${rel#*/}" == "${ZQ_STATE}/zccache-daemon"', '"${rel}" == */"${ZQ_STATE}"/zccache-daemon')]),
    "LNX-DAEMON-STOP": ("bash", "stops the private copy and the deployed daemon",
                        [(SH, '[[ -n "$(zq_owner "$1" "${exe}")" ]] && echo', '[[ "$(zq_owner "$1" "${exe}")" == bin ]] && echo')]),
    "LNX-CRASH-STATE": ("bash", "counts crash dumps and filled crash-spool records",
                        [(SH, """find "${root}" -type f \\( -path '*/crashes/*' -o \\( -path '*/crash-spool/*' -size +0 \\) \\)""",
                          """find "${root}/crashes" -type f"""),
                         (SH, "-path '*/crash-spool/*' -size +0", "-path '*/crash-spool/*'")]),
    "LNX-POISON-STORE": ("bash", "poisons zccache's store in the v1.15.6 state folder",
                         [(SH, 'zq_corrupt "$2/${ZQ_STATE}/artifacts"', 'zq_corrupt "$2/artifacts"')]),
    "LNX-POISON-RESTART": ("bash", "poisons zccache's store in the v1.15.6 state folder",
                           [(SH, '  stop=$(zq_stop_daemons "${ZQ_WORK}") || return 1\n  n=$(zq_corrupt', '  n=$(zq_corrupt')]),
    "LNX-CONTROL-STOP": ("bash", "the control phase primes, stops the daemon and rebuilds without corruption",
                         [(SH, '  stop=$(zq_stop_daemons "${ZQ_WORK}") || return 1\n  p=$(zq_phase "$1" ok "$2" ok-control) || return 1',
                           '  p=$(zq_phase "$1" ok "$2" ok-control) || return 1')]),
    "LNX-STDIN": ("bash", "builds and zccache calls read /dev/null",
                  [(SH, 'env -i "${keep[@]}" "$@" < /dev/null', 'env -i "${keep[@]}" "$@"')]),
    "JQ-DAEMON-ROOT": ("bash", 'fails daemons_pinned for: .meta.daemons[0] |= (.in_private_bin = false | .in_cache_root = "true")',
                       [(JQ, "(.in_private_bin == true or .in_cache_root == true)", "(.in_private_bin == true or .in_cache_root)")]),
    "JQ-DAEMON-OWNED": ("bash", "fails daemons_pinned for: .meta.daemons[0] |= (.in_private_bin = false | .in_cache_root = false)",
                        [(JQ, "(.in_private_bin == true or .in_cache_root == true)", "true")]),
    "JQ-REJECTED-CONTROL": ("bash", "fails poisoned_artifact_rejected for: .runs.control.journal.hit = 0",
                            [(JQ, "def rejected($r; $u; $c):\n  control_ok($c; $u) and ($r.daemon_stopped == true)\n",
                              "def rejected($r; $u; $c):\n  true and ($r.daemon_stopped == true)\n")]),
    "JQ-REJECTED-STOP": ("bash", "fails poisoned_artifact_rejected for: .runs.poisoned_artifact.daemon_stopped = false",
                         [(JQ, "($r.daemon_stopped == true)\n", "true\n")]),
    "WIN-DAEMON-ROOT": ("pester", "*owns only the private copy and the daemon copy*",
                        [(PS, "{ return 'root' }", "{ return '' }"),
                         (PS, "'\\\\zccache-daemon\\.exe$'", "'\\\\zccache-daemon\\.exe'")]),
    "WIN-DAEMON-STOP": ("pester", "*lists, pins and stops the private copy and the daemon deployed*",
                        [(PS, "            Get-ZqOwner $Work $p\n", "            (Get-ZqOwner $Work $p) -eq 'bin'\n")]),
    "WIN-CRASH-STATE": ("pester", "*counts crash dumps and filled crash-spool records*",
                        [(PS, " -or ($rel -match '\\\\crash-spool\\\\' -and $_.Length -gt 0)", ""),
                         (PS, " -and $_.Length -gt 0)", ")")]),
    "WIN-POISON-STORE": ("pester", "*poisons zccache?s store*",
                         [(PS, "Invoke-ZqCorrupt (Join-Path (Join-Path $Root $ZqState) 'artifacts')", "Invoke-ZqCorrupt (Join-Path $Root 'artifacts')")]),
    "WIN-POISON-RESTART": ("pester", "*poisons zccache?s store*",
                           [(PS, "    $stopped = Stop-ZqDaemon $Work\n    $n = Invoke-ZqCorrupt", "    $n = Invoke-ZqCorrupt")]),
    "WIN-CONTROL-STOP": ("pester", "*primes the control root*",
                         [(PS, "    $stopped = Stop-ZqDaemon $Work\n    $p = Invoke-ZqPhase", "    $p = Invoke-ZqPhase")]),
    "WIN-STDIN": ("pester", "*gives every run an empty stdin*",
                  [(PS, "try { @() | & $Exe @Argv", "try { & $Exe @Argv")]),
}


def copy_tree(dest):
    for t in TREES:
        shutil.copytree(REPO / t, dest / t, ignore=shutil.ignore_patterns("__pycache__"))


def mutate(root, variant):
    f, old, new = variant
    p = root / f
    s = p.read_text(encoding="utf-8")
    if s.count(old) != 1:
        raise SystemExit(f"mutation text not found exactly once in {f}: {old!r}")
    p.write_text(s.replace(old, new), encoding="utf-8", newline="\n")


def wsl_path(p):
    p = str(p.resolve())
    return "/mnt/" + p[0].lower() + p[2:].replace("\\", "/")


def run_bash(root, test):
    """Status of one named test in harness_test.sh: ok, FAIL or missing."""
    if os.name == "nt":
        # The copy moves below the WSL home first: /mnt/c is not a POSIX file system for these tests.
        script = root / "run-bash.sh"
        script.write_text('d=$(mktemp -d "$HOME/p041-mut.XXXXXX") && cp -r "$1/." "$d/" && '
                          'bash "$d/tests/parity/cache/qualification/harness_test.sh"; rm -rf "$d"\n',
                          encoding="utf-8", newline="\n")
        cmd = ["wsl.exe", "-d", "Ubuntu-24.04", "--", "bash", wsl_path(script), wsl_path(root)]
    else:
        cmd = ["bash", str(root / "tests/parity/cache/qualification/harness_test.sh")]
    out = subprocess.run(cmd, capture_output=True, text=True, timeout=600, stdin=subprocess.DEVNULL).stdout
    for line in out.splitlines():
        if line.startswith("ok   ") and line[5:].startswith(test):
            return "ok"
        if line.startswith("FAIL ") and line[5:].startswith(test):
            return "FAIL"
    return "missing"


def run_pester(root, test, shell, pester):
    """Status of one named test in Harness.Tests.ps1: ok, FAIL or missing."""
    # The child shell runs a plain runner script with -File and arguments, never an encoded
    # command line (the owner rejected those; Malwarebytes quarantines them as obfuscated PowerShell).
    runner = root / "run-pester.ps1"
    runner.write_text(
        "param([Parameter(Mandatory)][string]$Pester, [Parameter(Mandatory)][string]$Path,\n"
        "  [Parameter(Mandatory)][string]$Filter)\n"
        "Import-Module $Pester -MinimumVersion 5.0\n"
        "$c = New-PesterConfiguration\n"
        "$c.Run.Path = $Path\n"
        "$c.Run.PassThru = $true\n"
        "$c.Output.Verbosity = 'None'\n"
        "$c.Filter.FullName = $Filter\n"
        "$r = Invoke-Pester -Configuration $c\n"
        "Write-Output \"RESULT $($r.PassedCount) $($r.FailedCount)\"\n",
        encoding="utf-8", newline="\n")
    out = subprocess.run(
        [shell, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", str(runner),
         str(pester), str(root / "tests/parity/cache/qualification"), test],
        capture_output=True, text=True, timeout=600, stdin=subprocess.DEVNULL).stdout
    res = [ln.split() for ln in out.splitlines() if ln.startswith("RESULT ")]
    if not res:
        return "missing"
    passed, failed = int(res[-1][1]), int(res[-1][2])
    return "FAIL" if failed else ("ok" if passed else "missing")


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--suite", choices=("pester", "bash"))
    ap.add_argument("--only", nargs="*")
    ap.add_argument("--shell", default="pwsh")
    ap.add_argument("--pester", default="Pester", help="Pester 5 module name or .psd1 path")
    ap.add_argument("--work", default=tempfile.gettempdir())
    a = ap.parse_args(argv)
    ids = [i for i in MUTATIONS if (not a.only or i in a.only) and (not a.suite or MUTATIONS[i][0] == a.suite)]
    run = {"bash": run_bash, "pester": lambda r, t: run_pester(r, t, a.shell, a.pester)}
    base = Path(a.work) / ("p041-mut-" + uuid.uuid4().hex)
    bad = 0
    try:
        for i in ids:
            suite, test, variants = MUTATIONS[i]
            clean = base / (i + "-base")
            copy_tree(clean)
            if run[suite](clean, test) != "ok":
                print(f"BASELINE-FAIL {i}: '{test}' does not pass unmutated")
                bad += 1
                continue
            for n, v in enumerate(variants):
                root = base / f"{i}-{n}"
                copy_tree(root)
                mutate(root, v)
                status = run[suite](root, test)
                verdict = {"FAIL": "KILLED", "ok": "SURVIVED"}.get(status, "NO-TEST")
                print(f"{verdict:8} {i}#{n} ({suite}: {test})")
                bad += verdict != "KILLED"
    finally:
        shutil.rmtree(base, ignore_errors=True)
    print(f"{sum(len(MUTATIONS[i][2]) for i in ids)} mutation(s), {bad} not killed")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
