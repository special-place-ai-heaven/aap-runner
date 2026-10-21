# P07: builds the Ubuntu 24.04 golden image. Windows PowerShell 5.1 and PowerShell 7.
# Every Hyper-V, disk, seed-image, guest-channel, ACL and comparison call goes through the provider (a hashtable of
# scriptblocks, AapUbuntuImage.HyperV.psm1 in production, fakes in tests). This module itself does filesystem work inside
# the build and evidence folders only, and never touches the network: inputs come from P03 staging, verified by the provider.
# The build VM's network is the P10.0 host network module's (parity/contracts/host-network-module.md), taken as -Network:
# Attach, the shared declaration check, Verify and Hyper-V's read-back through the shared check before every start, the
# declaration written into the build seed as static addressing, and Detach after the VM is removed.
# The build, scan and verification guests run (or read) what internet-sourced installers produced and are treated as
# hostile: every reply is size-capped while received and validated, files received from a guest land in the build folder
# first, and no host path is ever resolved through guest-authored file system metadata. The host never mounts a guest file
# system: files go in on host-built seed images (cloud-init NoCloud), results come back only over the capped hvsocket
# channel, and the secret scan of the sealed disk runs inside a scanner guest booted from the pinned installation media.
# Every refusal throws 'AAP_<Reason>: <detail>'. Lines tagged '# check:<name>' are the safety checks the mutation run
# disables one at a time (tests/images/ubuntu-24.04/Invoke-AapUbuntuMutations.ps1).

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
# The path walk, safe deletion, read-only ACL and storage-record helpers are P06's, imported rather than copied:
# Read-AapStorageRecord, Get-AapPathKind, Assert-AapPlainPath, Remove-AapTree, Set-AapReadOnlyAcl. Smaller helpers below
# (JSON, hashing, printable text, provider calls, storage trust and space, state and evidence) are verbatim copies of P06's;
# INTEGRATION.md (Dependency on P06) lists them.
Import-Module (Join-Path $PSScriptRoot '..\windows\AapWinImage.psm1')

$script:Profile = 'ubuntu-24.04-x64'
$script:GiB = 1073741824
$script:Utf8 = New-Object Text.UTF8Encoding($false)
$script:ProviderOps = @('TestRootTrust', 'ExecFolders', 'GetVolume', 'MeasureBytes', 'VerifyInputs', 'NewBuildDisk', 'NewDiffDisk', 'NewSeedImage', 'GetSwitch', 'NewVm',
    'SetSeed', 'GetVmConfig', 'GetVmNetwork', 'AttachDisk', 'StartVm', 'TypeBootCommand', 'WaitVmOff', 'RemoveDvds', 'StopVm', 'RemoveVm', 'WaitGuestReady', 'InvokeGuest', 'ReceiveFile', 'OptimizeDisk',
    'SetReadOnlyAcl', 'GetVmMemoryOverheadMib', 'CompareInventory')
# Repository files the builder reads. Not configurable: a caller cannot point the builder at another plan, manifest, guest
# payload or comparison reference (tests replace them in module scope).
$script:RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$script:PlanPath = Join-Path $PSScriptRoot 'build-plan.json'
$script:ManifestPath = Join-Path $PSScriptRoot '..\common\artifacts.manifest.json'
$script:AllowlistPath = Join-Path $PSScriptRoot 'secret-allowlist.json'
$script:GuestDir = Join-Path $PSScriptRoot 'guest'
$script:ProbeScript = Join-Path $PSScriptRoot '..\..\tools\parity-certify\probe\linux.sh'
$script:HelloC = Join-Path $PSScriptRoot '..\..\tools\parity-certify\workloads\fixtures\hello.c'
$script:NetworkOps = @('Attach', 'Detach', 'Verify')
# A running build VM is verified again before the next phase once this long has passed since the last check (contract,
# Consumer obligations 3: at most every minute, at phase granularity here).
$script:NetVerifyMinutes = 1
# The shared check of host-network-module.md, loaded only once the builder's trust check passed for its folder.
$script:NetCheckPath = Join-Path $PSScriptRoot '..\..\supervisor\network\AapHostNetworkCheck.psm1'
$script:MediaName = '^ubuntu-24\.04(\.[0-9]+)?-live-server-amd64\.iso\z'   # Ubuntu 24.04 only; never 26.04
$script:PollSeconds = 15
$script:Actions = @('make-image-folder', 'upload-helpers', 'upload-build-scripts', 'upload-image-folder', 'upload-report-base', 'upload-toolset',
    'layout-image-folder', 'software-report-and-tests', 'download-software-report-md', 'download-software-report-json', 'deprovision')
$script:SealRules = @('install-user-absent', 'no-password-hash', 'no-authorized-keys', 'no-ssh-host-keys', 'no-agent', 'no-cloud-state', 'no-build-sudoers', 'no-build-network')
$script:ScanRules = @('runner-credentials', 'runner-config', 'ssh-host-key', 'ssh-authorized-keys', 'shell-history', 'app-key', 'cloud-init-seed',
    'installer-answers', 'azure-provisioning-data', 'shadow-password-hash', 'pem-private-key', 'github-token', 'github-pat', 'jit-config',
    'synthetic-marker', 'build-credential', 'build-agent', 'build-sudoers')
# Findings no allowlist entry can cover: the build's own credential and agent.
$script:NeverAllowed = @('build-credential', 'build-agent')
$script:Discovery = @('gcc', 'gxx', 'clang', 'cmake', 'ninja', 'make', 'pkg_config', 'hello_gcc', 'hello_clang', 'pwsh', 'python3', 'docker_daemon',
    'sudo_nopasswd', 'systemd_pid1', 'kernel_azure', 'job_user', 'post_generation')
$script:ScriptPhaseSeconds = 6 * 3600
$script:ActionSeconds = 3 * 3600
$script:ReadySeconds = 1800
$script:ShortCallSeconds = 45
$script:ReplyMaxBytes = 65536
$script:ReportMaxBytes = 16MB
$script:InventoryMaxBytes = 4MB
$script:ScanMaxBytes = 4MB
$script:CompareMaxBytes = 4MB
$script:SendMaxBytes = 1GB
$script:ListMax = 200
$script:LargeFilesMax = 10000
$script:CapHeadroom = 1.25              # cap = measured peak x 1.25, rounded up (backend-lifecycle: cap >= peak)
# The VM worker's memory is measured on the host but grows with what the guest does; a reading above this is refused, not
# recorded (Hyper-V's own overhead for a 10 GiB guest is a few hundred MiB).
$script:MemOverheadMibMax = 1024
# The owner-approved lab ceilings (contracts README, Resolved 2026-10-20): a config may ask for less, never more.
$script:OwnerLimits = [ordered]@{ BuildCpus = 4; BuildMemGib = 10; BaseGibMax = 186; JobDiskGibMax = 55 }
$script:Uuid = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z'
$script:Safe = '^[A-Za-z0-9_./:+-]{0,200}\z'   # every value that reaches the guest request or the seed

function Get-AapUtc([DateTime]$Time = [DateTime]::UtcNow) { $Time.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture) }
function Get-AapProp($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    if ($Object -is [Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] } else { return $null } }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value } else { return $null }
}
function Get-AapNames($Object) { @($Object.PSObject.Properties | ForEach-Object { $_.Name }) }
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
function Test-AapInt($Value, [long]$Min = 0) { ($Value -is [int] -or $Value -is [long]) -and $Value -ge $Min }

# The per-guest channel credential: 64 random hex characters. They become a PowerShell string only inside this class and
# while the seed text is assembled, never as a command parameter (PowerShell module logging, event 4103, records those) or
# in a log or record; the object prints as '[aap token]' and the provider writes its bytes into the channel with WriteTo.
class AapToken {
    hidden [byte[]]$Bytes
    [int]$Length
    AapToken() {
        $raw = New-Object byte[] 32
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($raw) } finally { $rng.Dispose() }
        $this.Bytes = [Text.Encoding]::ASCII.GetBytes(([BitConverter]::ToString($raw) -replace '-', '').ToLowerInvariant())
        $this.Length = $this.Bytes.Length
    }
    [void] WriteTo([IO.Stream]$Stream) { $Stream.Write($this.Bytes, 0, $this.Bytes.Length) }
    [string] ToString() { return '[aap token]' }
}

function Assert-AapProvider($Provider) {
    if (-not ($Provider -is [Collections.IDictionary])) { throw 'AAP_ProviderInvalid: the provider must be a hashtable of scriptblocks' }
    $missing = @($script:ProviderOps | Where-Object { -not ($Provider[$_] -is [scriptblock]) })
    if ($missing.Count) { throw "AAP_ProviderInvalid: missing $($missing -join ', ')" }
}

# ---------------------------------------------------------------------------------------------------------------------
# Storage (backend-lifecycle.md revision 2, Storage tiers): the record is read by P06's Read-AapStorageRecord.

# The builder writes to base_root, the staging root and the evidence root, and trusts the storage document's folder.
# Each must pass the ProgramData rules (owner, admin-only protected DACL, reparse, ancestors, fixed drive); the storage
# roots must also sit on their recorded volumes.
function Assert-AapStorageTrusted($Storage, $Provider, [string]$EvidenceRoot) {
    $checks = @(
        [pscustomobject]@{ Name = 'storage document folder'; Path = (Split-Path -Parent $Storage.Path); Guid = $null },
        [pscustomobject]@{ Name = 'base_root'; Path = $Storage.Base.Path; Guid = $Storage.Base.VolumeGuid },
        [pscustomobject]@{ Name = 'staging root'; Path = $Storage.Staging.Path; Guid = $Storage.Staging.VolumeGuid },
        [pscustomobject]@{ Name = 'evidence root'; Path = $EvidenceRoot; Guid = $null })
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

function Read-AapUbuntuBuildPlan {
    <# build-plan.json, shape-checked. Every script must carry a pinned SHA-256 (AAP_ScriptUnpinned otherwise). #>
    param([Parameter(Mandatory)][string]$Path)
    $plan = Read-AapJson $Path
    if ($plan.schema -ne 1 -or $plan.profile -cne $script:Profile -or [string]$plan.variables.image_os -cne 'ubuntu24') { throw 'AAP_PlanInvalid: not a schema 1 plan for ubuntu-24.04-x64' }
    if ([int]$plan.os_disk_gib -lt 1) { throw 'AAP_PlanInvalid: os_disk_gib' }
    # The version names folders, VMs and the generation id.
    if ([string]$plan.baseline.image_version -cnotmatch '^[0-9]{8}\.[0-9]+\.[0-9]+\z') { throw 'AAP_PlanInvalid: baseline.image_version' }   # check:plan-version
    foreach ($v in $plan.variables.PSObject.Properties) { if ([string]$v.Value -cnotmatch $script:Safe) { throw "AAP_PlanInvalid: variable $($v.Name)" } }   # check:request-value
    $ref = Join-Path $script:RepoRoot ([string]$plan.verify.reference_path -replace '/', '\')
    if ((Get-AapPathKind $ref) -ne 'file' -or (Get-AapSha256File $ref) -cne [string]$plan.verify.reference_sha256) { throw 'AAP_PlanInvalid: the comparison reference does not match its pinned SHA-256' }   # check:plan-reference
    # Missing-required fails the build only in the sections the image owns. The runner (image.runner_version, runner_os,
    # runner_arch), the job's identity and the Azure fabric are no part of it, and a verification guest has none of them.
    $foreign = @('image', 'infra', 'run_identity', 'credential_env')
    $owned = @(Get-AapProp (Get-AapProp $plan 'verify') 'required_sections' | Where-Object { $_ })
    if ($owned.Count -eq 0 -or @($owned | Where-Object { $foreign -ccontains [string]$_ }).Count) { throw "AAP_PlanInvalid: verify.required_sections must name the sections the image owns and none of $($foreign -join ', ')" }   # check:plan-required
    # The upstream source archive and the installation media are P03 entries pinned here by name and SHA-256, so plan_sha256
    # covers them. Until one is pinned, its blocker must be in the plan and must not be waivable.
    foreach ($k in @(@{ Key = 'source'; Blocker = 'p07-upstream-source-archive' }, @{ Key = 'media'; Blocker = 'p07-ubuntu-server-media' })) {
        $e = Get-AapProp (Get-AapProp $plan 'inputs') $k.Key
        $entry = Get-AapProp $e 'entry'; $sha = Get-AapProp $e 'sha256'
        $blocker = @($plan.blockers | Where-Object { [string]$_.id -ceq $k.Blocker -and $_.waivable -eq $false })
        $pinned = [string]$entry -cmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,79}\z' -and [string]$sha -cmatch '^[0-9a-f]{64}\z'
        if (-not $pinned -and ($null -ne $entry -or $null -ne $sha -or $blocker.Count -ne 1)) { throw "AAP_PlanInvalid: inputs.$($k.Key) is neither pinned by entry and SHA-256 nor blocked by an unwaivable $($k.Blocker)" }   # check:plan-inputs
    }
    foreach ($b in @($plan.blockers)) { if (-not ($b.waivable -is [bool])) { throw "AAP_PlanInvalid: blocker $($b.id) has no waivable flag" } }
    $i = 0
    foreach ($p in @($plan.phases)) {
        $i++
        if ($p.id -cne ('p{0:d2}' -f $i)) { throw "AAP_PlanInvalid: phase $i has id $($p.id)" }
        switch ($p.kind) {
            'scripts' {
                if (@('root', 'root-pwsh', 'user') -cnotcontains [string]$p.exec) { throw "AAP_PlanInvalid: $($p.id) runs as $($p.exec)" }   # check:plan-exec
                foreach ($s in @($p.scripts)) {
                    if ($s.name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,79}\.(sh|ps1)\z') { throw "AAP_PlanInvalid: $($p.id) script name $($s.name)" }
                    if ([string]$s.sha256 -cnotmatch '^[0-9a-f]{64}\z') { throw "AAP_ScriptUnpinned: $($p.id) $($s.name) has no pinned SHA-256 (rerun New-AapUbuntuBuildPlan.ps1 -ScriptsDir on the P03-staged archive)" }   # check:plan-unpinned
                }
            }
            'action' { if ($script:Actions -cnotcontains $p.action) { throw "AAP_PlanInvalid: $($p.id) unknown action $($p.action)" } }
            'restart' { }
            default { throw "AAP_PlanInvalid: $($p.id) unknown kind $($p.kind)" }
        }
    }
    $last = @($plan.phases)[-1]
    if ($last.kind -cne 'action' -or $last.action -cne 'deprovision') { throw 'AAP_PlanInvalid: the last phase must be deprovision' }
    return $plan
}

function Get-AapUbuntuBlockers {
    <# Ids of every input blocker for this profile: the P03 manifest's not_reproducible entries plus the plan's own. #>
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)][string]$ManifestPath)
    $m = Read-AapJson $ManifestPath
    $ids = @($m.not_reproducible | Where-Object { @($_.profiles) -contains $script:Profile } | ForEach-Object { [string]$_.id })
    return @($ids + @($Plan.blockers | ForEach-Object { [string]$_.id }))
}

function Get-AapUbuntuWaivers($Config, [string[]]$Known, [string]$PlanSha, [string[]]$Unwaivable = @()) {
    <# Chair-approved waivers of input blockers. Each is an approval record with exactly id, rationale, plan_sha256 and
       approver, valid only for the build plan it names; a bare id is refused, and so is a waiver of a blocker the plan marks
       unwaivable (the source archive and the media: without them there is nothing verified to build from). #>
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($wv in @(Get-AapProp $Config 'Waivers' | Where-Object { $null -ne $_ })) {
        $names = $(if ($wv -is [Collections.IDictionary]) { @($wv.Keys | ForEach-Object { [string]$_ }) } elseif ($wv -is [Management.Automation.PSCustomObject]) { Get-AapNames $wv } else { @() })
        if ((@($names | Sort-Object) -join ',') -cne 'approver,id,plan_sha256,rationale' -or [string](Get-AapProp $wv 'rationale') -cnotmatch '^[\x20-\x7e]{10,1000}\z' -or [string](Get-AapProp $wv 'approver') -cnotmatch '^[\x20-\x7e]{1,100}\z') {
            throw 'AAP_ConfigInvalid: a waiver is an approval record with exactly id, rationale, plan_sha256 and approver'
        }
        $id = [string](Get-AapProp $wv 'id')
        if ($Known -cnotcontains $id) { throw "AAP_ConfigInvalid: waiver for an unknown blocker: $(Get-AapPrintable $id 80)" }
        if ($Unwaivable -ccontains $id) { throw "AAP_ConfigInvalid: $id cannot be waived; it is resolved only by pinning the input in the plan" }   # check:waiver-unwaivable
        if ([string](Get-AapProp $wv 'plan_sha256') -cne $PlanSha) { throw "AAP_ConfigInvalid: the waiver for $id was approved for another build plan" }   # check:waiver
        $out.Add([ordered]@{ id = $id; rationale = [string]$wv.rationale; plan_sha256 = $PlanSha; approver = [string]$wv.approver })
    }
    return $out.ToArray()
}

function Assert-AapUbuntuConfig($Config) {
    foreach ($k in 'StoragePath', 'EvidenceRoot', 'AapBuild', 'BuildCpus', 'BuildMemGib', 'StagingGibMax', 'BaseGibMax', 'JobDiskGibMax', 'BuilderCommit') {
        if ($null -eq (Get-AapProp $Config $k) -or [string](Get-AapProp $Config $k) -eq '') { throw "AAP_ConfigInvalid: $k is required" }
    }
    # Numbers are parsed, never cast: casting 'four' would throw outside the builder's refusals.
    $n = 0
    foreach ($k in 'AapBuild', 'StagingGibMax') {
        if (-not [int]::TryParse([string](Get-AapProp $Config $k), [ref]$n) -or $n -lt 1) { throw "AAP_ConfigInvalid: $k must be a whole number of at least 1" }   # check:config-number
    }
    if ([string]$Config.BuilderCommit -cnotmatch '^[0-9a-f]{40}\z') { throw 'AAP_ConfigInvalid: BuilderCommit' }
    foreach ($k in @($script:OwnerLimits.Keys)) {
        if (-not [int]::TryParse([string](Get-AapProp $Config $k), [ref]$n) -or $n -lt 1 -or $n -gt $script:OwnerLimits[$k]) { throw "AAP_ConfigInvalid: $k must be 1 to $($script:OwnerLimits[$k]), the owner-approved lab ceiling" }   # check:owner-limits
    }
}

function Get-AapUbuntuNames($Plan, [int]$AapBuild) {
    $gen = "$($script:Profile)/$($Plan.baseline.image_version)-aap.$AapBuild"
    $id = $gen.Replace('/', '_')
    $tag = (Get-AapSha256Text $id).Substring(0, 8)
    return [pscustomobject]@{ GenerationId = $gen; BuildId = $id; Folder = "$($Plan.baseline.image_version)-aap.$AapBuild"; Tag = $tag
        BuildVm = "aap-lbuild-$tag"; ScanVm = "aap-lscan-$tag"; VerifyVm = "aap-lverify-$tag" }
}

# ---------------------------------------------------------------------------------------------------------------------
# Seed images and requests. Everything a guest receives is host-authored here and written onto a new seed image.

function ConvertTo-AapYamlIndent([string]$Text, [int]$Indent) {
    $pad = ' ' * $Indent
    $lines = $Text.Replace("`r`n", "`n").TrimEnd("`n").Split("`n")
    return (@($lines | ForEach-Object { if ($_ -eq '') { '' } else { $pad + $_ } }) -join "`n")
}

function New-AapUbuntuSeed {
    <# The cloud-init NoCloud seed (files user-data and meta-data) for one guest, and the new guest's channel token (an
       AapToken, made here so it is never a parameter). build: the unattended install (autoinstall) of the live-server ISO,
       whose installed system gets the install user (no password, key or login) and the agent, and its network is the static
       addressing of -Network, the host network module's declaration (no DHCP). verify: the job user and the
       agent for a fresh guest of the sealed image, after the first-boot step every clone gets (P15). scan: the agent for the
       live system that scans the sealed disk, and in /var/lib/aap-build/known the build guest's token (-Known) to look for.
       The agent listens on hvsocket only; no guest gets a password, an SSH key or a host share. Returns Files (user-data,
       meta-data) and Token. #>
    param([Parameter(Mandatory)][ValidateSet('build', 'verify', 'scan')][string]$Mode, [Parameter(Mandatory)]$Plan, [Parameter(Mandatory)][string]$InstanceId, $Known, $Network)
    if ($InstanceId -cnotmatch '^[a-z0-9-]{1,64}\z' -or (($Mode -eq 'scan') -ne ($Known -is [AapToken])) -or (($Mode -eq 'build') -ne ($null -ne $Network))) { throw 'AAP_SeedInvalid: instance id, a known token for anything but the scanner, or a network for anything but the build' }   # check:seed-values
    $token = [AapToken]::new()
    $agent = [IO.File]::ReadAllText((Join-Path $script:GuestDir 'aap-agent.sh')).Replace("`r`n", "`n")
    if ($agent -match '[^\x0a\x20-\x7e]') { throw 'AAP_SeedInvalid: the agent must be printable ASCII without tabs' }
    $port = [int]$Plan.channel.vsock_port
    $hostName = "aap-$Mode"
    $users = ''
    if ($Mode -eq 'build') {
        $users = "users:`n  - name: $($Plan.variables.install_user)`n    uid: 1000`n    shell: /bin/bash`n    lock_passwd: true`n    sudo: 'ALL=(ALL) NOPASSWD:ALL'`n"
    } elseif ($Mode -eq 'verify') {
        $j = $Plan.job_user
        $users = "users:`n  - name: $($j.name)`n    uid: $([int]$j.uid)`n    groups: [$(@($j.groups) -join ', ')]`n    shell: /bin/bash`n    lock_passwd: true`n    sudo: 'ALL=(ALL) NOPASSWD:ALL'`n"
    }
    $knownFile = $(if ($Mode -eq 'scan') { "  - path: /var/lib/aap-build/known`n    owner: root:root`n    permissions: '0600'`n    content: '@@AAP_KNOWN@@'`n" } else { '' })
    # A clone's first boot, before the agent answers: a new snakeoil TLS pair (the seal deleted the image's), which
    # PostgreSQL's ssl = on needs to start. The verification checks the image as a clone first boots it.
    $firstBoot = $(if ($Mode -eq 'verify') { "  - [make-ssl-cert, generate-default-snakeoil, --force-overwrite]`n" } else { '' })
    $config = @"
hostname: $hostName
$($users)write_files:
  - path: /var/lib/aap-build/token
    owner: root:root
    permissions: '0600'
    content: '@@AAP_TOKEN@@'
$($knownFile)  - path: /usr/local/libexec/aap-build/agent
    owner: root:root
    permissions: '0755'
    content: |
$(ConvertTo-AapYamlIndent $agent 6)
  - path: /etc/systemd/system/aap-agent.socket
    permissions: '0644'
    content: |
      [Unit]
      Description=AAP image agent on hvsocket port $port
      [Socket]
      ListenStream=vsock::$port
      Accept=yes
      [Install]
      WantedBy=sockets.target
  - path: /etc/systemd/system/aap-agent@.service
    permissions: '0644'
    content: |
      [Unit]
      Description=AAP image agent connection
      [Service]
      ExecStart=/usr/local/libexec/aap-build/agent
      StandardInput=socket
      StandardOutput=socket
      StandardError=journal
runcmd:
$($firstBoot)  - [systemctl, daemon-reload]
  - [systemctl, enable, --now, aap-agent.socket]
"@
    if ($Mode -ne 'build') { $userData = "#cloud-config`n" + $config.Replace("`r`n", "`n") + "`n" }
    else {
        $b = $Plan.base
        # The declaration's values, checked again where they enter YAML: dotted IPv4 addresses and a prefix length only.
        $ip = '^(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])(\.(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])){3}\z'
        $prefix = [string]@(([string](Get-AapProp $Network 'subnet')).Split('/'))[-1]
        $resolvers = @(Get-AapProp $Network 'resolvers' | ForEach-Object { [string]$_ })
        $addrs = @([string](Get-AapProp $Network 'address'), [string](Get-AapProp $Network 'gateway')) + $resolvers
        if ($prefix -cnotmatch '^(1[6-9]|2[0-9]|30)\z' -or $resolvers.Count -lt 1 -or @($addrs | Where-Object { $_ -cnotmatch $ip }).Count) { throw 'AAP_SeedInvalid: the network declaration is not static IPv4 addressing' }   # check:seed-network
        $userData = @"
#cloud-config
autoinstall:
  version: 1
  interactive-sections: []
  locale: C.UTF-8
  keyboard:
    layout: us
  timezone: Etc/UTC
  refresh-installer:
    update: false
  source:
    id: ubuntu-server
  network:
    version: 2
    ethernets:
      nic:
        match:
          driver: hv_netvsc
        dhcp4: false
        dhcp6: false
        accept-ra: false
        addresses: [$($Network.address)/$prefix]
        routes:
          - to: default
            via: $($Network.gateway)
        nameservers:
          addresses: [$($resolvers -join ', ')]
  storage:
    swap:
      size: 0
    config:
      - {type: disk, id: disk0, match: {size: largest}, ptable: gpt, wipe: superblock-recursive, preserve: false, grub_device: false}
      - {type: partition, id: part-efi, device: disk0, number: 1, size: 512M, flag: boot, grub_device: true, preserve: false}
      - {type: format, id: fmt-efi, volume: part-efi, fstype: fat32, preserve: false}
      - {type: partition, id: part-root, device: disk0, number: 2, size: -1, preserve: false}
      - {type: format, id: fmt-root, volume: part-root, fstype: ext4, preserve: false}
      - {type: mount, id: mnt-root, device: fmt-root, path: /}
      - {type: mount, id: mnt-efi, device: fmt-efi, path: /boot/efi}
  kernel:
    package: $($b.kernel_package)
  ssh:
    install-server: true
    allow-pw: false
  packages:
$(@($b.packages | ForEach-Object { "    - $_" }) -join "`n")
  late-commands:
$(@($b.masked_services | ForEach-Object { "    - curtin in-target --target=/target -- systemctl mask $_" }) -join "`n")
  shutdown: poweroff
  user-data:
$(ConvertTo-AapYamlIndent $config 4)
"@
        $userData = $userData.Replace("`r`n", "`n") + "`n"
    }
    foreach ($v in @($Plan.base.kernel_package) + @($Plan.base.packages) + @($Plan.base.masked_services) + @($Plan.variables.install_user, $Plan.job_user.name) + @($Plan.job_user.groups)) {
        if ([string]$v -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._@-]{0,63}\z') { throw "AAP_PlanInvalid: seed value $(Get-AapPrintable ([string]$v) 80)" }   # check:seed-values
    }
    # Only now, and only by method calls, do the token bytes enter the text.
    $userData = $userData.Replace('@@AAP_TOKEN@@', [Text.Encoding]::ASCII.GetString($token.Bytes))
    if ($Mode -eq 'scan') { $userData = $userData.Replace('@@AAP_KNOWN@@', [Text.Encoding]::ASCII.GetString($Known.Bytes)) }
    return [pscustomobject]@{ Files = [ordered]@{ 'user-data' = $userData; 'meta-data' = "instance-id: $InstanceId`nlocal-hostname: $hostName`n" }; Token = $token }
}

function New-AapUbuntuRequest {
    <# The key=value request the agent parses. Every value is checked here and again by the agent. #>
    param([Parameter(Mandatory)][string]$Phase, [Parameter(Mandatory)][string]$Kind, [hashtable]$Fields = @{}, [string[]]$Env = @(), [string[]]$Scripts = @(), $Vars)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('schema=1'); $lines.Add("phase=$Phase"); $lines.Add("kind=$Kind")
    foreach ($k in @($Fields.Keys | Sort-Object)) { $lines.Add("$k=$($Fields[$k])") }
    foreach ($e in $Env) { $lines.Add("env=$e") }
    foreach ($s in $Scripts) { $lines.Add("script=$s") }
    if ($Vars) { foreach ($v in $Vars.PSObject.Properties) { $lines.Add("var=$($v.Name)=$($v.Value)") } }
    foreach ($l in $lines) {
        $ok = $l -cmatch '^([a-z_]{1,20})=([\x20-\x7e]{0,400})\z' -and
            ($l -cnotmatch '^env=' -or $l -cmatch '^env=[A-Z0-9_]{1,40}=[A-Za-z0-9_./:+-]{0,200}\z') -and
            ($l -cnotmatch '^var=' -or $l -cmatch '^var=[a-z_]{1,40}=[A-Za-z0-9_./:+-]{0,200}\z')
        if (-not $ok) { throw "AAP_PlanInvalid: request line $(Get-AapPrintable $l 120)" }   # check:request-value
    }
    return (($lines -join "`n") + "`n")
}

# ---------------------------------------------------------------------------------------------------------------------
# Guest replies: hostile bytes. One printable-ASCII JSON object of known fields, bounded, for the expected phase.

function ConvertFrom-AapUbuntuReply {
    param([AllowNull()][string]$Text, [Parameter(Mandatory)][string]$Phase, [int]$MaxBytes = $script:ReplyMaxBytes)
    if ($null -eq $Text -or $Text.Length -gt $MaxBytes) { throw "AAP_HostileGuest: $Phase reply is missing or over $MaxBytes bytes" }   # check:hostile-size
    if ($Text -notmatch '^\s*\{[\x20-\x7e\r\n\t]*\}\s*$') { throw "AAP_HostileGuest: $Phase reply is not one printable-ASCII JSON object" }   # check:hostile-shape
    try { $o = ConvertFrom-Json -InputObject $Text } catch { throw "AAP_HostileGuest: $Phase reply is not JSON" }
    if (-not ($o -is [Management.Automation.PSCustomObject])) { throw "AAP_HostileGuest: $Phase reply is not a JSON object" }
    $extra = @(Get-AapNames $o | Where-Object { @('schema', 'phase', 'status', 'message', 'scripts', 'data') -cnotcontains $_ })
    if ($extra.Count -or (Get-AapProp $o 'schema') -ne 1 -or [string](Get-AapProp $o 'phase') -cne $Phase -or @('ok', 'failed') -cnotcontains [string](Get-AapProp $o 'status')) { throw "AAP_HostileGuest: $Phase reply has unexpected fields or values" }   # check:hostile-schema
    $msg = Get-AapProp $o 'message'
    if ($null -ne $msg -and (-not ($msg -is [string]) -or $msg.Length -gt 512)) { throw "AAP_HostileGuest: $Phase message" }
    $scripts = @(Get-AapProp $o 'scripts')
    if ($scripts.Count -gt 64) { throw "AAP_HostileGuest: $Phase lists too many scripts" }
    foreach ($s in $scripts) {
        if ($null -eq $s) { continue }
        if (-not ($s -is [Management.Automation.PSCustomObject])) { throw "AAP_HostileGuest: $Phase script entry" }
        $names = Get-AapNames $s
        $bad = $names.Count -ne 4 -or @($names | Where-Object { @('name', 'sha256', 'exit_code', 'seconds') -cnotcontains $_ }).Count -or
            [string](Get-AapProp $s 'name') -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,79}\.(sh|ps1)\z' -or [string](Get-AapProp $s 'sha256') -cnotmatch '^[0-9a-f]{64}\z' -or
            -not (Test-AapInt (Get-AapProp $s 'exit_code') -2147483648) -or -not (Test-AapInt (Get-AapProp $s 'seconds'))
        if ($bad) { throw "AAP_HostileGuest: $Phase script entry" }
    }
    return $o
}

# A script phase passed only if the guest ran exactly the planned scripts, in order, with the pinned hashes, each with an
# accepted exit code. The guest checks the hashes before running; this checks its report again.
function Assert-AapUbuntuScriptReply($Reply, $PhasePlan) {
    $want = @($PhasePlan.scripts); $got = @(Get-AapProp $Reply 'scripts' | Where-Object { $null -ne $_ })
    if ($Reply.status -cne 'ok') { throw "AAP_PhaseFailed: $($PhasePlan.id) $(Get-AapPrintable (Get-AapProp $Reply 'message'))" }   # check:phase-failed
    if ($got.Count -ne $want.Count) { throw "AAP_PhaseFailed: $($PhasePlan.id) ran $($got.Count) of $($want.Count) scripts" }
    for ($i = 0; $i -lt $want.Count; $i++) {
        if ($got[$i].name -cne $want[$i].name) { throw "AAP_PhaseFailed: $($PhasePlan.id) script $i is $($got[$i].name), planned $($want[$i].name)" }   # check:script-order
        if ($got[$i].sha256 -cne $want[$i].sha256) { throw "AAP_ScriptHashMismatch: $($PhasePlan.id) $($want[$i].name)" }   # check:script-hash
        if (@($PhasePlan.valid_exit_codes) -notcontains [int]$got[$i].exit_code) { throw "AAP_PhaseFailed: $($PhasePlan.id) $($want[$i].name) exited $($got[$i].exit_code)" }   # check:exit-code
    }
}

# The deprovision reply carries the seal check the guest ran as root after removing the build user, agent and state.
function Assert-AapSealReply($Reply) {
    $seal = Get-AapProp (Get-AapProp $Reply 'data') 'seal'
    $ok = $seal -is [Management.Automation.PSCustomObject] -and (@(Get-AapNames $seal | Sort-Object) -join ',') -ceq 'checked,findings,unreadable'
    if ($ok) { foreach ($k in 'checked', 'findings', 'unreadable') { foreach ($x in @(Get-AapProp $seal $k)) { if (-not ($x -is [string]) -or $script:SealRules -cnotcontains $x) { $ok = $false } } } }
    if (-not $ok) { throw 'AAP_HostileGuest: the deprovision reply lacks a well-formed seal check' }
    if (@($seal.findings).Count) { throw "AAP_SecretFound: the sealed guest still has $(@($seal.findings) -join ', ')" }   # check:seal-secret
    $missing = @($script:SealRules | Where-Object { @($seal.checked) -cnotcontains $_ -or @($seal.unreadable) -ccontains $_ })
    if ($missing.Count) { throw "AAP_ScanIncomplete: the guest could not check $($missing -join ', ')" }   # check:seal-incomplete
    return [ordered]@{ checked = $script:SealRules; findings = @(); unreadable = @(); checked_by = 'guest, as root, after deprovision' }
}

# ---------------------------------------------------------------------------------------------------------------------
# Secret scan of the sealed disk (image-catalog.md, secret_scan). The scanner guest reports rule, path and the file's
# SHA-256, never the matched value; the host validates its report and applies the reviewed allowlist.

function Read-AapUbuntuAllowlist {
    <# secret-allowlist.json: reviewed exceptions, each an exact relative path (forward slashes, from the image root) and
       SHA-256 with its justification. No wildcard: an entry suppresses a finding only for that path with those bytes. #>
    param([Parameter(Mandatory)][string]$Path)
    if ((Get-AapPathKind $Path) -ne 'file' -or (New-Object IO.FileInfo $Path).Length -gt 65536) { throw "AAP_AllowlistInvalid: $Path is missing or over 64 KiB" }
    try { $doc = Read-AapJson $Path } catch { throw "AAP_AllowlistInvalid: $Path is not JSON" }
    if (-not ($doc -is [Management.Automation.PSCustomObject]) -or (Get-AapProp $doc 'schema') -ne 1 -or ((Get-AapNames $doc) -join ',') -cne 'schema,entries') { throw 'AAP_AllowlistInvalid: not a schema 1 allowlist' }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($e in @($doc.entries | Where-Object { $null -ne $_ })) {
        $names = $(if ($e -is [Management.Automation.PSCustomObject]) { (@(Get-AapNames $e | Sort-Object) -join ',') } else { '' })
        $p = [string](Get-AapProp $e 'path')
        if (@($out | Where-Object { $_.path -ceq $p }).Count) { throw "AAP_AllowlistInvalid: $(Get-AapPrintable $p 200) is listed twice" }   # check:allowlist-duplicate
        if ($names -cne 'justification,path,sha256' -or $p -cnotmatch '^[A-Za-z0-9._()+@ -]+(/[A-Za-z0-9._()+@ -]+)*\z' -or $p -match '(^|/)\.\.?(/|$)' -or   # check:allowlist
            [string](Get-AapProp $e 'sha256') -cnotmatch '^[0-9a-f]{64}\z' -or [string](Get-AapProp $e 'justification') -cnotmatch '^[\x20-\x7e]{10,1000}\z') {
            throw 'AAP_AllowlistInvalid: every entry needs exactly a relative path, its sha256 and a justification'
        }
        $out.Add([pscustomobject]@{ path = $p; sha256 = [string]$e.sha256 })
    }
    return $out.ToArray()
}

function ConvertFrom-AapScanReport {
    <# The scanner's scan.json, received capped: one JSON object of known fields and bounded lists, or hostile. #>
    param([Parameter(Mandatory)][string]$Path)
    $len = (New-Object IO.FileInfo $Path).Length
    if ($len -gt $script:ScanMaxBytes) { throw 'AAP_HostileGuest: scan.json is oversized' }
    $text = [IO.File]::ReadAllText($Path)
    if ($text -notmatch '^\s*\{[\x20-\x7e\r\n\t]*\}\s*$') { throw 'AAP_HostileGuest: scan.json is not one printable-ASCII JSON object' }   # check:scan-shape
    try { $o = ConvertFrom-Json -InputObject $text } catch { throw 'AAP_HostileGuest: scan.json is not JSON' }
    if (-not ($o -is [Management.Automation.PSCustomObject]) -or (Get-AapProp $o 'schema') -ne 1) { throw 'AAP_HostileGuest: scan.json schema' }
    if ([string](Get-AapProp $o 'layout') -cne 'ok') { throw "AAP_HostileGuest: the sealed disk no longer has the EFI and ext4 root layout the builder made: $(Get-AapPrintable ([string](Get-AapProp $o 'detail')))" }   # check:scan-layout
    $want = 'files_scanned,findings,findings_count,large_files,large_files_count,layout,rules,schema,unreadable,unreadable_count'
    $path = '^[\x20-\x7e]{1,400}\z'
    $ok = (@(Get-AapNames $o | Sort-Object) -join ',') -ceq $want
    foreach ($k in 'files_scanned', 'findings_count', 'large_files_count', 'unreadable_count') { if (-not (Test-AapInt (Get-AapProp $o $k))) { $ok = $false } }
    $ok = $ok -and (@($o.rules) -join ',') -ceq ($script:ScanRules -join ',') -and @($o.findings).Count -le $script:ListMax -and @($o.unreadable).Count -le $script:ListMax -and @($o.large_files).Count -le $script:LargeFilesMax
    if ($ok) {
        foreach ($f in @($o.findings)) {
            if (-not ($f -is [Management.Automation.PSCustomObject]) -or (@(Get-AapNames $f | Sort-Object) -join ',') -cne 'path,rule,sha256' -or $script:ScanRules -cnotcontains [string]$f.rule -or
                [string]$f.path -cnotmatch $path -or [string]$f.sha256 -cnotmatch '^([0-9a-f]{64}|unreadable)\z') { $ok = $false }
        }
        foreach ($f in @($o.large_files)) {
            if (-not ($f -is [Management.Automation.PSCustomObject]) -or (@(Get-AapNames $f | Sort-Object) -join ',') -cne 'bytes,path,sha256' -or [string]$f.path -cnotmatch $path -or
                -not (Test-AapInt $f.bytes) -or [string]$f.sha256 -cnotmatch '^[0-9a-f]{64}\z') { $ok = $false }
        }
        foreach ($u in @($o.unreadable)) { if (-not ($u -is [string]) -or $u -cnotmatch $path) { $ok = $false } }
    }
    if (-not $ok) { throw 'AAP_HostileGuest: scan.json has unexpected fields or values' }   # check:scan-shape
    return $o
}

function Get-AapUbuntuScanResult {
    <# Applies the allowlist to a validated scan report. 'found': a finding the allowlist does not cover (a build-credential
       finding is never covered), or an allowlist entry that matches no finding with exactly its path and bytes.
       'incomplete': an unreadable path, a finding list the scanner had to cut, or more large files than it lists. #>
    param([Parameter(Mandatory)]$Report, [Parameter(Mandatory)][string]$AllowlistPath, $Seal = $null)
    $allow = @(Read-AapUbuntuAllowlist -Path $AllowlistPath)
    $findings = New-Object System.Collections.Generic.List[object]
    $allowed = New-Object System.Collections.Generic.List[object]
    $used = @{}
    foreach ($f in @($Report.findings)) {
        $hit = $null
        foreach ($a in $allow) { if ($a.path -ceq [string]$f.path) { $hit = $a } }
        if ($script:NeverAllowed -ccontains [string]$f.rule -or $null -eq $hit -or [string]$f.sha256 -cne $hit.sha256) {   # check:allowlist-exact
            $findings.Add([pscustomobject]@{ rule = [string]$f.rule; path = [string]$f.path })
        } else {
            $allowed.Add([pscustomobject]@{ rule = [string]$f.rule; path = $hit.path; sha256 = $hit.sha256 }); $used[$hit.path] = $true
        }
    }
    foreach ($a in $allow) { if (-not $used.ContainsKey($a.path)) { $findings.Add([pscustomobject]@{ rule = 'allowlist-mismatch'; path = $a.path }) } }   # check:allowlist-stale
    $result = 'clean'
    if ($Report.unreadable_count -gt 0 -or $Report.findings_count -gt @($Report.findings).Count -or $Report.large_files_count -gt @($Report.large_files).Count) { $result = 'incomplete' }   # check:scan-incomplete
    if ($findings.Count) { $result = 'found' }
    return [pscustomobject]@{ schema = 1; result = $result; scanned_by = 'scanner guest from the pinned installation media, no network'; files_scanned = $Report.files_scanned
        unreadable_count = $Report.unreadable_count; unreadable = @($Report.unreadable); large_files_count = $Report.large_files_count; large_files = @($Report.large_files)
        allowlisted = $allowed.ToArray(); findings = @($findings | Select-Object -First $script:ListMax); seal = $Seal
        rules = @($script:ScanRules) + @('allowlist-mismatch') + $script:SealRules }
}

# ---------------------------------------------------------------------------------------------------------------------
# Inventory comparison (P05 certify.py compare, run by the provider on the host against the committed reference)

function Read-AapInventoryReport {
    <# The comparison report (written by P05's certify.py from the reference and the capped guest inventory). Fails the build
       on any difference in a gate section (cached tool versions, services, PATH order, action archive cache, the job user,
       probe coverage) and on anything the reference requires that the image lacks in a section the image owns
       (missing-required in RequiredSections). Missing-required elsewhere (the runner, which a verification guest does not
       have, the job's identity, the Azure fabric), every other difference, and the count and first entries of what the
       image has beyond the reference (extra), are recorded for P24, which certifies. #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$GateSections, [Parameter(Mandatory)][string[]]$RequiredSections)
    if ((Get-AapPathKind $Path) -ne 'file' -or (New-Object IO.FileInfo $Path).Length -gt $script:CompareMaxBytes) { throw 'AAP_VerifyFailed: the inventory comparison wrote no report' }
    $r = Read-AapJson $Path
    $inv = Get-AapProp $r 'inventory'
    if ([string](Get-AapProp $r 'kind') -cne 'inventory-report' -or $null -eq $inv) { throw 'AAP_VerifyFailed: the inventory comparison report has the wrong shape' }
    $all = @(Get-AapProp $inv 'differences' | Where-Object { $null -ne $_ })
    $extra = @($all | Where-Object { [string]$_.class -ceq 'extra' })
    $diffs = @($all | Where-Object { @('extra', 'documented-rig-difference') -cnotcontains [string]$_.class })
    $gate = @($diffs | Where-Object { $GateSections -ccontains [string]$_.section })
    if ($gate.Count) {   # check:inventory-gate
        throw "AAP_VerifyFailed: the job inventory differs from the hosted reference: $(@($gate | Select-Object -First 5 | ForEach-Object { Get-AapPrintable "$($_.class) $($_.section).$($_.key)" 120 }) -join '; ')"
    }
    $missing = @($diffs | Where-Object { [string]$_.class -ceq 'missing-required' -and $RequiredSections -ccontains [string]$_.section })
    if ($missing.Count) {   # check:inventory-required
        throw "AAP_VerifyFailed: the image lacks what the hosted reference requires: $(@($missing | Select-Object -First 5 | ForEach-Object { Get-AapPrintable "$($_.class) $($_.section).$($_.key)" 120 }) -join '; ')"
    }
    $counts = [ordered]@{}
    $c = Get-AapProp $inv 'counts'
    if ($null -ne $c) { foreach ($p in @($c.PSObject.Properties)) { $counts[(Get-AapPrintable $p.Name 40)] = [int]$p.Value } }
    return [ordered]@{ status = Get-AapPrintable ([string](Get-AapProp $inv 'status')) 10; counts = $counts; gate_sections = $GateSections; required_sections = $RequiredSections
        recorded = @($diffs | Select-Object -First $script:ListMax | ForEach-Object { [ordered]@{ class = Get-AapPrintable ([string]$_.class) 40; section = Get-AapPrintable ([string]$_.section) 80; key = Get-AapPrintable ([string]$_.key) 200 } })
        extra_count = $extra.Count; extra = @($extra | Select-Object -First $script:ListMax | ForEach-Object { [ordered]@{ section = Get-AapPrintable ([string]$_.section) 80; key = Get-AapPrintable ([string]$_.key) 200 } }) }
}

# ---------------------------------------------------------------------------------------------------------------------
# Build

function Save-AapState($Ctx) { Write-AapJson $Ctx.State $Ctx.StatePath }
function Set-AapStep($Ctx, [string]$Step, [string]$Value) {
    $Ctx.State.steps[$Step] = $Value
    Save-AapState $Ctx
}
# Every evidence file this run writes is listed in state.json, so a failure cleanup removes exactly those and nothing else.
function Add-AapWritten($Ctx, [string]$Path) {
    $Ctx.State.written.Add((Split-Path -Leaf $Path))
    Save-AapState $Ctx
}
function Write-AapEvidence($Ctx, $Object, [string]$Name) {
    $path = Join-Path $Ctx.EvidenceDir $Name
    Write-AapJson $Object $path
    Add-AapWritten $Ctx $path
    return $path
}

function Get-AapVmId($Vm) {
    $id = [string](Get-AapProp $Vm 'Id')
    if ($id -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z') { throw 'AAP_Unexpected: NewVm returned no VM id' }
    return $id.ToLowerInvariant()
}

function Get-AapGuestArgs($Guest, [hashtable]$More) {
    $a = @{ VmName = $Guest.Vm; VmId = $Guest.VmId; Port = $Guest.Port; Token = $Guest.Token }
    foreach ($k in $More.Keys) { $a[$k] = $More[$k] }
    return $a
}
function Send-AapGuestFile($Guest, [string]$HostPath, [string]$Name) {
    $r = [string](Invoke-AapProvider $Guest.Provider 'InvokeGuest' (Get-AapGuestArgs $Guest @{ Verb = 'put'; Name = $Name; InputPath = $HostPath; MaxBytes = 64; TimeoutSeconds = 1800 }))
    if ($r.Trim() -cne 'stored') { throw "AAP_GuestUnreachable: the guest did not store $Name" }
}
function Invoke-AapGuestRun($Guest, [string]$Request, [string]$Phase, [int]$TimeoutSeconds) {
    $text = Invoke-AapProvider $Guest.Provider 'InvokeGuest' (Get-AapGuestArgs $Guest @{ Verb = 'run'; Name = '-'; InputText = $Request; MaxBytes = $script:ReplyMaxBytes; TimeoutSeconds = $TimeoutSeconds })
    return ConvertFrom-AapUbuntuReply -Text $text -Phase $Phase
}
function Wait-AapGuestReady($Guest, [int]$TimeoutSeconds) {
    [bool](Invoke-AapProvider $Guest.Provider 'WaitGuestReady' (Get-AapGuestArgs $Guest @{ TimeoutSeconds = $TimeoutSeconds }))
}

# The guest's boot id, or $null while it does not answer (going down, booting); anything but a UUID is hostile.
function Get-AapGuestBootId($Guest) {
    try { $t = [string](Invoke-AapProvider $Guest.Provider 'InvokeGuest' (Get-AapGuestArgs $Guest @{ Verb = 'bootid'; Name = '-'; MaxBytes = 64; TimeoutSeconds = $script:ShortCallSeconds })) }
    catch { if ($_.Exception.Message -match '^AAP_(GuestUnreachable|GuestTimeout):') { return $null }; throw }
    $t = $t.Trim()
    if ($t -cnotmatch $script:Uuid) { throw 'AAP_HostileGuest: the guest boot id is not a UUID' }   # check:bootid
    return $t
}

# A reboot counts only once the guest answers again with another boot id than it had before: a guest that answers before
# it went down, or that never reboots, is not ready yet; the wait goes on until the phase timeout.
function Wait-AapReboot($Ctx, [string]$Before, [int]$TimeoutSeconds) {
    $until = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $left = [int][Math]::Max(1, [Math]::Ceiling(($until - (Get-Date)).TotalSeconds))
        if (-not (Wait-AapGuestReady $Ctx $left)) { return $false }
        $now = Get-AapGuestBootId $Ctx
        if ($null -eq $now -or $now -ceq $Before) { Start-Sleep -Seconds $script:PollSeconds; continue }   # check:reboot-proof
        return $true
    } while ((Get-Date) -lt $until)
    return $false
}

# A guest-authored file lands in the build folder first (admin-only, inside the staging budget), is size-checked there and
# only then moved to its destination; a partial or oversized file is deleted.
function Receive-AapGuestFile($Ctx, $Guest, [string]$Name, [string]$Dest, [long]$MaxBytes) {
    $part = Join-Path $Ctx.BuildDir "recv-$Name.part"
    try {
        $null = Invoke-AapProvider $Ctx.Provider 'ReceiveFile' (Get-AapGuestArgs $Guest @{ Name = $Name; HostPath = $part; MaxBytes = $MaxBytes; TimeoutSeconds = 1800 })
        if ((Get-AapPathKind $part) -ne 'file' -or (New-Object IO.FileInfo $part).Length -gt $MaxBytes) { throw "AAP_HostileGuest: $Name is missing or over $MaxBytes bytes" }   # check:receive-size
        [IO.File]::Move($part, $Dest)
    } finally {
        if ((Get-AapPathKind $part) -eq 'file') { [IO.File]::Delete($part) }
    }
    return $Dest
}

function Assert-AapStagingBudget($Ctx) {
    $bytes = [double](Invoke-AapProvider $Ctx.Provider 'MeasureBytes' @{ Path = $Ctx.BuildDir })
    if ($bytes -gt $Ctx.State.staging_peak_bytes) { $Ctx.State.staging_peak_bytes = $bytes }
    if ($bytes -gt [double]$Ctx.Config.StagingGibMax * $script:GiB) { throw ("AAP_BudgetExceeded: the build folder holds {0:N1} GiB, over StagingGibMax {1}" -f ($bytes / $script:GiB), $Ctx.Config.StagingGibMax) }   # check:budget
}

function Resolve-AapPlanEnv($Ctx, $P) {
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($prop in @($P.env.PSObject.Properties)) {
        $v = [string]$prop.Value
        foreach ($vp in $Ctx.Plan.variables.PSObject.Properties) { $v = $v.Replace('${var.' + $vp.Name + '}', [string]$vp.Value) }
        if ($v -match '\$\{') { throw "AAP_PlanInvalid: $($P.id) $($prop.Name) has an unresolved variable" }   # check:plan-variable
        $out.Add("$($prop.Name)=$v")
    }
    return $out.ToArray()
}

function Invoke-AapUbuntuPhase($Ctx, $P) {
    switch ($P.kind) {
        'scripts' {
            $req = New-AapUbuntuRequest -Phase $P.id -Kind 'scripts' -Fields @{ exec = $P.exec; pause_before = [int]$P.pause_before_seconds; timeout = $script:ScriptPhaseSeconds } `
                -Env (Resolve-AapPlanEnv $Ctx $P) -Scripts @($P.scripts | ForEach-Object { "$($_.name) $($_.sha256)" }) -Vars $Ctx.Plan.variables
            $r = Invoke-AapGuestRun $Ctx $req $P.id ($script:ScriptPhaseSeconds + [int]$P.pause_before_seconds)
            Assert-AapUbuntuScriptReply $r $P
            $Ctx.Evidence.phases.Add([ordered]@{ id = $P.id; kind = 'scripts'; exec = $P.exec; scripts = @($r.scripts) })
        }
        'restart' {
            # Upstream reboots from inside the guest (sudo reboot, expect_disconnect); the agent does the same.
            $before = Get-AapGuestBootId $Ctx
            if ($null -eq $before) { throw "AAP_GuestUnreachable: $($P.id) the guest did not report its boot id before the reboot" }
            $ack = [string](Invoke-AapProvider $Ctx.Provider 'InvokeGuest' (Get-AapGuestArgs $Ctx @{ Verb = 'reboot'; Name = '-'; MaxBytes = 64; TimeoutSeconds = $script:ShortCallSeconds }))
            if ($ack.Trim() -cne 'rebooting') { throw "AAP_PhaseFailed: $($P.id) the guest did not start the reboot" }
            if (-not (Wait-AapReboot $Ctx $before ([int]$P.timeout_seconds))) { throw "AAP_RebootTimeout: $($P.id) guest did not come back from a reboot within $($P.timeout_seconds) s" }   # check:reboot-timeout
            $Ctx.Evidence.phases.Add([ordered]@{ id = $P.id; kind = 'restart' })
        }
        'action' {
            if ($P.action -like 'download-software-report-*') {
                $ext = $P.action.Substring($P.action.LastIndexOf('-') + 1)
                $dest = Receive-AapGuestFile $Ctx $Ctx "software-report.$ext" (Join-Path $Ctx.EvidenceDir "software-report.$ext") $script:ReportMaxBytes
                Add-AapWritten $Ctx $dest
                $Ctx.Evidence.reports["software-report.$ext"] = Get-AapSha256File $dest
            } else {
                $req = New-AapUbuntuRequest -Phase $P.id -Kind 'action' -Fields @{ action = $P.action; exec = $P.exec; timeout = $script:ActionSeconds } -Env (Resolve-AapPlanEnv $Ctx $P) -Vars $Ctx.Plan.variables
                $r = Invoke-AapGuestRun $Ctx $req $P.id $script:ActionSeconds
                if ($P.action -ceq 'deprovision') { $Ctx.Seal = Assert-AapSealReply $r }
                if ($r.status -cne 'ok') { throw "AAP_PhaseFailed: $($P.id) $($P.action) $(Get-AapPrintable (Get-AapProp $r 'message'))" }   # check:action-failed
            }
            $Ctx.Evidence.phases.Add([ordered]@{ id = $P.id; kind = 'action'; action = $P.action; exec = $P.exec })
        }
    }
}

# A guest with its own VM, seed and token, in folder $Dir. NewVm makes the VM with no network adapter and an empty DVD drive
# for the seed; the build VM is then attached by the host network module, and its seed carries the declaration's static
# addressing, so the seed is made after Attach and put in that drive while the VM is Off.
function New-AapGuest($Ctx, [string]$Mode, [string]$Vm, [string]$Dir, [string]$OsDisk, [string[]]$Dvds, [bool]$BootFromDvd, $Known = $null) {
    $vmMade = Invoke-AapProvider $Ctx.Provider 'NewVm' @{ Name = $Vm; Path = $Dir; OsDisk = $OsDisk; Dvds = @($Dvds); BootFromDvd = $BootFromDvd
        Cpus = [int]$Ctx.Config.BuildCpus; MemGib = [int]$Ctx.Config.BuildMemGib }
    $g = [pscustomobject]@{ Provider = $Ctx.Provider; Vm = $Vm; VmId = (Get-AapVmId $vmMade); Mode = $Mode; Port = [int]$Ctx.Plan.channel.vsock_port; Token = $null
        Seed = (Join-Path $Dir 'seed.iso'); Network = $null }
    if ($Mode -eq 'build') { $Ctx.State.vm_id = $g.VmId; Save-AapState $Ctx }   # so a later cleanup can Detach it
    # Only Attach starts a VM's network, and only the builder starts a VM: no automatic start, no checkpoint (contract,
    # Consumer obligations 1 and 2), read back from Hyper-V.
    $cfg = Invoke-AapProvider $Ctx.Provider 'GetVmConfig' @{ VmName = $g.Vm; VmId = $g.VmId }
    if ([string](Get-AapProp $cfg 'AutomaticStartAction') -cne 'Nothing' -or [string](Get-AapProp $cfg 'CheckpointType') -cne 'Disabled') { throw "AAP_NetworkUntrusted: $Vm may start on its own or keep a checkpoint" }   # check:vm-config
    $decl = $(if ($Mode -eq 'build') { Connect-AapGuestNetwork $Ctx $g } else { $null })
    $made = New-AapUbuntuSeed -Mode $Mode -Plan $Ctx.Plan -InstanceId "aap-$($Ctx.Names.Tag)-$Mode" -Known $Known -Network $decl
    $null = Invoke-AapProvider $Ctx.Provider 'NewSeedImage' @{ Path = $g.Seed; Label = 'CIDATA'; Files = $made.Files }
    $null = Invoke-AapProvider $Ctx.Provider 'SetSeed' @{ VmName = $g.Vm; VmId = $g.VmId; Path = $g.Seed }
    $g.Token = $made.Token
    return $g
}

# Attach (the VM Off) and the shared declaration check. The declaration comes from the module's journal each time; the
# builder keeps it only while the VM it was attached for runs.
function Connect-AapGuestNetwork($Ctx, $Guest) {
    $req = @{ VmId = $Guest.VmId; VmName = $Guest.Vm; Profile = 'linux' }
    try { $decl = & $Ctx.Network.Attach $req } catch { throw "AAP_NetworkUntrusted: Attach of $($Guest.Vm) failed: $(Get-AapPrintable ([string]$_.Exception.Message) 300)" }
    $bad = @(Get-AapHostNetworkDeclarationProblems -Request $req -Declaration $decl)
    if ($bad.Count) { throw "AAP_NetworkInvalid: $(@($bad | Select-Object -First 3 | ForEach-Object { Get-AapPrintable ([string]$_) 150 }) -join '; ')" }   # check:network-declaration
    $Guest.Network = $decl
    return $decl
}

# Verify, and before a start Hyper-V's read-back of the build VM against its declaration through the shared check. While it
# runs (-Running, between phases) Verify alone, as Consumer obligations 3 asks. Every object Verify writes is a problem, an
# empty or $null one included.
function Assert-AapGuestNetwork($Ctx, $Guest, [switch]$Running) {
    $req = @{ VmId = $Guest.VmId; VmName = $Guest.Vm; Profile = 'linux' }
    try { $problems = @(& $Ctx.Network.Verify $req) } catch { throw "AAP_NetworkUntrusted: Verify of $($Guest.Vm) failed: $(Get-AapPrintable ([string]$_.Exception.Message) 300)" }
    if ($problems.Count) { throw "AAP_NetworkUntrusted: $($Guest.Vm): $(@($problems | Select-Object -First 3 | ForEach-Object { Get-AapPrintable ([string]$_) 150 }) -join '; ')" }   # check:network-verify
    $Ctx.NetVerifiedAt = Get-Date
    if ($Running) { return }
    $nics = @(Invoke-AapProvider $Ctx.Provider 'GetVmNetwork' @{ VmName = $Guest.Vm; VmId = $Guest.VmId })
    $bad = @(Get-AapHostNetworkAdapterProblems -Declaration $Guest.Network -Adapters $nics)
    if ($bad.Count) { throw "AAP_NetworkUntrusted: $($Guest.Vm): $(@($bad | Select-Object -First 3 | ForEach-Object { Get-AapPrintable ([string]$_) 150 }) -join '; ')" }   # check:network-readback
}

# Every host-initiated start. The build VM: Attach again while Off, the declaration check, Verify and the read-back. The
# scanner and verification VMs: no adapter at all, read back.
function Start-AapGuest($Ctx, $Guest) {
    if ($Guest.Mode -eq 'build') {
        $null = Connect-AapGuestNetwork $Ctx $Guest
        Assert-AapGuestNetwork $Ctx $Guest
    } else {
        $nics = @(Invoke-AapProvider $Ctx.Provider 'GetVmNetwork' @{ VmName = $Guest.Vm; VmId = $Guest.VmId })
        if ($nics.Count) { throw "AAP_NetworkUntrusted: $($Guest.Vm) has $($nics.Count) network adapters and must have none" }   # check:nic-none
    }
    $null = Invoke-AapProvider $Ctx.Provider 'StartVm' @{ VmName = $Guest.Vm; VmId = $Guest.VmId }
}

# The build VM's network goes after the VM itself (contract, Consumer obligations 4): RemoveVm, then Detach.
function Disconnect-AapGuestNetwork($Network, [string]$VmId, [string]$VmName) {
    try { $null = & $Network.Detach @{ VmId = $VmId; VmName = $VmName; Profile = 'linux' } }
    catch { throw "AAP_NetworkUntrusted: the network of $VmName is not proven detached: $(Get-AapPrintable ([string]$_.Exception.Message) 300)" }
}

# The live-server ISO, installed unattended: the seed's autoinstall answers every question, the boot command adds
# 'autoinstall' to the installer's kernel command line, and the installer powers the VM off when it is done. Then the
# media is ejected, the seed with its copy of the token deleted, and the installed system boots from its disk.
function Invoke-AapInstall($Ctx) {
    $g = New-AapGuest $Ctx 'build' $Ctx.Names.BuildVm $Ctx.BuildDir $Ctx.OsDisk @($Ctx.Media) $true
    $Ctx.VmId = $g.VmId; $Ctx.Token = $g.Token; $Ctx.Guest = $g
    Start-AapGuest $Ctx $g
    $null = Invoke-AapProvider $Ctx.Provider 'TypeBootCommand' @{ VmName = $g.Vm; VmId = $g.VmId; Keys = @($Ctx.Plan.base.boot_command) }
    if (-not (Invoke-AapProvider $Ctx.Provider 'WaitVmOff' @{ VmName = $g.Vm; VmId = $g.VmId; TimeoutSeconds = [int]$Ctx.Plan.base.install_timeout_seconds })) {   # check:install-timeout
        throw "AAP_InstallTimeout: the unattended install did not power off within $($Ctx.Plan.base.install_timeout_seconds) s"
    }
    $null = Invoke-AapProvider $Ctx.Provider 'RemoveDvds' @{ VmName = $g.Vm; VmId = $g.VmId }
    Remove-AapTree $g.Seed $Ctx.BuildDir
    Start-AapGuest $Ctx $g
    if (-not (Wait-AapGuestReady $Ctx $script:ReadySeconds)) { throw 'AAP_GuestUnreachable: the installed system did not answer on its channel' }
    $Ctx.State.installed_at = Get-AapUtc
}

# The scanner: the pinned installation media booted with no network and no disk, so firmware can only boot the media; the
# sealed disk, as a differencing child, is hot-added once the live system answers, and a trusted kernel and userland read
# the guest-authored file system inside a disposable guest, never on the host. The build token it looks for comes in the
# scanner's own seed, never in a request.
function Invoke-AapScan($Ctx) {
    $dir = Join-Path $Ctx.BuildDir 'scan'
    [void](New-Item -ItemType Directory -Path $dir)
    $child = Join-Path $dir 'os.avhdx'
    $null = Invoke-AapProvider $Ctx.Provider 'NewDiffDisk' @{ Parent = $Ctx.OsDisk; Path = $child }
    $g = New-AapGuest $Ctx 'scan' $Ctx.Names.ScanVm $dir $null @($Ctx.Media) $true $Ctx.Token
    Start-AapGuest $Ctx $g
    if (-not (Wait-AapGuestReady $g $script:ReadySeconds)) { throw 'AAP_ScanIncomplete: the scanner guest did not answer' }
    $null = Invoke-AapProvider $Ctx.Provider 'AttachDisk' @{ VmName = $g.Vm; VmId = $g.VmId; Path = $child }
    Send-AapGuestFile $g (Join-Path $script:GuestDir 'aap-scan.sh') 'aap-scan.sh'
    $r = Invoke-AapGuestRun $g (New-AapUbuntuRequest -Phase 'scan' -Kind 'scan') 'scan' $script:ScriptPhaseSeconds
    # A scanner that refused the disk layout still writes scan.json, which says so; any other failure has none.
    try { $report = Receive-AapGuestFile $Ctx $g 'scan.json' (Join-Path $Ctx.BuildDir 'scan.json') $script:ScanMaxBytes }
    catch { if ($r.status -cne 'ok') { throw "AAP_ScanIncomplete: the scanner reported failure: $(Get-AapPrintable (Get-AapProp $r 'message'))" }; throw }
    $parsed = ConvertFrom-AapScanReport -Path $report
    if ($r.status -cne 'ok') { throw "AAP_ScanIncomplete: the scanner reported failure: $(Get-AapPrintable (Get-AapProp $r 'message'))" }
    $null = Invoke-AapProvider $Ctx.Provider 'RemoveVm' @{ Name = $g.Vm }
    Remove-AapTree $dir $Ctx.BuildDir
    return Get-AapUbuntuScanResult -Report $parsed -AllowlistPath $script:AllowlistPath -Seal $Ctx.Seal
}

# Fresh guest from the sealed disk: a differencing child in the build folder, the job user from a new seed, then the
# post-generation scripts, upstream tests, the P05 inventory probe and discovery as that user. It gets no network adapter.
function Invoke-AapVerify($Ctx) {
    $dir = Join-Path $Ctx.BuildDir 'verify'
    [void](New-Item -ItemType Directory -Path $dir)
    $child = Join-Path $dir 'os.avhdx'
    $null = Invoke-AapProvider $Ctx.Provider 'NewDiffDisk' @{ Parent = $Ctx.OsDisk; Path = $child }
    $g = New-AapGuest $Ctx 'verify' $Ctx.Names.VerifyVm $dir $child @() $false
    Start-AapGuest $Ctx $g
    if (-not (Wait-AapGuestReady $g $script:ReadySeconds)) { throw 'AAP_VerifyFailed: fresh guest not ready' }
    foreach ($f in @(@{ H = (Join-Path $script:GuestDir 'aap-verify.sh'); N = 'aap-verify.sh' }, @{ H = $script:ProbeScript; N = 'linux.sh' }, @{ H = $script:HelloC; N = 'hello.c' }, @{ H = $Ctx.SourceArchive; N = 'runner-images.tar.gz' })) {
        Send-AapGuestFile $g $f.H $f.N
    }
    $vars = [pscustomobject]@{ job_user = [string]$Ctx.Plan.job_user.name; post_generation = [string]$Ctx.Plan.post_generation }
    $r = Invoke-AapGuestRun $g (New-AapUbuntuRequest -Phase 'verify' -Kind 'verify' -Vars $vars) 'verify' $script:ScriptPhaseSeconds
    if ((Get-AapProp $r 'status') -cne 'ok') { throw "AAP_VerifyFailed: the fresh guest reported failure: $(Get-AapPrintable (Get-AapProp $r 'message'))" }   # check:verify-status
    $inv = Receive-AapGuestFile $Ctx $g 'job-inventory.json' (Join-Path $Ctx.EvidenceDir 'job-inventory.json') $script:InventoryMaxBytes
    Add-AapWritten $Ctx $inv
    $v = Assert-AapUbuntuVerifyReply $r $inv ([string]$Ctx.Plan.job_user.name)
    $report = Join-Path $Ctx.BuildDir 'inventory-report.json'
    $code = Invoke-AapProvider $Ctx.Provider 'CompareInventory' @{ Reference = (Join-Path $script:RepoRoot ([string]$Ctx.Plan.verify.reference_path -replace '/', '\')); Candidate = $inv
        Allowlist = (Join-Path $script:RepoRoot ([string]$Ctx.Plan.verify.allowlist_path -replace '/', '\')); Out = $report }
    if (@(0, 1) -notcontains [int]$code) { throw "AAP_VerifyFailed: the inventory comparison could not run (exit $code)" }
    $v.inventory_compare = Read-AapInventoryReport -Path $report -GateSections @($Ctx.Plan.verify.gate_sections) -RequiredSections @($Ctx.Plan.verify.required_sections)
    $Ctx.Evidence.verify = $v
    $Ctx.State.clone_peak_bytes = [double](Invoke-AapProvider $Ctx.Provider 'MeasureBytes' @{ Path = $child })
    $Ctx.State.mem_overhead_mib = [int](Invoke-AapProvider $Ctx.Provider 'GetVmMemoryOverheadMib' @{ VmName = $g.Vm; VmId = $g.VmId })
    if ($Ctx.State.mem_overhead_mib -lt 1 -or $Ctx.State.mem_overhead_mib -gt $script:MemOverheadMibMax) { throw "AAP_BudgetExceeded: the VM worker overhead $($Ctx.State.mem_overhead_mib) MiB is outside 1 to $($script:MemOverheadMibMax) MiB" }   # check:mem-overhead
    Assert-AapStagingBudget $Ctx   # the verification disk is part of the build folder's peak
    $null = Invoke-AapProvider $Ctx.Provider 'RemoveVm' @{ Name = $g.Vm }
    Remove-AapTree $dir $Ctx.BuildDir
}

function Assert-AapUbuntuVerifyReply($Reply, [string]$InventoryPath, [string]$JobUser) {
    $d = Get-AapProp $Reply 'data'
    $t = Get-AapProp $d 'upstream_tests'; $disc = Get-AapProp $d 'discovery'; $facts = Get-AapProp $d 'facts'
    if ($null -eq $t -or $null -eq $disc -or $null -eq $facts) { throw 'AAP_HostileGuest: verify reply lacks upstream_tests, discovery or facts' }
    foreach ($k in 'total', 'passed', 'failed', 'skipped') { if (-not (Test-AapInt (Get-AapProp $t $k))) { throw "AAP_HostileGuest: upstream_tests.$k" } }
    $f = [ordered]@{}
    foreach ($k in 'kernel', 'systemd_state', 'root_mount_options', 'read_ahead_kb_root') {
        $x = Get-AapProp $facts $k
        if (-not ($x -is [string]) -or $x -cnotmatch '^[\x20-\x7e]{0,200}\z') { throw "AAP_HostileGuest: facts.$k" }
        $f[$k] = $x
    }
    $missing = @($script:Discovery | Where-Object { (Get-AapProp $disc $_) -ne $true })
    if ((Get-AapPathKind $InventoryPath) -ne 'file' -or (New-Object IO.FileInfo $InventoryPath).Length -gt $script:InventoryMaxBytes) { throw 'AAP_VerifyFailed: job-inventory.json missing or oversized' }
    $invSha = Get-AapSha256File $InventoryPath
    if ([string](Get-AapProp $d 'inventory_sha256') -cne $invSha) { throw 'AAP_VerifyFailed: job-inventory.json does not match the hash the guest reported' }   # check:inventory-hash
    if ($t.total -lt 1 -or $t.failed -ne 0 -or $missing.Count) {   # check:verify
        throw "AAP_VerifyFailed: upstream tests $($t.passed)/$($t.total) passed, $($t.failed) failed; not found: $($missing -join ', ')"
    }
    return [ordered]@{ upstream_tests = [ordered]@{ total = $t.total; passed = $t.passed; failed = $t.failed; skipped = $t.skipped }; discovery = $script:Discovery
        facts = $f; inventory_sha256 = $invSha; job_user = $JobUser; inventory_compare = $null }
}

function New-AapUbuntuGenerationRecord {
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
        provenance        = [ordered]@{ built_by_item = 'P07'; builder_commit = $BuilderCommit; inputs_manifest_sha256 = $InputsManifestSha256; built_at = $BuiltAt }
        secret_scan       = [ordered]@{ result = $SecretScanResult; evidence_ref = $SecretScanRef }
        certification     = [ordered]@{ certificate_ref = $null; certified_at = $null }
        approved_by       = $null
        retention         = [ordered]@{ owner = 'P21'; purpose = 'candidate'; expires_at = $null }
        quarantine_reason = $null
        live_activation   = $null
    }
}

function New-AapUbuntuBudgetRecord {
    <# backend-lifecycle (schema 2) budget record from measured bytes. Caps are the peak x 1.25, rounded up. The Ubuntu
       guest has no scratch disk: like the hosted runner, a job writes to its root file system, which is the clone. #>
    param([Parameter(Mandatory)][string]$GenerationId, [Parameter(Mandatory)][double]$BaseBytes, [Parameter(Mandatory)][double]$ClonePeakBytes,
        [Parameter(Mandatory)][double]$StagingPeakBytes, [Parameter(Mandatory)][int]$MemOverheadMib, [Parameter(Mandatory)][string]$EvidenceRef, [Parameter(Mandatory)][string]$MeasuredAt)
    foreach ($b in $BaseBytes, $ClonePeakBytes, $StagingPeakBytes) { if ($b -le 0) { throw 'AAP_BudgetUnmeasured: a measured size is zero' } }   # check:budget-measured
    $g = { param($x) [int][Math]::Ceiling($x / $script:GiB) }
    $base = & $g $BaseBytes; $clone = [Math]::Max(1, (& $g $ClonePeakBytes))
    [ordered]@{
        schema = 2; kind = 'budget'; profile = 'linux'; image_generation = $GenerationId; measured = $true; evidence_ref = $EvidenceRef; measured_at = $MeasuredAt
        base_gib = $base; clone_peak_gib = $clone; clone_gib_max = [int][Math]::Ceiling($clone * $script:CapHeadroom)
        scratch_peak_gib = 0; scratch_gib_max = 0
        staging_gib = (& $g $StagingPeakBytes); replacement_gib = $base; rollback_retained_generations = 1; boot_mem_overhead_mib = $MemOverheadMib
    }
}

function Remove-AapUbuntuBuild {
    <# Removes a build's VMs, build folder and, if this build began publishing and did not finish, its generation folder. An
       unfinished build's evidence files go too, exactly those its state.json lists, except secret-scan.json, which stays as
       the record of why it failed; its evidence folder goes if it made it and it is then empty. Idempotent: everything
       absent counts as done. Never touches another generation or anything outside these folders. With -Network, the build
       VM's network is detached once its VM is gone (the VM id comes from state.json); a Detach that throws throws. #>
    param([Parameter(Mandatory)]$Storage, [Parameter(Mandatory)]$Provider, [Parameter(Mandatory)]$Names, [string]$EvidenceRoot, [hashtable]$Network)
    $buildDir = Join-Path (Join-Path $Storage.Staging.Path 'build') $Names.BuildId
    $state = $null
    $statePath = Join-Path $buildDir 'state.json'
    if ((Get-AapPathKind $statePath) -eq 'file') { try { $state = Read-AapJson $statePath } catch { $state = $null } }
    foreach ($vm in $Names.BuildVm, $Names.ScanVm, $Names.VerifyVm) { $null = Invoke-AapProvider $Provider 'RemoveVm' @{ Name = $vm } }
    $vmId = [string](Get-AapProp $state 'vm_id')
    if ($Network -and $vmId) { Disconnect-AapGuestNetwork $Network $vmId $Names.BuildVm }
    $done = $null -ne $state -and (Get-AapProp $state 'status') -eq 'done'
    $publishing = $null -ne $state -and (Get-AapProp (Get-AapProp $state 'steps') 'publish') -eq 'intent'
    if ($publishing -and -not $done) {
        Remove-AapTree (Join-Path (Join-Path $Storage.Base.Path $script:Profile) $Names.Folder) $Storage.Base.Path
    }
    if ($null -ne $state -and -not $done -and $EvidenceRoot) {
        $ev = Join-Path (Join-Path $EvidenceRoot 'P07') $Names.BuildId
        foreach ($leaf in @(Get-AapProp $state 'written')) {
            if ([string]$leaf -cmatch '^[A-Za-z0-9._-]{1,80}\z' -and [string]$leaf -cne 'secret-scan.json') { Remove-AapTree (Join-Path $ev $leaf) $EvidenceRoot }
        }
        if ((Get-AapProp $state 'evidence_created') -eq $true -and (Get-AapPathKind $ev) -eq 'dir' -and @([IO.Directory]::GetFileSystemEntries($ev)).Count -eq 0) { Remove-AapTree $ev $EvidenceRoot }
    }
    Remove-AapTree $buildDir $Storage.Staging.Path
}

function Invoke-AapUbuntuImageBuild {
    <# Builds, scans, verifies, publishes and records one generation. Returns Ok, Status (built, unchanged, refused, failed),
       Reason, Detail, GenerationId and the record paths. A refusal before the build folder exists changes nothing; a failure
       after it removes the VMs, build disks, any partly published generation and the evidence files it wrote. -Network is
       the P10.0 host network module (Attach, Detach, Verify); without it nothing is built. #>
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Provider, [hashtable]$Network)
    $result = [ordered]@{ Ok = $false; Status = 'refused'; Reason = $null; Detail = $null; GenerationId = $null; RecordPath = $null; BudgetPath = $null; EvidencePath = $null; PartialCleaned = $false }
    $lock = $null; $started = $false; $published = $false; $ctx = $null; $storage = $null; $names = $null; $evidenceRoot = $null
    try {
        Assert-AapProvider $Provider
        if ($null -eq $Network) { throw 'AAP_NetworkUnavailable: the P10.0 host network module is not installed; no guest is attached' }   # check:network-module
        $missing = @($script:NetworkOps | Where-Object { -not ($Network[$_] -is [scriptblock]) })
        if ($missing.Count) { throw "AAP_NetworkInvalid: the host network module lacks $($missing -join ', ')" }   # check:network-ops
        $here = $PSScriptRoot
        # The builder runs elevated: its own code, the P06 helpers it loads, every folder it sends files from and every folder
        # whose code the provider runs (python) must be as protected as the roots it writes (P19 deploys them admin-only).
        # Folders are checked, not each file in them. This runs after the modules loaded: it refuses a deployment anyone but
        # the administrators can change, it cannot undo code that was already changed when it loaded (README, Trust).
        foreach ($d in @($here, $script:GuestDir, [IO.Path]::GetFullPath((Join-Path $here '..\windows')), [IO.Path]::GetFullPath((Join-Path $here '..\common')),
            [IO.Path]::GetFullPath((Join-Path $script:RepoRoot 'tools\parity-certify')), [IO.Path]::GetFullPath((Split-Path -Parent $script:ProbeScript)), [IO.Path]::GetFullPath((Split-Path -Parent $script:HelloC)),
            [IO.Path]::GetFullPath((Split-Path -Parent $script:NetCheckPath))) +
            @(Invoke-AapProvider $Provider 'ExecFolders')) {
            $problems = @(Invoke-AapProvider $Provider 'TestRootTrust' @{ Path = $d } | Where-Object { $_ })
            if ($problems.Count) { throw "AAP_BuilderUntrusted: ${d}: $(@($problems | ForEach-Object { Get-AapPrintable ([string]$_) 300 }) -join '; ')" }   # check:builder-untrusted
        }
        Import-Module $script:NetCheckPath   # only now: its folder passed the check above
        Assert-AapUbuntuConfig $Config
        $storage = Read-AapStorageRecord -Path $Config.StoragePath
        $evidenceRoot = [IO.Path]::GetFullPath([string]$Config.EvidenceRoot)
        Assert-AapStorageTrusted $storage $Provider $evidenceRoot
        $plan = Read-AapUbuntuBuildPlan -Path $script:PlanPath
        $planSha = Get-AapSha256File $script:PlanPath
        $names = Get-AapUbuntuNames $plan ([int]$Config.AapBuild)
        # The build VM's switch (contract, Switches): aap-build-linux, its own segment; P19 creates it, and without it no
        # build starts (never a fallback to a guest switch).
        $switch = Get-AapHostNetworkSwitchName -VmName $names.BuildVm
        $sw = Invoke-AapProvider $Provider 'GetSwitch' @{ Name = $switch }
        if (-not $switch -or $null -eq $sw -or [string](Get-AapProp $sw 'Name') -cne $switch -or [string](Get-AapProp $sw 'SwitchType') -cne 'Internal') { throw "AAP_NetworkUntrusted: the build switch $switch is not an existing internal switch" }   # check:network
        $result.GenerationId = $names.GenerationId
        $known = @(Get-AapUbuntuBlockers -Plan $plan -ManifestPath $script:ManifestPath)
        $waivers = @(Get-AapUbuntuWaivers $Config $known $planSha @($plan.blockers | Where-Object { $_.waivable -eq $false } | ForEach-Object { [string]$_.id }))
        $waived = @($waivers | ForEach-Object { $_.id })
        $open = @($known | Where-Object { $waived -cnotcontains $_ })
        if ($open.Count) { throw "AAP_Blocked: unresolved input blockers: $($open -join ', ')" }   # check:blocked

        $evidenceDir = Join-Path (Join-Path $evidenceRoot 'P07') $names.BuildId
        Assert-AapPlainPath -Root $evidenceRoot -Path $evidenceDir -Reason 'AAP_StorageUntrusted'
        $genParent = Join-Path $storage.Base.Path $script:Profile
        $genDir = Join-Path $genParent $names.Folder
        Assert-AapPlainPath -Root $storage.Base.Path -Path $genDir -Reason 'AAP_StorageUntrusted'
        $recordPath = Join-Path $evidenceDir 'generation.json'
        $result.RecordPath = $recordPath; $result.BudgetPath = Join-Path $evidenceDir 'budget.json'; $result.EvidencePath = Join-Path $evidenceDir 'build.json'

        $buildRoot = Join-Path $storage.Staging.Path 'build'
        Assert-AapPlainPath -Root $storage.Staging.Path -Path $buildRoot -Reason 'AAP_StorageUntrusted' -Create
        # One build VM at a time on this machine (owner decision, gate D2): one lock for every image build in the staging root.
        try { $lock = [IO.File]::Open((Join-Path $buildRoot 'aap-image-build.lock'), 'OpenOrCreate', 'ReadWrite', 'None') } catch { throw 'AAP_BuildBusy: another image build is running' }

        $buildDir = Join-Path $buildRoot $names.BuildId
        if ((Get-AapPathKind $buildDir) -ne 'absent') {
            Remove-AapUbuntuBuild -Storage $storage -Provider $Provider -Names $names -EvidenceRoot $evidenceRoot -Network $Network
            $result.PartialCleaned = $true
        }
        if ((Get-AapPathKind $genDir) -ne 'absent') {
            # Idempotent only for the very bytes this item recorded; anything else keeps its id and is never overwritten.
            $file = Join-Path $genDir 'base.vhdx'
            $same = (Get-AapPathKind $recordPath) -eq 'file' -and (Get-AapPathKind $file) -eq 'file'
            if ($same) { $same = (Get-AapSha256File $file) -ceq [string]@((Read-AapJson $recordPath).artifacts)[0].sha256 }
            if (-not $same) { throw "AAP_GenerationExists: $($names.GenerationId) already exists with other bytes or no record; a rebuild takes a new aap.<n>" }   # check:generation-exists
            $null = Invoke-AapProvider $Provider 'SetReadOnlyAcl' @{ Path = $file }
            $null = Invoke-AapProvider $Provider 'SetReadOnlyAcl' @{ Path = $genDir }
            $result.Ok = $true; $result.Status = 'unchanged'
            return [pscustomobject]$result
        }
        if ((Get-AapPathKind $evidenceDir) -ne 'absent') { throw "AAP_GenerationExists: evidence for $($names.GenerationId) already exists; a rebuild takes a new aap.<n>" }   # check:evidence-exists

        Assert-AapBuildSpace $storage $Provider $plan ([int]$Config.StagingGibMax)
        # The source archive and the media are the P03 entries the plan pins; P03 verifies them offline, then each staged file
        # must still have exactly the plan's SHA-256.
        $pin = $plan.inputs
        $inputs = Invoke-AapProvider $Provider 'VerifyInputs' @{ StagingRoot = $storage.Staging.Path; Names = @([string]$pin.source.entry, [string]$pin.media.entry) + @(Get-AapProp $Config 'Inputs' | Where-Object { $_ }) }
        if (-not $inputs.Complete) { throw "AAP_InputsUnverified: P03 offline verification did not accept every input: $(Get-AapPrintable ([string]$inputs.Detail) 300)" }   # check:inputs
        $source = [string]$inputs.Paths[[string]$pin.source.entry]
        $media = [string]$inputs.Paths[[string]$pin.media.entry]
        foreach ($x in @(@{ What = 'upstream source archive'; Path = $source; Sha = [string]$pin.source.sha256 }, @{ What = 'installation media'; Path = $media; Sha = [string]$pin.media.sha256 })) {
            if (-not $x.Path -or (Get-AapPathKind $x.Path) -ne 'file' -or (Get-AapSha256File $x.Path) -cne $x.Sha) { throw "AAP_InputsUnverified: the $($x.What) is not staged with the plan's SHA-256" }   # check:input-pin
        }
        if ((Split-Path -Leaf $media) -cnotmatch $script:MediaName) { throw 'AAP_InputsUnverified: the media must be an Ubuntu 24.04 live-server amd64 ISO' }   # check:media-name

        # From here on a failure cleans up what it made.
        [void](New-Item -ItemType Directory -Path $buildDir)
        $started = $true
        $ctx = [pscustomobject]@{
            Config = $Config; Provider = $Provider; Network = $Network; Guest = $null; NetVerifiedAt = $null; Plan = $plan; Names = $names; BuildDir = $buildDir; EvidenceDir = $evidenceDir; Media = $media
            StatePath = (Join-Path $buildDir 'state.json'); OsDisk = (Join-Path $buildDir 'os.vhdx'); Vm = $names.BuildVm; VmId = $null; Port = [int]$plan.channel.vsock_port; Token = $null
            SourceArchive = $source; Seal = $null
            State = [ordered]@{ schema = 1; build_id = $names.BuildId; generation_id = $names.GenerationId; status = 'running'; started_at = (Get-AapUtc); vm_id = $null; steps = [ordered]@{}
                evidence_created = $false; written = (New-Object System.Collections.Generic.List[string]); staging_peak_bytes = [double]0; clone_peak_bytes = [double]0; mem_overhead_mib = 0 }
            Evidence = [ordered]@{ schema = 2; item = 'P07'; build_id = $names.BuildId; generation_id = $names.GenerationId; builder_commit = $Config.BuilderCommit
                plan_sha256 = $planSha; inputs_manifest_sha256 = (Get-AapSha256File $script:ManifestPath); template_sha256 = $plan.baseline.template_sha256
                media = [ordered]@{ entry = [string]$pin.media.entry; file = (Split-Path -Leaf $media); sha256 = [string]$pin.media.sha256 }; base = [ordered]@{ kernel_package = $plan.base.kernel_package; deviation = $plan.base.deviation }
                switch = $switch; network = $null; waivers = $waivers; phases = (New-Object System.Collections.Generic.List[object]); reports = [ordered]@{}; verify = $null; seal_check = $null }
        }
        Save-AapState $ctx
        Assert-AapPlainPath -Root $evidenceRoot -Path (Split-Path -Parent $evidenceDir) -Reason 'AAP_StorageUntrusted' -Create
        [void](New-Item -ItemType Directory -Path $evidenceDir)
        $ctx.State.evidence_created = $true
        Save-AapState $ctx

        Set-AapStep $ctx 'install' 'intent'
        $null = Invoke-AapProvider $Provider 'NewBuildDisk' @{ Path = $ctx.OsDisk; SizeGib = [int]$plan.os_disk_gib }
        Invoke-AapInstall $ctx
        $ctx.Evidence.network = $ctx.Guest.Network
        Send-AapGuestFile $ctx $source 'runner-images.tar.gz'
        Set-AapStep $ctx 'install' 'done'

        foreach ($p in @($plan.phases)) {
            # The running build VM is verified again before a phase once a minute has passed: Verify sees host address changes
            # (contract, Consumer obligations 3, at phase granularity; a watcher inside a phase is the lab's, README).
            if (((Get-Date) - $ctx.NetVerifiedAt).TotalMinutes -ge $script:NetVerifyMinutes) { Assert-AapGuestNetwork $ctx $ctx.Guest -Running }   # check:network-running
            Set-AapStep $ctx $p.id 'intent'
            Invoke-AapUbuntuPhase $ctx $p
            Assert-AapStagingBudget $ctx
            Set-AapStep $ctx $p.id 'done'
        }
        $ctx.Evidence.seal_check = $ctx.Seal

        Set-AapStep $ctx 'seal' 'intent'
        $null = Invoke-AapProvider $Provider 'StopVm' @{ VmName = $ctx.Vm; VmId = $ctx.VmId; TimeoutSeconds = 1800 }
        $null = Invoke-AapProvider $Provider 'RemoveVm' @{ Name = $ctx.Vm }
        Disconnect-AapGuestNetwork $Network $ctx.VmId $ctx.Vm
        $null = Invoke-AapProvider $Provider 'OptimizeDisk' @{ Vhdx = $ctx.OsDisk }
        Assert-AapStagingBudget $ctx
        $sealedSha = Get-AapSha256File $ctx.OsDisk
        $sealedBytes = [long](Invoke-AapProvider $Provider 'MeasureBytes' @{ Path = $ctx.OsDisk })
        Set-AapStep $ctx 'seal' 'done'

        Set-AapStep $ctx 'scan' 'intent'
        $scan = Invoke-AapScan $ctx
        $null = Write-AapEvidence $ctx $scan 'secret-scan.json'
        if ($scan.result -cne 'clean') {   # check:secret-found
            $what = @(@($scan.findings | ForEach-Object { "$($_.rule) $($_.path)" }) + @($scan.unreadable | ForEach-Object { "unreadable $_" }) | Select-Object -First 5) -join '; '
            throw "$(if ($scan.result -ceq 'found') { 'AAP_SecretFound' } else { 'AAP_ScanIncomplete' }): secret scan result $($scan.result): $(Get-AapPrintable $what 400)"
        }
        if ((Get-AapSha256File $ctx.OsDisk) -cne $sealedSha) { throw 'AAP_BaseChanged: the sealed disk changed during the scan' }   # check:base-changed
        Set-AapStep $ctx 'scan' 'done'

        Set-AapStep $ctx 'verify' 'intent'
        Invoke-AapVerify $ctx
        if ((Get-AapSha256File $ctx.OsDisk) -cne $sealedSha) { throw 'AAP_BaseChanged: the sealed disk changed during verification' }   # check:base-changed
        Set-AapStep $ctx 'verify' 'done'

        $builtAt = Get-AapUtc
        $ref = "evidence/P07/$($names.BuildId)"
        $record = New-AapUbuntuGenerationRecord -Plan $plan -GenerationId $names.GenerationId -Bytes $sealedBytes -Sha256 $sealedSha -BuilderCommit $Config.BuilderCommit `
            -InputsManifestSha256 $ctx.Evidence.inputs_manifest_sha256 -BuiltAt $builtAt -SecretScanResult 'clean' -SecretScanRef "$ref/secret-scan.json"
        $budget = New-AapUbuntuBudgetRecord -GenerationId $names.GenerationId -BaseBytes $sealedBytes -ClonePeakBytes $ctx.State.clone_peak_bytes `
            -StagingPeakBytes $ctx.State.staging_peak_bytes -MemOverheadMib $ctx.State.mem_overhead_mib -EvidenceRef "$ref/build.json" -MeasuredAt $builtAt
        # The measured budget must fit the owner-approved one (contracts README, Resolved 2026-10-20, item 4).
        if ($budget.base_gib -gt [int]$Config.BaseGibMax -or ($budget.clone_gib_max + $budget.scratch_gib_max) -gt [int]$Config.JobDiskGibMax) {   # check:budget-approved
            throw "AAP_BudgetExceeded: measured base $($budget.base_gib) GiB and clone+scratch caps $($budget.clone_gib_max + $budget.scratch_gib_max) GiB exceed the approved $($Config.BaseGibMax) and $($Config.JobDiskGibMax) GiB"
        }
        $ctx.Evidence.installed_at = $ctx.State.installed_at
        $ctx.Evidence.measured = [ordered]@{ base_bytes = $sealedBytes; staging_peak_bytes = $ctx.State.staging_peak_bytes; clone_peak_bytes = $ctx.State.clone_peak_bytes; mem_overhead_mib = $ctx.State.mem_overhead_mib }
        $ctx.Evidence.base_sha256 = $sealedSha

        Assert-AapPlainPath -Root $storage.Base.Path -Path $genParent -Reason 'AAP_StorageUntrusted' -Create
        if ((Get-AapPathKind $genDir) -ne 'absent') { throw "AAP_GenerationExists: $genDir appeared during the build" }   # check:gen-race
        [void](New-Item -ItemType Directory -Path $genDir)
        Set-AapStep $ctx 'publish' 'intent'   # only now does a cleanup own $genDir
        $partial = Join-Path $genDir 'base.vhdx.partial'
        [IO.File]::Copy($ctx.OsDisk, $partial, $false)
        if ((Get-AapSha256File $partial) -cne $sealedSha) { throw 'AAP_PublishMismatch: the published copy differs from the sealed disk' }   # check:publish-hash
        [IO.File]::Move($partial, (Join-Path $genDir 'base.vhdx'))
        $null = Write-AapEvidence $ctx $ctx.Evidence 'build.json'
        $null = Write-AapEvidence $ctx $budget 'budget.json'
        $null = Write-AapEvidence $ctx $record 'generation.json'
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
            try { Remove-AapUbuntuBuild -Storage $storage -Provider $Provider -Names $names -EvidenceRoot $evidenceRoot -Network $Network } catch { $result.Detail = Get-AapPrintable "$($result.Detail); cleanup failed: $($_.Exception.Message)" 500 }
        }
    } finally {
        if ($lock) { $lock.Dispose() }
    }
    return [pscustomobject]$result
}

Export-ModuleMember -Function Read-AapUbuntuBuildPlan, Get-AapUbuntuBlockers, New-AapUbuntuSeed, New-AapUbuntuRequest, ConvertFrom-AapUbuntuReply,
    Read-AapUbuntuAllowlist, ConvertFrom-AapScanReport, Get-AapUbuntuScanResult, Read-AapInventoryReport, New-AapUbuntuGenerationRecord, New-AapUbuntuBudgetRecord,
    Remove-AapUbuntuBuild, Invoke-AapUbuntuImageBuild, Get-AapUbuntuNames
