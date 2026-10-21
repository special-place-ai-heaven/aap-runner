# Windows guest agent and job bootstrap (P14). Windows PowerShell 5.1 and PowerShell 7.
#   Invoke-AapGuestAgent    agent.ps1: one host command per process (guest-transport.md): envelope line and payload on
#                           stdin, one reply line on stdout. probe bootstraps the clone, deliver_registration keeps the JIT
#                           config in the runner root, start_runner starts the launcher task, status/collect report
#   Start-AapGuestRunner    launch.ps1, as a scheduled task of the job user (a fresh logon environment, outside the
#   Wait-AapGuestRunner     PowerShell Direct session): the per-job cache, then Runner.Listener with the JIT config in
#                           its environment only, then its exit code
#   Install-AapGuestAgent   image overlay (P21): the agent files, Administrators-only
# The host is the elevated supervisor; the guest is hostile once a job has run (the job user is a local administrator).
# Secret bytes (the JIT config) never become a command's parameter (module logging, event 4103), argv or script text:
# they move by .NET calls only. Every safety check carries '# check:<name>'; Invoke-AapGuestMutations.ps1 breaks each.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:LineMax = 1024
$script:PayloadMax = 16384
$script:Commands = @('probe', 'deliver_registration', 'start_runner', 'status', 'collect', 'shutdown')
$script:OneShot = @('deliver_registration', 'start_runner', 'shutdown')
$script:EnvelopeKeys = @('schema', 'kind', 'vm_id', 'reservation_id', 'lease_generation', 'seq', 'nonce', 'cmd', 'payload_bytes', 'expires_at')
$script:GuidRe = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z'
$script:ClockSlackSeconds = 5     # the guest clock follows the host through Hyper-V time sync
$script:ExpiryMaxSeconds = 120    # guest-transport.md: expires_at at most 120 s ahead
$script:NonceMax = 8192           # 68 h of 30 s heartbeats; a full store refuses (fail closed)
# The only variables the cache may hand the runner (guests/cache/windows/AapZcCache.psm1, Initialize-AapZcJob).
$script:CacheEnvNames = @('AAP_ZC_STATE', 'CMAKE_C_COMPILER_LAUNCHER', 'CMAKE_CXX_COMPILER_LAUNCHER')
$script:StateMax = 524288
$script:RecordMax = 65536
# The host refuses a token- or key-shaped diag (AapWinBackend.psm1, SecretValue); guest-authored text is redacted first.
$script:SecretValue = 'gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|SYNTHETIC-JIT-MARKER'
$script:JitFile = '.aap-jit'
$script:Ascii = New-Object Text.ASCIIEncoding

function New-AapGuestContext {
    <# The production context: fixed paths and the operating-system calls, one scriptblock each (tests pass fakes). #>
    $self = [Security.Principal.WindowsIdentity]::GetCurrent()
    @{
        InstallDir = $PSScriptRoot                     # C:\Program Files\aap-guest
        StateDir = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'aap-guest'
        SystemRoot = [Environment]::GetFolderPath('Windows')
        SystemDrive = [IO.Path]::GetPathRoot([Environment]::GetFolderPath('Windows'))
        Scratch = 'D:\'                                # the scratch disk, hosted D: (images/windows/INTEGRATION.md)
        JobUser = 'runneradmin'
        # ponytail: fixed private cache root; take it from the profile's budget record once P10 sizes scratch with it.
        CacheBudgetBytes = 10GB
        StartWaitSeconds = 40                          # start_runner's own timeout is 60 s, session setup included
        PollMilliseconds = 500
        Ops = @{
            # Hyper-V's host-to-guest intrinsic data (Data Exchange): the VM id the hypervisor gave this partition.
            VmId = { [string](Get-AapGuestProp (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest\Parameters' -ErrorAction SilentlyContinue) 'VirtualMachineId') }
            SetupComplete = { [string](Get-AapGuestProp (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' -ErrorAction SilentlyContinue) 'ImageState') -ceq 'IMAGE_STATE_COMPLETE' }
            Identity = { @{ Name = $self.Name; IsAdmin = (New-Object Security.Principal.WindowsPrincipal $self).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } }.GetNewClosure()
            # Names are case-insensitive, as Windows treats them (the registry may hold PATH or Path).
            Env = { param($Scope) $h = @{}; foreach ($e in [Environment]::GetEnvironmentVariables($Scope).GetEnumerator()) { $h[[string]$e.Key] = [string]$e.Value }; $h }
            ScratchVolume = {
                $v = Get-Volume -DriveLetter D -ErrorAction SilentlyContinue
                if (-not $v) { return $null }
                $d = Get-Partition -DriveLetter D | Get-Disk
                @{ FileSystem = [string]$v.FileSystem; DriveType = [string]$v.DriveType; Boot = [bool]($d.IsBoot -or $d.IsSystem); Number = [int]$d.Number }
            }
            # Every disk but the boot and system disk, with its partition style and data partitions (MSR not counted).
            ScratchDisks = {
                @(Get-Disk | Where-Object { -not $_.IsBoot -and -not $_.IsSystem } | ForEach-Object {
                        @{ Number = [int]$_.Number; Style = [string]$_.PartitionStyle; Data = @(Get-Partition -DiskNumber $_.Number -ErrorAction SilentlyContinue | Where-Object { [string]$_.Type -ne 'Reserved' }).Count }
                    })
            }
            # Each step only if not done yet, so a probe killed half-way is finished by the next: initialize a RAW disk,
            # make or letter its one data partition D:, format it unless it is NTFS (P10 already formats it offline).
            FormatScratch = {
                param([int]$Number)
                if ([string](Get-Disk -Number $Number).PartitionStyle -eq 'RAW') { Initialize-Disk -Number $Number -PartitionStyle GPT }
                $p = @(Get-Partition -DiskNumber $Number -ErrorAction SilentlyContinue | Where-Object { [string]$_.Type -ne 'Reserved' })
                if (-not $p.Count) { $p = @(New-Partition -DiskNumber $Number -UseMaximumSize -DriveLetter D) }
                elseif ([string]$p[0].DriveLetter -ne 'D') { Set-Partition -InputObject $p[0] -NewDriveLetter D; $p = @(Get-Partition -DriveLetter D) }
                if ([string](Get-Volume -Partition $p[0]).FileSystem -ne 'NTFS') { $null = Format-Volume -Partition $p[0] -FileSystem NTFS -NewFileSystemLabel 'Temporary Storage' -Confirm:$false }
            }
            # A task of the job user (S4U: no password stored) at highest privileges and normal priority (a task's default
            # 7 is below normal): the launcher gets a fresh logon environment and lives outside the PowerShell Direct session.
            # What Windows PowerShell adds to its own environment (the execution policy preference, its PSModulePath) is
            # taken out again before Runner.Listener starts (Start-AapGuestRunner).
            StartLauncher = {
                param($Ctx)
                $ps = Join-Path $Ctx.SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                $action = New-ScheduledTaskAction -Execute $ps -Argument ('-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $Ctx.InstallDir 'launch.ps1'))
                $principal = New-ScheduledTaskPrincipal -UserId $self.Name -LogonType S4U -RunLevel Highest
                $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -Priority 4 -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
                $null = Register-ScheduledTask -TaskName 'aap-guest-runner' -Action $action -Principal $principal -Settings $settings -Force
                Start-ScheduledTask -TaskName 'aap-guest-runner'
            }.GetNewClosure()
            Process = {
                param([int]$Id)
                $p = Get-Process -Id $Id -ErrorAction SilentlyContinue
                if ($p) { @{ Path = [string]$p.Path; StartTicks = $p.StartTime.ToUniversalTime().Ticks } }
            }
            WorkerRunning = { param([string]$Root) [bool]@(Get-Process -Name 'Runner.Worker' -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase) }).Count }
            InitCache = {
                param($Ctx)
                Import-Module (Join-Path $Ctx.InstallDir 'cache\AapZcCache.psm1')
                $null = Initialize-AapZcJob -InstallDir (Join-Path $Ctx.InstallDir 'cache') -JobRoot (Get-AapGuestCacheRoot $Ctx) -BudgetBytes $Ctx.CacheBudgetBytes
            }
            CacheState = {
                param($Ctx)
                Import-Module (Join-Path $Ctx.InstallDir 'cache\AapZcCache.psm1')
                Get-AapZcState -JobRoot (Get-AapGuestCacheRoot $Ctx)
            }
            StartRunner = { param($Psi) $p = [Diagnostics.Process]::Start($Psi); @{ Pid = $p.Id; StartTicks = $p.StartTime.ToUniversalTime().Ticks; Process = $p } }
            WaitRunner = { param($Started) $Started.Process.WaitForExit(); [int]$Started.Process.ExitCode }
            Shutdown = { $null = & (Join-Path ([Environment]::GetFolderPath('System')) 'shutdown.exe') /s /t 5 /f /d p:4:1 }
            Now = { [DateTime]::UtcNow }
        }
    }
}

function Get-AapGuestRunnerRoot($Ctx) { Join-Path $Ctx.Scratch 'actions-runner' }
function Get-AapGuestCacheRoot($Ctx) { Join-Path $Ctx.Scratch 'aap-cache' }
function Get-AapGuestListener($Ctx) { Join-Path (Get-AapGuestRunnerRoot $Ctx) 'bin\Runner.Listener.exe' }

# Printable ASCII for a reply's diag, at most $Max characters, with no quote or backslash to escape and nothing the host
# would take for a secret.
function Get-AapGuestText([string]$Text, [int]$Max = 400) {
    if ($null -eq $Text) { return '' }
    $t = [regex]::Replace($Text, '[^ -~]', '?').Replace('"', "'").Replace('\', '/')
    $t = [regex]::Replace($t, $script:SecretValue, '[redacted]')
    if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max) }
    $t
}

# SYSTEM, Administrators and (WithSelf) this process's user, full control, inheritance off. At run time this process is
# the job user; an unelevated install (tests only) keeps its own access.
function Set-AapGuestAcl([string]$Path, [switch]$WithSelf) {
    $sec = New-Object Security.AccessControl.DirectorySecurity
    $sec.SetAccessRuleProtection($true, $false)
    $sids = @('S-1-5-18', 'S-1-5-32-544')
    if ($WithSelf) { $sids += [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
    foreach ($s in $sids) {
        $sec.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier $s), 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
    }
    $info = New-Object IO.DirectoryInfo $Path
    if ($PSVersionTable.PSVersion.Major -ge 6) { [IO.FileSystemAclExtensions]::SetAccessControl($info, $sec) } else { $info.SetAccessControl($sec) }
}

function Test-AapGuestLink([string]$Path) {
    $a = [IO.File]::GetAttributes($Path)
    [bool]($a -band [IO.FileAttributes]::ReparsePoint)
}

# A guest-written record (launch.json): at most 64 KiB, else $null.
function Read-AapGuestRecord([string]$Path) {
    try {
        $fi = New-Object IO.FileInfo $Path
        if (-not $fi.Exists -or $fi.Length -gt $script:RecordMax) { return $null }
        ConvertFrom-Json ([IO.File]::ReadAllText($Path))
    } catch { $null }
}
function Write-AapGuestRecord([string]$Path, $Doc) {
    $tmp = $Path + '.tmp'
    [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $Doc -Compress), $script:Ascii)
    if ([IO.File]::Exists($Path)) { [IO.File]::Replace($tmp, $Path, [NullString]::Value) } else { [IO.File]::Move($tmp, $Path) }
}
function Get-AapGuestProp($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { $p.Value } else { $null }
}

# ---- the wire ----

# One line of printable ASCII, at most 1024 bytes, after an optional UTF-8 BOM (a guest-side InputEncoding of 65001 adds
# one). $null on anything else, end of stream included.
function Read-AapGuestLine([IO.Stream]$Stream) {
    $b = New-Object Collections.Generic.List[byte]
    $c = $Stream.ReadByte()
    if ($c -eq 0xEF) {
        $b1 = $Stream.ReadByte(); $b2 = $Stream.ReadByte()
        if ($b1 -ne 0xBB -or $b2 -ne 0xBF) { return $null }   # check:bom
        $c = $Stream.ReadByte()
    }
    while ($c -ne 10) {
        if ($c -lt 0) { return $null }
        # Reading stops at the first byte that is not printable or at byte 1025 of the line.
        if ($c -lt 0x20 -or $c -gt 0x7e -or $b.Count -ge $script:LineMax) { return $null }   # check:line-bytes
        $b.Add([byte]$c)
        $c = $Stream.ReadByte()
    }
    $script:Ascii.GetString($b.ToArray())
}

# The host_cmd envelope (guest-transport.schema.json): exactly its ten keys, once each, flat scalars, every value in its
# range. $null when anything is off.
function ConvertFrom-AapGuestEnvelope([string]$Line) {
    $pair = '"[a-z_]{1,20}":(?:"[^"\\]*"|0|[1-9][0-9]{0,9})'
    if ($Line -cnotmatch "^\{$pair(?:,$pair)*\}\z") { return $null }   # check:envelope-shape
    $e = @{}
    foreach ($m in [regex]::Matches($Line, '"([a-z_]+)":(?:"([^"\\]*)"|([0-9]+))')) {
        $k = $m.Groups[1].Value
        if ($e.ContainsKey($k)) { return $null }   # check:envelope-duplicate
        $e[$k] = $(if ($m.Groups[2].Success) { $m.Groups[2].Value } else { [long]$m.Groups[3].Value })
    }
    if ($e.Count -ne $script:EnvelopeKeys.Count -or @($script:EnvelopeKeys | Where-Object { -not $e.ContainsKey($_) }).Count) { return $null }   # check:envelope-keys
    $num = { param($v, $lo, $hi) $v -is [long] -and $v -ge $lo -and $v -le $hi }
    $str = { param($v, $re) $v -is [string] -and $v -cmatch $re }
    $ok = (& $num $e.schema 1 1) -and $e.kind -ceq 'host_cmd' -and (& $str $e.vm_id $script:GuidRe) -and (& $str $e.reservation_id '^r-[0-9a-f]{16}\z') -and
        (& $num $e.lease_generation 1 999999999) -and (& $num $e.seq 1 2147483647) -and (& $str $e.nonce '^[0-9a-f]{32}\z') -and
        $e.cmd -is [string] -and $script:Commands -ccontains $e.cmd -and (& $num $e.payload_bytes 0 $script:PayloadMax) -and
        (& $str $e.expires_at '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\z')
    if (-not $ok) { return $null }   # check:envelope-values
    try {
        $e.Expires = [DateTime]::ParseExact($e.expires_at, "yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]'AssumeUniversal, AdjustToUniversal')
    } catch { return $null }
    $e
}

function Format-AapGuestReply($E, [string]$Status, [string]$State, $ExitCode, [string]$Diag) {
    $exit = $(if ($null -eq $ExitCode) { 'null' } else { ([int]$ExitCode).ToString([Globalization.CultureInfo]::InvariantCulture) })
    '{{"schema":1,"kind":"guest_reply","vm_id":"{0}","reservation_id":"{1}","lease_generation":{2},"seq":{3},"nonce":"{4}","status":"{5}","guest_state":"{6}","runner_exit_code":{7},"diag":"{8}"}}' -f
    $E.vm_id, $E.reservation_id, $E.lease_generation, $E.seq, $E.nonce, $Status, $State, $exit, (Get-AapGuestText $Diag)
}

# ---- the agent's state: one Administrators-only file, held open (no sharing) while a command is accepted ----

function New-AapGuestStateDoc { [ordered]@{ schema = 1; reservation_id = ''; lease_generation = 0; seq = 0; nonces = @(); shots = @(); phase = 'booting'; detail = '' } }

# $null when another agent process holds the file for 2 s (the caller answers without accepting anything).
function Open-AapGuestState($Ctx) {
    if (-not [IO.Directory]::Exists($Ctx.StateDir)) {
        [void][IO.Directory]::CreateDirectory($Ctx.StateDir)
        Set-AapGuestAcl $Ctx.StateDir -WithSelf
    }
    $path = Join-Path $Ctx.StateDir 'state.json'
    if (-not [IO.File]::Exists($path)) {
        # Born whole (written aside, then moved in), so an empty or cut file always means a torn save, never a new boot.
        $tmp = $path + '.' + [guid]::NewGuid().ToString('n')
        [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject (New-AapGuestStateDoc) -Compress), $script:Ascii)
        try { [IO.File]::Move($tmp, $path) } catch { [IO.File]::Delete($tmp) }
    }
    $fs = $null
    for ($i = 0; $null -eq $fs -and $i -le 20; $i++) {
        try { $fs = [IO.File]::Open($path, 'Open', 'ReadWrite', 'None') } catch [IO.IOException] { Start-Sleep -Milliseconds 100 }
    }
    if ($null -eq $fs) { return $null }
    $doc = New-AapGuestStateDoc
    $bad = $false
    if ($fs.Length -gt $script:StateMax) { $bad = $true }   # check:state-size
    else {
        $buf = New-Object byte[] $fs.Length
        $n = 0
        while ($n -lt $buf.Length) { $k = $fs.Read($buf, $n, $buf.Length - $n); if ($k -le 0) { break }; $n += $k }
        try {
            $j = ConvertFrom-Json ($script:Ascii.GetString($buf, 0, $n))
            foreach ($k in @($doc.Keys)) { $doc[$k] = Get-AapGuestProp $j $k }
            $doc.nonces = @($doc.nonces); $doc.shots = @($doc.shots)
            if ($doc.schema -ne 1 -or -not ($doc.reservation_id -is [string]) -or -not ($doc.seq -is [int] -or $doc.seq -is [long]) -or   # check:state-shape
                -not ($doc.lease_generation -is [int] -or $doc.lease_generation -is [long]) -or
                @('booting', 'ready', 'registered', 'started', 'failed', 'shutting_down') -cnotcontains $doc.phase -or
                @($doc.nonces + $doc.shots | Where-Object { -not ($_ -is [string]) }).Count) { $bad = $true }
        } catch { $bad = $true }
    }
    @{ Stream = $fs; Doc = $doc; Bad = $bad }
}
# Writes over the old bytes, then cuts the file to the new length: a save that dies half-way leaves a file that does not
# parse (Bad), never an empty one that would read as a fresh boot.
function Save-AapGuestState($S) {
    $b = $script:Ascii.GetBytes((ConvertTo-Json -InputObject $S.Doc -Compress))
    $S.Stream.Position = 0
    $S.Stream.Write($b, 0, $b.Length)
    $S.Stream.SetLength($b.Length)
    $S.Stream.Flush($true)
}

# Why a well-formed command is refused (guest-transport.md, Envelope), or $null. Who may send at all is the transport's
# boundary (the per-clone PowerShell Direct credential); these rules keep one sender's commands in order.
function Get-AapGuestRefusal($Ctx, $Doc, $E) {
    if ($Doc.reservation_id -cne '' -and $Doc.reservation_id -cne $E.reservation_id) { return 'reservation_id is not the first one of this boot' }   # check:refuse-reservation
    if ($Doc.lease_generation -ne 0 -and $Doc.lease_generation -ne $E.lease_generation) { return 'lease_generation is not the first one of this boot' }   # check:refuse-generation
    if ($E.seq -le $Doc.seq) { return 'seq is not greater than the last accepted one' }   # check:refuse-seq
    if (@($Doc.nonces) -ccontains $E.nonce) { return 'nonce already seen' }   # check:refuse-nonce
    if (@($Doc.nonces).Count -ge $script:NonceMax) { return 'nonce store full' }   # check:refuse-nonce-full
    if ($script:OneShot -ccontains $E.cmd -and @($Doc.shots) -ccontains $E.cmd) { return "$($E.cmd) already ran this boot" }   # check:refuse-oneshot
    $now = & $Ctx.Ops.Now
    if ($E.Expires.AddSeconds($script:ClockSlackSeconds) -lt $now) { return 'expired' }   # check:refuse-expired
    if ($E.Expires -gt $now.AddSeconds($script:ExpiryMaxSeconds + $script:ClockSlackSeconds)) { return 'expires_at too far ahead' }   # check:refuse-expiry-ahead
    if (($E.cmd -ceq 'deliver_registration') -ne ($E.payload_bytes -gt 0)) { return 'a payload comes only with deliver_registration' }   # check:refuse-payload
    $null
}

# ---- bootstrap (probe) ----

# Answer files that carried the per-clone password: the Panther tree, Sysprep and the system drive's root.
function Get-AapGuestBootstrapFiles($Ctx) {
    $found = New-Object Collections.Generic.List[string]
    $walk = New-Object Collections.Generic.Stack[string]
    $panther = Join-Path $Ctx.SystemRoot 'Panther'
    if ([IO.Directory]::Exists($panther)) { $walk.Push($panther) }
    while ($walk.Count) {
        foreach ($p in [IO.Directory]::GetFileSystemEntries($walk.Pop())) {
            $enter = [IO.Directory]::Exists($p)
            # A link is an entry (deleted as such when its name matches), never entered.
            if ($enter -and (Test-AapGuestLink $p)) { $enter = $false }   # check:walk-link
            if ($enter) { $walk.Push($p) }
            elseif ((Split-Path -Leaf $p) -like '*unattend*') { $found.Add($p) }
        }
    }
    foreach ($dir in (Join-Path $Ctx.SystemRoot 'System32\Sysprep'), $Ctx.SystemDrive) {
        if ([IO.Directory]::Exists($dir)) { foreach ($p in [IO.Directory]::GetFiles($dir, '*unattend*.xml')) { $found.Add($p) } }
    }
    $found.ToArray()
}

# What a job must not find: bootstrap material, and the JIT config outside a runner that has not started yet.
function Get-AapGuestResidue($Ctx, [switch]$Started) {
    $r = @(Get-AapGuestBootstrapFiles $Ctx | ForEach-Object { "bootstrap file $_" })
    if ($Started -and [IO.File]::Exists((Join-Path (Get-AapGuestRunnerRoot $Ctx) $script:JitFile))) { $r += 'registration material on disk after start' }   # check:residue-jit
    $r
}

# The defaults a fresh job step finds come from the image's machine and user environment, as on hosted runners; the agent
# adds nothing to them. It refuses an image whose default PATH carries a compiler (a developer environment is entered
# per job with VsDevCmd) or that lacks the tool cache the setup-* actions install other versions into.
function Get-AapGuestEnvProblems($Ctx) {
    $m = & $Ctx.Ops.Env 'Machine'
    $u = & $Ctx.Ops.Env 'User'
    $p = New-Object Collections.Generic.List[string]
    foreach ($n in 'ImageOS', 'ImageVersion', 'AGENT_TOOLSDIRECTORY') {
        if ([string]::IsNullOrEmpty([string]$m[$n])) { $p.Add("machine variable $n missing") }   # check:env-image
    }
    $tc = [string]$m['AGENT_TOOLSDIRECTORY']
    if ($tc -and -not [IO.Directory]::Exists($tc)) { $p.Add('tool cache folder missing') }   # check:env-toolcache
    foreach ($d in @(([string]$m['Path'] + ';' + [string]$u['Path']).Split(';') | Where-Object { $_ })) {
        $x = [Environment]::ExpandEnvironmentVariables($d)
        # A string join, not Join-Path: a PATH entry may name a drive this guest does not have.
        $cl = $(try { [IO.Path]::Combine($x, 'cl.exe') } catch { $null })
        if ($cl -and [IO.File]::Exists($cl)) { $p.Add("cl.exe on the default PATH: $x") }   # check:env-compiler
    }
    $p.ToArray()
}

# D: is the scratch disk. P10 creates it new for each reservation and formats it NTFS offline (no drive letter), so
# normally Windows has mounted it as D: and nothing is done here; that D: is trusted only because the disk is new per
# reservation. Otherwise exactly one disk besides the boot disk, with at most one data partition, is (re)made D: and
# formatted unless already NTFS; every step resumes where a killed probe stopped.
function Initialize-AapGuestScratch($Ctx) {
    $v = & $Ctx.Ops.ScratchVolume
    if ($null -ne $v -and -not $v.Boot -and @('', 'RAW') -ccontains $v.FileSystem) { & $Ctx.Ops.FormatScratch $v.Number; $v = & $Ctx.Ops.ScratchVolume }   # check:scratch-resume
    if ($null -eq $v) {
        $c = @(& $Ctx.Ops.ScratchDisks | Where-Object { $_.Style -ceq 'RAW' -or $_.Data -le 1 })
        if ($c.Count -ne 1) { return "expected one scratch disk, found $($c.Count)" }   # check:scratch-one
        & $Ctx.Ops.FormatScratch $c[0].Number
        $v = & $Ctx.Ops.ScratchVolume
    }
    if ($null -eq $v -or $v.FileSystem -cne 'NTFS' -or $v.DriveType -cne 'Fixed' -or $v.Boot) { return 'D: is not an NTFS scratch volume' }   # check:scratch-volume
    $null
}

# Copies the overlay file by file; a file appears under its own name only once complete, so a copy cut short by a
# killed probe resumes with the next file instead of starting over.
function Copy-AapGuestTree([string]$From, [string]$To) {
    [void][IO.Directory]::CreateDirectory($To)
    foreach ($d in [IO.Directory]::GetDirectories($From)) { Copy-AapGuestTree $d (Join-Path $To (Split-Path -Leaf $d)) }
    foreach ($f in [IO.Directory]::GetFiles($From)) {
        $t = Join-Path $To (Split-Path -Leaf $f)
        if ([IO.File]::Exists($t)) { continue }
        [IO.File]::Copy($f, $t + '.part', $true)
        [IO.File]::Move($t + '.part', $t)
    }
}

# Returns @{ State = booting|ready|failed; Detail }. Runs outside the state lock, under its own (bootstrap.lock): a probe
# that finds a bootstrap still running (an earlier probe the host gave up on) answers booting. Every step is idempotent.
function Invoke-AapGuestBootstrap($Ctx) {
    if (-not (& $Ctx.Ops.SetupComplete)) { return @{ State = 'booting'; Detail = 'windows setup still running' } }   # check:setup-complete
    $lock = $null
    try { $lock = [IO.File]::Open((Join-Path $Ctx.StateDir 'bootstrap.lock'), 'OpenOrCreate', 'ReadWrite', 'None') } catch [IO.IOException] { $lock = $null }
    if ($null -eq $lock) { return @{ State = 'booting'; Detail = 'bootstrap in progress' } }   # check:bootstrap-lock
    try {
        $id = & $Ctx.Ops.Identity
        if (-not $id.IsAdmin -or [string]$id.Name -notmatch ('\\' + [regex]::Escape($Ctx.JobUser) + '\z')) { return @{ State = 'failed'; Detail = 'the agent does not run as the job user' } }   # check:identity
        foreach ($f in Get-AapGuestBootstrapFiles $Ctx) { if ([IO.Directory]::Exists($f)) { [IO.Directory]::Delete($f) } else { [IO.File]::Delete($f) } }
        $envp = @(Get-AapGuestEnvProblems $Ctx)
        if ($envp.Count) { return @{ State = 'failed'; Detail = $envp[0] } }   # check:env
        $s = Initialize-AapGuestScratch $Ctx
        if ($s) { return @{ State = 'failed'; Detail = $s } }
        # The runner works on the scratch disk (its root, _work and _diag), never on the clone disk the host caps.
        $root = Get-AapGuestRunnerRoot $Ctx
        if (-not [IO.File]::Exists((Get-AapGuestListener $Ctx))) {
            $src = Join-Path $Ctx.InstallDir 'runner'
            if (-not [IO.File]::Exists((Join-Path $src 'bin\Runner.Listener.exe'))) { return @{ State = 'failed'; Detail = 'actions-runner overlay missing' } }   # check:runner-overlay
            $part = $root + '.partial'
            if (-not [IO.Directory]::Exists($part)) { [void][IO.Directory]::CreateDirectory($part); Set-AapGuestAcl $part -WithSelf }
            Copy-AapGuestTree $src $part
            if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root, $true) }
            [IO.Directory]::Move($part, $root)
        }
        # The cache job root: SYSTEM, Administrators and the job user only (guests/cache/INTEGRATION.md, P14 2).
        $cache = Get-AapGuestCacheRoot $Ctx
        if (-not [IO.Directory]::Exists($cache)) { [void][IO.Directory]::CreateDirectory($cache); Set-AapGuestAcl $cache -WithSelf }
        @{ State = 'ready'; Detail = 'bootstrap material removed; scratch, runner and cache root ready' }
    } finally { $lock.Dispose() }
}

# ---- the runner (launch.ps1, then status and collect) ----

function Get-AapGuestLaunchPath($Ctx) { Join-Path $Ctx.StateDir 'launch.json' }

function Start-AapGuestRunner {
    <# launch.ps1, first half: cache, then the JIT config out of the runner root and into Runner.Listener's environment.
       Records launch.json (phase starting, running or failed) and returns the started runner, or $null. Starts nothing
       unless start_runner asked (its 'requested' record) and is still waiting: after its deadline or its cancel mark the
       host has given up on this VM. #>
    param($Ctx = (New-AapGuestContext))
    $rec = Get-AapGuestLaunchPath $Ctx
    $deadline = 0L
    try {
        $req = Read-AapGuestRecord $rec
        if ([string](Get-AapGuestProp $req 'phase') -ceq 'requested') { $deadline = [long](Get-AapGuestProp $req 'deadline') }
    } catch { $deadline = 0L }
    Write-AapGuestRecord $rec ([ordered]@{ phase = 'starting'; launcher_pid = $PID })
    $jit = $null; $jitText = $null
    try {
        # Before the JIT config is read: the cache daemons start from this fresh logon environment and never hold it.
        $cacheEnv = @()
        try {
            & $Ctx.Ops.InitCache $Ctx
            $envFile = Join-Path (Get-AapGuestCacheRoot $Ctx) 'state\runner.env'
            if ([IO.File]::Exists($envFile) -and (New-Object IO.FileInfo $envFile).Length -le $script:RecordMax) { $cacheEnv = @([IO.File]::ReadAllLines($envFile) | Where-Object { $_ }) }
        } catch { $cacheEnv = @() }   # a cache that cannot start leaves the compilers running directly
        $file = Join-Path (Get-AapGuestRunnerRoot $Ctx) $script:JitFile
        $fs = [IO.File]::Open($file, 'Open', 'ReadWrite', 'None')
        try {
            if ($fs.Length -lt 1 -or $fs.Length -gt $script:PayloadMax) { throw 'registration material has the wrong size' }
            $jit = New-Object byte[] $fs.Length
            $n = 0
            while ($n -lt $jit.Length) { $k = $fs.Read($jit, $n, $jit.Length - $n); if ($k -le 0) { break }; $n += $k }
            # Overwrite before the delete: no copy outlives the start (the clone dies with the VM in any case).
            $fs.Position = 0
            $fs.Write((New-Object byte[] $fs.Length), 0, [int]$fs.Length)
            $fs.Flush($true)
        } finally { $fs.Dispose() }
        [IO.File]::Delete($file)
        if ([IO.File]::Exists((Join-Path $Ctx.StateDir 'cancel')) -or (& $Ctx.Ops.Now).Ticks -gt $deadline) { throw 'start cancelled: start_runner gave up' }   # check:launch-cancel

        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = Get-AapGuestListener $Ctx
        $psi.Arguments = 'run'
        $psi.WorkingDirectory = Get-AapGuestRunnerRoot $Ctx
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        # Runner inputs, and what Windows PowerShell put into its own environment (its execution policy preference, its
        # module path), are not the job's: job steps see what a fresh logon sees, as on hosted runners.
        foreach ($k in @($psi.EnvironmentVariables.Keys)) {
            if ($k -like 'ACTIONS_RUNNER_INPUT_*' -or $k -eq 'PSExecutionPolicyPreference') { $psi.EnvironmentVariables.Remove($k) }   # check:runner-env-strip
        }
        $u = & $Ctx.Ops.Env 'User'
        $pm = $(if ([string]$u['PSModulePath']) { [string]$u['PSModulePath'] } else { [string](& $Ctx.Ops.Env 'Machine')['PSModulePath'] })
        if ($pm) { $psi.EnvironmentVariables['PSModulePath'] = $pm } else { $psi.EnvironmentVariables.Remove('PSModulePath') }
        foreach ($l in $cacheEnv) {
            $i = $l.IndexOf('=')
            if ($i -lt 1) { continue }
            $name = $l.Substring(0, $i); $value = $l.Substring($i + 1)
            if ($script:CacheEnvNames -cnotcontains $name) { continue }   # check:runner-env-allow
            if ($value -cnotmatch '^[ -~]*\z') { continue }   # check:runner-env-value
            $psi.EnvironmentVariables[$name] = $value
        }
        $jitText = $script:Ascii.GetString($jit)
        $psi.EnvironmentVariables['ACTIONS_RUNNER_INPUT_JITCONFIG'] = $jitText
        $started = & $Ctx.Ops.StartRunner $psi
        $psi.EnvironmentVariables.Remove('ACTIONS_RUNNER_INPUT_JITCONFIG')
        Write-AapGuestRecord $rec ([ordered]@{ phase = 'running'; launcher_pid = $PID; runner_pid = [int]$started.Pid; runner_start = [long]$started.StartTicks })
        $started
    } catch {
        Write-AapGuestRecord $rec ([ordered]@{ phase = 'failed'; launcher_pid = $PID; detail = (Get-AapGuestText $_.Exception.Message 200) })
        $null
    } finally {
        if ($null -ne $jit) { [Array]::Clear($jit, 0, $jit.Length) }
        $jitText = $null
    }
}

function Wait-AapGuestRunner {
    <# launch.ps1, second half: waits for Runner.Listener (one job) and records its exit code. #>
    param($Ctx, $Started)
    $code = & $Ctx.Ops.WaitRunner $Started
    Write-AapGuestRecord (Get-AapGuestLaunchPath $Ctx) ([ordered]@{ phase = 'exited'; launcher_pid = $PID; runner_pid = [int]$Started.Pid; runner_start = [long]$Started.StartTicks; exit_code = [int]$code })
}

# Whether the runner a launch record names (pid, start time, path) is running now.
function Test-AapGuestRunnerAlive($Ctx, $Record) {
    try {
        $p = & $Ctx.Ops.Process ([int](Get-AapGuestProp $Record 'runner_pid'))
        $null -ne $p -and [long]$p.StartTicks -eq [long](Get-AapGuestProp $Record 'runner_start') -and [string]$p.Path -eq (Get-AapGuestListener $Ctx)
    } catch { $false }
}

# The runner as status/collect see it: @{ Phase; State; Exit; Detail }. launch.json is job-writable once the job runs,
# so every field is checked and only its own fixed words reach the reply. Even so these are hints (README, Trust).
function Get-AapGuestRunnerState($Ctx) {
    $l = Read-AapGuestRecord (Get-AapGuestLaunchPath $Ctx)
    $phase = [string](Get-AapGuestProp $l 'phase')
    $live = { if (& $Ctx.Ops.WorkerRunning (Get-AapGuestRunnerRoot $Ctx)) { @{ Phase = $phase; State = 'busy'; Exit = $null; Detail = 'job running' } } else { @{ Phase = $phase; State = 'listening'; Exit = $null; Detail = 'runner listening' } } }
    switch -CaseSensitive ($phase) {
        { $_ -ceq 'requested' -or $_ -ceq 'starting' } { return @{ Phase = $phase; State = 'listening'; Exit = $null; Detail = 'runner starting' } }
        'running' {
            if (-not (Test-AapGuestRunnerAlive $Ctx $l)) { return @{ Phase = $phase; State = 'job_done'; Exit = $null; Detail = 'runner gone; exit code not recorded' } }   # check:runner-identity
            return (& $live)
        }
        'exited' {
            # An exit record for a runner that still runs is not believed.
            if (Test-AapGuestRunnerAlive $Ctx $l) { return (& $live) }   # check:exited-alive
            $code = Get-AapGuestProp $l 'exit_code'
            if (-not ($code -is [int] -or $code -is [long]) -or $code -lt [int]::MinValue -or $code -gt [int]::MaxValue) { $code = $null }
            return @{ Phase = $phase; State = 'job_done'; Exit = $code; Detail = 'runner exited' }
        }
        'failed' { return @{ Phase = $phase; State = 'failed'; Exit = $null; Detail = 'launcher failed: ' + [string](Get-AapGuestProp $l 'detail') } }
    }
    @{ Phase = ''; State = 'failed'; Exit = $null; Detail = 'launcher record missing or unreadable' }
}

# ---- one command ----

function Invoke-AapGuestAgent {
    <# agent.ps1. Reads the envelope line and exactly payload_bytes bytes from In, writes one reply line to Out and
       returns the process exit code: 0 with a reply, 2 (no reply) for input that breaks the framing. #>
    param($Ctx = (New-AapGuestContext), [IO.Stream]$In = [Console]::OpenStandardInput(), [IO.Stream]$Out = [Console]::OpenStandardOutput())
    $line = Read-AapGuestLine $In
    if ($null -eq $line) { return 2 }
    $e = ConvertFrom-AapGuestEnvelope $line
    if ($null -eq $e) { return 2 }
    $payload = New-Object byte[] ([int]$e.payload_bytes)
    $s = $null
    try {
        $n = 0
        while ($n -lt $payload.Length) { $k = $In.Read($payload, $n, $payload.Length - $n); if ($k -le 0) { return 2 }; $n += $k }
        $status = 'error'; $state = 'failed'; $exit = $null; $diag = ''
        try {
            $own = [string](& $Ctx.Ops.VmId)
            $own = $(if ($own -match '^\{?([0-9a-fA-F-]{36})\}?\z') { $Matches[1].ToLowerInvariant() } else { '' })
            if ($own -cnotmatch $script:GuidRe) { $status = 'refused'; $diag = 'own vm id unavailable from the hypervisor' }   # check:vmid-source
            elseif ($own -cne $e.vm_id) { $status = 'refused'; $diag = 'vm_id is not this VM' }   # check:vmid
            elseif ($null -eq ($s = Open-AapGuestState $Ctx)) {
                # Another agent process holds the state: nothing is accepted; a probe just hears booting.
                $diag = 'agent busy'
                if ($e.cmd -ceq 'probe') { $status = 'ok'; $state = 'booting' }
            } else {
                $d = $s.Doc
                $state = $(if ($d.phase -ceq 'started') { 'listening' } else { @{ booting = 'booting'; ready = 'ready'; registered = 'registered'; failed = 'failed'; shutting_down = 'shutting_down' }[[string]$d.phase] })
                $why = $(if ($s.Bad) { 'agent state unreadable' } else { Get-AapGuestRefusal $Ctx $d $e })
                if ($s.Bad) { $status = 'error'; $state = 'failed'; $diag = $why }   # check:state-bad
                elseif ($why) { $status = 'refused'; $diag = $why }
                else {
                    # Accepted: recorded before anything runs, so a command that crashes half-way is never accepted twice.
                    $d.reservation_id = $e.reservation_id; $d.lease_generation = $e.lease_generation; $d.seq = $e.seq; $d.nonces = @($d.nonces) + $e.nonce
                    if ($script:OneShot -ccontains $e.cmd) { $d.shots = @($d.shots) + $e.cmd }
                    Save-AapGuestState $s
                    switch -CaseSensitive ($e.cmd) {
                        'probe' {
                            if ($d.phase -ceq 'booting') {
                                # The bootstrap may outlast one probe: it runs with the state file released.
                                $s.Stream.Dispose(); $s = $null
                                $b = Invoke-AapGuestBootstrap $Ctx
                                $s = Open-AapGuestState $Ctx
                                if ($null -eq $s -or $s.Bad) { throw 'agent state unavailable after the bootstrap' }
                                $d = $s.Doc
                                if ($b.State -cne 'booting' -and $d.phase -ceq 'booting') { $d.phase = $b.State; $d.detail = $b.Detail }
                                $state = $b.State; $diag = $b.Detail
                                if ($b.State -ceq 'failed') { $status = 'error' } else { $status = 'ok' }
                            } elseif ($d.phase -ceq 'ready') { $status = 'ok'; $state = 'ready'; $diag = 'ready' }
                            else { $diag = $(if ($d.phase -ceq 'failed') { [string]$d.detail } else { 'probe after ready' }) }
                        }
                        'deliver_registration' {
                            # A JIT config is base64 text; checked byte by byte, so no text copy of it is made here.
                            $shape = $true
                            foreach ($x in $payload) {
                                if (-not (($x -ge 65 -and $x -le 90) -or ($x -ge 97 -and $x -le 122) -or ($x -ge 48 -and $x -le 57) -or $x -eq 43 -or $x -eq 47 -or $x -eq 61)) { $shape = $false; break }
                            }
                            if ($d.phase -cne 'ready') { $diag = "deliver_registration in phase $($d.phase)" }   # check:deliver-phase
                            elseif (-not $shape) { $diag = 'registration payload is not a JIT config' }   # check:deliver-shape
                            else {
                                # Only inside the runner root (guest-transport.md, JIT secrecy rule), until launch.ps1 takes it.
                                [IO.File]::WriteAllBytes((Join-Path (Get-AapGuestRunnerRoot $Ctx) $script:JitFile), $payload)
                                $d.phase = 'registered'; $status = 'ok'; $state = 'registered'; $diag = 'registration held in the runner root'
                            }
                        }
                        'start_runner' {
                            $left = @(Get-AapGuestResidue $Ctx)
                            if ($d.phase -cne 'registered') { $diag = "start_runner in phase $($d.phase)" }   # check:start-phase
                            elseif ($left.Count) { $d.phase = 'failed'; $diag = $left[0] }   # check:start-residue
                            else {
                                $until = (& $Ctx.Ops.Now).AddSeconds($Ctx.StartWaitSeconds)
                                Write-AapGuestRecord (Get-AapGuestLaunchPath $Ctx) ([ordered]@{ phase = 'requested'; deadline = $until.Ticks })
                                & $Ctx.Ops.StartLauncher $Ctx
                                $d.phase = 'started'
                                Save-AapGuestState $s
                                $rs = Get-AapGuestRunnerState $Ctx
                                while (@('running', 'exited', 'failed') -cnotcontains $rs.Phase -and (& $Ctx.Ops.Now) -lt $until) {
                                    Start-Sleep -Milliseconds $Ctx.PollMilliseconds
                                    $rs = Get-AapGuestRunnerState $Ctx
                                }
                                $left = @(Get-AapGuestResidue $Ctx -Started)
                                $state = $rs.State; $diag = $rs.Detail
                                if ($left.Count) { $state = 'failed'; $diag = $left[0] }   # check:start-jit-gone
                                elseif ($rs.Phase -ceq 'running' -and @('listening', 'busy') -ccontains $rs.State) { $status = 'ok' }
                                elseif ($rs.Phase -cne 'exited' -and $rs.Phase -cne 'failed') { $state = 'failed'; $diag = "runner not started within $($Ctx.StartWaitSeconds) s" }
                                # Anything but a listening runner: the launcher must not start one later on a VM the host gives up.
                                if ($status -cne 'ok') { [IO.File]::WriteAllText((Join-Path $Ctx.StateDir 'cancel'), 'cancelled') }   # check:start-cancel
                            }
                        }
                        { $_ -ceq 'status' -or $_ -ceq 'collect' } {
                            if ($d.phase -cne 'started') { $diag = "$($e.cmd) before the runner started" }
                            else {
                                $rs = Get-AapGuestRunnerState $Ctx
                                $status = 'ok'; $state = $rs.State; $exit = $rs.Exit; $diag = $rs.Detail
                                if ($e.cmd -ceq 'collect') {
                                    $c = $null
                                    try { $c = & $Ctx.Ops.CacheState $Ctx } catch { $c = $null }
                                    $diag = 'runner: {0}; exit {1}; cache {2}: {3}' -f $rs.Detail, $(if ($null -eq $exit) { 'unknown' } else { $exit }),
                                    (Get-AapGuestText ([string](Get-AapGuestProp $c 'state')) 20), (Get-AapGuestText ([string](Get-AapGuestProp $c 'detail')) 200)
                                }
                            }
                        }
                        'shutdown' {
                            $d.phase = 'shutting_down'; $status = 'ok'; $state = 'shutting_down'; $diag = 'shutting down'
                            Save-AapGuestState $s
                            & $Ctx.Ops.Shutdown
                        }
                    }
                    Save-AapGuestState $s
                }
            }
        } catch { $status = 'error'; $exit = $null; $diag = 'agent error: ' + $_.Exception.GetType().Name }
        $b = $script:Ascii.GetBytes((Format-AapGuestReply $e $status $state $exit $diag) + "`n")
        $Out.Write($b, 0, $b.Length)
        $Out.Flush()
        0
    } finally {
        [Array]::Clear($payload, 0, $payload.Length)
        if ($null -ne $s) { $s.Stream.Dispose() }
    }
}

function Install-AapGuestAgent {
    <# Image overlay (P21): copies agent.ps1, launch.ps1 and this module into InstallDir (C:\Program Files\aap-guest),
       SYSTEM and Administrators only. The actions-runner goes to <InstallDir>\runner and zccache to <InstallDir>\cache
       (Install-AapZcCache), both inside this folder. #>
    param([Parameter(Mandatory)][string]$InstallDir)
    [void][IO.Directory]::CreateDirectory($InstallDir)
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    Set-AapGuestAcl $InstallDir -WithSelf:(-not (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
    foreach ($f in 'agent.ps1', 'launch.ps1', 'AapGuestAgent.psm1') { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $f) -Destination (Join-Path $InstallDir $f) -Force }
}

Export-ModuleMember -Function New-AapGuestContext, Invoke-AapGuestAgent, Start-AapGuestRunner, Wait-AapGuestRunner, Install-AapGuestAgent
