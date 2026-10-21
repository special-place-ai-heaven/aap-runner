# Fake world for the P07 builder tests: real temp folders for the storage roots, a fake provider that records every call
# and never touches Hyper-V, disks, ACLs, sockets or the network, the shared strict fake of the host network module
# (tests/common/AapHostNetworkFake.psm1, state under <world>\net) and a fake guest agent that answers like
# guest/aap-agent.sh. Storage roots must pass the contract's path form (letters, digits, space and ._()- only), so the world
# lives under $env:AAP_P07_TESTROOT when set, else %LOCALAPPDATA%\aap-p07-tests; the caller removes it.

$script:GiB = 1073741824

function Get-TestRepo { (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path }
function Get-TestModulePath {
    if ($env:AAP_UBUNTUIMAGE_MODULE) { return $env:AAP_UBUNTUIMAGE_MODULE }
    Join-Path (Get-TestRepo) 'images\ubuntu-24.04\AapUbuntuImage.psm1'
}
function Get-TextSha([string]$Text) {
    $h = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($h.ComputeHash((New-Object Text.UTF8Encoding($false)).GetBytes($Text))) -replace '-', '').ToLowerInvariant() } finally { $h.Dispose() }
}
function Get-FileSha([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Write-TestJson($Object, [string]$Path) { [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Object -Depth 12), (New-Object Text.UTF8Encoding($false))) }

function New-TestRoot {
    $base = $(if ($env:AAP_P07_TESTROOT) { $env:AAP_P07_TESTROOT } else { Join-Path $env:LOCALAPPDATA 'aap-p07-tests' })
    $root = Join-Path $base ([guid]::NewGuid().ToString('n').Substring(0, 12))
    [void][IO.Directory]::CreateDirectory($root)
    return $root
}

# The committed plan as P03.1 will leave it: every script hash filled in, the source archive and the media pinned by entry and
# SHA-256 and their two unwaivable blockers gone. And a 3-second reboot timeout, so a reboot that never proves itself ends
# the test (or a mutant) in seconds, not half an hour.
function New-PinnedPlan([string]$Path, [string]$SourceSha = ('1' * 64), [string]$MediaSha = ('2' * 64)) {
    $plan = Get-Content -Raw -LiteralPath (Join-Path (Get-TestRepo) 'images\ubuntu-24.04\build-plan.json') | ConvertFrom-Json
    foreach ($p in $plan.phases) {
        if ($p.kind -eq 'scripts') { foreach ($s in $p.scripts) { $s.sha256 = Get-TextSha $s.name } }
        if ($p.kind -eq 'restart') { $p.timeout_seconds = 3 }
    }
    $plan.inputs.source.entry = 'runner-images-7e7dc1b'; $plan.inputs.source.sha256 = $SourceSha
    $plan.inputs.media.entry = 'ubuntu-24.04.5-live-server'; $plan.inputs.media.sha256 = $MediaSha
    $plan.blockers = @($plan.blockers | Where-Object { $_.waivable })
    Write-TestJson $plan $Path
    return $plan
}

function Set-ModuleVar([string]$Name, $Value) { & (Get-Module AapUbuntuImage) { param($n, $v) Set-Variable -Scope Script -Name $n -Value $v } $Name $Value }
function Get-ModuleVar([string]$Name) { & (Get-Module AapUbuntuImage) { param($n) Get-Variable -Scope Script -Name $n -ValueOnly } $Name }

function New-TestWaiver([string]$Id, [string]$PlanSha) { [ordered]@{ id = $Id; rationale = 'fake world: every blocker waived for the test'; plan_sha256 = $PlanSha; approver = 'chair (test)' } }

# Edits the world's plan and re-approves its waivers for the new plan bytes.
function Update-TestPlan($w, [scriptblock]$Edit) {
    & $Edit $w.Plan
    Write-TestJson $w.Plan $w.PlanPath
    $sha = Get-FileSha $w.PlanPath
    foreach ($x in $w.Config.Waivers) { $x.plan_sha256 = $sha }
}

function Get-FakeScanReport {
    [ordered]@{ schema = 1; layout = 'ok'; files_scanned = 412345; findings_count = 0; findings = @(); unreadable_count = 0; unreadable = @(); large_files_count = 1
        large_files = @([ordered]@{ path = 'usr/lib/big.so'; bytes = 40000000; sha256 = (Get-TextSha 'big') })
        rules = @('runner-credentials', 'runner-config', 'ssh-host-key', 'ssh-authorized-keys', 'shell-history', 'app-key', 'cloud-init-seed', 'installer-answers',
            'azure-provisioning-data', 'shadow-password-hash', 'pem-private-key', 'github-token', 'github-pat', 'jit-config', 'synthetic-marker', 'build-credential',
            'build-agent', 'build-sudoers') }
}
# What certify.py compare writes when the image matches the hosted reference except for the exact Azure kernel build, for a
# verification guest: it has no runner, so the runner fields are missing (recorded, not gated: the image does not own them).
function Get-FakeCompareReport {
    [ordered]@{ schema = 1; kind = 'inventory-report'; inventory = [ordered]@{ status = 'fail'; counts = [ordered]@{ 'version-mismatch' = 1; 'missing-required' = 3; extra = 2 }
            differences = @([ordered]@{ class = 'version-mismatch'; section = 'image'; key = 'kernel'; reference = '6.17.0-1022-azure'; candidate = '6.17.0-1030-azure' },
                [ordered]@{ class = 'missing-required'; section = 'image'; key = 'runner_version'; reference = '2.337.0'; candidate = $null },
                [ordered]@{ class = 'missing-required'; section = 'image'; key = 'runner_os'; reference = 'Linux'; candidate = $null },
                [ordered]@{ class = 'missing-required'; section = 'image'; key = 'runner_arch'; reference = 'X64'; candidate = $null },
                [ordered]@{ class = 'extra'; section = 'tool_cache'; key = 'node/24.22.0'; reference = $null; candidate = '24.22.0' },
                [ordered]@{ class = 'extra'; section = 'env'; key = 'AAP'; reference = $null; candidate = 'x' })
            identity = [ordered]@{ status = 'pass'; checks = @() } } }
}

function New-FakeWorld {
    param([switch]$SeparateStaging)
    $root = New-TestRoot
    $w = [pscustomobject]@{
        Root = $root; Base = (Join-Path $root 'vol1\base'); Clone = (Join-Path $root 'vol1\clones'); Scratch = (Join-Path $root 'vol2\scratch')
        Staging = $null; Capacity = (Join-Path $root 'capacity'); StoragePath = (Join-Path $root 'capacity\storage.json'); Evidence = (Join-Path $root 'evidence')
        PlanPath = (Join-Path $root 'plan.json'); Plan = $null; Config = $null
        Guids = [ordered]@{ vol1 = '00000000-0000-4000-8000-0000000000a1'; vol2 = '00000000-0000-4000-8000-0000000000b2'; vol3 = '00000000-0000-4000-8000-0000000000c3' }
        Free = @{}; Untrusted = @{}; Sizes = @{}; BuildDirBytes = { param($n) 70 * 1073741824 }; MeasureCount = 0
        Calls = (New-Object System.Collections.Generic.List[object]); Requests = (New-Object System.Collections.Generic.List[object])
        Seeds = (New-Object System.Collections.Generic.List[object]); Puts = (New-Object System.Collections.Generic.List[object])
        Guest = $null; InstallOff = $true; ReadyAfterReboot = $true; GuestReady = $true; InputsComplete = $true; BootId = $null
        InventoryText = '{"schema":1,"probe":"fake"}'; ReportText = '# software report'; ScanReport = $null; ScanText = $null
        CompareReport = $null; CompareExit = 1; Vms = @{}; VmIds = @{}; ReadOnly = (New-Object System.Collections.Generic.List[string])
        SourceArchive = $null; MediaPath = $null; MediaSha = $null; Provider = $null; PythonDir = (Join-Path $root 'python'); MemOverheadMib = 280
        Switch = @{ Name = 'aap-build-linux'; SwitchType = 'Internal' }
        # The host network module (the shared fake) and what Hyper-V says about VMs beyond it: adapters the module did not
        # make (VM name -> provider-shape adapters), a VM's configuration, and a Hyper-V that cannot look.
        NetRoot = (Join-Path $root 'net'); Network = $null; ForeignNics = @{}; VmConfig = @{ AutomaticStartAction = 'Nothing'; CheckpointType = 'Disabled' }; VmLookFails = $false
        Seeded = @{}
    }
    $w.Staging = $(if ($SeparateStaging) { Join-Path $root 'vol3\staging' } else { Join-Path $w.Base 'staging' })
    foreach ($d in $w.Base, $w.Clone, $w.Scratch, $w.Staging, $w.Capacity, $w.Evidence, (Join-Path $w.Base 'media')) { [void][IO.Directory]::CreateDirectory($d) }
    foreach ($g in $w.Guids.Values) { $w.Free[$g] = [double]2000 * $script:GiB }
    $roots = [ordered]@{
        base_root    = [ordered]@{ path = $w.Base; volume_guid = $w.Guids.vol1 }
        clone_root   = [ordered]@{ path = $w.Clone; volume_guid = $w.Guids.vol1 }
        scratch_root = [ordered]@{ path = $w.Scratch; volume_guid = $w.Guids.vol2 }
    }
    if ($SeparateStaging) { $roots.staging_root = [ordered]@{ path = $w.Staging; volume_guid = $w.Guids.vol3 } }
    Write-TestJson ([ordered]@{ schema = 2; kind = 'storage'; volume_floor_gib = 50; roots = $roots }) $w.StoragePath
    # Both inputs as P03 stages them: <staging>\<entry>\<sha256>\<file>.
    $isoDir = Join-Path $w.Staging 'ubuntu-24.04.5-live-server\fake'
    [void][IO.Directory]::CreateDirectory($isoDir)
    $w.MediaPath = Join-Path $isoDir 'ubuntu-24.04.5-live-server-amd64.iso'
    [IO.File]::WriteAllText($w.MediaPath, 'fake installation media')
    $w.MediaSha = Get-FileSha $w.MediaPath
    $arcDir = Join-Path $w.Staging 'runner-images-7e7dc1b\7e7dc1bcc0ef464e5e315a2b4c33609590c6cffe'
    [void][IO.Directory]::CreateDirectory($arcDir)
    $w.SourceArchive = Join-Path $arcDir 'runner-images.tar.gz'
    [IO.File]::WriteAllText($w.SourceArchive, 'fake archive')
    [void][IO.Directory]::CreateDirectory($w.PythonDir)
    $w.Plan = New-PinnedPlan $w.PlanPath (Get-FileSha $w.SourceArchive) $w.MediaSha
    $repo = Get-TestRepo
    $manifest = Join-Path $repo 'images\common\artifacts.manifest.json'
    # The builder's repository files are fixed in module scope, never in Config; the fake world swaps them there.
    Set-ModuleVar 'PlanPath' $w.PlanPath
    Set-ModuleVar 'ManifestPath' $manifest
    Set-ModuleVar 'AllowlistPath' (Join-Path $repo 'images\ubuntu-24.04\secret-allowlist.json')
    Set-ModuleVar 'GuestDir' (Join-Path $repo 'images\ubuntu-24.04\guest')
    Set-ModuleVar 'ProbeScript' (Join-Path $repo 'tools\parity-certify\probe\linux.sh')
    Set-ModuleVar 'HelloC' (Join-Path $repo 'tools\parity-certify\workloads\fixtures\hello.c')
    Set-ModuleVar 'RepoRoot' $repo
    Set-ModuleVar 'PollSeconds' 0
    Set-ModuleVar 'NetVerifyMinutes' 1   # a test that wants the running build VM verified before every phase sets 0
    $planSha = Get-FileSha $w.PlanPath
    $w.Config = @{
        StoragePath = $w.StoragePath; EvidenceRoot = $w.Evidence; AapBuild = 1
        BuildCpus = 4; BuildMemGib = 10; StagingGibMax = 400; BaseGibMax = 186; JobDiskGibMax = 55
        BuilderCommit = '0123456789abcdef0123456789abcdef01234567'; Inputs = @()
        Waivers = @(Get-AapUbuntuBlockers -Plan $w.Plan -ManifestPath $manifest | ForEach-Object { New-TestWaiver $_ $planSha })
    }
    $w.Sizes['os.vhdx'] = [double]61 * $script:GiB
    $w.Sizes['os.avhdx'] = [double]14 * $script:GiB
    $w.ScanReport = Get-FakeScanReport
    $w.CompareReport = Get-FakeCompareReport
    $w.Guest = { param($w, $req) Get-FakeGuestReply $w $req }
    $w.Provider = New-FakeProvider $w
    # Hyper-V's answer for a VM id, as the module asks it: $null only for a VM it does not have. The builder gets the fake's
    # three ops wrapped so the world records each call in order with the provider's.
    $w | Add-Member -NotePropertyName NetFake -NotePropertyValue $null
    $w.Network = @{
        Attach = { param($a) Add-FakeCall 'Attach' $a; & $w.NetFake.Attach $a }
        Detach = { param($a) Add-FakeCall 'Detach' $a; & $w.NetFake.Detach $a }
        Verify = { param($a) Add-FakeCall 'Verify' $a; & $w.NetFake.Verify $a }
    }
    $w.NetFake = New-AapFakeHostNetwork -Root $w.NetRoot -Vm { param($id)
        if ($w.VmLookFails) { throw 'fake Hyper-V: the service does not answer' }
        $name = @($w.VmIds.Keys | Where-Object { $w.VmIds[$_] -eq $id }) | Select-Object -First 1
        if (-not $name -or -not $w.Vms.ContainsKey($name)) { return $null }
        @{ State = $w.Vms[$name]; Adapters = @($w.ForeignNics[$name] | Where-Object { $null -ne $_ }).Count } }
    return $w
}

# A request text as the agent parses it: fields, plus env, script and var lists.
function ConvertFrom-TestRequest([string]$Text) {
    $r = [ordered]@{ env = @(); script = @(); var = [ordered]@{}; text = $Text }
    foreach ($l in $Text.TrimEnd("`n").Split("`n")) {
        $k = $l.Substring(0, $l.IndexOf('=')); $v = $l.Substring($l.IndexOf('=') + 1)
        switch ($k) { 'env' { $r.env += $v } 'script' { $r.script += $v } 'var' { $r.var[$v.Substring(0, $v.IndexOf('='))] = $v.Substring($v.IndexOf('=') + 1) } default { $r[$k] = $v } }
    }
    return [pscustomobject]$r
}

# What guest/aap-agent.sh answers when everything works.
function Get-FakeGuestReply($w, $req) {
    $o = [ordered]@{ schema = 1; phase = $req.phase; status = 'ok'; message = '' }
    if ($req.kind -eq 'scripts') { $o.scripts = @($req.script | ForEach-Object { $n, $s = $_.Split(' '); [ordered]@{ name = $n; sha256 = $s; exit_code = 0; seconds = 3 } }) }
    if ($req.kind -eq 'action' -and $req.action -eq 'deprovision') {
        $o.data = [ordered]@{ seal = [ordered]@{ checked = @('install-user-absent', 'no-password-hash', 'no-authorized-keys', 'no-ssh-host-keys', 'no-agent', 'no-cloud-state', 'no-build-sudoers', 'no-build-network'); findings = @(); unreadable = @() } }
    }
    if ($req.kind -eq 'action' -and $req.action -eq 'software-report-and-tests') { $o.data = [ordered]@{ report_exit = 0; tests_exit = 0 } }
    if ($req.kind -eq 'verify') {
        $disc = [ordered]@{}
        foreach ($k in 'gcc', 'gxx', 'clang', 'cmake', 'ninja', 'make', 'pkg_config', 'hello_gcc', 'hello_clang', 'pwsh', 'python3', 'docker_daemon', 'sudo_nopasswd', 'systemd_pid1', 'kernel_azure', 'job_user', 'post_generation') { $disc[$k] = $true }
        $o.data = [ordered]@{ upstream_tests = [ordered]@{ total = 1650; passed = 1640; failed = 0; skipped = 10 }; discovery = $disc
            facts = [ordered]@{ kernel = '6.17.0-1030-azure'; systemd_state = 'running'; root_mount_options = 'rw,relatime,discard,commit=30,data=writeback'; read_ahead_kb_root = '128' }
            inventory_sha256 = (Get-TextSha $w.InventoryText) }
    }
    return (ConvertTo-Json -InputObject $o -Depth 6 -Compress)
}

function New-FakeProvider($w) {
    # Ops resolve $w at call time from the calling test scope (the test names its world $w); no closures, so the helpers here stay visible.
    $p = @{}
    $p.TestRootTrust = { param($a) Add-FakeCall 'TestRootTrust' $a; if ($w.Untrusted.ContainsKey($a.Path)) { $w.Untrusted[$a.Path] } }
    $p.ExecFolders = { param($a) Add-FakeCall 'ExecFolders' $a; @($w.PythonDir) }
    $p.GetVolume = { param($a) Add-FakeCall 'GetVolume' $a; $g = Get-VolumeOf $w $a.Path; @{ Guid = $g; FreeBytes = $w.Free[$g] } }
    $p.MeasureBytes = { param($a) Add-FakeCall 'MeasureBytes' $a
        $leaf = Split-Path -Leaf $a.Path
        if ($w.Sizes.ContainsKey($leaf)) { return $w.Sizes[$leaf] }
        $w.MeasureCount++
        return (& $w.BuildDirBytes $w.MeasureCount) }
    $p.VerifyInputs = { param($a) Add-FakeCall 'VerifyInputs' $a; @{ Complete = $w.InputsComplete; Paths = @{ 'runner-images-7e7dc1b' = $w.SourceArchive; 'ubuntu-24.04.5-live-server' = $w.MediaPath }; Detail = 'fake' } }
    $p.NewBuildDisk = { param($a) Add-FakeCall 'NewBuildDisk' $a; [IO.File]::WriteAllText($a.Path, 'empty disk') }
    $p.NewDiffDisk = { param($a) Add-FakeCall 'NewDiffDisk' $a; [IO.File]::WriteAllText($a.Path, 'diff') }
    $p.NewSeedImage = { param($a) Add-FakeCall 'NewSeedImage' $a; $w.Seeds.Add([pscustomobject]@{ Path = $a.Path; Label = $a.Label; Files = $a.Files })
        [IO.File]::WriteAllText($a.Path, [string]$a.Files['user-data']) }
    $p.GetSwitch = { param($a) Add-FakeCall 'GetSwitch' $a; $w.Switch }
    $p.NewVm = { param($a) Add-FakeCall 'NewVm' $a; $w.Vms[$a.Name] = 'Off'; $w.VmIds[$a.Name] = [guid]::NewGuid().ToString(); @{ Id = $w.VmIds[$a.Name] } }
    $p.SetSeed = { param($a) Add-FakeCall 'SetSeed' $a; if ($w.Vms[$a.VmName] -ne 'Off') { throw 'fake: SetSeed on a VM that is not Off' }; $w.Seeded[$a.VmName] = $a.Path }
    $p.GetVmConfig = { param($a) Add-FakeCall 'GetVmConfig' $a; $w.VmConfig }
    # Hyper-V's read-back: the module's adapter (the shared fake, tampers applied) and any adapter the module did not make.
    $p.GetVmNetwork = { param($a) Add-FakeCall 'GetVmNetwork' $a
        @(Get-AapFakeHostNetworkAdapter -Root $w.NetRoot -VmId $a.VmId) + @($w.ForeignNics[$a.VmName] | Where-Object { $null -ne $_ }) }
    $p.AttachDisk = { param($a) Add-FakeCall 'AttachDisk' $a }
    $p.StartVm = { param($a) Add-FakeCall 'StartVm' $a; $w.Vms[$a.VmName] = 'Running' }
    $p.TypeBootCommand = { param($a) Add-FakeCall 'TypeBootCommand' $a }
    $p.WaitVmOff = { param($a) Add-FakeCall 'WaitVmOff' $a; if ($w.InstallOff) { $w.Vms[$a.VmName] = 'Off' }; $w.InstallOff }
    $p.RemoveDvds = { param($a) Add-FakeCall 'RemoveDvds' $a }
    $p.StopVm = { param($a) Add-FakeCall 'StopVm' $a; $w.Vms[$a.VmName] = 'Off' }
    $p.RemoveVm = { param($a) Add-FakeCall 'RemoveVm' $a; $w.Vms.Remove($a.Name) }
    $p.WaitGuestReady = { param($a) Add-FakeCall 'WaitGuestReady' $a
        if (@($w.Calls | Where-Object { $_.Op -eq 'InvokeGuest' -and $_.Args.Verb -eq 'reboot' }).Count -eq 0) { return $w.GuestReady }
        if ($w.ReadyAfterReboot -is [scriptblock]) { return (& $w.ReadyAfterReboot $w) }
        return $w.ReadyAfterReboot }
    $p.InvokeGuest = { param($a) Add-FakeCall 'InvokeGuest' $a
        switch ($a.Verb) {
            'ready' { 'ready' }
            'bootid' { if ($w.BootId) { & $w.BootId $w } else { '0b0b0b0b-1111-4222-8333-{0:d12}' -f @($w.Calls | Where-Object { $_.Op -eq 'InvokeGuest' -and $_.Args.Verb -eq 'reboot' }).Count } }
            'reboot' { 'rebooting' }
            'put' { $w.Puts.Add([pscustomobject]@{ Vm = $a.VmName; Name = $a.Name; HostPath = $a.InputPath }); 'stored' }
            'run' { $req = ConvertFrom-TestRequest $a.InputText; $req | Add-Member -NotePropertyName Vm -NotePropertyValue $a.VmName; $w.Requests.Add($req); & $w.Guest $w $req }
            default { throw "fake: unknown verb $($a.Verb)" }
        } }
    $p.ReceiveFile = { param($a) Add-FakeCall 'ReceiveFile' $a
        $text = switch -Wildcard ($a.Name) { 'job-inventory.json' { $w.InventoryText } 'scan.json' { if ($w.ScanText) { $w.ScanText } else { ConvertTo-Json -InputObject $w.ScanReport -Depth 6 -Compress } } default { $w.ReportText } }
        [IO.File]::WriteAllText($a.HostPath, $text, (New-Object Text.UTF8Encoding($false))) }
    $p.OptimizeDisk = { param($a) Add-FakeCall 'OptimizeDisk' $a }
    # A real read-only ACL, with this user in the place of Administrators: reruns and cleanup must cope with it.
    $p.SetReadOnlyAcl = { param($a) Add-FakeCall 'SetReadOnlyAcl' $a; $w.ReadOnly.Add($a.Path)
        $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        Set-AapReadOnlyAcl -Path $a.Path -Owner $me -Readers @($me) }
    $p.GetVmMemoryOverheadMib = { param($a) Add-FakeCall 'GetVmMemoryOverheadMib' $a; $w.MemOverheadMib }
    $p.CompareInventory = { param($a) Add-FakeCall 'CompareInventory' $a; Write-TestJson $w.CompareReport $a.Out; $w.CompareExit }
    return $p
}

function Get-VolumeOf($w, [string]$Path) {
    if ($Path.StartsWith((Join-Path $w.Root 'vol2'), 'OrdinalIgnoreCase')) { return $w.Guids.vol2 }
    if ($Path.StartsWith((Join-Path $w.Root 'vol3'), 'OrdinalIgnoreCase')) { return $w.Guids.vol3 }
    return $w.Guids.vol1
}
function Get-Ops($w, [string]$Op) { @($w.Calls | Where-Object { $_.Op -eq $Op }) }
function Add-FakeCall([string]$Op, $A) { $w.Calls.Add([pscustomobject]@{ Op = $Op; Args = $A }) }

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
