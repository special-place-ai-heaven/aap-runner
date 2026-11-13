# Starts the interim Windows runner with no visible window. Run by the task AAP-Win-Interim-Runner;
# the installed copy is C:\aap-win-interim\start-runner.ps1. Until the runner is configured
# (runner\.runner exists) this exits 0 at once.
#
# One listener only. A listener that outlives the script that started it keeps the runner's GitHub
# session, and a second one is refused ("A session for this runner already exists"). Two rules make
# that impossible instead of cleaning up after it:
#   1. One instance of this script at a time (a machine-wide mutex held for its whole life).
#   2. The script puts itself in a Windows job object that kills every process in it when the
#      script ends, however it ends. run.cmd, Runner.Listener and Runner.Worker are born in that
#      job, so none of them can outlive the script, and the next start is clean.
# Stopping the task does NOT stop the runner: it ends only the outer conhost, and this script, its
# run.cmd and the listener keep running. The supervisor turns the runner off through the control
# file instead (-ControlFile, host-runner.json beside its status.json): off exactly when the file
# parses as JSON with schema 1 and desired "off"; anything else, a missing file included, is on.
# Off is read once after the mutex is held (exit 0 before anything is killed or started) and then
# every 2 s while run.cmd runs: with a job in progress the script keeps waiting (never kills a
# worker); otherwise it returns, and the job object ends the listener with it.
# So: a listener is running  =>  its script is running  =>  the mutex is held  =>  a second start
# exits 0 without reading any other process (which fails across logon sessions anyway).
#
# A listener started some other way (an older copy of this script, a hand-run run.cmd) is the one
# case left. It is looked for once before starting: with a job in progress it is left alone
# (exit 0); with a path this account cannot read nothing is touched (exit 1); otherwise its run.cmd
# shell and then the listener are killed, and the start goes ahead only when none remains.
# There is no graceful stop for a hidden listener; after a kill GitHub keeps the old session for a
# minute or two and the new listener retries until it gets one.
#
# Exit codes: 0 nothing to do (not configured, another instance holds the mutex, a job is in
# progress on a foreign listener, turned off by the control file); 1 refused, failed, or run.cmd ended (the task's restart-on-failure
# then starts the runner again). The job object does not allow breakaway: whatever a CI job leaves
# running in the background ends with the script too.
# One line per decision is appended to start-runner.log beside this script.
#
# Dot-source safe: with -NoRun only the functions are defined (tests).
param(
    [string]$Dir = 'C:\aap-win-interim\runner',
    [int]$StopWaitSeconds = 15,
    [string]$MutexName = 'Global\AapWinInterimRunnerStart',
    [string]$ControlFile = 'C:\ProgramData\aap-runner\host-runner.json',
    [switch]$NoRun
)

function Write-AapInterimLog([string]$Line) {
    try {
        Add-Content -LiteralPath $script:AapInterimLog -Encoding utf8 -Value "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK') $Line"
    } catch { }
}

# Puts this process in a new job object that terminates every process in it when the last handle
# closes, that is when this process ends. Children are born in the job. Throws when it cannot.
function Enter-AapInterimJob {
    if (-not ('AapInterim.Job' -as [type])) {
        Add-Type -Namespace AapInterim -Name Job -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr CreateJobObject(IntPtr attrs, string name);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetInformationJobObject(IntPtr job, int cls, IntPtr info, uint len);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
[DllImport("kernel32.dll")] public static extern IntPtr GetCurrentProcess();
'@
    }
    $job = [AapInterim.Job]::CreateJobObject([IntPtr]::Zero, $null)
    if ($job -eq [IntPtr]::Zero) { throw "CreateJobObject failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
    # JOBOBJECT_EXTENDED_LIMIT_INFORMATION (class 9): 144 bytes on x64, 112 on x86; LimitFlags at offset 16.
    $len = if ([IntPtr]::Size -eq 8) { 144 } else { 112 }
    $info = [Runtime.InteropServices.Marshal]::AllocHGlobal($len)
    try {
        0..($len - 1) | ForEach-Object { [Runtime.InteropServices.Marshal]::WriteByte($info, $_, 0) }
        [Runtime.InteropServices.Marshal]::WriteInt32($info, 16, 0x2000)   # KILL_ON_JOB_CLOSE
        if (-not [AapInterim.Job]::SetInformationJobObject($job, 9, $info, $len)) {
            throw "SetInformationJobObject failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
        }
    } finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($info) }
    if (-not [AapInterim.Job]::AssignProcessToJobObject($job, [AapInterim.Job]::GetCurrentProcess())) {
        throw "AssignProcessToJobObject failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
    $script:AapInterimJob = $job   # kept open until the process ends
}

# This folder's listeners and workers, the run.cmd shells directly above a listener, and Unknown:
# runner processes whose path this account cannot read. Never guesses.
function Get-AapInterimProcesses([string]$Dir) {
    $bin = [IO.Path]::GetFullPath($Dir).TrimEnd('\') + '\bin\'
    $all = @(Get-CimInstance Win32_Process)
    $runner = @($all | Where-Object { $_.Name -eq 'Runner.Listener.exe' -or $_.Name -eq 'Runner.Worker.exe' })
    $unknown = @($runner | Where-Object { -not $_.ExecutablePath })
    $mine = @($runner | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($bin, [StringComparison]::OrdinalIgnoreCase) })
    $listeners = @($mine | Where-Object { $_.Name -eq 'Runner.Listener.exe' })
    $ids = @($listeners | ForEach-Object { $_.ProcessId })
    # A worker is ours by path, or because one of our listeners started it.
    $workers = @($runner | Where-Object { $_.Name -eq 'Runner.Worker.exe' -and ($mine -contains $_ -or $ids -contains $_.ParentProcessId) })
    $hosts = @()
    foreach ($l in $listeners) {
        $parent = $l.ParentProcessId
        for ($i = 0; $i -lt 3 -and $parent; $i++) {
            $p = $all | Where-Object { $_.ProcessId -eq $parent } | Select-Object -First 1
            if (-not $p -or $p.Name -ne 'cmd.exe' -or $p.CommandLine -notmatch '(^|[\s"\\/])run(-helper)?\.cmd(\s|"|$)') { break }
            $hosts += $p
            $parent = $p.ParentProcessId
        }
    }
    [pscustomobject]@{ Listeners = $listeners; Workers = $workers; Hosts = $hosts; Unknown = $unknown }
}

# Deals with a listener this script did not start. 'none', 'busy' (job in progress; untouched),
# 'unknown' (unreadable runner process; untouched), 'stopped' or 'stuck'.
function Stop-AapInterimForeign([string]$Dir, [int]$WaitSeconds) {
    $now = Get-AapInterimProcesses $Dir
    if ($now.Unknown.Count -gt 0) { return 'unknown' }
    if ($now.Workers.Count -gt 0) { return 'busy' }
    if ($now.Listeners.Count -eq 0) { return 'none' }
    # Shells first, so nothing starts the listener again; then the listener, unless a job began.
    foreach ($p in @($now.Hosts) + @($now.Listeners)) {
        if ($p.Name -eq 'Runner.Listener.exe' -and (Get-AapInterimProcesses $Dir).Workers.Count -gt 0) {
            Write-AapInterimLog "a job started on listener $($p.ProcessId) while stopping it; its run.cmd shell is already gone"
            return 'busy'
        }
        try {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
            Write-AapInterimLog "killed $($p.Name) $($p.ProcessId)"
        } catch {
            Write-AapInterimLog "could not kill $($p.Name) $($p.ProcessId): $($_.Exception.Message)"
        }
    }
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    do {
        $left = Get-AapInterimProcesses $Dir
        if ($left.Listeners.Count -eq 0 -and $left.Unknown.Count -eq 0) { return 'stopped' }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    return 'stuck'
}

function Add-AapInterimGitBash([string]$GitBin = 'C:\Program Files\Git\bin') {
    # Git Bash first on PATH, as on GitHub's hosted Windows runners, so `shell: bash` never resolves
    # to C:\Windows\System32\bash.exe (the WSL launcher). Jobs inherit this process's PATH.
    if (-not (Test-Path -LiteralPath (Join-Path $GitBin 'bash.exe'))) { return $false }
    if (-not $env:Path.StartsWith("$GitBin;", [StringComparison]::OrdinalIgnoreCase)) { $env:Path = "$GitBin;$env:Path" }
    return $true
}

# The supervisor's switch: $true only for a file that parses as JSON with schema 1 and desired
# exactly "off". Missing, unreadable, malformed, another schema or any other word means on.
function Test-AapInterimOff([string]$ControlFile) {
    try {
        $o = [IO.File]::ReadAllText($ControlFile) | ConvertFrom-Json
        return ($null -ne $o -and ($o.schema -is [int] -or $o.schema -is [long]) -and $o.schema -eq 1 -and
            $o.desired -is [string] -and $o.desired -ceq 'off')
    } catch { return $false }
}

# Waits for run.cmd in slices, reading the control file each slice. Returns run.cmd's exit code,
# or $null once the runner is turned off and no job is in progress. A job in progress is never
# touched: the script keeps waiting and logs once per stop request; a withdrawn request is forgotten.
function Wait-AapInterimProcess($Process, [string]$Dir, [string]$ControlFile, [int]$SliceMs = 2000) {
    $asked = $false
    while (-not $Process.WaitForExit($SliceMs)) {
        if (-not (Test-AapInterimOff $ControlFile)) { $asked = $false; continue }
        $now = Get-AapInterimProcesses $Dir
        if ($now.Workers.Count -gt 0 -or $now.Unknown.Count -gt 0) {
            if (-not $asked) { Write-AapInterimLog 'turned off by the supervisor; waiting for the job in progress' }
            $asked = $true
            continue
        }
        Write-AapInterimLog 'turned off by the supervisor; no job in progress, stopping the runner'
        return $null
    }
    return [int]$Process.ExitCode
}

# run.cmd hidden, below normal priority; returns what Wait-AapInterimProcess returns.
function Start-AapInterimProcess([string]$Dir, [string]$ControlFile) {
    $p = Start-Process -FilePath $env:ComSpec -ArgumentList '/c', 'run.cmd' -WorkingDirectory $Dir -WindowStyle Hidden -PassThru
    $null = $p.Handle
    try { $p.PriorityClass = 'BelowNormal' } catch { Write-AapInterimLog "priority not set: $($_.Exception.Message)" }
    return (Wait-AapInterimProcess $p $Dir $ControlFile)
}

# The whole decision, for a caller that holds the mutex; returns the exit code.
function Start-AapInterimRunner([string]$Dir, [int]$StopWaitSeconds, [string]$ControlFile) {
    if (-not (Test-Path -LiteralPath (Join-Path $Dir '.runner'))) { return 0 }
    if (Test-AapInterimOff $ControlFile) { Write-AapInterimLog 'turned off by the supervisor; nothing started'; return 0 }
    if (-not (Add-AapInterimGitBash)) { Write-AapInterimLog 'Git Bash not found; PATH unchanged, shell: bash may resolve to the WSL launcher' }
    $state = Stop-AapInterimForeign $Dir $StopWaitSeconds
    switch ($state) {
        'busy' { Write-AapInterimLog 'a job is running on a listener this script did not start; left alone, nothing started'; return 0 }
        'unknown' { Write-AapInterimLog 'refusing: a runner process this account cannot read is running'; return 1 }
        'stuck' { Write-AapInterimLog 'refusing: a listener this script did not start survived the kill'; return 1 }
    }
    Enter-AapInterimJob
    Write-AapInterimLog "starting run.cmd (foreign listener: $state)"
    $code = Start-AapInterimProcess $Dir $ControlFile
    if ($null -eq $code) { return 0 }
    # The runner should run for as long as this script does. run.cmd returns 0 for almost every
    # ending (crash, session conflict), so report a failure and let the task's restart-on-failure
    # start it again.
    Write-AapInterimLog "run.cmd exited $code; reporting 1 so the task restarts the runner"
    return 1
}

$script:AapInterimLog = Join-Path $PSScriptRoot 'start-runner.log'
if ($NoRun) { return }

$ErrorActionPreference = 'Stop'
$lock = $null
$held = $false
try {
    $Dir = [IO.Path]::GetFullPath($Dir).TrimEnd('\')
    $lock = New-Object Threading.Mutex($false, $MutexName)
    try { $held = $lock.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
    if (-not $held) {
        Write-AapInterimLog 'another instance of this script is running the runner; nothing started'
        exit 0
    }
    exit (Start-AapInterimRunner $Dir $StopWaitSeconds $ControlFile)
} catch {
    Write-AapInterimLog "failed: $($_.Exception.Message)"
    exit 1
} finally {
    if ($held) { $lock.ReleaseMutex() }
    if ($lock) { $lock.Dispose() }
}
