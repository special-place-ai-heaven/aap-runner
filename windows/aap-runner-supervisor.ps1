# Host supervisor for the aap-runner WSL distro. Windows PowerShell 5.1
# and PowerShell 7. Task AAP-CRRR-Supervisor starts it at logon as the
# installing user (install-supervisor.ps1).
#
# Why a per-user logon task and not a SYSTEM service (WSL 3.0.3):
# - SYSTEM cannot start a distro: WSL_E_LOCAL_SYSTEM_NOT_SUPPORTED since
#   WSL 2.0.2 (github.com/microsoft/WSL, LxssUserSessionFactory.cpp).
# - WSL keeps one session per user SID. A distro this user starts in any
#   logon session is the same instance the user sees in a terminal.
# - wsl --mount needs an elevated token
#   (learn.microsoft.com/windows/wsl/wsl2-mount-disk). The disk is attached
#   by the existing AAP-CRRR-Mount-Work-Disk task; this script only runs it.
# - A distro stops about 15 s after its last wsl.exe client exits
#   (instanceIdleTimeout). The keep-alive child below holds it while On.
# Logoff and shutdown stop the runner by design; the next logon resumes it.
#
# Contracts. C:\ProgramData\aap-runner is admin-owned; the operator can
# only read it. Its inbox\ subfolder is the one place the operator (the
# non-elevated tray) can write. This elevated script only READS inbox\, with
# one bounded open per file, and never creates, renames or deletes anything
# there, so a junction or link planted in inbox\ cannot redirect a write.
# - inbox\state.json    {"desired":"on"|"off"}.
# - inbox\settings.json {"runner_count":1..3,"job_cpus":1..28,
#   "job_memory_gib":1..80,"paused":true|false}. Missing = no override, not
#   paused. Invalid = one logged warning, the last valid content stays.
#   Both files are parsed strictly. Only validated integers ever reach a
#   command or the limits file.
# - status.json   {"state","job","updated","detail","runner_count",
#   "job_cpus","job_memory_gib","repo","run_url"} in the admin-owned root.
#   repo and run_url are copied from the manager only when they match a
#   strict pattern (the tray opens run_url), else empty. Rewritten
#   atomically. The tray treats it as stale after 180 s, so it is rewritten
#   at least every 60 s, also while Off.
# - logs\supervisor.log (admin-owned), one line per event, rotated to .1 at
#   5 MB.
# wsl.exe is started by its absolute path; $env:SystemRoot comes from the
# operator's environment block and is not trusted.
#
# -Once runs one loop iteration. -DryRun logs decisions to the console and
# never calls wsl.exe, never starts a task, and writes no file.
[CmdletBinding()]
param(
    [string]$DataDir = 'C:\ProgramData\aap-runner',
    [string]$DistroName = 'aap-runner',
    [string]$MountTaskName = 'AAP-CRRR-Mount-Work-Disk',
    [int]$PollSeconds = 5,
    [int]$HealthSeconds = 60,
    [int]$DrainPollSeconds = 10,
    [int]$DrainTimeoutSeconds = 21600,
    [int]$WslTimeoutSeconds = 120,
    [switch]$Once,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# Functions read these two hashtables by dynamic scope and only change their
# keys, so a test that dot-sources this file can retarget them in place.
$AapCfg = @{
    DataDir             = $DataDir
    Distro              = $DistroName
    MountTask           = $MountTaskName
    HealthSeconds       = $HealthSeconds
    DrainPollSeconds    = $DrainPollSeconds
    DrainTimeoutSeconds = $DrainTimeoutSeconds
    WslTimeoutSeconds   = $WslTimeoutSeconds
    MountTimeoutSeconds = 180
    HeartbeatSeconds    = 60
    HealthyResetSeconds = 600
    LogMaxBytes         = 5MB
    DryRun              = [bool]$DryRun
}
$AapRt = @{}

$AapStates = @('off', 'starting', 'idle', 'running', 'draining', 'paused', 'error')
$AapManagerStates = @('starting', 'idle', 'running', 'draining')
$AapManager = '/usr/local/sbin/aap-runner-manager'
$AapOldManager = 'manager on the distro predates this supervisor; re-run install-host.ps1 from this branch'
$AapLimitsFile = '/etc/aap-runner/limits.conf'
# The only multi-word argument wsl.exe ever gets. A constant, so stdin is the
# only data channel into it. Same /bin/sh -c "..." form as install-host.ps1's
# key install, which is verified on Fresh.
$AapWriteLimits = 'umask 022; cat > /etc/aap-runner/limits.conf.tmp && mv /etc/aap-runner/limits.conf.tmp /etc/aap-runner/limits.conf'
$AapSettingRanges = [ordered]@{ runner_count = 3; job_cpus = 28; job_memory_gib = 80 }

function Initialize-AapRuntime {
    $AapRt.Mode = 'off'
    $AapRt.KeepAlive = $null
    # Two independent backoffs: OnFailures for the On sequence (mount task),
    # Failures for unit restarts in the health loop.
    $AapRt.OnFailures = 0
    $AapRt.Failures = 0
    $AapRt.HealthySince = $null
    $AapRt.NextHealth = [DateTimeOffset]::MinValue
    $AapRt.RetryAt = [DateTimeOffset]::MinValue
    $AapRt.LastWarn = $null
    $AapRt.LastSettingsWarn = $null
    $AapRt.Settings = @{ Limits = $null; Paused = $false }
    $AapRt.Paused = $false
    $AapRt.Applied = $null
    $AapRt.Refused = $null
    $AapRt.RefusedWhy = $null
    $AapRt.Effective = $null
    $AapRt.VmWarned = $false
    $AapRt.ManagerOk = $null
    $AapRt.ProbedAt = [DateTimeOffset]::MinValue
    $AapRt.Status = $null
    $AapRt.StatusAt = [DateTimeOffset]::MinValue
}
Initialize-AapRuntime

# Clock and sleep are separate functions so tests can replace them.
function Get-AapNow { return [DateTimeOffset]::Now }
function Wait-AapInterval([int]$Seconds) { Start-Sleep -Seconds $Seconds }

function Test-AapName([string]$Name) {
    return $Name -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z'
}

function Get-AapBackoffDelay([int]$Failures) {
    $steps = @(10, 30, 60, 120, 300)
    $i = [Math]::Min([Math]::Max($Failures, 1), $steps.Count) - 1
    return $steps[$i]
}

function Split-AapLine([string]$Text) {
    return @(($Text -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# Text from the distro or a file, made safe for one log or status line.
function Format-AapText([string]$Text, [int]$Max = 160) {
    $t = (($Text -replace '[\x00-\x1f]', ' ') -replace '\s+', ' ').Trim()
    if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max) }
    return $t
}

function Get-AapLimitsKey($Limits) {
    if ($null -eq $Limits) { return $null }
    return '{0},{1},{2}' -f $Limits.RunnerCount, $Limits.JobCpus, $Limits.JobMemoryGib
}

function Write-AapLog([string]$Text) {
    $line = (Get-AapNow).ToString('yyyy-MM-ddTHH:mm:sszzz', [Globalization.CultureInfo]::InvariantCulture) + ' ' + $Text
    if ($AapCfg.DryRun) {
        [Console]::Out.WriteLine($line)
        return
    }
    try {
        $dir = Join-Path $AapCfg.DataDir 'logs'
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $log = Join-Path $dir 'supervisor.log'
        if ((Test-Path -LiteralPath $log) -and (Get-Item -LiteralPath $log).Length -ge $AapCfg.LogMaxBytes) {
            Move-Item -LiteralPath $log -Destination "$log.1" -Force
        }
        Add-Content -LiteralPath $log -Encoding utf8 -Value $line
    } catch {
        [Console]::Error.WriteLine("log write failed: $($_.Exception.Message)")
    }
}

# Reads a tray-written JSON file: size-capped, must be one JSON object.
# Returns the object, or a warning string, or $null when the file is missing.
function Read-AapJsonFile([string]$Name) {
    $path = Join-Path (Join-Path $AapCfg.DataDir 'inbox') $Name
    try {
        # One open, at most 4097 bytes read: a file swapped between a size
        # check and a read cannot slip past the cap. More than 4096 = refused.
        try {
            $fs = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        } catch [IO.FileNotFoundException] {
            return $null
        } catch [IO.DirectoryNotFoundException] {
            return $null
        }
        $buf = New-Object byte[] 4097
        $n = 0
        try {
            while ($n -lt $buf.Length) {
                $got = $fs.Read($buf, $n, $buf.Length - $n)
                if ($got -le 0) { break }
                $n += $got
            }
        } finally {
            $fs.Dispose()
        }
        if ($n -gt 4096) { return "$Name is larger than 4 KB" }
        # Honours a UTF-8 or UTF-16 BOM, like the earlier ReadAllText.
        $reader = New-Object IO.StreamReader((New-Object IO.MemoryStream($buf, 0, $n)), (New-Object Text.UTF8Encoding($false)), $true)
        try { $raw = $reader.ReadToEnd().TrimStart([char]0xFEFF) } finally { $reader.Dispose() }
        try { $obj = ConvertFrom-Json -InputObject $raw } catch { return "$Name is not valid JSON" }
        if (-not ($obj -is [pscustomobject])) { return "$Name is not a JSON object" }
        return $obj
    } catch {
        return "$Name is unreadable"
    }
}

# Returns 'on' or 'off'. desired must be exactly "on" or "off". A repeated
# warning is logged once, not every 5 s.
function Read-AapDesired {
    $obj = Read-AapJsonFile 'state.json'
    $warn = $null
    $desired = 'off'
    if ($null -eq $obj) {
        $warn = 'state.json is missing'
    } elseif ($obj -is [string]) {
        $warn = $obj
    } else {
        $value = $null
        if ($obj.PSObject.Properties['desired']) { $value = $obj.desired }
        if ($value -is [string] -and ($value -ceq 'on' -or $value -ceq 'off')) {
            $desired = $value
        } else {
            $warn = 'state.json is not {"desired":"on"|"off"}'
        }
    }
    if ($warn -and $warn -ne $AapRt.LastWarn) { Write-AapLog "WARN $warn; treating as off" }
    $AapRt.LastWarn = $warn
    return $desired
}

# Returns @{ Limits = $null | @{RunnerCount;JobCpus;JobMemoryGib}; Paused }.
# Exactly the four keys; integers (not 1.0, not "1") inside their ranges;
# paused a JSON boolean. Anything else keeps the last valid settings.
function Read-AapSettingsFile {
    $obj = Read-AapJsonFile 'settings.json'
    $warn = $null
    if ($null -eq $obj) {
        $AapRt.Settings = @{ Limits = $null; Paused = $false }
    } elseif ($obj -is [string]) {
        $warn = $obj
    } else {
        $names = @($obj.PSObject.Properties.Name | Sort-Object)
        $want = @(@($AapSettingRanges.Keys) + 'paused' | Sort-Object)
        if (($names -join ',') -cne ($want -join ',')) {
            $warn = 'settings.json must have exactly runner_count, job_cpus, job_memory_gib, paused'
        } else {
            foreach ($key in $AapSettingRanges.Keys) {
                $v = $obj.$key
                if (-not ($v -is [int] -or $v -is [long]) -or $v -lt 1 -or $v -gt $AapSettingRanges[$key]) {
                    $warn = "settings.json $key must be an integer 1..$($AapSettingRanges[$key])"
                    break
                }
            }
            if (-not $warn -and -not ($obj.paused -is [bool])) { $warn = 'settings.json paused must be true or false' }
        }
        if (-not $warn) {
            $AapRt.Settings = @{
                Limits = @{ RunnerCount = [int]$obj.runner_count; JobCpus = [int]$obj.job_cpus; JobMemoryGib = [int]$obj.job_memory_gib }
                Paused = [bool]$obj.paused
            }
        }
    }
    if ($warn -and $warn -ne $AapRt.LastSettingsWarn) { Write-AapLog "WARN $warn; keeping the last valid settings" }
    $AapRt.LastSettingsWarn = $warn
    return $AapRt.Settings
}

function Write-AapStatus {
    param([string]$State, [string]$Job = '', [string]$Detail = '', [string]$Repo = '', [string]$RunUrl = '')
    if ($AapStates -notcontains $State) { throw "unknown status state $State" }
    $Job = Format-AapText $Job 128
    $now = Get-AapNow
    $eff = $AapRt.Effective
    $obj = [ordered]@{
        state          = $State
        job            = $Job
        updated        = $now.ToString('yyyy-MM-ddTHH:mm:sszzz', [Globalization.CultureInfo]::InvariantCulture)
        detail         = $Detail
        runner_count   = $null
        job_cpus       = $null
        job_memory_gib = $null
        repo           = $Repo
        run_url        = $RunUrl
    }
    if ($eff) {
        $obj.runner_count = $eff.RunnerCount
        $obj.job_cpus = $eff.JobCpus
        $obj.job_memory_gib = $eff.JobMemoryGib
    }
    $prev = $AapRt.Status
    $AapRt.Status = @{ State = $State; Job = $Job; Detail = $Detail; Repo = $Repo; RunUrl = $RunUrl }
    $AapRt.StatusAt = $now
    if ($null -eq $prev -or $prev.State -ne $State -or $prev.Job -ne $Job -or $prev.Detail -ne $Detail) {
        Write-AapLog "status $State job=$Job $Detail"
    }
    if ($AapCfg.DryRun) { return }
    $path = Join-Path $AapCfg.DataDir 'status.json'
    $tmp = "$path.tmp"
    [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $obj -Compress), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

# The one place wsl.exe is started. Arguments are fixed tokens from this
# script (plus the one constant $AapWriteLimits script); the allow-list makes
# a quoting mistake fail instead of reaching wsl.exe. Process is used instead
# of & so stdout, stderr and the exit code come back separately, stdin can
# carry data, and a hung call can be killed. That also avoids the Windows
# PowerShell 5.1 trap where native stderr under Stop becomes a terminating
# error (see ../mount-work-vhdx.ps1). WSL_UTF8=1 makes wsl.exe's own messages
# UTF-8 instead of UTF-16; NULs are stripped in case it is ignored.
# -Background returns the running Process (the keep-alive child).
function Invoke-AapWsl {
    param([Parameter(Mandatory = $true)][string[]]$Arguments, [int]$TimeoutSeconds = 0, [switch]$Background, $StdIn = $null)
    $quoted = foreach ($a in $Arguments) {
        if ($a -ceq $AapWriteLimits) { '"' + $a + '"'; continue }
        if ($a -notmatch '^[A-Za-z0-9_./:-]+\z') { throw "refusing wsl.exe argument: $a" }
        $a
    }
    if ($TimeoutSeconds -le 0) { $TimeoutSeconds = $AapCfg.WslTimeoutSeconds }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'C:\Windows\System32\wsl.exe'
    $psi.Arguments = @($quoted) -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables['WSL_UTF8'] = '1'
    if ($Background) {
        return [System.Diagnostics.Process]::Start($psi)
    }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = ($null -ne $StdIn)
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEndAsync()
    $err = $p.StandardError.ReadToEndAsync()
    if ($null -ne $StdIn) {
        # Raw bytes: the StandardInput writer would use the console code page.
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes([string]$StdIn)
        $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        $p.StandardInput.Close()
    }
    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
        try { $p.Kill() } catch { $null = $_ }
        [void]$p.WaitForExit(5000)
        return [pscustomobject]@{ Code = -1; Out = ''; Err = "timeout after $TimeoutSeconds s"; TimedOut = $true }
    }
    $p.WaitForExit()
    return [pscustomobject]@{
        Code     = $p.ExitCode
        Out      = ([string]$out.Result) -replace [char]0, ''
        Err      = ([string]$err.Result) -replace [char]0, ''
        TimedOut = $false
    }
}

function Invoke-AapRoot([string[]]$Argv, $StdIn = $null) {
    $argList = @('-d', $AapCfg.Distro, '-u', 'root', '--') + $Argv
    if ($null -ne $StdIn) { return Invoke-AapWsl -Arguments $argList -StdIn $StdIn }
    return Invoke-AapWsl -Arguments $argList
}

# /run/aap-runner/status.json from the manager. State is $null unless the
# Windows contract knows it. Limits are $null unless all three parse.
# Repo and RunUrl are '' unless they match exactly; the tray opens RunUrl.
function ConvertFrom-AapManagerStatus([string]$Text) {
    try { $obj = ConvertFrom-Json -InputObject $Text } catch { return $null }
    if (-not ($obj -is [pscustomobject])) { return $null }
    $state = [string]$obj.state
    if ($AapManagerStates -notcontains $state) { $state = $null }
    $limits = $null
    $count = [string]$obj.runner_count
    $cpus = [string]$obj.job_cpus
    $mem = [string]$obj.job_memory
    if ($count -match '^\d{1,4}\z' -and $cpus -match '^\d{1,4}\z' -and $mem -match '^(\d{1,5})[gG]\z') {
        $limits = @{ RunnerCount = [int]$count; JobCpus = [int]$cpus; JobMemoryGib = [int]$Matches[1] }
    }
    $repo = $obj.repo
    if (-not ($repo -is [string]) -or $repo -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z') { $repo = '' }
    $url = $obj.run_url
    if (-not ($url -is [string]) -or $url -cnotmatch '^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/actions/runs/[0-9]+\z') { $url = '' }
    return @{ State = $state; Job = [string]$obj.job; Limits = $limits; Repo = $repo; RunUrl = $url }
}

# Runs the existing mount task (no second copy of the mount logic). Returns
# $null on success, else an error text. The task runs elevated as this user;
# its script treats "already attached" as success.
function Invoke-AapMountTask {
    $name = $AapCfg.MountTask
    try {
        Start-ScheduledTask -TaskName $name -ErrorAction Stop
    } catch {
        return "could not start ${name}: $($_.Exception.Message)"
    }
    $deadline = (Get-AapNow).AddSeconds($AapCfg.MountTimeoutSeconds)
    $state = ''
    do {
        Wait-AapInterval 2
        try { $state = [string](Get-ScheduledTask -TaskName $name -ErrorAction Stop).State } catch { $state = 'missing' }
        if ($state -eq 'Ready') { break }
    } while ((Get-AapNow) -lt $deadline)
    if ($state -ne 'Ready') { return "$name still $state after $($AapCfg.MountTimeoutSeconds) s" }
    $result = (Get-ScheduledTaskInfo -TaskName $name -ErrorAction Stop).LastTaskResult
    if ($result -ne 0) { return "$name LastTaskResult $result" }
    return $null
}

function Invoke-AapKeepAlive {
    $p = $AapRt.KeepAlive
    if ($null -ne $p -and -not $p.HasExited) { return }
    if ($null -ne $p) { Write-AapLog 'keep-alive exited; restarting' }
    $AapRt.KeepAlive = Invoke-AapWsl -Arguments @('-d', $AapCfg.Distro, '--exec', '/bin/sleep', 'infinity') -Background
    Write-AapLog "keep-alive started pid=$($AapRt.KeepAlive.Id)"
}

function Invoke-AapKeepAliveStop {
    $p = $AapRt.KeepAlive
    $AapRt.KeepAlive = $null
    if ($null -eq $p -or $p.HasExited) { return }
    try {
        $p.Kill()
        [void]$p.WaitForExit(5000)
    } catch {
        Write-AapLog "keep-alive kill failed: $($_.Exception.Message)"
    }
}

# vmmemWSL is the WSL VM. BelowNormal lets interactive Windows apps (games)
# win CPU contention against CI jobs. Only this process is touched, only
# while On; a failure (access denied) is logged once.
function Set-AapVmPriority {
    foreach ($p in @(Get-Process -Name 'vmmemWSL' -ErrorAction SilentlyContinue)) {
        try {
            $old = [string]$p.PriorityClass
            if ($old -ne 'BelowNormal') {
                $p.PriorityClass = 'BelowNormal'
                Write-AapLog "vmmemWSL pid=$($p.Id) priority $old -> BelowNormal"
            }
        } catch {
            if (-not $AapRt.VmWarned) { Write-AapLog "vmmemWSL priority not set: $($_.Exception.Message)" }
            $AapRt.VmWarned = $true
        }
    }
}

# Polls until the manager unit is inactive (it exits 0 once drained and
# idle). Returns 'inactive', 'timeout', or 'aborted' when state.json says
# $AbortWhen. Shared by Off, pause and limit changes.
function Wait-AapManagerInactive([string]$AbortWhen, [string]$Detail) {
    $deadline = (Get-AapNow).AddSeconds($AapCfg.DrainTimeoutSeconds)
    while ($true) {
        $r = Invoke-AapRoot @('/bin/systemctl', 'is-active', 'aap-runner-manager')
        $lines = @(Split-AapLine $r.Out)
        $state = 'unknown'
        if ($lines.Count -ge 1) { $state = $lines[0] }
        # failed counts as stopped: the manager is not running a job.
        if ($state -eq 'inactive' -or $state -eq 'failed') { return 'inactive' }
        if ((Get-AapNow) -ge $deadline) {
            Write-AapLog "drain timeout after $($AapCfg.DrainTimeoutSeconds) s (manager $state); continuing"
            return 'timeout'
        }
        if ((Read-AapDesired) -eq $AbortWhen) { return 'aborted' }
        Write-AapStatus 'draining' '' "${Detail}: waiting for manager to exit ($state)"
        Wait-AapInterval $AapCfg.DrainPollSeconds
    }
}

# An older manager ignores unknown flags: --drain, --undrain or
# --check-limits would start a full pool, kill running jobs and block. So no
# manager flag is used until a passive probe shows the installed manager
# knows them. grep cannot start a pool; --version is not called on an
# unknown manager for the same reason. A pass is cached until Off; a failure
# is probed again at a later health tick (30 s or more after the last
# probe), so a reinstall is picked up.
function Test-AapManagerFlag {
    if ($null -eq $AapRt.ManagerOk) {
        $r = Invoke-AapRoot @('/bin/grep', '-q', '--', '--undrain', $AapManager)
        $AapRt.ManagerOk = ($r.Code -eq 0)
        $AapRt.ProbedAt = Get-AapNow
        if (-not $AapRt.ManagerOk) { Write-AapLog "WARN probe exit $($r.Code): $AapOldManager" }
    }
    return $AapRt.ManagerOk
}

# systemctl start, then is-active on the same units. A unit that is not
# active gets its last 5 journal lines in the log. Returns $true when all
# units are active.
function Invoke-AapUnitStart([string[]]$Units) {
    $r = Invoke-AapRoot (@('/bin/systemctl', 'start') + $Units)
    if ($r.Code -ne 0) { Write-AapLog "systemctl start $($Units -join ' ') exit $($r.Code): $(Format-AapText $r.Err)" }
    $lines = @(Split-AapLine (Invoke-AapRoot (@('/bin/systemctl', 'is-active') + $Units)).Out)
    $ok = $true
    for ($i = 0; $i -lt $Units.Count; $i++) {
        $state = 'unknown'
        if ($i -lt $lines.Count) { $state = $lines[$i] }
        if ($state -eq 'active') { continue }
        $ok = $false
        $j = Invoke-AapRoot @('/bin/journalctl', '-u', $Units[$i], '-n', '5', '--no-pager')
        Write-AapLog "$($Units[$i]) is $state after start; journal: $(Format-AapText ($j.Out + ' ' + $j.Err) 600)"
    }
    return $ok
}

# Off -> On. Every step is idempotent, so it is also the recovery path after
# a supervisor restart.
function Invoke-AapOn {
    Write-AapStatus 'starting' '' 'attaching work disk'
    $err = Invoke-AapMountTask
    if ($err) {
        $AapRt.OnFailures++
        $delay = Get-AapBackoffDelay $AapRt.OnFailures
        $AapRt.RetryAt = (Get-AapNow).AddSeconds($delay)
        Write-AapStatus 'error' '' "$err; retry in $delay s"
        return
    }
    Invoke-AapKeepAlive
    if (Test-AapManagerFlag) {
        $r = Invoke-AapRoot @($AapManager, '--undrain')
        if ($r.Code -ne 0) { Write-AapLog "undrain exit $($r.Code): $(Format-AapText $r.Err)" }
    }
    # systemctl is safe on the old manager too.
    [void](Invoke-AapUnitStart @('sysbox', 'aap-runner-manager'))
    $AapRt.OnFailures = 0
    $AapRt.Mode = 'on'
    Invoke-AapHealth
}

# One health pass. A restart attempt counts as a failure until the services
# have been active for 10 minutes in a row. The next check comes after the
# backoff delay, so the restart cadence is 10, 30, 60, 120, then 300 s.
# While paused the manager is meant to be stopped; only sysbox is kept up.
function Invoke-AapHealth {
    Invoke-AapKeepAlive
    Set-AapVmPriority
    if ($AapRt.ManagerOk -eq $false -and ((Get-AapNow) - $AapRt.ProbedAt).TotalSeconds -ge 30) {
        $AapRt.ManagerOk = $null
        [void](Test-AapManagerFlag)
    }
    $r = Invoke-AapRoot @('/bin/systemctl', 'is-active', 'sysbox', 'aap-runner-manager')
    $lines = @(Split-AapLine $r.Out)
    $sysbox = 'unknown'
    $manager = 'unknown'
    if ($lines.Count -ge 1) { $sysbox = $lines[0] }
    if ($lines.Count -ge 2) { $manager = $lines[1] }
    $m = ConvertFrom-AapManagerStatus (Invoke-AapRoot @('/bin/cat', '/run/aap-runner/status.json')).Out
    if ($m -and $m.Limits) { $AapRt.Effective = $m.Limits }
    $now = Get-AapNow
    if ($sysbox -eq 'active' -and ($AapRt.Paused -or $manager -eq 'active')) {
        if ($null -eq $AapRt.HealthySince) {
            $AapRt.HealthySince = $now
        } elseif ($AapRt.Failures -gt 0 -and ($now - $AapRt.HealthySince).TotalSeconds -ge $AapCfg.HealthyResetSeconds) {
            Write-AapLog "healthy for $($AapCfg.HealthyResetSeconds) s; backoff reset"
            $AapRt.Failures = 0
        }
        $detail = ''
        if ($AapRt.RefusedWhy) { $detail = $AapRt.RefusedWhy }
        if ($AapRt.ManagerOk -eq $false) {
            Write-AapStatus 'error' '' $AapOldManager
        } elseif ($AapRt.Paused) {
            Write-AapStatus 'paused' '' $detail
        } elseif ($m -and $m.State) {
            Write-AapStatus $m.State $m.Job $detail $m.Repo $m.RunUrl
        } else {
            Write-AapStatus 'starting' '' 'manager status unavailable'
        }
        $AapRt.NextHealth = $now.AddSeconds($AapCfg.HealthSeconds)
        return
    }
    $AapRt.HealthySince = $null
    $AapRt.Failures++
    $delay = Get-AapBackoffDelay $AapRt.Failures
    $detail = "sysbox=$sysbox manager=$manager; restart $($AapRt.Failures)"
    Write-AapLog "unhealthy: $detail; next check in $delay s"
    [void](Invoke-AapUnitStart @('sysbox'))
    if (-not $AapRt.Paused) { [void](Invoke-AapUnitStart @('aap-runner-manager')) }
    if ($AapRt.Failures -ge 5) {
        Write-AapStatus 'error' '' "$detail failed; retrying every $delay s"
    } else {
        Write-AapStatus 'starting' '' $detail
    }
    $AapRt.NextHealth = $now.AddSeconds($delay)
}

# Drain, wait for the job to finish, keep the distro up. If Off arrives while
# waiting, Off takes over. The manager is drained either way, so Paused is
# set and a later resume undrains it.
function Invoke-AapPause {
    Write-AapStatus 'draining' '' 'pausing'
    [void](Invoke-AapRoot @($AapManager, '--drain'))
    $r = Wait-AapManagerInactive 'off' 'pausing'
    $AapRt.Paused = $true
    if ($r -ne 'aborted') { Write-AapStatus 'paused' '' '' }
    return $r
}

function Invoke-AapResume {
    Write-AapLog 'resume'
    [void](Invoke-AapRoot @($AapManager, '--undrain'))
    [void](Invoke-AapUnitStart @('aap-runner-manager'))
    $AapRt.Paused = $false
    $AapRt.NextHealth = [DateTimeOffset]::MinValue
}

# Write limits.conf, let the manager validate it, then restart the manager
# between jobs (drain, wait, undrain, start). A refused file is replaced by
# the previous content (or removed if there was none) and not retried until
# settings.json changes.
function Invoke-AapLimitChange($Limits) {
    $key = Get-AapLimitsKey $Limits
    $content = "AAP_RUNNER_COUNT=$([int]$Limits.RunnerCount)`nAAP_JOB_CPUS=$([int]$Limits.JobCpus)`nAAP_JOB_MEMORY=$([int]$Limits.JobMemoryGib)g`n"
    Write-AapLog "applying limits $key"
    $prev = Invoke-AapRoot @('/bin/cat', $AapLimitsFile)
    $w = Invoke-AapRoot @('/bin/sh', '-c', $AapWriteLimits) $content
    $check = $null
    if ($w.Code -eq 0) { $check = Invoke-AapRoot @($AapManager, '--check-limits') }
    if ($w.Code -ne 0 -or $check.Code -ne 0) {
        if ($w.Code -ne 0) {
            $why = "write exit $($w.Code) $(Format-AapText $w.Err)"
        } else {
            $why = Format-AapText (@(Split-AapLine ($check.Out + "`n" + $check.Err)) | Select-Object -First 1)
        }
        if ($prev.Code -eq 0) {
            [void](Invoke-AapRoot @('/bin/sh', '-c', $AapWriteLimits) $prev.Out)
        } else {
            [void](Invoke-AapRoot @('/bin/rm', '-f', $AapLimitsFile))
        }
        $AapRt.Refused = $key
        $AapRt.RefusedWhy = "limits $key refused: $why"
        Write-AapLog "$($AapRt.RefusedWhy); previous limits.conf restored"
        Write-AapStatus 'error' '' $AapRt.RefusedWhy
        return
    }
    Write-AapLog "check-limits ok: $(Format-AapText ($check.Out) 300)"
    $AapRt.Refused = $null
    $AapRt.RefusedWhy = $null
    if ($AapRt.Paused) {
        $AapRt.Applied = $key
        Write-AapLog 'paused; the manager picks up the limits on resume'
        return
    }
    Write-AapStatus 'draining' '' "applying limits $key"
    [void](Invoke-AapRoot @($AapManager, '--drain'))
    if ((Wait-AapManagerInactive 'off' "applying limits $key") -eq 'aborted') { return }
    [void](Invoke-AapRoot @($AapManager, '--undrain'))
    [void](Invoke-AapUnitStart @('aap-runner-manager'))
    $AapRt.Applied = $key
    $AapRt.NextHealth = [DateTimeOffset]::MinValue
}

# settings.json while On: pause or resume, then limits. Limits the manager
# already reports as effective count as applied, so a supervisor restart
# does not restart the manager for nothing.
function Sync-AapSettingsFile {
    $s = Read-AapSettingsFile
    # Pause and limits need manager flags; an old manager ignores settings.
    if (($s.Paused -or $null -ne $s.Limits -or $AapRt.Paused) -and -not (Test-AapManagerFlag)) { return }
    if ($s.Paused -and -not $AapRt.Paused) {
        if ((Invoke-AapPause) -eq 'aborted') { return }
    } elseif (-not $s.Paused -and $AapRt.Paused) {
        Invoke-AapResume
    }
    $key = Get-AapLimitsKey $s.Limits
    if ($null -eq $key -or $key -eq $AapRt.Applied -or $key -eq $AapRt.Refused) { return }
    if ($null -eq $AapRt.Applied -and $key -eq (Get-AapLimitsKey $AapRt.Effective)) {
        $AapRt.Applied = $key
        return
    }
    Invoke-AapLimitChange $s.Limits
}

# On -> Off. Off wins over paused. Drain lets the running job finish. If the
# tray flips back to On while draining, the drain is undone instead of
# waiting up to 6 h.
function Invoke-AapOff {
    if (Test-AapManagerFlag) {
        Write-AapStatus 'draining' '' 'drain requested'
        $r = Invoke-AapRoot @($AapManager, '--drain')
        if ($r.Code -ne 0) { Write-AapLog "drain exit $($r.Code): $(Format-AapText $r.Err)" }
        if ((Wait-AapManagerInactive 'on' 'stopping') -eq 'aborted') {
            Write-AapLog 'desired is on again during drain; undraining'
            [void](Invoke-AapRoot @($AapManager, '--undrain'))
            $AapRt.Paused = $false
            $AapRt.NextHealth = [DateTimeOffset]::MinValue
            return
        }
    } else {
        Write-AapLog "WARN no drain: $AapOldManager; terminating, which ends any running job"
    }
    $r = Invoke-AapWsl -Arguments @('--terminate', $AapCfg.Distro)
    if ($r.Code -ne 0) { Write-AapLog "terminate exit $($r.Code): $(Format-AapText $r.Err)" }
    Invoke-AapKeepAliveStop
    $AapRt.Mode = 'off'
    $AapRt.OnFailures = 0
    $AapRt.Failures = 0
    $AapRt.HealthySince = $null
    $AapRt.RetryAt = [DateTimeOffset]::MinValue
    $AapRt.Paused = $false
    $AapRt.Applied = $null
    $AapRt.Effective = $null
    $AapRt.ManagerOk = $null
    Write-AapStatus 'off' '' 'stopped'
}

function Get-AapAction([string]$Desired, [string]$Mode) {
    if ($Desired -eq 'on' -and $Mode -eq 'off') { return 'start' }
    if ($Desired -eq 'on') { return 'health' }
    if ($Mode -eq 'on') { return 'stop' }
    return 'none'
}

# One loop iteration. Off makes no wsl.exe call, so the distro stays stopped
# and Vmmem can exit. The status file is refreshed every HeartbeatSeconds.
function Invoke-AapCycle {
    $desired = Read-AapDesired
    $action = Get-AapAction $desired $AapRt.Mode
    $now = Get-AapNow
    if ($AapCfg.DryRun) {
        switch ($action) {
            'start' {
                Write-AapLog "DRYRUN would Start-ScheduledTask $($AapCfg.MountTask); wsl.exe -d $($AapCfg.Distro) --exec /bin/sleep infinity; aap-runner-manager --undrain; systemctl start sysbox aap-runner-manager"
                $AapRt.Mode = 'on'
            }
            'stop' {
                Write-AapLog "DRYRUN would aap-runner-manager --drain; wait for inactive; wsl.exe --terminate $($AapCfg.Distro); stop keep-alive"
                $AapRt.Mode = 'off'
            }
            'health' {
                if ($now -ge $AapRt.NextHealth) {
                    $s = Read-AapSettingsFile
                    Write-AapLog "DRYRUN would check systemctl is-active sysbox aap-runner-manager; settings limits=$(Get-AapLimitsKey $s.Limits) paused=$($s.Paused)"
                    $AapRt.NextHealth = $now.AddSeconds($AapCfg.HealthSeconds)
                }
            }
        }
        return
    }
    switch ($action) {
        'start' { if ($now -ge $AapRt.RetryAt) { Invoke-AapOn } }
        'stop' { Invoke-AapOff }
    }
    if ($desired -eq 'on' -and $AapRt.Mode -eq 'on') {
        Sync-AapSettingsFile
        if ((Get-AapNow) -ge $AapRt.NextHealth) { Invoke-AapHealth }
    }
    if ($null -eq $AapRt.Status) {
        Write-AapStatus 'off' '' ''
    } elseif (((Get-AapNow) - $AapRt.StatusAt).TotalSeconds -ge $AapCfg.HeartbeatSeconds) {
        Write-AapStatus $AapRt.Status.State $AapRt.Status.Job $AapRt.Status.Detail $AapRt.Status.Repo $AapRt.Status.RunUrl
    }
}

# A supervisor that was killed leaves the distro running (and its keep-alive
# child). When desired is off at startup and the distro runs, treat it as On
# so the next cycle drains and terminates it. When desired is on, the start
# sequence is idempotent and simply runs again.
function Initialize-AapMode {
    if ((Read-AapDesired) -ne 'off') { return }
    $r = Invoke-AapWsl -Arguments @('--list', '--running', '--quiet')
    if (@(Split-AapLine $r.Out) -contains $AapCfg.Distro) {
        Write-AapLog "$($AapCfg.Distro) is running while desired is off; will drain"
        $AapRt.Mode = 'on'
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    # powershell.exe 5.1 inherits pwsh 7's PSModulePath and then cannot
    # autoload ScheduledTasks. The task also resets it before this script.
    $machine = [Environment]::GetEnvironmentVariable('PSModulePath', 'Machine')
    if ([string]::IsNullOrEmpty($machine)) {
        [Console]::Error.WriteLine('refusing: machine PSModulePath is empty')
        exit 1
    }
    $env:PSModulePath = $machine
    if (-not (Test-AapName $DistroName) -or -not (Test-AapName $MountTaskName)) {
        [Console]::Error.WriteLine('refusing: DistroName or MountTaskName')
        exit 1
    }
    $code = 0
    try {
        Write-AapLog "supervisor start pid=$PID user=$([Security.Principal.WindowsIdentity]::GetCurrent().Name) dryrun=$($AapCfg.DryRun)"
        if (-not $AapCfg.DryRun) { Initialize-AapMode }
        while ($true) {
            try {
                Invoke-AapCycle
            } catch {
                $code = 1
                Write-AapLog "ERROR $($_.Exception.Message)"
            }
            if ($Once) { break }
            Wait-AapInterval $PollSeconds
        }
    } finally {
        # Runs on Ctrl+C and on a normal exit, not when Task Scheduler kills
        # the process. The distro is left as it is.
        if (-not $Once) {
            $final = 'off'
            if ($AapRt.Mode -eq 'on') { $final = 'error' }
            Write-AapStatus $final '' 'supervisor stopped'
        }
        Write-AapLog 'supervisor exit'
    }
    exit $code
}
