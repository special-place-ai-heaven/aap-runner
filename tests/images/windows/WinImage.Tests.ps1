# P06 Windows image builder. Pester 5 on Windows PowerShell 5.1 and PowerShell 7.
# Everything runs against a fake provider (WinImageTestHelpers.ps1): no VM, no Hyper-V cmdlet, no disk, ACL or network
# change on the host. Tags name the safety check each test guards; Invoke-AapWinMutations.ps1 disables each check in turn
# and requires its tagged tests to fail. $w is the fake world; the fake provider resolves it from the calling test scope.

BeforeDiscovery {
    . (Join-Path $PSScriptRoot 'WinImageTestHelpers.ps1')
    $script:Py = Find-TestPython
    $repo = Get-TestRepo
    $script:Validator = $(if ($env:AAP_P06_VALIDATOR) { $env:AAP_P06_VALIDATOR } else { Join-Path $repo 'parity\contracts\validate.py' })
    $schema = Get-Content -Raw -LiteralPath (Join-Path (Split-Path -Parent $script:Validator) 'image-catalog.schema.json') | ConvertFrom-Json
    $script:CanValidate = [bool]$script:Py -and $schema.properties.schema.const -eq 2
    $script:PhaseCases = @((Get-Content -Raw -LiteralPath (Join-Path $repo 'images\windows\build-plan.json') | ConvertFrom-Json).phases |
            Where-Object { $_.kind -ne 'restart' -and $_.action -notlike 'download-*' } | ForEach-Object { @{ Phase = $_.id } })
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'WinImageTestHelpers.ps1')
    Import-Module (Get-TestModulePath) -Force
    $script:Repo = Get-TestRepo
    $script:Py = Find-TestPython
    $script:Validator = $(if ($env:AAP_P06_VALIDATOR) { $env:AAP_P06_VALIDATOR } else { Join-Path $script:Repo 'parity\contracts\validate.py' })
    $script:Gen = 'win25-vs2026-x64/20261007.264.1-aap.1'

    function Invoke-Build { Invoke-AapWinImageBuild -Config $w.Config -Provider $w.Provider -Network $w.Network }
    function Assert-NothingStarted {
        (Get-Ops $w 'NewVm').Count | Should -Be 0
        (Get-Ops $w 'NewBuildDisk').Count | Should -Be 0
        Test-Path (Join-Path $w.Staging 'build\win25-vs2026-x64_20261007.264.1-aap.1') | Should -BeFalse
        Test-Path (Join-Path $w.Base 'win25-vs2026-x64\20261007.264.1-aap.1') | Should -BeFalse
    }
    function Assert-CleanedUp {
        $w.Vms.Count | Should -Be 0
        Test-Path (Join-Path $w.Staging 'build\win25-vs2026-x64_20261007.264.1-aap.1') | Should -BeFalse
        Test-Path (Join-Path $w.Base 'win25-vs2026-x64\20261007.264.1-aap.1') | Should -BeFalse
        Test-Path (Join-Path $w.Evidence 'P06\win25-vs2026-x64_20261007.264.1-aap.1\generation.json') | Should -BeFalse
    }
    function Set-GuestFault([string]$Phase, [scriptblock]$Reply) {
        $w | Add-Member -NotePropertyName FaultPhase -NotePropertyValue $Phase -Force
        $w | Add-Member -NotePropertyName FaultReply -NotePropertyValue $Reply -Force
        $w.Guest = { param($w, $req) if ($req.phase -eq $w.FaultPhase) { & $w.FaultReply $w $req } else { Get-FakeGuestReply $w $req } }
    }
    function Invoke-Validator([string]$Contract, $Object) {
        $f = Join-Path $w.Root "$Contract-$([guid]::NewGuid().ToString('n')).json"
        Write-TestJson $Object $f
        $out = & $script:Py -B -I $script:Validator $Contract $f 2>&1
        return [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($out -join "`n") }
    }
}

Describe 'build plan mirrors the pinned upstream template' {
    BeforeAll {
        $script:Plan = Get-Content -Raw -LiteralPath (Join-Path $script:Repo 'images\windows\build-plan.json') | ConvertFrom-Json
        $script:Scripts = @($script:Plan.phases | Where-Object { $_.kind -eq 'scripts' } | ForEach-Object { $_.scripts } | ForEach-Object { $_ })
    }
    It 'is exactly what the generator derives from the template (the script hashes and the archive pin come from the P03-staged archive, not from the repo)' {
        $tmp = Join-Path $TestDrive 'plan.json'
        $null = & (Join-Path $script:Repo 'images\windows\New-AapWinBuildPlan.ps1') -OutFile $tmp
        $regen = Get-Content -Raw $tmp | ConvertFrom-Json
        # What only -ScriptsDir/-SourceSha256 can produce is stripped from both sides: the script hashes, the archive
        # hash and the archive blocker (P03.1 pinned both in the committed plan). The skeleton must still match byte
        # for byte: phases, order, env, elevation, variables and baseline. The regen keeps the archive blocker.
        foreach ($p in @($regen.phases)) { if ($p.kind -eq 'scripts') { foreach ($s in $p.scripts) { $s.sha256 = $null } } }
        $regen.source.sha256 = $null
        $regen.blockers = @()
        $skeleton = Get-Content -Raw (Join-Path $script:Repo 'images\windows\build-plan.json') | ConvertFrom-Json
        foreach ($p in @($skeleton.phases)) { if ($p.kind -eq 'scripts') { foreach ($s in $p.scripts) { $s.sha256 = $null } } }
        $skeleton.source.sha256 = $null
        $skeleton.blockers = @()
        ($regen | ConvertTo-Json -Depth 12 -Compress) | Should -Be ($skeleton | ConvertTo-Json -Depth 12 -Compress)
    }
    It 'pins the build-commit template and locals by hash' {
        $script:Plan.baseline.template_sha256 | Should -Be (Get-FileSha (Join-Path $script:Repo ($script:Plan.baseline.template_path -replace '/', '\')))
        $script:Plan.baseline.template_path | Should -Match 'build-commit-aee0669'
        $script:Plan.baseline.locals_sha256 | Should -Be (Get-FileSha (Join-Path $script:Repo ($script:Plan.baseline.locals_path -replace '/', '\')))
        $script:Plan.baseline.inventory_sha256 | Should -Be (Get-FileSha (Join-Path $script:Repo ($script:Plan.baseline.inventory_path -replace '/', '\')))
        $script:Plan.baseline.runner_images_commit | Should -Be 'aee0669dd04510a11756664eb77f5630debabed3'
    }
    It 'has one phase per upstream provisioner, in order, with the six reboots' {
        $script:Plan.phases.Count | Should -Be 29
        @($script:Plan.phases | ForEach-Object { $_.upstream.block }) | Should -Be (1..29)
        $r = @($script:Plan.phases | Where-Object { $_.kind -eq 'restart' })
        $r.Count | Should -Be 6
        @($r | ForEach-Object { $_.id }) | Should -Be @('p09', 'p12', 'p14', 'p17', 'p20', 'p28')
        ($r | Where-Object { $_.id -eq 'p09' }).check | Should -Be 'wait-containers-feature'
        ($r | Where-Object { $_.id -eq 'p20' }).check | Should -Be 'wait-tiworker-idle'
        ($r | Where-Object { $_.id -eq 'p20' }).timeout_seconds | Should -Be 1800
    }
    It 'runs the build scripts in the order inputs.md lists them (81, LLVM in the elevated block of the build commit)' {
        $rows = @(Select-String -LiteralPath (Join-Path $script:Repo 'parity\baselines\windows-2025-vs2026-x64\inputs.md') -Pattern '^\| (\d+) \| `([A-Za-z0-9.-]+\.ps1)`' | ForEach-Object { $_.Matches[0].Groups[2].Value })
        $rows.Count | Should -Be 81
        @($script:Scripts | Where-Object { $_.dir -eq 'build' } | ForEach-Object { $_.name }) | Should -Be $rows
        $llvm = $script:Plan.phases | Where-Object { $_.kind -eq 'scripts' -and @($_.scripts.name) -contains 'Install-LLVM.ps1' }
        $llvm.elevated | Should -BeTrue
        $llvm.id | Should -Be 'p19'
    }
    It 'keeps elevation, exit 3010, pause, execution policy and environment of each upstream block' {
        $vs = $script:Plan.phases | Where-Object { $_.id -eq 'p13' }
        @($vs.scripts.name) | Should -Be @('Install-VisualStudio.ps1', 'Install-KubernetesTools.ps1')
        $vs.elevated | Should -BeTrue
        @($vs.valid_exit_codes) | Should -Be @(0, 3010)
        $vs.env.INSTALL_VS_2026 | Should -Be 'true'
        ($script:Plan.phases | Where-Object { $_.id -eq 'p15' }).pause_before_seconds | Should -Be 120
        ($script:Plan.phases | Where-Object { $_.id -eq 'p16' }).execution_policy | Should -Be 'remotesigned'
        ($script:Plan.phases | Where-Object { $_.id -eq 'p08' }).execution_policy | Should -Be 'unrestricted'
        ($script:Plan.phases | Where-Object { $_.id -eq 'p27' }).env.INSTALL_USER | Should -Be '${var.install_user}'
    }
    It 'runs the upstream tests and software report before sysprep, and sysprep last' {
        $ids = @($script:Plan.phases | ForEach-Object { if ($_.kind -eq 'action') { $_.action } elseif ($_.kind -eq 'scripts') { @($_.scripts.name)[-1] } else { 'restart' } })
        $ids.IndexOf('RunAll-Tests.ps1') | Should -BeLessThan $ids.IndexOf('assert-test-results')
        $ids.IndexOf('assert-test-results') | Should -BeLessThan $ids.IndexOf('software-report')
        $ids.IndexOf('Post-Build-Validation.ps1') | Should -BeLessThan $ids.IndexOf('sysprep-generalize')
        $ids[-1] | Should -Be 'sysprep-generalize'
    }
    It 'sizes the OS disk from the pinned upstream locals (150 GiB), not the 60 GiB Linux default' {
        $script:Plan.os_disk_gib | Should -Be 150
        $script:Plan.temp_disk_gib | Should -Be 150
        (Get-Content -Raw (Join-Path $script:Repo 'images\windows\AapWinImage.psm1')) | Should -Not -Match '\b60\b'
    }
    It 'pins every script hash of the committed plan, so the builder no longer refuses it with AAP_ScriptUnpinned' -Tag 'plan-unpinned' {
        @($script:Scripts | Where-Object { $null -eq $_.sha256 }).Count | Should -Be 0
        { Read-AapWinBuildPlan -Path (Join-Path $script:Repo 'images\windows\build-plan.json') } | Should -Not -Throw
    }
    It 'refuses a plan with one unpinned script and accepts it fully pinned' -Tag 'plan-unpinned' {
        $p = New-PinnedPlan (Join-Path $TestDrive 'pinned.json')
        { Read-AapWinBuildPlan -Path (Join-Path $TestDrive 'pinned.json') } | Should -Not -Throw
        $p.phases[7].scripts[3].sha256 = 'ABC'
        Write-TestJson $p (Join-Path $TestDrive 'one-bad.json')
        { Read-AapWinBuildPlan -Path (Join-Path $TestDrive 'one-bad.json') } | Should -Throw 'AAP_ScriptUnpinned*Install-WSL2.ps1*'
    }
    It 'names the source archive entry and pins its hash from the P03 manifest, so no blocker stays' {
        $m = Get-Content -Raw (Join-Path $script:Repo 'images\common\artifacts.manifest.json') | ConvertFrom-Json
        $e = @($m.entries | Where-Object { $_.name -eq 'runner-images-aee0669' })
        $e.Count | Should -Be 1
        $script:Plan.source.entry | Should -Be 'runner-images-aee0669'
        $script:Plan.source.sha256 | Should -Be $e[0].hash.value
        @($script:Plan.blockers) | Should -Be @()
    }
    It 'keeps the unwaivable archive blocker when the generator gets no hash, and drops it with one' {
        $gen = Join-Path $script:Repo 'images\windows\New-AapWinBuildPlan.ps1'
        $tmp = Join-Path $TestDrive 'pinned-source.json'
        $null = & $gen -OutFile $tmp
        $plain = Get-Content -Raw $tmp | ConvertFrom-Json
        @($plain.blockers | ForEach-Object { $_.id }) | Should -Be @('p06-upstream-source-archive')
        $null = & $gen -OutFile $tmp -SourceSha256 ('ab' * 32)
        $p = Get-Content -Raw $tmp | ConvertFrom-Json
        $p.source.sha256 | Should -Be ('ab' * 32)
        @($p.blockers) | Should -Be @()
        { & $gen -OutFile $tmp -SourceSha256 'ABC' } | Should -Throw 'AAP_PlanSource*'
    }
    It 'refuses a plan whose source is <Case>' -TestCases @(
        @{ Case = 'missing'; Edit = { param($p) $p.PSObject.Properties.Remove('source') } }
        @{ Case = 'an entry name that could be a path'; Edit = { param($p) $p.source.entry = '..\x' } }
        @{ Case = 'a hash that is not hex'; Edit = { param($p) $p.source.sha256 = 'ABC' } }) {
        $p = New-PinnedPlan (Join-Path $TestDrive 'src.json')
        & $Edit $p
        Write-TestJson $p (Join-Path $TestDrive 'src.json')
        { Read-AapWinBuildPlan -Path (Join-Path $TestDrive 'src.json') } | Should -Throw 'AAP_PlanInvalid*source*'
    }
    It 'lists every P03 Windows blocker, and none of its own: source and variables are pinned' {
        $b = @(Get-AapWinBlockers -Plan $script:Plan -ManifestPath (Join-Path $script:Repo 'images\common\artifacts.manifest.json'))
        $b | Should -Contain 'windows-server-2025-media'
        $b | Should -Contain 'visual-studio-2026-bootstrapper'
        $b | Should -Not -Contain 'p06-upstream-source-archive'
        $b | Should -Not -Contain 'p06-upstream-variables-unverified'
        $b | Should -Not -Contain 'azure-base-image-ubuntu-24.04'
    }
}

Describe 'storage record' {
    BeforeEach { $w = New-FakeWorld }
    AfterEach { Remove-World $w }
    It 'refuses to build without a storage document, before anything exists' -Tag 'storage-missing' {
        Remove-Item -LiteralPath $w.StoragePath
        $r = Invoke-Build
        $r.Status | Should -Be 'refused'
        $r.Reason | Should -Be 'AAP_StorageMissing'
        Assert-NothingStarted
    }
    It 'defaults the staging root to <base_root>\staging, also when staging_root is null' {
        $s = Read-AapStorageRecord -Path $w.StoragePath
        $s.Staging.Path | Should -Be (Join-Path $w.Base 'staging')
        $s.Staging.VolumeGuid | Should -Be $w.Guids.vol1
        $d = Get-Content -Raw $w.StoragePath | ConvertFrom-Json
        $d.roots | Add-Member -NotePropertyName staging_root -NotePropertyValue $null
        Write-TestJson $d $w.StoragePath
        (Read-AapStorageRecord -Path $w.StoragePath).Staging.Path | Should -Be (Join-Path $w.Base 'staging')
    }
    It 'refuses a storage document over 64 KiB' {
        [IO.File]::AppendAllText($w.StoragePath, (' ' * 70000))
        { Read-AapStorageRecord -Path $w.StoragePath } | Should -Throw 'AAP_StorageInvalid*64 KiB*'
    }
    It 'refuses root <Case>' -Tag 'storage-invalid' -TestCases @(
        @{ Case = 'UNC'; Path = '\\server\share\aap' }, @{ Case = 'relative'; Path = 'aap\base' }, @{ Case = 'drive root'; Path = 'X:\' },
        @{ Case = 'dotdot'; Path = 'X:\aap\..\base' }, @{ Case = 'reserved name'; Path = 'X:\aap\NUL' }, @{ Case = 'trailing dot'; Path = 'X:\aap.\base' },
        @{ Case = 'device path'; Path = '\\?\X:\aap' }, @{ Case = 'short name'; Path = 'X:\AAP~1\base' }, @{ Case = 'newline'; Path = "X:\aap`n" },
        @{ Case = 'COM0'; Path = 'X:\aap\COM0' }, @{ Case = 'aux with extension and space'; Path = 'X:\aap\aux .d' }, @{ Case = 'stream'; Path = 'X:\aap\base:s' },
        @{ Case = 'forward slash'; Path = 'X:/aap/base' }, @{ Case = 'trailing backslash'; Path = 'X:\aap\' }, @{ Case = 'the data folder'; Path = 'C:\ProgramData\aap-runner\scratch' },
        @{ Case = 'a parent of the data folder'; Path = 'C:\ProgramData' }, @{ Case = 'the Windows folder'; Path = (Join-Path $env:SystemRoot 'aap') }, @{ Case = 'C:\wsl'; Path = 'C:\wsl' }) {
        $d = Get-Content -Raw $w.StoragePath | ConvertFrom-Json
        $d.roots.scratch_root.path = $Path
        Write-TestJson $d $w.StoragePath
        { Read-AapStorageRecord -Path $w.StoragePath } | Should -Throw 'AAP_StorageInvalid*'
        (Invoke-Build).Reason | Should -Be 'AAP_StorageInvalid'
        Assert-NothingStarted
    }
    It 'refuses <Case>' -Tag 'storage-nesting' -TestCases @(@{ Case = 'a clone root inside base_root'; Sub = 'clones' }, @{ Case = 'a clone root equal to base_root'; Sub = '' }, @{ Case = 'an explicit staging root equal to the default'; Sub = 'staging' }) {
        $d = Get-Content -Raw $w.StoragePath | ConvertFrom-Json
        if ($Sub -eq 'staging') { $d.roots | Add-Member -NotePropertyName staging_root -NotePropertyValue ([pscustomobject]@{ path = (Join-Path $w.Base 'staging'); volume_guid = $w.Guids.vol1 }) }
        else { $d.roots.clone_root.path = $(if ($Sub) { Join-Path $w.Base $Sub } else { $w.Base }) }
        Write-TestJson $d $w.StoragePath
        { Read-AapStorageRecord -Path $w.StoragePath } | Should -Throw 'AAP_StorageInvalid*'
    }
    It 'refuses a missing tier, a low floor, a bad volume id and another schema' -Tag 'storage-invalid' {
        $good = Get-Content -Raw $w.StoragePath
        foreach ($mut in @({ param($d) $d.roots.PSObject.Properties.Remove('scratch_root') }, { param($d) $d.volume_floor_gib = 9 },
                { param($d) $d.roots.base_root.volume_guid = 'nope' }, { param($d) $d.schema = 1 })) {
            $d = $good | ConvertFrom-Json
            & $mut $d
            Write-TestJson $d $w.StoragePath
            { Read-AapStorageRecord -Path $w.StoragePath } | Should -Throw 'AAP_StorageInvalid*'
        }
    }
}

Describe 'root trust and volumes' {
    BeforeEach { $w = New-FakeWorld }
    AfterEach { Remove-World $w }
    It 'refuses when <Name> is not admin-only' -Tag 'root-untrusted' -TestCases @(@{ Name = 'base_root' }, @{ Name = 'staging' }, @{ Name = 'capacity' }) {
        $path = @{ base_root = $w.Base; staging = $w.Staging; capacity = $w.Capacity }[$Name]
        $w.Untrusted[$path] = @('owner S-1-5-21-1 is not trusted', 'Users may write')
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_StorageUntrusted'
        $r.Detail | Should -Match 'Users may write'
        Assert-NothingStarted
    }
    It 'refuses a root that is not on its recorded volume' -Tag 'volume-mismatch' {
        $d = Get-Content -Raw $w.StoragePath | ConvertFrom-Json
        $d.roots.base_root.volume_guid = $w.Guids.vol3
        $d.roots.clone_root.volume_guid = $w.Guids.vol3
        Write-TestJson $d $w.StoragePath
        (Invoke-Build).Reason | Should -Be 'AAP_StorageVolumeMismatch'
        Assert-NothingStarted
    }
    It 'the production provider refuses a user-owned folder with the real ACL rules (no Hyper-V call)' {
        Import-Module (Join-Path $script:Repo 'images\windows\AapWinImage.HyperV.psm1') -Force
        $p = New-AapWinHyperVProvider
        $mine = Join-Path $TestDrive 'mine'
        [void](New-Item -ItemType Directory $mine)
        @(& $p.TestRootTrust @{ Path = $mine }).Count | Should -BeGreaterThan 0
    }
    It 'the production provider checks images\common before it loads it, and does not load it when it is not admin-only' {
        Get-Module -All AapArtifact | Remove-Module -Force
        Import-Module (Join-Path $script:Repo 'images\windows\AapWinImage.HyperV.psm1') -Force
        $p = New-AapWinHyperVProvider
        $out = @(& $p.TestRootTrust @{ Path = $TestDrive })
        $out.Count | Should -BeGreaterThan 0
        foreach ($o in $out) { $o | Should -Match '^images\\common is not admin-only, so it was not loaded: ' }
        @(Get-Module -All AapArtifact).Count | Should -Be 0
    }
    It 'the production provider implements every op the builder calls' {
        Import-Module (Join-Path $script:Repo 'images\windows\AapWinImage.HyperV.psm1') -Force
        $p = New-AapWinHyperVProvider
        $want = @(Select-String -LiteralPath (Get-TestModulePath) -Pattern "Invoke-AapProvider \`$[A-Za-z.]*Provider '([A-Za-z]+)'" -AllMatches | ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $want.Count | Should -BeGreaterThan 20
        foreach ($op in $want) { $p[$op] | Should -BeOfType [scriptblock] -Because $op }
        @($w.Provider.Keys | Sort-Object) | Should -Be @($p.Keys | Sort-Object)
    }
}

Describe 'preflight refusals change nothing' {
    BeforeEach { $w = New-FakeWorld }
    AfterEach { Remove-World $w }
    It 'refuses unresolved input blockers and names them' -Tag 'blocked' {
        $w.Config.Waivers = @($w.Config.Waivers | Where-Object { $_.id -ne 'windows-updates-level' })
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_Blocked'
        $r.Detail | Should -Match 'windows-updates-level'
        Assert-NothingStarted
    }
    It 'refuses with no waivers at all' -Tag 'blocked' {
        $w.Config.Waivers = @()
        (Invoke-Build).Reason | Should -Be 'AAP_Blocked'
        Assert-NothingStarted
    }
    It 'refuses a waiver for an unknown blocker' {
        $w.Config.Waivers = @($w.Config.Waivers) + @(New-TestWaiver 'made-up' $w.Config.Waivers[0].plan_sha256)
        (Invoke-Build).Reason | Should -Be 'AAP_ConfigInvalid'
    }
    It 'refuses a waiver that is <Case>' -TestCases @(
        @{ Case = 'a bare id'; Edit = { param($x) 'windows-updates-level' } }
        @{ Case = 'without an approver'; Edit = { param($x) $x.Remove('approver'); $x } }
        @{ Case = 'without a rationale'; Edit = { param($x) $x.rationale = ''; $x } }
        @{ Case = 'carrying an extra field'; Edit = { param($x) $x.scope = 'all'; $x } }) {
        $i = [array]::IndexOf(@($w.Config.Waivers | ForEach-Object { $_.id }), 'windows-updates-level')
        $w.Config.Waivers[$i] = & $Edit $w.Config.Waivers[$i]
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_ConfigInvalid'
        $r.Detail | Should -Match 'approval record'
        Assert-NothingStarted
    }
    It 'refuses a waiver approved for another build plan' -Tag 'waiver' {
        ($w.Config.Waivers | Where-Object { $_.id -eq 'windows-updates-level' }).plan_sha256 = 'a' * 64
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_ConfigInvalid'
        $r.Detail | Should -Match 'windows-updates-level was approved for another build plan'
        Assert-NothingStarted
    }
    It 'refuses a waiver for <Id>, which only <Clearer> clears' -Tag 'unwaivable' -TestCases @(
        @{ Id = 'windows-server-2025-media'; Clearer = 'the media check' }
        @{ Id = 'p06-upstream-source-archive'; Clearer = 'a reviewed plan that pins the archive' }) {
        if ($Id -eq 'p06-upstream-source-archive') {
            Update-TestPlan $w { param($p) $p.blockers = @($p.blockers) + @([pscustomobject]@{ id = 'p06-upstream-source-archive'; reason = 'x'; owner_action = 'y' }) }
        }
        $w.Config.Waivers = @($w.Config.Waivers) + @(New-TestWaiver $Id $w.Config.Waivers[0].plan_sha256)
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_ConfigInvalid'
        $r.Detail | Should -Match "$Id cannot be waived"
        Assert-NothingStarted
    }
    It 'keeps the source archive blocker open while the plan carries it' -Tag 'blocked' {
        Update-TestPlan $w { param($p) $p.blockers = @($p.blockers) + @([pscustomobject]@{ id = 'p06-upstream-source-archive'; reason = 'x'; owner_action = 'y' }) }
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_Blocked'
        $r.Detail | Should -Be 'unresolved input blockers: p06-upstream-source-archive'
        Assert-NothingStarted
    }
    It 'builds with no waiver for the media: the media check against the pinned hash clears it' {
        @($w.Config.Waivers | ForEach-Object { $_.id }) | Should -Not -Contain 'windows-server-2025-media'
        (Invoke-Build).Status | Should -Be 'built'
    }
    It 'refuses an upstream archive that is not the one the plan pins: <Case>' -Tag 'source-pin' -TestCases @(
        @{ Case = 'no pinned hash'; Edit = { param($w) Update-TestPlan $w { param($p) $p.source.sha256 = $null } } }
        @{ Case = 'another pinned hash'; Edit = { param($w) Update-TestPlan $w { param($p) $p.source.sha256 = 'c' * 64 } } }
        @{ Case = 'other staged bytes'; Edit = { param($w) [IO.File]::WriteAllText($w.SourceZip, 'swapped archive') } }) {
        & $Edit $w
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_InputsUnverified'
        $r.Detail | Should -Match 'not the one the build plan pins'
        Assert-NothingStarted
    }
    It 'asks P03 for the archive the plan names, whatever the config says' {
        $w.Config.SourceEntry = 'evil-archive'
        (Invoke-Build).Status | Should -Be 'built'
        @((Get-Ops $w 'VerifyInputs')[0].Args.Names) | Should -Not -Contain 'evil-archive'
    }
    It 'refuses inputs P03 did not verify offline' -Tag 'inputs' {
        $w.InputsComplete = $false
        (Invoke-Build).Reason | Should -Be 'AAP_InputsUnverified'
        Assert-NothingStarted
        (Get-Ops $w 'VerifyInputs')[0].Args.Names | Should -Contain 'runner-images-aee0669'
    }
    It 'refuses media whose hash differs from the pin, or missing media' -Tag 'media' {
        $w.Config.MediaSha256 = 'f' * 64
        (Invoke-Build).Reason | Should -Be 'AAP_MediaMismatch'
        $w.Config.MediaSha256 = $w.MediaSha
        $w.Config.MediaFile = 'other.iso'
        (Invoke-Build).Reason | Should -Be 'AAP_MediaMismatch'
        Assert-NothingStarted
    }
    It 'refuses when the staging volume lacks room above its floor' -Tag 'disk-low' {
        $w.Free[$w.Guids.vol1] = [double](400 + 151 + 50 - 1) * 1073741824
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_DiskLow'
        Assert-NothingStarted
    }
    It 'counts staging and the published copy separately when they are on different volumes' -Tag 'disk-low' {
        Remove-World $w
        $w = New-FakeWorld -SeparateStaging
        $w.Free[$w.Guids.vol3] = [double](400 + 50) * 1073741824
        $w.Free[$w.Guids.vol1] = [double](151 + 50) * 1073741824
        (Invoke-Build).Status | Should -Be 'built'
        Remove-World $w
        $w = New-FakeWorld -SeparateStaging
        $w.Free[$w.Guids.vol1] = [double](151 + 50 - 1) * 1073741824
        (Invoke-Build).Reason | Should -Be 'AAP_DiskLow'
    }
    It 'refuses a generation id that already exists without its record' -Tag 'generation-exists' {
        [void](New-Item -ItemType Directory (Join-Path $w.Base 'win25-vs2026-x64\20261007.264.1-aap.1'))
        (Invoke-Build).Reason | Should -Be 'AAP_GenerationExists'
        (Get-Ops $w 'NewVm').Count | Should -Be 0
    }
    It 'refuses a config without <Key>' -TestCases @(@{ Key = 'MediaSha256' }, @{ Key = 'BuilderCommit' }, @{ Key = 'StagingGibMax' }, @{ Key = 'BaseGibMax' }, @{ Key = 'JobDiskGibMax' }) {
        $w.Config.Remove($Key)
        (Invoke-Build).Reason | Should -Be 'AAP_ConfigInvalid'
    }
    It 'refuses while another builder holds the same generation' {
        [void][IO.Directory]::CreateDirectory((Join-Path $w.Staging 'build'))
        $h = [IO.File]::Open((Join-Path $w.Staging 'build\win25-vs2026-x64_20261007.264.1-aap.1.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
        try { (Invoke-Build).Reason | Should -Be 'AAP_BuildBusy' } finally { $h.Dispose() }
    }
    It 'refuses a provider that lacks an op' {
        $w.Provider.Remove('SetReadOnlyAcl')
        (Invoke-Build).Reason | Should -Be 'AAP_ProviderInvalid'
    }
}

Describe 'a full build with fakes' {
    BeforeAll {
        $w = New-FakeWorld
        $script:W1 = $w
        $script:R = Invoke-Build
        $script:Rec = Get-Content -Raw -LiteralPath $script:R.RecordPath | ConvertFrom-Json
        $script:Bud = Get-Content -Raw -LiteralPath $script:R.BudgetPath | ConvertFrom-Json
        $script:Ev = Get-Content -Raw -LiteralPath $script:R.EvidencePath | ConvertFrom-Json
        $script:Pub = Join-Path $w.Base 'win25-vs2026-x64\20261007.264.1-aap.1\base.vhdx'
    }
    AfterAll { Remove-World $script:W1 }
    BeforeEach { $w = $script:W1 }
    It 'builds and publishes the generation' {
        $script:R.Status | Should -Be 'built'
        $script:R.Ok | Should -BeTrue
        $script:R.GenerationId | Should -Be $script:Gen
        Test-Path -LiteralPath $script:Pub | Should -BeTrue
    }
    It 'sends the guest every phase in upstream order, with reboots between them' {
        $order = @($w.Requests | Where-Object { $_.phase -ne 'verify' } | ForEach-Object { $_.phase } | Select-Object -Unique)
        $expected = @($w.Plan.phases | Where-Object { $_.kind -ne 'restart' -or $_.check_registry -or $_.check } | Where-Object { $_.kind -ne 'action' -or $_.action -notlike 'download-*' } | ForEach-Object { $_.id })
        $order | Should -Be $expected
        @(Get-Ops $w 'StopVm').Count | Should -Be 7   # six reboots and the seal
        $seq = @($w.Calls | Where-Object { $_.Op -in 'StopVm', 'InvokeGuest' } | ForEach-Object { if ($_.Op -eq 'StopVm') { 'R' } else { 'G' } }) -join ''
        $seq | Should -Match '^G{8}RG'
        @($w.Requests | Where-Object { $_.phase -eq 'p09' } | ForEach-Object { $_.action }) | Should -Be @('wait-no-pending-reboot', 'wait-containers-feature')
    }
    It 'sends each script phase with pinned hashes, resolved environment and its exit codes' {
        $p13 = $w.Requests | Where-Object { $_.phase -eq 'p13' }
        @($p13.scripts.name) | Should -Be @('Install-VisualStudio.ps1', 'Install-KubernetesTools.ps1')
        @($p13.valid_exit_codes) | Should -Be @(0, 3010)
        $p13.env.IMAGE_FOLDER | Should -Be 'C:\image'
        $p13.env.TEMP_DIR | Should -Be 'D:\temp'
        foreach ($q in @($w.Requests | Where-Object { $_.kind -eq 'scripts' })) {
            ($q.env | ConvertTo-Json -Compress) | Should -Not -Match '\$\{'
            foreach ($s in $q.scripts) { $s.sha256 | Should -Match '^[0-9a-f]{64}$' }
        }
    }
    It 'records the published bytes in a candidate image-catalog generation entry' {
        $script:Rec.generation_id | Should -Be $script:Gen
        $script:Rec.state | Should -Be 'candidate'
        $script:Rec.artifacts[0].path | Should -Be "$($script:Gen)/base.vhdx"
        $script:Rec.artifacts[0].sha256 | Should -Be (Get-FileSha $script:Pub)
        $script:Rec.artifacts[0].bytes | Should -Be (128 * 1073741824)
        $script:Rec.provenance.built_by_item | Should -Be 'P06'
        $script:Rec.provenance.inputs_manifest_sha256 | Should -Be (Get-FileSha (Join-Path $script:Repo 'images\common\artifacts.manifest.json'))
        $script:Rec.secret_scan.result | Should -Be 'clean'
        $script:Rec.secret_scan.evidence_ref | Should -Be 'evidence/P06/win25-vs2026-x64_20261007.264.1-aap.1/secret-scan.json'
        $script:Rec.baseline.inventory_sha256 | Should -Be 'cf842a07fd309da0100d955383883f9423bb2b7524e78bd33a67ecdcfc953f25'
        $script:Rec.certification.certificate_ref | Should -BeNullOrEmpty
    }
    It 'passes the contract validator as a lab catalog entry' -Skip:(-not $script:CanValidate) {
        $cat = [ordered]@{ schema = 2; revision = 1; scope = 'lab'; profiles = [ordered]@{ 'win25-vs2026-x64' = [ordered]@{ active = $null; rollback = $null }; 'ubuntu-24.04-x64' = [ordered]@{ active = $null; rollback = $null } }; generations = @($script:Rec) }
        $v = Invoke-Validator 'image-catalog' $cat
        $v.Code | Should -Be 0 -Because $v.Text
        $v = Invoke-Validator 'backend-lifecycle' $script:Bud
        $v.Code | Should -Be 0 -Because $v.Text
    }
    It 'writes a measured budget, not a default' {
        $script:Bud.measured | Should -BeTrue
        $script:Bud.base_gib | Should -Be 128
        $script:Bud.replacement_gib | Should -Be 128
        $script:Bud.clone_peak_gib | Should -Be 18
        $script:Bud.clone_gib_max | Should -Be 23
        $script:Bud.scratch_peak_gib | Should -Be 9
        $script:Bud.scratch_gib_max | Should -Be 12
        $script:Bud.staging_gib | Should -Be 40
        $script:Bud.boot_mem_overhead_mib | Should -Be 310
        $script:Bud.evidence_ref | Should -Be 'evidence/P06/win25-vs2026-x64_20261007.264.1-aap.1/build.json'
    }
    It 'records media, evaluation expiry, waivers, script hashes and the verification in the evidence' {
        $script:Ev.media.sha256 | Should -Be $w.MediaSha
        $script:Ev.media.edition | Should -Match 'Evaluation'
        $script:Ev.evaluation.days | Should -Be 180
        ([DateTime]$script:Ev.evaluation.expires_at - [DateTime]$script:Ev.evaluation.installed_at).TotalDays | Should -Be 180
        @($script:Ev.waivers | ForEach-Object { $_.id }) | Should -Contain 'windows-updates-level'
        @($script:Ev.waivers | ForEach-Object { $_.id }) | Should -Not -Contain 'windows-server-2025-media'
        @($script:Ev.waivers | ForEach-Object { $_.approver } | Sort-Object -Unique) | Should -Be @('chair (test)')
        @($script:Ev.phases | Where-Object { $_.kind -eq 'scripts' } | ForEach-Object { $_.scripts } | ForEach-Object { $_ }).Count | Should -Be 82
        $script:Ev.verify.upstream_tests.failed | Should -Be 0
        $script:Ev.verify.job_user | Should -Be 'runneradmin'
        $script:Ev.reports.'software-report.json' | Should -Be (Get-TextSha $w.ReportText)
    }
    It 'verifies in a fresh guest, a differencing child of the sealed disk, as the job user' {
        $diff = @(Get-Ops $w 'NewDiffDisk')
        $diff.Count | Should -Be 1
        $diff[0].Args.Parent | Should -Match 'os\.vhdx$'
        $tag = (Get-TextSha 'win25-vs2026-x64_20261007.264.1-aap.1').Substring(0, 8)
        @(Get-Ops $w 'NewVm' | ForEach-Object { $_.Args.Name }) | Should -Be @("aap-wbuild-$tag", "aap-wverify-$tag")
        @(Get-Ops $w 'NewVm' | ForEach-Object { "$($_.Args.Cpus)/$($_.Args.MemGib)" }) | Should -Be @('4/10', '4/10')
        $w.Unattend[1] | Should -Match '<Name>runneradmin</Name>'
        (Get-Ops $w 'WaitGuestReady' | Select-Object -Last 1).Args.User | Should -Be 'runneradmin'
    }
    It 'makes the published generation read-only and removes every build artifact' {
        $w.ReadOnly | Should -Contain $script:Pub
        $w.ReadOnly | Should -Contain (Split-Path -Parent $script:Pub)
        (Get-Item -LiteralPath $script:Pub).IsReadOnly | Should -BeTrue
        $w.Vms.Count | Should -Be 0
        Test-Path (Join-Path $w.Staging 'build\win25-vs2026-x64_20261007.264.1-aap.1') | Should -BeFalse
        @(Get-ChildItem -LiteralPath (Split-Path -Parent $script:Pub) -Force).Name | Should -Be @('base.vhdx')
    }
    It 'gives the build guest the declaration''s static addressing in its answer file, and the verification guest none' {
        $address = @(Get-Content -Raw (Join-Path $w.NetRoot 'released.json') | ConvertFrom-Json)[0]
        $address | Should -Match '^172\.31\.252\.\d+$'
        $u = $w.Unattend[0]
        $u | Should -Match ('<IpAddress wcm:action="add" wcm:keyValue="1">' + [regex]::Escape($address) + '/24</IpAddress>')
        $u | Should -Match '<NextHopAddress>172\.31\.252\.1</NextHopAddress>'
        $u | Should -Match '<IpAddress wcm:action="add" wcm:keyValue="1">192\.0\.2\.53</IpAddress>\s+<IpAddress wcm:action="add" wcm:keyValue="2">198\.51\.100\.53</IpAddress>'
        $u | Should -Match '<DhcpEnabled>false</DhcpEnabled>'
        $u | Should -Not -Match '<DhcpEnabled>true'
        $w.Unattend[1] | Should -Not -Match 'Microsoft-Windows-TCPIP|Microsoft-Windows-DNS-Client'
        @((Get-Ops $w 'ApplyWindowsImage')[0].Args.Files.Keys).Count | Should -Be 0
    }
    It 'creates both answer files with a random password and never autologon' {
        $w.Unattend.Count | Should -Be 2
        foreach ($u in $w.Unattend) {
            $x = [xml]$u
            $u | Should -Not -Match 'AutoLogon'
            $u | Should -Match '<SanPolicy>1</SanPolicy>'
            $x.unattend.settings[1].component[1].UserAccounts.LocalAccounts.LocalAccount.Password.Value | Should -Match '^.{32}$'
        }
        $w.Unattend[0] | Should -Match '<Name>installer</Name>'
    }
    It 'leaves no build or job password in any host file it wrote' {
        $pws = @($w.Unattend | ForEach-Object { ([xml]$_).unattend.settings[1].component[1].UserAccounts.LocalAccounts.LocalAccount.Password.Value })
        $pws[0] | Should -Not -Be $pws[1]
        foreach ($f in @(Get-ChildItem -LiteralPath $w.Root -Recurse -File | Where-Object { $_.FullName -notlike "$($w.Disk)*" })) {
            $t = [IO.File]::ReadAllText($f.FullName)
            foreach ($pw in $pws) { $t.Contains($pw) | Should -BeFalse -Because $f.FullName }
        }
    }
    It 'copies nothing into a guest but the runner, the request, the pinned sources and the verification files' {
        $sent = @(Get-ops $w 'SendFile' | ForEach-Object { Split-Path -Leaf $_.Args.HostPath } | Sort-Object -Unique)
        $sent | Should -Be @('hello.c', 'request.json', 'runner-images.zip', 'AapGuestVerify.ps1', 'windows.ps1' | Sort-Object)
        @((Get-Ops $w 'ApplyWindowsImage')[0].Args.CopyFiles.Keys) | Should -Be @('aap-build\AapGuestRunner.ps1')
    }
    It 'attaches the build VM before every power-on with the VM off, detaches it after removal, never attaches the verification VM, and addresses guests by VM id' {
        $build = $w.VmIds[@($w.VmIds.Keys | Where-Object { $_ -like 'aap-wbuild-*' })[0]]
        $verify = $w.VmIds[@($w.VmIds.Keys | Where-Object { $_ -like 'aap-wverify-*' })[0]]
        $ops = 'NewVm', 'GetVmConfig', 'NetAttach', 'WriteOfflineFiles', 'NetVerify', 'GetVmNetwork', 'StartVm', 'StopVm', 'RemoveVm', 'NetDetach'
        $seq = @($w.Calls | Where-Object { $_.Op -in $ops } | ForEach-Object { $_.Op }) -join ','
        $want = @(@('NewVm,GetVmConfig,NetAttach,WriteOfflineFiles,NetVerify,GetVmNetwork,StartVm') + @(1..6 | ForEach-Object { 'StopVm,NetAttach,NetVerify,GetVmNetwork,StartVm' }) +
            @('StopVm,RemoveVm,NetDetach', 'WriteOfflineFiles,NewVm,GetVmConfig,GetVmNetwork,StartVm,RemoveVm')) -join ','
        $seq | Should -Be $want
        foreach ($c in @(Get-Ops $w 'NetAttach') + @(Get-Ops $w 'NetVerify') + @(Get-Ops $w 'NetDetach')) {
            $c.Args.VmId | Should -Be $build; $c.Args.VmName | Should -BeLike 'aap-wbuild-*'; $c.Args.Profile | Should -Be 'windows'; $c.Args.Count | Should -Be 3
        }
        @(Get-Ops $w 'GetVmNetwork' | ForEach-Object { $_.Args.VmId } | Select-Object -Unique) | Should -Be @($build, $verify)
        @(Get-AapFakeHostNetworkRecord -Root $w.NetRoot).Count | Should -Be 0
        $ids = @($w.VmIds.Values)
        foreach ($op in 'InvokeGuest', 'SendFile', 'ReceiveFile', 'WaitGuestReady', 'StartVm', 'GetGuestBootTime') {
            @(Get-Ops $w $op).Count | Should -BeGreaterThan 0 -Because $op
            foreach ($c in @(Get-Ops $w $op)) { $ids | Should -Contain $c.Args.VmId -Because $op }
        }
    }
    It 'marks only the upstream elevated phases elevated in the guest requests' {
        @($w.Requests | Where-Object { $_.elevated } | ForEach-Object { $_.phase } | Select-Object -Unique) | Should -Be @('p07', 'p13', 'p19')
    }
    It 'records the plan, the inputs manifest, the builder commit and the guest registry check in the evidence' {
        $script:Ev.plan_sha256 | Should -Be (Get-FileSha $w.PlanPath)
        $script:Ev.inputs_manifest_sha256 | Should -Be $script:Rec.provenance.inputs_manifest_sha256
        $script:Ev.builder_commit | Should -Be $w.Config.BuilderCommit
        $script:Ev.switch | Should -Be 'aap-build-win'
        @($script:Ev.registry_check.checked) | Should -Be @('autologon-password', 'autologon-enabled', 'lsa-default-password')
        $scan = Get-Content -Raw (Join-Path (Split-Path -Parent $script:R.RecordPath) 'secret-scan.json') | ConvertFrom-Json
        @($scan.registry.checked).Count | Should -Be 3
        $scan.result | Should -Be 'clean'
    }
    It 'is idempotent: a second run reports unchanged and creates nothing' {
        $before = $w.Calls.Count
        $r2 = Invoke-Build
        $r2.Status | Should -Be 'unchanged'
        @($w.Calls | Select-Object -Skip $before | Where-Object { $_.Op -in 'NewVm', 'NewBuildDisk', 'ApplyWindowsImage' }).Count | Should -Be 0
    }
    It 'never contacts the network itself' {
        Mock -ModuleName AapWinImage Invoke-WebRequest { throw 'network' }
        Mock -ModuleName AapWinImage Invoke-RestMethod { throw 'network' }
        $w.Config.AapBuild = 7
        (Invoke-Build).Status | Should -Be 'built'
        Should -Invoke -ModuleName AapWinImage Invoke-WebRequest -Times 0 -Exactly
        Should -Invoke -ModuleName AapWinImage Invoke-RestMethod -Times 0 -Exactly
    }
}

Describe 'immutable generations' {
    BeforeEach { $w = New-FakeWorld }
    AfterEach { Remove-World $w }
    It 'refuses to rebuild an id whose published bytes changed' -Tag 'generation-exists' {
        (Invoke-Build).Status | Should -Be 'built'
        $f = Join-Path $w.Base 'win25-vs2026-x64\20261007.264.1-aap.1\base.vhdx'
        Unlock-TestPath $f; [IO.File]::SetAttributes($f, 'Normal'); [IO.File]::AppendAllText($f, 'tampered')
        (Invoke-Build).Reason | Should -Be 'AAP_GenerationExists'
    }
    It 'builds aap.2 beside aap.1 without touching it' {
        (Invoke-Build).Status | Should -Be 'built'
        $f = Join-Path $w.Base 'win25-vs2026-x64\20261007.264.1-aap.1\base.vhdx'
        $sha = Get-FileSha $f
        $w.Config.AapBuild = 2
        $r = Invoke-Build
        $r.Status | Should -Be 'built'
        $r.GenerationId | Should -Be 'win25-vs2026-x64/20261007.264.1-aap.2'
        Get-FileSha $f | Should -Be $sha
    }
}

Describe 'failures roll back' {
    BeforeEach { $w = New-FakeWorld }
    AfterEach { Remove-World $w }
    It 'a failed guest step at <Phase> removes the VM, the build disks and any partial generation' -Tag 'phase-failed', 'action-failed' -TestCases $script:PhaseCases {
        Set-GuestFault $Phase { param($w, $req)
            $o = @{ schema = 1; phase = $req.phase; status = 'failed'; message = 'injected' }
            if ($req.action -eq 'sysprep-generalize') { $o.data = Get-FakeRegistryData }
            ConvertTo-Json -Compress -Depth 6 $o }
        $r = Invoke-Build
        $r.Status | Should -Be 'failed'
        $r.Reason | Should -Be 'AAP_PhaseFailed'
        Assert-CleanedUp
        (Get-Ops $w 'RemoveVm').Count | Should -BeGreaterThan 0
    }
    It 'accepts exit 3010 where upstream does and nowhere else' -Tag 'exit-code' {
        $w.Guest = { param($w, $req)
            $o = ConvertFrom-Json (Get-FakeGuestReply $w $req)
            if ($req.kind -eq 'scripts') { $o.scripts[0].exit_code = 3010 }
            ConvertTo-Json $o -Depth 6 -Compress }
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_PhaseFailed'
        $r.Detail | Should -Match '^p08 Configure-WindowsDefender.ps1 exited 3010'
        Assert-CleanedUp
        $w.Guest = { param($w, $req)
            $o = ConvertFrom-Json (Get-FakeGuestReply $w $req)
            if ($req.phase -eq 'p13') { $o.scripts[0].exit_code = 3010 }
            ConvertTo-Json $o -Depth 6 -Compress }
        (Invoke-Build).Status | Should -Be 'built'
    }
    It 'refuses a guest that reports a script hash other than the pin' -Tag 'script-hash' {
        Set-GuestFault 'p18' { param($w, $req) $o = ConvertFrom-Json (Get-FakeGuestReply $w $req); $o.scripts[5].sha256 = 'a' * 64; ConvertTo-Json $o -Depth 6 -Compress }
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_ScriptHashMismatch'
        Assert-CleanedUp
    }
    It 'fails a script phase the guest reports as failed even when every script is listed with exit 0' -Tag 'phase-failed' {
        Set-GuestFault 'p15' { param($w, $req) $o = ConvertFrom-Json (Get-FakeGuestReply $w $req); $o.status = 'failed'; $o.message = 'post-script check failed'; ConvertTo-Json $o -Depth 6 -Compress }
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_PhaseFailed'
        $r.Detail | Should -Match 'post-script check failed'
        Assert-CleanedUp
    }
    It 'refuses a guest that ran fewer scripts than planned' {
        Set-GuestFault 'p18' { param($w, $req) $o = ConvertFrom-Json (Get-FakeGuestReply $w $req); $o.scripts = @($o.scripts | Select-Object -First 3); ConvertTo-Json $o -Depth 6 -Compress }
        (Invoke-Build).Reason | Should -Be 'AAP_PhaseFailed'
        Assert-CleanedUp
    }
    It 'treats a <Case> reply as hostile' -Tag 'hostile-size', 'hostile-shape', 'hostile-schema' -TestCases @(
        @{ Case = 'oversized'; Make = { param($ok) $ok + (' ' * 70000) } }
        @{ Case = 'non-ASCII'; Make = { param($ok) $ok.Replace('"message":""', ('"message":"' + [regex]::Unescape('\u202E') + '"')) } }
        @{ Case = 'two-object'; Make = { param($ok) $ok + "`n" + $ok } }
        @{ Case = 'extra-field'; Make = { param($ok) $ok.Replace('"status":"ok"', '"status":"ok","token":"x"') } }
        @{ Case = 'wrong-phase'; Make = { param($ok) $ok.Replace('"phase":"p11"', '"phase":"p12"') } }
        @{ Case = 'string-exit-code'; Make = { param($ok) $ok.Replace('"exit_code":0', '"exit_code":"0"') } }
        @{ Case = 'path-script-name'; Make = { param($ok) $ok.Replace('"name":"Install-Docker.ps1"', '"name":"..\\Install-Docker.ps1"') } }
        @{ Case = 'empty'; Make = { param($ok) '' } }
        @{ Case = 'not-json'; Make = { param($ok) '{ this is not json }' } }) {
        $w | Add-Member -NotePropertyName Make -NotePropertyValue $Make -Force
        Set-GuestFault 'p11' { param($w, $req) & $w.Make (Get-FakeGuestReply $w $req) }
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_HostileGuest'
        Assert-CleanedUp
    }
    It 'fails when the guest does not come back after a reboot' -Tag 'reboot-timeout' {
        $w.ReadyAfterRestart = { param($n) $n -lt 3 }
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_RebootTimeout'
        $r.Detail | Should -Match '^p14'
        Assert-CleanedUp
    }
    It 'refuses to publish a generation whose measured <What> exceeds the approved lab budget' -Tag 'budget-approved' -TestCases @(
        @{ What = 'base'; Leaf = 'os.vhdx'; Gib = 190 }, @{ What = 'clone peak'; Leaf = 'os.avhdx'; Gib = 40 }, @{ What = 'scratch peak'; Leaf = 'temp.vhdx'; Gib = 30 }) {
        $w.Sizes[$Leaf] = [double]$Gib * 1073741824
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_BudgetExceeded'
        Assert-CleanedUp
    }
    It 'stops when the build folder grows past StagingGibMax' -Tag 'budget' {
        $w.BuildDirBytes = { param($n) [double]($n * 30) * 1073741824 }
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_BudgetExceeded'
        Assert-CleanedUp
    }
    It 'refuses to publish an image whose secret scan finds the build password' -Tag 'secret-found', 'secret-known' {
        Set-GuestFault 'p29' { param($w, $req) ConvertTo-Json -Compress -Depth 6 @{ schema = 1; phase = $req.phase; status = 'ok'; message = ''; data = (Get-FakeRegistryData) } }
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_SecretFound'
        $r.Detail | Should -Match 'answer-file'
        $r.Detail | Should -Match 'build-credential'
        Assert-CleanedUp
        $scan = Get-Content -Raw (Join-Path $w.Evidence 'P06\win25-vs2026-x64_20261007.264.1-aap.1\secret-scan.json')
        $scan | Should -Match '"result":\s*"found"'
        $pw = ([xml]$w.Unattend[0]).unattend.settings[1].component[1].UserAccounts.LocalAccounts.LocalAccount.Password.Value
        $scan.Contains($pw) | Should -BeFalse
        $r.Detail.Contains($pw) | Should -BeFalse
    }
    It 'refuses to publish when a planted runner credential is in the image' -Tag 'secret-found' {
        [void][IO.Directory]::CreateDirectory((Join-Path $w.Disk 'actions-runner'))
        [IO.File]::WriteAllText((Join-Path $w.Disk 'actions-runner\.credentials'), '{}')
        (Invoke-Build).Reason | Should -Be 'AAP_SecretFound'
        Assert-CleanedUp
    }
    It 'fails verification when <Case>' -Tag 'verify' -TestCases @(
        @{ Case = 'an upstream test fails'; Edit = { param($o) $o.data.upstream_tests.failed = 2 } }
        @{ Case = 'no upstream test ran'; Edit = { param($o) $o.data.upstream_tests.total = 0 } }
        @{ Case = 'clang-cl is not discovered'; Edit = { param($o) $o.data.discovery.clang_cl = $false } }
        @{ Case = 'the resource compiler is not discovered'; Edit = { param($o) $o.data.discovery.resource_compile = $false } }
        @{ Case = 'the job user is not an administrator'; Edit = { param($o) $o.data.discovery.job_user_admin = $false } }) {
        $w | Add-Member -NotePropertyName Edit -NotePropertyValue $Edit -Force
        Set-GuestFault 'verify' { param($w, $req) $o = ConvertFrom-Json (Get-FakeGuestReply $w $req); & $w.Edit $o; ConvertTo-Json $o -Depth 6 -Compress }
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_VerifyFailed'
        Assert-CleanedUp
    }
    It 'fails verification when the fresh guest reports failure' -Tag 'verify-status' {
        Set-GuestFault 'verify' { param($w, $req) ConvertTo-Json -Compress @{ schema = 1; phase = 'verify'; status = 'failed'; message = 'RunAll-Tests missing' } }
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_VerifyFailed'
        $r.Detail | Should -Match 'RunAll-Tests missing'
        Assert-CleanedUp
    }
    It 'fails verification when the inventory differs from what the guest hashed' {
        Set-GuestFault 'verify' { param($w, $req) $o = ConvertFrom-Json (Get-FakeGuestReply $w $req); $o.data.inventory_sha256 = 'b' * 64; ConvertTo-Json $o -Depth 6 -Compress }
        (Invoke-Build).Reason | Should -Be 'AAP_VerifyFailed'
        Assert-CleanedUp
    }
    It 'refuses when the sealed disk changes during verification' -Tag 'base-changed' {
        $w.Provider.NewDiffDisk = { param($a) Add-FakeCall 'NewDiffDisk' $a; [IO.File]::WriteAllText($a.Path, 'diff'); [IO.File]::AppendAllText($a.Parent, 'written through') }
        (Invoke-Build).Reason | Should -Be 'AAP_BaseChanged'
        Assert-CleanedUp
    }
    It 'removes the partial generation when the published copy does not match' -Tag 'publish-hash' {
        Mock -ModuleName AapWinImage Get-AapSha256File { 'c' * 64 } -ParameterFilter { $Path -like '*.partial' }
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_PublishMismatch'
        Assert-CleanedUp
    }
}

Describe 'partial builds and safe deletion' {
    BeforeEach { $w = New-FakeWorld }
    AfterEach { Remove-World $w }
    It 'cleans a crashed build that had begun publishing, then builds' {
        $bd = Join-Path $w.Staging 'build\win25-vs2026-x64_20261007.264.1-aap.1'
        $gd = Join-Path $w.Base 'win25-vs2026-x64\20261007.264.1-aap.1'
        [void][IO.Directory]::CreateDirectory($bd); [void][IO.Directory]::CreateDirectory($gd)
        [IO.File]::WriteAllText((Join-Path $gd 'base.vhdx.partial'), 'half')
        [IO.File]::WriteAllText((Join-Path $bd 'os.vhdx'), 'old')
        Write-TestJson ([ordered]@{ schema = 1; status = 'running'; steps = [ordered]@{ publish = 'intent' } }) (Join-Path $bd 'state.json')
        $w.Vms['aap-wbuild-' + (Get-TextSha 'win25-vs2026-x64_20261007.264.1-aap.1').Substring(0, 8)] = 'Running'
        $r = Invoke-Build
        $r.PartialCleaned | Should -BeTrue
        $r.Status | Should -Be 'built'
        (Get-Ops $w 'Dismount' | Where-Object { $_.Args.Vhdx -eq (Join-Path $bd 'os.vhdx') }).Count | Should -BeGreaterThan 0
    }
    It 'keeps a finished generation when only the build folder survived a crash' {
        (Invoke-Build).Status | Should -Be 'built'
        $bd = Join-Path $w.Staging 'build\win25-vs2026-x64_20261007.264.1-aap.1'
        [void][IO.Directory]::CreateDirectory($bd)
        Write-TestJson ([ordered]@{ schema = 1; status = 'done'; steps = [ordered]@{ publish = 'done' } }) (Join-Path $bd 'state.json')
        $r = Invoke-Build
        $r.Status | Should -Be 'unchanged'
        $r.PartialCleaned | Should -BeTrue
        Test-Path (Join-Path $w.Base 'win25-vs2026-x64\20261007.264.1-aap.1\base.vhdx') | Should -BeTrue
        Test-Path $bd | Should -BeFalse
    }
    It 'removes a junction inside the build folder without following it' -Tag 'safe-delete' {
        $outside = Join-Path $w.Root 'outside'
        [void][IO.Directory]::CreateDirectory($outside)
        [IO.File]::WriteAllText((Join-Path $outside 'sentinel.txt'), 'keep')
        Set-GuestFault 'p05' { param($w, $req)
            [void](New-Item -ItemType Junction -Path (Join-Path $w.Staging 'build\win25-vs2026-x64_20261007.264.1-aap.1\link') -Target (Join-Path $w.Root 'outside'))
            ConvertTo-Json -Compress @{ schema = 1; phase = $req.phase; status = 'failed'; message = 'x' } }
        (Invoke-Build).Status | Should -Be 'failed'
        Test-Path (Join-Path $outside 'sentinel.txt') | Should -BeTrue
        Assert-CleanedUp
    }
    It 'refuses to delete through a linked folder or outside its root' -Tag 'safe-delete' {
        $real = Join-Path $w.Root 'real'
        [void][IO.Directory]::CreateDirectory((Join-Path $real 'x'))
        [IO.File]::WriteAllText((Join-Path $real 'x\keep.txt'), 'keep')
        $under = Join-Path $w.Root 'under'
        [void][IO.Directory]::CreateDirectory($under)
        [void](New-Item -ItemType Junction -Path (Join-Path $under 'j') -Target $real)
        { Remove-AapTree (Join-Path $under 'j\x') $under } | Should -Throw 'AAP_UnsafeDelete*'
        Test-Path (Join-Path $real 'x\keep.txt') | Should -BeTrue
        { Remove-AapTree $real $under } | Should -Throw 'AAP_UnsafeDelete*'
    }
}

Describe 'secret scan of the sealed disk' {
    BeforeEach {
        $w = New-FakeWorld
        $script:T = Join-Path $w.Root 'scan'
        [void][IO.Directory]::CreateDirectory((Join-Path $script:T 'Windows\System32'))
        [IO.File]::WriteAllText((Join-Path $script:T 'Windows\System32\ok.txt'), 'nothing to see')
    }
    AfterEach { Remove-World $w }
    It 'reports clean for a clean tree' {
        (Invoke-AapWinSecretScan -MountRoot $script:T -KnownSecret 'Pw-123456789').result | Should -Be 'clean'
    }
    It 'flags <File> by name' -TestCases @(
        @{ File = 'actions-runner\.credentials'; Rule = 'runner-credentials' }, @{ File = 'actions-runner\.credentials_rsaparams'; Rule = 'runner-credentials' }
        @{ File = 'actions-runner\.runner'; Rule = 'runner-config' }, @{ File = 'Windows\Panther\unattend.xml'; Rule = 'answer-file' }
        @{ File = 'autounattend.xml'; Rule = 'answer-file' }, @{ File = 'ProgramData\ssh\ssh_host_ed25519_key'; Rule = 'ssh-host-key' }
        @{ File = 'ProgramData\ssh\administrators_authorized_keys'; Rule = 'ssh-authorized-keys' }
        @{ File = 'Users\installer\AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt'; Rule = 'shell-history' }
        @{ File = 'Users\installer\AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine\Visual Studio Code Host_history.txt'; Rule = 'shell-history' }
        @{ File = 'etc\aap-runner\app.pem'; Rule = 'app-key' }) {
        $f = Join-Path $script:T $File
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $f))
        [IO.File]::WriteAllText($f, 'x')
        $s = Invoke-AapWinSecretScan -MountRoot $script:T
        $s.result | Should -Be 'found'
        @($s.findings.rule) | Should -Contain $Rule
    }
    It 'flags <Rule> by content and never records the value' -TestCases @(
        @{ Rule = 'pem-private-key'; Text = ('-----BEGIN ' + 'OPENSSH PRIVATE KEY-----' + "`nabc") }
        @{ Rule = 'github-token'; Text = ('token=' + 'ghs' + '_' + ('Q' * 36)) }
        @{ Rule = 'github-pat'; Text = ('github' + '_pat_' + ('R' * 30)) }
        @{ Rule = 'jit-config'; Text = ('ACTIONS_RUNNER_INPUT_' + 'JITCONFIG=abc') }
        @{ Rule = 'synthetic-marker'; Text = ('AAP-SYNTHETIC-' + 'SECRET-MARKER') }) {
        [IO.File]::WriteAllText((Join-Path $script:T 'Windows\leak.log'), $Text)
        $s = Invoke-AapWinSecretScan -MountRoot $script:T
        @($s.findings.rule) | Should -Contain $Rule
        (ConvertTo-Json $s -Depth 6).Contains($Text) | Should -BeFalse
    }
    It 'finds a known build credential in ASCII and UTF-16 text' -Tag 'secret-known' {
        $pw = New-AapWinPassword
        [IO.File]::WriteAllText((Join-Path $script:T 'a.log'), "x $pw y", [Text.Encoding]::ASCII)
        [IO.File]::WriteAllText((Join-Path $script:T 'b.log'), "x $pw y", [Text.Encoding]::Unicode)
        $s = Invoke-AapWinSecretScan -MountRoot $script:T -KnownSecret $pw
        @($s.findings | Where-Object { $_.rule -eq 'build-credential' }).Count | Should -Be 2
        (ConvertTo-Json $s -Depth 6).Contains($pw) | Should -BeFalse
    }
    It 'marks an unreadable folder incomplete and names it' -Tag 'scan-incomplete' {
        New-LockedDir (Join-Path $script:T 'Windows\Locked')
        $s = Invoke-AapWinSecretScan -MountRoot $script:T
        $s.result | Should -Be 'incomplete'
        @($s.unreadable) | Should -Contain 'Windows\Locked'
    }
    It 'skips only the reviewed SYSTEM-only folder at the volume root' {
        New-LockedDir (Join-Path $script:T 'System Volume Information')
        $s = Invoke-AapWinSecretScan -MountRoot $script:T
        $s.result | Should -Be 'clean'
        @($s.skipped) | Should -Be @('System Volume Information')
        New-LockedDir (Join-Path $script:T 'Windows\System Volume Information')
        (Invoke-AapWinSecretScan -MountRoot $script:T).result | Should -Be 'incomplete'
    }
    It 'lists files over the content limit with size and hash instead of skipping them' {
        $max = Get-ModuleVar 'ScanFileMaxBytes'
        try {
            Set-ModuleVar 'ScanFileMaxBytes' 16
            [IO.File]::WriteAllText((Join-Path $script:T 'Windows\big.bin'), ('z' * 100))
            $s = Invoke-AapWinSecretScan -MountRoot $script:T
            $s.result | Should -Be 'clean'
            $s.large_files_count | Should -Be 1
            $s.large_files[0].path | Should -Be 'Windows\big.bin'
            $s.large_files[0].bytes | Should -Be 100
            $s.large_files[0].sha256 | Should -Be (Get-FileSha (Join-Path $script:T 'Windows\big.bin'))
            [IO.File]::WriteAllText((Join-Path $script:T '.credentials'), ('z' * 100))
            (Invoke-AapWinSecretScan -MountRoot $script:T).result | Should -Be 'found'
        } finally { Set-ModuleVar 'ScanFileMaxBytes' $max }
    }
    It 'turns incomplete when there are more large files than the record lists' -Tag 'scan-incomplete' {
        $max = Get-ModuleVar 'ScanFileMaxBytes'; $list = Get-ModuleVar 'LargeFilesMax'
        try {
            Set-ModuleVar 'ScanFileMaxBytes' 16; Set-ModuleVar 'LargeFilesMax' 1
            foreach ($n in 'a.bin', 'b.bin') { [IO.File]::WriteAllText((Join-Path $script:T $n), ('z' * 100)) }
            $s = Invoke-AapWinSecretScan -MountRoot $script:T
            $s.result | Should -Be 'incomplete'
            $s.large_files_count | Should -Be 2
        } finally { Set-ModuleVar 'ScanFileMaxBytes' $max; Set-ModuleVar 'LargeFilesMax' $list }
    }
    It 'suppresses a finding only for the exact path and bytes on the allowlist' -Tag 'allowlist-exact' {
        $rel = 'Program Files\tool\test-data\key.pem'
        $f = Join-Path $script:T $rel
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $f))
        [IO.File]::WriteAllText($f, ('-----BEGIN ' + 'RSA PRIVATE KEY-----' + "`nabc"))
        $al = Join-Path $w.Root 'allow.json'
        Write-TestJson ([ordered]@{ schema = 1; entries = @([ordered]@{ path = $rel; sha256 = (Get-FileSha $f); justification = 'upstream test fixture, not a live key' }) }) $al
        $s = Invoke-AapWinSecretScan -MountRoot $script:T -AllowlistPath $al
        $s.result | Should -Be 'clean'
        $s.allowlisted[0].path | Should -Be $rel
        [IO.File]::AppendAllText($f, 'changed')
        $s = Invoke-AapWinSecretScan -MountRoot $script:T -AllowlistPath $al
        $s.result | Should -Be 'found'
        @($s.findings.rule) | Should -Contain 'pem-private-key'
    }
    It 'never allowlists the build credential' -Tag 'allowlist-exact' {
        $pw = New-AapWinPassword
        $f = Join-Path $script:T 'Windows\setup.log'
        [IO.File]::WriteAllText($f, "x $pw y")
        $al = Join-Path $w.Root 'allow.json'
        Write-TestJson ([ordered]@{ schema = 1; entries = @([ordered]@{ path = 'Windows\setup.log'; sha256 = (Get-FileSha $f); justification = 'an attempt to hide the build password' }) }) $al
        $s = Invoke-AapWinSecretScan -MountRoot $script:T -KnownSecret $pw -AllowlistPath $al
        @($s.findings.rule) | Should -Contain 'build-credential'
    }
    It 'fails on an allowlist entry that matches nothing' -Tag 'allowlist-stale' {
        $al = Join-Path $w.Root 'allow.json'
        Write-TestJson ([ordered]@{ schema = 1; entries = @([ordered]@{ path = 'gone\key.pem'; sha256 = ('a' * 64); justification = 'was a fixture once' }) }) $al
        $s = Invoke-AapWinSecretScan -MountRoot $script:T -AllowlistPath $al
        $s.result | Should -Be 'found'
        @($s.findings.rule) | Should -Be @('allowlist-mismatch')
    }
    It 'refuses an allowlist entry with <Case>' -Tag 'allowlist' -TestCases @(
        @{ Case = 'no justification'; Entry = [ordered]@{ path = 'a\b.pem'; sha256 = ('a' * 64) } }
        @{ Case = 'a wildcard'; Entry = [ordered]@{ path = 'a\*.pem'; sha256 = ('a' * 64); justification = 'every fixture key' } }
        @{ Case = 'an absolute path'; Entry = [ordered]@{ path = 'C:\a\b.pem'; sha256 = ('a' * 64); justification = 'a fixture key' } }
        @{ Case = 'a parent step'; Entry = [ordered]@{ path = 'a\..\b.pem'; sha256 = ('a' * 64); justification = 'a fixture key' } }
        @{ Case = 'an uppercase hash'; Entry = [ordered]@{ path = 'a\b.pem'; sha256 = ('A' * 64); justification = 'a fixture key' } }
        @{ Case = 'an extra field'; Entry = [ordered]@{ path = 'a\b.pem'; sha256 = ('a' * 64); justification = 'a fixture key'; rule = 'pem-private-key' } }) {
        $al = Join-Path $w.Root 'allow.json'
        Write-TestJson ([ordered]@{ schema = 1; entries = @($Entry) }) $al
        { Invoke-AapWinSecretScan -MountRoot $script:T -AllowlistPath $al } | Should -Throw 'AAP_AllowlistInvalid*'
    }
    It 'the committed allowlist is valid and empty' {
        @(Read-AapSecretAllowlist -Path (Join-Path $script:Repo 'images\windows\secret-allowlist.json')).Count | Should -Be 0
    }
    It 'does not follow a junction out of the mounted disk' {
        $out = Join-Path $w.Root 'elsewhere'
        [void][IO.Directory]::CreateDirectory($out)
        [IO.File]::WriteAllText((Join-Path $out '.credentials'), 'x')
        [void](New-Item -ItemType Junction -Path (Join-Path $script:T 'link') -Target $out)
        (Invoke-AapWinSecretScan -MountRoot $script:T).result | Should -Be 'clean'
    }
}

Describe 'budget record' {
    It 'refuses to write a budget from a size that was not measured' -Tag 'budget-measured' {
        $a = @{ GenerationId = $script:Gen; BaseBytes = 5GB; ClonePeakBytes = 1GB; ScratchPeakBytes = 1GB; StagingPeakBytes = 6GB; MemOverheadMib = 300; EvidenceRef = 'evidence/P06/x/build.json'; MeasuredAt = '2026-10-20T00:00:00Z' }
        { New-AapWinBudgetRecord @a } | Should -Not -Throw
        foreach ($k in 'BaseBytes', 'ClonePeakBytes', 'StagingPeakBytes') {
            $b = $a.Clone(); $b[$k] = 0
            { New-AapWinBudgetRecord @b } | Should -Throw 'AAP_BudgetUnmeasured*'
        }
    }
    It 'sets every cap at or above its measured peak' {
        $r = New-AapWinBudgetRecord -GenerationId $script:Gen -BaseBytes 130GB -ClonePeakBytes 21.5GB -ScratchPeakBytes 0 -StagingPeakBytes 290GB -MemOverheadMib 300 -EvidenceRef 'evidence/P06/x/build.json' -MeasuredAt '2026-10-20T00:00:00Z'
        $r.clone_gib_max | Should -BeGreaterOrEqual $r.clone_peak_gib
        $r.scratch_gib_max | Should -BeGreaterOrEqual $r.scratch_peak_gib
        $r.clone_peak_gib | Should -Be 22
        $r.scratch_peak_gib | Should -Be 0
    }
}

Describe 'answer file and passwords' {
    It 'escapes the password and parses back to it' {
        $pw = 'a<b&c>d"e''f' + (New-AapWinPassword)
        $x = [xml](New-AapWinUnattend -UserName 'installer' -Password $pw)
        $x.unattend.settings[1].component[1].UserAccounts.LocalAccounts.LocalAccount.Password.Value | Should -BeExactly $pw
        $x.unattend.settings[1].component[1].UserAccounts.LocalAccounts.LocalAccount.Group | Should -Be 'Administrators'
        $x.unattend.settings[0].component[1].TimeZone | Should -Be 'UTC'
        $x.OuterXml | Should -Not -Match 'AutoLogon|ProductKey'
    }
    It 'refuses a user name that could inject markup' {
        { New-AapWinUnattend -UserName 'a<b>' -Password 'x' } | Should -Throw 'AAP_UnattendInvalid*'
    }
    It 'makes distinct 32-character passwords with every character class' {
        $a = New-AapWinPassword; $b = New-AapWinPassword
        $a | Should -Not -Be $b
        foreach ($p in $a, $b) { $p.Length | Should -Be 32; $p | Should -MatchExactly '[A-Z]'; $p | Should -MatchExactly '[a-z]'; $p | Should -Match '[0-9]'; $p | Should -Match '[^A-Za-z0-9]' }
    }
}

Describe 'hostile guest disk: offline writes never follow guest-authored links' {
    BeforeEach {
        $w = New-FakeWorld
        $script:G = Join-Path $w.Root 'gdisk'
        $script:Out = Join-Path $w.Root 'outside'
        [void][IO.Directory]::CreateDirectory((Join-Path $script:G 'Windows\System32'))
        [void][IO.Directory]::CreateDirectory($script:Out)
        $script:Bytes = [Text.Encoding]::ASCII.GetBytes('<unattend/>')
    }
    AfterEach { Remove-World $w }
    It 'writes through plain folders and replaces a plain file' {
        [void][IO.Directory]::CreateDirectory((Join-Path $script:G 'Windows\Panther'))
        [IO.File]::WriteAllText((Join-Path $script:G 'Windows\Panther\unattend.xml'), 'old')
        Write-AapGuestFile -Root $script:G -RelPath 'Windows\Panther\unattend.xml' -Bytes $script:Bytes
        [IO.File]::ReadAllText((Join-Path $script:G 'Windows\Panther\unattend.xml')) | Should -Be '<unattend/>'
        Write-AapGuestFile -Root $script:G -RelPath 'aap-build\new\x.ps1' -Bytes $script:Bytes
        Test-Path (Join-Path $script:G 'aap-build\new\x.ps1') | Should -BeTrue
    }
    It 'refuses a junction at <Link> on the way and writes nothing through it' -Tag 'plain-path' -TestCases @(@{ Link = 'Windows\Panther' }, @{ Link = 'Windows' }) {
        if ($Link -eq 'Windows') { Remove-AapTree (Join-Path $script:G 'Windows') $script:G }
        [void](New-Item -ItemType Junction -Path (Join-Path $script:G $Link) -Target $script:Out)
        { Write-AapGuestFile -Root $script:G -RelPath 'Windows\Panther\unattend.xml' -Bytes $script:Bytes } | Should -Throw 'AAP_HostileGuest*'
        @(Get-ChildItem -LiteralPath $script:Out -Recurse -Force).Count | Should -Be 0
    }
    It 'refuses a <Case> where the file goes' -Tag 'guest-write' -TestCases @(@{ Case = 'junction' }, @{ Case = 'folder' }) {
        [void][IO.Directory]::CreateDirectory((Join-Path $script:G 'Windows\Panther'))
        $leaf = Join-Path $script:G 'Windows\Panther\unattend.xml'
        if ($Case -eq 'junction') { [void](New-Item -ItemType Junction -Path $leaf -Target $script:Out) } else { [void][IO.Directory]::CreateDirectory($leaf) }
        { Write-AapGuestFile -Root $script:G -RelPath 'Windows\Panther\unattend.xml' -Bytes $script:Bytes } | Should -Throw 'AAP_HostileGuest*'
        @(Get-ChildItem -LiteralPath $script:Out -Recurse -Force).Count | Should -Be 0
    }
    It 'refuses a guest path that climbs out of the disk' {
        { Write-AapGuestFile -Root $script:G -RelPath '..\outside\x.txt' -Bytes $script:Bytes } | Should -Throw 'AAP_HostileGuest*'
        { Write-AapGuestFile -Root $script:G -RelPath 'C:\x.txt' -Bytes $script:Bytes } | Should -Throw 'AAP_HostileGuest*'
    }
    It 'a build refuses the verification disk when the guest planted a junction at Windows\Panther' -Tag 'plain-path' {
        $outside = $script:Out
        $w | Add-Member -NotePropertyName Outside -NotePropertyValue $outside -Force
        Set-GuestFault 'p29' { param($w, $req)
            $reply = Get-FakeGuestReply $w $req
            Remove-AapTree (Join-Path $w.Disk 'Windows\Panther') $w.Disk
            [void](New-Item -ItemType Junction -Path (Join-Path $w.Disk 'Windows\Panther') -Target $w.Outside)
            $reply }
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_HostileGuest'
        @(Get-ChildItem -LiteralPath $outside -Recurse -Force).Count | Should -Be 0
        Assert-CleanedUp
    }
    It 'takes the Windows partition only from the layout the builder made' -Tag 'disk-layout' {
        $efi = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'; $msr = '{e3c9e316-0b5c-4db8-817d-f92df00215ae}'; $data = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
        $mk = { param($n, $t) [pscustomobject]@{ PartitionNumber = $n; GptType = $t; DriveLetter = $null } }
        (Select-AapWindowsPartition -Partitions @((& $mk 3 $data.ToUpperInvariant()), (& $mk 1 $efi), (& $mk 2 $msr))).PartitionNumber | Should -Be 3
        { Select-AapWindowsPartition -Partitions @((& $mk 1 $efi), (& $mk 2 $msr), (& $mk 3 $data), (& $mk 4 $data)) } | Should -Throw 'AAP_HostileGuest*'
        { Select-AapWindowsPartition -Partitions @((& $mk 1 $data), (& $mk 2 $msr), (& $mk 3 $efi)) } | Should -Throw 'AAP_HostileGuest*'
        { Select-AapWindowsPartition -Partitions @((& $mk 1 $efi), (& $mk 3 $data)) } | Should -Throw 'AAP_HostileGuest*'
        { Select-AapWindowsPartition -Partitions @((& $mk 1 $efi), (& $mk 2 $msr), (& $mk 4 $data)) } | Should -Throw 'AAP_HostileGuest*'
        { Select-AapWindowsPartition -Partitions @((& $mk 2 $efi), (& $mk 3 $msr), (& $mk 4 $data)) } | Should -Throw 'AAP_HostileGuest*'
        { Select-AapWindowsPartition -Partitions @((& $mk 2 $efi), (& $mk 1 $msr), (& $mk 3 $data)) } | Should -Throw 'AAP_HostileGuest*'
        { Select-AapWindowsPartition -Partitions @() } | Should -Throw 'AAP_HostileGuest*'
    }
    It 'the production provider finds the partition by layout and writes only through Write-AapGuestFile' {
        $t = Get-Content -Raw (Join-Path (Split-Path -Parent (Get-TestModulePath)) 'AapWinImage.HyperV.psm1')
        $t | Should -Match 'Select-AapWindowsPartition -Partitions'
        $t | Should -Not -Match 'WriteAllText|Copy-Item -LiteralPath \$a\.CopyFiles|Copy-Item[^\r\n]*-FromSession|reg(\.exe)?[''"]? load'
        @([regex]::Matches($t, 'Write-AapGuestFile -Root')).Count | Should -Be 3
    }
}

Describe 'network: the host network module, the build VM on its own switch, none for verification' {
    BeforeDiscovery {
        $script:ReadBackTampers = @('no-adapter', 'second-adapter', 'external-switch', 'other-switch', 'dhcp-guard-off', 'router-guard-off', 'mac-spoofing-on',
            'port-mirroring', 'vlan-trunk', 'storm-limit-off', 'legacy-acl', 'foreign-peer', 'drop-fixed-deny', 'drop-inbound-deny', 'scoped-deny', 'stateful-rule',
            'isolated-rule', 'no-source-pin', 'pin-above-deny', 'extra-allow' | ForEach-Object { @{ Tamper = $_ } })
        $script:HostTampers = @('public-host', 'host-empty', 'host-no-gateway', 'host-no-lan' | ForEach-Object { @{ Tamper = $_ } })
    }
    BeforeAll {
        function Assert-NotStarted {
            @(Get-Ops $w 'StartVm').Count | Should -Be 0
            Assert-CleanedUp
        }
        # Remove-BuildNetwork from the guest runner (the copy under test), defined here next to stand-ins for the cmdlets it
        # calls: functions win over cmdlets, so nothing touches this host's network. Returns what it did, in order.
        function Invoke-GuestRemoveBuildNetwork($Nics, [string]$Address, [switch]$Stuck) {
            $runner = Join-Path (Split-Path -Parent (Get-TestModulePath)) 'guest\AapGuestRunner.ps1'
            $ast = [Management.Automation.Language.Parser]::ParseFile($runner, [ref]$null, [ref]$null)
            $fn = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Remove-BuildNetwork' }, $true)
            $log = New-Object System.Collections.Generic.List[string]
            function Get-NetIPAddress { [CmdletBinding()] param($AddressFamily)
                @($Nics | Where-Object { $_.IPv4 } | ForEach-Object { [pscustomobject]@{ IPAddress = $_.IPv4; InterfaceIndex = $_.Index } }) }
            function Remove-NetRoute { [CmdletBinding(SupportsShouldProcess)] param($InterfaceIndex) $log.Add("route $InterfaceIndex") }
            function Remove-NetIPAddress { [CmdletBinding(SupportsShouldProcess)] param($InterfaceIndex, $AddressFamily)
                $log.Add("ip $InterfaceIndex"); if (-not $Stuck) { foreach ($n in $Nics) { if ($n.Index -eq $InterfaceIndex) { $n.IPv4 = $null } } } }
            function Set-NetIPInterface { [CmdletBinding()] param($InterfaceIndex, $Dhcp) $log.Add("dhcp $InterfaceIndex") }
            function Set-DnsClientServerAddress { [CmdletBinding()] param($InterfaceIndex, [switch]$ResetServerAddresses) $log.Add("dns $InterfaceIndex") }
            . ([scriptblock]::Create($fn.Extent.Text))
            Remove-BuildNetwork $Address
            , $log.ToArray()
        }
    }
    BeforeEach { $w = New-FakeWorld }
    AfterEach { Remove-World $w }
    It 'the production provider creates every VM without an adapter, never restarts one in place, and reads adapters back in the contract''s shape' {
        $t = Get-Content -Raw (Join-Path (Split-Path -Parent (Get-TestModulePath)) 'AapWinImage.HyperV.psm1')
        $t | Should -Match "'Guest Service Interface', 'Key-Value Pair Exchange'"
        $t | Should -Match 'Hyper-V\\Get-VMNetworkAdapter -VM \$vm \| Hyper-V\\Remove-VMNetworkAdapter'
        $t | Should -Not -Match 'Connect-VMNetworkAdapter|Add-VMNetworkAdapter|Set-VMNetworkAdapter|Restart-VM'
        $t | Should -Match 'MacAddressSpoofing = \[string\]\$n\.MacAddressSpoofing'
        $t | Should -Match 'VlanMode = \[string\]\$n\.VlanSetting\.OperationMode'
        $t | Should -Match 'LegacyAcls = @\(Hyper-V\\Get-VMNetworkAdapterAcl -VMNetworkAdapter \$n\)\.Count'
        $t | Should -Match 'Get-VMNetworkAdapter -All \| Where-Object \{ \$name -and -not \$_\.IsManagementOs'
        $t | Should -Match 'Weight = \$_\.Weight; Stateful = \[string\]\$_\.Stateful; IsolationId = \[string\]\$_\.IsolationID'
        $t | Should -Match 'AutomaticStartAction = \[string\]\$vm\.AutomaticStartAction; CheckpointType = \[string\]\$vm\.CheckpointType'
        $t | Should -Match 'Invoke-Command -VMId'
        $t | Should -Not -Match '-VMName'
    }
    It 'keeps no switch name or deny list of its own and imports the shared check only after supervisor\network passed the admin-only check' {
        $t = Get-Content -Raw (Get-TestModulePath)
        $t | Should -Not -Match 'aap-guests-win|DenyRanges|10\.0\.0\.0/8|GetSwitch|RestartVm'
        $imports = [regex]::Matches($t, 'Import-Module \$script:NetworkCheck')
        $imports.Count | Should -Be 1
        $imports[0].Index | Should -BeGreaterThan $t.IndexOf('# check:builder-untrusted')
    }
    It 'refuses to build without the P10.0 host network module' -Tag 'network-module' {
        $r = Invoke-AapWinImageBuild -Config $w.Config -Provider $w.Provider
        $r.Reason | Should -Be 'AAP_NetworkUnavailable'
        Assert-NothingStarted
    }
    It 'refuses a network module without <Op>' -TestCases @(@{ Op = 'Attach' }, @{ Op = 'Detach' }, @{ Op = 'Verify' }) {
        $w.Network.Remove($Op)
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_NetworkInvalid'
        $r.Detail | Should -Match $Op
        Assert-NothingStarted
    }
    It 'refuses a VM that reads back <Case>, before anything is attached' -Tag 'vm-config' -TestCases @(
        @{ Case = 'an automatic start action'; Edit = { param($w) $w.StartAction = 'StartIfRunning' } }
        @{ Case = 'checkpoints'; Edit = { param($w) $w.Checkpoints = 'Standard' } }) {
        & $Edit $w
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_VmUntrusted'
        @(Get-Ops $w 'NetAttach').Count | Should -Be 0
        Assert-NotStarted
    }
    It 'refuses a declaration the shared check rejects: <Case>' -Tag 'net-declaration' -TestCases @(
        @{ Case = 'an address outside the subnet'; Edit = { param($d) $d.address = '172.31.250.9' } }
        @{ Case = 'the gateway as address'; Edit = { param($d) $d.address = $d.gateway } }
        @{ Case = 'a private resolver nobody declared'; Edit = { param($d) $d.resolvers = @('192.168.1.1') } }
        @{ Case = 'another VM''s name'; Edit = { param($d) $d.vm_name = 'aap-wbuild-0badc0de' } }) {
        $w | Add-Member -NotePropertyName DeclEdit -NotePropertyValue $Edit -Force
        $w.Network.Attach = { param($a) Add-FakeCall 'NetAttach' $a; $d = & $w.NetFake.Attach $a; & $w.DeclEdit $d; $d }
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_NetworkInvalid'
        @(Get-Ops $w 'WriteOfflineFiles').Count | Should -Be 0
        Assert-NotStarted
        @(Get-AapFakeHostNetworkRecord -Root $w.NetRoot).Count | Should -Be 0
    }
    It 'refuses when the module''s Verify reports the tamper <Tamper>, and tears down: VM removed, then detached' -Tag 'network-verify' -TestCases ($script:ReadBackTampers + $script:HostTampers) {
        Set-AapFakeHostNetworkKnob -Root $w.NetRoot -Tamper $Tamper
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_NetworkUntrusted'
        $r.Detail | Should -Match '^Verify'
        Assert-NotStarted
        @(Get-AapFakeHostNetworkRecord -Root $w.NetRoot).Count | Should -Be 0
        $seq = @($w.Calls | Where-Object { $_.Op -in 'RemoveVm', 'NetDetach' } | ForEach-Object { $_.Op }) -join ','
        $seq | Should -BeLike '*RemoveVm,NetDetach'
    }
    It 'counts anything Verify writes as a problem: <Case>' -Tag 'network-verify' -TestCases @(
        @{ Case = 'a null'; Out = { $null } }, @{ Case = 'an empty line'; Out = { '' } }) {
        $w | Add-Member -NotePropertyName VerifyOut -NotePropertyValue $Out -Force
        $w.Network.Verify = { param($a) Add-FakeCall 'NetVerify' $a; & $w.VerifyOut }
        (Invoke-Build).Reason | Should -Be 'AAP_NetworkUntrusted'
        Assert-NotStarted
    }
    It 'reads the adapter back from Hyper-V even when Verify passes it: <Tamper>' -Tag 'net-readback' -TestCases $script:ReadBackTampers {
        Set-AapFakeHostNetworkKnob -Root $w.NetRoot -Tamper $Tamper
        $w.Network.Verify = { param($a) Add-FakeCall 'NetVerify' $a }   # a module that says nothing is wrong
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_NetworkUntrusted'
        $r.Detail | Should -Match '^read-back'
        Assert-NotStarted
        @(Get-AapFakeHostNetworkRecord -Root $w.NetRoot).Count | Should -Be 0
    }
    It 'refuses when the module fails: <Fault>' -TestCases @(
        @{ Fault = 'Attach' }, @{ Fault = 'AttachAfterIntent' }, @{ Fault = 'AttachAfterAct' }, @{ Fault = 'Verify' }) {
        Set-AapFakeHostNetworkKnob -Root $w.NetRoot -Fail $Fault
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_NetworkUntrusted'
        $r.Detail | Should -Match "^$(if ($Fault -eq 'Verify') { 'Verify' } else { 'Attach' }) threw"
        Assert-NotStarted
        @(Get-AapFakeHostNetworkRecord -Root $w.NetRoot).Count | Should -Be 0
    }
    It 'reports a Detach that fails (<Fault>) as a cleanup that did not prove the network detached, and the next run of the build id detaches' -Tag 'rerun-detach' -TestCases @(@{ Fault = 'Detach' }, @{ Fault = 'DetachAfterReleased' }) {
        Set-AapFakeHostNetworkKnob -Root $w.NetRoot -Fail $Fault
        $r = Invoke-Build
        $r.Status | Should -Be 'failed'
        $r.Reason | Should -Be 'AAP_NetworkUntrusted'
        $r.Detail | Should -Match '^Detach threw.*cleanup failed: AAP_NetworkUntrusted: the network is not proven detached: Detach threw'
        $w.Vms.Count | Should -Be 0
        $state = Get-Content -Raw (Join-Path $w.Staging 'build\win25-vs2026-x64_20261007.264.1-aap.1\state.json') | ConvertFrom-Json
        $state.vm_id | Should -Be $w.VmIds[@($w.VmIds.Keys | Where-Object { $_ -like 'aap-wbuild-*' })[0]]
        @(Get-AapFakeHostNetworkRecord -Root $w.NetRoot).Count | Should -Be 1
        Set-AapFakeHostNetworkKnob -Root $w.NetRoot
        $r = Invoke-Build
        $r.Status | Should -Be 'built'
        $r.PartialCleaned | Should -BeTrue
        @(Get-Ops $w 'NetDetach' | Where-Object { $_.Args.VmId -eq $state.vm_id }).Count | Should -BeGreaterThan 2
        @(Get-AapFakeHostNetworkRecord -Root $w.NetRoot).Count | Should -Be 0
    }
    It 'detaches a crashed run''s build VM by the id state.json took at NewVm, before anything was cleaned up' -Tag 'rerun-detach' {
        Set-GuestFault 'p05' { param($w, $req) throw 'the host died here' }
        $w.Provider.RemoveVm = { param($a) Add-FakeCall 'RemoveVm' $a; throw 'AAP_Unexpected: crashed' }   # no cleanup at all
        (Invoke-Build).Status | Should -Be 'failed'
        @(Get-AapFakeHostNetworkRecord -Root $w.NetRoot).Count | Should -Be 1
        $w.Provider.RemoveVm = { param($a) Add-FakeCall 'RemoveVm' $a; $w.Vms.Remove($a.Name) }
        $w.Guest = { param($w, $req) Get-FakeGuestReply $w $req }
        $old = $w.VmIds[@($w.VmIds.Keys | Where-Object { $_ -like 'aap-wbuild-*' })[0]]
        $w.Calls.Clear()
        $r = Invoke-Build
        $r.Status | Should -Be 'built'
        $seq = @($w.Calls | Where-Object { ($_.Op -eq 'NetDetach' -and $_.Args.VmId -eq $old) -or $_.Op -eq 'RemoveVm' } | ForEach-Object { $_.Op })
        ($seq[0..2] -join ',') | Should -Be 'RemoveVm,RemoveVm,NetDetach'
        @(Get-AapFakeHostNetworkRecord -Root $w.NetRoot).Count | Should -Be 0
    }
    It 'refuses to clean up an attached build VM without the network module' {
        Set-GuestFault 'p05' { param($w, $req) throw 'the host died here' }
        $w.Provider.RemoveVm = { param($a) Add-FakeCall 'RemoveVm' $a; throw 'AAP_Unexpected: crashed' }
        $null = Invoke-Build
        $w.Provider.RemoveVm = { param($a) Add-FakeCall 'RemoveVm' $a; $w.Vms.Remove($a.Name) }
        $names = Get-AapWinNames $w.Plan 1
        $storage = Read-AapStorageRecord -Path $w.StoragePath
        { Remove-AapWinBuild -Storage $storage -Provider $w.Provider -Names $names -EvidenceRoot $w.Evidence } | Should -Throw 'AAP_NetworkUnavailable*'
        Test-Path (Join-Path $w.Staging 'build\win25-vs2026-x64_20261007.264.1-aap.1\state.json') | Should -BeTrue
    }
    It 'refuses a re-Attach that declares other addressing than the answer file carries' -Tag 'net-unchanged' {
        $w | Add-Member -NotePropertyName AttachN -NotePropertyValue 0 -Force
        $w.Network.Attach = { param($a) Add-FakeCall 'NetAttach' $a; $d = & $w.NetFake.Attach $a; $w.AttachN++; if ($w.AttachN -eq 2) { $d.address = '172.31.252.200' }; $d }
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_NetworkInvalid'
        $r.Detail | Should -Match '^declaration changed: Attach now declares 172\.31\.252\.200 in '
        @(Get-Ops $w 'StartVm').Count | Should -Be 1
        Assert-CleanedUp
        @(Get-AapFakeHostNetworkRecord -Root $w.NetRoot).Count | Should -Be 0
    }
    It 're-checks the network while a stop waits for the build VM to go Off' {
        $null = Invoke-Build
        $build = $w.VmIds[@($w.VmIds.Keys | Where-Object { $_ -like 'aap-wbuild-*' })[0]]
        $stops = @(Get-Ops $w 'StopVm' | Where-Object { $_.Args.VmId -eq $build })
        $stops.Count | Should -Be 7
        foreach ($s in $stops) { $s.Args.Tick | Should -BeOfType [scriptblock] }
        $t = Get-Content -Raw (Join-Path (Split-Path -Parent (Get-TestModulePath)) 'AapWinImage.HyperV.psm1')
        $t | Should -Match 'Hyper-V\\Stop-VM -VM \(Get-AapVm \$a\) -Force -AsJob'
        $t | Should -Match 'Wait-AapVmOff -GetState \{ \(Get-AapVm \$a\)\.State \} -TimeoutSeconds \$a\.TimeoutSeconds -Tick \$a\.Tick'
    }
    It 'runs the re-check on every poll of a stop, outside any catch' -Tag 'stop-tick' {
        $script:polls = 0; $script:ticks = 0
        Wait-AapVmOff -GetState { $script:polls++; if ($script:polls -lt 4) { 'Running' } else { 'Off' } } -TimeoutSeconds 60 -PollSeconds 0 -Tick { $script:ticks++ } | Should -BeTrue
        $script:ticks | Should -Be 3
        { Wait-AapVmOff -GetState { 'Stopping' } -TimeoutSeconds 60 -PollSeconds 0 -Tick { throw 'AAP_NetworkUntrusted: re-check failed' } } | Should -Throw 'AAP_NetworkUntrusted: re-check failed'
    }
    It 'gives up on a VM that does not go Off' {
        Wait-AapVmOff -GetState { 'Running' } -TimeoutSeconds 1 -PollSeconds 0 | Should -BeFalse
    }
    It 'hands the re-check to every ready probe and asks a guest that does not answer yet again' {
        $script:seen = New-Object System.Collections.Generic.List[object]
        $tick = { $null = 1 }
        Wait-AapGuestReady -TimeoutSeconds 60 -PollSeconds 0 -Tick $tick -Probe { param($t) $script:seen.Add($t); if ($script:seen.Count -lt 3) { throw 'AAP_GuestUnreachable: not yet' }; 'ready' } | Should -BeTrue
        $script:seen.Count | Should -Be 3
        foreach ($s in $script:seen) { [object]::ReferenceEquals($s, $tick) | Should -BeTrue }
        $t = Get-Content -Raw (Join-Path (Split-Path -Parent (Get-TestModulePath)) 'AapWinImage.HyperV.psm1')
        $t | Should -Match 'Wait-AapGuestReady -TimeoutSeconds \$a\.TimeoutSeconds -Tick \$a\.Tick -Probe \{ param\(\$t\)'
        $t | Should -Match 'Invoke-AapGuestJob @\{ VmId = \$a\.VmId; User = \$a\.User; Password = \$a\.Password; Tick = \$t \}'
    }
    It 'ends the ready wait when the re-check inside a probe fails, instead of asking again' -Tag 'ready-network' {
        { Wait-AapGuestReady -TimeoutSeconds 2 -PollSeconds 0 -Probe { param($t) throw 'AAP_NetworkUntrusted: Verify: dhcp guard off' } } | Should -Throw 'AAP_NetworkUntrusted: Verify*'
    }
    It 'attaches and checks again with the VM off before a reboot, and refuses to start it on a problem' {
        Set-GuestFault 'p08' { param($w, $req) Set-AapFakeHostNetworkKnob -Root $w.NetRoot -Tamper 'dhcp-guard-off'; Get-FakeGuestReply $w $req }
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_NetworkUntrusted'
        @(Get-Ops $w 'NetAttach').Count | Should -Be 2
        @(Get-Ops $w 'StartVm').Count | Should -Be 1
        @($w.Calls | Where-Object { $_.Op -in 'StopVm', 'NetAttach' } | Select-Object -Last 2 | ForEach-Object { $_.Op }) | Should -Be @('StopVm', 'NetAttach')
        Assert-CleanedUp
    }
    It 'verifies again while the build VM runs and stops the build on a problem' -Tag 'net-poll' {
        Set-ModuleVar 'NetPollSeconds' 0
        Set-GuestFault 'p22' { param($w, $req) Set-AapFakeHostNetworkKnob -Root $w.NetRoot -Tamper 'public-host'; Get-FakeGuestReply $w $req }
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_NetworkUntrusted'
        $r.Detail | Should -Match '^Verify'
        @($w.Requests | ForEach-Object { $_.phase }) | Should -Not -Contain 'p24'
        Assert-CleanedUp
    }
    It 'refuses a verification VM with any network adapter, before it boots' -Tag 'verify-no-nic' {
        $w.VerifyHasNic = $true
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_NetworkUntrusted'
        $r.Detail | Should -Match 'aap-wverify-.* 1 network adapters, not 0'
        $verify = $w.VmIds[@($w.VmIds.Keys | Where-Object { $_ -like 'aap-wverify-*' })[0]]
        @(Get-Ops $w 'StartVm' | Where-Object { $_.Args.VmId -eq $verify }).Count | Should -Be 0
        Assert-CleanedUp
    }
    It 'refuses an answer-file network that is not a well-formed declaration: <Case>' -TestCases @(
        @{ Case = 'an address that is not IPv4'; Net = @{ address = 'fe80::1'; gateway = '172.31.252.1'; subnet = '172.31.252.0/24'; resolvers = @('192.0.2.53') } }
        @{ Case = 'markup in the gateway'; Net = @{ address = '172.31.252.2'; gateway = '172.31.252.1<x/>'; subnet = '172.31.252.0/24'; resolvers = @('192.0.2.53') } }
        @{ Case = 'no prefix length'; Net = @{ address = '172.31.252.2'; gateway = '172.31.252.1'; subnet = '172.31.252.0'; resolvers = @('192.0.2.53') } }
        @{ Case = 'three resolvers'; Net = @{ address = '172.31.252.2'; gateway = '172.31.252.1'; subnet = '172.31.252.0/24'; resolvers = @('192.0.2.53', '192.0.2.54', '192.0.2.55') } }) {
        { New-AapWinUnattend -UserName 'installer' -Password 'Aa1!aaaaaaaaaaaaaaaaaaaaaaaaaaaa' -Network $Net } | Should -Throw 'AAP_UnattendInvalid*network*'
    }
    It 'the build guest drops its static network before sysprep, given the declared build address' {
        $null = Invoke-Build
        $seal = @($w.Requests | Where-Object { $_.kind -eq 'action' -and $_.action -eq 'sysprep-generalize' })
        $seal.Count | Should -Be 1
        $seal[0].build_address | Should -Match '^172\.31\.252\.[0-9]{1,3}$'
        $w.Unattend[0].Contains("$($seal[0].build_address)/24") | Should -BeTrue
        $t = Get-Content -Raw (Join-Path (Split-Path -Parent (Get-TestModulePath)) 'guest\AapGuestRunner.ps1')
        $t.IndexOf("                Remove-BuildNetwork ([string](Get-Prop `$req 'build_address'))") | Should -BeGreaterThan 0
        $t.IndexOf('                Remove-BuildNetwork') | Should -BeLessThan $t.IndexOf("'System32\Sysprep\Sysprep.exe') /oobe")
    }
    It 'the build guest resets only the adapter that holds the build address; another adapter stays as it is' -Tag 'seal-build-nic' {
        $nics = @([pscustomobject]@{ Index = 4; IPv4 = '172.31.252.2' }, [pscustomobject]@{ Index = 7; IPv4 = '10.9.8.7' })
        $log = Invoke-GuestRemoveBuildNetwork $nics '172.31.252.2'
        @($log) | Should -Be @('route 4', 'ip 4', 'dhcp 4', 'dns 4')
        $nics[0].IPv4 | Should -BeNullOrEmpty
        $nics[1].IPv4 | Should -Be '10.9.8.7'
    }
    It 'the build guest refuses to seal while the build address is still configured' -Tag 'seal-no-address' {
        $nics = @([pscustomobject]@{ Index = 4; IPv4 = '172.31.252.2' })
        { Invoke-GuestRemoveBuildNetwork $nics '172.31.252.2' -Stuck } | Should -Throw '*build address 172.31.252.2 is still configured*'
    }
    It 'the build guest needs a build address, and touches nothing when no adapter holds it' {
        $nics = @([pscustomobject]@{ Index = 7; IPv4 = '10.9.8.7' })
        { Invoke-GuestRemoveBuildNetwork $nics '' } | Should -Throw '*no build address*'
        $log = Invoke-GuestRemoveBuildNetwork $nics '172.31.252.2'
        $log.Count | Should -Be 0
        $nics[0].IPv4 | Should -Be '10.9.8.7'
    }
}

Describe 'configuration cannot redirect the builder' {
    BeforeEach { $w = New-FakeWorld }
    AfterEach { Remove-World $w }
    It 'ignores plan, manifest and payload paths in the config' {
        $w.Config.PlanPath = Join-Path $script:Repo 'images\windows\build-plan.json'
        $w.Config.ManifestPath = Join-Path $w.Root 'nope.json'
        $w.Config.ProbeScript = Join-Path $w.Root 'evil.ps1'
        $w.Config.HelloC = Join-Path $w.Root 'evil.c'
        (Invoke-Build).Status | Should -Be 'built'
        @(Get-Ops $w 'SendFile' | Where-Object { $_.Args.HostPath -like '*evil*' }).Count | Should -Be 0
    }
    It 'refuses a plan whose image version could name a path' -Tag 'plan-version' {
        Update-TestPlan $w { param($p) $p.baseline.image_version = '..\..\x' }
        { Read-AapWinBuildPlan -Path $w.PlanPath } | Should -Throw 'AAP_PlanInvalid*image_version*'
        (Invoke-Build).Reason | Should -Be 'AAP_PlanInvalid'
        Assert-NothingStarted
    }
}

Describe 'evidence root and the builder''s own folders' {
    BeforeEach {
        $w = New-FakeWorld
        $script:Out = Join-Path $w.Root 'outside'
        [void][IO.Directory]::CreateDirectory($script:Out)
    }
    AfterEach { Remove-World $w }
    It 'refuses an evidence root that is not admin-only' -Tag 'root-untrusted' {
        $w.Untrusted[$w.Evidence] = @('Users may write')
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_StorageUntrusted'
        $r.Detail | Should -Match 'evidence root'
        Assert-NothingStarted
    }
    It 'refuses a junction at <Where> and writes nothing through it' -Tag 'plain-path' -TestCases @(
        @{ Where = 'evidence\P06'; Make = { param($w) Join-Path $w.Evidence 'P06' } }
        @{ Where = 'the build id evidence folder'; Make = { param($w) [void][IO.Directory]::CreateDirectory((Join-Path $w.Evidence 'P06')); Join-Path $w.Evidence 'P06\win25-vs2026-x64_20261007.264.1-aap.1' } }
        @{ Where = 'staging\build'; Make = { param($w) Join-Path $w.Staging 'build' } }
        @{ Where = 'the generation parent'; Make = { param($w) Join-Path $w.Base 'win25-vs2026-x64' } }) {
        [void](New-Item -ItemType Junction -Path (& $Make $w) -Target $script:Out)
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_StorageUntrusted'
        @(Get-ChildItem -LiteralPath $script:Out -Recurse -Force).Count | Should -Be 0
        (Get-Ops $w 'NewVm').Count | Should -Be 0
    }
    It 'refuses to run when <Which> is not admin-only' -Tag 'builder-untrusted' -TestCases @(
        @{ Which = 'its own folder'; Path = { Split-Path -Parent (Get-TestModulePath) } }
        @{ Which = 'images\common'; Path = { Join-Path (Split-Path -Parent (Get-TestModulePath)) '..\common' } }
        @{ Which = 'the guest scripts'; Path = { Join-Path (Split-Path -Parent (Get-TestModulePath)) 'guest' } }
        @{ Which = 'the P05 probe folder'; Path = { Split-Path -Parent (Get-ModuleVar 'ProbeScript') } }
        @{ Which = 'the hello.c folder'; Path = { Split-Path -Parent (Get-ModuleVar 'HelloC') } }
        @{ Which = 'supervisor\network'; Path = { Join-Path (Split-Path -Parent (Get-TestModulePath)) '..\..\supervisor\network' } }) {
        $w.Untrusted[[IO.Path]::GetFullPath((& $Path))] = @('Users may write')
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_BuilderUntrusted'
        Assert-NothingStarted
    }
}

Describe 'guest output is capped while it arrives' {
    BeforeEach { $w = New-FakeWorld }
    AfterEach { Remove-World $w }
    It 'drops an oversized software report and keeps no partial file' -Tag 'receive-size' {
        $max = Get-ModuleVar 'ReportMaxBytes'
        try {
            Set-ModuleVar 'ReportMaxBytes' 8
            $r = Invoke-Build
        } finally { Set-ModuleVar 'ReportMaxBytes' $max }
        $r.Reason | Should -Be 'AAP_HostileGuest'
        $r.Detail | Should -Match 'software-report.md'
        Assert-CleanedUp
        Test-Path (Join-Path $w.Evidence 'P06\win25-vs2026-x64_20261007.264.1-aap.1') | Should -BeFalse
    }
    It 'stops a job that sends more text than the cap' -Tag 'reply-cap' {
        $j = Start-Job { 1..100000 | ForEach-Object { 'x' * 100 } }
        { Receive-AapCappedJob -Job $j -MaxBytes 65536 -TimeoutSeconds 120 -PollSeconds 1 } | Should -Throw 'AAP_HostileGuest*over 65536 bytes*'
        @(Get-Job -Id $j.Id -ErrorAction SilentlyContinue).Count | Should -Be 0
    }
    It 'refuses an output object that is not text or bytes: <Case>' -Tag 'reply-type' -TestCases @(
        @{ Case = 'a property bag'; Body = { 1..20 | ForEach-Object { [pscustomobject]@{ big = 'A' * 102400 } } } }
        @{ Case = 'a string carrying an object note'; Body = { 'x' | Add-Member -NotePropertyName big -NotePropertyValue ([pscustomobject]@{ v = 'A' * 102400 }) -PassThru } }
        @{ Case = 'a number'; Body = { 42 } }) {
        $j = Start-Job -ScriptBlock $Body
        { Receive-AapCappedJob -Job $j -MaxBytes 1000 -TimeoutSeconds 120 -PollSeconds 1 } | Should -Throw 'AAP_HostileGuest*only text or bytes*'
    }
    It 'caps the number of <Stream> records, whose size it cannot measure' -Tag 'reply-records' -TestCases @(
        @{ Stream = 'error'; Body = { 1..20 | ForEach-Object { Write-Error -Message 'e' -TargetObject ('T' * 102400) } } }
        @{ Stream = 'warning'; Body = { 1..20 | ForEach-Object { Write-Warning 'w' } } }) {
        $j = Start-Job -ScriptBlock $Body
        { Receive-AapCappedJob -Job $j -MaxBytes 100000 -TimeoutSeconds 120 -PollSeconds 1 } | Should -Throw 'AAP_HostileGuest*over 16 stream records*'
    }
    It 'reports a failed call as unreachable, never as an empty answer' -Tag 'job-failed' {
        $j = Start-Job { throw 'the guest went down' }
        { Receive-AapCappedJob -Job $j -MaxBytes 1000 -TimeoutSeconds 120 -PollSeconds 1 } | Should -Throw 'AAP_GuestUnreachable*'
    }
    It 'the production provider talks to a guest only through capped jobs, file copies included' {
        $t = Get-Content -Raw (Join-Path (Split-Path -Parent (Get-TestModulePath)) 'AapWinImage.HyperV.psm1')
        $t | Should -Not -Match '-ToSession|-FromSession|New-PSSession'
        @([regex]::Matches($t, 'Invoke-Command')).Count | Should -Be 1
    }
    It 'fails the build, not silently, when receiving a guest file fails' {
        $w.Provider.ReceiveFile = { param($a) Add-FakeCall 'ReceiveFile' $a; throw 'AAP_GuestUnreachable: the guest call failed' }
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_GuestUnreachable'
        Assert-CleanedUp
    }
    It 'returns a small job''s output, byte chunks intact' -Tag 'reply-cap' {
        $j = Start-Job { 'line'; Write-Output -NoEnumerate ([byte[]](1, 2, 3)); Write-Warning 'w' }
        $o = Receive-AapCappedJob -Job $j -MaxBytes 1000 -TimeoutSeconds 120 -PollSeconds 1
        $o.Count | Should -Be 2
        $o[0] | Should -Be 'line'
        ($o[1] -is [byte[]]) | Should -BeTrue
        $o[1].Length | Should -Be 3
    }
    It 'stops waiting on the guest when the network re-check of its tick fails' -Tag 'receive-tick' {
        $j = Start-Job { Start-Sleep -Seconds 60 }
        { Receive-AapCappedJob -Job $j -MaxBytes 1000 -TimeoutSeconds 5 -PollSeconds 1 -Tick { throw 'AAP_NetworkUntrusted: re-check failed' } } | Should -Throw 'AAP_NetworkUntrusted: re-check failed'
    }
    It 'gives up on a job that never answers' {
        $j = Start-Job { Start-Sleep -Seconds 60 }
        { Receive-AapCappedJob -Job $j -MaxBytes 1000 -TimeoutSeconds 2 -PollSeconds 1 } | Should -Throw 'AAP_GuestTimeout*'
    }
}

Describe 'read-only ACLs on real files' {
    BeforeEach {
        $w = New-FakeWorld
        $script:Me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    }
    AfterEach { Remove-World $w }
    It 'sets the read-only ACL twice on a real file and folder, then still deletes them' -Tag 'acl-idempotent' {
        $d = Join-Path $w.Root 'gen'; [void][IO.Directory]::CreateDirectory($d)
        $f = Join-Path $d 'base.vhdx'; [IO.File]::WriteAllText($f, 'bytes')
        foreach ($i in 1, 2) {
            Set-AapReadOnlyAcl -Path $f -Owner $script:Me -Readers @($script:Me)
            Set-AapReadOnlyAcl -Path $d -Owner $script:Me -Readers @($script:Me)
        }
        (Get-Item -LiteralPath $f).IsReadOnly | Should -BeTrue
        $acl = Get-Acl -LiteralPath $f
        $acl.AreAccessRulesProtected | Should -BeTrue
        @($acl.Access | ForEach-Object { "$($_.FileSystemRights)" }) | Should -Be @('ReadAndExecute, Synchronize')
        { [IO.File]::AppendAllText($f, 'x') } | Should -Throw
        Remove-AapTree $d $w.Root
        Test-Path -LiteralPath $d | Should -BeFalse
    }
}

Describe 'evidence belongs to the run that wrote it' {
    BeforeEach { $w = New-FakeWorld; $script:Ev = Join-Path $w.Evidence 'P06\win25-vs2026-x64_20261007.264.1-aap.1' }
    AfterEach { Remove-World $w }
    It 'refuses an id whose evidence folder already exists, and leaves it alone' -Tag 'evidence-exists' {
        [void][IO.Directory]::CreateDirectory($script:Ev)
        [IO.File]::WriteAllText((Join-Path $script:Ev 'generation.json'), 'theirs')
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_GenerationExists'
        [IO.File]::ReadAllText((Join-Path $script:Ev 'generation.json')) | Should -Be 'theirs'
        Assert-NothingStarted
    }
    It 'a failure deletes the evidence it wrote, except the scan record' {
        Set-GuestFault 'verify' { param($w, $req) ConvertTo-Json -Compress @{ schema = 1; phase = 'verify'; status = 'failed'; message = 'x' } }
        (Invoke-Build).Reason | Should -Be 'AAP_VerifyFailed'
        @(Get-ChildItem -LiteralPath $script:Ev -Force | ForEach-Object { $_.Name }) | Should -Be @('secret-scan.json')
    }
    It 'cleans exactly the evidence files a crashed run listed' {
        $bd = Join-Path $w.Staging 'build\win25-vs2026-x64_20261007.264.1-aap.1'
        [void][IO.Directory]::CreateDirectory($bd); [void][IO.Directory]::CreateDirectory($script:Ev)
        foreach ($n in 'build.json', 'software-report.md', 'other.txt') { [IO.File]::WriteAllText((Join-Path $script:Ev $n), 'x') }
        Write-TestJson ([ordered]@{ schema = 1; status = 'running'; evidence_created = $true; written = @('build.json', 'software-report.md', '..\..\other.txt'); steps = [ordered]@{} }) (Join-Path $bd 'state.json')
        $r = Invoke-Build
        $r.PartialCleaned | Should -BeTrue
        $r.Reason | Should -Be 'AAP_GenerationExists'
        @(Get-ChildItem -LiteralPath $script:Ev | ForEach-Object { $_.Name }) | Should -Be @('other.txt')
    }
    It 'leaves a generation folder that appeared during the build to whoever made it' -Tag 'gen-race' {
        $w.Provider.NewDiffDisk = { param($a) Add-FakeCall 'NewDiffDisk' $a; [IO.File]::WriteAllText($a.Path, 'diff')
            $g = Join-Path $w.Base 'win25-vs2026-x64\20261007.264.1-aap.1'; [void][IO.Directory]::CreateDirectory($g); [IO.File]::WriteAllText((Join-Path $g 'theirs.txt'), 'x') }
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_GenerationExists'
        Test-Path (Join-Path $w.Base 'win25-vs2026-x64\20261007.264.1-aap.1\theirs.txt') | Should -BeTrue
    }
}

Describe 'measurement and reboots' {
    BeforeEach { $w = New-FakeWorld }
    AfterEach { Remove-World $w }
    It 'measures the build folder while the verification disks still exist' -Tag 'budget' {
        $w.BuildDirBytes = { param($n) if (@($w.Vms.Keys | Where-Object { $_ -like 'aap-wverify-*' }).Count) { [double]500 * 1073741824 } else { [double]40 * 1073741824 } }
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_BudgetExceeded'
        Assert-CleanedUp
    }
    It 'does not count a reboot until the guest boot time moves' -Tag 'reboot-proof' {
        Update-TestPlan $w { param($p) ($p.phases | Where-Object { $_.id -eq 'p09' }).timeout_seconds = 2 }
        $w.BootTime = { param($w) '630000000000000000' }
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_RebootTimeout'
        $r.Detail | Should -Match '^p09'
        Assert-CleanedUp
    }
    It 'keeps waiting while the guest does not answer its boot time, then counts the reboot' -Tag 'reboot-proof' {
        $w | Add-Member -NotePropertyName Blank -NotePropertyValue 2 -Force
        $w.BootTime = { param($w) $n = @($w.Calls | Where-Object { $_.Op -eq 'StopVm' }).Count
            if ($n -ge 1 -and $w.Blank -gt 0) { $w.Blank--; return '' }
            [string](630000000000000000 + $n) }
        (Invoke-Build).Status | Should -Be 'built'
        $w.Blank | Should -Be 0
    }
    It 'times out, not hostile, when the guest never answers its boot time after a reboot' -Tag 'reboot-proof' {
        Update-TestPlan $w { param($p) ($p.phases | Where-Object { $_.id -eq 'p09' }).timeout_seconds = 2 }
        $w.BootTime = { param($w) if (@($w.Calls | Where-Object { $_.Op -eq 'StopVm' }).Count -ge 1) { '' } else { '630000000000000000' } }
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_RebootTimeout'
        $r.Detail | Should -Match '^p09'
        Assert-CleanedUp
    }
    It 'treats a boot time that is not a tick count as hostile' {
        $w.BootTime = { param($w) 'soon' }
        (Invoke-Build).Reason | Should -Be 'AAP_HostileGuest'
        Assert-CleanedUp
    }
    It 'the production provider waits between polls and checks the VM by id' {
        $t = Get-Content -Raw (Join-Path (Split-Path -Parent (Get-TestModulePath)) 'AapWinImage.HyperV.psm1')
        $t | Should -Match 'Wait-AapGuestReady -TimeoutSeconds \$a\.TimeoutSeconds'
        (Get-Content -Raw (Get-TestModulePath)) | Should -Match '\[int\]\$PollSeconds = 15\)'
        $t | Should -Match 'LastBootUpTime'
    }
}

Describe 'registry check in the guest before sysprep' {
    BeforeEach { $w = New-FakeWorld }
    AfterEach { Remove-World $w }
    It 'refuses an image whose guest registry holds <Rule>' -Tag 'registry-secret' -TestCases @(@{ Rule = 'autologon-password' }, @{ Rule = 'autologon-enabled' }, @{ Rule = 'lsa-default-password' }) {
        $w | Add-Member -NotePropertyName Rule -NotePropertyValue $Rule -Force
        Set-GuestFault 'p29' { param($w, $req) $o = ConvertFrom-Json (Get-FakeGuestReply $w $req); $o.status = 'failed'; $o.data.registry.findings = @($w.Rule); ConvertTo-Json $o -Depth 6 -Compress }
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_SecretFound'
        $r.Detail | Should -Match $Rule
        Assert-CleanedUp
    }
    It 'refuses when the guest could not check the LSA secret' -Tag 'registry-incomplete' {
        Set-GuestFault 'p29' { param($w, $req) $o = ConvertFrom-Json (Get-FakeGuestReply $w $req); $o.data.registry.checked = @('autologon-password', 'autologon-enabled'); $o.data.registry.unreadable = @('lsa-default-password'); ConvertTo-Json $o -Depth 6 -Compress }
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_ScanIncomplete'
        $r.Detail | Should -Match 'lsa-default-password'
        Assert-CleanedUp
    }
    It 'refuses when the guest checked every rule but reports one unreadable' -Tag 'registry-incomplete' {
        Set-GuestFault 'p29' { param($w, $req) $o = ConvertFrom-Json (Get-FakeGuestReply $w $req); $o.data.registry.unreadable = @('autologon-enabled'); ConvertTo-Json $o -Depth 6 -Compress }
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_ScanIncomplete'
        $r.Detail | Should -Match 'autologon-enabled'
        Assert-CleanedUp
    }
    It 'treats a sysprep reply with <Case> as hostile' -TestCases @(
        @{ Case = 'no registry check'; Edit = { param($o) $o.PSObject.Properties.Remove('data') } }
        @{ Case = 'an unknown rule'; Edit = { param($o) $o.data.registry.checked = @('autologon-password', 'autologon-enabled', 'lsa-default-password', 'other') } }
        @{ Case = 'an extra field'; Edit = { param($o) $o.data.registry | Add-Member -NotePropertyName value -NotePropertyValue 'x' } }) {
        $w | Add-Member -NotePropertyName Edit -NotePropertyValue $Edit -Force
        Set-GuestFault 'p29' { param($w, $req) $o = ConvertFrom-Json (Get-FakeGuestReply $w $req); & $w.Edit $o; ConvertTo-Json $o -Depth 6 -Compress }
        (Invoke-Build).Reason | Should -Be 'AAP_HostileGuest'
        Assert-CleanedUp
    }
    It 'the guest runs the check as SYSTEM, disables the install user and skips sysprep on a finding' {
        $t = Get-Content -Raw (Join-Path (Split-Path -Parent (Get-TestModulePath)) 'guest\AapGuestRunner.ps1')
        $t | Should -Match "Invoke-AsTask 'SYSTEM' 'ServiceAccount' ""-RegistryCheck"
        $t | Should -Match 'HKLM:\\SECURITY\\Policy\\Secrets\\DefaultPassword'
        $t | Should -Match 'Disable-LocalUser -Name \$u'
        $t | Should -Match "sysprep not run"
    }
}

Describe 'elevated phases' {
    It 'marks exactly the upstream elevated blocks (bcdedit, Visual Studio, LLVM) as elevated' {
        $plan = Get-Content -Raw -LiteralPath (Join-Path $script:Repo 'images\windows\build-plan.json') | ConvertFrom-Json
        @($plan.phases | Where-Object { $_.PSObject.Properties['elevated'] -and $_.elevated } | ForEach-Object { $_.id }) | Should -Be @('p07', 'p13', 'p19')
    }
    It 'the guest runs an elevated request as a highest-privilege S4U task of the install user' {
        $t = Get-Content -Raw (Join-Path (Split-Path -Parent (Get-TestModulePath)) 'guest\AapGuestRunner.ps1')
        $t | Should -Match 'New-ScheduledTaskPrincipal -UserId \$UserId -LogonType \$LogonType -RunLevel Highest'
        $t | Should -Match "Invoke-AsTask \(\[string\]\`$vars.install_user\) 'S4U'"
        $t | Should -Match "exit ``\`$LastExitCode"
    }
}

Describe 'guest script order and plan variables' {
    BeforeEach { $w = New-FakeWorld }
    AfterEach { Remove-World $w }
    It 'refuses a guest that ran the planned scripts in another order' -Tag 'script-order' {
        Set-GuestFault 'p18' { param($w, $req) $o = ConvertFrom-Json (Get-FakeGuestReply $w $req); $a = $o.scripts[0]; $o.scripts[0] = $o.scripts[1]; $o.scripts[1] = $a; ConvertTo-Json $o -Depth 6 -Compress }
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_PhaseFailed'
        $r.Detail | Should -Match '^p18 script 0'
        Assert-CleanedUp
    }
    It 'refuses a phase environment with an unresolved variable' -Tag 'plan-variable' {
        Update-TestPlan $w { param($p) $p.phases[7].env | Add-Member -NotePropertyName AAP_X -NotePropertyValue '${var.nope}' }
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_PlanInvalid'
        $r.Detail | Should -Match 'p08 AAP_X'
        Assert-CleanedUp
    }
}

Describe 'source rules for everything P06 authors' {
    BeforeAll {
        $all = @(Get-ChildItem -LiteralPath (Join-Path $script:Repo 'images\windows'), (Join-Path $script:Repo 'tests\images\windows') -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psm1' })
        $script:Files = @($all | Where-Object { $_.Name -ne 'WinImage.Tests.ps1' })   # this file names the patterns it bans
        $script:Product = @($all | Where-Object { $_.FullName -notlike '*\tests\images\windows\*' })
        $script:AllFiles = $all
        $script:AvPattern = '(?i)' + (@('Invoke-' + 'Expression', '\biex\b', '-Encoded' + 'Command', 'FromBase64' + 'String', 'SecureStringTo' + 'BSTR', 'PtrToString' + 'Auto',
                'PtrToString' + 'BSTR', '\[char\]\s*\d', 'Add-Type\s+-Type' + 'Definition', '-Member' + 'Definition') -join '|')
    }
    It 'never downloads: no web cmdlet, client, socket or package fetch in the builder or guest code' {
        foreach ($f in $script:Product) {
            (Get-Content -Raw $f.FullName) | Should -Not -Match '(?i)Invoke-WebRequest|Invoke-RestMethod|WebClient|HttpClient|Start-BitsTransfer|DownloadFile|Net\.Sockets|\bcurl\b|\bwget\b|bitsadmin|Install-Module|Save-Module|Install-PackageProvider' -Because $f.Name
        }
        (Get-Content -Raw (Join-Path $script:Repo 'images\windows\AapWinImage.HyperV.psm1')) | Should -Match 'Invoke-AapManifest -Manifest \$m -StagingRoot \$a\.StagingRoot -Name \$a\.Names -Offline'
    }
    It 'compiles nothing: no Add-Type in the elevated builder, only named framework assemblies loaded in the guest' {
        foreach ($f in $script:Product) {
            $lines = @(Get-Content $f.FullName | Where-Object { $_ -match '(?i)\bAdd-Type\b' })
            if ($f.FullName -like '*\images\windows\guest\*') {
                foreach ($l in $lines) { $l | Should -Match '^\s*Add-Type -AssemblyName System(\.[A-Za-z]+)+\s*$' -Because $f.Name }
            } else { $lines.Count | Should -Be 0 -Because $f.Name }
        }
    }
    It 'never builds a SecureString from plain text' {
        foreach ($f in $script:Product) { (Get-Content -Raw $f.FullName) | Should -Not -Match '(?i)AsPlainText' -Because $f.Name }
    }
    It 'uses none of the patterns the host AV flags' {
        foreach ($f in $script:Files) {
            (Get-Content -Raw $f.FullName) | Should -Not -Match $script:AvPattern -Because $f.Name
        }
    }
    It 'starts every child process without a window' {
        foreach ($f in $script:Files) {
            foreach ($line in @(Get-Content $f.FullName | Where-Object { $_ -match 'Start-Process ' -and $_ -notmatch '^\s*#' })) { $line | Should -Match '-NoNewWindow|-WindowStyle Hidden' -Because $f.Name }
            foreach ($line in @(Get-Content $f.FullName | Where-Object { $_ -match 'UseShellExecute\s*=' })) { $line | Should -Match '\$false' }
        }
    }
    It 'is plain ASCII, so Windows PowerShell 5.1 reads it as written and no bidi control hides in it' {
        foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $script:Repo 'images\windows'), (Join-Path $script:Repo 'tests\images\windows') -Recurse -File)) {
            @([IO.File]::ReadAllBytes($f.FullName) | Where-Object { $_ -gt 127 }).Count | Should -Be 0 -Because $f.Name
        }
    }
    It 'parses on this PowerShell host' {
        foreach ($f in $script:AllFiles) {
            $errors = $null
            [void][Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors)
            @($errors).Count | Should -Be 0 -Because $f.Name
        }
    }
}
