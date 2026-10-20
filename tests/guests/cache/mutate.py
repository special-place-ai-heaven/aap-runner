"""Mutation proof for the P13 safety checks. Standard library only.

    python -B -I tests/guests/cache/mutate.py [--suite pester|bash|python] [--only ID ...] [--work DIR]

Every safety check in guests/cache carries a `SAFETY:<ID>` tag. For each ID this copies guests/cache to a scratch
folder, disables that one check with the literal replacement below, and runs only the tests tagged ID against the copy
(AAP_ZC_SRC): Pester tags (WIN-*, TRUST-*), AAP_ZC_TAGS in zccache_test.sh (LNX-*), the generator tests (GEN-*).
A mutation must make that run fail (KILLED). A run that still passes (SURVIVED) or runs no test (NO-TEST) means the
check is not proven. Before the mutations, each selected suite runs once on an unmutated copy and must pass.
Every tag in the sources needs an entry here and every entry a tag, so a new check cannot go unproven silently.
Exit 0 only when every selected mutation is KILLED.

Bash runs through Git Bash on Windows (never System32\\bash.exe, which is WSL); cases that need symbolic links are
skipped there, so LNX-DIR-LINK and LNX-BIND-LINK are proven only on real Linux.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
SRC = REPO / "guests" / "cache"
W = "windows/AapZcCache.psm1"
L = "linux/aap-zccache.sh"
T = "host/AapCacheTrust.psm1"
G = "gen_wrappers.py"

# ID: (file, old, new). `old` must occur exactly once in the file.
MUTATIONS = {
    "WIN-DIR-LINK": (W, "if (Test-AapZcLink $Path) { throw", "if ($false) { throw"),
    "WIN-ENV-ZCCACHE": (W, "if ($n -like 'ZCCACHE_*') { continue }", "if ($false) { continue }"),
    "WIN-ENV-SECRET": (W, "if ($n -match $script:SecretName -or [string]$all[$k] -match $script:UrlCredential) { continue }", "if ($false) { continue }"),
    "WIN-COPY-MODE": (W, "$envOut['ZCCACHE_MODE'] = 'COPY'", "$envOut['ZCCACHE_MODE'] = 'AUTO'"),
    "WIN-BUDGET-SET": (W, "$envOut['ZCCACHE_CACHE_SIZE_BYTES'] =", "$envOut['ZCCACHE_UNUSED'] ="),
    "WIN-PROVENANCE": (W, "if (-not $provOk) {", "if ($false) {"),
    "WIN-ARCHIVE-HASH": (W, "if ($bytes.Length -ne [long]$plat.archive_bytes -or (Get-AapZcBytesHash $bytes) -ne $plat.archive_sha256) {", "if ($false) {"),
    "WIN-ZIP-MEMBER": (W, r"if ($n -match '(^|[\\/])\.\.([\\/]|$)' -or $n -match '^[\\/]' -or $n.Contains(':') -or $isLink) {", "if ($false) {"),
    "WIN-MEMBER-HASH": (W, "if ($b.Length -ne [long]$m.bytes -or (Get-AapZcBytesHash $b) -ne $m.sha256) {", "if ($false) {"),
    "WIN-BOOT-BINARY": (W, "{ $binOk = $false }", "{ }"),
    "WIN-BOOT-TOOLCHAIN": (W, "if ([IO.File]::Exists($t.path) -and (Get-AapZcFileHash $t.path) -eq $t.sha256) { $t }", "if ([IO.File]::Exists($t.path)) { $t }"),
    "WIN-DAEMON-ALIVE": (W, "return ($null -ne $p -and $p.StartTime.ToUniversalTime().Ticks -eq [long](Get-AapZcProp $Daemon 'start'))", "return ($null -ne $p)"),
    "WIN-BIND-ONCE": (W, "{ $reason = 'already-bound' }", "{ $reason = $null }"),
    "WIN-BIND-MISSING": (W, "{ $reason = 'binding-missing' }", "{ $reason = $null }"),
    "WIN-BIND-CLASS": (W, "{ $reason = 'trust-class-unknown' }", "{ $reason = $null }"),
    "WIN-BIND-RUNNER": (W, "{ $reason = 'runner-mismatch' }", "{ $reason = $null }"),
    "WIN-BIND-TOOLCHAIN": (W, "{ $reason = 'toolchain-mismatch' }", "{ $reason = $null }"),
    "WIN-BIND-LINK": (W, "{ $reason = 'root-is-link' }", "{ $reason = $null }"),
    "WIN-BIND-MARKER": (W, "if (-not $same) { $reason = 'marker-mismatch' }", "if ($false) { $reason = 'marker-mismatch' }"),
    "WIN-LOG-BOUND": (W, "if ($fi.Exists -and $fi.Length -gt $script:LogLimit) {", "if ($false) {"),
    "WIN-OVER-BUDGET": (W, "return ($all -gt [long]$Root.budget_bytes -or ($all - $art) -gt ([long]$Root.budget_bytes - [long]$Root.artifact_budget_bytes))", "return $false"),
    "WIN-SHIM-TOOLCHAIN": (W, "if (-not $fi.Exists -or $fi.Length -ne [long]$tc.bytes -or $fi.LastWriteTimeUtc.Ticks -ne [long]$tc.mtime) {", "if (-not $fi.Exists) {"),
    "WIN-SHIM-QUALIFIED": (W, "if (-not $q.Count) { $d.Reason = 'not-qualified:'", "if ($false) { $d.Reason = 'not-qualified:'"),
    "WIN-SHIM-FLAG": (W, "if ([IO.File]::Exists((Get-AapZcFlagPath $cfg $d.RootId))) {", "if ($false) {"),
    "WIN-SHIM-DAEMON": (W, "if (-not (Test-AapZcDaemonAlive $d.Root.daemon)) {", "if ($false) {"),
    "WIN-SHIM-FALLBACK": (W, "$code = (Invoke-AapZcProcess -FilePath $exe -Arguments $rest).ExitCode  # SAFETY:WIN-SHIM-FALLBACK", "$code = $(if ($r) { $r.ExitCode } else { 1 })"),
    "TRUST-EVENT": (T, "if (@('push', 'schedule', 'workflow_dispatch') -cnotcontains $ev) {", "if ($false) {"),
    "TRUST-BRANCH": (T, "if ($branch -cne $DefaultBranch) {", "if ($false) {"),
    "TRUST-HEAD-REPO": (T, "if ($headId -ne $repoId) {", "if ($false) {"),
    "TRUST-TAG-UNKNOWN": (T, "if ($null -eq $TagNamedLikeBranch) {", "if ($false) {"),
    "LNX-DIR-LINK": (L, '[[ -L "$1" ]] && zc_die', 'false && zc_die'),
    "LNX-PROVENANCE": (L, '|| zc_die "the archive was not accepted and verified by a strict P03 run for this pin"', "|| true"),
    "LNX-ARCHIVE-HASH": (L, 'zc_die "the archive is not the pinned release archive"', "true"),
    "LNX-TAR-MEMBER": (L, "&& zc_die \"refused member '${line}' (absolute or parent segment)\"", "&& true"),
    "LNX-TAR-TYPE": (L, '|| zc_die "refused a link or special member: ${line:0:1}"', "|| true"),
    "LNX-MEMBER-HASH": (L, '|| zc_die "${path} is not the pinned member"', "|| true"),
    "LNX-ENV-ZCCACHE": (L, 'if [[ "${n}" == ZCCACHE_* ]]; then', "if false; then"),
    "LNX-ENV-SECRET": (L, 'if grep -Eiq -- "${ZC_SECRET_NAME_RE}" <<< "${n}" || [[ "${!n-}" =~ ${ZC_URL_CREDENTIAL_RE} ]]; then', "if false; then"),
    "LNX-COPY-MODE": (L, "ZCCACHE_MODE=COPY ZCCACHE_CACHE_SIZE_BYTES", "ZCCACHE_MODE=AUTO ZCCACHE_CACHE_SIZE_BYTES"),
    "LNX-BUDGET-SET": (L, 'ZCCACHE_CACHE_SIZE_BYTES="${budget}" "$@"', 'ZCCACHE_UNUSED="${budget}" "$@"'),
    "LNX-DAEMON-ALIVE": (L, '[[ -n "$1" && -n "$2" && "$(zc_proc_start "$1")" == "$2" ]]', '[[ -n "$1" && -r "${ZC_PROC}/$1/stat" ]]'),
    "LNX-BOOT-BINARY": (L, "]] || ok=0  # SAFETY:LNX-BOOT-BINARY", "]] || true"),
    "LNX-BOOT-TOOLCHAIN": (L, '[[ -f "$(jq -r .real <<< "${t}")" && "$(zc_sha "$(jq -r .real <<< "${t}")")" == "$(jq -r .sha256 <<< "${t}")" ]]', '[[ -f "$(jq -r .real <<< "${t}")" ]]'),
    "LNX-BIND-ONCE": (L, "elif jq -e '.roots.shared'", "elif false && jq -e '.roots.shared'"),
    "LNX-BIND-MISSING": (L, "then reason=binding-missing", 'then reason=""'),
    "LNX-BIND-CLASS": (L, "elif ! jq -e '.namespace.trust_class ==", "elif false && ! jq -e '.namespace.trust_class =="),
    "LNX-BIND-RUNNER": (L, "elif ! jq -e --arg r \"${runner}\"", "elif false && ! jq -e --arg r \"${runner}\""),
    "LNX-BIND-TOOLCHAIN": (L, "elif ! jq -e --arg p \"${ZC_PLATFORM}\" --arg d", "elif false && ! jq -e --arg p \"${ZC_PLATFORM}\" --arg d"),
    "LNX-BIND-LINK": (L, 'elif [[ -L "${mount}" || -L "${mount}/root" ]]', "elif false"),
    "LNX-BIND-MARKER": (L, "elif ! jq -e --argjson b \"${b}\" '. as $m", "elif false && ! jq -e --argjson b \"${b}\" '. as $m"),
    "LNX-LOG-BOUND": (L, '-gt ${ZC_LOG_LIMIT} ]] && mv', "-gt 999999999999 ]] && mv"),
    "LNX-OVER-BUDGET": (L, "[[ ${all} -gt $4 || $((all - art)) -gt $(($4 - $5)) ]]", "false"),
    "LNX-SHIM-TOOLCHAIN": (L, 'elif [[ "$(readlink -f -- "${path}")" != "${real}" ||', 'elif false && [[ "$(readlink -f -- "${path}")" != "${real}" ||'),
    "LNX-SHIM-QUALIFIED": (L, '[[ " ${quals} " == *" ${c} "* ]] || {', "true || {"),
    "LNX-SHIM-FLAG": (L, 'if [[ -f "${job}/shim/degraded-${root}" ]]; then', "if false; then"),
    "LNX-SHIM-DAEMON": (L, 'elif ! zc_daemon_alive "${pid}" "${start}"; then', "elif false; then"),
    "LNX-SHIM-FALLBACK": (L, '"${path}" "$@"  # SAFETY:LNX-SHIM-FALLBACK', "false"),
    "GEN-VALIDATE": (G, "if r.returncode != 0:", "if False:"),
    "GEN-BINARY-PIN": (G, 'if z["binary_sha256"] != pins["members"][0]["sha256"]:', "if False:"),
    "GEN-ACQUIRE": (G, "if (acq is None or", "if False and (acq is None or"),
    "GEN-EVIDENCE": (G, "if not ref or not (Path(repo) / ref).is_file():", "if not ref:"),
}
SUITE = {"WIN": "pester", "TRUST": "pester", "LNX": "bash", "GEN": "python"}


def suite_of(tag):
    return SUITE[tag.split("-")[0]]


def source_tags():
    tags = set()
    for p in SRC.rglob("*"):
        if p.is_file() and p.suffix in (".ps1", ".psm1", ".sh", ".py"):
            tags.update(re.findall(r"SAFETY:([A-Z]+(?:-[A-Z]+)+)", p.read_text(encoding="utf-8")))
    return tags


def git_bash():
    if os.name != "nt":
        return shutil.which("bash")
    for c in (r"C:\Program Files\Git\usr\bin\bash.exe", r"C:\Program Files\Git\bin\bash.exe"):
        if Path(c).is_file():
            return c
    return None


def pwsh():
    return shutil.which("pwsh")


def run_suite(suite, copy, tag):
    """-> (ran, failed) or None when the suite's runner is missing."""
    env = dict(os.environ, AAP_ZC_SRC=str(copy))
    if suite == "pester":
        shell = pwsh()
        if not shell:
            return None
        flt = f"$c.Filter.Tag = '{tag}'; " if tag else ""
        cmd = ("$c = New-PesterConfiguration; $c.Run.Path = '" + str(HERE / "AapZcCache.Tests.ps1") + "'; " + flt +
               "$c.Output.Verbosity = 'None'; $c.Run.PassThru = $true; $r = Invoke-Pester -Configuration $c; "
               "'RESULT {0} {1}' -f ($r.PassedCount + $r.FailedCount), $r.FailedCount")
        r = subprocess.run([shell, "-NoProfile", "-NonInteractive", "-Command", cmd], env=env, capture_output=True, text=True)
        m = re.search(r"RESULT (\d+) (\d+)", r.stdout)
        return (int(m.group(1)), int(m.group(2))) if m else (0, 1)
    if suite == "bash":
        bash = git_bash()
        if not bash:
            return None
        if tag:
            env["AAP_ZC_TAGS"] = tag
        if os.name == "nt":  # find, sort and tar must be Git's, not System32's
            env["PATH"] = str(Path(bash).parent) + os.pathsep + env.get("PATH", "")
        r = subprocess.run([bash, str(HERE / "zccache_test.sh")], env=env, capture_output=True, text=True)
        m = re.search(r"passed (\d+), failed (\d+)", r.stdout)
        return (int(m.group(1)) + int(m.group(2)), int(m.group(2))) if m else (0, 1)
    r = subprocess.run([sys.executable, "-B", "-I", "-m", "unittest", "discover", "-s", str(HERE), "-p", "test_gen_wrappers.py"],
                       env=env, capture_output=True, text=True)
    m = re.search(r"Ran (\d+) test", r.stderr)
    return (int(m.group(1)) if m else 0, 0 if r.returncode == 0 else 1)


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--suite", choices=("pester", "bash", "python"))
    ap.add_argument("--only", nargs="*")
    ap.add_argument("--work")
    a = ap.parse_args(argv[1:])
    tags = source_tags()
    if tags != set(MUTATIONS):
        print(f"tags without a mutation: {sorted(tags - set(MUTATIONS))}; mutations without a tag: {sorted(set(MUTATIONS) - tags)}")
        return 1
    chosen = [t for t in sorted(MUTATIONS) if (not a.suite or suite_of(t) == a.suite) and (not a.only or t in a.only)]
    work = Path(a.work or tempfile.mkdtemp(prefix="p13-mut-"))
    work.mkdir(parents=True, exist_ok=True)
    base = work / "baseline"
    shutil.rmtree(base, ignore_errors=True)
    shutil.copytree(SRC, base)
    unavailable = set()
    for suite in sorted({suite_of(t) for t in chosen}):
        res = run_suite(suite, base, None)
        if res is None:
            unavailable.add(suite)
            print(f"baseline {suite}: runner not available here")
        elif res[1] or not res[0]:
            print(f"baseline {suite}: FAILED ({res[0]} ran, {res[1]} failed); fix the suite before proving mutations")
            return 1
        else:
            print(f"baseline {suite}: {res[0]} passed", flush=True)
    bad = 0
    for tag in chosen:
        f, old, new = MUTATIONS[tag]
        copy = work / tag
        shutil.rmtree(copy, ignore_errors=True)
        shutil.copytree(SRC, copy)
        path = copy / f
        text = path.read_text(encoding="utf-8")
        if text.count(old) != 1:
            print(f"{tag:22} BAD-MUTATION (pattern found {text.count(old)} times in {f})")
            bad += 1
            continue
        path.write_text(text.replace(old, new), encoding="utf-8", newline="\n")
        suite = suite_of(tag)
        if suite in unavailable:
            print(f"{tag:22} NOT-RUN ({suite} runner not available)")
            bad += 1
            continue
        ran, failed = run_suite(suite, copy, tag)
        verdict = "KILLED" if failed else ("NO-TEST" if not ran else "SURVIVED")
        bad += verdict != "KILLED"
        print(f"{tag:22} {verdict} ({ran} ran, {failed} failed)", flush=True)
        shutil.rmtree(copy, ignore_errors=True)
    shutil.rmtree(base, ignore_errors=True)
    print(f"{len(chosen) - bad} of {len(chosen)} mutations killed")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
