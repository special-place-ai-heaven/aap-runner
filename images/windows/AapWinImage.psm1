# P06: builds the Windows Server 2025 / VS2026 golden image. Windows PowerShell 5.1 and PowerShell 7.
# Every Hyper-V, disk, guest, ACL and input-verification call goes through the provider (a hashtable of scriptblocks,
# AapWinImage.HyperV.psm1 in production, fakes in tests). This module itself does filesystem work inside the build and
# evidence folders only, and never touches the network: inputs come from P03 staging, verified by the provider.
# Every refusal throws 'AAP_<Reason>: <detail>'. Lines tagged '# check:<name>' are the safety checks the mutation run
# disables one at a time (tests/images/windows/Invoke-AapWinMutations.ps1).

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:Profile = 'win25-vs2026-x64'
$script:GiB = 1073741824
$script:Utf8 = New-Object Text.UTF8Encoding($false)
$script:ProviderOps = @('TestRootTrust', 'GetVolume', 'MeasureBytes', 'VerifyInputs', 'NewBuildDisk', 'ApplyWindowsImage', 'NewDiffDisk',
    'WriteOfflineFiles', 'NewVm', 'StartVm', 'StopVm', 'RestartVm', 'RemoveVm', 'WaitGuestReady', 'SendFile', 'InvokeGuest', 'ReceiveFile',
    'OptimizeDisk', 'MountReadOnly', 'Dismount', 'ReadOfflineRegistry', 'SetReadOnlyAcl', 'GetVmMemoryOverheadMib')
$script:Actions = @('prepare-folders', 'upload-sources', 'upload-report-base', 'layout-image-folder', 'create-install-user', 'check-install-user',
    'bcdedit-testsigning', 'wlansvc-manual', 'assert-test-results', 'software-report', 'assert-software-report',
    'download-software-report-md', 'download-software-report-json', 'sysprep-generalize')
$script:ScriptPhaseSeconds = 6 * 3600   # longest upstream phase (Visual Studio) is a few hours
$script:ActionSeconds = 3600
$script:ReplyMaxBytes = 65536
$script:ReportMaxBytes = 16MB
$script:InventoryMaxBytes = 4MB
$script:ScanFileMaxBytes = 32MB
$script:CapHeadroom = 1.25              # cap = measured peak x 1.25, rounded up (backend-lifecycle: cap >= peak)
$script:EvaluationDays = 180
$script:RebuildLeadDays = 14
$script:Reserved = '^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9]) *(\..*)?$'

function Get-AapUtc([DateTime]$Time = [DateTime]::UtcNow) { $Time.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture) }
function Get-AapProp($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    if ($Object -is [Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] } else { return $null } }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value } else { return $null }
}
function Get-AapSha256File([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Get-AapSha256Text([string]$Text) {
    $h = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($h.ComputeHash($script:Utf8.GetBytes($Text))) -replace '-', '').ToLowerInvariant() } finally { $h.Dispose() }
}
function Get-AapPrintable([string]$Text, [int]$Max = 200) {
    if ($null -eq $Text) { return '' }
    $t = [regex]::Replace($Text, '[^\x20-\x7e]', '?')
    if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max) }
    return $t
}
function Write-AapJson($Object, [string]$Path) {
    $tmp = "$Path.tmp"
    [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $Object -Depth 12) + "`n", $script:Utf8)
    if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($tmp, $Path, [NullString]::Value) } else { [IO.File]::Move($tmp, $Path) }
}
function Read-AapJson([string]$Path) { ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path)) }
function Invoke-AapProvider($Provider, [string]$Op, [hashtable]$A = @{}) { & $Provider[$Op] $A }

function Assert-AapProvider($Provider) {
    if (-not ($Provider -is [Collections.IDictionary])) { throw 'AAP_ProviderInvalid: the provider must be a hashtable of scriptblocks' }
    $missing = @($script:ProviderOps | Where-Object { -not ($Provider[$_] -is [scriptblock]) })
    if ($missing.Count) { throw "AAP_ProviderInvalid: missing $($missing -join ', ')" }
}

function Test-AapLink([string]$Path) {
    try { return (([int][IO.File]::GetAttributes($Path)) -band [int][IO.FileAttributes]::ReparsePoint) -ne 0 } catch { return $false }
}

# Deletes $Path, which must lie strictly below $Under, without following any junction or symbolic link: a link is removed
# as an entry, never entered. Every folder from $Under down to $Path must be a plain folder.
function Remove-AapTree([string]$Path, [string]$Under) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\'); $root = [IO.Path]::GetFullPath($Under).TrimEnd('\')
    if (-not $full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "AAP_UnsafeDelete: $full is not below $root" }
    $walk = $root
    foreach ($seg in $full.Substring($root.Length + 1).Split('\')) {
        if (Test-AapLink $walk) { throw "AAP_UnsafeDelete: $walk is a link" }   # check:safe-delete
        $walk = Join-Path $walk $seg
    }
    if (-not (Test-Path -LiteralPath $full)) { return }
    $attr = [int][IO.File]::GetAttributes($full)
    if (($attr -band [int][IO.FileAttributes]::Directory) -eq 0) { [IO.File]::SetAttributes($full, [IO.FileAttributes]::Normal); [IO.File]::Delete($full); return }
    if (($attr -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) { [IO.Directory]::Delete($full, $false); return }
    Remove-AapTreeInner $full
}
function Remove-AapTreeInner([string]$Dir) {
    foreach ($e in [IO.Directory]::GetFileSystemEntries($Dir)) {
        $attr = [int][IO.File]::GetAttributes($e)
        $isDir = ($attr -band [int][IO.FileAttributes]::Directory) -ne 0
        if (($attr -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) {
            if ($isDir) { [IO.Directory]::Delete($e, $false) } else { [IO.File]::Delete($e) }
        } elseif ($isDir) { Remove-AapTreeInner $e }
        else { [IO.File]::SetAttributes($e, [IO.FileAttributes]::Normal); [IO.File]::Delete($e) }
    }
    [IO.Directory]::Delete($Dir, $false)
}

# ---------------------------------------------------------------------------------------------------------------------
# Storage record (backend-lifecycle.md revision 2, Storage tiers). Only the elevated helper writes it; this reads it.

function Test-AapRootForm([string]$Path) {
    if ($Path -cnotmatch '^[A-Za-z]:\\[A-Za-z0-9 ._()\-]+(\\[A-Za-z0-9 ._()\-]+)*\z') { return "is not an absolute folder below a drive root" }
    foreach ($seg in $Path.Substring(3).Split('\')) {
        if ($seg -eq '.' -or $seg -eq '..') { return 'has a . or .. component' }
        if ($seg -match '[ .]$') { return 'has a component with a trailing dot or space' }
        if ($seg -match $script:Reserved) { return 'names a reserved device' }
    }
    return $null
}

function Read-AapStorageRecord {
    <# The storage document, validated. Throws AAP_StorageMissing or AAP_StorageInvalid. Adds Staging (staging_root or <base_root>\staging). #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "AAP_StorageMissing: no storage document at $Path; the VM profiles stay off until the installer writes one" }   # check:storage-missing
    if ((New-Object IO.FileInfo $Path).Length -gt 65536) { throw "AAP_StorageInvalid: $Path is over 64 KiB" }
    try { $doc = Read-AapJson $Path } catch { throw "AAP_StorageInvalid: $Path is not JSON" }
    if ((Get-AapProp $doc 'schema') -ne 2 -or (Get-AapProp $doc 'kind') -cne 'storage') { throw 'AAP_StorageInvalid: not a schema 2 storage document' }
    $floor = Get-AapProp $doc 'volume_floor_gib'
    if (-not ($floor -is [int] -or $floor -is [long]) -or $floor -lt 10) { throw 'AAP_StorageInvalid: volume_floor_gib must be an integer of at least 10' }
    $roots = Get-AapProp $doc 'roots'
    $tiers = [ordered]@{}
    foreach ($t in 'base_root', 'clone_root', 'scratch_root', 'staging_root') {
        $r = Get-AapProp $roots $t
        if ($null -eq $r) { if ($t -eq 'staging_root') { continue } else { throw "AAP_StorageInvalid: $t is missing" } }
        $p = [string](Get-AapProp $r 'path'); $g = [string](Get-AapProp $r 'volume_guid')
        $why = Test-AapRootForm $p
        if ($why) { throw "AAP_StorageInvalid: $t $why" }   # check:storage-invalid
        if ($g -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') { throw "AAP_StorageInvalid: $t volume_guid is malformed" }
        $tiers[$t] = [pscustomobject]@{ Tier = $t; Path = $p; VolumeGuid = $g }
    }
    $list = @($tiers.Values)
    foreach ($a in $list) {
        foreach ($b in $list) {
            if ($a -eq $b) { continue }
            $pa = $a.Path.ToLowerInvariant(); $pb = $b.Path.ToLowerInvariant()
            if ($pa -eq $pb -or $pa.StartsWith($pb + '\')) { throw "AAP_StorageInvalid: $($a.Tier) is equal to or inside $($b.Tier)" }   # check:storage-nesting
        }
        foreach ($f in @('C:\ProgramData\aap-runner', $env:SystemRoot, 'C:\wsl') | Where-Object { $_ }) {
            $pa = $a.Path.ToLowerInvariant(); $pf = $f.TrimEnd('\').ToLowerInvariant()
            if ($pa -eq $pf -or $pa.StartsWith($pf + '\') -or $pf.StartsWith($pa + '\')) { throw "AAP_StorageInvalid: $($a.Tier) overlaps $f" }   # check:storage-nesting
        }
    }
    $staging = $tiers['staging_root']
    if ($null -eq $staging) { $staging = [pscustomobject]@{ Tier = 'staging_root'; Path = (Join-Path $tiers['base_root'].Path 'staging'); VolumeGuid = $tiers['base_root'].VolumeGuid } }
    return [pscustomobject]@{ Path = $Path; FloorGib = [int]$floor; Base = $tiers['base_root']; Clone = $tiers['clone_root']; Scratch = $tiers['scratch_root']; Staging = $staging }
}

# The builder writes to base_root and the staging root, and trusts the storage document's folder. Each must pass the
# ProgramData rules (owner, ACL, reparse, ancestors, fixed drive) and sit on its recorded volume.
function Assert-AapStorageTrusted($Storage, $Provider) {
    $checks = @(
        [pscustomobject]@{ Name = 'storage document folder'; Path = (Split-Path -Parent $Storage.Path); Guid = $null },
        [pscustomobject]@{ Name = 'base_root'; Path = $Storage.Base.Path; Guid = $Storage.Base.VolumeGuid },
        [pscustomobject]@{ Name = 'staging root'; Path = $Storage.Staging.Path; Guid = $Storage.Staging.VolumeGuid })
    foreach ($c in $checks) {
        $problems = @(Invoke-AapProvider $Provider 'TestRootTrust' @{ Path = $c.Path } | Where-Object { $_ })
        if ($problems.Count) { throw "AAP_StorageUntrusted: $($c.Name) $($c.Path): $(@($problems | ForEach-Object { Get-AapPrintable ([string]$_) 300 }) -join '; ')" }   # check:root-untrusted
        if ($c.Guid) {
            $v = Invoke-AapProvider $Provider 'GetVolume' @{ Path = $c.Path }
            if ([string]$v.Guid -ne $c.Guid) { throw "AAP_StorageVolumeMismatch: $($c.Name) is on volume $($v.Guid), recorded $($c.Guid)" }   # check:volume-mismatch
        }
    }
}

# A build checks its own volumes before it starts (backend-lifecycle.md, Admission). The staging volume holds the build
# folder up to StagingGibMax; base_root receives one copy of the OS disk, at most its maximum size.
function Assert-AapBuildSpace($Storage, $Provider, $Plan, [int]$StagingGibMax) {
    $need = @{}
    $need[$Storage.Staging.VolumeGuid] = [double]$StagingGibMax
    $need[$Storage.Base.VolumeGuid] = [double](Get-AapProp $need $Storage.Base.VolumeGuid) + [int]$Plan.os_disk_gib + 1
    foreach ($guid in @($need.Keys)) {
        $path = $(if ($guid -eq $Storage.Staging.VolumeGuid) { $Storage.Staging.Path } else { $Storage.Base.Path })
        $v = Invoke-AapProvider $Provider 'GetVolume' @{ Path = $path }
        $usable = ([double]$v.FreeBytes / $script:GiB) - $Storage.FloorGib
        if ($usable -lt $need[$guid]) { throw ("AAP_DiskLow: volume {0} has {1:N1} GiB above its {2} GiB floor; the build needs {3} GiB there" -f $guid, $usable, $Storage.FloorGib, $need[$guid]) }   # check:disk-low
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# Plan, blockers and inputs

function Read-AapWinBuildPlan {
    <# build-plan.json, shape-checked. Every script must carry a pinned SHA-256 (AAP_ScriptUnpinned otherwise). #>
    param([Parameter(Mandatory)][string]$Path)
    $plan = Read-AapJson $Path
    if ($plan.schema -ne 1 -or $plan.profile -cne $script:Profile) { throw 'AAP_PlanInvalid: not a schema 1 plan for win25-vs2026-x64' }
    if ([int]$plan.os_disk_gib -lt 1) { throw 'AAP_PlanInvalid: os_disk_gib' }
    $i = 0
    foreach ($p in @($plan.phases)) {
        $i++
        if ($p.id -cne ('p{0:d2}' -f $i)) { throw "AAP_PlanInvalid: phase $i has id $($p.id)" }
        switch ($p.kind) {
            'scripts' {
                foreach ($s in @($p.scripts)) {
                    if ($s.name -cnotmatch '^[A-Za-z0-9._-]{1,80}\.ps1$' -or ($s.dir -cne 'build' -and $s.dir -cne 'tests')) { throw "AAP_PlanInvalid: $($p.id) script name $($s.name)" }
                    if ([string]$s.sha256 -cnotmatch '^[0-9a-f]{64}$') { throw "AAP_ScriptUnpinned: $($p.id) $($s.name) has no pinned SHA-256 (rerun New-AapWinBuildPlan.ps1 -ScriptsDir on the P03-staged archive)" }   # check:plan-unpinned
                }
            }
            'action' { if ($script:Actions -cnotcontains $p.action) { throw "AAP_PlanInvalid: $($p.id) unknown action $($p.action)" } }
            'restart' { }
            default { throw "AAP_PlanInvalid: $($p.id) unknown kind $($p.kind)" }
        }
    }
    $last = @($plan.phases)[-1]
    if ($last.kind -cne 'action' -or $last.action -cne 'sysprep-generalize') { throw 'AAP_PlanInvalid: the last phase must be sysprep-generalize' }
    return $plan
}

function Get-AapWinBlockers {
    <# Ids of every input blocker for this profile: the P03 manifest's not_reproducible entries plus the plan's own. #>
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)][string]$ManifestPath)
    $m = Read-AapJson $ManifestPath
    $ids = @($m.not_reproducible | Where-Object { @($_.profiles) -contains 'windows-2025-vs2026-x64' } | ForEach-Object { [string]$_.id })
    return @($ids + @($Plan.blockers | ForEach-Object { [string]$_.id }))
}

# ---------------------------------------------------------------------------------------------------------------------
# Credentials and answer files

function New-AapWinPassword {
    <# 32 random characters with upper, lower, digit and symbol. Memory only: never written to a file, log or record. #>
    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789-_=+.,:!@#%'
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        do {
            $bytes = New-Object byte[] 64
            $rng.GetBytes($bytes)
            $sb = New-Object Text.StringBuilder
            foreach ($b in $bytes) { if ($b -lt 204 -and $sb.Length -lt 32) { [void]$sb.Append($alphabet[$b % 68]) } }
            $pw = $sb.ToString()
        } until ($pw.Length -eq 32 -and $pw -cmatch '[A-Z]' -and $pw -cmatch '[a-z]' -and $pw -match '[0-9]' -and $pw -match '[^A-Za-z0-9]')
        return $pw
    } finally { $rng.Dispose() }
}

function New-AapWinUnattend {
    <# The answer file the builder writes offline into \Windows\Panther\unattend.xml of a disk before its first boot.
       It creates one local administrator (the build's install user, or the verification job user), skips OOBE, sets UTC and
       en-US, and never enables autologon. The password is a plain-text value only inside the disk being prepared. #>
    param([Parameter(Mandatory)][string]$UserName, [Parameter(Mandatory)][string]$Password)
    if ($UserName -cnotmatch '^[A-Za-z][A-Za-z0-9_-]{0,19}$') { throw 'AAP_UnattendInvalid: user name' }
    $e = [Security.SecurityElement]::Escape($Password)
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
              <Value>$e</Value>
              <PlainText>true</PlainText>
            </Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
    </component>
  </settings>
</unattend>
"@
    [void]([xml]$xml)
    return $xml
}

# ---------------------------------------------------------------------------------------------------------------------
# Guest replies: hostile bytes. One printable-ASCII JSON object of known fields, bounded, for the expected phase.

function ConvertFrom-AapGuestReply {
    param([AllowNull()][string]$Text, [Parameter(Mandatory)][string]$Phase, [int]$MaxBytes = $script:ReplyMaxBytes)
    if ($null -eq $Text -or $Text.Length -gt $MaxBytes) { throw "AAP_HostileGuest: $Phase reply is missing or over $MaxBytes bytes" }   # check:hostile-size
    if ($Text -notmatch '^\s*\{[\x20-\x7e\r\n\t]*\}\s*$') { throw "AAP_HostileGuest: $Phase reply is not one printable-ASCII JSON object" }   # check:hostile-shape
    try { $o = ConvertFrom-Json -InputObject $Text } catch { throw "AAP_HostileGuest: $Phase reply is not JSON" }
    if (-not ($o -is [Management.Automation.PSCustomObject])) { throw "AAP_HostileGuest: $Phase reply is not a JSON object" }
    $extra = @($o.PSObject.Properties | ForEach-Object { $_.Name } | Where-Object { @('schema', 'phase', 'status', 'message', 'scripts', 'data') -cnotcontains $_ })
    if ($extra.Count -or (Get-AapProp $o 'schema') -ne 1 -or [string](Get-AapProp $o 'phase') -cne $Phase -or @('ok', 'failed') -cnotcontains [string](Get-AapProp $o 'status')) { throw "AAP_HostileGuest: $Phase reply has unexpected fields or values" }   # check:hostile-schema
    $msg = Get-AapProp $o 'message'
    if ($null -ne $msg -and (-not ($msg -is [string]) -or $msg.Length -gt 512)) { throw "AAP_HostileGuest: $Phase message" }
    $scripts = @(Get-AapProp $o 'scripts')
    if ($scripts.Count -gt 64) { throw "AAP_HostileGuest: $Phase lists too many scripts" }
    foreach ($s in $scripts) {
        if ($null -eq $s) { continue }
        if (-not ($s -is [Management.Automation.PSCustomObject])) { throw "AAP_HostileGuest: $Phase script entry" }
        $names = @($s.PSObject.Properties | ForEach-Object { $_.Name })
        $code = Get-AapProp $s 'exit_code'; $secs = Get-AapProp $s 'seconds'
        $bad = $names.Count -ne 4 -or @($names | Where-Object { @('name', 'sha256', 'exit_code', 'seconds') -cnotcontains $_ }).Count -or
            [string](Get-AapProp $s 'name') -cnotmatch '^[A-Za-z0-9._-]{1,80}\.ps1$' -or [string](Get-AapProp $s 'sha256') -cnotmatch '^[0-9a-f]{64}$' -or
            -not ($code -is [int] -or $code -is [long]) -or -not ($secs -is [int] -or $secs -is [long]) -or $secs -lt 0
        if ($bad) { throw "AAP_HostileGuest: $Phase script entry" }
    }
    return $o
}

# A script phase passed only if the guest ran exactly the planned scripts, in order, with the pinned hashes, each with an
# accepted exit code. The guest checks the hashes before running; this checks its report again.
function Assert-AapScriptReply($Reply, $PhasePlan) {
    $want = @($PhasePlan.scripts); $got = @(Get-AapProp $Reply 'scripts' | Where-Object { $null -ne $_ })
    if ($Reply.status -cne 'ok') { throw "AAP_PhaseFailed: $($PhasePlan.id) $(Get-AapPrintable (Get-AapProp $Reply 'message'))" }   # check:phase-failed
    if ($got.Count -ne $want.Count) { throw "AAP_PhaseFailed: $($PhasePlan.id) ran $($got.Count) of $($want.Count) scripts" }
    for ($i = 0; $i -lt $want.Count; $i++) {
        if ($got[$i].name -cne $want[$i].name) { throw "AAP_PhaseFailed: $($PhasePlan.id) script $i is $($got[$i].name), planned $($want[$i].name)" }
        if ($got[$i].sha256 -cne $want[$i].sha256) { throw "AAP_ScriptHashMismatch: $($PhasePlan.id) $($want[$i].name)" }   # check:script-hash
        if (@($PhasePlan.valid_exit_codes) -notcontains [int]$got[$i].exit_code) { throw "AAP_PhaseFailed: $($PhasePlan.id) $($want[$i].name) exited $($got[$i].exit_code)" }   # check:exit-code
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# Secret scan of the sealed disk (image-catalog.md, secret_scan). Reports rule and path, never the matched value.

function Invoke-AapWinSecretScan {
    param([Parameter(Mandatory)][string]$MountRoot, [Parameter(Mandatory)]$Provider, [string[]]$KnownSecret = @())
    $nameRules = @(
        @{ Id = 'runner-credentials'; Re = '^\.credentials' }, @{ Id = 'runner-config'; Re = '^\.runner$' },
        @{ Id = 'answer-file'; Re = '^(auto)?unattend.*\.xml$' }, @{ Id = 'ssh-host-key'; Re = '^ssh_host_.*_key$' },
        @{ Id = 'ssh-authorized-keys'; Re = '^(administrators_)?authorized_keys$' }, @{ Id = 'shell-history'; Re = '^(ConsoleHost_history\.txt|\.bash_history|\.zsh_history|\.python_history)$' },
        @{ Id = 'app-key'; Re = '^app\.pem$' }, @{ Id = 'cloud-init-seed'; Re = '^(user-data|meta-data|network-config)$' })
    $contentRules = @(
        @{ Id = 'pem-private-key'; Re = '-----BEGIN [A-Z ]*PRIVATE KEY-----' },
        @{ Id = 'github-token'; Re = '\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36}\b' },
        @{ Id = 'github-pat'; Re = 'github_pat_[A-Za-z0-9_]{22,}' },
        @{ Id = 'jit-config'; Re = 'ACTIONS_RUNNER_INPUT_JITCONFIG=' },
        @{ Id = 'synthetic-marker'; Re = 'AAP-SYNTHETIC-SECRET-MARKER|SYNTHETIC-JIT-MARKER' })
    $findings = New-Object System.Collections.Generic.List[object]
    $scanned = 0; $large = 0; $unreadable = 0
    $latin1 = [Text.Encoding]::GetEncoding(28591)
    $root = $MountRoot.TrimEnd('\')
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($root)
    while ($stack.Count) {
        $dir = $stack.Pop()
        try { $entries = [IO.Directory]::GetFileSystemEntries($dir) } catch { $unreadable++; continue }
        foreach ($e in $entries) {
            $rel = $e.Substring($root.Length + 1)
            $attr = [int][IO.File]::GetAttributes($e)
            if (($attr -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            if (($attr -band [int][IO.FileAttributes]::Directory) -ne 0) { $stack.Push($e); continue }
            $leaf = [IO.Path]::GetFileName($e)
            foreach ($r in $nameRules) { if ($leaf -match $r.Re) { $findings.Add([pscustomobject]@{ rule = $r.Id; path = (Get-AapPrintable $rel) }) } }
            if ((New-Object IO.FileInfo $e).Length -gt $script:ScanFileMaxBytes) { $large++; continue }
            try { $bytes = [IO.File]::ReadAllBytes($e) } catch { $unreadable++; continue }
            $scanned++
            $text = $latin1.GetString($bytes)
            foreach ($r in $contentRules) { if ($text -cmatch $r.Re) { $findings.Add([pscustomobject]@{ rule = $r.Id; path = (Get-AapPrintable $rel) }) } }
            $wide = $null
            foreach ($k in $KnownSecret) {
                if (-not $k) { continue }
                if ($null -eq $wide) { $wide = [Text.Encoding]::Unicode.GetString($bytes, 0, $bytes.Length - ($bytes.Length % 2)) }
                if ($text.Contains($k) -or $wide.Contains($k)) { $findings.Add([pscustomobject]@{ rule = 'build-credential'; path = (Get-AapPrintable $rel) }) }   # check:secret-known
            }
        }
    }
    $reg = @(
        @{ Id = 'autologon-password'; Hive = 'SOFTWARE'; Key = 'Microsoft\Windows NT\CurrentVersion\Winlogon'; Name = 'DefaultPassword' },
        @{ Id = 'autologon-enabled'; Hive = 'SOFTWARE'; Key = 'Microsoft\Windows NT\CurrentVersion\Winlogon'; Name = 'AutoAdminLogon' },
        @{ Id = 'lsa-default-password'; Hive = 'SECURITY'; Key = 'Policy\Secrets\DefaultPassword'; Name = $null })
    foreach ($r in $reg) {
        $v = Invoke-AapProvider $Provider 'ReadOfflineRegistry' @{ MountRoot = $MountRoot; Hive = $r.Hive; Key = $r.Key; Name = $r.Name }
        $hit = $(if ($r.Id -eq 'autologon-enabled') { [string]$v -eq '1' } else { $null -ne $v -and [string]$v -ne '' })
        if ($hit) { $findings.Add([pscustomobject]@{ rule = $r.Id; path = "registry:$($r.Hive)\$($r.Key)" }) }
    }
    $result = $(if ($findings.Count) { 'found' } elseif ($unreadable) { 'incomplete' } else { 'clean' })
    return [pscustomobject]@{ schema = 1; result = $result; files_scanned = $scanned; content_skipped_over_32mib = $large; unreadable = $unreadable
        findings = @($findings | Select-Object -First 200); rules = @(@($nameRules + $contentRules) | ForEach-Object { $_.Id }) + @('build-credential') + @($reg | ForEach-Object { $_.Id }) }
}

# ---------------------------------------------------------------------------------------------------------------------
# Build

function Get-AapWinNames($Plan, [int]$AapBuild) {
    $gen = "$($script:Profile)/$($Plan.baseline.image_version)-aap.$AapBuild"
    $id = $gen.Replace('/', '_')
    $tag = (Get-AapSha256Text $id).Substring(0, 8)
    return [pscustomobject]@{ GenerationId = $gen; BuildId = $id; Folder = "$($Plan.baseline.image_version)-aap.$AapBuild"; BuildVm = "aap-wbuild-$tag"; VerifyVm = "aap-wverify-$tag" }
}

function Assert-AapWinConfig($Config) {
    foreach ($k in 'StoragePath', 'EvidenceRoot', 'AapBuild', 'MediaFile', 'MediaSha256', 'Edition', 'BuildCpus', 'BuildMemGib', 'StagingGibMax', 'BaseGibMax', 'JobDiskGibMax', 'BuilderCommit', 'SourceEntry') {
        if ($null -eq (Get-AapProp $Config $k) -or [string](Get-AapProp $Config $k) -eq '') { throw "AAP_ConfigInvalid: $k is required" }
    }
    if ([int]$Config.AapBuild -lt 1) { throw 'AAP_ConfigInvalid: AapBuild' }
    if ([string]$Config.MediaSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'AAP_ConfigInvalid: MediaSha256' }
    if ([string]$Config.BuilderCommit -cnotmatch '^[0-9a-f]{40}$') { throw 'AAP_ConfigInvalid: BuilderCommit' }
    if ([string]$Config.MediaFile -cnotmatch '^[A-Za-z0-9._()\- ]{1,120}\.iso$') { throw 'AAP_ConfigInvalid: MediaFile must be a file name under <base_root>\media' }
}

function Save-AapState($Ctx) { Write-AapJson $Ctx.State $Ctx.StatePath }
function Set-AapStep($Ctx, [string]$Step, [string]$Value) {
    $Ctx.State.steps[$Step] = $Value
    Save-AapState $Ctx
}

function Invoke-AapGuest($Ctx, [hashtable]$Request, [int]$TimeoutSeconds) {
    $Request['schema'] = 1
    $local = Join-Path $Ctx.BuildDir 'request.json'
    [IO.File]::WriteAllText($local, (ConvertTo-Json -InputObject $Request -Depth 8), $script:Utf8)
    $null = Invoke-AapProvider $Ctx.Provider 'SendFile' @{ VmName = $Ctx.Vm; User = $Ctx.User; Password = $Ctx.Password; HostPath = $local; GuestPath = 'C:\aap-build\request.json' }
    $text = Invoke-AapProvider $Ctx.Provider 'InvokeGuest' @{ VmName = $Ctx.Vm; User = $Ctx.User; Password = $Ctx.Password; Script = $Ctx.GuestScript
        RequestPath = 'C:\aap-build\request.json'; TimeoutSeconds = $TimeoutSeconds; MaxBytes = $script:ReplyMaxBytes }
    return ConvertFrom-AapGuestReply -Text $text -Phase ([string]$Request.phase)
}

function Assert-AapStagingBudget($Ctx) {
    $bytes = [double](Invoke-AapProvider $Ctx.Provider 'MeasureBytes' @{ Path = $Ctx.BuildDir })
    if ($bytes -gt $Ctx.State.staging_peak_bytes) { $Ctx.State.staging_peak_bytes = $bytes }
    if ($bytes -gt [double]$Ctx.Config.StagingGibMax * $script:GiB) { throw ("AAP_BudgetExceeded: the build folder holds {0:N1} GiB, over StagingGibMax {1}" -f ($bytes / $script:GiB), $Ctx.Config.StagingGibMax) }   # check:budget
}

function Invoke-AapPhase($Ctx, $P) {
    $vars = $Ctx.Plan.variables
    switch ($P.kind) {
        'scripts' {
            $envMap = [ordered]@{}
            foreach ($prop in $P.env.PSObject.Properties) {
                $v = [string]$prop.Value
                foreach ($vp in $vars.PSObject.Properties) { $v = $v.Replace('${var.' + $vp.Name + '}', [string]$vp.Value) }
                if ($v -match '\$\{') { throw "AAP_PlanInvalid: $($P.id) $($prop.Name) has an unresolved variable" }
                $envMap[$prop.Name] = $v
            }
            $req = @{ phase = $P.id; kind = 'scripts'; scripts = @($P.scripts | ForEach-Object { @{ name = $_.name; dir = $_.dir; sha256 = $_.sha256 } })
                env = $envMap; execution_policy = $P.execution_policy; valid_exit_codes = @($P.valid_exit_codes); pause_before_seconds = [int]$P.pause_before_seconds
                vars = $vars }
            $r = Invoke-AapGuest $Ctx $req $script:ScriptPhaseSeconds
            Assert-AapScriptReply $r $P
            $Ctx.Evidence.phases.Add([ordered]@{ id = $P.id; kind = 'scripts'; scripts = @($r.scripts) })
        }
        'restart' {
            $null = Invoke-AapProvider $Ctx.Provider 'RestartVm' @{ VmName = $Ctx.Vm; TimeoutSeconds = [int]$P.timeout_seconds }
            $ok = Invoke-AapProvider $Ctx.Provider 'WaitGuestReady' @{ VmName = $Ctx.Vm; User = $Ctx.User; Password = $Ctx.Password; TimeoutSeconds = [int]$P.timeout_seconds }
            if (-not $ok) { throw "AAP_RebootTimeout: $($P.id) guest not ready within $($P.timeout_seconds) s" }   # check:reboot-timeout
            foreach ($check in @($(if ($P.check_registry) { 'wait-no-pending-reboot' }), $P.check) | Where-Object { $_ }) {
                $r = Invoke-AapGuest $Ctx @{ phase = $P.id; kind = 'action'; action = $check; vars = $vars; timeout_seconds = [int]$P.timeout_seconds } ([int]$P.timeout_seconds)
                if ($r.status -cne 'ok') { throw "AAP_PhaseFailed: $($P.id) $check $(Get-AapPrintable (Get-AapProp $r 'message'))" }
            }
            $Ctx.Evidence.phases.Add([ordered]@{ id = $P.id; kind = 'restart' })
        }
        'action' {
            switch ($P.action) {
                { $_ -like 'download-software-report-*' } {
                    $ext = $P.action.Substring($P.action.LastIndexOf('-') + 1)
                    $dest = Join-Path $Ctx.EvidenceDir "software-report.$ext"
                    $null = Invoke-AapProvider $Ctx.Provider 'ReceiveFile' @{ VmName = $Ctx.Vm; User = $Ctx.User; Password = $Ctx.Password; GuestPath = "C:\software-report.$ext"; HostPath = $dest; MaxBytes = $script:ReportMaxBytes }
                    if (-not (Test-Path -LiteralPath $dest) -or (New-Object IO.FileInfo $dest).Length -gt $script:ReportMaxBytes) { throw "AAP_HostileGuest: software-report.$ext missing or over $($script:ReportMaxBytes) bytes" }
                    $Ctx.Evidence.reports["software-report.$ext"] = Get-AapSha256File $dest
                }
                default {
                    if ($P.action -eq 'upload-sources') { $null = Invoke-AapProvider $Ctx.Provider 'SendFile' @{ VmName = $Ctx.Vm; User = $Ctx.User; Password = $Ctx.Password; HostPath = $Ctx.SourceArchive; GuestPath = 'C:\aap-build\runner-images.zip' } }
                    $req = @{ phase = $P.id; kind = 'action'; action = $P.action; vars = $vars }
                    $r = Invoke-AapGuest $Ctx $req $script:ActionSeconds
                    if ($r.status -cne 'ok') { throw "AAP_PhaseFailed: $($P.id) $($P.action) $(Get-AapPrintable (Get-AapProp $r 'message'))" }   # check:action-failed
                }
            }
            $Ctx.Evidence.phases.Add([ordered]@{ id = $P.id; kind = 'action'; action = $P.action })
        }
    }
}

# Fresh guest from the sealed disk: a differencing child in the build folder, the job user from a new answer file, then
# upstream tests, the P05 inventory probe and native toolchain discovery as that user (guest/AapGuestVerify.ps1).
function Invoke-AapVerify($Ctx) {
    $dir = Join-Path $Ctx.BuildDir 'verify'
    [void][IO.Directory]::CreateDirectory($dir)
    $child = Join-Path $dir 'os.avhdx'; $temp = Join-Path $dir 'temp.vhdx'
    $user = 'runneradmin'; $pw = New-AapWinPassword
    $null = Invoke-AapProvider $Ctx.Provider 'NewDiffDisk' @{ Parent = $Ctx.OsDisk; Path = $child }
    $null = Invoke-AapProvider $Ctx.Provider 'NewBuildDisk' @{ Path = $temp; SizeGib = [int]$Ctx.Plan.temp_disk_gib; Format = $true }
    $null = Invoke-AapProvider $Ctx.Provider 'WriteOfflineFiles' @{ Vhdx = $child; Files = @{ 'Windows\Panther\unattend.xml' = (New-AapWinUnattend -UserName $user -Password $pw) } }
    $null = Invoke-AapProvider $Ctx.Provider 'NewVm' @{ Name = $Ctx.Names.VerifyVm; Path = $dir; OsDisk = $child; TempDisk = $temp; Cpus = [int]$Ctx.Config.BuildCpus; MemGib = [int]$Ctx.Config.BuildMemGib; SwitchName = (Get-AapProp $Ctx.Config 'SwitchName') }
    $null = Invoke-AapProvider $Ctx.Provider 'StartVm' @{ VmName = $Ctx.Names.VerifyVm }
    if (-not (Invoke-AapProvider $Ctx.Provider 'WaitGuestReady' @{ VmName = $Ctx.Names.VerifyVm; User = $user; Password = $pw; TimeoutSeconds = 1800 })) { throw 'AAP_VerifyFailed: fresh guest not ready' }
    $vctx = [pscustomobject]@{ Provider = $Ctx.Provider; BuildDir = $Ctx.BuildDir; Vm = $Ctx.Names.VerifyVm; User = $user; Password = $pw; GuestScript = 'C:\aap-build\AapGuestVerify.ps1' }
    foreach ($f in @(@{ H = $Ctx.VerifyScript; G = 'C:\aap-build\AapGuestVerify.ps1' }, @{ H = $Ctx.ProbeScript; G = 'C:\aap-build\probe-windows.ps1' }, @{ H = $Ctx.HelloC; G = 'C:\aap-build\hello.c' }, @{ H = $Ctx.SourceArchive; G = 'C:\aap-build\runner-images.zip' })) {
        $null = Invoke-AapProvider $Ctx.Provider 'SendFile' @{ VmName = $vctx.Vm; User = $user; Password = $pw; HostPath = $f.H; GuestPath = $f.G }
    }
    $r = Invoke-AapGuest $vctx @{ phase = 'verify'; kind = 'verify'; vars = $Ctx.Plan.variables } $script:ScriptPhaseSeconds
    $inv = Join-Path $Ctx.EvidenceDir 'job-inventory.json'
    $null = Invoke-AapProvider $Ctx.Provider 'ReceiveFile' @{ VmName = $vctx.Vm; User = $user; Password = $pw; GuestPath = 'D:\aap-verify\job-inventory.json'; HostPath = $inv; MaxBytes = $script:InventoryMaxBytes }
    $v = Assert-AapVerifyReply $r $inv
    $Ctx.Evidence.verify = $v
    $Ctx.State.clone_peak_bytes = [double](Invoke-AapProvider $Ctx.Provider 'MeasureBytes' @{ Path = $child })
    $Ctx.State.scratch_peak_bytes = [double](Invoke-AapProvider $Ctx.Provider 'MeasureBytes' @{ Path = $temp })
    $Ctx.State.mem_overhead_mib = [int](Invoke-AapProvider $Ctx.Provider 'GetVmMemoryOverheadMib' @{ VmName = $vctx.Vm })
    $null = Invoke-AapProvider $Ctx.Provider 'RemoveVm' @{ Name = $Ctx.Names.VerifyVm }
    Remove-AapTree $dir $Ctx.BuildDir
}

function Assert-AapVerifyReply($Reply, [string]$InventoryPath) {
    if ((Get-AapProp $Reply 'status') -cne 'ok') { throw "AAP_VerifyFailed: the fresh guest reported failure: $(Get-AapPrintable (Get-AapProp $Reply 'message'))" }   # check:verify-status
    $d = Get-AapProp $Reply 'data'
    $t = Get-AapProp $d 'upstream_tests'; $disc = Get-AapProp $d 'discovery'
    if ($null -eq $t -or $null -eq $disc) { throw 'AAP_HostileGuest: verify reply lacks upstream_tests or discovery' }
    foreach ($k in 'total', 'passed', 'failed', 'skipped') { if (-not ((Get-AapProp $t $k) -is [int] -or (Get-AapProp $t $k) -is [long])) { throw "AAP_HostileGuest: upstream_tests.$k" } }
    $need = @('vswhere', 'cl', 'link', 'clang_cl', 'lld_link', 'rc', 'msbuild', 'cmake', 'ninja', 'windows_sdk', 'hello_msvc', 'hello_clang_cl', 'resource_compile', 'job_user_admin')
    $missing = @($need | Where-Object { (Get-AapProp $disc $_) -ne $true })
    $sdk = [string](Get-AapProp $d 'sdk_version')
    if ($sdk -and $sdk -cnotmatch '^10\.0\.[0-9]{5}\.[0-9]{1,4}$') { throw 'AAP_HostileGuest: sdk_version' }
    if (-not (Test-Path -LiteralPath $InventoryPath) -or (New-Object IO.FileInfo $InventoryPath).Length -gt $script:InventoryMaxBytes) { throw 'AAP_VerifyFailed: job-inventory.json missing or oversized' }
    $invSha = Get-AapSha256File $InventoryPath
    if ([string](Get-AapProp $d 'inventory_sha256') -cne $invSha) { throw 'AAP_VerifyFailed: job-inventory.json does not match the hash the guest reported' }
    if ($t.total -lt 1 -or $t.failed -ne 0 -or $missing.Count) {   # check:verify
        throw "AAP_VerifyFailed: upstream tests $($t.passed)/$($t.total) passed, $($t.failed) failed; not discovered: $($missing -join ', ')"
    }
    return [ordered]@{ upstream_tests = [ordered]@{ total = $t.total; passed = $t.passed; failed = $t.failed; skipped = $t.skipped }; discovery = $need; sdk_version = $sdk; inventory_sha256 = $invSha; job_user = 'runneradmin' }
}

function New-AapWinGenerationRecord {
    <# One image-catalog (schema 2) generation entry, state candidate. P21 adds it to the catalog; P24 certifies it. #>
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)][string]$GenerationId, [Parameter(Mandatory)][long]$Bytes, [Parameter(Mandatory)][string]$Sha256,
        [Parameter(Mandatory)][string]$BuilderCommit, [Parameter(Mandatory)][string]$InputsManifestSha256, [Parameter(Mandatory)][string]$BuiltAt,
        [Parameter(Mandatory)][string]$SecretScanResult, [string]$SecretScanRef)
    [ordered]@{
        generation_id     = $GenerationId
        profile           = $script:Profile
        state             = 'candidate'
        state_changed_at  = $BuiltAt
        baseline          = [ordered]@{ runner_images_commit = $Plan.baseline.runner_images_commit; image_version = $Plan.baseline.image_version; inventory_path = $Plan.baseline.inventory_path; inventory_sha256 = $Plan.baseline.inventory_sha256 }
        artifacts         = @([ordered]@{ role = 'base_vhdx'; path = "$GenerationId/base.vhdx"; bytes = $Bytes; sha256 = $Sha256 })
        overlays          = @()
        provenance        = [ordered]@{ built_by_item = 'P06'; builder_commit = $BuilderCommit; inputs_manifest_sha256 = $InputsManifestSha256; built_at = $BuiltAt }
        secret_scan       = [ordered]@{ result = $SecretScanResult; evidence_ref = $SecretScanRef }
        certification     = [ordered]@{ certificate_ref = $null; certified_at = $null }
        approved_by       = $null
        retention         = [ordered]@{ owner = 'P21'; purpose = 'candidate'; expires_at = $null }
        quarantine_reason = $null
        live_activation   = $null
    }
}

function New-AapWinBudgetRecord {
    <# backend-lifecycle (schema 2) budget record from measured bytes. Caps are the peak x 1.25, rounded up. #>
    param([Parameter(Mandatory)][string]$GenerationId, [Parameter(Mandatory)][double]$BaseBytes, [Parameter(Mandatory)][double]$ClonePeakBytes,
        [Parameter(Mandatory)][double]$ScratchPeakBytes, [Parameter(Mandatory)][double]$StagingPeakBytes, [Parameter(Mandatory)][int]$MemOverheadMib,
        [Parameter(Mandatory)][string]$EvidenceRef, [Parameter(Mandatory)][string]$MeasuredAt)
    foreach ($b in $BaseBytes, $ClonePeakBytes, $StagingPeakBytes) { if ($b -le 0) { throw 'AAP_BudgetUnmeasured: a measured size is zero' } }   # check:budget-measured
    $g = { param($x) [int][Math]::Ceiling($x / $script:GiB) }
    $base = & $g $BaseBytes; $clone = [Math]::Max(1, (& $g $ClonePeakBytes)); $scratch = & $g $ScratchPeakBytes
    [ordered]@{
        schema = 2; kind = 'budget'; profile = 'windows'; image_generation = $GenerationId; measured = $true; evidence_ref = $EvidenceRef; measured_at = $MeasuredAt
        base_gib = $base; clone_peak_gib = $clone; clone_gib_max = [int][Math]::Ceiling($clone * $script:CapHeadroom)
        scratch_peak_gib = $scratch; scratch_gib_max = [int][Math]::Ceiling($scratch * $script:CapHeadroom)
        staging_gib = (& $g $StagingPeakBytes); replacement_gib = $base; rollback_retained_generations = 1; boot_mem_overhead_mib = $MemOverheadMib
    }
}

function Remove-AapWinBuild {
    <# Removes a build's VMs, mounts, build folder and, if this build began publishing and did not finish, its generation
       folder. Idempotent: everything absent counts as done. Never touches another generation or anything outside its folders. #>
    param([Parameter(Mandatory)]$Storage, [Parameter(Mandatory)]$Provider, [Parameter(Mandatory)]$Names)
    $buildDir = Join-Path (Join-Path $Storage.Staging.Path 'build') $Names.BuildId
    $state = $null
    $statePath = Join-Path $buildDir 'state.json'
    if (Test-Path -LiteralPath $statePath) { try { $state = Read-AapJson $statePath } catch { $state = $null } }
    foreach ($vm in $Names.BuildVm, $Names.VerifyVm) { $null = Invoke-AapProvider $Provider 'RemoveVm' @{ Name = $vm } }
    foreach ($d in 'os.vhdx', 'temp.vhdx', 'verify\os.avhdx', 'verify\temp.vhdx') {
        $f = Join-Path $buildDir $d
        if (Test-Path -LiteralPath $f) { $null = Invoke-AapProvider $Provider 'Dismount' @{ Vhdx = $f } }
    }
    $done = $null -ne $state -and (Get-AapProp $state 'status') -eq 'done'
    $publishing = $null -ne $state -and (Get-AapProp (Get-AapProp $state 'steps') 'publish') -eq 'intent'
    if ($publishing -and -not $done) {
        Remove-AapTree (Join-Path (Join-Path $Storage.Base.Path $script:Profile) $Names.Folder) $Storage.Base.Path
    }
    Remove-AapTree $buildDir $Storage.Staging.Path
}

function Invoke-AapWinImageBuild {
    <# Builds, scans, verifies, publishes and records one generation. Returns Ok, Status (built, unchanged, refused, failed),
       Reason, Detail, GenerationId and the record paths. A refusal before the build folder exists changes nothing; a failure
       after it removes the VMs, build disks and any partly published generation. #>
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Provider)
    $result = [ordered]@{ Ok = $false; Status = 'refused'; Reason = $null; Detail = $null; GenerationId = $null; RecordPath = $null; BudgetPath = $null; EvidencePath = $null; PartialCleaned = $false }
    $lock = $null; $started = $false; $published = $false; $ctx = $null; $storage = $null; $names = $null
    try {
        Assert-AapProvider $Provider
        Assert-AapWinConfig $Config
        $here = $PSScriptRoot
        $planPath = $(if (Get-AapProp $Config 'PlanPath') { $Config.PlanPath } else { Join-Path $here 'build-plan.json' })
        $manifestPath = $(if (Get-AapProp $Config 'ManifestPath') { $Config.ManifestPath } else { Join-Path $here '..\common\artifacts.manifest.json' })
        $storage = Read-AapStorageRecord -Path $Config.StoragePath
        Assert-AapStorageTrusted $storage $Provider
        $plan = Read-AapWinBuildPlan -Path $planPath
        $names = Get-AapWinNames $plan ([int]$Config.AapBuild)
        $result.GenerationId = $names.GenerationId
        $known = @(Get-AapWinBlockers -Plan $plan -ManifestPath $manifestPath)
        $waived = @(Get-AapProp $Config 'Waivers' | Where-Object { $_ })
        $unknownWaiver = @($waived | Where-Object { $known -cnotcontains $_ })
        if ($unknownWaiver.Count) { throw "AAP_ConfigInvalid: waiver for an unknown blocker: $($unknownWaiver -join ', ')" }
        $open = @($known | Where-Object { $waived -cnotcontains $_ })
        if ($open.Count) { throw "AAP_Blocked: unresolved input blockers: $($open -join ', ')" }   # check:blocked

        $evidenceDir = [IO.Path]::GetFullPath((Join-Path (Join-Path $Config.EvidenceRoot 'P06') $names.BuildId))
        $genParent = Join-Path $storage.Base.Path $script:Profile
        $genDir = Join-Path $genParent $names.Folder
        $recordPath = Join-Path $evidenceDir 'generation.json'
        $result.RecordPath = $recordPath; $result.BudgetPath = Join-Path $evidenceDir 'budget.json'; $result.EvidencePath = Join-Path $evidenceDir 'build.json'

        $buildRoot = Join-Path $storage.Staging.Path 'build'
        [void][IO.Directory]::CreateDirectory($buildRoot)
        if (Test-AapLink $buildRoot) { throw "AAP_UnsafeDelete: $buildRoot is a link" }
        try { $lock = [IO.File]::Open((Join-Path $buildRoot "$($names.BuildId).lock"), 'OpenOrCreate', 'ReadWrite', 'None') } catch { throw "AAP_BuildBusy: another builder holds $($names.BuildId)" }

        $buildDir = Join-Path $buildRoot $names.BuildId
        if (Test-Path -LiteralPath $buildDir) {
            Remove-AapWinBuild -Storage $storage -Provider $Provider -Names $names
            $result.PartialCleaned = $true
        }
        if (Test-Path -LiteralPath $genDir) {
            # Idempotent only for the very bytes this item recorded; anything else keeps its id and is never overwritten.
            $file = Join-Path $genDir 'base.vhdx'
            $same = (Test-Path -LiteralPath $recordPath) -and (Test-Path -LiteralPath $file) -and
                (Get-AapSha256File $file) -ceq [string]@((Read-AapJson $recordPath).artifacts)[0].sha256
            if (-not $same) { throw "AAP_GenerationExists: $($names.GenerationId) already exists with other bytes or no record; a rebuild takes a new aap.<n>" }   # check:generation-exists
            $null = Invoke-AapProvider $Provider 'SetReadOnlyAcl' @{ Path = $file }
            $null = Invoke-AapProvider $Provider 'SetReadOnlyAcl' @{ Path = $genDir }
            $result.Ok = $true; $result.Status = 'unchanged'
            return [pscustomobject]$result
        }

        Assert-AapBuildSpace $storage $Provider $plan ([int]$Config.StagingGibMax)
        $media = Join-Path (Join-Path $storage.Base.Path 'media') $Config.MediaFile
        if (-not (Test-Path -LiteralPath $media) -or (Get-AapSha256File $media) -cne $Config.MediaSha256) { throw "AAP_MediaMismatch: $($Config.MediaFile) is missing or its SHA-256 differs from the pinned value" }   # check:media
        $inputs = Invoke-AapProvider $Provider 'VerifyInputs' @{ StagingRoot = $storage.Staging.Path; Names = @($Config.SourceEntry) + @(Get-AapProp $Config 'Inputs' | Where-Object { $_ }) }
        if (-not $inputs.Complete) { throw "AAP_InputsUnverified: P03 offline verification did not accept every input: $(Get-AapPrintable ([string]$inputs.Detail) 300)" }   # check:inputs
        $source = [string]$inputs.Paths[[string]$Config.SourceEntry]
        if (-not $source -or -not (Test-Path -LiteralPath $source)) { throw 'AAP_InputsUnverified: the upstream source archive is not staged' }

        # From here on a failure cleans up what it made.
        [void][IO.Directory]::CreateDirectory($buildDir)
        [void][IO.Directory]::CreateDirectory($evidenceDir)
        $started = $true
        $pw = New-AapWinPassword
        $ctx = [pscustomobject]@{
            Config = $Config; Provider = $Provider; Plan = $plan; Names = $names; BuildDir = $buildDir; EvidenceDir = $evidenceDir
            StatePath = (Join-Path $buildDir 'state.json'); OsDisk = (Join-Path $buildDir 'os.vhdx'); TempDisk = (Join-Path $buildDir 'temp.vhdx')
            Vm = $names.BuildVm; User = [string]$plan.variables.install_user; Password = $pw; GuestScript = 'C:\aap-build\AapGuestRunner.ps1'
            SourceArchive = $source; VerifyScript = (Join-Path $here 'guest\AapGuestVerify.ps1')
            ProbeScript = $(if (Get-AapProp $Config 'ProbeScript') { $Config.ProbeScript } else { Join-Path $here '..\..\tools\parity-certify\probe\windows.ps1' })
            HelloC = $(if (Get-AapProp $Config 'HelloC') { $Config.HelloC } else { Join-Path $here '..\..\tools\parity-certify\workloads\fixtures\hello.c' })
            State = [ordered]@{ schema = 1; build_id = $names.BuildId; generation_id = $names.GenerationId; status = 'running'; started_at = (Get-AapUtc); steps = [ordered]@{}
                staging_peak_bytes = [double]0; clone_peak_bytes = [double]0; scratch_peak_bytes = [double]0; mem_overhead_mib = 0 }
            Evidence = [ordered]@{ schema = 1; item = 'P06'; build_id = $names.BuildId; generation_id = $names.GenerationId; builder_commit = $Config.BuilderCommit
                plan_sha256 = (Get-AapSha256File $planPath); template_sha256 = $plan.baseline.template_sha256; media = [ordered]@{ file = $Config.MediaFile; sha256 = $Config.MediaSha256; edition = $Config.Edition }
                waived_blockers = $waived; phases = (New-Object System.Collections.Generic.List[object]); reports = [ordered]@{}; verify = $null }
        }
        Save-AapState $ctx

        Set-AapStep $ctx 'disks' 'intent'
        $null = Invoke-AapProvider $Provider 'NewBuildDisk' @{ Path = $ctx.OsDisk; SizeGib = [int]$plan.os_disk_gib; Format = $false }
        $null = Invoke-AapProvider $Provider 'NewBuildDisk' @{ Path = $ctx.TempDisk; SizeGib = [int]$plan.temp_disk_gib; Format = $true }
        $applied = Invoke-AapProvider $Provider 'ApplyWindowsImage' @{ IsoPath = $media; Edition = $Config.Edition; Vhdx = $ctx.OsDisk
            Files = @{ 'Windows\Panther\unattend.xml' = (New-AapWinUnattend -UserName $ctx.User -Password $pw) }
            CopyFiles = @{ 'aap-build\AapGuestRunner.ps1' = (Join-Path $here 'guest\AapGuestRunner.ps1') } }
        $ctx.Evidence.media.image_index = [int]$applied.ImageIndex
        $ctx.Evidence.media.os_build = Get-AapPrintable ([string]$applied.Build) 40
        Set-AapStep $ctx 'disks' 'done'

        Set-AapStep $ctx 'vm' 'intent'
        $null = Invoke-AapProvider $Provider 'NewVm' @{ Name = $ctx.Vm; Path = $buildDir; OsDisk = $ctx.OsDisk; TempDisk = $ctx.TempDisk; Cpus = [int]$Config.BuildCpus; MemGib = [int]$Config.BuildMemGib; SwitchName = (Get-AapProp $Config 'SwitchName') }
        $null = Invoke-AapProvider $Provider 'StartVm' @{ VmName = $ctx.Vm }
        if (-not (Invoke-AapProvider $Provider 'WaitGuestReady' @{ VmName = $ctx.Vm; User = $ctx.User; Password = $pw; TimeoutSeconds = 1800 })) { throw 'AAP_RebootTimeout: build guest not ready after first boot' }
        $ctx.State.installed_at = Get-AapUtc
        Set-AapStep $ctx 'vm' 'done'

        foreach ($p in @($plan.phases)) {
            Set-AapStep $ctx $p.id 'intent'
            Invoke-AapPhase $ctx $p
            Assert-AapStagingBudget $ctx
            Set-AapStep $ctx $p.id 'done'
        }

        Set-AapStep $ctx 'seal' 'intent'
        $null = Invoke-AapProvider $Provider 'StopVm' @{ VmName = $ctx.Vm; TimeoutSeconds = 1800 }
        $null = Invoke-AapProvider $Provider 'RemoveVm' @{ Name = $ctx.Vm }
        $null = Invoke-AapProvider $Provider 'Dismount' @{ Vhdx = $ctx.TempDisk }
        Remove-AapTree $ctx.TempDisk $buildDir
        $null = Invoke-AapProvider $Provider 'OptimizeDisk' @{ Vhdx = $ctx.OsDisk }
        Assert-AapStagingBudget $ctx
        $sealedSha = Get-AapSha256File $ctx.OsDisk
        $sealedBytes = [long](Invoke-AapProvider $Provider 'MeasureBytes' @{ Path = $ctx.OsDisk })
        Set-AapStep $ctx 'seal' 'done'

        Set-AapStep $ctx 'scan' 'intent'
        $mount = Invoke-AapProvider $Provider 'MountReadOnly' @{ Vhdx = $ctx.OsDisk }
        try { $scan = Invoke-AapWinSecretScan -MountRoot $mount -Provider $Provider -KnownSecret @($pw) } finally { $null = Invoke-AapProvider $Provider 'Dismount' @{ Vhdx = $ctx.OsDisk } }
        Write-AapJson $scan (Join-Path $evidenceDir 'secret-scan.json')
        if ($scan.result -cne 'clean') { throw "AAP_SecretFound: secret scan result $($scan.result): $(@($scan.findings | ForEach-Object { "$($_.rule) $($_.path)" } | Select-Object -First 5) -join '; ')" }   # check:secret-found
        Set-AapStep $ctx 'scan' 'done'

        Set-AapStep $ctx 'verify' 'intent'
        Invoke-AapVerify $ctx
        if ((Get-AapSha256File $ctx.OsDisk) -cne $sealedSha) { throw 'AAP_BaseChanged: the sealed disk changed during verification' }   # check:base-changed
        Set-AapStep $ctx 'verify' 'done'

        $builtAt = Get-AapUtc
        $ref = "evidence/P06/$($names.BuildId)"
        $manifestSha = Get-AapSha256File $manifestPath
        $record = New-AapWinGenerationRecord -Plan $plan -GenerationId $names.GenerationId -Bytes $sealedBytes -Sha256 $sealedSha -BuilderCommit $Config.BuilderCommit `
            -InputsManifestSha256 $manifestSha -BuiltAt $builtAt -SecretScanResult 'clean' -SecretScanRef "$ref/secret-scan.json"
        $budget = New-AapWinBudgetRecord -GenerationId $names.GenerationId -BaseBytes $sealedBytes -ClonePeakBytes $ctx.State.clone_peak_bytes -ScratchPeakBytes $ctx.State.scratch_peak_bytes `
            -StagingPeakBytes $ctx.State.staging_peak_bytes -MemOverheadMib $ctx.State.mem_overhead_mib -EvidenceRef "$ref/build.json" -MeasuredAt $builtAt
        # The measured budget must fit the owner-approved one (contracts README, Resolved 2026-10-20, item 4).
        if ($budget.base_gib -gt [int]$Config.BaseGibMax -or ($budget.clone_gib_max + $budget.scratch_gib_max) -gt [int]$Config.JobDiskGibMax) {   # check:budget-approved
            throw "AAP_BudgetExceeded: measured base $($budget.base_gib) GiB and clone+scratch caps $($budget.clone_gib_max + $budget.scratch_gib_max) GiB exceed the approved $($Config.BaseGibMax) and $($Config.JobDiskGibMax) GiB"
        }
        $installed = [DateTime]::Parse($ctx.State.installed_at, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]'AssumeUniversal, AdjustToUniversal')
        $ctx.Evidence.evaluation = [ordered]@{ media = 'Windows Server 2025 Evaluation'; installed_at = $ctx.State.installed_at; days = $script:EvaluationDays
            expires_at = (Get-AapUtc $installed.AddDays($script:EvaluationDays)); rebuild_by = (Get-AapUtc $installed.AddDays($script:EvaluationDays - $script:RebuildLeadDays)) }
        $ctx.Evidence.measured = [ordered]@{ base_bytes = $sealedBytes; staging_peak_bytes = $ctx.State.staging_peak_bytes; clone_peak_bytes = $ctx.State.clone_peak_bytes; scratch_peak_bytes = $ctx.State.scratch_peak_bytes; mem_overhead_mib = $ctx.State.mem_overhead_mib }
        $ctx.Evidence.base_sha256 = $sealedSha

        Set-AapStep $ctx 'publish' 'intent'
        if (-not (Test-Path -LiteralPath $genParent)) { [void][IO.Directory]::CreateDirectory($genParent) }
        if (Test-AapLink $genParent) { throw "AAP_UnsafeDelete: $genParent is a link" }
        if (Test-Path -LiteralPath $genDir) { throw "AAP_GenerationExists: $genDir appeared during the build" }
        [void][IO.Directory]::CreateDirectory($genDir)
        $partial = Join-Path $genDir 'base.vhdx.partial'
        [IO.File]::Copy($ctx.OsDisk, $partial, $false)
        if ((Get-AapSha256File $partial) -cne $sealedSha) { throw 'AAP_PublishMismatch: the published copy differs from the sealed disk' }   # check:publish-hash
        [IO.File]::Move($partial, (Join-Path $genDir 'base.vhdx'))
        Write-AapJson $ctx.Evidence $result.EvidencePath
        Write-AapJson $budget $result.BudgetPath
        Write-AapJson $record $recordPath
        $null = Invoke-AapProvider $Provider 'SetReadOnlyAcl' @{ Path = (Join-Path $genDir 'base.vhdx') }
        $null = Invoke-AapProvider $Provider 'SetReadOnlyAcl' @{ Path = $genDir }
        $ctx.State.status = 'done'
        Set-AapStep $ctx 'publish' 'done'
        $published = $true
        $result.Ok = $true; $result.Status = 'built'
        try { Remove-AapTree $buildDir $storage.Staging.Path } catch { $result.Detail = Get-AapPrintable "published; build folder not removed: $($_.Exception.Message)" 500 }
    } catch {
        $msg = [string]$_.Exception.Message
        if ($msg -match '^(AAP_[A-Za-z]+): ?(.*)$') { $result.Reason = $Matches[1]; $result.Detail = Get-AapPrintable $Matches[2] 500 } else { $result.Reason = 'AAP_Unexpected'; $result.Detail = Get-AapPrintable $msg 500 }
        if ($started -and -not $published) {
            $result.Status = 'failed'
            if ($ctx) { try { $ctx.State.status = 'failed'; Save-AapState $ctx } catch { $null = $_ } }
            try { Remove-AapWinBuild -Storage $storage -Provider $Provider -Names $names } catch { $result.Detail = Get-AapPrintable "$($result.Detail); cleanup failed: $($_.Exception.Message)" 500 }
            foreach ($f in $result.RecordPath, $result.BudgetPath, $result.EvidencePath) { if ($f -and (Test-Path -LiteralPath $f)) { [IO.File]::Delete($f) } }
        }
    } finally {
        if ($lock) { $lock.Dispose() }
    }
    return [pscustomobject]$result
}

Export-ModuleMember -Function Read-AapStorageRecord, Read-AapWinBuildPlan, Get-AapWinBlockers, New-AapWinPassword, New-AapWinUnattend, ConvertFrom-AapGuestReply,
    Invoke-AapWinSecretScan, New-AapWinGenerationRecord, New-AapWinBudgetRecord, Remove-AapWinBuild, Invoke-AapWinImageBuild, Remove-AapTree, Get-AapWinNames
