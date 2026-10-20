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

    function Invoke-Build { Invoke-AapWinImageBuild -Config $w.Config -Provider $w.Provider }
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
    It 'is exactly what the generator derives from the template' {
        $tmp = Join-Path $TestDrive 'plan.json'
        $null = & (Join-Path $script:Repo 'images\windows\New-AapWinBuildPlan.ps1') -OutFile $tmp
        (Get-Content -Raw $tmp | ConvertFrom-Json | ConvertTo-Json -Depth 12 -Compress) | Should -Be ($script:Plan | ConvertTo-Json -Depth 12 -Compress)
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
    It 'refuses the committed plan until every script hash is pinned' -Tag 'plan-unpinned' {
        @($script:Scripts | Where-Object { $null -ne $_.sha256 }).Count | Should -Be 0
        { Read-AapWinBuildPlan -Path (Join-Path $script:Repo 'images\windows\build-plan.json') } | Should -Throw 'AAP_ScriptUnpinned*'
    }
    It 'refuses a plan with one unpinned script and accepts it fully pinned' -Tag 'plan-unpinned' {
        $p = New-PinnedPlan (Join-Path $TestDrive 'pinned.json')
        { Read-AapWinBuildPlan -Path (Join-Path $TestDrive 'pinned.json') } | Should -Not -Throw
        $p.phases[7].scripts[3].sha256 = 'ABC'
        Write-TestJson $p (Join-Path $TestDrive 'one-bad.json')
        { Read-AapWinBuildPlan -Path (Join-Path $TestDrive 'one-bad.json') } | Should -Throw 'AAP_ScriptUnpinned*Install-WSL2.ps1*'
    }
    It 'lists every P03 Windows blocker plus its own' {
        $b = @(Get-AapWinBlockers -Plan $script:Plan -ManifestPath (Join-Path $script:Repo 'images\common\artifacts.manifest.json'))
        $b | Should -Contain 'windows-server-2025-media'
        $b | Should -Contain 'visual-studio-2026-bootstrapper'
        $b | Should -Contain 'p06-upstream-source-archive'
        $b | Should -Contain 'p06-upstream-variables-unverified'
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
        $w.Config.Waivers = @($w.Config.Waivers | Where-Object { $_ -ne 'windows-updates-level' })
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
        $w.Config.Waivers = @($w.Config.Waivers) + 'made-up'
        (Invoke-Build).Reason | Should -Be 'AAP_ConfigInvalid'
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
    It 'refuses a config without <Key>' -TestCases @(@{ Key = 'MediaSha256' }, @{ Key = 'BuilderCommit' }, @{ Key = 'StagingGibMax' }, @{ Key = 'SourceEntry' }, @{ Key = 'BaseGibMax' }, @{ Key = 'JobDiskGibMax' }) {
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
        (Get-Ops $w 'RestartVm').Count | Should -Be 6
        $seq = @($w.Calls | Where-Object { $_.Op -in 'RestartVm', 'InvokeGuest' } | ForEach-Object { if ($_.Op -eq 'RestartVm') { 'R' } else { 'G' } }) -join ''
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
        @($script:Ev.waived_blockers) | Should -Contain 'windows-server-2025-media'
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
        [IO.File]::SetAttributes($f, 'Normal'); [IO.File]::AppendAllText($f, 'tampered')
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
        Set-GuestFault $Phase { param($w, $req) ConvertTo-Json -Compress @{ schema = 1; phase = $req.phase; status = 'failed'; message = 'injected' } }
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
        Set-GuestFault 'p29' { param($w, $req) ConvertTo-Json -Compress @{ schema = 1; phase = $req.phase; status = 'ok'; message = '' } }
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
        (Invoke-AapWinSecretScan -MountRoot $script:T -Provider $w.Provider -KnownSecret 'Pw-123456789').result | Should -Be 'clean'
    }
    It 'flags <File> by name' -TestCases @(
        @{ File = 'actions-runner\.credentials'; Rule = 'runner-credentials' }, @{ File = 'actions-runner\.credentials_rsaparams'; Rule = 'runner-credentials' }
        @{ File = 'actions-runner\.runner'; Rule = 'runner-config' }, @{ File = 'Windows\Panther\unattend.xml'; Rule = 'answer-file' }
        @{ File = 'autounattend.xml'; Rule = 'answer-file' }, @{ File = 'ProgramData\ssh\ssh_host_ed25519_key'; Rule = 'ssh-host-key' }
        @{ File = 'ProgramData\ssh\administrators_authorized_keys'; Rule = 'ssh-authorized-keys' }
        @{ File = 'Users\installer\AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt'; Rule = 'shell-history' }
        @{ File = 'etc\aap-runner\app.pem'; Rule = 'app-key' }) {
        $f = Join-Path $script:T $File
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $f))
        [IO.File]::WriteAllText($f, 'x')
        $s = Invoke-AapWinSecretScan -MountRoot $script:T -Provider $w.Provider
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
        $s = Invoke-AapWinSecretScan -MountRoot $script:T -Provider $w.Provider
        @($s.findings.rule) | Should -Contain $Rule
        (ConvertTo-Json $s -Depth 6).Contains($Text) | Should -BeFalse
    }
    It 'finds a known build credential in ASCII and UTF-16 text' -Tag 'secret-known' {
        $pw = New-AapWinPassword
        [IO.File]::WriteAllText((Join-Path $script:T 'a.log'), "x $pw y", [Text.Encoding]::ASCII)
        [IO.File]::WriteAllText((Join-Path $script:T 'b.log'), "x $pw y", [Text.Encoding]::Unicode)
        $s = Invoke-AapWinSecretScan -MountRoot $script:T -Provider $w.Provider -KnownSecret $pw
        @($s.findings | Where-Object { $_.rule -eq 'build-credential' }).Count | Should -Be 2
        (ConvertTo-Json $s -Depth 6).Contains($pw) | Should -BeFalse
    }
    It 'flags autologon and LSA default password values in the offline registry' {
        $w.Registry['SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\DefaultPassword'] = 'x'
        $w.Registry['SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\AutoAdminLogon'] = '1'
        $w.Registry['SECURITY\Policy\Secrets\DefaultPassword\'] = 'present'
        $s = Invoke-AapWinSecretScan -MountRoot $script:T -Provider $w.Provider
        @($s.findings.rule | Sort-Object) | Should -Be @('autologon-enabled', 'autologon-password', 'lsa-default-password')
    }
    It 'does not follow a junction out of the mounted disk' {
        $out = Join-Path $w.Root 'elsewhere'
        [void][IO.Directory]::CreateDirectory($out)
        [IO.File]::WriteAllText((Join-Path $out '.credentials'), 'x')
        [void](New-Item -ItemType Junction -Path (Join-Path $script:T 'link') -Target $out)
        (Invoke-AapWinSecretScan -MountRoot $script:T -Provider $w.Provider).result | Should -Be 'clean'
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
