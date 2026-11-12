# Starts the interim Windows runner with no visible window. Run by the task AAP-Win-Interim-Runner;
# the installed copy is C:\aap-win-interim\start-runner.ps1. Until the runner is configured
# (runner\.runner exists) this exits immediately.
#
# One listener only. A listener left by an earlier task instance keeps the runner's GitHub session,
# and a second one is refused ("A session for this runner already exists") until the first is gone.
# So before starting: look for this folder's Runner.Listener; if it has a job (Runner.Worker), leave
# it and exit; otherwise stop it and its run.cmd hosts, wait, kill what is left, and start only when
# none remain.
#
# Dot-source safe: with -NoRun only the functions are defined (tests).
param(
    [string]$Dir = 'C:\aap-win-interim\runner',
    [int]$StopWaitSeconds = 15,
    [switch]$NoRun
)

function Get-AapInterimProcesses([string]$Dir) {
    $bin = (Join-Path $Dir 'bin') + '\'
    $all = @(Get-CimInstance Win32_Process)
    $own = { param($p, $name) $p.Name -eq $name -and $p.ExecutablePath -and $p.ExecutablePath.StartsWith($bin, [StringComparison]::OrdinalIgnoreCase) }
    $listeners = @($all | Where-Object { & $own $_ 'Runner.Listener.exe' })
    $workers = @($all | Where-Object { & $own $_ 'Runner.Worker.exe' })
    # The cmd.exe hosts (run.cmd, run-helper.cmd) above a listener would start it again.
    $hosts = @()
    foreach ($l in $listeners) {
        $parent = $l.ParentProcessId
        for ($i = 0; $i -lt 4 -and $parent; $i++) {
            $p = $all | Where-Object { $_.ProcessId -eq $parent } | Select-Object -First 1
            if (-not $p -or $p.Name -ne 'cmd.exe' -or $p.CommandLine -notmatch 'run(-helper)?\.cmd') { break }
            $hosts += $p
            $parent = $p.ParentProcessId
        }
    }
    [pscustomobject]@{ Listeners = $listeners; Workers = $workers; Hosts = $hosts }
}

# 'none' (nothing was running), 'busy' (a job is running; nothing was touched),
# 'stopped' (old listener gone) or 'stuck' (still alive after the kill).
function Stop-AapInterimStale([string]$Dir, [int]$WaitSeconds) {
    $now = Get-AapInterimProcesses $Dir
    if ($now.Listeners.Count -eq 0) { return 'none' }
    if ($now.Workers.Count -gt 0) { return 'busy' }
    foreach ($p in @($now.Hosts) + @($now.Listeners)) {
        Stop-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
    }
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while ((Get-Date) -lt $deadline -and (Get-AapInterimProcesses $Dir).Listeners.Count -gt 0) {
        Start-Sleep -Milliseconds 500
    }
    foreach ($p in (Get-AapInterimProcesses $Dir).Listeners) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 1
    if ((Get-AapInterimProcesses $Dir).Listeners.Count -gt 0) { return 'stuck' }
    return 'stopped'
}

if ($NoRun) { return }

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath (Join-Path $Dir '.runner'))) { exit 0 }
# Git Bash first on PATH, as on GitHub's hosted Windows runners, so `shell: bash` never resolves to
# C:\Windows\System32\bash.exe (the WSL launcher). Jobs inherit this process's PATH.
$gitBash = 'C:\Program Files\Git\bin'
if (Test-Path -LiteralPath (Join-Path $gitBash 'bash.exe')) { $env:Path = "$gitBash;$env:Path" }

switch (Stop-AapInterimStale $Dir $StopWaitSeconds) {
    'busy' { exit 0 }
    'stuck' { Write-Error 'refusing: an earlier Runner.Listener is still running' -ErrorAction Continue; exit 1 }
}
$p = Start-Process -FilePath $env:ComSpec -ArgumentList '/c', 'run.cmd' -WorkingDirectory $Dir -WindowStyle Hidden -PassThru
try { $p.PriorityClass = 'BelowNormal' } catch { }
$p.WaitForExit()
exit $p.ExitCode
