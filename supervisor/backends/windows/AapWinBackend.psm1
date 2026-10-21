# Windows VM backend (ledger item P10): the supervisor-side provider for `hyperv-vm` Windows reservations.
# Windows PowerShell 5.1 and PowerShell 7.5 or later (the allocator module refuses 6.0 to 7.4).
#
# Contracts: parity/contracts/backend-lifecycle.md (version 2), guest-transport.md (version 1), allocator.md
# (version 2, "Provider rules for P10 and P11") and broker.md (version 1).
#
# Invoke-AapWinStep moves one reservation one step, by its allocator state:
#   creating   create (base re-hash, differencing and scratch disks, per-clone credential, VM, network), boot, ready (probe)
#   ready      run_one: broker lease, deliver_registration (JIT on the call child's stdin), start_runner
#   ready, busy, draining   heartbeat: guest status over the host-side channel, JobRunning from the broker
#   every step of a reservation with a VM: the clone cap and a paused VM, host-side, with or without a guest channel
#   collecting collect (the bounded job summary)        deleting   destroy (release, VM, folders, observed absence)
# The journal, <JournalRoot>\<reservation_id>.jsonl (one backend-lifecycle `op` record per line, admin-only), is the
# state: every op appends `intent` before it acts and `done` or `failed` after, so a supervisor killed anywhere resumes
# from it. The per-clone guest credential lives only in this process (guest-transport.md); after a restart a VM that
# runs no job is destroyed, and one that does runs to its end under the broker's status. A job is never cancelled here:
# only a hostile guest, the clone cap or a paused VM (backend-lifecycle.md) end a running VM.
#
# Hyper-V, disk, volume and hash calls go through $Backend.Provider (AapWinBackend.HyperV.psm1 in production, fakes in
# tests), the guest network through $Backend.Network (the P10.0 interface: Attach, Detach, Verify), the guest channel
# through $Backend.Transport (the capped psdirect-call.ps1 child by default) and the clock through $Backend.Now.
# Allocator and broker calls go to AapCapacity.psm1 and aap-broker.psm1 beside this folder.
# Lines tagged '# check:<name>' are the safety checks tests/backends/windows/Invoke-AapWinMutations.ps1 disables one at a
# time; each must make at least one test fail.
# One backend context ($B) belongs to one runspace: its hashtables, its scriptblocks and the process-wide console input
# encoding swap around each child start are not thread-safe. Steps of one reservation never overlap: Invoke-AapWinStep
# holds <JournalRoot>\<reservation_id>.lock (FileShare.None, deleted on close) for the whole step.

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\..\capacity\AapCapacity.psm1')
Import-Module (Join-Path $PSScriptRoot '..\..\broker\aap-broker.psm1')

$script:ImageProfile = 'win25-vs2026-x64'
$script:User = 'runneradmin'            # the job user P06 verified with; created per clone by the answer file
$script:SwitchName = 'aap-guests-win'   # P10.0's internal switch; never External, never Default Switch
$script:ChildExe = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$script:ChildScript = Join-Path $PSScriptRoot 'psdirect-call.ps1'
$script:ChildMemoryBytes = 536870912    # job object cap on the call child, all its processes together
$script:ReplyMax = 8192
$script:ReadMax = 8193                  # one byte past the reply bound: more is a hostile guest
$script:EnvelopeMax = 1024
$script:PayloadMax = 16384
$script:Timeouts = @{ probe = 30; deliver_registration = 30; start_runner = 60; status = 15; collect = 60 }
# guest_state values a well-behaved agent can answer to each command (anything else is hostile, code bad_state).
$script:Answers = @{ probe = @('booting', 'ready'); deliver_registration = @('registered', 'listening'); start_runner = @('listening', 'busy')
    status = @('listening', 'busy', 'job_done', 'failed'); collect = @('listening', 'busy', 'job_done', 'failed', 'shutting_down')
}
$script:GuestStates = @('booting', 'ready', 'registered', 'listening', 'busy', 'job_done', 'failed', 'shutting_down')
$script:ReplyKeys = @('schema', 'kind', 'vm_id', 'reservation_id', 'lease_generation', 'seq', 'nonce', 'status', 'guest_state', 'runner_exit_code', 'diag')
$script:BootMinutes = 15                # guest-transport.md: probe until 15 min after Start-VM
$script:LeaseWindowMinutes = 15         # a lease call the broker never recorded cannot be recorded after this (55 s run cap)
$script:RetrySeconds = 60               # a pending release is asked again at most this often
$script:TeardownTries = 3               # ARCHITECTURE.md section 10: three retries over 15 s, then quarantined
$script:TeardownPauseSeconds = 5
# ponytail: fixed VHDX metadata headroom under scratch_gib; replace with the P02.1 measurement of a full VHDX.
$script:ScratchHeadroomBytes = 67108864
$script:GiB = 1073741824
$script:JournalMax = 4194304
$script:AdminSids = @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
# WriteData, AppendData, WriteEA, DeleteChild, WriteAttributes, Delete, WriteDAC, WriteOwner, GenericAll, GenericWrite.
$script:WriteMask = 0x500D0156
$script:SecretValue = 'gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|SYNTHETIC-JIT-MARKER'
$script:GuidRe = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z'
$script:RidRe = '^r-[0-9a-f]{16}\z'
$script:GenerationRe = '^win25-vs2026-x64/[0-9]{8}\.[0-9]+\.[0-9]+-aap\.[0-9]+\z'
$script:Reserved = '^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9]) *(\..*)?$'
$script:ProviderOps = @('GetVolumeGuid', 'GetHostSecurity', 'HashFile', 'NewDiffDisk', 'GetVhdParent', 'NewDisk', 'WriteUnattend', 'NewVm',
    'GetVmConfig', 'StartVm', 'StopVm', 'RemoveVm', 'ListVms', 'MeasureBytes')
$script:VmGroupSid = 'S-1-5-83-0'      # NT VIRTUAL MACHINE\Virtual Machines: may read a sealed base (P06), nothing more
# The lease outcomes journaled right after the lease call (a repeated `ready` `done` record: `op` has no lease field), so a
# restarted supervisor never takes a broker that lost an issued lease for one that never recorded it.
$script:LeaseAnswers = @('lease issued by the broker', 'lease answer unreadable')
$script:DrainOnline = 'runner online and idle; released at destroy'
$script:StatusSeconds = 30             # guest and broker status at most this often per reservation (allocator: 30 s heartbeat)
$script:DrainKeepHours = 6              # a drained VM kept for its pending release is flagged after this (allocator's wall clock)
$script:Utf8 = New-Object Text.UTF8Encoding($false)
$script:NetworkOps = @('Attach', 'Detach', 'Verify')
$script:Ops = @('create', 'boot', 'ready', 'run_one', 'drain', 'collect', 'destroy')
# Legal allocator edges down to deleting (draining always passes through collecting).
$script:Down = @{ creating = @('deleting'); ready = @('draining', 'collecting', 'deleting'); busy = @('collecting', 'deleting')
    draining = @('collecting', 'deleting'); collecting = @('deleting')
}
$script:Inv = [Globalization.CultureInfo]::InvariantCulture
$script:DateKind = (Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')
$script:Fault = $null                   # test hook: a fault point name; the process kills itself there

# ---- small helpers ----------------------------------------------------------------------------------------------------

function Invoke-AapWinFault([string]$Point) {
    if ($script:Fault -ceq $Point) {
        [Diagnostics.Process]::GetCurrentProcess().Kill()
        Start-Sleep -Seconds 30
    }
}

function Get-AapWinNow($B) { ([datetime](& $B.Now)).ToUniversalTime() }
function Format-AapWinTime([datetime]$Time) { $Time.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $script:Inv) }
function ConvertTo-AapWinUtc($Value) {
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    [DateTime]::ParseExact([string]$Value, "yyyy-MM-dd'T'HH:mm:ss'Z'", $script:Inv, [Globalization.DateTimeStyles]'AssumeUniversal, AdjustToUniversal')
}
function ConvertFrom-AapWinJson([string]$Text) {
    if ($script:DateKind) { return , (ConvertFrom-Json -InputObject $Text -DateKind String) }
    , (ConvertFrom-Json -InputObject $Text)
}
function New-AapWinHex([int]$Bytes) {
    $b = New-Object byte[] $Bytes
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($b) } finally { $rng.Dispose() }
    (($b | ForEach-Object { $_.ToString('x2') }) -join '')
}
# A field of a hashtable or object by exact name, $null when absent.
function Get-AapWinField($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    # The comma keeps an array (a byte[] above all) in one piece through the function's output.
    if ($Object -is [Collections.IDictionary]) { if ($Object.Contains($Name)) { return , $Object[$Name] } else { return $null } }
    foreach ($p in $Object.PSObject.Properties) { if ([string]::Equals($p.Name, $Name, [StringComparison]::Ordinal)) { return , $p.Value } }
    $null
}
# One printable-ASCII line of at most Max characters (journal details, quarantine reasons, results).
function Get-AapWinLine([string]$Text, [int]$Max = 200) {
    if ($null -eq $Text) { return '' }
    $t = [regex]::Replace($Text, '[^\x20-\x7e]', ' ')
    if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max) }
    $t
}
# 'AAP_<Reason>: detail' of an error record, one bounded line.
function Get-AapWinError($ErrorRecord) { Get-AapWinLine ([string]$ErrorRecord.Exception.Message) 200 }

function New-AapWinPassword {
    <# The per-clone password: 32 random characters with upper, lower, digit and symbol, no space or quote. Returned as an
       object whose only property is Length (the broker's JitConfig pattern), so it formats, serializes and logs as nothing
       else; WriteTo(stream) writes its ASCII bytes and Clear() zeroes them. Built with .NET calls only, so the characters
       are never a command's parameter value (module logging, event 4103, records those). Memory only: never in a file,
       log, journal or record outside the clone's own answer file. #>
    $alphabet = [Text.Encoding]::ASCII.GetBytes('ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789-_=+.,:!@#%')
    $pwBytes = New-Object byte[] 32
    $raw = New-Object byte[] 64
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        do {
            $rng.GetBytes($raw)
            $n = 0
            foreach ($b in $raw) { if ($b -lt 204 -and $n -lt 32) { $pwBytes[$n] = $alphabet[$b % 68]; $n++ } }
            $up = $lo = $digit = $other = $false
            foreach ($c in $pwBytes) {
                if ($c -ge 65 -and $c -le 90) { $up = $true } elseif ($c -ge 97 -and $c -le 122) { $lo = $true } elseif ($c -ge 48 -and $c -le 57) { $digit = $true } else { $other = $true }
            }
        } until ($n -eq 32 -and $up -and $lo -and $digit -and $other)
    } finally { $rng.Dispose(); [Array]::Clear($raw, 0, $raw.Length) }
    $secret = [pscustomobject]@{ Length = $pwBytes.Length }
    $writeTo = { param([IO.Stream]$Stream) $Stream.Write($pwBytes, 0, $pwBytes.Length) }.GetNewClosure()
    $clear = { [Array]::Clear($pwBytes, 0, $pwBytes.Length) }.GetNewClosure()
    $secret.PSObject.Methods.Add([Management.Automation.PSScriptMethod]::new('WriteTo', $writeTo))
    $secret.PSObject.Methods.Add([Management.Automation.PSScriptMethod]::new('Clear', $clear))
    $secret
}

# ---- paths (the patterns of images/windows/AapWinImage.psm1, P06) -----------------------------------------------------

# What one path is, without following it: 'absent', 'link' (any reparse point), 'dir' or 'file'. Access denied and every
# other error propagate, so an unreadable entry is never taken for an absent one.
function Get-AapWinPathKind([string]$Path) {
    try { $attr = [int][IO.File]::GetAttributes($Path) } catch [IO.FileNotFoundException], [IO.DirectoryNotFoundException] { return 'absent' }
    if (($attr -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) { return 'link' }
    if (($attr -band [int][IO.FileAttributes]::Directory) -ne 0) { return 'dir' }
    'file'
}

# Walks $Path down from $Root one component at a time and refuses a reparse point anywhere on the way, $Root included.
# With -Create, missing folders are created on the way.
function Assert-AapWinPlainPath {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Reason, [switch]$Create)
    $r = [IO.Path]::GetFullPath($Root); $full = [IO.Path]::GetFullPath($Path)
    if ($r.Length -gt 3) { $r = $r.TrimEnd('\') }
    if ($full.Length -gt 3) { $full = $full.TrimEnd('\') }
    $prefix = $(if ($r.EndsWith('\')) { $r } else { $r + '\' })
    if ($full -ne $r -and -not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw "${Reason}: not below its root: $full" }
    $segs = @($(if ($full.Length -gt $r.Length) { $full.Substring($prefix.Length).Split('\') }))
    $walk = $r
    $kind = Get-AapWinPathKind $walk
    foreach ($seg in @('') + $segs) {
        if ($seg) {
            $walk = Join-Path $walk $seg
            $kind = Get-AapWinPathKind $walk
            if ($kind -eq 'absent' -and $Create) { [void][IO.Directory]::CreateDirectory($walk); $kind = Get-AapWinPathKind $walk }
            if ($kind -eq 'absent') { return }
        }
        if ($kind -ne 'dir') { throw "${Reason}: $(@{ link = 'a link'; file = 'a file'; absent = 'missing' }[$kind]), not a plain folder: $walk" }   # check:plain-path
    }
}

# Gives this process's user full control of one entry, replacing its DACL, so an entry whose ACL forbids the delete can
# be deleted right after (an administrator owns every file the supervisor created).
function Grant-AapWinOwnerAccess([string]$Path, [bool]$IsDir) {
    # Setting an ACL follows a link to its target: a link is never re-permissioned, only removed as an entry.
    if ((Get-AapWinPathKind $Path) -ceq 'link') { throw "AAP_UnsafeDelete: a link: $Path" }   # check:grant-link
    $sec = $(if ($IsDir) { New-Object Security.AccessControl.DirectorySecurity } else { New-Object Security.AccessControl.FileSecurity })
    $sec.SetAccessRuleProtection($true, $false)
    $sec.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule ([Security.Principal.WindowsIdentity]::GetCurrent().User), 'FullControl', 'Allow'))
    $info = $(if ($IsDir) { New-Object IO.DirectoryInfo $Path } else { New-Object IO.FileInfo $Path })
    if ($PSVersionTable.PSVersion.Major -ge 6) { [IO.FileSystemAclExtensions]::SetAccessControl($info, $sec) } else { $info.SetAccessControl($sec) }
}

# Deletes $Path, which must lie strictly below $Under, without following any junction or symbolic link: a link is removed
# as an entry, never entered, so a link a guest or anyone else planted never redirects the delete.
function Remove-AapWinTree([string]$Path, [string]$Under) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\'); $root = [IO.Path]::GetFullPath($Under).TrimEnd('\')
    if (-not $full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "AAP_UnsafeDelete: not below its root: $full" }
    $walk = $root
    foreach ($seg in $full.Substring($root.Length + 1).Split('\')) {
        if ((Get-AapWinPathKind $walk) -eq 'link') { throw "AAP_UnsafeDelete: a link: $walk" }   # check:safe-delete
        $walk = Join-Path $walk $seg
    }
    $kind = Get-AapWinPathKind $full
    if ($kind -eq 'absent') { return }
    if ($kind -eq 'dir') { Remove-AapWinTreeInner $full } else { Remove-AapWinEntry $full $kind }
}
function Remove-AapWinTreeInner([string]$Dir) {
    try { $entries = [IO.Directory]::GetFileSystemEntries($Dir) } catch [UnauthorizedAccessException] { Grant-AapWinOwnerAccess $Dir $true; $entries = [IO.Directory]::GetFileSystemEntries($Dir) }
    foreach ($e in $entries) {
        $kind = Get-AapWinPathKind $e
        if ($kind -eq 'dir') { Remove-AapWinTreeInner $e } else { Remove-AapWinEntry $e $kind }
    }
    Remove-AapWinEntry $Dir 'dir'
}
function Remove-AapWinEntry([string]$Path, [string]$Kind) {
    $isDir = $Kind -eq 'dir' -or ($Kind -eq 'link' -and (([int][IO.File]::GetAttributes($Path)) -band [int][IO.FileAttributes]::Directory) -ne 0)
    $once = { if ($isDir) { [IO.Directory]::Delete($Path, $false) } else { [IO.File]::SetAttributes($Path, [IO.FileAttributes]::Normal); [IO.File]::Delete($Path) } }
    try { & $once } catch [UnauthorizedAccessException] { if ($Kind -ceq 'link') { throw }; Grant-AapWinOwnerAccess $Path $isDir; & $once }
}

# ---- guest disk preparation (exported for the production provider; P06's rules) --------------------------------------

function Select-AapWinPartition {
    <# The Windows partition of a clone disk: exactly EFI, MSR and one basic data partition, numbers 1 to 3, the layout P06
       builds. Anything else is refused, so a decoy partition is never written to. #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Partitions)
    $p = @($Partitions | Sort-Object { [int]$_.PartitionNumber })
    $types = (@($p | ForEach-Object { ([string]$_.GptType).ToLowerInvariant() }) -join ',')
    $numbers = (@($p | ForEach-Object { [int]$_.PartitionNumber }) -join ',')
    if ($types -cne '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b},{e3c9e316-0b5c-4db8-817d-f92df00215ae},{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}' -or $numbers -ne '1,2,3') {   # check:disk-layout
        throw 'AAP_DiskLayout: the clone disk does not have the EFI, MSR, Windows layout of its base'
    }
    $p[2]
}

function Test-AapWinAdmin { (New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }

# A protected DACL for a new entry: SYSTEM and Administrators; the elevated supervisor (or SYSTEM) writes through its
# Administrators entry. Only a token outside Administrators (an unelevated test) adds its own identity, to write what it
# creates: the owner's account SID, which every unelevated process of the owner carries, never gets an entry in
# production. Containers inherit it.
function New-AapWinSecurity([bool]$IsDir, [bool]$Admin = (Test-AapWinAdmin)) {
    $f = $(if ($IsDir) { 'OICI' } else { '' })
    $sddl = "D:P(A;$f;FA;;;SY)(A;$f;FA;;;BA)"
    if (-not $Admin) { $sddl += "(A;$f;FA;;;$([Security.Principal.WindowsIdentity]::GetCurrent().User.Value))" }   # check:own-sid
    $sec = $(if ($IsDir) { New-Object Security.AccessControl.DirectorySecurity } else { New-Object Security.AccessControl.FileSecurity })
    $sec.SetSecurityDescriptorSddlForm($sddl)
    $sec
}
# A new folder with $Security from its creation (no window with an inherited DACL).
function New-AapWinDir([string]$Path, $Security) {
    $ext = 'System.IO.FileSystemAclExtensions' -as [type]
    if ($ext -and $ext.GetMethod('Create', [type[]]@([IO.DirectoryInfo], [Security.AccessControl.DirectorySecurity]))) { [void]$ext::Create([IO.DirectoryInfo]$Path, $Security) }
    else { [void][IO.Directory]::CreateDirectory($Path, $Security) }
}

function Write-AapWinUnattend {
    <# The per-clone answer file (images/windows/INTEGRATION.md, P10 item 2): one local administrator, OOBE skipped, UTC,
       en-US, SanPolicy 1 so the scratch disk comes online, never autologon. Written to Windows\Panther\unattend.xml under
       $Root, the Windows partition of a clone disk that never booted, mounted with no drive letter at an access path inside
       the admin-only reservation folder. -Password is New-AapWinPassword's object: the text is built and written here with
       .NET calls only, never bound to a command (event 4103). $Root itself is the provider's volume mount point (a
       reparse point by design, inside the admin-only reservation folder); every folder below it must be plain, a missing
       one is created, and the file created new, with a protected SYSTEM/Administrators DACL, so nothing on the disk
       redirects the write and no other account reads it. The guest agent deletes the file at first boot (guest-transport.md). #>
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$UserName, [Parameter(Mandatory)]$Password)
    if ($UserName -cnotmatch '^[A-Za-z][A-Za-z0-9_-]{0,19}$') { throw 'AAP_UnattendInvalid: user name' }
    $dir = $Root
    foreach ($seg in @('', 'Windows', 'Panther')) {
        if ($seg) { $dir = Join-Path $dir $seg }
        $kind = Get-AapWinPathKind $dir
        if ($kind -eq 'link' -and -not $seg) { continue }   # check:unattend-root
        if ($kind -eq 'absent' -and $seg) { New-AapWinDir $dir (New-AapWinSecurity $true); $kind = Get-AapWinPathKind $dir }
        if ($kind -ne 'dir') { throw "AAP_UnsafePath: $(@{ link = 'a link'; file = 'a file'; absent = 'missing' }[$kind]), not a plain folder: $dir" }   # check:guest-write
    }
    $target = Join-Path $dir 'unattend.xml'
    $kind = Get-AapWinPathKind $target
    if ($kind -eq 'link' -or $kind -eq 'dir') { throw "AAP_UnsafePath: a $kind where the answer file goes: $target" }   # check:guest-write
    if ($kind -eq 'file') { [IO.File]::SetAttributes($target, [IO.FileAttributes]::Normal); [IO.File]::Delete($target) }
    $ms = New-Object IO.MemoryStream
    try {
        $Password.WriteTo($ms)
        $pwText = [Text.Encoding]::ASCII.GetString($ms.GetBuffer(), 0, [int]$ms.Length)
    } finally { $buf = $ms.GetBuffer(); [Array]::Clear($buf, 0, $buf.Length); $ms.Dispose() }
    $c = 'processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"'
    $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="specialize">
    <component name="Microsoft-Windows-PartitionManager" $c>
      <SanPolicy>1</SanPolicy>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" $c>
      <ComputerName>*</ComputerName>
      <TimeZone>UTC</TimeZone>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" $c>
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" $c>
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Name>$UserName</Name>
            <Group>Administrators</Group>
            <Password>
              <Value>$([Security.SecurityElement]::Escape($pwText))</Value>
              <PlainText>true</PlainText>
            </Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
    </component>
  </settings>
</unattend>
"@
    $pwText = $null
    [void]([xml]$xml)
    $xmlBytes = $script:Utf8.GetBytes($xml)
    $xml = $null
    try {
        $sec = New-AapWinSecurity $false
        if ($PSVersionTable.PSVersion.Major -ge 6) {
            $fs = [IO.FileSystemAclExtensions]::Create([IO.FileInfo]$target, [IO.FileMode]::CreateNew, [Security.AccessControl.FileSystemRights]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::None, $sec)
        } else {
            $fs = New-Object IO.FileStream($target, [IO.FileMode]::CreateNew, [Security.AccessControl.FileSystemRights]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::None, $sec)
        }
        try { $fs.Write($xmlBytes, 0, $xmlBytes.Length) } finally { $fs.Dispose() }
    } finally { [Array]::Clear($xmlBytes, 0, $xmlBytes.Length) }
}

# ---- trust: the admin-only definition of backend-lifecycle.md, Trust checks -------------------------------------------

function Test-AapWinReparse([string]$Path) {
    $attr = -1
    try { $attr = [int](New-Object IO.FileInfo $Path).Attributes } catch { $attr = -1 }
    $attr -ne -1 -and ($attr -band [int][IO.FileAttributes]::ReparsePoint) -ne 0
}
function Get-AapWinRawSd([string]$Path) {
    $acl = Get-Acl -LiteralPath $Path
    New-Object Security.AccessControl.RawSecurityDescriptor($acl.GetSecurityDescriptorBinaryForm(), 0)
}

# Get-AapAncestorProblem of install-supervisor.ps1: an admin owner and no other SID that may delete, delete children,
# re-permission or take ownership (create rights are allowed; inherit-only ACEs do not apply to the folder itself).
function Get-AapWinAncestorAclProblem([string]$Dir) {
    $bad = [int]([Security.AccessControl.FileSystemRights]'Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership') -bor 0x10000000
    try { $raw = Get-AapWinRawSd $Dir } catch { return "cannot read the ACL: $Dir" }
    if ($null -eq $raw.Owner -or $script:AdminSids -notcontains $raw.Owner.Value) { return "owner $($raw.Owner) is not an admin: $Dir" }
    if ($null -eq $raw.DiscretionaryAcl) { return "no DACL (everyone has full control): $Dir" }
    foreach ($ace in $raw.DiscretionaryAcl) {
        $type = [int]$ace.AceType
        if ($type -ne 0 -and $type -ne 1) { return "an ACE that is not a plain allow or deny: $Dir" }
        if ($type -ne 0 -or ([int]$ace.AceFlags -band 8) -ne 0) { continue }
        if ($script:AdminSids -contains $ace.SecurityIdentifier.Value) { continue }
        if (([int]$ace.AccessMask -band $bad) -ne 0) { return "grants $($ace.SecurityIdentifier.Value) delete or re-permission rights: $Dir" }
    }
    $null
}

# The problems of one root: a normalized path on a fixed drive, plain ancestors with admin owners, the root itself a plain
# folder with a trusted owner and a protected DACL, and no ACE for anyone else (-AllowRead: read and execute only, not
# inheritable). An empty list means trusted.
function Get-AapWinTrustProblem($B, [string]$Path, [switch]$AllowRead) {
    $out = New-Object Collections.Generic.List[string]
    if ($Path -notmatch '^[A-Za-z]:\\.+' -or $Path.EndsWith('\') -or [IO.Path]::GetFullPath($Path) -cne $Path) {
        $out.Add("not a normalized absolute path on a drive: $Path")
        return $out.ToArray()
    }
    $fixed = $false
    try { $fixed = (New-Object IO.DriveInfo($Path.Substring(0, 1))).DriveType -eq [IO.DriveType]::Fixed } catch { $fixed = $false }
    if (-not $fixed) { $out.Add("not on a fixed local drive: $Path") }   # check:fixed-drive
    $dir = Split-Path -Parent $Path
    while ($dir) {
        if (Test-AapWinReparse $dir) { $out.Add("reparse point above the root: $dir") }   # check:ancestor-reparse
        elseif (-not $B.Relaxed) { $p = Get-AapWinAncestorAclProblem $dir; if ($p) { $out.Add($p) } }
        $dir = Split-Path -Parent $dir
    }
    if (Test-AapWinReparse $Path) { $out.Add("reparse point: $Path"); return $out.ToArray() }   # check:root-reparse
    if (-not [IO.Directory]::Exists($Path)) { $out.Add("does not exist: $Path"); return $out.ToArray() }
    try { $raw = Get-AapWinRawSd $Path } catch { $out.Add("cannot read the ACL: $Path"); return $out.ToArray() }
    if ($null -eq $raw.Owner -or $B.TrustedSids -notcontains $raw.Owner.Value) { $out.Add("owner $($raw.Owner) is not an admin: $Path") }   # check:root-owner
    if (([int]$raw.ControlFlags -band 0x1000) -eq 0) { $out.Add("inherits its DACL from its parent: $Path") }   # check:acl-protected
    if ($null -eq $raw.DiscretionaryAcl) { $out.Add("no DACL (everyone has full control): $Path"); return $out.ToArray() }
    foreach ($ace in $raw.DiscretionaryAcl) {
        $type = [int]$ace.AceType
        if ($type -ne 0 -and $type -ne 1) { $out.Add("an ACE that is not a plain allow or deny: $Path"); continue }
        if ($type -ne 0) { continue }
        $sid = $ace.SecurityIdentifier.Value
        if ($B.TrustedSids -contains $sid) { continue }
        if (-not $AllowRead) { $out.Add("grants $sid access (it must be admin-only): $Path"); continue }   # check:admin-only
        if ((([int]$ace.AccessMask) -band $script:WriteMask) -ne 0 -or (([int]$ace.AceFlags) -band 3) -ne 0) { $out.Add("grants $sid write or inheritable access: $Path") }   # check:no-write
    }
    $out.ToArray()
}

# A sealed generation entry (P06's read-only signature, images/windows/INTEGRATION.md): an admin owner, a protected DACL,
# no allow entry for anyone but the admins and Virtual Machines (S-1-5-83-0, read only) and, for the file, the ReadOnly
# attribute. Hyper-V only reads the parent of a differencing disk, so nobody but an administrator may change the base.
function Get-AapWinSealedProblem($B, [string]$Path) {
    try { $raw = Get-AapWinRawSd $Path } catch { return "cannot read the ACL: $Path" }
    if ($null -eq $raw.Owner -or $B.TrustedSids -notcontains $raw.Owner.Value) { return "owner $($raw.Owner) is not an admin: $Path" }   # check:sealed-owner
    if (([int]$raw.ControlFlags -band 0x1000) -eq 0) { return "inherits its DACL from its parent: $Path" }   # check:sealed-acl
    if ($null -eq $raw.DiscretionaryAcl) { return "no DACL (everyone has full control): $Path" }
    foreach ($ace in $raw.DiscretionaryAcl) {
        $type = [int]$ace.AceType
        if ($type -ne 0 -and $type -ne 1) { return "an ACE that is not a plain allow or deny: $Path" }
        if ($type -ne 0 -or $B.TrustedSids -contains $ace.SecurityIdentifier.Value) { continue }
        if ($ace.SecurityIdentifier.Value -cne $script:VmGroupSid -or ([int]$ace.AccessMask -band $script:WriteMask) -ne 0) { return "grants $($ace.SecurityIdentifier.Value) more than Virtual Machines read: $Path" }   # check:sealed-acl
    }
    if ((Get-AapWinPathKind $Path) -ceq 'file' -and (([int][IO.File]::GetAttributes($Path)) -band [int][IO.FileAttributes]::ReadOnly) -eq 0) { return "not ReadOnly: $Path" }   # check:sealed-readonly
    $null
}

# -RelaxedTrustForTests trusts the current user and skips the ancestor ACL check (P09's rule): refused for SYSTEM and for
# any folder below ProgramData, Program Files or Windows.
function Get-AapWinRelaxedProblem([string[]]$Paths) {
    if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ceq 'S-1-5-18') { return 'relaxed trust is refused for SYSTEM' }
    $sf = [Environment+SpecialFolder]
    foreach ($d in @($sf::CommonApplicationData, $sf::ProgramFiles, $sf::ProgramFilesX86, $sf::Windows)) {
        $dir = [Environment]::GetFolderPath($d)
        if (-not $dir) { continue }
        foreach ($p in $Paths) { if (($p + '\').StartsWith($dir.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { return "relaxed trust is for test folders only, never below $dir" } }
    }
    $null
}

# ---- storage document (backend-lifecycle.md, Storage tiers) ----------------------------------------------------------

function Test-AapWinRootForm([string]$Path) {
    if ($Path -cnotmatch '^[A-Za-z]:\\[A-Za-z0-9 ._()\-]+(\\[A-Za-z0-9 ._()\-]+)*\z') { return 'is not an absolute folder below a drive root' }
    foreach ($seg in $Path.Substring(3).Split('\')) {
        if ($seg -eq '.' -or $seg -eq '..') { return 'has a . or .. component' }
        if ($seg -match '[ .]$') { return 'has a component with a trailing dot or space' }
        if ($seg -match $script:Reserved) { return 'names a reserved device' }
    }
    $null
}

function Read-AapWinStorage([string]$Path) {
    if (-not [IO.File]::Exists($Path)) { throw "AAP_StorageMissing: no storage document at $Path; the VM profiles stay off until the installer writes one" }
    if ((New-Object IO.FileInfo $Path).Length -gt 65536) { throw "AAP_StorageInvalid: $Path is over 64 KiB" }
    try { $doc = ConvertFrom-AapWinJson ([IO.File]::ReadAllText($Path)) } catch { throw "AAP_StorageInvalid: $Path is not JSON" }
    if ((Get-AapWinField $doc 'schema') -ne 2 -or (Get-AapWinField $doc 'kind') -cne 'storage') { throw 'AAP_StorageInvalid: not a schema 2 storage document' }
    $floor = Get-AapWinField $doc 'volume_floor_gib'
    if (-not ($floor -is [int] -or $floor -is [long]) -or $floor -lt 10) { throw 'AAP_StorageInvalid: volume_floor_gib must be an integer of at least 10' }
    $s = @{ FloorGib = [int]$floor }
    foreach ($t in 'base_root', 'clone_root', 'scratch_root') {
        $r = Get-AapWinField (Get-AapWinField $doc 'roots') $t
        $p = [string](Get-AapWinField $r 'path'); $g = [string](Get-AapWinField $r 'volume_guid')
        $why = Test-AapWinRootForm $p
        if ($why) { throw "AAP_StorageInvalid: $t $why" }   # check:storage-form
        if ($g -cnotmatch $script:GuidRe) { throw "AAP_StorageInvalid: $t volume_guid is malformed" }
        $s[$t] = @{ Path = $p; Guid = $g }
    }
    $fixed = @('C:\ProgramData\aap-runner', [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows), 'C:\wsl') | Where-Object { $_ }
    foreach ($a in 'base_root', 'clone_root', 'scratch_root') {
        $pa = $s[$a].Path.ToLowerInvariant()
        foreach ($b in 'base_root', 'clone_root', 'scratch_root') {
            if ($a -eq $b) { continue }
            $pb = $s[$b].Path.ToLowerInvariant()
            if ($pa -eq $pb -or $pa.StartsWith($pb + '\')) { throw "AAP_StorageInvalid: $a is equal to or inside $b" }   # check:storage-nesting
        }
        foreach ($f in $fixed) {
            $pf = $f.TrimEnd('\').ToLowerInvariant()
            if ($pa -eq $pf -or $pa.StartsWith($pf + '\') -or $pf.StartsWith($pa + '\')) { throw "AAP_StorageInvalid: $a overlaps $f" }   # check:storage-nesting
        }
    }
    $s
}

# Every tier root's problems, '<tier>: <problem>' (empty = trusted). Run at supervisor start (P12 shows them in
# status.v5.json storage) and before every create.
function Get-AapWinStorageProblem {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Backend)
    $B = $Backend
    $out = New-Object Collections.Generic.List[string]
    foreach ($t in 'base_root', 'clone_root', 'scratch_root') {
        $root = $B.Storage[$t]
        foreach ($p in @(Get-AapWinTrustProblem $B $root.Path -AllowRead:($t -ceq 'base_root'))) { $out.Add("${t}: $p") }
        $g = ''
        try { $g = [string](& $B.Provider.GetVolumeGuid @{ Path = $root.Path }) } catch { $g = 'unreadable' }
        if ($g -cne $root.Guid) { $out.Add("${t}: on volume $(Get-AapWinLine $g 40), recorded $($root.Guid)") }   # check:volume
    }
    $out.ToArray()
}

function Get-AapWinHostProblem {
    <# The host settings a Windows VM profile needs: Enhanced Session Mode off (it opens an interactive console channel
       into every guest), and nobody in Hyper-V Administrators (S-1-5-32-578) but SYSTEM and Administrators (a member can
       drive every VM, read its disks and connect to it). 'AAP_<Reason>: detail' lines, empty = trusted. Run at supervisor
       start (P12 shows them and keeps the VM profiles off) and before every create. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Backend)
    $out = New-Object Collections.Generic.List[string]
    try { $h = & $Backend.Provider.GetHostSecurity @{} } catch { $out.Add("AAP_HostUnreadable: $(Get-AapWinError $_)"); return $out.ToArray() }
    if ((Get-AapWinField $h 'EnhancedSessionMode') -ne $false) { $out.Add('AAP_EnhancedSession: Enhanced Session Mode is not off on this Hyper-V host') }   # check:enhanced-session
    $members = Get-AapWinField $h 'HyperVAdmins'
    if ($null -eq $members) { $out.Add('AAP_HostUnreadable: the members of Hyper-V Administrators are unknown') }
    foreach ($sid in @($members | Where-Object { $null -ne $_ })) {
        if ($script:AdminSids -cnotcontains [string]$sid) { $out.Add("AAP_HyperVAdmins: $(Get-AapWinLine ([string]$sid) 80) is a member of Hyper-V Administrators") }   # check:hyperv-admins
    }
    $out.ToArray()
}

# ---- journal ----------------------------------------------------------------------------------------------------------

function Get-AapWinVmName($r) { Get-AapVmName -Profile windows -Slot ([int]$r.slot) -LeaseGeneration ([long]$r.lease_generation) -ReservationId ([string]$r.reservation_id) }
function Get-AapWinJournalPath($B, $r) { Join-Path $B.JournalRoot ([string]$r.reservation_id + '.jsonl') }

# Appends one `op` record and flushes it to disk before the caller acts (intent) or moves on (done, failed). A last line
# without its newline is a write a crash cut short: it is cut off first, so the new record never joins it.
function Write-AapWinJournal($B, $r, [string]$Op, [string]$Phase, [string]$VmId = '', [object[]]$Disks = @(), [string]$Code = '', [string]$Detail = '') {
    $result = $null
    if ($Phase -cne 'intent') { $result = [ordered]@{ code = $Code; detail = (Get-AapWinLine $Detail 200) } }
    $vm = $null
    if ($VmId) { $vm = $VmId }
    $rec = [ordered]@{
        schema = 2; kind = 'op'; reservation_id = [string]$r.reservation_id; lease_generation = [long]$r.lease_generation
        backend = 'hyperv-vm'; profile = 'windows'; image_generation = [string]$r.image_generation; op = $Op
        idempotency_key = ('{0}/{1}/{2}' -f $r.reservation_id, $r.lease_generation, $Op); phase = $Phase; at = (Format-AapWinTime (Get-AapWinNow $B))
        vm = [ordered]@{ vm_id = $vm; vm_name = (Get-AapWinVmName $r) }; disks = [object[]]$Disks; result = $result
    }
    $bytes = $script:Utf8.GetBytes((ConvertTo-Json -InputObject $rec -Depth 6 -Compress) + "`n")
    $fs = New-Object IO.FileStream((Get-AapWinJournalPath $B $r), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
    try {
        $keep = $fs.Length
        while ($keep -gt 0) { $fs.Position = $keep - 1; if ($fs.ReadByte() -eq 10) { break }; $keep-- }
        if ($keep -ne $fs.Length) { $fs.SetLength($keep); $fs.Flush($true) }   # check:journal-torn
        $fs.Position = $fs.Length
        $fs.Write($bytes, 0, $bytes.Length)
        $fs.Flush($true)
    } finally { $fs.Dispose() }
}

# A failed record, unless the journal's last record says exactly the same: a teardown that keeps failing the same way (a
# pending release, a VM that will not go) does not grow the journal toward its size bound.
function Write-AapWinFailedOnce($B, $r, $j, [string]$Op, [string]$VmId, [string]$Code, [string]$Detail) {
    if ($j.Last -ceq "$Op/failed/$Code/$(Get-AapWinLine $Detail 200)") { return }   # check:journal-dedup
    Write-AapWinJournal $B $r $Op 'failed' -VmId $VmId -Code $Code -Detail $Detail
}

# The facts the steps need, from the journal. Throws AAP_JournalUnreadable on anything but well-formed records of this
# reservation and lease generation. A last line without its newline was torn by a crash mid-append: that write never
# completed, so neither did its act (intent), or only the act's record is missing (done, failed); both re-run safely, and
# the next append cuts it off. Last is '<op>/<phase>/<code>/<detail>' of the last record.
function Read-AapWinJournal($B, $r) {
    $f = @{ Has = @{}; VmId = $null; LeaseId = $null; LeaseIssued = $false; DrainedOnline = $false; DrainAt = $null; BootAt = $null; RunOneAt = $null; Hostile = $null; LastDestroyFail = $null; Last = '' }
    $path = Get-AapWinJournalPath $B $r
    $kind = Get-AapWinPathKind $path
    if ($kind -eq 'absent') { return $f }
    if ($kind -ne 'file' -or (New-Object IO.FileInfo $path).Length -gt $script:JournalMax) { throw 'AAP_JournalUnreadable: not a plain file within its size bound' }   # check:journal-shape
    $lines = [IO.File]::ReadAllText($path, (New-Object Text.UTF8Encoding($false, $true))).Split("`n")
    for ($i = 0; $i -lt $lines.Length - 1; $i++) {
        try { $rec = ConvertFrom-AapWinJson $lines[$i] } catch { throw "AAP_JournalUnreadable: line $($i + 1) is not JSON" }
        $op = [string](Get-AapWinField $rec 'op'); $phase = [string](Get-AapWinField $rec 'phase')
        $mine = (Get-AapWinField $rec 'kind') -ceq 'op' -and [string](Get-AapWinField $rec 'reservation_id') -ceq [string]$r.reservation_id -and
            [long](Get-AapWinField $rec 'lease_generation') -eq [long]$r.lease_generation -and $script:Ops -ccontains $op -and @('intent', 'done', 'failed') -ccontains $phase
        if (-not $mine) { throw "AAP_JournalUnreadable: line $($i + 1) is not a record of this lease" }   # check:journal-owner
        $f.Has["$op/$phase"] = $true
        $at = Get-AapWinField $rec 'at'
        $vmId = Get-AapWinField (Get-AapWinField $rec 'vm') 'vm_id'
        if ($vmId) { $f.VmId = [string]$vmId }
        $res = Get-AapWinField $rec 'result'
        $code = [string](Get-AapWinField $res 'code'); $detail = [string](Get-AapWinField $res 'detail')
        if ($op -ceq 'ready' -and $phase -ceq 'done' -and $detail -cmatch 'lease (l-[0-9a-f]{32})\z') { $f.LeaseId = $Matches[1] }
        if ($op -ceq 'ready' -and $phase -ceq 'done' -and $script:LeaseAnswers -ccontains $detail) { $f.LeaseIssued = $true }
        if ($op -ceq 'drain' -and $phase -ceq 'done' -and $detail -ceq $script:DrainOnline) { $f.DrainedOnline = $true; $f.DrainAt = ConvertTo-AapWinUtc $at }
        $f.Last = "$op/$phase/$code/$detail"
        if ($op -ceq 'boot' -and $phase -ceq 'done') { $f.BootAt = ConvertTo-AapWinUtc $at }
        if ($op -ceq 'run_one' -and $phase -ceq 'intent' -and $null -eq $f.RunOneAt) { $f.RunOneAt = ConvertTo-AapWinUtc $at }
        if ($code -ceq 'hostile_guest') { $f.Hostile = $detail }
        if ($op -ceq 'destroy' -and $phase -ceq 'failed') { $f.LastDestroyFail = ConvertTo-AapWinUtc $at }
    }
    $f
}

# ---- allocator --------------------------------------------------------------------------------------------------------

function Get-AapWinAllocArgs($B, $r) {
    $a = @{ Root = $B.AllocatorRoot; ReservationId = [string]$r.reservation_id; LeaseGeneration = [long]$r.lease_generation }
    foreach ($k in $B.AllocArgs.Keys) { $a[$k] = $B.AllocArgs[$k] }
    $a
}

function Set-AapWinState($B, $r, [string]$State, [string]$Kind = '', [string]$Reason = '', [string]$VmId = '') {
    $a = Get-AapWinAllocArgs $B $r
    $a.State = $State
    if ($Kind) { $a.QuarantineKind = $Kind; $a.Reason = $Reason }
    if ($VmId) { $a.VmId = $VmId }
    Set-AapSlotState @a
}

# Walks the legal edges from the reservation's state down to $To (draining, collecting or deleting). Returns the
# reservation as the allocator now holds it, or $null when the allocator refused or failed an edge.
function Move-AapWinState($B, $r, [string]$To, [string]$VmId = '') {
    $path = $script:Down[[string]$r.state]
    if (-not $path) { return $r }
    foreach ($s in $path) {
        $res = Set-AapWinState $B $r $s -VmId $(if ($r.state -ceq 'creating') { $VmId } else { '' })
        if (-not $res.Ok) { return $null }
        $next = Get-AapWinField $res 'Reservation'
        if ($null -ne $next) { $r = $next }
        if ($s -ceq $To) { break }
    }
    $r
}

# ---- guest transport (guest-transport.md, Envelope and Wire framing) ---------------------------------------------------

# Checks one transport result against the command it answers. Kind: ok, refused, error (a valid reply whose status says
# so), timeout, no_reply (a failed guest) or hostile (Code: a fixed code; the host never keeps guest text as a reason).
function Test-AapWinReply($Raw, $Cmd) {
    $v = @{ Kind = 'hostile'; Code = $null; Reply = $null }
    if ($null -eq $Raw) { $v.Kind = 'no_reply'; return $v }
    $out = Get-AapWinField $Raw 'Stdout'; $exit = Get-AapWinField $Raw 'ExitCode'
    if ([bool](Get-AapWinField $Raw 'Overflow')) { $v.Code = 'oversized_reply'; return $v }   # check:reply-size
    if ([bool](Get-AapWinField $Raw 'TimedOut')) { $v.Kind = 'timeout'; return $v }
    if (-not ($exit -is [int]) -or $exit -ne 0) { $v.Code = 'child_exit'; return $v }   # check:child-exit
    if (-not ($out -is [byte[]]) -or $out.Length -eq 0) { $v.Kind = 'no_reply'; return $v }
    $n = $out.Length
    if ($out[$n - 1] -eq 10) { $n-- }
    if ($n -gt $script:ReplyMax) { $v.Code = 'oversized_reply'; return $v }   # check:reply-size
    for ($i = 0; $i -lt $n; $i++) {
        if ($out[$i] -lt 0x20 -or $out[$i] -gt 0x7e) { $v.Code = 'non_printable'; return $v }   # check:printable
    }
    $doc = ConvertFrom-AapBrokerJson ([Text.Encoding]::ASCII.GetString($out, 0, $n))
    if ($null -eq $doc) { $v.Code = 'bad_json'; return $v }   # check:reply-json
    $keys = @($doc.Keys)
    if ($keys.Count -ne $script:ReplyKeys.Count -or @($keys | Where-Object { $script:ReplyKeys -cnotcontains $_ }).Count) { $v.Code = 'extra_fields'; return $v }   # check:reply-fields
    $int = { param($x) $x -is [long] -or $x -is [int] }
    $exitCode = $doc['runner_exit_code']
    $ok = (& $int $doc['schema']) -and $doc['schema'] -eq 1 -and $doc['kind'] -ceq 'guest_reply' -and
        $doc['vm_id'] -is [string] -and $doc['vm_id'] -cmatch $script:GuidRe -and $doc['reservation_id'] -is [string] -and $doc['reservation_id'] -cmatch $script:RidRe -and
        (& $int $doc['lease_generation']) -and (& $int $doc['seq']) -and $doc['nonce'] -is [string] -and $doc['nonce'] -cmatch '^[0-9a-f]{32}\z' -and
        $doc['status'] -is [string] -and @('ok', 'refused', 'error') -ccontains $doc['status'] -and
        $doc['guest_state'] -is [string] -and $script:GuestStates -ccontains $doc['guest_state'] -and
        ($null -eq $exitCode -or ((& $int $exitCode) -and $exitCode -ge [int]::MinValue -and $exitCode -le [int]::MaxValue)) -and
        $doc['diag'] -is [string] -and $doc['diag'].Length -le 512
    if (-not $ok) { $v.Code = 'bad_value'; return $v }   # check:reply-values
    foreach ($k in 'vm_id', 'reservation_id', 'lease_generation', 'seq', 'nonce') {
        if ([string]$doc[$k] -cne [string]$Cmd[$k]) { $v.Code = 'wrong_echo'; return $v }   # check:reply-echo
    }
    if ($doc['diag'] -cmatch $script:SecretValue) { $v.Code = 'secret_value'; return $v }   # check:reply-secret
    $v.Reply = $doc
    if ($doc['status'] -cne 'ok') { $v.Kind = [string]$doc['status']; return $v }
    if ($script:Answers[[string]$Cmd['cmd']] -cnotcontains $doc['guest_state']) { $v.Code = 'bad_state'; return $v }   # check:reply-state
    $v.Kind = 'ok'
    $v
}

# Sends one command to the reservation's guest. The VM, the reservation and the lease generation come from this
# process's own records, never from the guest; seq grows by one per send, including a send that times out or fails, and
# is never reused, so a command the guest never saw or whose reply was lost leaves a gap the agent accepts
# (guest-transport.md, Sequence rule: any seq strictly greater than the last accepted one); the nonce is fresh. A reply
# must echo this command's seq and nonce, or it is hostile (wrong_echo). A JIT config ($Jit, the
# broker's object) is written by the transport straight onto the call child's stdin and never becomes text here.
function Invoke-AapWinCommand($B, $r, [string]$Cmd, $Jit = $null) {
    $g = $B.Guests[[string]$r.reservation_id]
    $g.Seq = [long]$g.Seq + 1
    $timeout = $script:Timeouts[$Cmd]
    $len = 0
    if ($null -ne $Jit) { $len = [int]$Jit.Length }
    $c = [ordered]@{ vm_id = $g.VmId; reservation_id = [string]$r.reservation_id; lease_generation = [long]$r.lease_generation; seq = [long]$g.Seq
        nonce = (New-AapWinHex 16); cmd = $Cmd; payload_bytes = $len; expires_at = (Format-AapWinTime (Get-AapWinNow $B).AddSeconds($timeout))
    }
    $doc = [ordered]@{ schema = 1; kind = 'host_cmd' }
    foreach ($k in $c.Keys) { $doc[$k] = $c[$k] }
    $line = ConvertTo-Json -InputObject $doc -Compress
    if ($c.vm_id -cnotmatch $script:GuidRe -or $line.Length -gt $script:EnvelopeMax -or $len -gt $script:PayloadMax -or ($Cmd -ceq 'deliver_registration') -ne ($len -gt 0)) {
        throw 'AAP_BadCommand: the envelope breaks guest-transport.md'
    }
    $call = @{ VmId = $g.VmId; User = $script:User; Password = $g.Password; Envelope = $line; PayloadLength = $len; WritePayload = $null; TimeoutSeconds = $timeout }
    if ($null -ne $Jit) { $call.WritePayload = { param([IO.Stream]$Stream) $Jit.WriteTo($Stream) }.GetNewClosure() }
    $raw = $null
    try { $raw = & $B.Transport $call } catch { $raw = $null }
    $v = Test-AapWinReply $raw $c
    if ($v.Kind -ceq 'hostile') { $g.Hostile = $v.Code }
    $v
}

$script:JobSource = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class AapWinJobObject {
    [StructLayout(LayoutKind.Sequential)]
    struct Basic { public long PerProcessUserTimeLimit; public long PerJobUserTimeLimit; public uint LimitFlags; public UIntPtr MinimumWorkingSetSize; public UIntPtr MaximumWorkingSetSize; public uint ActiveProcessLimit; public UIntPtr Affinity; public uint PriorityClass; public uint SchedulingClass; }
    [StructLayout(LayoutKind.Sequential)]
    struct Counters { public ulong ReadOps; public ulong WriteOps; public ulong OtherOps; public ulong ReadBytes; public ulong WriteBytes; public ulong OtherBytes; }
    [StructLayout(LayoutKind.Sequential)]
    struct Extended { public Basic Limits; public Counters Io; public UIntPtr ProcessMemoryLimit; public UIntPtr JobMemoryLimit; public UIntPtr PeakProcessMemoryUsed; public UIntPtr PeakJobMemoryUsed; }
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern IntPtr CreateJobObjectW(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref Extended info, int length);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool TerminateJobObject(IntPtr job, uint exitCode);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr handle);
    // Kill on close (0x2000), job memory (0x200), job CPU time (0x4), no error dialog on a crash (0x400).
    public static IntPtr Start(IntPtr process, long memoryBytes, long cpuSeconds) {
        IntPtr job = CreateJobObjectW(IntPtr.Zero, null);
        if (job == IntPtr.Zero) throw new Win32Exception();
        Extended info = new Extended();
        info.Limits.LimitFlags = 0x2000 | 0x200 | 0x4 | 0x400;
        info.Limits.PerJobUserTimeLimit = cpuSeconds * 10000000L;
        info.JobMemoryLimit = new UIntPtr((ulong)memoryBytes);
        if (!SetInformationJobObject(job, 9, ref info, Marshal.SizeOf(typeof(Extended))) || !AssignProcessToJobObject(job, process)) {
            int e = Marshal.GetLastWin32Error();
            CloseHandle(job);
            throw new Win32Exception(e);
        }
        return job;
    }
    public static void Kill(IntPtr job) { TerminateJobObject(job, 1); }
    public static void Close(IntPtr job) { CloseHandle(job); }
}
'@

# The default transport: one hidden child per command (psdirect-call.ps1 under Windows PowerShell, fixed command line,
# machine PSModulePath), inside a job object with a memory cap, a CPU-time cap and kill-on-close; the wall cap is the
# command's timeout plus 10 s. Its stdin gets the VM id, the guest user, the per-clone password and the envelope, one per
# line (the password straight from its secret object), then the payload; at most 8193 bytes of its stdout are read,
# stderr is drained and dropped.
# ponytail: the child runs for a moment before it is assigned to the job; it reads nothing from the guest until the
# supervisor writes its stdin, which happens only after the assignment. CREATE_SUSPENDED would close that gap.
# Windows PowerShell 5.1 (.NET Framework) builds a redirected stdin writer from [Console]::InputEncoding and writes its
# preamble at Process.Start: under code page 65001 the child would read EF BB BF before the first line. Start under a
# preamble-free encoding and restore it; without a console there is nothing to swap.
function Start-AapWinProcess([Diagnostics.ProcessStartInfo]$Psi) {
    $saved = $null
    try { $saved = [Console]::InputEncoding } catch { $null = $_ }
    if ($null -ne $saved) {   # check:stdin-bom
        try { [Console]::InputEncoding = New-Object Text.UTF8Encoding($false) } catch { $saved = $null }
    }
    try { [Diagnostics.Process]::Start($Psi) } finally { if ($null -ne $saved) { try { [Console]::InputEncoding = $saved } catch { $null = $_ } } }
}

function Invoke-AapWinGuestChild([hashtable]$Call) {
    if (-not ('AapWinJobObject' -as [type])) { throw 'AAP_ChildUncapped: the job object type is compiled by New-AapWinBackend' }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $script:ChildExe
    $psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $script:ChildScript
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.EnvironmentVariables['PSModulePath'] = [Environment]::GetEnvironmentVariable('PSModulePath', 'Machine')
    $wall = [int]$Call.TimeoutSeconds + 10
    $deadline = [DateTime]::UtcNow.AddSeconds($wall)
    $buf = New-Object byte[] $script:ReadMax
    $n = 0
    $job = [IntPtr]::Zero
    $p = Start-AapWinProcess $psi
    try {
        try { $job = [AapWinJobObject]::Start($p.Handle, $script:ChildMemoryBytes, $wall) } catch { throw 'AAP_ChildUncapped: the call child could not be put in its job object' }
        $in = $p.StandardInput.BaseStream
        try {
            $head = [Text.Encoding]::ASCII.GetBytes(('{0}{2}{1}{2}' -f $Call.VmId, $Call.User, "`n"))
            $tail = [Text.Encoding]::ASCII.GetBytes("`n" + $Call.Envelope + "`n")
            $in.Write($head, 0, $head.Length)
            # The password and the payload (a JIT config) go to the pipe unbuffered: written through $in they would stay
            # behind in that stream's private 4 KiB write buffer, which nothing can zero. Asking for the handle flushes the
            # head first.
            $pipe = New-Object IO.FileStream($in.SafeFileHandle, [IO.FileAccess]::Write, 1)
            $Call.Password.WriteTo($pipe)
            $pipe.Write($tail, 0, $tail.Length)
            if ([int]$Call.PayloadLength -gt 0) { & $Call.WritePayload $pipe }
        } catch {
            $null = $_   # it exited without reading; its exit code tells why
        }
        try { $p.StandardInput.Close() } catch { $null = $_ }
        $out = $p.StandardOutput.BaseStream
        $err = $p.StandardError.BaseStream
        $scratch = New-Object byte[] 4096
        $outTask = $out.ReadAsync($buf, 0, $buf.Length)
        $errTask = $err.ReadAsync($scratch, 0, $scratch.Length)
        $stopped = $null
        while ($null -eq $stopped -and ($null -ne $outTask -or $null -ne $errTask)) {
            $left = [int][Math]::Ceiling(($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            $tasks = [Threading.Tasks.Task[]]@(@($outTask, $errTask) | Where-Object { $null -ne $_ })
            if ($left -le 0 -or [Threading.Tasks.Task]::WaitAny($tasks, $left) -lt 0) { $stopped = 'timeout'; break }
            if ($null -ne $outTask -and $outTask.IsCompleted) {
                $got = $outTask.Result
                if ($got -le 0) { $outTask = $null } else {
                    $n += $got
                    if ($n -ge $buf.Length) { $stopped = 'overflow'; break }   # check:child-cap
                    $outTask = $out.ReadAsync($buf, $n, $buf.Length - $n)
                }
            }
            if ($null -ne $errTask -and $errTask.IsCompleted) {
                if ($errTask.Result -le 0) { $errTask = $null } else { $errTask = $err.ReadAsync($scratch, 0, $scratch.Length) }
            }
        }
        if ($null -eq $stopped) {
            $left = [int][Math]::Max(0, [Math]::Ceiling(($deadline - [DateTime]::UtcNow).TotalMilliseconds))
            if (-not $p.WaitForExit($left)) { $stopped = 'timeout' }
        }
        if ($null -ne $stopped) {
            [AapWinJobObject]::Kill($job)
            return @{ ExitCode = $null; Stdout = $null; TimedOut = ($stopped -ceq 'timeout'); Overflow = ($stopped -ceq 'overflow') }
        }
        $p.WaitForExit()
        $stdout = New-Object byte[] $n
        [Array]::Copy($buf, $stdout, $n)
        @{ ExitCode = $p.ExitCode; Stdout = $stdout; TimedOut = $false; Overflow = $false }
    } finally {
        [Array]::Clear($buf, 0, $buf.Length)
        if ($job -ne [IntPtr]::Zero) { [AapWinJobObject]::Close($job) }   # kill on close: nothing of the call outlives it
        try { if (-not $p.HasExited) { $p.Kill() } } catch { $null = $_ }
        $p.Dispose()
    }
}

# ---- Hyper-V reads ----------------------------------------------------------------------------------------------------

# Every VM on the host, complete or throws (a listing error never reads as an empty host).
function Get-AapWinVms($B) {
    $list = @(foreach ($v in @(& $B.Provider.ListVms @{})) {
        $id = ([string](Get-AapWinField $v 'Id')).ToLowerInvariant(); $name = [string](Get-AapWinField $v 'Name')
        if ($id -cnotmatch $script:GuidRe -or -not $name) { throw 'AAP_InventoryIncomplete: a VM entry has no name or id' }   # check:vm-entry
        [pscustomobject]@{ Id = $id; Name = $name; State = [string](Get-AapWinField $v 'State'); Cpus = Get-AapWinField $v 'Cpus'; MemGib = Get-AapWinField $v 'MemGib' }
    })
    $list
}

# The VM's settings against backend-lifecycle.md (create): checkpoints off, TurnOff/Nothing, Guest Service Interface and
# Key-Value Pair Exchange off, the reserved CPU and memory, every file under the reservation's folders, exactly the disks
# create made, no COM port, DVD drive, GPU partition or assigned device (a VM the journal names is inventoried the same
# way before it is reused); with -Adapters
# also the guest network: at least one adapter, each on the internal switch with DHCP guard and router guard on and MAC
# spoofing off.
function Assert-AapWinVmConfig($B, $r, [string]$VmId, [string]$Clone, [string]$Scratch, [string[]]$Expected, [switch]$Adapters) {
    $c = & $B.Provider.GetVmConfig @{ VmId = $VmId }
    $bad = New-Object Collections.Generic.List[string]
    $under = { param($p, $dir) $p = [string]$p; $p -and ($p.TrimEnd('\') -ieq $dir -or $p.StartsWith($dir + '\', [StringComparison]::OrdinalIgnoreCase)) }
    if ([int](Get-AapWinField $c 'Generation') -ne 2) { $bad.Add('not generation 2') }   # check:vm-settings
    if ([string](Get-AapWinField $c 'CheckpointType') -cne 'Disabled') { $bad.Add('checkpoints are not disabled') }   # check:vm-settings
    if ([string](Get-AapWinField $c 'AutomaticStopAction') -cne 'TurnOff' -or [string](Get-AapWinField $c 'AutomaticStartAction') -cne 'Nothing') { $bad.Add('automatic start or stop action') }   # check:vm-settings
    if ((Get-AapWinField $c 'GuestServiceInterface') -ne $false -or (Get-AapWinField $c 'KeyValuePairExchange') -ne $false) { $bad.Add('Guest Service Interface or Key-Value Pair Exchange is on') }   # check:vm-integration
    if ([int](Get-AapWinField $c 'Cpus') -ne [int]$r.cpus -or [int](Get-AapWinField $c 'MemGib') -ne [int]$r.mem_gib) { $bad.Add('CPU or memory differs from the reservation') }   # check:vm-settings
    foreach ($k in 'ConfigurationLocation', 'SnapshotFileLocation', 'SmartPagingFilePath') {
        if (-not (& $under (Get-AapWinField $c $k) $Clone)) { $bad.Add("$k is outside the reservation's clone folder") }   # check:vm-paths
    }
    $vmDisks = Get-AapWinField $c 'Disks'
    $vmDisks = @($vmDisks | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
    foreach ($d in $vmDisks) {
        if (-not ((& $under $d $Clone) -or (& $under $d $Scratch))) { $bad.Add('a disk is outside the reservation folders') }   # check:vm-paths
    }
    $same = $vmDisks.Count -eq $Expected.Count -and @($Expected | Where-Object { $vmDisks -notcontains $_ }).Count -eq 0
    if (-not $same) { $bad.Add('the disks are not exactly os.avhdx and scratch.vhdx') }   # check:vm-devices
    foreach ($k in 'ComPorts', 'DvdDrives', 'GpuPartitions', 'AssignedDevices') {
        $v = Get-AapWinField $c $k
        if ($null -eq $v -or [int]$v -ne 0) { $bad.Add("$k attached or unknown") }   # check:vm-devices
    }
    if ($Adapters) {
        $nics = Get-AapWinField $c 'Adapters'
        $nics = @($nics | Where-Object { $null -ne $_ })
        if (-not $nics.Count) { $bad.Add('no network adapter after attach') }
        foreach ($a in $nics) {
            if ([string](Get-AapWinField $a 'SwitchName') -cne $script:SwitchName -or [string](Get-AapWinField $a 'SwitchType') -cne 'Internal') { $bad.Add("an adapter is not on the internal switch $($script:SwitchName)") }   # check:switch
            if ((Get-AapWinField $a 'DhcpGuard') -ne $true -or (Get-AapWinField $a 'RouterGuard') -ne $true -or (Get-AapWinField $a 'MacAddressSpoofing') -ne $false) { $bad.Add('an adapter lacks DHCP guard, router guard or has MAC spoofing on') }   # check:switch
        }
    }
    if ($bad.Count) { throw "AAP_VmUntrusted: $($bad -join '; ')" }
}

# ---- lifecycle ops ------------------------------------------------------------------------------------------------------

function New-AapWinResult($r, [string]$Action, $Code = $null, $Summary = $null) {
    [pscustomobject][ordered]@{ ReservationId = [string]$r.reservation_id; LeaseGeneration = [long]$r.lease_generation; Action = $Action; State = [string]$r.state; Code = $Code; Summary = $Summary }
}

# create (backend-lifecycle.md): idempotent. Re-run after a crash it reuses only the VM whose id the journal recorded
# right after New-VM (a VM found only by its name is never adopted: create fails and destroy removes it), keeps the disks
# it made (a reused os.avhdx must still be a child of the pinned base), and writes a fresh credential, which is safe only
# because the clone never booted (Step-AapWinCreating destroys a clone whose credential died with the supervisor).
function Invoke-AapWinCreate($B, $r, [string]$BaseSha256, $j) {
    $rid = [string]$r.reservation_id
    $name = Get-AapWinVmName $r
    $gen = [string]$r.image_generation
    if ($gen -cnotmatch $script:GenerationRe) { throw "AAP_BadGeneration: $gen is not a Windows generation id" }
    if ($BaseSha256 -cnotmatch '^[0-9a-f]{64}\z') { throw 'AAP_BaseUnpinned: create needs the base SHA-256 pinned outside the roots' }   # check:base-pin
    $scratchGib = [long]$r.scratch_gib
    $disks = @([ordered]@{ role = 'base_ref'; path = "$gen/base.vhdx"; sha256 = $BaseSha256 }, [ordered]@{ role = 'os_diff'; path = "$rid/os.avhdx"; sha256 = $null })
    if ($scratchGib -gt 0) { $disks += [ordered]@{ role = 'scratch'; path = "$rid/scratch.vhdx"; sha256 = $null } }
    Write-AapWinJournal $B $r 'create' 'intent' -Disks $disks
    Invoke-AapWinFault 'create:after-intent'
    $problems = @(Get-AapWinStorageProblem -Backend $B)
    if ($problems.Count) { throw "AAP_StorageUntrusted: $($problems -join '; ')" }   # check:root-trust
    $problems = @(Get-AapWinHostProblem -Backend $B)
    if ($problems.Count) { throw ($problems -join '; ') }   # check:host-trust
    $baseRoot = $B.Storage.base_root.Path
    $base = Join-Path $baseRoot (($gen -replace '/', '\') + '\base.vhdx')
    $genDir = Split-Path -Parent $base
    Assert-AapWinPlainPath -Root $baseRoot -Path $genDir -Reason 'AAP_BaseUntrusted'
    if ((Get-AapWinPathKind $base) -cne 'file') { throw "AAP_BaseMissing: not a plain file: $base" }   # check:base-kind
    foreach ($p in @($genDir, $base)) {
        $why = Get-AapWinSealedProblem $B $p
        if ($why) { throw "AAP_BaseUntrusted: $why" }   # check:base-sealed
    }
    $clone = Join-Path $B.Storage.clone_root.Path $rid
    $scratch = Join-Path $B.Storage.scratch_root.Path $rid
    $os = Join-Path $clone 'os.avhdx'
    # One read handle that shares only reading, from the hash to the differencing disk: nobody can write, rename or delete
    # the base in between. ponytail: Hyper-V opening the parent next to this handle is a P02.1 lab check.
    $hold = New-Object IO.FileStream($base, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ([string](& $B.Provider.HashFile @{ Path = $base; Stream = $hold }) -cne $BaseSha256) { throw "AAP_BaseHashMismatch: $gen does not match its pinned hash" }   # check:base-hash
        Assert-AapWinPlainPath -Root $B.Storage.clone_root.Path -Path $clone -Reason 'AAP_UnsafePath' -Create
        Assert-AapWinPlainPath -Root $B.Storage.scratch_root.Path -Path $scratch -Reason 'AAP_UnsafePath' -Create
        Invoke-AapWinFault 'create:after-folders'
        $kind = Get-AapWinPathKind $os
        if ($kind -cne 'absent' -and $kind -cne 'file') { throw "AAP_UnsafePath: os.avhdx is a ${kind}: $os" }   # check:disk-kind
        if ($kind -ceq 'absent') { & $B.Provider.NewDiffDisk @{ Path = $os; Parent = $base } }
        if ([string](& $B.Provider.GetVhdParent @{ Path = $os }) -ine $base) { throw "AAP_UnsafePath: os.avhdx is not a child of its generation's base: $os" }   # check:disk-parent
    } finally { $hold.Dispose() }
    $scratchDisk = $null
    if ($scratchGib -gt 0) {
        $scratchDisk = Join-Path $scratch 'scratch.vhdx'
        $kind = Get-AapWinPathKind $scratchDisk
        # The scratch cap is enforced by the disk's own maximum size (backend-lifecycle.md, Disk paths and budgets).
        if ($kind -cne 'absent' -and $kind -cne 'file') { throw "AAP_UnsafePath: scratch.vhdx is a ${kind}: $scratchDisk" }   # check:disk-kind
        if ($kind -ceq 'absent') { & $B.Provider.NewDisk @{ Path = $scratchDisk; SizeBytes = $scratchGib * $script:GiB - $script:ScratchHeadroomBytes } }
    }
    Invoke-AapWinFault 'create:after-disks'
    $named = @(Get-AapWinVms $B | Where-Object { $_.Name -ceq $name })
    $id = [string]$j.VmId
    if ($id) {
        if ($named.Count -ne 1 -or $named[0].Id -cne $id) { throw "AAP_VmMismatch: the VM the journal recorded is not the one VM named $name" }   # check:vm-journaled
    } elseif ($named.Count) {
        throw "AAP_VmNotJournaled: a VM named $name exists that this journal never recorded; it is destroyed, never adopted"   # a crash between New-VM and its record
    }
    $pw = New-AapWinPassword
    & $B.Provider.WriteUnattend @{ Vhdx = $os; User = $script:User; Password = $pw }
    if ($B.Guests.ContainsKey($rid)) { $B.Guests[$rid].Password.Clear() }
    $B.Guests[$rid] = @{ VmId = $null; Password = $pw; Seq = 0; Started = $false; Hostile = $null }
    Invoke-AapWinFault 'create:after-unattend'
    $diskList = @(@($os, $scratchDisk) | Where-Object { $_ })
    if (-not $id) {
        $id = ([string](Get-AapWinField (& $B.Provider.NewVm @{ Name = $name; Path = $clone; Cpus = [int]$r.cpus; MemGib = [int]$r.mem_gib; OsDisk = $os; ScratchDisk = $scratchDisk }) 'Id')).ToLowerInvariant()
        if ($id -cnotmatch $script:GuidRe) { throw 'AAP_Unexpected: the new VM has no id' }
        Invoke-AapWinFault 'create:after-newvm'
        # The VM's id, before anything else touches it: the only VM a re-run may reuse.
        Write-AapWinJournal $B $r 'create' 'intent' -VmId $id -Disks $disks
    }
    $B.Guests[$rid].VmId = $id
    Invoke-AapWinFault 'create:after-vm'
    Assert-AapWinVmConfig $B $r $id $clone $scratch $diskList
    $net = @{ VmId = $id; VmName = $name; Profile = 'windows' }
    & $B.Network.Attach $net
    $problems = @(& $B.Network.Verify $net | Where-Object { $_ })
    if ($problems.Count) { throw "AAP_NetworkUntrusted: $(@($problems | ForEach-Object { Get-AapWinLine ([string]$_) 100 }) -join '; ')" }   # check:network-verify
    Assert-AapWinVmConfig $B $r $id $clone $scratch $diskList -Adapters
    Write-AapWinJournal $B $r 'create' 'done' -VmId $id -Disks $disks -Code 'ok' -Detail 'differencing disk, scratch disk and VM created; network verified'
    Invoke-AapWinFault 'create:after-done'
    $id
}

# The runner part of the teardown proof (broker INTEGRATION.md, rules for the callers): never_registered when no lease
# was ever asked for, $true or 'github-removed' when the release closed the lease, 'pending' to ask again later and
# 'uncertain' when the broker lost a lease it had issued (never proof).
function Get-AapWinRunnerProof($B, $r, $j) {
    if (-not $j.Has['run_one/intent']) { return 'never_registered' }
    if (-not $j.LeaseId) { return 'uncertain' }
    $ba = $B.BrokerArgs
    $rel = Invoke-AapBrokerRelease -LeaseId $j.LeaseId @ba
    if ($rel.Outcome -ceq 'deregistered') { return $true }
    if ($rel.Outcome -ceq 'already_gone') { return 'github-removed' }
    if ($rel.Outcome -ceq 'refused' -and $rel.Reason -ceq 'not_found') {
        $known = [string]$B.Leases[[string]$r.reservation_id]
        if ($j.LeaseIssued -or @('issued', 'bad_reply') -ccontains $known) { return 'uncertain' }   # check:release-uncertain
        # A lease call the broker never recorded can no longer reach it (each broker run ends within 55 s).
        if ($null -ne $j.RunOneAt -and ((Get-AapWinNow $B) - $j.RunOneAt).TotalMinutes -ge $script:LeaseWindowMinutes) { return 'never_registered' }   # check:lease-window
    }
    'pending'
}

# True only when the VM (by id and by name) and both reservation folders are observed absent, on both tier roots present
# and on the volumes the storage document records: a root that is missing or on another volume (a USB disk not back yet)
# would make every folder look gone.
function Test-AapWinGone($B, [string]$VmId, [string]$Name, [string]$Clone, [string]$Scratch) {
    try {
        foreach ($t in 'clone_root', 'scratch_root') {
            $root = $B.Storage[$t]
            if ((Get-AapWinPathKind $root.Path) -cne 'dir' -or [string](& $B.Provider.GetVolumeGuid @{ Path = $root.Path }) -cne $root.Guid) { return $false }   # check:gone-volume
        }
        $vms = @(Get-AapWinVms $B | Where-Object { ($VmId -and $_.Id -ceq $VmId) -or $_.Name -ceq $Name })
        if ($vms.Count) { return $false }   # check:observe-absent
        if ((Get-AapWinPathKind $Clone) -cne 'absent') { return $false }   # check:observe-absent
        if ((Get-AapWinPathKind $Scratch) -cne 'absent') { return $false }   # check:observe-scratch
    } catch { return $false }
    $true
}

# destroy (backend-lifecycle.md): release the lease if one was ever asked for, turn the VM off and remove it, detach it
# from the guest network, delete both reservation folders through reparse-checked paths, then observe absence. Only
# observed absence plus a final runner proof completes the teardown (Complete-AapTeardown frees the slot). The VM goes
# whatever the release answered, except after a drain: a runner that was listening may still be listed, so its VM stays
# until the release is final. -Urgent (a hostile guest, a broken limit, a failed op) removes the VM in every case. A VM
# or folder that will not go after three tries quarantines the slot (teardown_failed, capacity held); an uncertain runner
# does the same; a pending release keeps it deleting. A retry continues the journaled intent and repeats no identical
# failure record; it runs at most once a minute (-Force: now). A VM kept here (a drain waiting for its release, a
# teardown being retried) still runs whatever GitHub hands its runner, so the host-side limits hold on every step, before
# the retry gate. A breach makes the destroy urgent, at once the first
# time this process sees it; a drained VM kept past DrainKeepHours is flagged (drain_overdue), never destroyed for time.
function Invoke-AapWinDestroy($B, $r, $j, [switch]$Force, [switch]$Urgent) {
    $rid = [string]$r.reservation_id
    $name = Get-AapWinVmName $r
    $now = Get-AapWinNow $B
    $breach = $null
    if (-not $Urgent) {
        $breach = Get-AapWinLimitBreach $B $r $j
        if ($breach) {   # check:deleting-limits
            $Urgent = $true
            if (-not $B.Breached.ContainsKey($rid)) { $B.Breached[$rid] = $true; $Force = $true } else { $breach = $null }
        }
    }
    $last = $j.LastDestroyFail
    if ($B.Tried.ContainsKey($rid) -and ($null -eq $last -or $B.Tried[$rid] -gt $last)) { $last = $B.Tried[$rid] }
    if (-not $Force -and $null -ne $last -and ($now - $last).TotalSeconds -lt $script:RetrySeconds) { return (New-AapWinResult $r 'waiting' 'retry_later') }
    $B.Tried[$rid] = $now
    $clone = Join-Path $B.Storage.clone_root.Path $rid
    $scratch = Join-Path $B.Storage.scratch_root.Path $rid
    $vmId = [string](Get-AapWinField $r 'vm_id')
    if (-not $vmId) { $vmId = [string]$j.VmId }
    $mine = @(Get-AapWinVms $B | Where-Object { ($vmId -and $_.Id -ceq $vmId) -or $_.Name -ceq $name })
    if (-not $vmId -and $mine.Count) { $vmId = $mine[0].Id }
    if (-not $vmId) {
        # No VM ever existed for this reservation, so no lease either: remove the folders, free it as never registered.
        Write-AapWinFailedOnce $B $r $j 'create' '' 'fatal' 'abandoned before a VM existed; reservation folders removed'
        foreach ($d in @(@($clone, $B.Storage.clone_root.Path), @($scratch, $B.Storage.scratch_root.Path))) { try { Remove-AapWinTree $d[0] $d[1] } catch { $null = $_ } }
        if (-not (Test-AapWinGone $B '' $name $clone $scratch)) { return (New-AapWinResult $r 'held' 'folders_remain') }
        $proof = [ordered]@{ kind = 'vm'; observed_at = (Format-AapWinTime $now); vm_absent = $true; disks_absent = $true; vm_files_absent = $true; runner_deregistered = 'never_registered' }
        $a = Get-AapWinAllocArgs $B $r
        $c = Complete-AapTeardown @a -Proof $proof
        if ($c.Ok) { $next = Get-AapWinField $c 'Reservation'; if ($null -ne $next) { $r = $next }; return (New-AapWinResult $r 'destroyed') }
        return (New-AapWinResult $r 'held' $c.Reason)
    }
    if ($j.Last -notlike 'destroy/*') { Write-AapWinJournal $B $r 'destroy' 'intent' -VmId $vmId }
    if ($breach) { Write-AapWinJournal $B $r 'destroy' 'failed' -VmId $vmId -Code 'fatal' -Detail "limit broken while kept: $breach" }
    Invoke-AapWinFault 'destroy:after-intent'
    $runner = Get-AapWinRunnerProof $B $r $j
    Invoke-AapWinFault 'destroy:after-release'
    if (-not $Urgent -and $runner -is [string] -and $runner -ceq 'pending' -and $j.DrainedOnline) {   # check:drain-keep
        if ($null -ne $j.DrainAt -and ($now - $j.DrainAt).TotalHours -ge $script:DrainKeepHours) {   # check:drain-overdue
            Write-AapWinFailedOnce $B $r $j 'destroy' $vmId 'retryable' "drained VM kept $($script:DrainKeepHours) h with its release pending; flagged, never destroyed for time"
            return (New-AapWinResult $r 'waiting' 'drain_overdue')
        }
        Write-AapWinFailedOnce $B $r $j 'destroy' $vmId 'retryable' 'runner release pending; the drained VM stays until it is final'
        return (New-AapWinResult $r 'waiting' 'release_pending')
    }
    $gone = $false
    for ($try = 1; $try -le $script:TeardownTries; $try++) {
        $detached = $false
        try {
            foreach ($vm in @(Get-AapWinVms $B | Where-Object { $_.Id -ceq $vmId -or $_.Name -ceq $name })) {
                if ($vm.State -cne 'Off') { & $B.Provider.StopVm @{ VmId = $vm.Id } }
                & $B.Provider.RemoveVm @{ VmId = $vm.Id }
            }
        } catch { $null = $_ }
        Invoke-AapWinFault 'destroy:after-vm'
        try { & $B.Network.Detach @{ VmId = $vmId; VmName = $name; Profile = 'windows' }; $detached = $true } catch { $null = $_ }
        try { Remove-AapWinTree $clone $B.Storage.clone_root.Path } catch { $null = $_ }
        try { Remove-AapWinTree $scratch $B.Storage.scratch_root.Path } catch { $null = $_ }
        $gone = Test-AapWinGone $B $vmId $name $clone $scratch
        if (-not $detached) { $gone = $false }   # check:detach
        if ($gone) { break }
        if ($try -lt $script:TeardownTries) { & $B.Sleep $script:TeardownPauseSeconds }
    }
    if ($B.Guests.ContainsKey($rid)) { $B.Guests[$rid].Password.Clear(); [void]$B.Guests.Remove($rid) }   # the per-clone credential dies with the clone
    if (-not $gone) {
        Write-AapWinFailedOnce $B $r $j 'destroy' $vmId 'retryable' 'the VM, its network or a reservation folder remains after 3 tries'
        if ($r.state -ceq 'deleting') { [void](Set-AapWinState $B $r quarantined -Kind teardown_failed -Reason 'VM, network or reservation folders remain after 3 tries; capacity held') }
        return (New-AapWinResult $r 'held' 'teardown_failed')
    }
    if ($runner -is [string] -and $runner -ceq 'pending') {
        Write-AapWinFailedOnce $B $r $j 'destroy' $vmId 'retryable' 'VM gone; runner release pending'
        return (New-AapWinResult $r 'waiting' 'release_pending')
    }
    if ($runner -is [string] -and $runner -ceq 'uncertain') {
        Write-AapWinFailedOnce $B $r $j 'destroy' $vmId 'fatal' 'VM gone; the broker has no record of an issued lease'
        if ($r.state -ceq 'deleting') { [void](Set-AapWinState $B $r quarantined -Kind teardown_failed -Reason 'runner deregistration uncertain; capacity held') }
        return (New-AapWinResult $r 'held' 'release_uncertain')
    }
    Write-AapWinJournal $B $r 'destroy' 'done' -VmId $vmId -Code 'absent' -Detail 'VM, its files and both reservation folders observed absent'
    Invoke-AapWinFault 'destroy:after-done'
    $proof = [ordered]@{ kind = 'vm'; observed_at = (Format-AapWinTime (Get-AapWinNow $B)); vm_absent = $true; disks_absent = $true; vm_files_absent = $true; runner_deregistered = $runner }
    $a = Get-AapWinAllocArgs $B $r
    $c = Complete-AapTeardown @a -Proof $proof
    if ($c.Ok) {
        foreach ($t in $B.Leases, $B.Tried, $B.StatusAt, $B.StatusBusy, $B.Breached) { [void]$t.Remove($rid) }
        $next = Get-AapWinField $c 'Reservation'
        if ($null -ne $next) { $r = $next }
        return (New-AapWinResult $r 'destroyed')
    }
    New-AapWinResult $r 'held' $c.Reason
}

# Journals the failed op, walks the slot down to deleting and destroys, in the same step.
function Invoke-AapWinAbandon($B, $r, $j, [string]$Op, [string]$Code, [string]$Detail) {
    $vmId = [string]$j.VmId
    if (-not $vmId -and $B.Guests.ContainsKey([string]$r.reservation_id)) { $vmId = [string]$B.Guests[[string]$r.reservation_id].VmId }
    if ($Op -cne 'create' -and -not $vmId) { $Op = 'create' }   # a record after create must name its VM
    Write-AapWinFailedOnce $B $r $j $Op $vmId $Code $Detail
    $j = Read-AapWinJournal $B $r
    if ($vmId -or $r.state -cne 'creating') {
        $next = Move-AapWinState $B $r 'deleting' $vmId
        if ($null -ne $next) { $r = $next }
    }
    $out = Invoke-AapWinDestroy $B $r $j -Force -Urgent
    if (-not $out.Code) { $out.Code = $Code }
    $out
}

# hostile_guest (allocator.md): immediate and final from every guest state. The slot goes straight to deleting and the VM
# is destroyed even when the allocator call fails; the reason is a fixed code, never guest text.
function Invoke-AapWinHostile($B, $r, $j, [string]$Op, [string]$Code) {
    $rid = [string]$r.reservation_id
    if ($B.Guests.ContainsKey($rid)) { $B.Guests[$rid].Hostile = $Code }
    $vmId = [string]$j.VmId
    if (-not $vmId -and $B.Guests.ContainsKey($rid)) { $vmId = [string]$B.Guests[$rid].VmId }
    if (-not $j.Hostile) { Write-AapWinJournal $B $r $Op 'failed' -VmId $vmId -Code 'hostile_guest' -Detail $Code }
    try {
        $s = Set-AapWinState $B $r quarantined -Kind hostile_guest -Reason $Code -VmId $vmId
        $next = Get-AapWinField $s 'Reservation'
        if ($s.Ok -and $null -ne $next) { $r = $next }
    } catch { $null = $_ }
    $out = Invoke-AapWinDestroy $B $r (Read-AapWinJournal $B $r) -Force -Urgent
    $out.Code = $Code
    $out
}

# The limits backend-lifecycle.md lets end a running VM, checked from the host on every step of a reservation that has a
# VM, with or without a guest channel (a guest that silences its agent is measured all the same): a paused VM, and a
# clone folder over clone_gib or one that cannot be measured (fail closed: a step that threw every tick would leave the
# VM unwatched). Returns the reason, or $null.
function Get-AapWinLimitBreach($B, $r, $j) {
    if (-not $j.VmId) { return $null }
    $vm = @(Get-AapWinVms $B | Where-Object { $_.Id -ceq [string]$j.VmId })
    if (-not $vm.Count) { return $null }
    if ($vm[0].State -like 'Paused*') { return 'vm paused' }   # check:vm-paused
    $clone = Join-Path $B.Storage.clone_root.Path ([string]$r.reservation_id)
    try { $bytes = [double](& $B.Provider.MeasureBytes @{ Path = $clone }) } catch { return 'clone not measurable' }
    if ($bytes -gt [double]$r.clone_gib * $script:GiB) { return 'clone over cap' }   # check:clone-cap
    $null
}

function Step-AapWinCreating($B, $r, $j, $g, [string]$BaseSha256) {
    # An earlier step gave this clone up and its teardown is not finished: finish it, never create again.
    if ($j.Has['create/failed'] -or $j.Has['boot/failed'] -or $j.Has['ready/failed']) {   # check:no-recreate
        if ($j.VmId) { $next = Move-AapWinState $B $r 'deleting' ([string]$j.VmId); if ($null -ne $next) { $r = $next } }
        return (Invoke-AapWinDestroy $B $r $j)
    }
    # A clone created or booted without this process: its credential died with the supervisor, so it is never booted or
    # probed (crash table: boot or ready in flight -> re-probe; on timeout destroy).
    if (($j.Has['create/done'] -or $j.Has['boot/intent']) -and $null -eq $g) {   # check:lost-credential
        return (Invoke-AapWinAbandon $B $r $j $(if ($j.Has['boot/intent']) { 'ready' } else { 'boot' }) 'retryable' 'credential lost with the supervisor before ready')
    }
    if (-not $j.Has['create/done']) {
        try { [void](Invoke-AapWinCreate $B $r $BaseSha256 $j) }
        catch { return (Invoke-AapWinAbandon $B $r (Read-AapWinJournal $B $r) 'create' 'fatal' (Get-AapWinError $_)) }
        return (New-AapWinResult $r 'created')
    }
    if (-not $j.Has['boot/done']) {
        Write-AapWinJournal $B $r 'boot' 'intent' -VmId $j.VmId
        Invoke-AapWinFault 'boot:after-intent'
        try { & $B.Provider.StartVm @{ VmId = $j.VmId } }   # running already counts as done
        catch { return (Invoke-AapWinAbandon $B $r $j 'boot' 'fatal' (Get-AapWinError $_)) }
        Write-AapWinJournal $B $r 'boot' 'done' -VmId $j.VmId -Code 'ok' -Detail 'VM started'
        Invoke-AapWinFault 'boot:after-done'
        return (New-AapWinResult $r 'booted')
    }
    if (-not $j.Has['ready/done']) {
        if (-not $j.Has['ready/intent']) { Write-AapWinJournal $B $r 'ready' 'intent' -VmId $j.VmId }
        $p = Invoke-AapWinCommand $B $r 'probe'
        if ($p.Kind -ceq 'hostile') { return (Invoke-AapWinHostile $B $r $j 'ready' $p.Code) }
        $ready = $p.Kind -ceq 'ok' -and $p.Reply['guest_state'] -ceq 'ready'
        if (-not $ready -and ($p.Kind -ceq 'refused' -or $p.Kind -ceq 'error')) { return (Invoke-AapWinAbandon $B $r $j 'ready' 'fatal' "the guest answered the probe with $($p.Kind)") }
        if (-not $ready -and ((Get-AapWinNow $B) - $j.BootAt).TotalMinutes -ge $script:BootMinutes) { return (Invoke-AapWinAbandon $B $r $j 'ready' 'timeout' 'no ready reply within 15 minutes of boot') }   # check:boot-deadline
        if (-not $ready) { return (New-AapWinResult $r 'probing' $p.Kind) }
        # The lease id is journaled here, before the lease call (broker INTEGRATION.md, rule 1).
        Write-AapWinJournal $B $r 'ready' 'done' -VmId $j.VmId -Code 'ok' -Detail ('probe ready; lease ' + (New-AapBrokerLeaseId))
        Invoke-AapWinFault 'ready:after-done'
        $j = Read-AapWinJournal $B $r
    }
    $s = Set-AapWinState $B $r ready -VmId $j.VmId
    $next = Get-AapWinField $s 'Reservation'
    if ($null -ne $next) { $r = $next }
    New-AapWinResult $r 'ready' $s.Reason
}

# run_one: broker lease, deliver_registration, start_runner (then heartbeats until the job ends).
function Invoke-AapWinRunOne($B, $r, $j, $g) {
    $rid = [string]$r.reservation_id
    Write-AapWinJournal $B $r 'run_one' 'intent' -VmId $j.VmId
    Invoke-AapWinFault 'run_one:after-intent'
    $ba = $B.BrokerArgs
    $lease = Invoke-AapBrokerLease -LeaseId $j.LeaseId -ReservationId $rid -LeaseGeneration ([long]$r.lease_generation) -Slot ([int]$r.slot) `
        -RunnerProfile $script:ImageProfile -ImageGeneration ([string]$r.image_generation) @ba
    $B.Leases[$rid] = [string]$lease.Outcome
    $jit = $lease.JitConfig
    try {
        if ($lease.Outcome -ceq 'issued') { Write-AapWinJournal $B $r 'ready' 'done' -VmId $j.VmId -Code 'ok' -Detail $script:LeaseAnswers[0] }
        elseif ($lease.Outcome -ceq 'bad_reply') { Write-AapWinJournal $B $r 'ready' 'done' -VmId $j.VmId -Code 'ok' -Detail $script:LeaseAnswers[1] }
        Invoke-AapWinFault 'run_one:after-lease'
        $j = Read-AapWinJournal $B $r
        if ($lease.Outcome -cne 'issued') { return (Invoke-AapWinAbandon $B $r $j 'run_one' 'retryable' "lease $($lease.Outcome)") }
        # F1 (broker INTEGRATION.md): the JIT config goes only to the transport of this reservation's own VM, created and
        # booted here from the base, never run a job, not hostile, before the lease's delivery deadline.
        $fits = $lease.RunnerName -ceq (Get-AapWinVmName $r) -and [string]$g.VmId -ceq [string]$j.VmId -and -not $g.Started -and -not $g.Hostile -and
            (Get-AapWinNow $B) -lt (ConvertTo-AapWinUtc $lease.ExpiresAt)
        if (-not $fits) { return (Invoke-AapWinAbandon $B $r $j 'run_one' 'fatal' 'the lease does not fit this VM') }   # check:jit-target
        $d = Invoke-AapWinCommand $B $r 'deliver_registration' $jit
        Invoke-AapWinFault 'run_one:after-deliver'
        if ($d.Kind -ceq 'hostile') { return (Invoke-AapWinHostile $B $r $j 'run_one' $d.Code) }
        if ($d.Kind -cne 'ok') { return (Invoke-AapWinAbandon $B $r $j 'run_one' 'fatal' "deliver_registration $($d.Kind)") }
        $s = Invoke-AapWinCommand $B $r 'start_runner'
        if ($s.Kind -ceq 'hostile') { return (Invoke-AapWinHostile $B $r $j 'run_one' $s.Code) }
        if ($s.Kind -cne 'ok') { return (Invoke-AapWinAbandon $B $r $j 'run_one' 'fatal' "start_runner $($s.Kind)") }
        $g.Started = $true
        Invoke-AapWinFault 'run_one:after-start'
        New-AapWinResult $r 'running'
    } finally {
        if ($null -ne $jit) { $jit.Clear() }   # check:jit-clear
    }
}

# collect: the agent's bounded summary (the guest_reply itself: state, runner exit code, diag), then deleting and destroy.
function Step-AapWinCollect($B, $r, $j, $g) {
    $summary = $null
    if (-not $j.Has['collect/done'] -and -not $j.Has['collect/failed']) {
        Write-AapWinJournal $B $r 'collect' 'intent' -VmId $j.VmId
        Invoke-AapWinFault 'collect:after-intent'
        if ($null -ne $g -and $g.Started -and -not $g.Hostile) {
            $c = Invoke-AapWinCommand $B $r 'collect'
            if ($c.Kind -ceq 'hostile') { return (Invoke-AapWinHostile $B $r $j 'collect' $c.Code) }
            if ($c.Kind -ceq 'ok') {
                $summary = [pscustomobject]@{ GuestState = [string]$c.Reply['guest_state']; RunnerExitCode = $c.Reply['runner_exit_code']; Diag = [string]$c.Reply['diag'] }
                Write-AapWinJournal $B $r 'collect' 'done' -VmId $j.VmId -Code 'ok' -Detail "summary collected; runner exit $($c.Reply['runner_exit_code'])"
            } else {
                Write-AapWinJournal $B $r 'collect' 'failed' -VmId $j.VmId -Code 'retryable' -Detail "no summary: $($c.Kind)"
            }
        } else {
            Write-AapWinJournal $B $r 'collect' 'done' -VmId $j.VmId -Code 'ok' -Detail 'no guest channel; no summary'
        }
    }
    $next = Move-AapWinState $B $r 'deleting'
    if ($null -eq $next) { return (New-AapWinResult $r 'held' 'allocator' $summary) }
    $out = Invoke-AapWinDestroy $B $next (Read-AapWinJournal $B $next) -Force
    $out.Summary = $summary
    $out
}

# ready (runner started), busy, draining: one heartbeat. The guest's `status` reply proves liveness over this VM's own
# channel; whether a job runs comes from the broker's record of the runner, never from the guest.
function Step-AapWinRunning($B, $r, $j, $g) {
    $breach = Get-AapWinLimitBreach $B $r $j
    if ($breach) { return (Invoke-AapWinAbandon $B $r $j 'run_one' 'fatal' $breach) }
    if ($j.Has['run_one/done'] -or $j.Has['run_one/failed']) {
        if ($j.Has['run_one/failed']) { return (Invoke-AapWinAbandon $B $r $j 'run_one' 'retryable' 'run_one failed earlier') }
        $next = Move-AapWinState $B $r 'collecting'
        if ($null -eq $next) { return (New-AapWinResult $r 'held' 'allocator') }
        return (Step-AapWinCollect $B $next $j $g)
    }
    if (-not $j.Has['run_one/intent']) {
        # No lease was ever asked for. Without this process's credential nobody can reach the guest: retire it.
        if ($null -eq $g -or $r.state -cne 'ready') { return (Invoke-AapWinAbandon $B $r $j 'run_one' 'retryable' 'no lease and no guest channel') }
        return (Invoke-AapWinRunOne $B $r $j $g)
    }
    $rid = [string]$r.reservation_id
    $now = Get-AapWinNow $B
    if ($B.StatusAt.ContainsKey($rid) -and ($now - $B.StatusAt[$rid]).TotalSeconds -lt $B.StatusSeconds) {
        return (New-AapWinResult $r $(if ($B.StatusBusy[$rid]) { 'busy' } else { 'listening' }) 'not_due')
    }
    $B.StatusAt[$rid] = $now
    $live = $null -ne $g -and $g.Started -and -not $g.Hostile
    $hb = $null
    if ($live) {
        $hb = Invoke-AapWinCommand $B $r 'status'
        if ($hb.Kind -ceq 'hostile') { return (Invoke-AapWinHostile $B $r $j 'run_one' $hb.Code) }
    }
    $ba = $B.BrokerArgs
    $bs = Invoke-AapBrokerStatus -LeaseId $j.LeaseId @ba
    $known = $bs.Outcome -ceq 'ok'
    $busy = $known -and $bs.RunnerBusy -eq $true
    $B.StatusBusy[$rid] = $busy
    if ($live -and $hb.Kind -ceq 'ok') {
        $a = Get-AapWinAllocArgs $B $r
        [void](Update-AapHeartbeat @a -JobRunning:$busy)
    }
    if ($known -and -not $busy -and ($bs.RunnerStatus -ceq 'absent' -or $bs.RunnerStatus -ceq 'offline')) {
        Write-AapWinJournal $B $r 'run_one' 'done' -VmId $j.VmId -Code 'ok' -Detail "runner $($bs.RunnerStatus) and idle: job ended"
        $next = Move-AapWinState $B $r 'collecting'
        if ($null -eq $next) { return (New-AapWinResult $r 'held' 'allocator') }
        return (Step-AapWinCollect $B $next (Read-AapWinJournal $B $next) $g)
    }
    $unknown = $bs.Outcome -ceq 'refused' -and $bs.Reason -ceq 'not_found'
    if (($known -and -not $busy -and ($r.state -ceq 'draining' -or -not $live)) -or (-not $live -and $unknown)) {
        # drain: a listening runner without a job is stopped (deregistered by the release in destroy); a busy runner is
        # never touched. Without a guest channel the same holds for ready, and for a lease the broker never recorded.
        Write-AapWinJournal $B $r 'drain' 'intent' -VmId $j.VmId
        Invoke-AapWinFault 'drain:after-intent'
        Write-AapWinJournal $B $r 'drain' 'done' -VmId $j.VmId -Code 'ok' -Detail $(if ($known) { $script:DrainOnline } else { 'the broker has no runner for this lease; released at destroy' })
        $next = Move-AapWinState $B $r 'collecting'
        if ($null -eq $next) { return (New-AapWinResult $r 'held' 'allocator') }
        return (Step-AapWinCollect $B $next (Read-AapWinJournal $B $next) $g)
    }
    $code = $null
    if ($live) { $code = $hb.Kind }
    New-AapWinResult $r $(if ($busy) { 'busy' } else { 'listening' }) $code
}

function Step-AapWinQuarantined($B, $r, $j, $g) {
    $kind = [string](Get-AapWinField $r 'quarantine_kind')
    if ($kind -ceq 'hostile_guest' -or $kind -ceq 'teardown_failed' -or $j.Has['destroy/intent']) { return (Invoke-AapWinDestroy $B $r $j) }
    $breach = Get-AapWinLimitBreach $B $r $j
    if ($breach) { return (Invoke-AapWinAbandon $B $r $j 'run_one' 'fatal' $breach) }
    if ($kind -ceq 'heartbeat' -and $null -ne $g -and $g.Started -and -not $g.Hostile -and $j.LeaseId) {
        $hb = Invoke-AapWinCommand $B $r 'status'
        if ($hb.Kind -ceq 'hostile') { return (Invoke-AapWinHostile $B $r $j 'run_one' $hb.Code) }
        if ($hb.Kind -ceq 'ok') {
            $ba = $B.BrokerArgs
            $bs = Invoke-AapBrokerStatus -LeaseId $j.LeaseId @ba
            if ($bs.Outcome -cne 'ok') { return (New-AapWinResult $r 'held' 'broker_unavailable') }   # check:recover-broker
            $a = Get-AapWinAllocArgs $B $r
            $h = Update-AapHeartbeat @a -JobRunning:($bs.RunnerBusy -eq $true)
            $next = Get-AapWinField $h 'Reservation'
            if ($null -ne $next) { $r = $next }
            return (New-AapWinResult $r 'recovered')
        }
    }
    # heartbeat without a channel, crash and unknown_vm: held; Invoke-AapReconcile decides on the broker's status.
    New-AapWinResult $r 'held' $kind
}

# ---- public -------------------------------------------------------------------------------------------------------------

function New-AapWinBackend {
    <# The backend context every other call takes. Production: -Provider (New-AapWinHyperVProvider) and -Network (the P10.0
       module's Attach, Detach, Verify); everything else defaults to the fixed production paths. Without -Network, no
       guest can be attached and every create fails closed. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Provider,
        [hashtable]$Network = $null,
        [scriptblock]$Transport = $null,
        [scriptblock]$BrokerInvoker = $null,
        [string]$Distro = 'aap-runner',
        [string]$AllocatorRoot = 'C:\ProgramData\aap-runner\capacity',
        [string]$JournalRoot = 'C:\ProgramData\aap-runner\capacity\journal',
        [string]$StoragePath = 'C:\ProgramData\aap-runner\capacity\storage.json',
        [scriptblock]$Clock = $null,
        [scriptblock]$Sleep = $null,
        [int]$LockTimeoutSeconds = 30,
        [switch]$RelaxedTrustForTests
    )
    $missing = @($script:ProviderOps | Where-Object { -not ($Provider[$_] -is [scriptblock]) })
    if ($missing.Count) { throw "AAP_ProviderInvalid: missing $($missing -join ', ')" }   # check:provider-ops
    if ($null -eq $Network) {
        $Network = @{
            Attach = { param($a) throw 'AAP_NetworkUnavailable: the P10.0 guest network module is not installed; no guest is attached' }
            Detach = { param($a) }
            Verify = { param($a) 'the P10.0 guest network module is not installed' }
        }
    }
    $missing = @($script:NetworkOps | Where-Object { -not ($Network[$_] -is [scriptblock]) })
    if ($missing.Count) { throw "AAP_NetworkInvalid: missing $($missing -join ', ')" }
    $storage = Read-AapWinStorage $StoragePath
    $trusted = $script:AdminSids
    if ($RelaxedTrustForTests) {
        $why = Get-AapWinRelaxedProblem @($AllocatorRoot, $JournalRoot, $storage.base_root.Path, $storage.clone_root.Path, $storage.scratch_root.Path)
        if ($why) { throw "AAP_RelaxedRefused: $why" }
        $trusted = $script:AdminSids + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        Write-Warning 'AapWinBackend: relaxed trust for tests; the current user is trusted and ancestor ACLs are not checked'
    }
    $broker = @{ Distro = $Distro }
    if ($null -ne $BrokerInvoker) { $broker.Invoker = $BrokerInvoker }
    $B = @{
        Provider = $Provider; Network = $Network; Storage = $storage; AllocatorRoot = $AllocatorRoot; JournalRoot = $JournalRoot
        AllocArgs = @{ LockTimeoutSeconds = $LockTimeoutSeconds; RelaxedTrustForTests = [bool]$RelaxedTrustForTests }
        BrokerArgs = $broker; Relaxed = [bool]$RelaxedTrustForTests; TrustedSids = $trusted
        Transport = $Transport; Now = $Clock; Sleep = $Sleep; StatusSeconds = $script:StatusSeconds
        Guests = @{}; Leases = @{}; Tried = @{}; StatusAt = @{}; StatusBusy = @{}; Breached = @{}
    }
    if ($null -eq $B.Transport) { $B.Transport = { param($Call) Invoke-AapWinGuestChild $Call } }
    if ($null -eq $B.Now) { $B.Now = { [DateTime]::UtcNow } }
    if ($null -eq $B.Sleep) { $B.Sleep = { param($Seconds) Start-Sleep -Seconds $Seconds } }
    # A new journal folder, and its compile folder, are admin-only from their creation (P09's New-AapFolder): protected
    # DACL, SYSTEM and Administrators full control; relaxed mode adds the current user so an unelevated test can write.
    $sddl = 'D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)'
    if ($RelaxedTrustForTests) { $sddl += "(A;OICI;FA;;;$([Security.Principal.WindowsIdentity]::GetCurrent().User.Value))" }
    $sec = New-Object Security.AccessControl.DirectorySecurity
    $sec.SetSecurityDescriptorSddlForm($sddl)
    if ((Get-AapWinPathKind $JournalRoot) -ceq 'absent' -and (Get-AapWinPathKind (Split-Path -Parent $JournalRoot)) -ceq 'dir') { New-AapWinDir $JournalRoot $sec }
    $problems = @(Get-AapWinTrustProblem $B $JournalRoot)
    if ($problems.Count) { throw "AAP_JournalUntrusted: $($problems -join '; ')" }   # check:journal-trust
    # Windows PowerShell compiles Add-Type through csc.exe with temporary files under %TMP%: in the elevated supervisor
    # they must not sit in a folder a user can write, or a planted file could join the compiled job object type.
    $compile = Join-Path $JournalRoot 'compile'
    if ((Get-AapWinPathKind $compile) -ceq 'absent') { New-AapWinDir $compile $sec }
    $problems = @(Get-AapWinTrustProblem $B $compile)
    if ($problems.Count) { throw "AAP_CompileUntrusted: $($problems -join '; ')" }   # check:compile-trust
    if (-not ('AapWinJobObject' -as [type])) {
        $saved = @($env:TMP, $env:TEMP)
        try { $env:TMP = $compile; $env:TEMP = $compile; Add-Type -TypeDefinition $script:JobSource }
        finally { $env:TMP = $saved[0]; $env:TEMP = $saved[1] }
    }
    $B
}

function Invoke-AapWinStep {
    <# One step for one live windows hyperv-vm reservation (Get-AapAllocatorState .State.reservations), chosen by its
       allocator state and its journal. Call it for every such reservation on every supervisor tick; after a reconcile,
       its destroy and replay actions are carried out by the next step of the named reservation. -BaseSha256 is the
       generation's pinned hash (approved-images.json); only create uses it. Returns ReservationId, LeaseGeneration,
       Action, State, Code (a fixed code) and Summary (collect only; guest-authored text, bounded and printable). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Backend, [Parameter(Mandatory)]$Reservation, [string]$BaseSha256 = '')
    $B = $Backend
    $r = $Reservation
    if ((Get-AapWinField $r 'profile') -cne 'windows' -or (Get-AapWinField $r 'backend') -cne 'hyperv-vm' -or [string](Get-AapWinField $r 'reservation_id') -cnotmatch $script:RidRe) {
        throw 'AAP_BadRequest: the Windows backend steps windows hyperv-vm reservations only'
    }
    $lock = $null
    try { $lock = New-Object IO.FileStream((Join-Path $B.JournalRoot ([string]$r.reservation_id + '.lock')), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None, 1, [IO.FileOptions]::DeleteOnClose) } catch { $lock = $null }
    if ($null -eq $lock) { return (New-AapWinResult $r 'held' 'step_in_progress') }   # check:step-lock
    try { Step-AapWinOne $B $r $BaseSha256 } finally { $lock.Dispose() }
}

function Step-AapWinOne($B, $r, [string]$BaseSha256) {
    try { $j = Read-AapWinJournal $B $r }
    catch {
        # Journal unreadable: quarantine the reservation, capacity held (backend-lifecycle.md, crash table); a deleting
        # one as teardown_failed (the only quarantine a deleting slot may enter), never left deleting for ever.
        $s = [string]$r.state
        $qk = $(if ($s -ceq 'deleting') { 'teardown_failed' } else { 'crash' })
        if (@('creating', 'ready', 'busy', 'draining', 'collecting', 'deleting') -ccontains $s) { [void](Set-AapWinState $B $r quarantined -Kind $qk -Reason 'journal unreadable; capacity held') }   # check:journal-deleting
        return (New-AapWinResult $r 'held' 'journal_unreadable')
    }
    $g = $null
    if ($B.Guests.ContainsKey([string]$r.reservation_id)) { $g = $B.Guests[[string]$r.reservation_id] }
    # A hostile guest is final: once journaled, the slot only goes down, even after a crash between the journal and the
    # allocator write.
    $kind = [string](Get-AapWinField $r 'quarantine_kind')
    if ($j.Hostile -and $r.state -cne 'deleting' -and $r.state -cne 'reconciled' -and -not ($r.state -ceq 'quarantined' -and @('hostile_guest', 'teardown_failed') -ccontains $kind)) {   # check:hostile-final
        return (Invoke-AapWinHostile $B $r $j 'run_one' $j.Hostile)
    }
    switch -CaseSensitive ([string]$r.state) {
        'creating' { return (Step-AapWinCreating $B $r $j $g $BaseSha256) }
        'ready' { return (Step-AapWinRunning $B $r $j $g) }
        'busy' { return (Step-AapWinRunning $B $r $j $g) }
        'draining' { return (Step-AapWinRunning $B $r $j $g) }
        'collecting' { return (Step-AapWinCollect $B $r $j $g) }
        'deleting' { return (Invoke-AapWinDestroy $B $r $j) }
        'quarantined' { return (Step-AapWinQuarantined $B $r $j $g) }
    }
    New-AapWinResult $r 'held' 'state'
}

function Get-AapWinInventory {
    <# The -Inventory callback of Invoke-AapReconcile (allocator.md, Reconcile): every VM named aap-(w|l)-<slot>-..., every
       reservation folder under clone_root and scratch_root, every journaled reservation. Complete or throws: a listing
       error, an entry in a tier root that is not a plain reservation folder, or a VM entry without name or id throws. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Backend)
    $B = $Backend
    $vms = @(Get-AapWinVms $B | Where-Object { $_.Name -cmatch '^aap-(w|l)-[1-5]-' } | ForEach-Object {
            @{ name = $_.Name; vm_id = $_.Id; cpus = [int]$_.Cpus; mem_gib = [int]$_.MemGib } })
    $folders = New-Object Collections.Generic.List[object]
    foreach ($t in 'clone_root', 'scratch_root') {
        foreach ($e in [IO.Directory]::GetFileSystemEntries($B.Storage[$t].Path)) {
            $leaf = Split-Path -Leaf $e
            if ((Get-AapWinPathKind $e) -cne 'dir' -or $leaf -cnotmatch $script:RidRe) { throw "AAP_InventoryIncomplete: $e is not a reservation folder" }   # check:inventory-strict
            if (-not $folders.Contains($leaf)) { $folders.Add($leaf) }
        }
    }
    $journaled = @([IO.Directory]::GetFiles($B.JournalRoot, '*.jsonl') | ForEach-Object { Split-Path -Leaf $_ } |
            Where-Object { $_ -cmatch '^r-[0-9a-f]{16}\.jsonl\z' } | ForEach-Object { $_.Substring(0, 18) })
    @{ vms = [object[]]$vms; folders = [object[]]$folders.ToArray(); journaled = [object[]]$journaled }
}

function Get-AapWinBrokerStatus {
    <# The -BrokerStatus callback of Invoke-AapReconcile: the broker's read-only status of the reservation's runner, by the
       lease id in its journal. No lease ever asked for: absent. A journaled job end: job_ended. Broker unavailable or the
       journal unreadable: $null (the slot stays held). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Backend, [Parameter(Mandatory)]$Reservation)
    try { $j = Read-AapWinJournal $Backend $Reservation } catch { return $null }
    if ($j.Has['run_one/done']) { return @{ status = 'absent'; busy = $false; job_ended = $true } }
    if (-not $j.Has['run_one/intent']) { return @{ status = 'absent'; busy = $false; job_ended = $false } }
    if (-not $j.LeaseId) { return $null }
    $ba = $Backend.BrokerArgs
    $s = Invoke-AapBrokerStatus -LeaseId $j.LeaseId @ba
    if ($s.Outcome -cne 'ok') { return $null }
    @{ status = [string]$s.RunnerStatus; busy = [bool]$s.RunnerBusy; job_ended = $false }
}

Export-ModuleMember -Function New-AapWinBackend, Invoke-AapWinStep, Get-AapWinInventory, Get-AapWinBrokerStatus, Get-AapWinStorageProblem,
    Get-AapWinHostProblem, Select-AapWinPartition, Write-AapWinUnattend
