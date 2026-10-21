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
# - inbox\state.json    {"desired":"on"|"off"} plus optional "retry":<unix s>.
#   A retry newer than the last one seen resets both backoffs and runs the
#   next attempt now; nothing else is taken from it.
# - inbox\settings.json {"runner_count":1..5,"job_cpus":1..28,
#   "job_memory_gib":1..80,"paused":true|false} plus optional "schema":2,
#   "io_percent":0..100, "sharing":"slice"|"fixed" and "windows_runner_count":
#   0..4 with runner_count plus it at most 5 (schema 2). windows_runner_count
#   is reserved for a tray with a Windows backend: validated, never applied;
#   runner_count stays the Linux count. Schema 3 (only with the capacity
#   module, below) has every key of parity/contracts/settings-v3.schema.json:
#   Linux 0..5 and Windows 0..5 (together 1..5), shares and host reserve.
#   A schema above the newest accepted one is refused and named in the
#   status detail. Missing =
#   no override, not paused. Invalid = one logged warning, the last valid
#   content stays. Both files are parsed strictly. Only validated values
#   ever reach a command or the limits file.
# - status.json   {"state","job","updated","detail","runner_count",
#   "job_cpus","job_memory_gib","repo","run_url","schema":4,"sampled_at",
#   "pool","slots","job_io_mbps","sharing","work_disk_gib","work_disk_free_gb",
#   "work_disk_floor_gb","cleaning"} in the admin-owned root. Every
#   manager value is re-validated: URLs and repos match a strict pattern
#   (the tray opens them), numbers are in range, else empty or null. pool,
#   slots and the rest are mirrored only while the manager reports idle,
#   running or draining. Rewritten atomically. The tray treats it as stale
#   after 180 s, so it is rewritten at least every 60 s, also while Off.
# - status.v5.json, written with status.json: both profiles, the slots of
#   every backend, storage and the legacy pool (status-v5.schema.json).
#   status.json keeps schema 4 and describes the legacy pool only.
# - logs\supervisor.log (admin-owned), one line per event, rotated to .1 at
#   5 MB.
# Capacity. With capacity\AapCapacity.psm1 deployed beside this script, the
# P09 allocator in capacity\ (admin-only) holds every slot: it adopts the
# legacy pool, grants its slots (limits.conf follows the grants), and admits
# VM slots for the backends in backends\. Without it this is the schema 2
# supervisor: legacy pool only.
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
    ModuleDir           = $PSScriptRoot
    ReconcileSeconds    = 600
    # The always-on control VM's memory, paid before any slot. An estimate
    # until P22 measures the WSL VM without legacy jobs.
    ControlDistroMemGib = 2
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
$AapSettingRanges = [ordered]@{ runner_count = 5; job_cpus = 28; job_memory_gib = 80 }
$AapRepoPattern = '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z'
$AapRunUrlPattern = '^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/actions/runs/[0-9]+\z'
$AapJobUrlPattern = '^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/actions/runs/[0-9]+/job/[0-9]+\z'
$AapSlotStates = @('idle', 'running', 'draining', 'starting', 'error')
$AapV3Keys = @('schema', 'linux_backend', 'runner_count', 'windows_runner_count', 'job_cpus', 'job_memory_gib', 'paused', 'io_percent', 'sharing',
    'host_reserve_percent', 'share_mode', 'linux_share_percent', 'windows_share_percent', 'lease_wall_clock_hours')
$AapOs = @{ linux = 'Linux'; windows = 'Windows' }
# The backend modules a VM profile is driven by; the supervisor calls Invoke-Aap<Kind>Step and the
# other exported functions of backends\<folder>\Aap<Kind>Backend.psm1 by these names.
$AapVmKinds = @{ windows = 'Win'; linux = 'Lin' }
$AapVmFolders = @{ windows = 'windows'; linux = 'linux' }
$AapLegacyGeneration = 'legacy-manager'

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
    $AapRt.LastRetry = 0
    $AapRt.Settings = @{ Limits = $null; Paused = $false; Profiles = $null; Schema = $null }
    # A refused settings.json the status detail names (a newer schema).
    $AapRt.SettingsWhy = $null
    $AapRt.Paused = $false
    # The legacy manager is drained and stopped because no Linux slot is
    # granted (Linux 0, or Linux on VMs); the distro stays up for the broker.
    $AapRt.ManagerStopped = $false
    # Capacity (Initialize-AapProviders). CapArgs is splatted into every
    # allocator call; only tests put RelaxedTrustForTests in it.
    $AapRt.Cap = $false
    $AapRt.CapRoot = $null
    $AapRt.CapArgs = @{}
    $AapRt.CapReady = $false
    $AapRt.CapError = $null
    $AapRt.CapWhy = $null
    # grant_waits: raised legacy totals wait for the slots' next grant.
    $AapRt.HoldWhy = $null
    $AapRt.CapFlags = @()
    # The last refusal or error logged, per allocator call.
    $AapRt.CapLogged = @{}
    $AapRt.ReconcileAt = [DateTimeOffset]::MinValue
    $AapRt.HostInfo = $null
    $AapRt.StatusDoc = $null
    # Per VM profile: $null, or @{ Kind = 'Win'|'Lin'; B = <backend context> }.
    $AapRt.Vm = @{ linux = $null; windows = $null }
    $AapRt.VmWhy = @{ linux = 'capacity module not installed'; windows = 'capacity module not installed' }
    # Per VM profile: $null, or the active generation @{ Id; State; BaseSha256;
    # MemOverheadMib; CloneGib; ScratchGib; IoMbps } (catalog and pin).
    $AapRt.Generation = @{ linux = $null; windows = $null }
    $AapRt.VmChecks = @{ Storage = @(); Host = @{} }
    $AapRt.ChecksAt = [DateTimeOffset]::MinValue
    $AapRt.ChecksLogged = $null
    $AapRt.Steps = @{}
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
    $key = '{0},{1},{2}' -f $Limits.RunnerCount, $Limits.JobCpus, $Limits.JobMemoryGib
    if ($null -ne $Limits.IoPercent) { $key += ",io=$($Limits.IoPercent)" }
    if ($null -ne $Limits.Sharing) { $key += ",sharing=$($Limits.Sharing)" }
    return $key
}

# limits.conf text. The two schema 2 keys only when the settings set them.
function Get-AapLimitsContent($Limits) {
    $c = "AAP_RUNNER_COUNT=$([int]$Limits.RunnerCount)`nAAP_JOB_CPUS=$([int]$Limits.JobCpus)`nAAP_JOB_MEMORY=$([int]$Limits.JobMemoryGib)g`n"
    if ($null -ne $Limits.IoPercent) { $c += "AAP_JOB_IO_PERCENT=$([int]$Limits.IoPercent)`n" }
    if ($Limits.Sharing -ceq 'slice' -or $Limits.Sharing -ceq 'fixed') { $c += "AAP_POOL_SHARING=$($Limits.Sharing)`n" }
    return $c
}

# Manager values for status.json: a string matching Pattern else '', a JSON
# number 0..Max else $null (booleans and strings are not numbers), a time
# as RFC 3339 else $null. The manager writes times as unix seconds; those
# and pwsh 7's DateTime (its ConvertFrom-Json parses date strings) come out
# as UTC. An RFC 3339 string passes through.
function Get-AapMatch($Value, [string]$Pattern) {
    if ($Value -is [string] -and $Value -cmatch $Pattern) { return $Value }
    return ''
}

function Get-AapNumber($Value, [double]$Max) {
    if (($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) -and $Value -ge 0 -and $Value -le $Max) { return [double]$Value }
    return $null
}

function Get-AapTime($Value) {
    if (($Value -is [int] -or $Value -is [long]) -and $Value -gt 0 -and $Value -lt 8589934592) {
        return [DateTimeOffset]::FromUnixTimeSeconds($Value).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [datetime]) {
        if ($Value.Kind -eq [DateTimeKind]::Unspecified) { return $null }
        return $Value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [string] -and $Value -cmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?(Z|[+-]\d{2}:\d{2})\z') { return $Value }
    return $null
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
        $retry = $null
        if ($obj.PSObject.Properties['retry']) { $retry = $obj.retry }
        if (($retry -is [int] -or $retry -is [long]) -and $retry -gt $AapRt.LastRetry) {
            $AapRt.LastRetry = $retry
            Write-AapLog "retry requested ($retry); backoff reset"
            $AapRt.OnFailures = 0
            $AapRt.Failures = 0
            $AapRt.RetryAt = [DateTimeOffset]::MinValue
            $AapRt.NextHealth = [DateTimeOffset]::MinValue
        }
    }
    if ($warn -and $warn -ne $AapRt.LastWarn) { Write-AapLog "WARN $warn; treating as off" }
    $AapRt.LastWarn = $warn
    return $desired
}

# Returns @{ Limits = $null | @{RunnerCount;JobCpus;JobMemoryGib;IoPercent;
# Sharing}; Paused; Profiles; Schema }. Schema 1 and 2: the four keys, plus
# optionally schema (2), io_percent,
# sharing and windows_runner_count; integers (not 1.0, not "1") inside their
# ranges; paused a JSON boolean. Anything else keeps the last valid settings.
# IoPercent and Sharing are $null when absent. windows_runner_count is checked
# and not returned, so it never reaches limits.conf or restarts the manager.
# Profiles is what the allocator gets: for schema 1 and 2 the Linux count,
# Windows 0, even shares, reserve 10. Schema 3 (ConvertFrom-AapSettingsV3) is
# accepted only with the capacity module; a newer schema is refused and kept
# in SettingsWhy for the status detail.
function Read-AapSettingsFile {
    $obj = Read-AapJsonFile 'settings.json'
    $warn = $null
    $newer = $null
    if ($null -eq $obj) {
        $AapRt.Settings = @{ Limits = $null; Paused = $false; Profiles = $null; Schema = $null }
    } elseif ($obj -is [string]) {
        $warn = $obj
    } else {
        $names = @($obj.PSObject.Properties.Name)
        $want = @(@($AapSettingRanges.Keys) + 'paused')
        $optional = @('schema', 'io_percent', 'sharing', 'windows_runner_count')
        $schema = $null
        if ($names -ccontains 'schema') { $schema = $obj.schema }
        $max = 2
        if ($AapRt.Cap) { $max = 3 }
        $whole = ($schema -is [int] -or $schema -is [long])
        if ($whole -and $schema -gt $max) {   # check:settings-newer
            $warn = "settings.json schema $schema is newer than this supervisor accepts ($((1..$max) -join ', '))"
            $newer = $warn
        } elseif ($whole -and $schema -eq 3) {
            $warn = ConvertFrom-AapSettingsV3 $obj
            if ($warn -isnot [string]) {
                $AapRt.Settings = $warn
                $warn = $null
            }
        } elseif (@($want | Where-Object { $names -cnotcontains $_ }).Count -gt 0 -or
            @($names | Where-Object { $want -cnotcontains $_ -and $optional -cnotcontains $_ }).Count -gt 0) {
            $warn = 'settings.json must have runner_count, job_cpus, job_memory_gib, paused and only optionally schema, io_percent, sharing, windows_runner_count'
        } else {
            foreach ($key in $AapSettingRanges.Keys) {
                $v = $obj.$key
                if (-not ($v -is [int] -or $v -is [long]) -or $v -lt 1 -or $v -gt $AapSettingRanges[$key]) {
                    $warn = "settings.json $key must be an integer 1..$($AapSettingRanges[$key])"
                    break
                }
            }
            if (-not $warn -and -not ($obj.paused -is [bool])) { $warn = 'settings.json paused must be true or false' }
            $io = $null
            $sharing = $null
            if (-not $warn -and $names -ccontains 'schema' -and -not ($whole -and $schema -eq 2)) { $warn = 'settings.json schema must be 2' }
            if (-not $warn -and $names -ccontains 'io_percent') {
                $io = $obj.io_percent
                if (-not ($io -is [int] -or $io -is [long]) -or $io -lt 0 -or $io -gt 100) { $warn = 'settings.json io_percent must be an integer 0..100' }
            }
            if (-not $warn -and $names -ccontains 'sharing') {
                $sharing = $obj.sharing
                if (-not ($sharing -is [string] -and ($sharing -ceq 'slice' -or $sharing -ceq 'fixed'))) { $warn = 'settings.json sharing must be "slice" or "fixed"' }
            }
            # Checked so a bad file is caught, then dropped: schema 2 runs no Windows runner.
            if (-not $warn -and $names -ccontains 'windows_runner_count') {
                $win = $obj.windows_runner_count
                if (-not ($win -is [int] -or $win -is [long]) -or $win -lt 0 -or $win + $obj.runner_count -gt 5) { $warn = 'settings.json windows_runner_count must be an integer 0..4, with runner_count at most 5 together' }
            }
            if (-not $warn) {
                if ($null -ne $io) { $io = [int]$io }
                $AapRt.Settings = @{
                    Limits   = @{ RunnerCount = [int]$obj.runner_count; JobCpus = [int]$obj.job_cpus; JobMemoryGib = [int]$obj.job_memory_gib; IoPercent = $io; Sharing = $sharing }
                    Paused   = [bool]$obj.paused
                    Profiles = @{ Linux = [int]$obj.runner_count; Windows = 0; ShareMode = 'even'; LinuxShare = $null; WindowsShare = $null; Reserve = 10; LinuxBackend = 'wsl-legacy'; LeaseHours = 6 }
                    Schema   = $(if ($names -ccontains 'schema') { 2 } else { 1 })
                }
            }
        }
    }
    $AapRt.SettingsWhy = $newer
    if ($warn -and $warn -ne $AapRt.LastSettingsWarn) { Write-AapLog "WARN $warn; keeping the last valid settings" }
    $AapRt.LastSettingsWarn = $warn
    return $AapRt.Settings
}

# Schema 3 (settings-v3.schema.json and its validate.py rules): exactly these
# keys; Linux and Windows 0..5 with 1..5 together; per_profile shares plus
# the reserve are 100 and a share is 0 exactly when its count is; even mode
# has no shares. linux_backend hyperv-vm only while an Ubuntu generation is
# active. Returns the settings, or a warning string.
function ConvertFrom-AapSettingsV3($Obj) {
    $names = @($Obj.PSObject.Properties.Name)
    if (@($AapV3Keys | Where-Object { $names -cnotcontains $_ }).Count -gt 0 -or @($names | Where-Object { $AapV3Keys -cnotcontains $_ }).Count -gt 0) {
        return "settings.json schema 3 must have exactly $($AapV3Keys -join ', ')"
    }
    foreach ($k in @(@('runner_count', 0, 5), @('windows_runner_count', 0, 5), @('job_cpus', 1, 28), @('job_memory_gib', 1, 80),
            @('io_percent', 0, 100), @('host_reserve_percent', 10, 90), @('lease_wall_clock_hours', 1, 72))) {
        $v = $Obj.($k[0])
        if (-not ($v -is [int] -or $v -is [long]) -or $v -lt $k[1] -or $v -gt $k[2]) { return "settings.json $($k[0]) must be an integer $($k[1])..$($k[2])" }
    }
    $linux = [int]$Obj.runner_count
    $windows = [int]$Obj.windows_runner_count
    if ($linux + $windows -lt 1 -or $linux + $windows -gt 5) { return 'settings.json runner_count plus windows_runner_count must be 1..5' }   # check:v3-counts
    if (-not ($Obj.paused -is [bool])) { return 'settings.json paused must be true or false' }
    foreach ($k in @(@('sharing', 'slice', 'fixed'), @('linux_backend', 'wsl-legacy', 'hyperv-vm'), @('share_mode', 'even', 'per_profile'))) {
        $v = $Obj.($k[0])
        if (-not ($v -is [string] -and ($v -ceq $k[1] -or $v -ceq $k[2]))) { return "settings.json $($k[0]) must be `"$($k[1])`" or `"$($k[2])`"" }
    }
    $reserve = [int]$Obj.host_reserve_percent
    $shares = @($Obj.linux_share_percent, $Obj.windows_share_percent)
    if ($Obj.share_mode -ceq 'even') {
        if ($null -ne $shares[0] -or $null -ne $shares[1]) { return 'settings.json share_mode even takes null shares' }   # check:v3-even
    } else {
        foreach ($v in $shares) {
            if (-not ($v -is [int] -or $v -is [long]) -or $v -lt 0 -or $v -gt 90) { return 'settings.json per_profile shares must be integers 0..90' }
        }
        if ($shares[0] + $shares[1] + $reserve -ne 100) { return 'settings.json shares plus host_reserve_percent must be 100' }   # check:v3-reserve
        if (($linux -eq 0) -ne ($shares[0] -eq 0) -or ($windows -eq 0) -ne ($shares[1] -eq 0)) { return 'settings.json a share is 0 exactly when its count is 0' }   # check:v3-zero-share
        $shares = @([int]$shares[0], [int]$shares[1])
    }
    if ($Obj.linux_backend -ceq 'hyperv-vm' -and $null -eq $AapRt.Generation.linux) { return 'settings.json linux_backend hyperv-vm needs an active Ubuntu generation' }   # check:v3-linux-vm
    return @{
        Limits   = @{ RunnerCount = $linux; JobCpus = [int]$Obj.job_cpus; JobMemoryGib = [int]$Obj.job_memory_gib; IoPercent = [int]$Obj.io_percent; Sharing = [string]$Obj.sharing }
        Paused   = [bool]$Obj.paused
        Profiles = @{ Linux = $linux; Windows = $windows; ShareMode = [string]$Obj.share_mode; LinuxShare = $shares[0]; WindowsShare = $shares[1]
            Reserve = $reserve; LinuxBackend = [string]$Obj.linux_backend; LeaseHours = [int]$Obj.lease_wall_clock_hours }
        Schema   = 3
    }
}

function Write-AapStatus {
    param([string]$State, [string]$Job = '', [string]$Detail = '', [string]$Repo = '', [string]$RunUrl = '', $Mirror = $null)
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
        schema             = 4
        sampled_at         = $null
        pool               = [ordered]@{ cpu_cores = $null; mem_gib = $null; io_mbps = $null }
        slots              = @()
        job_io_mbps        = $null
        sharing            = $null
        work_disk_gib      = $null
        work_disk_free_gb  = $null
        work_disk_floor_gb = $null
        cleaning           = $false
    }
    # Pool and slots only while the manager reports them; never while off,
    # paused, starting or in error.
    if ($Mirror -and @('idle', 'running', 'draining') -contains $State) {
        $obj.sampled_at = $Mirror.SampledAt
        $obj.pool = $Mirror.Pool
        $obj.slots = $Mirror.Slots
        $obj.job_io_mbps = $Mirror.JobIoMbps
        $obj.sharing = $Mirror.Sharing
        $obj.work_disk_gib = $Mirror.WorkDiskGib
        $obj.work_disk_free_gb = $Mirror.WorkDiskFreeGb
        $obj.work_disk_floor_gb = $Mirror.WorkDiskFloorGb
        $obj.cleaning = [bool]$Mirror.Cleaning
    }
    if ($eff) {
        $obj.runner_count = $eff.RunnerCount
        $obj.job_cpus = $eff.JobCpus
        $obj.job_memory_gib = $eff.JobMemoryGib
    }
    $prev = $AapRt.Status
    $AapRt.Status = @{ State = $State; Job = $Job; Detail = $Detail; Repo = $Repo; RunUrl = $RunUrl; Mirror = $Mirror }
    $AapRt.StatusAt = $now
    # The legacy heartbeat and adoption read the sample as written here.
    $AapRt.StatusDoc = $obj
    if ($null -eq $prev -or $prev.State -ne $State -or $prev.Job -ne $Job -or $prev.Detail -ne $Detail) {
        Write-AapLog "status $State job=$Job $Detail"
    }
    if ($AapCfg.DryRun) { return }
    Write-AapJsonAtomic 'status.json' $obj
    Write-AapJsonAtomic 'status.v5.json' (Get-AapStatusV5 $State $Detail $Mirror $now)
}

function Write-AapJsonAtomic([string]$Name, $Obj) {
    $path = Join-Path $AapCfg.DataDir $Name
    $tmp = "$path.tmp"
    [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $Obj -Compress -Depth 8), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

# One line of printable ASCII for status.v5.json (its detail and reason patterns).
function Format-AapV5Text([string]$Text, [int]$Max) {
    return Format-AapText ($Text -replace '[^\x20-\x7e]', ' ') $Max
}

# A whole number 0..Max for status.v5.json, else $null; Clamp gives 0..Max instead.
function Get-AapV5Int($Value, [long]$Max, [switch]$Clamp) {
    if ($null -eq $Value -or $Value -is [bool] -or $Value -is [string]) {
        if ($Clamp) { return [long]0 }
        return $null
    }
    $d = [Math]::Floor([double]$Value)
    if ($Clamp) { return [long][Math]::Min([Math]::Max($d, 0), $Max) }
    if ($d -lt 0 -or $d -gt $Max) { return $null }
    return [long]$d
}

# status.v5.json times are UTC with a Z; the mirror's may carry an offset.
function ConvertTo-AapUtcText($Value) {
    if (-not ($Value -is [string])) { return $null }
    $t = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$t)) { return $null }
    return $t.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
}

# A legacy reservation the manager runs (allocator rule 3: admitted).
function Test-AapGranted($R) {
    return (@('creating', 'ready', 'busy') -ccontains $R.state -or ($R.state -ceq 'quarantined' -and $R.quarantine_kind -ceq 'heartbeat'))
}

# One slots[] entry. M is a mirrored manager slot (already checked by
# ConvertFrom-AapManagerStatus) for a legacy slot, else $null.
function New-AapV5Slot([int]$Slot, [string]$Profile, [string]$Backend, [string]$Lifecycle, [string]$Generation, $M) {
    $s = [ordered]@{
        slot = $Slot; profile = $Profile; os = $AapOs[$Profile]; backend = $Backend; lifecycle = $Lifecycle
        image_generation = (Format-AapV5Text $Generation 80); job = ''; repo = ''; run_url = ''; job_url = $null
        started_at = $null; cpu_cores = $null; mem_gib = $null
    }
    if ($M) {
        $s.job = Format-AapText ([string]$M.job -replace '[\x7f\u200e\u200f\u202a-\u202e\u2066-\u2069]', ' ') 200
        $s.repo = [string]$M.repo
        $s.run_url = [string]$M.run_url
        if ($M.job_url) { $s.job_url = [string]$M.job_url }
        $s.started_at = ConvertTo-AapUtcText $M.started_at
        $s.cpu_cores = $M.cpu_cores
        $s.mem_gib = $M.mem_gib
    }
    return $s
}

# The manager's slot state as an allocator lifecycle, while no allocator holds the slots.
function ConvertTo-AapLifecycle([string]$State) {
    switch ($State) {
        'idle' { return 'ready' }
        'running' { return 'busy' }
        'draining' { return 'draining' }
    }
    return 'creating'
}

# One profiles[] entry: from the allocator when it holds the slots, else from
# the settings (and, for the legacy pool, the limits the manager reports).
function New-AapV5Profile([string]$Profile, $Doc, $St, $Live, [string]$StorageState) {
    $set = $AapRt.Settings.Profiles
    $o = [ordered]@{
        profile = $Profile; os = $AapOs[$Profile]; backend = 'none'; count = 0; share_percent = $null
        per_runner = [ordered]@{ cpus = [long]0; mem_gib = [long]0 }; profile_cap = [ordered]@{ cpus = [long]0; mem_gib = [long]0 }
        image_generation = $null; generation_state = $null; cache = [ordered]@{ state = 'unknown'; detail = '' }
        available = $false; unavailable_reason = ''
    }
    if ($Doc) {
        $dp = $Doc.profiles.$Profile
        $sp = $St.Profiles.$Profile
        $o.backend = [string]$dp.backend
        $o.count = [int]$dp.count
        $o.share_percent = Get-AapV5Int $dp.share_percent 90
        $o.per_runner = [ordered]@{ cpus = (Get-AapV5Int $sp.EachCpus 1024 -Clamp); mem_gib = (Get-AapV5Int $sp.EachMemGib 4096 -Clamp) }
        $o.profile_cap = [ordered]@{ cpus = (Get-AapV5Int $sp.CapCpus 1024 -Clamp); mem_gib = (Get-AapV5Int $sp.CapMemGib 4096 -Clamp) }
    } elseif ($Profile -ceq 'linux') {
        $o.backend = 'wsl-legacy'
        $o.count = 1
        $eff = $AapRt.Effective
        if ($set) {
            $o.backend = $set.LinuxBackend
            $o.count = $set.Linux
            $o.share_percent = $set.LinuxShare
        } elseif ($eff -and $eff.RunnerCount -ge 1 -and $eff.RunnerCount -le 5) {
            $o.count = $eff.RunnerCount
        }
        if (-not $AapRt.Cap -and $eff -and $o.count -ge 1) {
            $o.per_runner = [ordered]@{ cpus = (Get-AapV5Int ([Math]::Floor($eff.JobCpus / $o.count)) 1024 -Clamp); mem_gib = (Get-AapV5Int ([Math]::Floor($eff.JobMemoryGib / $o.count)) 4096 -Clamp) }
            $o.profile_cap = [ordered]@{ cpus = (Get-AapV5Int $eff.JobCpus 1024 -Clamp); mem_gib = (Get-AapV5Int $eff.JobMemoryGib 4096 -Clamp) }
        }
    } elseif ($AapRt.Cap) {
        $o.backend = 'hyperv-vm'
        if ($set) {
            $o.count = $set.Windows
            $o.share_percent = $set.WindowsShare
        }
    }
    $mine = @($Live | Where-Object { $_.profile -ceq $Profile -and $_.backend -ceq $o.backend })
    if ($o.backend -ceq 'wsl-legacy') {
        if ($mine.Count) {
            $o.image_generation = [string](@($mine | Sort-Object -Property @{ Expression = { $_.acquired_at } } | Select-Object -Last 1)[0].image_generation)
        } elseif ($o.count -gt 0 -and -not $AapRt.ManagerStopped) {
            $o.image_generation = $AapLegacyGeneration
        }
        if ($o.image_generation) { $o.generation_state = 'active' }
        $o.available = $true
    } elseif ($o.backend -ceq 'hyperv-vm') {
        $active = $null
        if ($Doc) { $active = $Doc.profiles.$Profile.active_generation }
        $gens = @($mine | ForEach-Object { [string]$_.image_generation } | Sort-Object -Unique)
        $g = $AapRt.Generation[$Profile]
        if ($active) { $o.image_generation = [string]$active } elseif ($gens.Count) { $o.image_generation = $gens[0] }
        if ($o.image_generation) {
            # status-settings.md, generation_state: the catalog's verdict on the
            # active generation first, then what the live slots run.
            if (-not $active) {
                $o.generation_state = 'quarantined'
            } elseif ($g -and $g.Id -ceq $active -and @('stale', 'quarantined') -ccontains $g.State) {
                $o.generation_state = [string]$g.State
            } elseif (@($gens | Where-Object { $_ -cne $active }).Count) {
                $o.generation_state = 'draining_old'
            } else {
                $o.generation_state = 'active'
            }
        }
        $o.unavailable_reason = Get-AapVmUnavailable $Profile $Doc $StorageState
        $o.available = -not $o.unavailable_reason
    } else {
        $o.unavailable_reason = $AapRt.VmWhy[$Profile]
    }
    if ($o.image_generation) { $o.image_generation = Format-AapV5Text $o.image_generation 80 }
    $o.unavailable_reason = Format-AapV5Text $o.unavailable_reason 200
    return $o
}

# status.v5.json (parity/contracts/status-v5.schema.json): status.json's state
# and detail, both profiles, the slots of every backend, storage and the legacy
# pool. Built only from values this script already checked, the allocator's
# validated state and the storage document the backends validated.
function Get-AapStatusV5([string]$State, [string]$Detail, $Mirror, [DateTimeOffset]$Now) {
    $mirrored = ($Mirror -and @('idle', 'running', 'draining') -contains $State)
    $mslots = @()
    if ($mirrored) { $mslots = @($Mirror.Slots) }
    $doc = $null
    $st = $null
    if ($AapRt.Cap -and $AapRt.CapReady) {
        $st = Invoke-AapCap 'Get-AapAllocatorState'
        if ($st.Ok) { $doc = $st.State }
    }
    $live = @()
    if ($doc) { $live = @($doc.reservations | Where-Object { $_.state -cne 'reconciled' } | Sort-Object -Property @{ Expression = { [int]$_.slot } }) }
    $slots = New-Object System.Collections.Generic.List[object]
    if ($doc) {
        # Granted legacy reservations, oldest first, are manager slots 1..n
        # (allocator INTEGRATION.md, P16 item 4: accounting, not identity).
        $granted = @($live | Where-Object { $_.backend -ceq 'wsl-legacy' -and (Test-AapGranted $_) } | Sort-Object -Property @{ Expression = { $_.acquired_at } }, @{ Expression = { [int]$_.slot } })
        foreach ($r in $live) {
            $m = $null
            for ($i = 0; $i -lt $granted.Count; $i++) {
                if ($granted[$i].reservation_id -ceq $r.reservation_id) { $m = @($mslots | Where-Object { $_.slot -eq ($i + 1) }) | Select-Object -First 1 }
            }
            $slots.Add((New-AapV5Slot ([int]$r.slot) ([string]$r.profile) ([string]$r.backend) ([string]$r.state) ([string]$r.image_generation) $m))
        }
    } else {
        $n = 0
        foreach ($m in @($mslots | Select-Object -First 5)) {
            $n++
            $slots.Add((New-AapV5Slot $n 'linux' 'wsl-legacy' (ConvertTo-AapLifecycle ([string]$m.state)) $AapLegacyGeneration $m))
        }
    }
    $storage = Get-AapStorageView (Get-AapStorageTiers)
    $profiles = @(foreach ($p in 'linux', 'windows') { New-AapV5Profile $p $doc $st $live $storage.state })
    $v5state = $State
    if ($State -ceq 'idle' -and @($live | Where-Object { $_.backend -ceq 'hyperv-vm' -and $_.state -ceq 'busy' }).Count) { $v5state = 'running' }
    if ($doc) {
        $capacity = [ordered]@{
            max_slots = 5; used_slots = [int]$st.UsedSlots; free_slots = [int]$st.FreeSlots
            host_reserve_percent = [int]$doc.host_reserve_percent; share_mode = [string]$doc.share_mode
            host = [ordered]@{ cpus = (Get-AapV5Int $doc.host.cpu_cores 1024 -Clamp); mem_gib = (Get-AapV5Int $doc.host.mem_gib 4096 -Clamp) }
        }
    } else {
        $h = Get-AapHostInfoCached
        $reserve = 10
        $mode = 'even'
        if ($AapRt.Settings.Profiles) {
            $reserve = $AapRt.Settings.Profiles.Reserve
            $mode = $AapRt.Settings.Profiles.ShareMode
        }
        $capacity = [ordered]@{
            max_slots = 5; used_slots = $slots.Count; free_slots = 5 - $slots.Count; host_reserve_percent = $reserve; share_mode = $mode
            host = [ordered]@{ cpus = (Get-AapV5Int $h.cpu_cores 1024 -Clamp); mem_gib = (Get-AapV5Int $h.mem_gib 4096 -Clamp) }
        }
    }
    $legacy = $null
    if ($profiles[0].backend -ceq 'wsl-legacy') {
        $legacy = [ordered]@{
            runner_count = $null; job_cpus = $null; job_memory_gib = $null; sharing = $null; job_io_mbps = $null
            work_disk_gib = $null; work_disk_free_gb = $null; work_disk_floor_gb = $null; cleaning = $false
        }
        $eff = $AapRt.Effective
        if ($eff -and -not $AapRt.ManagerStopped) {
            $legacy.runner_count = Get-AapV5Int $eff.RunnerCount 5
            $legacy.job_cpus = Get-AapV5Int $eff.JobCpus 1024
            $legacy.job_memory_gib = Get-AapV5Int $eff.JobMemoryGib 4096
        }
        if ($mirrored) {
            $legacy.sharing = $Mirror.Sharing
            $legacy.job_io_mbps = Get-AapV5Int $Mirror.JobIoMbps 1000000
            $legacy.work_disk_gib = Get-AapV5Int $Mirror.WorkDiskGib 1024
            $legacy.work_disk_free_gb = Get-AapV5Int $Mirror.WorkDiskFreeGb 1024
            $legacy.work_disk_floor_gb = Get-AapV5Int $Mirror.WorkDiskFloorGb 1024
            $legacy.cleaning = [bool]$Mirror.Cleaning
        }
    }
    $schemas = @(1, 2)
    if ($AapRt.Cap) { $schemas = @(1, 2, 3) }
    return [ordered]@{
        schema = 5; state = $v5state; updated = $Now.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
        detail = (Format-AapV5Text $Detail 300); settings_schemas = $schemas; applied_settings_schema = $AapRt.Settings.Schema
        capacity = $capacity; profiles = $profiles; slots = $slots.ToArray(); storage = $storage; legacy_pool = $legacy
    }
}

# The one place wsl.exe is started. Arguments are fixed tokens from this
# script (plus the one constant $AapWriteLimits script); the allow-list makes
# a quoting mistake fail instead of reaching wsl.exe. Process is used instead
# of & so stdout, stderr and the exit code come back separately, stdin can
# carry data, and a hung call can be killed. That also avoids the Windows
# PowerShell 5.1 trap where native stderr under Stop becomes a terminating
# error (see ../installer/mount-work-vhdx.ps1). WSL_UTF8=1 makes wsl.exe's own messages
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
# Schema 3 adds sampled_at, pool, slots (an array; at most 5 objects are
# kept), job_io_mbps and sharing; an older manager's slots count gives [].
# Schema 4 adds work_disk_gib, work_disk_free_gb, work_disk_floor_gb and
# cleaning. A manager file without them leaves the sizes null and cleaning false.
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
    $pool = $obj.pool
    if (-not ($pool -is [Management.Automation.PSCustomObject])) { $pool = [pscustomobject]@{} }
    $slots = @()
    if ($obj.slots -is [array]) {
        $slots = @(@($obj.slots | Where-Object { $_ -is [Management.Automation.PSCustomObject] } | Select-Object -First 5) | ForEach-Object {
                $n = $_.slot
                if (-not ($n -is [int] -or $n -is [long]) -or $n -lt 0 -or $n -gt 64) { $n = $null }
                $st = $_.state
                if (-not ($st -is [string] -and $AapSlotStates -ccontains $st)) { $st = '' }
                $job = ''
                if ($_.job -is [string]) { $job = Format-AapText $_.job 128 }
                [ordered]@{
                    slot       = $n
                    state      = $st
                    job        = $job
                    repo       = Get-AapMatch $_.repo $AapRepoPattern
                    run_url    = Get-AapMatch $_.run_url $AapRunUrlPattern
                    job_url    = Get-AapMatch $_.job_url $AapJobUrlPattern
                    started_at = Get-AapTime $_.started_at
                    cpu_cores  = Get-AapNumber $_.cpu_cores 1024
                    mem_gib    = Get-AapNumber $_.mem_gib 4096
                }
            })
    }
    $sharing = $obj.sharing
    if (-not ($sharing -is [string] -and ($sharing -ceq 'slice' -or $sharing -ceq 'fixed'))) { $sharing = $null }
    $cleaning = $false
    if ($obj.cleaning -is [bool] -and $obj.cleaning) { $cleaning = $true }
    return @{
        State     = $state
        Job       = [string]$obj.job
        Limits    = $limits
        Repo      = Get-AapMatch $obj.repo $AapRepoPattern
        RunUrl    = Get-AapMatch $obj.run_url $AapRunUrlPattern
        SampledAt = Get-AapTime $obj.sampled_at
        Pool      = [ordered]@{
            cpu_cores = Get-AapNumber $pool.cpu_cores 1024
            mem_gib   = Get-AapNumber $pool.mem_gib 4096
            io_mbps   = Get-AapNumber $pool.io_mbps 1048576
        }
        Slots     = $slots
        JobIoMbps       = Get-AapNumber $obj.job_io_mbps 1048576
        Sharing         = $sharing
        WorkDiskGib     = Get-AapNumber $obj.work_disk_gib 1024
        WorkDiskFreeGb  = Get-AapNumber $obj.work_disk_free_gb 1024
        WorkDiskFloorGb = Get-AapNumber $obj.work_disk_floor_gb 1024
        Cleaning        = $cleaning
    }
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
        # A drain can take hours; the VM slots keep their heartbeats, and a
        # Pause or a lower count reaches them meanwhile (nothing is admitted).
        if ($AapRt.CapReady) {
            $s = Read-AapSettingsFile
            if ($s.Paused) { Invoke-AapVmDrain }   # check:wait-pause
            [void](Set-AapCounts $s)
        }
        Invoke-AapVmSteps
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
    [void](Read-AapSettingsFile)
    if (Test-AapLegacyWanted) {
        if (Test-AapManagerFlag) {
            $r = Invoke-AapRoot @($AapManager, '--undrain')
            if ($r.Code -ne 0) { Write-AapLog "undrain exit $($r.Code): $(Format-AapText $r.Err)" }
        }
        # systemctl is safe on the old manager too.
        [void](Invoke-AapUnitStart @('sysbox', 'aap-runner-manager'))
    } else {
        # Linux 0 (or Linux on VMs): the distro runs for the broker; the
        # manager is never started, and one a previous run left is drained.
        [void](Invoke-AapUnitStart @('sysbox'))
        if (Test-AapManagerFlag) { Invoke-AapManagerStop }
    }
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
    $stopped = ($AapRt.Paused -or $AapRt.ManagerStopped)
    if ($sysbox -eq 'active' -and ($stopped -or $manager -eq 'active')) {
        if ($null -eq $AapRt.HealthySince) {
            $AapRt.HealthySince = $now
        } elseif ($AapRt.Failures -gt 0 -and ($now - $AapRt.HealthySince).TotalSeconds -ge $AapCfg.HealthyResetSeconds) {
            Write-AapLog "healthy for $($AapCfg.HealthyResetSeconds) s; backoff reset"
            $AapRt.Failures = 0
        }
        $detail = Get-AapDetail
        if ($AapRt.ManagerOk -eq $false) {
            Write-AapStatus 'error' '' $AapOldManager
        } elseif ($AapRt.CapError) {
            Write-AapStatus 'error' '' $detail
        } elseif ($AapRt.Paused) {
            Write-AapStatus 'paused' '' $detail
        } elseif ($AapRt.ManagerStopped) {
            Write-AapStatus 'idle' '' $detail
        } elseif ($m -and $m.State) {
            Write-AapStatus $m.State $m.Job $detail $m.Repo $m.RunUrl $m
            # The legacy heartbeat reads the sample just written (allocator INTEGRATION.md, P12 item 4).
            if ($AapRt.Cap -and $AapRt.CapReady) { [void](Invoke-AapCap 'Update-AapHeartbeat' @{ ManagerStatus = $AapRt.StatusDoc }) }
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
    if (-not $stopped) { [void](Invoke-AapUnitStart @('aap-runner-manager')) }
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
    if (-not $AapRt.ManagerStopped) { Start-AapManager }
    $AapRt.Paused = $false
    $AapRt.NextHealth = [DateTimeOffset]::MinValue
}

# Write limits.conf, let the manager validate it, then restart the manager
# between jobs (drain, wait, undrain, start). A refused file is replaced by
# the previous content (or removed if there was none) and not retried until
# settings.json changes. After a supervisor start (nothing applied yet) a
# limits.conf that already holds exactly this content counts as applied: the
# manager the On sequence started has read it.
function Invoke-AapLimitChange($Limits) {
    $key = Get-AapLimitsKey $Limits
    $content = Get-AapLimitsContent $Limits
    $prev = Invoke-AapRoot @('/bin/cat', $AapLimitsFile)
    if ($null -eq $AapRt.Applied -and $prev.Code -eq 0 -and $prev.Out -ceq $content) {
        $AapRt.Applied = $key
        Write-AapLog "limits.conf already has $key"
        return
    }
    Write-AapLog "applying limits $key"
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
    if ($AapRt.Paused -or $AapRt.ManagerStopped) {
        $AapRt.Applied = $key
        Write-AapLog 'manager stopped; it picks up the limits when it starts'
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
        # Pause covers the whole pool: no admission, and the VM slots drain too.
        Invoke-AapVmDrain
        if ((Invoke-AapPause) -eq 'aborted') { return }
    } elseif (-not $s.Paused -and $AapRt.Paused) {
        Invoke-AapResume
    }
    if ($AapRt.Cap) {
        Sync-AapCapacity $s
        return
    }
    Set-AapLimits $s.Limits
}

function Set-AapLimits($Limits) {
    $key = Get-AapLimitsKey $Limits
    if ($null -eq $key -or $key -eq $AapRt.Applied -or $key -eq $AapRt.Refused) { return }
    if ($null -eq $AapRt.Applied -and $key -eq (Get-AapLimitsKey $AapRt.Effective)) {
        $AapRt.Applied = $key
        return
    }
    Invoke-AapLimitChange $Limits
}

# ---- capacity: the P09 allocator, the legacy pool and the VM backends ----
# (supervisor\capacity\INTEGRATION.md and backends\*\INTEGRATION.md, the P12
# items). Every allocator call goes through Invoke-AapCap.

# Code the elevated supervisor imports must be admin-only: owned by SYSTEM,
# Administrators or TrustedInstaller, no reparse point, and no ACE that lets
# anyone else write, delete, re-permission or take ownership (the folder and
# everything below it: the modules import each other by relative path). The
# folders above it, up to the drive root, follow install-supervisor.ps1's
# Get-AapAncestorProblem: no reparse point, an admin owner, and nobody else
# may delete, delete children, re-permission or take ownership (creating
# folders is allowed, as C:\ grants it). Returns the problems, empty = trusted.
function Get-AapCodeProblem([string]$Dir) {
    $admins = @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    # write data, append, write EA, delete child, write attributes, delete,
    # change permissions, take ownership, generic all, generic write
    $writes = 0x2 -bor 0x4 -bor 0x10 -bor 0x40 -bor 0x100 -bor 0x10000 -bor 0x40000 -bor 0x80000 -bor 0x10000000 -bor 0x40000000
    # delete child, delete, change permissions, take ownership, generic all
    $moves = 0x40 -bor 0x10000 -bor 0x40000 -bor 0x80000 -bor 0x10000000
    $out = New-Object System.Collections.Generic.List[string]
    $todo = New-Object System.Collections.Generic.List[string]
    $todo.Add($Dir)
    for ($i = 0; $i -lt $todo.Count; $i++) {
        $p = $todo[$i]
        $item = Get-Item -LiteralPath $p -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { $out.Add("reparse point: $p"); continue }   # check:code-reparse
        $acl = Get-Acl -LiteralPath $p
        $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
        if ($admins -notcontains $owner) { $out.Add("owner $owner is not an admin: $p") }   # check:code-owner
        foreach ($ace in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
            if ($ace.AccessControlType -ne 'Allow' -or ($ace.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly)) { continue }
            if ($admins -notcontains $ace.IdentityReference.Value -and ([long]$ace.FileSystemRights -band [long]$writes)) { $out.Add("$($ace.IdentityReference.Value) may write: $p") }   # check:code-write
        }
        if ($item.PSIsContainer) { foreach ($c in [IO.Directory]::GetFileSystemEntries($p)) { $todo.Add($c) } }   # check:code-tree
    }
    $up = Split-Path -Parent $Dir
    while ($up) {
        $item = Get-Item -LiteralPath $up -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            $out.Add("ancestor ${up}: reparse point")
        } else {
            $acl = Get-Acl -LiteralPath $up
            $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
            if ($admins -notcontains $owner) { $out.Add("ancestor ${up}: owner $owner is not an admin") }   # check:code-ancestor
            foreach ($ace in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
                if ($ace.AccessControlType -ne 'Allow' -or ($ace.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly)) { continue }
                if ($admins -notcontains $ace.IdentityReference.Value -and ([long]$ace.FileSystemRights -band [long]$moves)) { $out.Add("ancestor ${up}: $($ace.IdentityReference.Value) may replace it") }
            }
        }
        $up = Split-Path -Parent $up
    }
    return $out.ToArray()
}

# What is deployed beside this script (P19 deploys capacity\, broker\,
# backends\ and network\, admin-only). Without capacity\ this stays the
# schema 2 supervisor. A VM profile also needs its backend module, the P10.0
# host network module and an approved active generation (catalog reader P21,
# approved-images.json pins P24): none of the last three exists yet, so no
# backend context is built and the VM profiles report why. When they land,
# one context per profile, New-Aap<Kind>Backend -Provider
# (New-Aap<Kind>HyperVProvider) -Network <module>, fills $AapRt.Vm and the
# active generation fills $AapRt.Generation.
function Initialize-AapProviders {
    $dir = Join-Path $AapCfg.ModuleDir 'capacity'
    if (-not [IO.File]::Exists((Join-Path $dir 'AapCapacity.psm1'))) {
        Write-AapLog 'capacity module not installed: legacy pool only, settings schema 1 and 2'
        return
    }
    $problems = @(Get-AapCodeProblem $AapCfg.ModuleDir)
    if ($problems.Count) {   # check:code-trusted
        Write-AapLog "WARN capacity module not loaded, the supervisor folder is not admin-only: $(Format-AapText ($problems -join '; ') 600)"
        return
    }
    try {
        Import-Module -Name (Join-Path $dir 'AapCapacity.psm1') -Force -Global -ErrorAction Stop
    } catch {
        Write-AapLog "WARN capacity module not loaded: $(Format-AapText $_.Exception.Message 300); legacy pool only"
        return
    }
    $AapRt.Cap = $true
    $AapRt.CapRoot = Join-Path $AapCfg.DataDir 'capacity'
    foreach ($p in 'windows', 'linux') {
        if ([IO.File]::Exists((Join-Path $AapCfg.ModuleDir "backends\$($AapVmFolders[$p])\Aap$($AapVmKinds[$p])Backend.psm1"))) {
            $AapRt.VmWhy[$p] = 'the host network module (P10.0) is not installed'
        } else {
            $AapRt.VmWhy[$p] = "the $($AapOs[$p]) VM backend is not installed"
        }
    }
    Write-AapLog "capacity module loaded; VM profiles: windows: $($AapRt.VmWhy.windows); linux: $($AapRt.VmWhy.linux)"
}

# One allocator call with the capacity folder (and CapArgs, which only tests
# fill). An error makes the supervisor state error until Sync-AapCapacity
# reads the state again; each new refusal or error is logged once.
function Invoke-AapCap([string]$Name, [hashtable]$Params = @{}) {
    $extra = $AapRt.CapArgs
    try {
        $r = & $Name -Root $AapRt.CapRoot @Params @extra
    } catch {
        $r = [pscustomobject]@{ Ok = $false; Status = 'error'; Reason = 'failed'; Detail = $_.Exception.Message }
    }
    if (-not $r.Ok) {
        $line = "$Name $($r.Status) $($r.Reason): $(Format-AapText $r.Detail 300)"
        if ($line -cne $AapRt.CapLogged[$Name]) { Write-AapLog "allocator $line" }
        $AapRt.CapLogged[$Name] = $line
    }
    if ($r.Status -ceq 'error') { $AapRt.CapError = "allocator $($r.Reason): $(Format-AapText $r.Detail 200)" }
    return $r
}

# The host the allocator divides (allocator.md, host): logical CPUs, RAM, the
# control VM, and the volumes of a trusted storage layout. IO stays 0 until it
# is measured (P22), and the allocator admits no VM before that.
function Get-AapHostInfo($Doc = $null) {
    $mem = 0
    try { $mem = [long][Math]::Floor((Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory / 1GB) } catch { Write-AapLog "WARN host memory unreadable: $(Format-AapText $_.Exception.Message)" }
    return [ordered]@{
        cpu_cores = [long][Environment]::ProcessorCount; mem_gib = $mem; volumes = @(Get-AapHostVolumes $Doc)
        io_mbps = [long]0; control_distro_mem_gib = [long]$AapCfg.ControlDistroMemGib
    }
}

function Get-AapHostInfoCached {
    if ($null -eq $AapRt.HostInfo) { $AapRt.HostInfo = Get-AapHostInfo }
    return $AapRt.HostInfo
}

function Get-AapFreeGib([string]$Path) {
    try { return [long][Math]::Floor((New-Object IO.DriveInfo([IO.Path]::GetPathRoot($Path))).AvailableFreeSpace / 1GB) } catch { return $null }
}

function Get-AapAnyVm {
    if ($AapRt.Vm.windows) { return $AapRt.Vm.windows }
    return $AapRt.Vm.linux
}

# A backend's problem line as a storage detail code (status-settings.md); the
# full line goes to the log only.
function ConvertTo-AapStorageCode([string]$Line) {
    if ($Line -match 'reparse') { return 'reparse' }
    if ($Line -match 'does not exist') { return 'missing' }
    if ($Line -match 'owner') { return 'owner' }
    if ($Line -match 'volume') { return 'volume' }
    if ($Line -match 'fixed local drive|normalized') { return 'drive-type' }
    if ($Line -match 'ancestor|above') { return 'ancestor' }
    return 'acl'
}

# The storage tiers (backend-lifecycle.md, Storage tiers) from the storage
# document the backends validated: $null while no backend context has one,
# else the floor and four tiers with root, volume GUID, free GiB and state.
# Trust problems are the backends' (Update-AapVmChecks). Staging is P03's
# (created on demand under base_root): only its volume's free space counts.
function Get-AapStorageTiers {
    $vm = Get-AapAnyVm
    if (-not $vm) { return $null }
    $s = $vm.B.Storage
    $floor = [long]$s.FloorGib
    $tiers = foreach ($t in 'base', 'clone', 'scratch', 'staging') {
        $src = $t
        if ($t -ceq 'staging') { $src = 'base' }
        $root = $s["${src}_root"].Path
        $state = 'ok'
        $code = ''
        $free = $null
        $problems = @($AapRt.VmChecks.Storage | Where-Object { $_.StartsWith("${src}_root: ", [StringComparison]::Ordinal) })
        if (-not [IO.Directory]::Exists($root)) {
            $state = 'missing'
            $code = 'missing'
        } else {
            $free = Get-AapFreeGib $root
            if ($t -cne 'staging' -and $problems.Count) {
                $state = 'untrusted'
                $code = ConvertTo-AapStorageCode $problems[0]
            } elseif ($null -eq $free) {
                $state = 'untrusted'
                $code = 'volume'
            } elseif ($free -lt $floor) {
                $state = 'low'
                $code = 'low'
            }
        }
        if ($t -ceq 'staging') { $root = Join-Path $root 'staging' }
        @{ Tier = $t; Root = $root; Guid = $s["${src}_root"].Guid; Free = $free; State = $state; Code = $code }
    }
    return @{ Floor = $floor; Tiers = @($tiers) }
}

# storage in status.v5.json: unconfigured without a storage document; else the
# floor, all four tiers and the worst tier state. The detail has fixed codes.
function Get-AapStorageView($Tiers) {
    if (-not $Tiers) { return [ordered]@{ state = 'unconfigured'; detail = ''; volume_floor_gib = $null; tiers = @() } }
    $states = @($Tiers.Tiers | ForEach-Object { $_.State })
    $worst = 'ok'
    foreach ($w in 'low', 'untrusted', 'missing') { if ($states -ccontains $w) { $worst = $w } }
    return [ordered]@{
        state = $worst
        detail = (@($Tiers.Tiers | Where-Object { $_.Code } | ForEach-Object { "$($_.Tier): $($_.Code)" }) -join '; ')
        volume_floor_gib = [long][Math]::Min([Math]::Max($Tiers.Floor, 10), 4096)
        tiers = @($Tiers.Tiers | ForEach-Object {
                $free = $null
                if ($null -ne $_.Free) { $free = [long][Math]::Min($_.Free, 1048576) }
                [ordered]@{ tier = $_.Tier; root = $_.Root; volume_free_gib = $free; state = $_.State }
            })
    }
}

# host.volumes for the allocator: one entry per volume holding the base, clone
# or scratch tier, only while every tier is ok (else none: no VM admission).
# available_gib is the free space plus the caps live VM slots already hold there.
function Get-AapHostVolumes($Doc) {
    $t = Get-AapStorageTiers
    if (-not $t -or (Get-AapStorageView $t).state -cne 'ok') { return @() }
    $live = @()
    if ($Doc) { $live = @($Doc.reservations | Where-Object { $_.backend -ceq 'hyperv-vm' -and $_.state -cne 'reconciled' }) }
    # Tiers by volume, in tier order (Group-Object cannot read hashtable keys on 5.1).
    $byGuid = [ordered]@{}
    foreach ($tier in @($t.Tiers | Where-Object { $_.Tier -cne 'staging' })) {
        if (-not $byGuid.Contains($tier.Guid)) { $byGuid[$tier.Guid] = New-Object System.Collections.Generic.List[object] }
        $byGuid[$tier.Guid].Add($tier)
    }
    $out = foreach ($guid in @($byGuid.Keys)) {
        $names = @($byGuid[$guid] | ForEach-Object { $_.Tier })
        $held = [long]0
        foreach ($r in $live) {
            if ($names -ccontains 'clone') { $held += [long]$r.clone_gib }
            if ($names -ccontains 'scratch') { $held += [long]$r.scratch_gib }
        }
        [ordered]@{ volume_guid = $guid; tiers = $names; available_gib = [long]$byGuid[$guid][0].Free + $held; floor_gib = $t.Floor; held_gib = [long]0 }
    }
    return @($out)
}

# The VM profiles' storage and host problems (backends\*\INTEGRATION.md, P12
# items 3 and 5), at start and every HealthSeconds; a new list is logged in full.
function Update-AapVmChecks {
    $AapRt.ChecksAt = (Get-AapNow).AddSeconds($AapCfg.HealthSeconds)
    $checks = @{ Storage = @(); Host = @{} }
    $vm = Get-AapAnyVm
    if ($vm) {
        try { $checks.Storage = @(& "Get-Aap$($vm.Kind)StorageProblem" -Backend $vm.B) } catch { $checks.Storage = @("base_root: cannot be checked: $($_.Exception.Message)") }
        foreach ($p in 'windows', 'linux') {
            $v = $AapRt.Vm[$p]
            if (-not $v) { continue }
            try { $checks.Host[$p] = @(& "Get-Aap$($v.Kind)HostProblem" -Backend $v.B) } catch { $checks.Host[$p] = @("AAP_HostUnreadable: $($_.Exception.Message)") }
        }
    }
    $line = Format-AapText ((@($checks.Storage) + @($checks.Host.Values | ForEach-Object { $_ })) -join '; ') 1000
    if ($line -ne $AapRt.ChecksLogged -and $line) { Write-AapLog "VM storage and host problems: $line" }
    $AapRt.ChecksLogged = $line
    $AapRt.VmChecks = $checks
}

# Why a VM profile admits nothing, or '' (backends\*\INTEGRATION.md, P12
# item 5; status-settings.md: unavailable while storage is not ok).
function Get-AapVmUnavailable([string]$Profile, $Doc, [string]$StorageState) {
    if (-not $AapRt.Vm[$Profile]) { return [string]$AapRt.VmWhy[$Profile] }
    if ($StorageState -cne 'ok') { return "storage is $StorageState" }   # check:vm-storage
    $hp = @($AapRt.VmChecks.Host[$Profile])
    if ($hp.Count) { return [string]$hp[0] }   # check:vm-host
    $g = $AapRt.Generation[$Profile]
    if (-not $g -or $g.State -ceq 'quarantined') { return 'no approved active generation' }   # check:vm-generation
    if ($Doc -and [long]$Doc.host.io_mbps -eq 0) { return 'host IO is not measured yet' }
    return ''
}

# The active generation the allocator records for a profile; a quarantined one
# admits nothing (status-settings.md, generation_state).
function Get-AapActiveId([string]$Profile) {
    $g = $AapRt.Generation[$Profile]
    if ($g -and $g.State -cne 'quarantined') { return [string]$g.Id }
    return $null
}

function Get-AapVmInventory {
    $vm = Get-AapAnyVm
    return (& "Get-Aap$($vm.Kind)Inventory" -Backend $vm.B)
}

function Get-AapVmBrokerStatus($R) {
    $vm = $AapRt.Vm[[string]$R.profile]
    if (-not $vm) { return $null }
    return (& "Get-Aap$($vm.Kind)BrokerStatus" -Backend $vm.B -Reservation $R)
}

# The Linux runners the legacy manager should run: none for Linux 0 or Linux
# on VMs (only known with the allocator and settings).
function Test-AapLegacyWanted {
    $p = $AapRt.Settings.Profiles
    return -not ($AapRt.Cap -and $p -and ($p.Linux -eq 0 -or $p.LinuxBackend -ceq 'hyperv-vm'))
}

# The status detail: an allocator hold-back first (its reason word leads,
# status-settings.md), an allocator error, a refused limits file, a refused
# settings file, VM slots past the lease wall clock, the stopped legacy pool.
function Get-AapDetail {
    $parts = @($AapRt.CapWhy, $AapRt.HoldWhy, $AapRt.CapError, $AapRt.RefusedWhy, $AapRt.SettingsWhy) + @($AapRt.CapFlags)
    if ($AapRt.ManagerStopped) { $parts += 'legacy pool stopped: no Linux slot is granted' }
    return (@($parts | Where-Object { $_ }) -join '; ')
}

# A new host measurement when it differs from the stored one, and always
# before a VM admission (-Force): free space is measured at admission. Returns
# the refusal (pool_over_live, storage_low) for the status detail, or $null.
function Update-AapHostMeasurement([switch]$Force) {
    $st = Invoke-AapCap 'Get-AapAllocatorState'
    if (-not $st.Ok) { return $null }
    $info = Get-AapHostInfo $st.State
    $h = $st.State.host
    $same = ([long]$h.cpu_cores -eq $info.cpu_cores -and [long]$h.mem_gib -eq $info.mem_gib -and [long]$h.io_mbps -eq $info.io_mbps -and
        [long]$h.control_distro_mem_gib -eq $info.control_distro_mem_gib -and (ConvertTo-Json @($h.volumes) -Compress -Depth 4) -ceq (ConvertTo-Json @($info.volumes) -Compress -Depth 4))
    if ($same -and -not $Force) { return $null }
    $r = Invoke-AapCap 'Set-AapHostMeasurement' @{ HostInfo = $info }
    if ($r.Status -ceq 'refused') { return "$($r.Reason): $($r.Detail)" }
    return $null
}

# At start and every ReconcileSeconds: the host measurement, then reconcile
# with the VM inventory and the broker's read-only runner status. The flags
# (VM slots past the lease wall clock) go to the detail; destroy and replay
# actions are carried out by the next step of each named reservation.
function Invoke-AapCapReconcile($s) {
    [void](Update-AapHostMeasurement)
    $a = @{}
    if ($s.Profiles) { $a.LeaseWallClockHours = $s.Profiles.LeaseHours }
    if (Get-AapAnyVm) {
        $a.Inventory = { Get-AapVmInventory }
        $a.BrokerStatus = { param($r) Get-AapVmBrokerStatus $r }
    }
    $r = Invoke-AapCap 'Invoke-AapReconcile' $a
    if ($r.Ok) {
        $AapRt.CapFlags = @($r.Flags)
        if ($r.Status -ceq 'ok') { Write-AapLog "reconcile: $(Format-AapText $r.Detail 600)" }
    }
}

# At the first tick of an On session: create the allocator state once (never
# over an existing or a lost one), then reconcile before any admission, so a
# reservation a crashed predecessor persisted is never counted twice.
function Initialize-AapCapacity($s) {
    if ($AapRt.CapReady) { return $true }
    $init = @{ HostInfo = (Get-AapHostInfo) }
    $p = $s.Profiles
    if ($p) {
        $init += @{ Linux = $p.Linux; Windows = $p.Windows; ShareMode = $p.ShareMode; LinuxShare = $p.LinuxShare; WindowsShare = $p.WindowsShare
            HostReservePercent = $p.Reserve; LinuxBackend = $p.LinuxBackend }
    } elseif ($AapRt.Effective -and $AapRt.Effective.RunnerCount -ge 1 -and $AapRt.Effective.RunnerCount -le 5) {
        $init.Linux = $AapRt.Effective.RunnerCount
    }
    $r = Invoke-AapCap 'Initialize-AapAllocator' $init
    if (-not $r.Ok) { return $false }
    $AapRt.CapError = $null
    Update-AapVmChecks
    Invoke-AapCapReconcile $s
    $AapRt.ReconcileAt = (Get-AapNow).AddSeconds($AapCfg.ReconcileSeconds)
    $AapRt.CapReady = $true
    return $true
}

# The allocator's tick while On: the two counts and the shares, admission
# (never while paused, never before the legacy pool is adopted), limits.conf
# from the legacy grants, and one step for every VM slot.
function Sync-AapCapacity($s) {
    if (-not (Initialize-AapCapacity $s)) { return }
    $AapRt.CapError = $null
    $now = Get-AapNow
    if ($now -ge $AapRt.ChecksAt) { Update-AapVmChecks }
    if ($now -ge $AapRt.ReconcileAt) {
        $AapRt.ReconcileAt = $now.AddSeconds($AapCfg.ReconcileSeconds)
        Invoke-AapCapReconcile $s
    }
    $why = Set-AapCounts $s
    $st = Invoke-AapCap 'Get-AapAllocatorState'
    if (-not $st.Ok) { return }
    if ($AapRt.Paused) { Invoke-AapVmDrain }
    $admit = $true
    if ($AapRt.Paused -or -not $st.State.legacy_adopted) { $admit = $false }   # check:admit-after-adoption
    if ($admit) {
        $w = Grant-AapSlots $s $st
        if (-not $why) { $why = $w }
    }
    Sync-AapLegacyPool $s
    $AapRt.CapWhy = $why
    Invoke-AapVmSteps
}

# The two counts and the shares. A smaller count drains (never cancels a
# job); resize_waits and pool_over_live keep the last applied settings and
# are returned for the detail, else $null.
function Set-AapCounts($s) {
    $p = $s.Profiles
    if (-not $p) { return $null }
    $r = Invoke-AapCap 'Set-AapProfileCounts' @{ Linux = $p.Linux; Windows = $p.Windows; ShareMode = $p.ShareMode; LinuxShare = $p.LinuxShare
        WindowsShare = $p.WindowsShare; HostReservePercent = $p.Reserve; LinuxBackend = $p.LinuxBackend
        LinuxGeneration = (Get-AapActiveId 'linux'); WindowsGeneration = (Get-AapActiveId 'windows')
    }
    if ($r.Status -ceq 'ok' -and (@($r.Drained).Count -or @($r.Cancelled).Count)) { Write-AapLog "resize: draining [$(@($r.Drained) -join ',')] cancelled [$(@($r.Cancelled) -join ',')]" }
    if ($r.Status -ceq 'refused') { return "$($r.Reason): $($r.Detail)" }
    return $null
}

# Admission (allocator INTEGRATION.md, P12 item 5): legacy slots at the next
# grant's size up to the Linux count, then at most one VM per VM profile per
# tick on its active generation's measured budget while it is available.
# Returns the first refusal for the detail, or $null.
function Grant-AapSlots($s, $St) {
    $doc = $St.State
    $why = $null
    $lp = $St.Profiles.linux
    if ($doc.profiles.linux.backend -ceq 'wsl-legacy' -and $lp.Admitted -lt $lp.Count) {
        $L = Invoke-AapCap 'Get-AapLegacyLimits' (Get-AapLegacyCaps $s)
        for ($i = $lp.Admitted; $L.Ok -and $i -lt $lp.Count; $i++) {
            $r = Invoke-AapCap 'Request-AapReservation' @{ Profile = 'linux'; Cpus = $L.NextSlotCpus; MemGib = $L.NextSlotMemGib; ImageGeneration = $AapLegacyGeneration }
            if (-not $r.Ok) {
                $why = "$($r.Reason): $($r.Detail)"
                break
            }
            Write-AapLog "granted legacy slot $($r.Reservation.slot) ($($r.Reservation.reservation_id)) of $($L.NextSlotCpus) CPUs and $($L.NextSlotMemGib) GiB"
        }
    }
    $storage = (Get-AapStorageView (Get-AapStorageTiers)).state
    foreach ($p in 'windows', 'linux') {
        $vp = $St.Profiles.$p
        if ($doc.profiles.$p.backend -cne 'hyperv-vm' -or $vp.Admitted -ge $vp.Count) { continue }
        if (Get-AapVmUnavailable $p $doc $storage) { continue }   # check:vm-admit
        $w = Update-AapHostMeasurement -Force
        if ($w) {
            if (-not $why) { $why = $w }
            continue
        }
        $g = $AapRt.Generation[$p]
        $r = Invoke-AapCap 'Request-AapReservation' @{ Profile = $p; MemOverheadMib = $g.MemOverheadMib; CloneGib = $g.CloneGib; ScratchGib = $g.ScratchGib; IoMbps = $g.IoMbps; ImageGeneration = [string]$g.Id }
        if ($r.Ok) {
            Write-AapLog "admitted $p VM slot $($r.Reservation.slot) ($($r.Reservation.reservation_id)) as $($r.VmName)"
        } elseif (-not $why) {
            $why = "$($r.Reason): $($r.Detail)"
        }
    }
    return $why
}

# limits.conf follows the allocator (allocator.md, Legacy adoption and Linux
# 0). Before adoption the manager keeps its own limits unless adoption is
# refused with a Target. After it, RunnerCount is the granted legacy slots and
# the totals their sums, never above the settings (shares win, the settings
# stay the maximum). No granted slot: drain and stop the manager, never a
# limits.conf with 0, and release the slots that left.
function Sync-AapLegacyPool($s) {
    $AapRt.HoldWhy = $null
    $lim = $s.Limits
    $caps = Get-AapLegacyCaps $s
    $L = Invoke-AapCap 'Get-AapLegacyLimits' $caps
    if (-not $L.Ok) { return }
    if ($L.Stop) {   # check:legacy-stop
        if (-not $AapRt.ManagerStopped) { Invoke-AapManagerStop }
        if ($AapRt.ManagerStopped -and -not $L.Adopted) { [void](Invoke-AapCap 'Register-AapLegacySlots' @{ ManagerStopped = $true }) }
        return
    }
    if (-not $L.Adopted) {
        if ($AapRt.ManagerStopped) {
            # A stopped pool has no slot to adopt; the next tick grants them.
            [void](Invoke-AapCap 'Register-AapLegacySlots' @{ ManagerStopped = $true })
            return
        }
        $a = Invoke-AapCap 'Register-AapLegacySlots' @{ ManagerStatus = $AapRt.StatusDoc }
        if ($a.Ok) { Write-AapLog "legacy pool adopted: $(Format-AapText $a.Detail)" }
        # Too big for the Linux profile: shrink it to Target, adopt next time.
        if ($a.Status -cne 'refused' -or [string]$a.Reason -notlike 'legacy_over_*') { return }   # check:adopt-target
        $target = $a.Target
    } else {
        $target = $L
    }
    $limits = @{ RunnerCount = [int]$target.RunnerCount; JobCpus = [int]$target.JobCpus; JobMemoryGib = [int]$target.JobMemoryGib; IoPercent = $null; Sharing = $null }
    if ($caps.Count) {
        if ($caps.JobCpus -lt $limits.JobCpus) { $limits.JobCpus = $caps.JobCpus }   # check:settings-max
        if ($caps.JobMemoryGib -lt $limits.JobMemoryGib) { $limits.JobMemoryGib = $caps.JobMemoryGib }   # check:settings-max
    }
    if ($lim) {
        $limits.IoPercent = $lim.IoPercent
        $limits.Sharing = $lim.Sharing
    }
    if ($limits.RunnerCount -lt 1) { return }
    # Raised totals reach a legacy slot only with its next grant.
    if ($L.Adopted -and ($limits.JobCpus -lt $L.NextSlotCpus * $limits.RunnerCount -or $limits.JobMemoryGib -lt $L.NextSlotMemGib * $limits.RunnerCount)) {
        $AapRt.HoldWhy = "grant_waits: the legacy slots keep $($limits.JobCpus) CPUs and $($limits.JobMemoryGib) GiB until they are granted again"
    }
    Set-AapLimits $limits
    if ($AapRt.ManagerStopped -and -not $AapRt.Paused -and $AapRt.Applied -eq (Get-AapLimitsKey $limits)) { Start-AapManager }
}

# The most the legacy totals may be: the settings' totals, or with no
# settings.json (no override) the limits the manager runs.
function Get-AapLegacyCaps($s) {
    $from = $s.Limits
    if (-not $from) { $from = $AapRt.Effective }   # check:keep-manager-limits
    if (-not $from) { return @{} }
    return @{ JobCpus = $from.JobCpus; JobMemoryGib = $from.JobMemoryGib }
}

function Start-AapManager {
    Write-AapLog 'starting the manager'
    [void](Invoke-AapRoot @($AapManager, '--undrain'))
    [void](Invoke-AapUnitStart @('aap-runner-manager'))
    $AapRt.ManagerStopped = $false
    $AapRt.NextHealth = [DateTimeOffset]::MinValue
}

# No legacy slot is granted (Linux 0, or Linux on VMs): drain the manager, let
# its jobs finish, and keep it stopped. The distro, sysbox and the keep-alive
# stay up while On: the broker lives there (status-settings.md).
function Invoke-AapManagerStop {
    Write-AapStatus 'draining' '' 'stopping the legacy pool'
    [void](Invoke-AapRoot @($AapManager, '--drain'))
    if ((Wait-AapManagerInactive 'off' 'stopping the legacy pool') -ne 'inactive') { return }   # check:stop-inactive
    $AapRt.ManagerStopped = $true
    $AapRt.Effective = $null
    $AapRt.Applied = $null
    Write-AapLog 'legacy pool stopped: no Linux slot is granted'
    if ($AapRt.CapReady) { [void](Invoke-AapCap 'Update-AapHeartbeat' @{ ManagerStopped = $true }) }
}

# One backend step for every live VM slot (backends\*\INTEGRATION.md, P12
# item 4), by its profile's backend, with the active generation's pinned base
# hash. A late result for an older lease generation is the backend's and the
# allocator's to ignore. A throw is a provider failure: logged, retried next
# tick. A slot whose backend is not loaded is held as it is.
function Invoke-AapVmSteps {
    if (-not ($AapRt.Cap -and $AapRt.CapReady)) { return }
    $st = Invoke-AapCap 'Get-AapAllocatorState'
    if (-not $st.Ok) { return }
    $seen = @{}
    foreach ($r in @($st.State.reservations | Where-Object { $_.backend -ceq 'hyperv-vm' -and $_.state -cne 'reconciled' })) {
        $vm = $AapRt.Vm[[string]$r.profile]
        if (-not $vm) { continue }
        $seen[[string]$r.reservation_id] = $true
        $pin = ''
        $g = $AapRt.Generation[[string]$r.profile]
        if ($g -and $g.Id -ceq $r.image_generation) { $pin = [string]$g.BaseSha256 }
        try {
            $res = & "Invoke-Aap$($vm.Kind)Step" -Backend $vm.B -Reservation $r -BaseSha256 $pin
            $line = "$($r.profile) slot $($r.slot) $($r.reservation_id): $(Format-AapText "$($res.Action) $($res.Code)" 200)"
        } catch {
            $line = "$($r.profile) slot $($r.slot) $($r.reservation_id): step failed: $(Format-AapText $_.Exception.Message 300)"
        }
        if ($AapRt.Steps[$r.reservation_id] -ne $line) { Write-AapLog "vm $line" }
        $AapRt.Steps[$r.reservation_id] = $line
    }
    foreach ($k in @($AapRt.Steps.Keys)) { if (-not $seen[$k]) { $AapRt.Steps.Remove($k) } }
}

# Pause and Off (allocator INTEGRATION.md, P12 item 9): every ready or busy VM
# slot goes to draining, nothing else. A busy one keeps its job running; the
# backend stops idle runners and waits for busy ones. Legacy slots follow the
# manager's own drain.
function Invoke-AapVmDrain {
    if (-not ($AapRt.Cap -and $AapRt.CapReady)) { return }
    $st = Invoke-AapCap 'Get-AapAllocatorState'
    if (-not $st.Ok) { return }
    # A slot whose backend is not loaded cannot be stepped: it keeps its state.
    foreach ($r in @($st.State.reservations | Where-Object { $_.backend -ceq 'hyperv-vm' -and $AapRt.Vm[[string]$_.profile] })) {
        if ($r.state -ceq 'ready' -or $r.state -ceq 'busy') {   # check:vm-drain
            $d = Invoke-AapCap 'Set-AapSlotState' @{ ReservationId = [string]$r.reservation_id; LeaseGeneration = [long]$r.lease_generation; State = 'draining' }
            if ($d.Status -ceq 'ok') { Write-AapLog "vm $($r.profile) slot $($r.slot) $($r.reservation_id): $($r.state) -> draining" }
        }
    }
}

# Off: the VM slots finish their jobs and are torn down before the distro,
# where the broker releases their runners, stops. 'gone'; 'unknown' (the
# allocator state is not readable) or 'timeout' (logged), and Off
# keeps the distro; 'aborted' when state.json says $AbortWhen, like
# Wait-AapManagerInactive. A slot whose backend is loaded counts until it is
# reconciled; one whose backend is not loaded cannot be torn down here and
# counts while its record may hold a job (busy, draining or quarantined).
function Wait-AapVmGone([string]$AbortWhen) {
    if (-not $AapRt.Cap) { return 'gone' }
    $deadline = (Get-AapNow).AddSeconds($AapCfg.DrainTimeoutSeconds)
    while ($true) {
        Invoke-AapVmDrain
        Invoke-AapVmSteps
        $st = Invoke-AapCap 'Get-AapAllocatorState'
        if (-not $st.Ok) { return 'unknown' }   # check:off-cap-ready
        $n = 0
        foreach ($r in @($st.State.reservations | Where-Object { $_.backend -ceq 'hyperv-vm' -and $_.state -cne 'reconciled' })) {
            if ($AapRt.Vm[[string]$r.profile] -or @('busy', 'draining', 'quarantined') -ccontains $r.state) { $n++ }   # check:off-vm-job
        }
        if ($n -eq 0) { return 'gone' }
        if ((Get-AapNow) -ge $deadline) {
            Write-AapLog "VM drain timeout after $($AapCfg.DrainTimeoutSeconds) s ($n VM slots live); the distro stays up, Off waits on"
            return 'timeout'
        }
        if ((Read-AapDesired) -eq $AbortWhen) { return 'aborted' }
        Write-AapStatus 'draining' '' "stopping: waiting for $n VM slots"
        Wait-AapInterval $AapCfg.DrainPollSeconds
    }
}

# On -> Off. Off wins over paused. Drain lets the running job finish. If the
# tray flips back to On while draining, the drain is undone instead of
# waiting up to 6 h. A job still running at the end of a wait (legacy or VM),
# or VM slots the allocator cannot account for, keep the distro and the
# manager: Off stays draining and the next cycle tries again, never killing.
function Invoke-AapOff {
    # The VM slots drain beside the manager; the broker that releases their
    # runners lives in the distro, so it stops after them.
    if ($AapRt.Cap) { [void](Initialize-AapCapacity $AapRt.Settings) }
    Invoke-AapVmDrain
    if (Test-AapManagerFlag) {
        Write-AapStatus 'draining' '' 'drain requested'
        $r = Invoke-AapRoot @($AapManager, '--drain')
        if ($r.Code -ne 0) { Write-AapLog "drain exit $($r.Code): $(Format-AapText $r.Err)" }
        $w = Wait-AapManagerInactive 'on' 'stopping'
        if ($w -eq 'aborted') {
            Write-AapLog 'desired is on again during drain; undraining'
            [void](Invoke-AapRoot @($AapManager, '--undrain'))
            $AapRt.Paused = $false
            $AapRt.NextHealth = [DateTimeOffset]::MinValue
            return
        }
        if ($w -ne 'inactive') {   # check:off-manager-busy
            Write-AapStatus 'draining' '' 'stopping: the legacy pool still runs a job; Off waits on'
            return
        }
    } else {
        Write-AapLog "WARN no drain: $AapOldManager; terminating, which ends any running job"
    }
    $g = Wait-AapVmGone 'on'
    if ($g -eq 'aborted') {
        Write-AapLog 'desired is on again while VM slots drain; undraining'
        if ($AapRt.ManagerOk) { [void](Invoke-AapRoot @($AapManager, '--undrain')) }
        $AapRt.Paused = $false
        $AapRt.NextHealth = [DateTimeOffset]::MinValue
        return
    }
    if ($g -ne 'gone') {   # check:off-vm-busy
        Write-AapStatus 'draining' '' "stopping: VM slots may still run jobs ($g); Off waits on"
        return
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
    $AapRt.ManagerStopped = $false
    # The next On initializes and reconciles again.
    $AapRt.CapReady = $false
    $AapRt.CapWhy = $null
    $AapRt.HoldWhy = $null
    $AapRt.CapFlags = @()
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
        Write-AapStatus $AapRt.Status.State $AapRt.Status.Job $AapRt.Status.Detail $AapRt.Status.Repo $AapRt.Status.RunUrl $AapRt.Status.Mirror
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
        if (-not $AapCfg.DryRun) {
            Initialize-AapProviders
            Initialize-AapMode
        }
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
