<#
.SYNOPSIS
Runs the P17 Windows and Actions parity workloads through tools/parity-certify and writes one JSON result per workload.

.DESCRIPTION
Definitions: parity/workloads/windows/defs and parity/workloads/actions/windows/defs (P05 workload format).
The selected definitions are copied to <OutDir>\defs and run by `certify.py run-workloads`, which writes
<OutDir>\results.json and <OutDir>\logs (the reference results a later `certify.py certify --reference-results` reads).
This script then writes <OutDir>\workloads\<id>.json (definition oracle, observed facts, exit code, artifacts with
hashes, duration, image identity) and <OutDir>\summary.json. Exit code: 0 only when every selected workload passed.
-Name takes ids, prefixes (windows/msvc selects every msvc workload and its negative controls) or wildcards, as
several values or one comma-separated string. OutDir defaults to $env:PARITY_OUT, then $env:RUNNER_TEMP\parity-out.
Build trees under <OutDir>\work are pruned to their report.txt after the run unless -KeepWork.
Runs under pwsh or Windows PowerShell 5.1; the workloads themselves always run in powershell.exe (5.1).

.EXAMPLE
pwsh -NoProfile -File parity\workloads\windows\Invoke-Workloads.ps1 -Name windows/msvc,windows/rust-plain -OutDir C:\t\out
#>
[CmdletBinding()]
param(
    [string[]]$Name = @(),
    [string]$OutDir = '',
    [Alias('Profile')][string]$ProfileName = 'windows-2025-vs2026',
    [switch]$List,
    [switch]$KeepWork
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

function Write-Json($Obj, [string]$Path) {
    [IO.File]::WriteAllText($Path, ($Obj | ConvertTo-Json -Depth 12).Replace("`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))
}

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).ProviderPath
$certify = Join-Path $repo 'tools\parity-certify\certify.py'
if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot "oracle\$ProfileName.json"))) { throw "no oracle for profile $ProfileName" }
$all = foreach ($dir in (Join-Path $PSScriptRoot 'defs'), (Join-Path $repo 'parity\workloads\actions\windows\defs')) {
    foreach ($f in (Get-ChildItem -LiteralPath $dir -Filter '*.json' | Sort-Object Name)) {
        $d = Get-Content -Raw -LiteralPath $f.FullName | ConvertFrom-Json
        [pscustomobject]@{ Id = $d.id; File = $f.FullName; Def = $d }
    }
}
if ($List) { $all | ForEach-Object { $_.Id }; exit 0 }

$sel = @($all)
if ($Name.Count) {
    # the coordinator may pass one comma-separated string
    $pats = @($Name | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    # an id or prefix, or a wildcard pattern (the hosted dispatch input allows no wildcard characters)
    $match = { param($id, $p) if ([Management.Automation.WildcardPattern]::ContainsWildcardCharacters($p)) { $id -like $p } else { $id.StartsWith($p) } }
    foreach ($p in $pats) { if (-not ($all | Where-Object { & $match $_.Id $p })) { throw "no workload matches '$p' (use -List)" } }
    $sel = @($all | Where-Object { $id = $_.Id; [bool]($pats | Where-Object { & $match $id $_ }) })
}

if (-not $OutDir) {
    $OutDir = if ($env:PARITY_OUT) { $env:PARITY_OUT } elseif ($env:RUNNER_TEMP) { Join-Path $env:RUNNER_TEMP 'parity-out' } else { Join-Path $env:TEMP 'parity-out' }
}
if ((Test-Path -LiteralPath $OutDir) -and (Get-ChildItem -LiteralPath $OutDir -Force | Select-Object -First 1)) {
    throw "output folder $OutDir is not empty; give a new or empty -OutDir"
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDir = (Resolve-Path -LiteralPath $OutDir).ProviderPath
foreach ($d in 'defs', 'work', 'observed', 'workloads') { New-Item -ItemType Directory -Force -Path (Join-Path $OutDir $d) | Out-Null }
foreach ($w in $sel) { Copy-Item -LiteralPath $w.File -Destination (Join-Path $OutDir ('defs\' + ($w.Id -replace '/', '__') + '.json')) }

$py = Get-Command python.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $py) { throw 'python.exe is required on PATH to run tools/parity-certify' }
$env:PARITY_PROFILE = $ProfileName
$env:PARITY_OBS_DIR = Join-Path $OutDir 'observed'
$results = Join-Path $OutDir 'results.json'
Write-Host ("running {0} workload(s) into {1}" -f $sel.Count, $OutDir)
& $py.Source -B -I $certify run-workloads --defs (Join-Path $OutDir 'defs') --out $results --work (Join-Path $OutDir 'work')
$code = $LASTEXITCODE
if (-not (Test-Path -LiteralPath $results)) { Write-Host "certify.py run-workloads wrote no results (exit $code)"; exit 2 }

$image = [ordered]@{
    ImageOS = $env:ImageOS; ImageVersion = $env:ImageVersion; RUNNER_ENVIRONMENT = $env:RUNNER_ENVIRONMENT
    os = (Get-CimInstance Win32_OperatingSystem | ForEach-Object { "$($_.Caption) $($_.Version) build $($_.BuildNumber)" })
    imagedata = $(if (Test-Path -LiteralPath 'C:\imagedata.json') { Get-Content -Raw -LiteralPath 'C:\imagedata.json' | ConvertFrom-Json } else { $null })
}
$source = [ordered]@{ repo_head = $null; GITHUB_SHA = $env:GITHUB_SHA; GITHUB_RUN_ID = $env:GITHUB_RUN_ID; GITHUB_RUN_ATTEMPT = $env:GITHUB_RUN_ATTEMPT }
$git = Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($git) { try { $source.repo_head = (& $git.Source -C $repo rev-parse HEAD 2>$null) } catch { } }  # not a git checkout: no head

$rows = @()
foreach ($r in (Get-Content -Raw -LiteralPath $results | ConvertFrom-Json).results) {
    $w = $sel | Where-Object { $_.Id -eq $r.id } | Select-Object -First 1
    $obsFile = Join-Path $OutDir ('observed\' + ($r.id -replace '/', '__') + '.observed.json')
    $obs = if (Test-Path -LiteralPath $obsFile) { Get-Content -Raw -LiteralPath $obsFile | ConvertFrom-Json } else { $null }
    $oracle = [ordered]@{ expected_exit_codes = $w.Def.expected_exit_codes; profile_oracle = "parity/workloads/windows/oracle/$ProfileName.json" }
    foreach ($k in 'expected_first_error', 'artifact_globs', 'expected_hashes') { if ($w.Def.PSObject.Properties[$k]) { $oracle[$k] = $w.Def.$k } }
    $doc = [ordered]@{
        schema = 1; kind = 'p17-workload-result'; id = $r.id; status = $r.status; reasons = $r.reasons
        oracle = $oracle; observed = $obs; exit_code = $r.exit_code; first_error = $r.first_error
        artifacts = $r.artifacts; log = ('logs/' + ($r.id -replace '/', '__') + '.log'); log_sha256 = $r.log_sha256
        def_sha256 = $r.def_sha256; started_at = $r.started_at; ended_at = $r.ended_at; duration_s = $r.duration_s
        image = $image; source = $source
    }
    Write-Json $doc (Join-Path $OutDir ('workloads\' + ($r.id -replace '/', '__') + '.json'))
    # keep the hashed artifacts (report.txt) next to the record; the build tree itself is not evidence
    if ($r.command -match ' -Work (.+?) -Id ' -and @($r.artifacts).Count) {
        $dst = Join-Path $OutDir ('artifacts\' + ($r.id -replace '/', '__'))
        New-Item -ItemType Directory -Force -Path $dst | Out-Null
        foreach ($a in $r.artifacts) { Copy-Item -LiteralPath (Join-Path $Matches[1] $a.name) -Destination $dst }
    }
    $rows +=[pscustomobject]@{ id = $r.id; status = $r.status; exit_code = $r.exit_code; duration_s = $r.duration_s }
}
if (-not $KeepWork) { Remove-Item -LiteralPath (Join-Path $OutDir 'work') -Recurse -Force }  # created by this run in an empty OutDir
$pass = @($rows | Where-Object { $_.status -eq 'pass' }).Count
Write-Json ([ordered]@{ schema = 1; kind = 'p17-workload-summary'; profile = $ProfileName; image = $image; source = $source; pass = $pass; total = $rows.Count; workloads = $rows }) (Join-Path $OutDir 'summary.json')
$rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
Write-Host ("{0}/{1} workloads pass; results in {2}" -f $pass, $rows.Count, $OutDir)
if ($code -ne 0 -or $pass -ne $rows.Count -or $rows.Count -ne $sel.Count) { exit 1 }
exit 0
