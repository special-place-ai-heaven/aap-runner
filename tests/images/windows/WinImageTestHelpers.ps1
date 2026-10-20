# Fake world for the P06 builder tests: real temp folders for the storage roots, a fake provider that records every call
# and never touches Hyper-V, disks, ACLs or the network, and a fake guest that answers like guest/AapGuestRunner.ps1.
# Storage roots must pass the contract's path form (letters, digits, space and ._()- only), so the world lives under
# $env:AAP_P06_TESTROOT when set, else %LOCALAPPDATA%\aap-p06-tests; the caller removes it.

$script:GiB = 1073741824

function Get-TestRepo { (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path }
function Get-TestModulePath {
    if ($env:AAP_WINIMAGE_MODULE) { return $env:AAP_WINIMAGE_MODULE }
    Join-Path (Get-TestRepo) 'images\windows\AapWinImage.psm1'
}
function Get-TextSha([string]$Text) {
    $h = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))) -replace '-', '').ToLowerInvariant() } finally { $h.Dispose() }
}
function Get-FileSha([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Write-TestJson($Object, [string]$Path) { [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Object -Depth 12), (New-Object Text.UTF8Encoding($false))) }

function New-TestRoot {
    $base = $(if ($env:AAP_P06_TESTROOT) { $env:AAP_P06_TESTROOT } else { Join-Path $env:LOCALAPPDATA 'aap-p06-tests' })
    $root = Join-Path $base ([guid]::NewGuid().ToString('n').Substring(0, 12))
    [void][IO.Directory]::CreateDirectory($root)
    return $root
}

# The committed plan with every script hash filled in (the real plan is unpinned until P03 stages the upstream archive).
function New-PinnedPlan([string]$Path) {
    $plan = Get-Content -Raw -LiteralPath (Join-Path (Get-TestRepo) 'images\windows\build-plan.json') | ConvertFrom-Json
    foreach ($p in $plan.phases) { if ($p.kind -eq 'scripts') { foreach ($s in $p.scripts) { $s.sha256 = Get-TextSha $s.name } } }
    Write-TestJson $plan $Path
    return $plan
}

function New-FakeWorld {
    param([switch]$SeparateStaging)
    $root = New-TestRoot
    $w = [pscustomobject]@{
        Root = $root; Base = (Join-Path $root 'vol1\base'); Clone = (Join-Path $root 'vol1\clones'); Scratch = (Join-Path $root 'vol2\scratch')
        Staging = $null; Capacity = (Join-Path $root 'capacity'); StoragePath = (Join-Path $root 'capacity\storage.json'); Evidence = (Join-Path $root 'evidence')
        Disk = (Join-Path $root 'guestdisk'); PlanPath = (Join-Path $root 'plan.json'); Plan = $null; Config = $null
        Guids = [ordered]@{ vol1 = '00000000-0000-4000-8000-0000000000a1'; vol2 = '00000000-0000-4000-8000-0000000000b2'; vol3 = '00000000-0000-4000-8000-0000000000c3' }
        Free = @{}; Untrusted = @{}; Sizes = @{}; BuildDirBytes = { param($n) 40 * 1073741824 }; MeasureCount = 0
        Calls = (New-Object System.Collections.Generic.List[object]); Requests = (New-Object System.Collections.Generic.List[object])
        Guest = $null; ReadyAfterRestart = $true; InputsComplete = $true; Unattend = (New-Object System.Collections.Generic.List[string])
        InventoryText = '{"schema":1,"probe":"fake"}'; ReportText = '# software report'; Vms = @{}; VmIds = @{}; ReadOnly = (New-Object System.Collections.Generic.List[string])
        LastRequest = $null; SourceZip = $null; MediaSha = $null; Provider = $null; BootTime = $null
        Switch = @{ Name = 'aap-guests-win'; SwitchType = 'Internal' }
    }
    $w.Staging = $(if ($SeparateStaging) { Join-Path $root 'vol3\staging' } else { Join-Path $w.Base 'staging' })
    foreach ($d in $w.Base, $w.Clone, $w.Scratch, $w.Staging, $w.Capacity, $w.Evidence, $w.Disk, (Join-Path $w.Base 'media')) { [void][IO.Directory]::CreateDirectory($d) }
    foreach ($g in $w.Guids.Values) { $w.Free[$g] = [double]2000 * $script:GiB }
    $roots = [ordered]@{
        base_root    = [ordered]@{ path = $w.Base; volume_guid = $w.Guids.vol1 }
        clone_root   = [ordered]@{ path = $w.Clone; volume_guid = $w.Guids.vol1 }
        scratch_root = [ordered]@{ path = $w.Scratch; volume_guid = $w.Guids.vol2 }
    }
    if ($SeparateStaging) { $roots.staging_root = [ordered]@{ path = $w.Staging; volume_guid = $w.Guids.vol3 } }
    Write-TestJson ([ordered]@{ schema = 2; kind = 'storage'; volume_floor_gib = 50; roots = $roots }) $w.StoragePath
    $iso = Join-Path $w.Base 'media\SERVER_EVAL_x64FRE_en-us.iso'
    [IO.File]::WriteAllText($iso, 'fake evaluation media')
    $w.MediaSha = Get-FileSha $iso
    $zipDir = Join-Path $w.Staging 'runner-images-aee0669\aee0669dd04510a11756664eb77f5630debabed3'
    [void][IO.Directory]::CreateDirectory($zipDir)
    $w.SourceZip = Join-Path $zipDir 'runner-images.zip'
    [IO.File]::WriteAllText($w.SourceZip, 'fake archive')
    $w.Plan = New-PinnedPlan $w.PlanPath
    $repo = Get-TestRepo
    $manifest = Join-Path $repo 'images\common\artifacts.manifest.json'
    # The builder's repository files are fixed in module scope, never in Config; the fake world swaps them there.
    Set-ModuleVar 'PlanPath' $w.PlanPath
    Set-ModuleVar 'ManifestPath' $manifest
    Set-ModuleVar 'ProbeScript' (Join-Path $repo 'tools\parity-certify\probe\windows.ps1')
    Set-ModuleVar 'HelloC' (Join-Path $repo 'tools\parity-certify\workloads\fixtures\hello.c')
    Set-ModuleVar 'AllowlistPath' (Join-Path (Split-Path -Parent (Get-TestModulePath)) 'secret-allowlist.json')
    Set-ModuleVar 'PollSeconds' 0
    $planSha = Get-FileSha $w.PlanPath
    $w.Config = @{
        StoragePath = $w.StoragePath; EvidenceRoot = $w.Evidence; AapBuild = 1; MediaFile = 'SERVER_EVAL_x64FRE_en-us.iso'; MediaSha256 = $w.MediaSha
        Edition = 'Windows Server 2025 Datacenter Evaluation (Desktop Experience)'; BuildCpus = 4; BuildMemGib = 10; StagingGibMax = 400; BaseGibMax = 186; JobDiskGibMax = 55
        BuilderCommit = '0123456789abcdef0123456789abcdef01234567'; SourceEntry = 'runner-images-aee0669'; Inputs = @(); SwitchName = 'aap-guests-win'
        Waivers = @(Get-AapWinBlockers -Plan $w.Plan -ManifestPath $manifest | ForEach-Object { New-TestWaiver $_ $planSha })
    }
    $w.Sizes['os.vhdx'] = [double]128 * $script:GiB
    $w.Sizes['os.avhdx'] = [double]18 * $script:GiB
    $w.Sizes['temp.vhdx'] = [double]9 * $script:GiB
    $w.Guest = { param($w, $req) Get-FakeGuestReply $w $req }
    $w.Provider = New-FakeProvider $w
    return $w
}

function New-TestWaiver([string]$Id, [string]$PlanSha) { [ordered]@{ id = $Id; rationale = 'fake world: every blocker waived for the test'; plan_sha256 = $PlanSha; approver = 'chair (test)' } }

# Edits the world's plan and re-approves its waivers for the new plan bytes.
function Update-TestPlan($w, [scriptblock]$Edit) {
    & $Edit $w.Plan
    Write-TestJson $w.Plan $w.PlanPath
    $sha = Get-FileSha $w.PlanPath
    foreach ($x in $w.Config.Waivers) { $x.plan_sha256 = $sha }
}

# Writes only the DACL (Set-Acl in PowerShell 7 also asks for the SACL, which needs a privilege this user lacks).
function Set-TestAcl([string]$Path, $Security) {
    $info = $(if ($Security -is [Security.AccessControl.DirectorySecurity]) { New-Object IO.DirectoryInfo $Path } else { New-Object IO.FileInfo $Path })
    if ($PSVersionTable.PSVersion.Major -ge 6) { [IO.FileSystemAclExtensions]::SetAccessControl($info, $Security) } else { $info.SetAccessControl($Security) }
}

# Gives this user full control of a path the fake provider made read-only, so a test can tamper with it.
function Unlock-TestPath([string]$Path) {
    $sec = $(if (Test-Path -LiteralPath $Path -PathType Container) { New-Object Security.AccessControl.DirectorySecurity } else { New-Object Security.AccessControl.FileSecurity })
    $sec.SetAccessRuleProtection($true, $false)
    $sec.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule ([Security.Principal.WindowsIdentity]::GetCurrent().User), 'FullControl', 'Allow'))
    Set-TestAcl $Path $sec
}

# A folder this user cannot list (protected DACL with no entry); the user still owns it, so cleanup can reopen it.
function New-LockedDir([string]$Path) {
    [void][IO.Directory]::CreateDirectory($Path)
    $sec = New-Object Security.AccessControl.DirectorySecurity
    $sec.SetAccessRuleProtection($true, $false)
    Set-TestAcl $Path $sec
}

function Get-FakeRegistryData { [ordered]@{ registry = [ordered]@{ checked = @('autologon-password', 'autologon-enabled', 'lsa-default-password'); findings = @(); unreadable = @() } } }

function Set-ModuleVar([string]$Name, $Value) { & (Get-Module AapWinImage) { param($n, $v) Set-Variable -Scope Script -Name $n -Value $v } $Name $Value }
function Get-ModuleVar([string]$Name) { & (Get-Module AapWinImage) { param($n) Get-Variable -Scope Script -Name $n -ValueOnly } $Name }

function Get-VolumeOf($w, [string]$Path) {
    if ($Path.StartsWith((Join-Path $w.Root 'vol2'), 'OrdinalIgnoreCase')) { return $w.Guids.vol2 }
    if ($Path.StartsWith((Join-Path $w.Root 'vol3'), 'OrdinalIgnoreCase')) { return $w.Guids.vol3 }
    return $w.Guids.vol1
}

# What guest/AapGuestRunner.ps1 and guest/AapGuestVerify.ps1 answer when everything works.
function Get-FakeGuestReply($w, $req) {
    $o = [ordered]@{ schema = 1; phase = $req.phase; status = 'ok'; message = '' }
    if ($req.kind -eq 'scripts') { $o.scripts = @($req.scripts | ForEach-Object { [ordered]@{ name = $_.name; sha256 = $_.sha256; exit_code = 0; seconds = 3 } }) }
    if ($req.kind -eq 'action' -and $req.action -eq 'sysprep-generalize') {
        foreach ($f in @(Get-ChildItem -LiteralPath $w.Disk -Recurse -File -Filter 'unattend.xml')) { Remove-Item -LiteralPath $f.FullName -Force }
        $ab = Join-Path $w.Disk 'aap-build'; if (Test-Path $ab) { Remove-Item -LiteralPath $ab -Recurse -Force }
        $o.data = Get-FakeRegistryData
    }
    if ($req.kind -eq 'verify') {
        $disc = [ordered]@{}
        foreach ($k in 'vswhere', 'cl', 'link', 'clang_cl', 'lld_link', 'rc', 'msbuild', 'cmake', 'ninja', 'windows_sdk', 'hello_msvc', 'hello_clang_cl', 'resource_compile', 'job_user_admin') { $disc[$k] = $true }
        $o.data = [ordered]@{ upstream_tests = [ordered]@{ total = 1200; passed = 1190; failed = 0; skipped = 10 }; discovery = $disc; sdk_version = '10.0.26100.0'; inventory_sha256 = (Get-TextSha $w.InventoryText) }
    }
    return (ConvertTo-Json -InputObject $o -Depth 6 -Compress)
}

function New-FakeProvider($w) {
    # Ops resolve $w at call time from the calling test scope (the test names its world $w); no closures, so the helpers here stay visible.
    $p = @{}
    $p.TestRootTrust = { param($a) Add-FakeCall 'TestRootTrust' $a; if ($w.Untrusted.ContainsKey($a.Path)) { $w.Untrusted[$a.Path] } }
    $p.GetVolume = { param($a) Add-FakeCall 'GetVolume' $a; $g = Get-VolumeOf $w $a.Path; @{ Guid = $g; FreeBytes = $w.Free[$g] } }
    $p.MeasureBytes = { param($a) Add-FakeCall 'MeasureBytes' $a
        $leaf = Split-Path -Leaf $a.Path
        if ($w.Sizes.ContainsKey($leaf)) { return $w.Sizes[$leaf] }
        $w.MeasureCount++
        return (& $w.BuildDirBytes $w.MeasureCount) }
    $p.VerifyInputs = { param($a) Add-FakeCall 'VerifyInputs' $a; @{ Complete = $w.InputsComplete; Paths = @{ 'runner-images-aee0669' = $w.SourceZip }; Detail = 'fake' } }
    $p.NewBuildDisk = { param($a) Add-FakeCall 'NewBuildDisk' $a; [IO.File]::WriteAllText($a.Path, "disk $(Split-Path -Leaf $a.Path)") }
    $p.ApplyWindowsImage = { param($a) Add-FakeCall 'ApplyWindowsImage' $a
        foreach ($k in @($a.Files.Keys)) { Write-AapGuestFile -Root $w.Disk -RelPath $k -Bytes ([Text.Encoding]::UTF8.GetBytes($a.Files[$k])); $w.Unattend.Add($a.Files[$k]) }
        foreach ($k in @($a.CopyFiles.Keys)) { Write-AapGuestFile -Root $w.Disk -RelPath $k -Bytes ([IO.File]::ReadAllBytes($a.CopyFiles[$k])) }
        [IO.File]::AppendAllText($a.Vhdx, ' windows applied')
        @{ ImageIndex = 4; Build = '10.0.26100.1742' } }
    $p.NewDiffDisk = { param($a) Add-FakeCall 'NewDiffDisk' $a; [IO.File]::WriteAllText($a.Path, 'diff') }
    # The fake guest disk is a real folder: offline writes go through the production path walk.
    $p.WriteOfflineFiles = { param($a) Add-FakeCall 'WriteOfflineFiles' $a
        foreach ($k in @($a.Files.Keys)) { Write-AapGuestFile -Root $w.Disk -RelPath $k -Bytes ([Text.Encoding]::UTF8.GetBytes($a.Files[$k])); $w.Unattend.Add($a.Files[$k]) } }
    $p.GetSwitch = { param($a) Add-FakeCall 'GetSwitch' $a; $w.Switch }
    $p.NewVm = { param($a) Add-FakeCall 'NewVm' $a; $w.Vms[$a.Name] = 'Off'; $w.VmIds[$a.Name] = [guid]::NewGuid().ToString(); @{ Id = $w.VmIds[$a.Name] } }
    $p.GetGuestBootTime = { param($a) Add-FakeCall 'GetGuestBootTime' $a
        if ($w.BootTime) { return (& $w.BootTime $w) }
        [string](630000000000000000 + @($w.Calls | Where-Object { $_.Op -eq 'RestartVm' }).Count) }
    $p.StartVm = { param($a) Add-FakeCall 'StartVm' $a; $w.Vms[$a.VmName] = 'Running' }
    $p.StopVm = { param($a) Add-FakeCall 'StopVm' $a; $w.Vms[$a.VmName] = 'Off' }
    $p.RestartVm = { param($a) Add-FakeCall 'RestartVm' $a }
    $p.RemoveVm = { param($a) Add-FakeCall 'RemoveVm' $a; $w.Vms.Remove($a.Name) }
    $p.WaitGuestReady = { param($a) Add-FakeCall 'WaitGuestReady' $a
        $restarts = @($w.Calls | Where-Object { $_.Op -eq 'RestartVm' }).Count
        if ($restarts -eq 0) { return $true }
        if ($w.ReadyAfterRestart -is [scriptblock]) { return (& $w.ReadyAfterRestart $restarts) }
        return $w.ReadyAfterRestart }
    $p.SendFile = { param($a) Add-FakeCall 'SendFile' $a
        if ($a.GuestPath -like '*request.json') { $w.LastRequest = Get-Content -Raw -LiteralPath $a.HostPath | ConvertFrom-Json; $w.Requests.Add($w.LastRequest) }
        if ($a.GuestPath -like 'C:\aap-build\*' -and $a.GuestPath -notlike '*request.json') { $t = Join-Path $w.Disk ($a.GuestPath.Substring(3)); [void][IO.Directory]::CreateDirectory((Split-Path -Parent $t)); Copy-Item -LiteralPath $a.HostPath -Destination $t -Force } }
    $p.InvokeGuest = { param($a) Add-FakeCall 'InvokeGuest' $a; & $w.Guest $w $w.LastRequest }
    $p.ReceiveFile = { param($a) Add-FakeCall 'ReceiveFile' $a
        $text = $(if ($a.GuestPath -like '*job-inventory.json') { $w.InventoryText } else { $w.ReportText })
        [IO.File]::WriteAllText($a.HostPath, $text, (New-Object Text.UTF8Encoding($false))) }
    $p.OptimizeDisk = { param($a) Add-FakeCall 'OptimizeDisk' $a }
    $p.MountReadOnly = { param($a) Add-FakeCall 'MountReadOnly' $a; $w.Disk }
    $p.Dismount = { param($a) Add-FakeCall 'Dismount' $a }
    # A real read-only ACL, with this user in the place of Administrators: reruns and cleanup must cope with it.
    $p.SetReadOnlyAcl = { param($a) Add-FakeCall 'SetReadOnlyAcl' $a; $w.ReadOnly.Add($a.Path)
        $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        Set-AapReadOnlyAcl -Path $a.Path -Owner $me -Readers @($me) }
    $p.GetVmMemoryOverheadMib = { param($a) Add-FakeCall 'GetVmMemoryOverheadMib' $a; 310 }
    return $p
}

function Get-Ops($w, [string]$Op) { @($w.Calls | Where-Object { $_.Op -eq $Op }) }

# Removes the world without following the junctions some tests plant (Windows PowerShell 5.1 Remove-Item would).
function Remove-World($w) {
    if ($w -and (Test-Path -LiteralPath $w.Root)) { Remove-AapTree $w.Root (Split-Path -Parent $w.Root) }
}

# Stock repo python 3 that really runs (the WindowsApps stub does not count).
function Find-TestPython {
    foreach ($c in @(Get-Command python, python3 -All -ErrorAction SilentlyContinue)) {
        try { $v = & $c.Source -I --version 2>&1; if ($LASTEXITCODE -eq 0 -and "$v" -match 'Python 3\.') { return $c.Source } } catch { $null = $_ }
    }
    return $null
}

function Add-FakeCall([string]$Op, $A) { $w.Calls.Add([pscustomobject]@{ Op = $Op; Args = $A }) }
