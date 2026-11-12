# Starts the interim Windows runner with no visible window. Run by the task AAP-Win-Interim-Runner;
# the installed copy is C:\aap-win-interim\start-runner.ps1. Until the runner is configured
# (runner\.runner exists) this exits 0 at once.
#
# One listener only. A listener left by an earlier task instance keeps the runner's GitHub session,
# and a second one is refused ("A session for this runner already exists") until the first is gone.
# So, under a machine-wide lock, before starting:
#   1. list this folder's Runner.Listener, Runner.Worker and the cmd.exe hosts (run.cmd,
#      run-helper.cmd) that would start the listener again;
#   2. a job in progress (Runner.Worker) is never touched: log and exit 0;
#   3. a runner process whose path cannot be read (another account, elevated) is not ours to judge:
#      log and exit 1, start nothing;
#   4. otherwise ask the listener to stop (Ctrl+C, so it closes its GitHub session), wait, kill the
#      hosts and what is left, wait again, and start only when no listener and no host remains.
# Exit codes: the runner's own on a normal run; 0 nothing to do (not configured, job in progress,
# another instance of this script holds the lock); 1 refused (unreadable or surviving process).
# One line per decision is appended to start-runner.log beside this script.
#
# Dot-source safe: with -NoRun only the functions are defined (tests).
param(
    [string]$Dir = 'C:\aap-win-interim\runner',
    [int]$StopWaitSeconds = 15,
    [switch]$NoRun
)

function Write-AapInterimLog([string]$Line) {
    try {
        Add-Content -LiteralPath $script:AapInterimLog -Encoding utf8 -Value "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK') $Line"
    } catch { }
}

# Listeners, workers and hosts of the runner in $Dir, plus Unknown: runner processes whose path this
# account cannot read. Never guesses: a process with no readable path is in Unknown, not ignored.
function Get-AapInterimProcesses([string]$Dir) {
    $root = [IO.Path]::GetFullPath($Dir).TrimEnd('\')
    $bin = "$root\bin\"
    $helper = "$root\run-helper.cmd"
    $all = @(Get-CimInstance Win32_Process)
    $runner = @($all | Where-Object { $_.Name -eq 'Runner.Listener.exe' -or $_.Name -eq 'Runner.Worker.exe' })
    $unknown = @($runner | Where-Object { -not $_.ExecutablePath })
    $mine = @($runner | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($bin, [StringComparison]::OrdinalIgnoreCase) })
    $listeners = @($mine | Where-Object { $_.Name -eq 'Runner.Listener.exe' })
    $ids = @($listeners | ForEach-Object { $_.ProcessId })
    $workers = @($mine | Where-Object { $_.Name -eq 'Runner.Worker.exe' })
    # A worker is also any Runner.Worker started by one of our listeners, whatever its path says.
    $workers += @($runner | Where-Object { $_.Name -eq 'Runner.Worker.exe' -and $ids -contains $_.ParentProcessId -and $workers -notcontains $_ })
    # Hosts: every cmd.exe running this folder's run-helper.cmd (with or without a listener under
    # it), and the run.cmd shell directly above one of those or above a listener.
    $cmds = @($all | Where-Object { $_.Name -eq 'cmd.exe' -and $_.CommandLine })
    $hosts = @($cmds | Where-Object { $_.CommandLine.IndexOf($helper, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
    $above = @($hosts | ForEach-Object { $_.ParentProcessId }) + @($listeners | ForEach-Object { $_.ParentProcessId })
    $hosts += @($cmds | Where-Object { $above -contains $_.ProcessId -and $hosts -notcontains $_ -and $_.CommandLine -match '(^|[\s"\\/])run(-helper)?\.cmd(\s|"|$)' })
    [pscustomobject]@{ Listeners = $listeners; Workers = $workers; Hosts = $hosts; Unknown = $unknown }
}

# Ctrl+C to the console the listener runs in, which is how run.cmd is stopped by hand: the listener
# then deletes its GitHub session and exits. Works only for a console in this logon session; a
# failure is reported as $false and the caller falls back to killing.
function Send-AapInterimCtrlC([int]$ProcessId) {
    try {
        if (-not ('AapInterim.Console' -as [type])) {
            Add-Type -Namespace AapInterim -Name Console -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool AttachConsole(uint pid);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool FreeConsole();
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetConsoleCtrlHandler(IntPtr handler, bool add);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool GenerateConsoleCtrlEvent(uint ev, uint group);
'@
        }
        [void][AapInterim.Console]::FreeConsole()
        if (-not [AapInterim.Console]::AttachConsole([uint32]$ProcessId)) { return $false }
        [void][AapInterim.Console]::SetConsoleCtrlHandler([IntPtr]::Zero, $true)
        $sent = [AapInterim.Console]::GenerateConsoleCtrlEvent(0, 0)
        Start-Sleep -Milliseconds 300
        [void][AapInterim.Console]::FreeConsole()
        [void][AapInterim.Console]::SetConsoleCtrlHandler([IntPtr]::Zero, $false)
        return [bool]$sent
    } catch { return $false }
}

function Wait-AapInterimGone([string]$Dir, [int]$Seconds) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        $now = Get-AapInterimProcesses $Dir
        if ($now.Listeners.Count -eq 0 -and $now.Hosts.Count -eq 0) { return $true }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    return $false
}

# 'none' (nothing was running), 'busy' (a job is running; nothing was touched), 'unknown' (a runner
# process this account cannot read; nothing was touched), 'stopped' (old listener and hosts gone)
# or 'stuck' (something survived the kill).
function Stop-AapInterimStale([string]$Dir, [int]$WaitSeconds) {
    $now = Get-AapInterimProcesses $Dir
    if ($now.Unknown.Count -gt 0) { return 'unknown' }
    if ($now.Workers.Count -gt 0) { return 'busy' }
    if ($now.Listeners.Count -eq 0 -and $now.Hosts.Count -eq 0) { return 'none' }
    foreach ($l in $now.Listeners) {
        Write-AapInterimLog "asking listener $($l.ProcessId) to stop: ctrl-c sent=$(Send-AapInterimCtrlC $l.ProcessId)"
    }
    if (Wait-AapInterimGone $Dir $WaitSeconds) { return 'stopped' }
    # Not gone. A job may have started while we waited: look again before every kill.
    $now = Get-AapInterimProcesses $Dir
    if ($now.Unknown.Count -gt 0) { return 'unknown' }
    if ($now.Workers.Count -gt 0) { return 'busy' }
    foreach ($p in @($now.Hosts) + @($now.Listeners)) {
        if ($p.Name -eq 'Runner.Listener.exe' -and (Get-AapInterimProcesses $Dir).Workers.Count -gt 0) { return 'busy' }
        try {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
            Write-AapInterimLog "killed $($p.Name) $($p.ProcessId)"
        } catch {
            Write-AapInterimLog "could not kill $($p.Name) $($p.ProcessId): $($_.Exception.Message)"
        }
    }
    # run-helper.cmd may start the listener again a few seconds after it exits; wait past that.
    if (Wait-AapInterimGone $Dir ([math]::Max($WaitSeconds, 10))) { return 'stopped' }
    return 'stuck'
}

function Add-AapInterimGitBash([string]$GitBin = 'C:\Program Files\Git\bin') {
    # Git Bash first on PATH, as on GitHub's hosted Windows runners, so `shell: bash` never resolves
    # to C:\Windows\System32\bash.exe (the WSL launcher). Jobs inherit this process's PATH.
    if (-not (Test-Path -LiteralPath (Join-Path $GitBin 'bash.exe'))) { return $false }
    if (-not $env:Path.StartsWith("$GitBin;", [StringComparison]::OrdinalIgnoreCase)) { $env:Path = "$GitBin;$env:Path" }
    return $true
}

# run.cmd hidden, below normal priority; returns its exit code.
function Start-AapInterimProcess([string]$Dir) {
    $p = Start-Process -FilePath $env:ComSpec -ArgumentList '/c', 'run.cmd' -WorkingDirectory $Dir -WindowStyle Hidden -PassThru
    $null = $p.Handle
    try { $p.PriorityClass = 'BelowNormal' } catch { Write-AapInterimLog "priority not set: $($_.Exception.Message)" }
    $p.WaitForExit()
    return [int]$p.ExitCode
}

# The whole decision; returns the exit code.
function Start-AapInterimRunner([string]$Dir, [int]$StopWaitSeconds) {
    if (-not (Test-Path -LiteralPath (Join-Path $Dir '.runner'))) { return 0 }
    if (-not (Add-AapInterimGitBash)) { Write-AapInterimLog 'Git Bash not found; PATH unchanged, shell: bash may resolve to the WSL launcher' }
    $state = Stop-AapInterimStale $Dir $StopWaitSeconds
    switch ($state) {
        'busy' { Write-AapInterimLog 'a job is running on the existing listener; left alone, nothing started'; return 0 }
        'unknown' { Write-AapInterimLog 'refusing: a runner process this account cannot read is running'; return 1 }
        'stuck' { Write-AapInterimLog 'refusing: an earlier listener or its host is still running after the kill'; return 1 }
    }
    Write-AapInterimLog "starting run.cmd (earlier listener: $state)"
    $code = Start-AapInterimProcess $Dir
    Write-AapInterimLog "run.cmd exited $code"
    return $code
}

$script:AapInterimLog = Join-Path $PSScriptRoot 'start-runner.log'
if ($NoRun) { return }

$ErrorActionPreference = 'Stop'
$Dir = [IO.Path]::GetFullPath($Dir).TrimEnd('\')
# One instance of this script at a time, for as long as it supervises run.cmd.
$lock = New-Object Threading.Mutex($false, 'Global\AapWinInterimRunnerStart')
$held = $false
try {
    try { $held = $lock.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
    if (-not $held) {
        Write-AapInterimLog 'another instance of this script is running; nothing started'
        exit 0
    }
    exit (Start-AapInterimRunner $Dir $StopWaitSeconds)
} catch {
    Write-AapInterimLog "failed: $($_.Exception.Message)"
    exit 1
} finally {
    if ($held) { $lock.ReleaseMutex() }
    $lock.Dispose()
}
