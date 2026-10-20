<#
.SYNOPSIS
Runs Linux-cross-built Windows artifacts on this Windows machine and writes the execution records (P18 xwin hand-off).

.DESCRIPTION
For every <name>.handoff.json in -Dir (written by parity/workloads/xwin/run.sh on Linux), checks that the artifact
next to it has the recorded sha256, runs it (60 s limit), and writes <name>.executed.json: sha256, runner_os, OS
version, exit code, stdout, run id. `python handoff.py verdict <built> <executed>` then says executed-on-windows only
when the bytes, exit code and output match. This is the only way a cross build becomes Windows execution evidence;
P22/P24 call it on the Windows twin with the artifacts of a Linux run. Windows PowerShell 5.1 and pwsh 7.

.EXAMPLE
pwsh -NoProfile -File parity\workloads\xwin\Invoke-HandoffExecution.ps1 -Dir C:\t\xwin-artifacts
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Dir)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$found = @(Get-ChildItem -LiteralPath $Dir -Filter '*.handoff.json')
if (-not $found.Count) { throw "no *.handoff.json in $Dir" }
$bad = 0
foreach ($h in $found) {
    $b = Get-Content -Raw -LiteralPath $h.FullName | ConvertFrom-Json
    $exe = Join-Path $Dir $b.artifact
    $sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $exe).Hash.ToLowerInvariant()
    $rec = [ordered]@{
        schema = 1; kind = 'xwin-executed'; artifact = $b.artifact; sha256 = $sha
        runner_os = $(if ($env:OS -eq 'Windows_NT') { 'Windows' } else { "$env:OS" })
        os_version = [Environment]::OSVersion.VersionString; exit_code = $null; stdout = $null
        run_id = $env:GITHUB_RUN_ID
    }
    if ($sha -ne $b.sha256) {
        Write-Host "error: $($b.artifact) sha256 $sha differs from the built record $($b.sha256); not run"
        $bad++
    }
    else {
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $p = [Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEndAsync()
        if (-not $p.WaitForExit(60000)) { $p.Kill(); Write-Host "error: $($b.artifact) did not exit within 60 s"; $bad++ }
        else {
            $rec.exit_code = $p.ExitCode
            $rec.stdout = $out.Result
            Write-Host ("{0}: exit {1}, output {2}" -f $b.artifact, $p.ExitCode, $out.Result.Trim())
        }
    }
    $path = Join-Path $Dir ($h.Name -replace '\.handoff\.json$', '.executed.json')
    [IO.File]::WriteAllText($path, ($rec | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
}
exit $(if ($bad) { 1 } else { 0 })
