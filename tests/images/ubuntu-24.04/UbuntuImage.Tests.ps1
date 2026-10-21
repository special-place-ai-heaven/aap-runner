# P07 Ubuntu 24.04 image builder. Pester 5 on Windows PowerShell 5.1 and PowerShell 7.
# Everything runs against a fake provider (UbuntuImageTestHelpers.ps1): no VM, no Hyper-V cmdlet, no disk, ACL, socket or
# network change on the host. Tags name the safety check each test guards; Invoke-AapUbuntuMutations.ps1 disables each check
# in turn and requires its tagged tests to fail. $w is the fake world; the fake provider resolves it from the calling test scope.

BeforeDiscovery {
    . (Join-Path $PSScriptRoot 'UbuntuImageTestHelpers.ps1')
    $script:Py = Find-TestPython
    $repo = Get-TestRepo
    $script:Validator = Join-Path $repo 'parity\contracts\validate.py'
    $schema = Get-Content -Raw -LiteralPath (Join-Path $repo 'parity\contracts\image-catalog.schema.json') | ConvertFrom-Json
    $script:CanValidate = [bool]$script:Py -and $schema.properties.schema.const -eq 2
    $script:PhaseCases = @((Get-Content -Raw -LiteralPath (Join-Path $repo 'images\ubuntu-24.04\build-plan.json') | ConvertFrom-Json).phases |
            Where-Object { $_.kind -ne 'restart' -and $_.action -notlike 'download-*' } | ForEach-Object { @{ Phase = $_.id } })
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'UbuntuImageTestHelpers.ps1')
    Import-Module (Join-Path (Get-TestRepo) 'images\windows\AapWinImage.psm1') -Force
    Import-Module (Join-Path (Get-TestRepo) 'supervisor\network\AapHostNetworkCheck.psm1') -Force
    Import-Module (Join-Path (Get-TestRepo) 'tests\common\AapHostNetworkFake.psm1') -Force
    Import-Module (Get-TestModulePath) -Force
    $script:Repo = Get-TestRepo
    $script:Py = Find-TestPython
    $script:Validator = Join-Path $script:Repo 'parity\contracts\validate.py'
    $script:BuildId = 'ubuntu-24.04-x64_20261012.334.1-aap.1'
    $script:Gen = 'ubuntu-24.04-x64/20261012.334.1-aap.1'
    $script:Sha0 = '0' * 64

    function Invoke-Build { Invoke-AapUbuntuImageBuild -Config $w.Config -Provider $w.Provider -Network $w.Network }
    # The VM ops in call order, the host network module's included.
    function Get-OpOrder([string[]]$Only) { @($w.Calls | Where-Object { $Only -contains $_.Op } | ForEach-Object { $_.Op }) }
    function Get-EvidenceDir { Join-Path $w.Evidence "P07\$script:BuildId" }
    function Assert-NothingStarted {
        (Get-Ops $w 'NewVm').Count | Should -Be 0
        (Get-Ops $w 'NewBuildDisk').Count | Should -Be 0
        Test-Path (Join-Path $w.Staging "build\$script:BuildId") | Should -BeFalse
        Test-Path (Join-Path $w.Base 'ubuntu-24.04-x64\20261012.334.1-aap.1') | Should -BeFalse
    }
    function Assert-CleanedUp {
        $w.Vms.Count | Should -Be 0
        Test-Path (Join-Path $w.Staging "build\$script:BuildId") | Should -BeFalse
        Test-Path (Join-Path $w.Base 'ubuntu-24.04-x64\20261012.334.1-aap.1') | Should -BeFalse
        Test-Path (Join-Path (Get-EvidenceDir) 'generation.json') | Should -BeFalse
    }
    function Set-GuestFault([string]$Phase, [scriptblock]$Reply) {
        $w | Add-Member -NotePropertyName FaultPhase -NotePropertyValue $Phase -Force
        $w | Add-Member -NotePropertyName FaultReply -NotePropertyValue $Reply -Force
        $w.Guest = { param($w, $req) if ($req.phase -eq $w.FaultPhase) { & $w.FaultReply $w $req } else { Get-FakeGuestReply $w $req } }
    }
    function Get-Reply($w, $req) { Get-FakeGuestReply $w $req | ConvertFrom-Json }
    function Invoke-Validator([string]$Contract, $Object) {
        $f = Join-Path $w.Root "$Contract-$([guid]::NewGuid().ToString('n')).json"
        Write-TestJson $Object $f
        $out = & $script:Py -B -I $script:Validator $Contract $f 2>&1
        return [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($out -join "`n") }
    }
    function Get-PlanText { Get-Content -Raw -LiteralPath (Join-Path $script:Repo 'images\ubuntu-24.04\build-plan.json') }
}

Describe 'build plan mirrors the pinned upstream template' {
    BeforeAll {
        $script:Plan = Get-PlanText | ConvertFrom-Json
        $script:Scripts = @($script:Plan.phases | Where-Object { $_.kind -eq 'scripts' } | ForEach-Object { $_.scripts } | ForEach-Object { $_ })
    }
    It 'is exactly what the generator derives from the template' {
        $tmp = Join-Path $TestDrive 'plan.json'
        $null = & (Join-Path $script:Repo 'images\ubuntu-24.04\New-AapUbuntuBuildPlan.ps1') -OutFile $tmp
        (Get-Content -Raw $tmp | ConvertFrom-Json | ConvertTo-Json -Depth 12 -Compress) | Should -Be ($script:Plan | ConvertTo-Json -Depth 12 -Compress)
    }
    It 'pins the build-commit template, locals, toolset, hosted capture, inventory and comparison reference by hash' {
        $b = $script:Plan.baseline
        foreach ($k in 'template', 'locals', 'toolset', 'capture', 'inventory') {
            $b.PSObject.Properties["$($k)_sha256"].Value | Should -Be (Get-FileSha (Join-Path $script:Repo ($b.PSObject.Properties["$($k)_path"].Value -replace '/', '\')))
        }
        $b.template_path | Should -Match 'build-commit-7e7dc1b'
        $b.runner_images_commit | Should -Be '7e7dc1bcc0ef464e5e315a2b4c33609590c6cffe'
        $b.image_version | Should -Be '20261012.334.1'
        $script:Plan.verify.reference_sha256 | Should -Be (Get-FileSha (Join-Path $script:Repo 'images\ubuntu-24.04\reference-inventory.json'))
    }
    It 'has one phase per upstream provisioner, in order, with the one reboot before cleanup' {
        $script:Plan.phases.Count | Should -Be 30
        @($script:Plan.phases | ForEach-Object { $_.upstream.block }) | Should -Be (1..30)
        $r = @($script:Plan.phases | Where-Object { $_.kind -eq 'restart' })
        @($r | ForEach-Object { $_.id }) | Should -Be @('p23')
        $next = $script:Plan.phases | Where-Object { $_.id -eq 'p24' }
        @($next.scripts.name) | Should -Be @('cleanup.sh')
        $next.pause_before_seconds | Should -Be 300
        $next.start_retry_seconds | Should -Be 600
    }
    It 'runs the 72 build scripts in the order inputs.md lists them' {
        $rows = @(Select-String -LiteralPath (Join-Path $script:Repo 'parity\baselines\ubuntu-24.04-x64\inputs.md') -Pattern '^\| (\d+) \| `([A-Za-z0-9.-]+\.(sh|ps1))`' | ForEach-Object { $_.Matches[0].Groups[2].Value })
        $rows.Count | Should -Be 72
        @($script:Scripts | ForEach-Object { $_.name }) | Should -Be $rows
    }
    It 'keeps how Packer ran each block: sudo, sudo pwsh, or the build user' {
        @($script:Plan.phases | Where-Object { $_.exec -eq 'root-pwsh' } | ForEach-Object { $_.id }) | Should -Be @('p15', 'p18')
        @($script:Plan.phases | Where-Object { $_.kind -eq 'scripts' -and $_.exec -eq 'user' } | ForEach-Object { @($_.scripts.name) }) | Should -Be @('install-homebrew.sh')
        ($script:Plan.phases | Where-Object { $_.id -eq 'p25' }).exec | Should -Be 'user'
        ($script:Plan.phases | Where-Object { $_.id -eq 'p12' }).env.IMAGE_OS | Should -Be '${var.image_os}'
        ($script:Plan.phases | Where-Object { $_.id -eq 'p16' }).scripts.Count | Should -Be 51
        ($script:Plan.phases | Where-Object { $_.id -eq 'p28' }).env.IMAGE_FOLDER | Should -Be '${var.image_folder}'
        # Packer's file provisioner uploaded over SFTP as the build user.
        @($script:Plan.phases | Where-Object { [string]$_.action -like 'upload-*' } | ForEach-Object { $_.exec } | Sort-Object -Unique) | Should -Be @('user')
    }
    It 'gates only sections the hosted reference has values for: no tool_cache.defaults gate while the capture records none' {
        $ref = Get-Content -Raw (Join-Path $script:Repo 'images\ubuntu-24.04\reference-inventory.json') | ConvertFrom-Json
        @($ref.tool_cache.defaults.PSObject.Properties).Count | Should -Be 0
        $script:Plan.verify.gate_sections | Should -Not -Contain 'tool_cache.defaults'
    }
    It 'fails on missing-required only in the sections the image owns, never in the runner, job identity or Azure fabric ones' {
        @($script:Plan.verify.required_sections) | Should -Be @('tools', 'shells', 'docker', 'docker.images', 'env', 'limits', 'limits.sysctl', 'hardware', 'tool_cache',
            'action_archive_cache', 'services', 'path.process', 'path.machine')
        foreach ($s in 'image', 'infra', 'run_identity', 'credential_env') { @($script:Plan.verify.required_sections) + @($script:Plan.verify.gate_sections) | Should -Not -Contain $s }
    }
    It 'refuses a plan whose required sections are <Case>' -Tag 'plan-required' -TestCases @(
        @{ Case = 'absent'; Edit = { param($p) $p.verify.PSObject.Properties.Remove('required_sections') } },
        @{ Case = 'empty'; Edit = { param($p) $p.verify.required_sections = @() } },
        @{ Case = 'naming the runner a verification guest does not have'; Edit = { param($p) $p.verify.required_sections = @('tools', 'image') } },
        @{ Case = 'naming the Azure fabric'; Edit = { param($p) $p.verify.required_sections = @('infra') } }) {
        $p = New-PinnedPlan (Join-Path $TestDrive 'required.json')
        & $Edit $p
        Write-TestJson $p (Join-Path $TestDrive 'required.json')
        { Read-AapUbuntuBuildPlan -Path (Join-Path $TestDrive 'required.json') } | Should -Throw 'AAP_PlanInvalid*required_sections*'
    }
    It 'passes P05''s real comparison of a guest without a runner, and fails one that lacks a tool' -Tag 'inventory-required' -Skip:(-not $script:Py) {
        # certify.py fails both (missing-required image.runner_version, runner_os, runner_arch); the plan's sections decide.
        $ref = Join-Path $script:Repo 'images\ubuntu-24.04\reference-inventory.json'
        $cand = Join-Path $TestDrive 'guest.json'; $out = Join-Path $TestDrive 'report.json'
        $g = Get-Content -Raw $ref | ConvertFrom-Json
        foreach ($k in 'runner_version', 'runner_os', 'runner_arch', 'runner_environment') { $g.image.$k = $null }
        $g.infra = [pscustomobject]@{ hostname = 'aap-verify' }
        $compare = {
            Write-TestJson $g $cand
            $null = & $script:Py -B -I -S (Join-Path $script:Repo 'tools\parity-certify\certify.py') compare --reference $ref --candidate $cand `
                --allowlist (Join-Path $script:Repo 'tools\parity-certify\allowlist.json') --out $out
            $LASTEXITCODE | Should -Be 1
            Read-AapInventoryReport -Path $out -GateSections @($script:Plan.verify.gate_sections) -RequiredSections @($script:Plan.verify.required_sections)
        }
        $r = & $compare
        @($r.recorded | Where-Object { $_.class -eq 'missing-required' } | ForEach-Object { "$($_.section).$($_.key)" }) | Should -Be @('image.runner_version', 'image.runner_os', 'image.runner_arch')
        $g.tools.gcc = $null
        { & $compare } | Should -Throw 'AAP_VerifyFailed*missing-required tools.gcc*'
    }
    It 'pins the source archive and the media nowhere yet, so both stay unwaivable blockers' {
        $script:Plan.inputs.source.entry | Should -BeNullOrEmpty
        $script:Plan.inputs.media.sha256 | Should -BeNullOrEmpty
        @($script:Plan.blockers | Where-Object { $_.waivable -eq $false } | ForEach-Object { $_.id }) | Should -Be @('p07-upstream-source-archive', 'p07-ubuntu-server-media')
    }
    It 'refuses a plan whose <Case>' -Tag 'plan-inputs' -TestCases @(
        @{ Case = 'media is neither pinned nor blocked'; Edit = { param($p) $p.inputs.media.entry = $null; $p.inputs.media.sha256 = $null } },
        @{ Case = 'source entry has no hash'; Edit = { param($p) $p.inputs.source.sha256 = $null } },
        @{ Case = 'media blocker is waivable'; Edit = { param($p) $p.inputs.media.entry = $null; $p.inputs.media.sha256 = $null
                $p.blockers += [pscustomobject]@{ id = 'p07-ubuntu-server-media'; waivable = $true; reason = 'r'; owner_action = 'o' } } }) {
        $p = New-PinnedPlan (Join-Path $TestDrive 'inputs.json')
        & $Edit $p
        Write-TestJson $p (Join-Path $TestDrive 'inputs.json')
        { Read-AapUbuntuBuildPlan -Path (Join-Path $TestDrive 'inputs.json') } | Should -Throw 'AAP_PlanInvalid*inputs.*'
    }
    It 'runs the software report and upstream tests before deprovision, and deprovision last' {
        $ids = @($script:Plan.phases | ForEach-Object { if ($_.kind -eq 'action') { $_.action } elseif ($_.kind -eq 'scripts') { @($_.scripts.name)[-1] } else { 'restart' } })
        $ids.IndexOf('software-report-and-tests') | Should -BeLessThan $ids.IndexOf('download-software-report-md')
        $ids.IndexOf('post-build-validation.sh') | Should -BeLessThan $ids.IndexOf('deprovision')
        $ids[-1] | Should -Be 'deprovision'
    }
    It 'sizes the OS disk from the hosted capture (150 GiB), records the 75 GB build disk, and never uses the 60 GiB Linux default' {
        $script:Plan.os_disk_gib | Should -Be 150
        $script:Plan.baseline.upstream_os_disk_gb | Should -Be 75
        (Get-Content -Raw (Join-Path $script:Repo 'images\ubuntu-24.04\AapUbuntuImage.psm1')) | Should -Not -Match '\b60\b'
    }
    It 'builds Ubuntu 24.04 only: no 26.04 media, image or locals entry anywhere in the plan' {
        $script:Plan.variables.image_os | Should -Be 'ubuntu24'
        $script:Plan.baseline.upstream_source_sku | Should -Be 'canonical:ubuntu-24_04-lts:server'
        Get-PlanText | Should -Not -Match '26[._]04|ubuntu26'
    }
    It 'installs the Azure kernel flavour and agent the hosted image runs, and masks the agent' {
        $script:Plan.base.kernel_package | Should -Be 'linux-azure'
        @($script:Plan.base.packages) | Should -Be @('walinuxagent')
        @($script:Plan.base.masked_services) | Should -Be @('walinuxagent.service')
        ($script:Plan.base.boot_command -join '') | Should -Match 'autoinstall ds=nocloud'
    }
    It 'refuses the committed plan until every script hash is pinned' -Tag 'plan-unpinned' {
        @($script:Scripts | Where-Object { $null -ne $_.sha256 }).Count | Should -Be 0
        { Read-AapUbuntuBuildPlan -Path (Join-Path $script:Repo 'images\ubuntu-24.04\build-plan.json') } | Should -Throw 'AAP_ScriptUnpinned*'
    }
    It 'refuses a plan with one unpinned script and accepts it fully pinned' -Tag 'plan-unpinned' {
        $p = New-PinnedPlan (Join-Path $TestDrive 'pinned.json')
        { Read-AapUbuntuBuildPlan -Path (Join-Path $TestDrive 'pinned.json') } | Should -Not -Throw
        ($p.phases | Where-Object { $_.id -eq 'p16' }).scripts[4].sha256 = 'ABC'
        Write-TestJson $p (Join-Path $TestDrive 'one-bad.json')
        { Read-AapUbuntuBuildPlan -Path (Join-Path $TestDrive 'one-bad.json') } | Should -Throw 'AAP_ScriptUnpinned*install-azure-devops-cli.sh*'
    }
    It 'refuses a plan whose phase runs as anything but root, root through pwsh, or the build user' -Tag 'plan-exec' {
        $p = New-PinnedPlan (Join-Path $TestDrive 'exec.json')
        ($p.phases | Where-Object { $_.id -eq 'p03' }).exec = 'host'
        Write-TestJson $p (Join-Path $TestDrive 'exec.json')
        { Read-AapUbuntuBuildPlan -Path (Join-Path $TestDrive 'exec.json') } | Should -Throw 'AAP_PlanInvalid*p03 runs as host*'
    }
    It 'refuses a plan whose comparison reference does not match its pinned hash' -Tag 'plan-reference' {
        $p = New-PinnedPlan (Join-Path $TestDrive 'ref.json')
        $p.verify.reference_sha256 = $script:Sha0
        Write-TestJson $p (Join-Path $TestDrive 'ref.json')
        { Read-AapUbuntuBuildPlan -Path (Join-Path $TestDrive 'ref.json') } | Should -Throw 'AAP_PlanInvalid*reference*'
    }
    It 'lists every P03 Ubuntu blocker plus its own, and no Windows one' {
        $b = @(Get-AapUbuntuBlockers -Plan $script:Plan -ManifestPath (Join-Path $script:Repo 'images\common\artifacts.manifest.json'))
        foreach ($id in 'azure-base-image-ubuntu-24.04', 'ubuntu-superseded-apt-versions', 'tool-cache-manifests', 'p07-upstream-source-archive', 'p07-upstream-variables-unverified', 'p07-ubuntu-server-media') { $b | Should -Contain $id }
        $b | Should -Not -Contain 'windows-server-2025-media'
        $b.Count | Should -Be 17
    }
    It 'the comparison reference is what P05 parses from the pinned hosted capture' -Skip:(-not $script:Py) {
        $out = Join-Path $TestDrive 'ref.json'
        $null = & $script:Py -B -I (Join-Path $script:Repo 'tools\parity-certify\certify.py') parse-hosted-log (Join-Path $script:Repo ($script:Plan.baseline.capture_path -replace '/', '\')) --out $out --run-id 39305649952
        $LASTEXITCODE | Should -Be 0
        (Get-Content -Raw $out | ConvertFrom-Json | ConvertTo-Json -Depth 12 -Compress) | Should -Be (Get-Content -Raw (Join-Path $script:Repo 'images\ubuntu-24.04\reference-inventory.json') | ConvertFrom-Json | ConvertTo-Json -Depth 12 -Compress)
    }
}

Describe 'storage record and roots' {
    BeforeEach { $w = New-FakeWorld }
    AfterEach { Remove-World $w }
    It 'refuses to build without a storage document, before anything exists' {
        Remove-Item -LiteralPath $w.StoragePath
        $r = Invoke-Build
        $r.Status | Should -Be 'refused'
        $r.Reason | Should -Be 'AAP_StorageMissing'
        Assert-NothingStarted
    }
    It 'refuses when <Name> is not admin-only' -Tag 'root-untrusted' -TestCases @(@{ Name = 'base_root' }, @{ Name = 'staging' }, @{ Name = 'capacity' }, @{ Name = 'evidence' }) {
        $path = @{ base_root = $w.Base; staging = $w.Staging; capacity = $w.Capacity; evidence = $w.Evidence }[$Name]
        $w.Untrusted[$path] = @("$path is writable by Users")
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_StorageUntrusted'
        Assert-NothingStarted
    }
    It 'refuses a root that is not on its recorded volume' -Tag 'volume-mismatch' {
        $doc = Get-Content -Raw $w.StoragePath | ConvertFrom-Json
        $doc.roots.base_root.volume_guid = $w.Guids.vol2
        Write-TestJson $doc $w.StoragePath
        (Invoke-Build).Reason | Should -Be 'AAP_StorageVolumeMismatch'
        Assert-NothingStarted
    }
    It 'refuses when the staging volume lacks room above its floor' -Tag 'disk-low' {
        $w.Free[$w.Guids.vol1] = [double]300 * $script:GiB
        (Invoke-Build).Reason | Should -Be 'AAP_DiskLow'
        Assert-NothingStarted
    }
    It 'counts staging and the published copy separately when they are on different volumes' -Tag 'disk-low' {
        Remove-World $w
        $w = New-FakeWorld -SeparateStaging
        $w.Free[$w.Guids.vol1] = [double]210 * $script:GiB   # base: 150 + 1 above the floor of 50 fits
        (Invoke-Build).Status | Should -Be 'built'
        Remove-World $w
        $w = New-FakeWorld -SeparateStaging
        $w.Free[$w.Guids.vol1] = [double]210 * $script:GiB
        $w.Free[$w.Guids.vol3] = [double]100 * $script:GiB   # staging needs 400 above its floor
        (Invoke-Build).Reason | Should -Be 'AAP_DiskLow'
    }
    It 'refuses to run when <Which> is not admin-only' -Tag 'builder-untrusted' -TestCases @(
        @{ Which = 'its own folder'; Rel = '.' }, @{ Which = 'the guest payload'; Rel = '<repo>\images\ubuntu-24.04\guest' },
        @{ Which = 'the shared P06 helpers'; Rel = '..\windows' }, @{ Which = 'images\common'; Rel = '..\common' },
        @{ Which = 'the P05 harness'; Rel = '<repo>\tools\parity-certify' }, @{ Which = 'the probe'; Rel = '<repo>\tools\parity-certify\probe' },
        @{ Which = 'the python the provider runs'; Rel = '<python>' }, @{ Which = 'the shared network check'; Rel = '..\..\supervisor\network' }) {
        # Folders next to the module are taken from where it was loaded (the mutation run loads a copy); the rest from the repository.
        $here = Split-Path -Parent (Get-Module AapUbuntuImage).Path
        $path = $(if ($Rel -eq '<python>') { $w.PythonDir } elseif ($Rel.StartsWith('<repo>')) { Join-Path $script:Repo $Rel.Substring(7) } else { Join-Path $here $Rel })
        $w.Untrusted[[IO.Path]::GetFullPath($path)] = @('writable by Users')
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_BuilderUntrusted'
        Assert-NothingStarted
    }
    It 'the production provider refuses a user-owned folder with the real ACL rules (no Hyper-V call)' {
        Import-Module (Join-Path $script:Repo 'images\ubuntu-24.04\AapUbuntuImage.HyperV.psm1') -Force
        $p = New-AapUbuntuHyperVProvider -PythonPath (Get-Process -Id $PID).Path
        $dir = Join-Path $w.Root 'userdir'
        [void](New-Item -ItemType Directory -Path $dir)
        @(& $p.TestRootTrust @{ Path = $dir }).Count | Should -BeGreaterThan 0
    }
    It 'the production provider names a python under %LOCALAPPDATA% for the trust check, which the real ACL rules refuse' {
        Import-Module (Join-Path $script:Repo 'images\ubuntu-24.04\AapUbuntuImage.HyperV.psm1') -Force
        $py = Join-Path $w.Root 'py\python.exe'
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $py)); [IO.File]::WriteAllText($py, 'not python')
        $p = New-AapUbuntuHyperVProvider -PythonPath $py
        $folders = @(& $p.ExecFolders @{})
        $folders | Should -Be @((Split-Path -Parent $py))
        @(& $p.TestRootTrust @{ Path = $folders[0] }).Count | Should -BeGreaterThan 0
    }
    It 'the production provider refuses the python app execution alias, a reparse point' -Skip:(-not (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\python.exe'))) {
        Import-Module (Join-Path $script:Repo 'images\ubuntu-24.04\AapUbuntuImage.HyperV.psm1') -Force
        { New-AapUbuntuHyperVProvider -PythonPath (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\python.exe') } | Should -Throw 'AAP_ProviderInvalid*reparse*'
    }
}

Describe 'preflight refusals change nothing' {
    BeforeEach { $w = New-FakeWorld }
    AfterEach { Remove-World $w }
    It 'refuses unresolved input blockers and names them' -Tag 'blocked' {
        $w.Config.Waivers = @($w.Config.Waivers | Where-Object { $_.id -ne 'azure-base-image-ubuntu-24.04' })
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_Blocked'
        $r.Detail | Should -Match 'azure-base-image-ubuntu-24.04'
        Assert-NothingStarted
    }
    It 'refuses with no waivers at all' -Tag 'blocked' {
        $w.Config.Remove('Waivers')
        (Invoke-Build).Reason | Should -Be 'AAP_Blocked'
    }
    It 'refuses a waiver for an unknown blocker' {
        $w.Config.Waivers += (New-TestWaiver 'windows-server-2025-media' (Get-FileSha $w.PlanPath))
        (Invoke-Build).Reason | Should -Be 'AAP_ConfigInvalid'
    }
    It 'refuses a waiver that is <Case>' -TestCases @(
        @{ Case = 'a bare id'; Edit = { param($x) 'tool-cache-manifests' } },
        @{ Case = 'missing its approver'; Edit = { param($x) $x.Remove('approver'); $x } },
        @{ Case = 'a short rationale'; Edit = { param($x) $x.rationale = 'ok'; $x } }) {
        $w.Config.Waivers[0] = & $Edit $w.Config.Waivers[0]
        (Invoke-Build).Reason | Should -Be 'AAP_ConfigInvalid'
        Assert-NothingStarted
    }
    It 'refuses a waiver of the media or source blocker, which only pinning resolves' -Tag 'waiver-unwaivable' {
        Update-TestPlan $w { param($p) $p.inputs.media.entry = $null; $p.inputs.media.sha256 = $null
            $p.blockers += [pscustomobject]@{ id = 'p07-ubuntu-server-media'; waivable = $false; reason = 'not pinned'; owner_action = 'pin it' } }
        (Invoke-Build).Reason | Should -Be 'AAP_Blocked'
        $w.Config.Waivers += (New-TestWaiver 'p07-ubuntu-server-media' (Get-FileSha $w.PlanPath))
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_ConfigInvalid'
        $r.Detail | Should -Match 'p07-ubuntu-server-media cannot be waived'
        Assert-NothingStarted
    }
    It 'refuses a waiver approved for another build plan' -Tag 'waiver' {
        $w.Config.Waivers[0].plan_sha256 = $script:Sha0
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_ConfigInvalid'
        $r.Detail | Should -Match 'another build plan'
    }
    It 'refuses inputs P03 did not verify offline' -Tag 'inputs' {
        $w.InputsComplete = $false
        (Invoke-Build).Reason | Should -Be 'AAP_InputsUnverified'
        Assert-NothingStarted
    }
    It 'refuses a staged <What> whose bytes differ from the plan pin, or that is missing' -Tag 'input-pin' -TestCases @(@{ What = 'media'; Prop = 'MediaPath' }, @{ What = 'source archive'; Prop = 'SourceArchive' }) {
        [IO.File]::AppendAllText($w.$Prop, 'changed')
        (Invoke-Build).Reason | Should -Be 'AAP_InputsUnverified'
        Remove-Item -LiteralPath $w.$Prop
        (Invoke-Build).Reason | Should -Be 'AAP_InputsUnverified'
        Assert-NothingStarted
    }
    It 'refuses media that is not an Ubuntu 24.04 live-server amd64 ISO: <File>' -Tag 'media-name' -TestCases @(
        @{ File = 'ubuntu-26.04-live-server-amd64.iso' }, @{ File = 'ubuntu-24.04.5-desktop-amd64.iso' }, @{ File = 'ubuntu-24.04.5-live-server-arm64.iso' }) {
        $other = Join-Path (Split-Path -Parent $w.MediaPath) $File
        Copy-Item -LiteralPath $w.MediaPath -Destination $other
        $w.MediaPath = $other   # same bytes, so it passes the pin
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_InputsUnverified'
        $r.Detail | Should -Match 'live-server amd64'
        Assert-NothingStarted
    }
    It 'refuses a config without <Key>' -TestCases @(@{ Key = 'BuilderCommit' }, @{ Key = 'StagingGibMax' }, @{ Key = 'BaseGibMax' }, @{ Key = 'JobDiskGibMax' }, @{ Key = 'BuildCpus' }, @{ Key = 'BuildMemGib' }) {
        $w.Config.Remove($Key)
        (Invoke-Build).Reason | Should -Be 'AAP_ConfigInvalid'
        Assert-NothingStarted
    }
    It 'refuses <Key> = <Value>, outside the owner-approved lab ceiling' -Tag 'owner-limits' -TestCases @(
        @{ Key = 'BuildCpus'; Value = 5 }, @{ Key = 'BuildMemGib'; Value = 11 }, @{ Key = 'BaseGibMax'; Value = 187 }, @{ Key = 'JobDiskGibMax'; Value = 56 }, @{ Key = 'BuildCpus'; Value = 0 },
        @{ Key = 'BuildMemGib'; Value = 'ten' }, @{ Key = 'BuildCpus'; Value = 2.5 }) {
        $w.Config[$Key] = $Value
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_ConfigInvalid'
        $r.Detail | Should -Match "^$Key must be 1 to"
        Assert-NothingStarted
    }
    It 'refuses <Key> = <Value>, not a whole number of at least 1' -Tag 'config-number' -TestCases @(
        @{ Key = 'AapBuild'; Value = 'x' }, @{ Key = 'AapBuild'; Value = 0 }, @{ Key = 'StagingGibMax'; Value = '400 GiB' }) {
        $w.Config[$Key] = $Value
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_ConfigInvalid'
        $r.Detail | Should -Match "^$Key must be a whole number"
        Assert-NothingStarted
    }
    It 'refuses while another image build is running' {
        [void][IO.Directory]::CreateDirectory((Join-Path $w.Staging 'build'))
        $h = [IO.File]::Open((Join-Path $w.Staging 'build\aap-image-build.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
        try { (Invoke-Build).Reason | Should -Be 'AAP_BuildBusy' } finally { $h.Dispose() }
    }
    It 'refuses a provider that lacks an op' {
        $w.Provider.Remove('CompareInventory')
        (Invoke-Build).Reason | Should -Be 'AAP_ProviderInvalid'
    }
    It 'refuses <Case>: the build switch aap-build-linux, never a guest switch' -Tag 'network' -TestCases @(
        @{ Case = 'a missing build switch'; Edit = { param($w) $w.Switch = $null } },
        @{ Case = 'only the Linux guests switch'; Edit = { param($w) $w.Switch = @{ Name = 'aap-guests-linux'; SwitchType = 'Internal' } } },
        @{ Case = 'an External switch of the right name'; Edit = { param($w) $w.Switch = @{ Name = 'aap-build-linux'; SwitchType = 'External' } } },
        @{ Case = 'a Private switch of the right name'; Edit = { param($w) $w.Switch = @{ Name = 'aap-build-linux'; SwitchType = 'Private' } } }) {
        & $Edit $w
        (Invoke-Build).Reason | Should -Be 'AAP_NetworkUntrusted'
        (Get-Ops $w 'GetSwitch')[0].Args.Name | Should -Be 'aap-build-linux'
        Assert-NothingStarted
    }
    It 'refuses to build without the host network module' -Tag 'network-module' {
        $r = Invoke-AapUbuntuImageBuild -Config $w.Config -Provider $w.Provider
        $r.Reason | Should -Be 'AAP_NetworkUnavailable'
        Assert-NothingStarted
    }
    It 'refuses a host network module without <Op>' -Tag 'network-ops' -TestCases @(@{ Op = 'Attach' }, @{ Op = 'Detach' }, @{ Op = 'Verify' }) {
        $w.Network.Remove($Op)
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_NetworkInvalid'
        $r.Detail | Should -Match $Op
        Assert-NothingStarted
    }
    It 'refuses a plan whose image version could name a path' -Tag 'plan-version' {
        # A traversal made only of whole '..' steps: with this check disabled (the mutation run) the build escapes its folders
        # but every name it creates stays deletable; a name ending in dots ('x_..') would not be, so Remove-World could not.
        Update-TestPlan $w { param($p) $p.baseline.image_version = 'a\..\..\x' }
        (Invoke-Build).Reason | Should -Be 'AAP_PlanInvalid'
        Assert-NothingStarted
    }
    It 'refuses a plan variable that could break out of the guest request' -Tag 'request-value' {
        Update-TestPlan $w { param($p) $p.variables.image_folder = "/imagegeneration'; reboot" }
        (Invoke-Build).Reason | Should -Be 'AAP_PlanInvalid'
        Assert-NothingStarted
    }
    It 'ignores plan, manifest and payload paths in the config' {
        $w.Config.PlanPath = 'C:\elsewhere\plan.json'; $w.Config.GuestDir = 'C:\elsewhere'
        (Invoke-Build).Status | Should -Be 'built'
    }
}

Describe 'a full build with fakes' {
    BeforeAll {
        $w = New-FakeWorld
        $script:R = Invoke-Build
        $script:W = $w
        $script:Ev = Get-Content -Raw (Join-Path (Get-EvidenceDir) 'build.json') | ConvertFrom-Json
    }
    AfterAll { Remove-World $script:W }
    BeforeEach { $w = $script:W }
    It 'builds and publishes the generation' {
        $script:R.Status | Should -Be 'built'
        $script:R.Ok | Should -BeTrue
        Test-Path (Join-Path $w.Base 'ubuntu-24.04-x64\20261012.334.1-aap.1\base.vhdx') | Should -BeTrue
    }
    It 'installs the ISO unattended: empty disk, VM, network, seed, boot command, power-off, media out, seed deleted, boot from disk' {
        $ops = @($w.Calls | ForEach-Object { $_.Op })
        $first = [array]::IndexOf($ops, 'NewBuildDisk')
        # host-network-module.md, Consumer obligations 1 and 2: NewVm with no adapter, Attach and the declaration check, the
        # seed from the declaration while the VM is Off, then before every start Attach again, Verify and the read-back.
        @($ops[$first..($first + 20)]) | Should -Be @('NewBuildDisk', 'NewVm', 'GetVmConfig', 'Attach', 'NewSeedImage', 'SetSeed', 'Attach', 'Verify', 'GetVmNetwork', 'StartVm',
            'TypeBootCommand', 'WaitVmOff', 'RemoveDvds', 'Attach', 'Verify', 'GetVmNetwork', 'StartVm', 'WaitGuestReady', 'InvokeGuest', 'InvokeGuest', 'MeasureBytes')
        $vm = (Get-Ops $w 'NewVm')[0].Args
        $vm.Name | Should -Match '^aap-lbuild-[0-9a-f]{8}$'
        $vm.ContainsKey('SwitchName') | Should -BeFalse
        @($vm.Dvds | ForEach-Object { Split-Path -Leaf $_ }) | Should -Be @('ubuntu-24.04.5-live-server-amd64.iso')
        Split-Path -Leaf (Get-Ops $w 'SetSeed')[0].Args.Path | Should -Be 'seed.iso'
        $vm.BootFromDvd | Should -BeTrue
        (Get-Ops $w 'NewBuildDisk')[0].Args.SizeGib | Should -Be 150
        @((Get-Ops $w 'TypeBootCommand')[0].Args.Keys) -join '' | Should -Match 'autoinstall ds=nocloud<enter>'
        (Get-Ops $w 'WaitVmOff')[0].Args.TimeoutSeconds | Should -Be 5400
    }
    It 'sends the guest the P03 archive after the install, then every phase in upstream order with the reboot between them' {
        $w.Puts[0].Name | Should -Be 'runner-images.tar.gz'
        $w.Puts[0].HostPath | Should -Be $w.SourceArchive
        $build = @($w.Requests | Where-Object { $_.Vm -like 'aap-lbuild-*' } | ForEach-Object { $_.phase })
        $want = @($w.Plan.phases | Where-Object { $_.kind -ne 'restart' -and $_.action -notlike 'download-*' } | ForEach-Object { $_.id })
        $build | Should -Be $want
        @(Get-Ops $w 'InvokeGuest' | Where-Object { $_.Args.Verb -eq 'reboot' }).Count | Should -Be 1
        (Get-Ops $w 'ReceiveFile' | ForEach-Object { $_.Args.Name }) | Should -Be @('software-report.md', 'software-report.json', 'scan.json', 'job-inventory.json')
    }
    It 'sends each script phase with pinned hashes, resolved environment, its exec mode and pause' {
        $q = $w.Requests | Where-Object { $_.phase -eq 'p16' }
        $q.kind | Should -Be 'scripts'
        $q.exec | Should -Be 'root'
        $q.script.Count | Should -Be 51
        $q.script[0] | Should -Be "install-actions-cache.sh $(Get-TextSha 'install-actions-cache.sh')"
        $q.env | Should -Be @('HELPER_SCRIPTS=/imagegeneration/helpers', 'INSTALLER_SCRIPT_FOLDER=/imagegeneration/installers', 'DEBIAN_FRONTEND=noninteractive')
        $q.var.image_folder | Should -Be '/imagegeneration'
        ($w.Requests | Where-Object { $_.phase -eq 'p20' }).exec | Should -Be 'user'
        ($w.Requests | Where-Object { $_.phase -eq 'p18' }).exec | Should -Be 'root-pwsh'
        ($w.Requests | Where-Object { $_.phase -eq 'p24' }).pause_before | Should -Be '300'
        ($w.Requests | Where-Object { $_.phase -eq 'p12' }).env | Should -Be @('IMAGE_VERSION=20261012.334.1', 'IMAGE_OS=ubuntu24', 'HELPER_SCRIPTS=/imagegeneration/helpers')
    }
    It 'records the published bytes in a candidate image-catalog generation entry' {
        $g = Get-Content -Raw $script:R.RecordPath | ConvertFrom-Json
        $g.generation_id | Should -Be $script:Gen
        $g.profile | Should -Be 'ubuntu-24.04-x64'
        $g.state | Should -Be 'candidate'
        $g.provenance.built_by_item | Should -Be 'P07'
        $g.artifacts[0].path | Should -Be "$script:Gen/base.vhdx"
        $g.artifacts[0].sha256 | Should -Be (Get-FileSha (Join-Path $w.Base 'ubuntu-24.04-x64\20261012.334.1-aap.1\base.vhdx'))
        $g.baseline.inventory_sha256 | Should -Be '48608655281529b27f298ea92cc8ad63e52f847fa2fb8b03d1e0ddd5e2a192ed'
        $g.secret_scan.result | Should -Be 'clean'
        $g.secret_scan.evidence_ref | Should -Be "evidence/P07/$script:BuildId/secret-scan.json"
    }
    It 'passes the contract validator as a lab catalog entry and a budget record' -Skip:(-not $script:CanValidate) {
        $g = Get-Content -Raw $script:R.RecordPath | ConvertFrom-Json
        $cat = [ordered]@{ schema = 2; revision = 1; scope = 'lab'; profiles = [ordered]@{ 'win25-vs2026-x64' = [ordered]@{ active = $null; rollback = $null }; 'ubuntu-24.04-x64' = [ordered]@{ active = $null; rollback = $null } }; generations = @($g) }
        $v = Invoke-Validator 'image-catalog' $cat
        $v.Text | Should -Not -Match 'FAIL'
        $v.Code | Should -Be 0
        $b = Invoke-Validator 'backend-lifecycle' (Get-Content -Raw $script:R.BudgetPath | ConvertFrom-Json)
        $b.Code | Should -Be 0
    }
    It 'writes a measured Linux budget: no scratch disk, caps from the verification clone, inside the approved lab budget' {
        $b = Get-Content -Raw $script:R.BudgetPath | ConvertFrom-Json
        $b.profile | Should -Be 'linux'
        $b.measured | Should -BeTrue
        $b.base_gib | Should -Be 61
        $b.clone_peak_gib | Should -Be 14
        $b.clone_gib_max | Should -Be 18
        $b.scratch_peak_gib | Should -Be 0
        $b.scratch_gib_max | Should -Be 0
        $b.staging_gib | Should -Be 70
        $b.boot_mem_overhead_mib | Should -Be 280
        $b.image_generation | Should -Be $script:Gen
    }
    It 'records plan, inputs manifest, builder commit, waivers, base deviation, phases, seal check and the inventory comparison' {
        $script:Ev.plan_sha256 | Should -Be (Get-FileSha $w.PlanPath)
        $script:Ev.inputs_manifest_sha256 | Should -Be (Get-FileSha (Join-Path $script:Repo 'images\common\artifacts.manifest.json'))
        $script:Ev.builder_commit | Should -Be '0123456789abcdef0123456789abcdef01234567'
        @($script:Ev.waivers).Count | Should -Be 15   # the P03 blockers and the variables blocker; source and media are pinned
        $script:Ev.base.kernel_package | Should -Be 'linux-azure'
        $script:Ev.media.sha256 | Should -Be $w.MediaSha
        $script:Ev.media.entry | Should -Be 'ubuntu-24.04.5-live-server'
        $script:Ev.verify.inventory_compare.extra_count | Should -Be 2
        @($script:Ev.verify.inventory_compare.extra | ForEach-Object { "$($_.section).$($_.key)" }) | Should -Be @('tool_cache.node/24.22.0', 'env.AAP')
        $script:Ev.switch | Should -Be 'aap-build-linux'
        $script:Ev.network.address | Should -Match '^172\.31\.253\.'
        $script:Ev.seal_check.findings.Count | Should -Be 0
        $script:Ev.verify.upstream_tests.failed | Should -Be 0
        $script:Ev.verify.facts.kernel | Should -Be '6.17.0-1030-azure'
        $script:Ev.verify.inventory_compare.recorded[0].key | Should -Be 'kernel'
        # A verification guest has no runner: recorded, not gated.
        @($script:Ev.verify.inventory_compare.recorded | Where-Object { $_.class -eq 'missing-required' } | ForEach-Object { "$($_.section).$($_.key)" }) |
            Should -Be @('image.runner_version', 'image.runner_os', 'image.runner_arch')
        @($script:Ev.verify.inventory_compare.required_sections) | Should -Be @($w.Plan.verify.required_sections)
        $script:Ev.verify.inventory_compare.counts.'version-mismatch' | Should -Be 1
        $script:Ev.reports.'software-report.md' | Should -Be (Get-TextSha $w.ReportText)
    }
    It 'scans in a guest of the pinned media with no network and no disk at boot, then hot-adds the sealed disk as a differencing child' {
        $vm = (Get-Ops $w 'NewVm')[1].Args
        $vm.Name | Should -Match '^aap-lscan-'
        $vm.OsDisk | Should -BeNullOrEmpty
        @($vm.Dvds | ForEach-Object { Split-Path -Leaf $_ }) | Should -Be @('ubuntu-24.04.5-live-server-amd64.iso')
        $vm.BootFromDvd | Should -BeTrue
        $d = (Get-Ops $w 'NewDiffDisk')[0].Args
        $d.Parent | Should -Be (Join-Path $w.Staging "build\$script:BuildId\os.vhdx")
        $ops = $w.Calls.ToArray()
        $attach = @(0..($ops.Count - 1) | Where-Object { $ops[$_].Op -eq 'AttachDisk' })[0]
        $ready = @(0..($ops.Count - 1) | Where-Object { $ops[$_].Op -eq 'WaitGuestReady' -and $ops[$_].Args.VmName -eq $vm.Name })[0]
        $attach | Should -BeGreaterThan $ready
        $ops[$attach].Args.Path | Should -Be $d.Path
        $ops[$attach].Args.VmName | Should -Be $vm.Name
        ($w.Puts | Where-Object { $_.Vm -like 'aap-lscan-*' }).Name | Should -Be 'aap-scan.sh'
    }
    It 'gives the scanner the build token in its own seed, never in a request' {
        $buildToken = [regex]::Match($w.Seeds[0].Files['user-data'], "content: '([0-9a-f]{64})'").Groups[1].Value
        $w.Seeds[1].Files['user-data'] | Should -Match ("(?m)^  - path: /var/lib/aap-build/known\n    owner: root:root\n    permissions: '0600'\n    content: '" + $buildToken + "'$")
        $tokens = @($w.Seeds | ForEach-Object { [regex]::Match($_.Files['user-data'], "content: '([0-9a-f]{64})'").Groups[1].Value })
        foreach ($q in $w.Requests) { foreach ($t in $tokens) { $q.text.Contains($t) | Should -BeFalse -Because $q.phase }; $q.text | Should -Not -Match '(?m)^known=' }
        $w.Seeds[0].Files['user-data'] | Should -Not -Match 'aap-build/known'
        $w.Seeds[2].Files['user-data'] | Should -Not -Match 'aap-build/known'
    }
    It 'verifies in a fresh guest of the sealed disk with no network and no media, as the job user, then compares the inventory' {
        $vm = (Get-Ops $w 'NewVm')[2].Args
        $vm.Name | Should -Match '^aap-lverify-'
        @($vm.Dvds).Count | Should -Be 0
        $vm.BootFromDvd | Should -BeFalse
        @($w.Puts | Where-Object { $_.Vm -like 'aap-lverify-*' } | ForEach-Object { $_.Name }) | Should -Be @('aap-verify.sh', 'linux.sh', 'hello.c', 'runner-images.tar.gz')
        $q = $w.Requests | Where-Object { $_.kind -eq 'verify' }
        $q.var.job_user | Should -Be 'runner'
        $q.var.post_generation | Should -Be '/imagegeneration/post-generation'
        $c = (Get-Ops $w 'CompareInventory')[0].Args
        $c.Reference | Should -Be (Join-Path $script:Repo 'images\ubuntu-24.04\reference-inventory.json')
        $c.Allowlist | Should -Be (Join-Path $script:Repo 'tools\parity-certify\allowlist.json')
        $c.Candidate | Should -Be (Join-Path (Get-EvidenceDir) 'job-inventory.json')
    }
    It 'gives each guest its own seed and token; only the build seed installs, only the verification seed creates the job user' {
        $w.Seeds.Count | Should -Be 3
        @($w.Seeds | ForEach-Object { $_.Label }) | Should -Be @('CIDATA', 'CIDATA', 'CIDATA')
        $tokens = @($w.Seeds | ForEach-Object { [regex]::Match($_.Files['user-data'], "content: '([0-9a-f]{64})'").Groups[1].Value })
        @($tokens | Sort-Object -Unique).Count | Should -Be 3
        $b, $s, $v = @($w.Seeds | ForEach-Object { $_.Files['user-data'] })
        $b | Should -Match '(?m)^autoinstall:$'
        $b | Should -Match 'package: linux-azure'
        $b | Should -Match 'systemctl mask walinuxagent.service'
        $b | Should -Match 'allow-pw: false'
        $b | Should -Match "(?m)^        lock_passwd: true$"
        $s | Should -Not -Match 'autoinstall|users:'
        $v | Should -Not -Match 'autoinstall'
        $v | Should -Match '(?m)^  - name: runner\n    uid: 1001\n    groups: \[adm, users, docker, systemd-journal\]'
        # The verification guest boots like a clone (P15): a new snakeoil TLS pair before the agent answers.
        $v | Should -Match '(?m)^runcmd:\n  - \[make-ssl-cert, generate-default-snakeoil, --force-overwrite\]\n  - \[systemctl, daemon-reload\]\n  - \[systemctl, enable, --now, aap-agent\.socket\]$'
        foreach ($x in $b, $s) { $x | Should -Not -Match 'make-ssl-cert' }
        # The build guest's network is the declaration, static (contract: no DHCP); the others have no network at all.
        $d = $script:Ev.network
        $b | Should -Match ("(?m)^        dhcp4: false\n        dhcp6: false\n        accept-ra: false\n        addresses: \[" + [regex]::Escape("$($d.address)/24") + "\]\n        routes:\n          - to: default\n            via: " + [regex]::Escape($d.gateway) + "\n        nameservers:\n          addresses: \[192\.0\.2\.53, 198\.51\.100\.53\]$")
        foreach ($x in $b, $s, $v) { $x | Should -Not -Match 'dhcp4: true' }
        foreach ($x in $s, $v) { $x | Should -Not -Match 'network:' }
        foreach ($x in $b, $s, $v) {
            $x | Should -Match 'ListenStream=vsock::5223'
            $x | Should -Not -Match '(?m)^\s*-?\s*(passwd|plain_text_passwd|hashed_passwd|ssh_authorized_keys|password):'
            $x | Should -Not -Match "`t"
        }
        $w.Seeds[0].Files['meta-data'] | Should -Match '(?m)^instance-id: aap-[0-9a-f]{8}-build$'
    }
    It 'embeds the agent verbatim in every seed' {
        $agent = [IO.File]::ReadAllText((Join-Path $script:Repo 'images\ubuntu-24.04\guest\aap-agent.sh')).TrimEnd("`n")
        foreach ($i in 0, 1, 2) {
            $pad = ' ' * $(if ($i -eq 0) { 10 } else { 6 })   # the build seed nests the cloud-config under autoinstall.user-data
            $indented = (@($agent.Split("`n") | ForEach-Object { if ($_ -eq '') { '' } else { $pad + $_ } }) -join "`n")
            $w.Seeds[$i].Files['user-data'].Contains($indented) | Should -BeTrue
        }
    }
    It 'makes the published generation read-only and removes every build artifact' {
        $gen = Join-Path $w.Base 'ubuntu-24.04-x64\20261012.334.1-aap.1'
        $w.ReadOnly | Should -Contain (Join-Path $gen 'base.vhdx')
        $w.ReadOnly | Should -Contain $gen
        ([IO.File]::GetAttributes((Join-Path $gen 'base.vhdx')) -band [IO.FileAttributes]::ReadOnly) | Should -Be ([IO.FileAttributes]::ReadOnly)
        Test-Path (Join-Path $w.Staging "build\$script:BuildId") | Should -BeFalse
        $w.Vms.Count | Should -Be 0
    }
    It 'leaves no guest token in any host file it kept' {
        $tokens = @($w.Seeds | ForEach-Object { [regex]::Match($_.Files['user-data'], "content: '([0-9a-f]{64})'").Groups[1].Value })
        foreach ($f in @(Get-ChildItem -LiteralPath $w.Root -Recurse -File)) {
            $text = [IO.File]::ReadAllText($f.FullName)
            foreach ($t in $tokens) { $text.Contains($t) | Should -BeFalse -Because $f.FullName }
        }
    }
    It 'never attaches, mounts or opens a guest disk on the host' {
        foreach ($op in 'MountReadOnly', 'Dismount', 'WriteOfflineFiles', 'ApplyWindowsImage') { (Get-Ops $w $op).Count | Should -Be 0 }
        @(Get-Ops $w 'OptimizeDisk').Count | Should -Be 1
    }
    It 'is idempotent: a second run reports unchanged and creates nothing' {
        $before = $w.Calls.Count
        $r2 = Invoke-Build
        $r2.Status | Should -Be 'unchanged'
        @($w.Calls | Select-Object -Skip $before | Where-Object { $_.Op -in 'NewVm', 'NewBuildDisk', 'NewSeedImage' }).Count | Should -Be 0
    }
}

Describe 'the build VM''s network: the host network module (host-network-module.md, Consumer obligations)' {
    BeforeEach { $w = New-FakeWorld }
    AfterEach { Remove-World $w }
    It 'attaches only the build VM, the same declaration at every start, verifies it while it runs and detaches it after RemoveVm' -Tag 'network-running' {
        Set-ModuleVar 'NetVerifyMinutes' 0
        (Invoke-Build).Status | Should -Be 'built'
        $build = (Get-Ops $w 'NewVm')[0].Args.Name
        $att = @(Get-Ops $w 'Attach')
        $att.Count | Should -Be 3   # the declaration for the seed, then before each of the two starts
        foreach ($a in $att) { $a.Args.VmName | Should -Be $build; $a.Args.Profile | Should -Be 'linux'; @($a.Args.Keys).Count | Should -Be 3 }
        @(Get-Ops $w 'Verify').Count | Should -Be (2 + @($w.Plan.phases).Count)   # before each start and before each phase
        $ops = $w.Calls.ToArray()
        $removed = @(0..($ops.Count - 1) | Where-Object { $ops[$_].Op -eq 'RemoveVm' -and $ops[$_].Args.Name -eq $build })[0]
        $detached = @(0..($ops.Count - 1) | Where-Object { $ops[$_].Op -eq 'Detach' })
        $detached.Count | Should -Be 1
        $detached[0] | Should -BeGreaterThan $removed
        $ops[$detached[0]].Args.VmId | Should -Be $att[0].Args.VmId
        @(Get-AapFakeHostNetworkRecord -Root $w.NetRoot) | Should -BeNullOrEmpty
        # The scanner and the verification VM: never attached, read back with no adapter before they start.
        foreach ($vm in @(Get-Ops $w 'NewVm' | Select-Object -Skip 1 | ForEach-Object { $_.Args.Name })) {
            $read = @(0..($ops.Count - 1) | Where-Object { $ops[$_].Op -eq 'GetVmNetwork' -and $ops[$_].Args.VmName -eq $vm })
            $start = @(0..($ops.Count - 1) | Where-Object { $ops[$_].Op -eq 'StartVm' -and $ops[$_].Args.VmName -eq $vm })
            $read.Count | Should -Be 1 -Because $vm
            $read[0] | Should -BeLessThan $start[0]
        }
    }
    It 'refuses to start the build VM when the module''s Verify reports <Tamper>' -Tag 'network-verify' -TestCases @(
        @{ Tamper = 'public-host' }, @{ Tamper = 'host-empty' }, @{ Tamper = 'host-no-gateway' }, @{ Tamper = 'host-no-lan' }, @{ Tamper = 'no-adapter' },
        @{ Tamper = 'second-adapter' }, @{ Tamper = 'external-switch' }, @{ Tamper = 'other-switch' }, @{ Tamper = 'dhcp-guard-off' }, @{ Tamper = 'router-guard-off' },
        @{ Tamper = 'mac-spoofing-on' }, @{ Tamper = 'port-mirroring' }, @{ Tamper = 'vlan-trunk' }, @{ Tamper = 'storm-limit-off' }, @{ Tamper = 'legacy-acl' },
        @{ Tamper = 'foreign-peer' }, @{ Tamper = 'drop-fixed-deny' }, @{ Tamper = 'drop-inbound-deny' }, @{ Tamper = 'scoped-deny' }, @{ Tamper = 'stateful-rule' },
        @{ Tamper = 'isolated-rule' }, @{ Tamper = 'no-source-pin' }, @{ Tamper = 'pin-above-deny' }, @{ Tamper = 'extra-allow' }) {
        Set-AapFakeHostNetworkKnob -Root $w.NetRoot -Tamper @($Tamper)
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_NetworkUntrusted'
        (Get-Ops $w 'StartVm').Count | Should -Be 0
        Assert-CleanedUp
        @(Get-AapFakeHostNetworkRecord -Root $w.NetRoot) | Should -BeNullOrEmpty   # RemoveVm, then Detach
    }
    It 'counts every object Verify writes as a problem, an empty or null one included: <Case>' -Tag 'network-verify' -TestCases @(
        @{ Case = 'null'; Out = { $null } }, @{ Case = 'empty'; Out = { '' } }) {
        $w | Add-Member -NotePropertyName VerifyOut -NotePropertyValue $Out -Force
        $w.Network.Verify = { param($a) Add-FakeCall 'Verify' $a; & $w.VerifyOut }
        (Invoke-Build).Reason | Should -Be 'AAP_NetworkUntrusted'
        (Get-Ops $w 'StartVm').Count | Should -Be 0
    }
    It 'verifies the running build VM again before each phase, and stops it when the host changes' -Tag 'network-verify', 'network-running' {
        Set-ModuleVar 'NetVerifyMinutes' 0
        Set-GuestFault 'p05' { param($w, $req) Set-AapFakeHostNetworkKnob -Root $w.NetRoot -Tamper @('public-host'); Get-FakeGuestReply $w $req }
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_NetworkUntrusted'
        $r.Detail | Should -Match 'public IPv4'
        ($w.Requests | Select-Object -Last 1).phase | Should -Be 'p05'
        Assert-CleanedUp
    }
    It 'reads the adapter back itself: a module whose Verify reports nothing does not get a VM with <Tamper> started' -Tag 'network-readback' -TestCases @(
        @{ Tamper = 'dhcp-guard-off' }, @{ Tamper = 'extra-allow' }, @{ Tamper = 'drop-inbound-deny' }, @{ Tamper = 'foreign-peer' }) {
        $w.Network.Verify = { param($a) Add-FakeCall 'Verify' $a }
        Set-AapFakeHostNetworkKnob -Root $w.NetRoot -Tamper @($Tamper)
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_NetworkUntrusted'
        (Get-Ops $w 'StartVm').Count | Should -Be 0
        Assert-CleanedUp
    }
    It 'refuses a declaration the shared check refuses, before any seed is made: <Case>' -Tag 'network-declaration' -TestCases @(
        @{ Case = 'the address is the gateway'; Edit = { param($d) $d.address = $d.gateway } },
        @{ Case = 'another VM''s name'; Edit = { param($d) $d.vm_name = 'aap-lbuild-ffffffff' } },
        @{ Case = 'a public subnet'; Edit = { param($d) $d.subnet = '8.8.8.0/24' } }) {
        $w | Add-Member -NotePropertyName DeclEdit -NotePropertyValue $Edit -Force
        $w.Network.Attach = { param($a) Add-FakeCall 'Attach' $a; $d = & $w.NetFake.Attach $a; & $w.DeclEdit $d; $d }
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_NetworkInvalid'
        (Get-Ops $w 'NewSeedImage').Count | Should -Be 0
        Assert-CleanedUp
    }
    It 'stops, removes the VM and then detaches when the module fails: <Fail>' -TestCases @(@{ Fail = 'Attach' }, @{ Fail = 'AttachAfterIntent' }, @{ Fail = 'AttachAfterAct' }, @{ Fail = 'Verify' }) {
        Set-AapFakeHostNetworkKnob -Root $w.NetRoot -Fail @($Fail)
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_NetworkUntrusted'
        (Get-Ops $w 'StartVm').Count | Should -Be 0
        Assert-CleanedUp
        @(Get-AapFakeHostNetworkRecord -Root $w.NetRoot) | Should -BeNullOrEmpty   # the record a failed Attach kept goes with Detach
    }
    It 'reports a Detach that fails as a network not proven detached, and keeps the record for the module''s reconcile' {
        Set-AapFakeHostNetworkKnob -Root $w.NetRoot -Fail @('Detach')
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_NetworkUntrusted'
        $r.Detail | Should -Match 'not proven detached'
        $r.Detail | Should -Match 'cleanup failed'
        @(Get-AapFakeHostNetworkRecord -Root $w.NetRoot).Count | Should -Be 1
    }
    It 'refuses a VM that could start on its own or keep a checkpoint: <Case>' -Tag 'vm-config' -TestCases @(
        @{ Case = 'automatic start'; Config = @{ AutomaticStartAction = 'StartIfRunning'; CheckpointType = 'Disabled' } },
        @{ Case = 'checkpoints'; Config = @{ AutomaticStartAction = 'Nothing'; CheckpointType = 'Standard' } }) {
        $w.VmConfig = $Config
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_NetworkUntrusted'
        (Get-Ops $w 'Attach').Count | Should -Be 0
        Assert-CleanedUp
    }
    It 'refuses to start the <Which> VM with any network adapter' -Tag 'nic-none' -TestCases @(@{ Which = 'scanner'; Prop = 'ScanVm' }, @{ Which = 'verification'; Prop = 'VerifyVm' }) {
        $name = (Get-AapUbuntuNames $w.Plan 1).$Prop
        $w.ForeignNics[$name] = @(@{ SwitchName = 'aap-guests-linux'; SwitchType = 'Internal' })
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_NetworkUntrusted'
        @(Get-Ops $w 'StartVm' | Where-Object { $_.Args.VmName -eq $name }).Count | Should -Be 0
        Assert-CleanedUp
    }
    It 'detaches a crashed run''s build VM once its VM is gone, before it builds again' {
        $names = Get-AapUbuntuNames $w.Plan 1
        $old = [guid]::NewGuid().ToString()
        $w.Vms[$names.BuildVm] = 'Off'; $w.VmIds[$names.BuildVm] = $old
        $null = & $w.NetFake.Attach @{ VmId = $old; VmName = $names.BuildVm; Profile = 'linux' }
        $bd = Join-Path $w.Staging "build\$script:BuildId"
        [void][IO.Directory]::CreateDirectory($bd)
        Write-TestJson ([ordered]@{ schema = 1; status = 'running'; vm_id = $old; steps = [ordered]@{}; written = @(); evidence_created = $false }) (Join-Path $bd 'state.json')
        $r = Invoke-Build
        $r.Status | Should -Be 'built'
        $r.PartialCleaned | Should -BeTrue
        (Get-Ops $w 'Detach')[0].Args.VmId | Should -Be $old
        Get-AapFakeHostNetworkRecord -Root $w.NetRoot -VmId $old | Should -BeNullOrEmpty
    }
}

Describe 'immutable generations' {
    BeforeEach { $w = New-FakeWorld }
    AfterEach { Remove-World $w }
    It 'refuses to rebuild an id whose published bytes changed' -Tag 'generation-exists' {
        (Invoke-Build).Status | Should -Be 'built'
        $f = Join-Path $w.Base 'ubuntu-24.04-x64\20261012.334.1-aap.1\base.vhdx'
        Unlock-TestPath $f; [IO.File]::SetAttributes($f, 'Normal'); [IO.File]::AppendAllText($f, 'tampered')
        (Invoke-Build).Reason | Should -Be 'AAP_GenerationExists'
    }
    It 'refuses a generation id that already exists without its record' -Tag 'generation-exists' {
        [void][IO.Directory]::CreateDirectory((Join-Path $w.Base 'ubuntu-24.04-x64\20261012.334.1-aap.1'))
        (Invoke-Build).Reason | Should -Be 'AAP_GenerationExists'
    }
    It 'builds aap.2 beside aap.1 without touching it' {
        (Invoke-Build).Status | Should -Be 'built'
        $one = Get-FileSha (Join-Path $w.Base 'ubuntu-24.04-x64\20261012.334.1-aap.1\base.vhdx')
        $w.Config.AapBuild = 2
        (Invoke-Build).Status | Should -Be 'built'
        Get-FileSha (Join-Path $w.Base 'ubuntu-24.04-x64\20261012.334.1-aap.1\base.vhdx') | Should -Be $one
        Test-Path (Join-Path $w.Base 'ubuntu-24.04-x64\20261012.334.1-aap.2\base.vhdx') | Should -BeTrue
    }
    It 'refuses an id whose evidence folder already exists, and leaves it alone' -Tag 'evidence-exists' {
        $ev = Get-EvidenceDir
        [void][IO.Directory]::CreateDirectory($ev); [IO.File]::WriteAllText((Join-Path $ev 'note.txt'), 'someone else')
        (Invoke-Build).Reason | Should -Be 'AAP_GenerationExists'
        Get-Content (Join-Path $ev 'note.txt') | Should -Be 'someone else'
        Assert-NothingStarted
    }
}

Describe 'failures roll back' {
    BeforeEach { $w = New-FakeWorld }
    AfterEach { Remove-World $w }
    It 'a failed guest step at <Phase> removes the VMs, the build disks and any partial generation' -Tag 'phase-failed', 'action-failed' -TestCases $script:PhaseCases {
        Set-GuestFault $Phase { param($w, $req) $o = Get-Reply $w $req; $o.status = 'failed'; $o.message = 'boom'; ConvertTo-Json $o -Depth 6 -Compress }
        $r = Invoke-Build
        $r.Status | Should -Be 'failed'
        $r.Reason | Should -BeIn @('AAP_PhaseFailed', 'AAP_SecretFound', 'AAP_ScanIncomplete')
        Assert-CleanedUp
    }
    It 'fails a script phase the guest reports as failed even when every script is listed with exit 0' -Tag 'phase-failed' {
        Set-GuestFault 'p05' { param($w, $req) $o = Get-Reply $w $req; $o.status = 'failed'; ConvertTo-Json $o -Depth 6 -Compress }
        (Invoke-Build).Reason | Should -Be 'AAP_PhaseFailed'
    }
    It 'refuses a script that exited non-zero, however the guest reports the phase' -Tag 'exit-code' {
        Set-GuestFault 'p16' { param($w, $req) $o = Get-Reply $w $req; $o.scripts[7].exit_code = 1; ConvertTo-Json $o -Depth 6 -Compress }
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_PhaseFailed'
        $r.Detail | Should -Match 'exited 1'
    }
    It 'refuses a guest that reports a script hash other than the pin' -Tag 'script-hash' {
        Set-GuestFault 'p04' { param($w, $req) $o = Get-Reply $w $req; $o.scripts[1].sha256 = $script:Sha0; ConvertTo-Json $o -Depth 6 -Compress }
        (Invoke-Build).Reason | Should -Be 'AAP_ScriptHashMismatch'
        Assert-CleanedUp
    }
    It 'refuses a guest that ran the planned scripts in another order' -Tag 'script-order' {
        Set-GuestFault 'p04' { param($w, $req) $o = Get-Reply $w $req; $o.scripts = @($o.scripts[1], $o.scripts[0], $o.scripts[2]); ConvertTo-Json $o -Depth 6 -Compress }
        (Invoke-Build).Reason | Should -Be 'AAP_PhaseFailed'
    }
    It 'refuses a guest that ran fewer scripts than planned' {
        Set-GuestFault 'p04' { param($w, $req) $o = Get-Reply $w $req; $o.scripts = @($o.scripts[0]); ConvertTo-Json $o -Depth 6 -Compress }
        (Invoke-Build).Reason | Should -Be 'AAP_PhaseFailed'
    }
    It 'treats a <Case> reply as hostile' -Tag 'hostile-size', 'hostile-shape', 'hostile-schema' -TestCases @(
        @{ Case = 'oversized'; Reply = { param($w, $req) (Get-FakeGuestReply $w $req) + (' ' * 70000) } },
        @{ Case = 'non-JSON'; Reply = { param($w, $req) 'all good' } },
        @{ Case = 'control-byte'; Reply = { param($w, $req) "{`"schema`":1,`"phase`":`"p05`",`"status`":`"ok`",`"message`":`"a$([char]27)b`"}" } },
        @{ Case = 'extra-field'; Reply = { param($w, $req) $o = Get-Reply $w $req; $o | Add-Member -NotePropertyName extra -NotePropertyValue 1; ConvertTo-Json $o -Depth 6 -Compress } },
        @{ Case = 'wrong-phase'; Reply = { param($w, $req) $o = Get-Reply $w $req; $o.phase = 'p06'; ConvertTo-Json $o -Depth 6 -Compress } },
        @{ Case = 'bad-script-entry'; Reply = { param($w, $req) $o = Get-Reply $w $req; $o.scripts[0].name = '../x.sh'; ConvertTo-Json $o -Depth 6 -Compress } }) {
        Set-GuestFault 'p05' $Reply
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_HostileGuest'
        Assert-CleanedUp
    }
    It 'fails when the unattended install never powers off' -Tag 'install-timeout' {
        $w.InstallOff = $false
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_InstallTimeout'
        Assert-CleanedUp
    }
    It 'fails when the installed system never answers on its channel' {
        $w.GuestReady = $false
        (Invoke-Build).Reason | Should -Be 'AAP_GuestUnreachable'
        Assert-CleanedUp
    }
    It 'fails when the guest does not come back after the reboot' -Tag 'reboot-timeout' {
        $w.ReadyAfterReboot = $false
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_RebootTimeout'
        Assert-CleanedUp
    }
    It 'does not count a reboot until the boot id changes' -Tag 'reboot-proof' {
        $w.BootId = { param($w) '0b0b0b0b-1111-4222-8333-000000000000' }
        $w.ReadyAfterReboot = { param($w) @($w.Calls | Where-Object { $_.Op -eq 'WaitGuestReady' }).Count -lt 6 }
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_RebootTimeout'
    }
    It 'keeps waiting while the guest does not answer its boot id, then counts the reboot' -Tag 'reboot-proof' {
        $w.BootId = { param($w) $n = @($w.Calls | Where-Object { $_.Op -eq 'InvokeGuest' -and $_.Args.Verb -eq 'bootid' }).Count
            if ($n -eq 2) { throw 'AAP_GuestUnreachable: down' } elseif ($n -le 1) { '0b0b0b0b-1111-4222-8333-000000000000' } else { '0b0b0b0b-1111-4222-8333-000000000001' } }
        (Invoke-Build).Status | Should -Be 'built'
        @(Get-Ops $w 'InvokeGuest' | Where-Object { $_.Args.Verb -eq 'bootid' }).Count | Should -Be 3
    }
    It 'treats a boot id that is not a UUID as hostile' -Tag 'bootid' {
        $w.BootId = { param($w) '../../etc/passwd' }
        (Invoke-Build).Reason | Should -Be 'AAP_HostileGuest'
    }
    It 'refuses to publish a generation whose measured <What> exceeds the approved lab budget' -Tag 'budget-approved' -TestCases @(
        @{ What = 'base'; Edit = { param($w) $w.Sizes['os.vhdx'] = [double]190 * 1073741824 } },
        @{ What = 'clone'; Edit = { param($w) $w.Sizes['os.avhdx'] = [double]50 * 1073741824 } }) {
        & $Edit $w
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_BudgetExceeded'
        Assert-CleanedUp
    }
    It 'stops when the build folder grows past StagingGibMax' -Tag 'budget' {
        $w.BuildDirBytes = { param($n) if ($n -ge 5) { 500 * 1073741824 } else { 50 * 1073741824 } }
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_BudgetExceeded'
        Assert-CleanedUp
    }
    It 'refuses a sealed guest whose seal check found <Rule>' -Tag 'seal-secret' -TestCases @(@{ Rule = 'no-authorized-keys' }, @{ Rule = 'no-password-hash' }, @{ Rule = 'install-user-absent' }) {
        Set-GuestFault 'p30' { param($w, $req) $o = Get-Reply $w $req; $o.data.seal.findings = @($Rule); $o.status = 'failed'; ConvertTo-Json $o -Depth 6 -Compress }
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_SecretFound'
        $r.Detail | Should -Match $Rule
        Assert-CleanedUp
    }
    It 'refuses a seal check that skipped or could not read a rule' -Tag 'seal-incomplete' {
        Set-GuestFault 'p30' { param($w, $req) $o = Get-Reply $w $req; $o.data.seal.checked = @($o.data.seal.checked | Select-Object -Skip 1); ConvertTo-Json $o -Depth 6 -Compress }
        (Invoke-Build).Reason | Should -Be 'AAP_ScanIncomplete'
        Remove-World $w; $w = New-FakeWorld
        Set-GuestFault 'p30' { param($w, $req) $o = Get-Reply $w $req; $o.data.seal.unreadable = @('no-password-hash'); ConvertTo-Json $o -Depth 6 -Compress }
        (Invoke-Build).Reason | Should -Be 'AAP_ScanIncomplete'
    }
    It 'treats a deprovision reply with <Case> as hostile' -TestCases @(
        @{ Case = 'no seal check'; Edit = { param($o) $o.data = [pscustomobject]@{} } },
        @{ Case = 'an unknown rule'; Edit = { param($o) $o.data.seal.checked += 'made-up' } },
        @{ Case = 'an extra field'; Edit = { param($o) $o.data.seal | Add-Member -NotePropertyName values -NotePropertyValue @('x') } }) {
        $w | Add-Member -NotePropertyName Edit -NotePropertyValue $Edit -Force
        Set-GuestFault 'p30' { param($w, $req) $o = Get-Reply $w $req; & $w.Edit $o; ConvertTo-Json $o -Depth 6 -Compress }
        (Invoke-Build).Reason | Should -Be 'AAP_HostileGuest'
    }
    It 'fails verification when <Case>' -Tag 'verify' -TestCases @(
        @{ Case = 'an upstream test failed'; Edit = { param($o) $o.data.upstream_tests.failed = 1 } },
        @{ Case = 'no upstream test ran'; Edit = { param($o) $o.data.upstream_tests.total = 0 } },
        @{ Case = 'sudo asks for a password'; Edit = { param($o) $o.data.discovery.sudo_nopasswd = $false } },
        @{ Case = 'systemd is not PID 1'; Edit = { param($o) $o.data.discovery.systemd_pid1 = $false } },
        @{ Case = 'the Docker daemon is down'; Edit = { param($o) $o.data.discovery.docker_daemon = $false } },
        @{ Case = 'the kernel is not the Azure flavour'; Edit = { param($o) $o.data.discovery.kernel_azure = $false } },
        @{ Case = 'the post-generation scripts failed'; Edit = { param($o) $o.data.discovery.post_generation = $false } },
        @{ Case = 'a discovery item is missing'; Edit = { param($o) $o.data.discovery.PSObject.Properties.Remove('hello_clang') } }) {
        $w | Add-Member -NotePropertyName Edit -NotePropertyValue $Edit -Force
        Set-GuestFault 'verify' { param($w, $req) $o = Get-Reply $w $req; & $w.Edit $o; ConvertTo-Json $o -Depth 6 -Compress }
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_VerifyFailed'
        Assert-CleanedUp
    }
    It 'fails verification when the fresh guest reports failure' -Tag 'verify-status' {
        Set-GuestFault 'verify' { param($w, $req) '{"schema":1,"phase":"verify","status":"failed","message":"the verification wrote no result"}' }
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_VerifyFailed'
        $r.Detail | Should -Match 'wrote no result'
        @(Get-Ops $w 'ReceiveFile' | Where-Object { $_.Args.Name -eq 'job-inventory.json' }).Count | Should -Be 0
    }
    It 'fails verification when the inventory differs from what the guest hashed' -Tag 'inventory-hash' {
        $w.InventoryText = '{"schema":1,"probe":"other"}'
        Set-GuestFault 'verify' { param($w, $req) $o = Get-Reply $w $req; $o.data.inventory_sha256 = Get-TextSha '{"schema":1,"probe":"fake"}'; ConvertTo-Json $o -Depth 6 -Compress }
        (Invoke-Build).Reason | Should -Be 'AAP_VerifyFailed'
    }
    It 'treats verification facts that are not short printable text as hostile' {
        Set-GuestFault 'verify' { param($w, $req) $o = Get-Reply $w $req; $o.data.facts.kernel = @(1, 2); ConvertTo-Json $o -Depth 6 -Compress }
        (Invoke-Build).Reason | Should -Be 'AAP_HostileGuest'
    }
    It 'fails when the inventory differs from the hosted reference in gate section <Section>' -Tag 'inventory-gate' -TestCases @(
        @{ Section = 'tool_cache'; Class = 'missing-required'; Key = 'Python/3.10.22' },
        @{ Section = 'services'; Class = 'service-mismatch'; Key = 'docker' }, @{ Section = 'path.process'; Class = 'path-order'; Key = 'index 3' },
        @{ Section = 'user'; Class = 'env-mismatch'; Key = 'groups' }, @{ Section = 'action_archive_cache'; Class = 'missing-required'; Key = 'actions_checkout' },
        @{ Section = 'coverage'; Class = 'missing-required'; Key = 'docker' }) {
        $w.CompareReport.inventory.differences += [ordered]@{ class = $Class; section = $Section; key = $Key; reference = 'r'; candidate = $null }
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_VerifyFailed'
        $r.Detail | Should -Match ([regex]::Escape("$Class $Section.$Key"))
        Assert-CleanedUp
    }
    It 'fails when the image lacks what the hosted reference requires in <Section>, a section the image owns' -Tag 'inventory-required' -TestCases @(
        @{ Section = 'tools'; Key = 'gradle' }, @{ Section = 'shells'; Key = 'zsh' }, @{ Section = 'docker'; Key = 'server' }, @{ Section = 'docker.images'; Key = 'alpine:3.22' },
        @{ Section = 'env'; Key = 'JAVA_HOME' }, @{ Section = 'limits'; Key = 'nofile' }, @{ Section = 'limits.sysctl'; Key = 'vm.max_map_count' },
        @{ Section = 'hardware'; Key = 'logical_processors' }) {
        $w.CompareReport.inventory.differences += [ordered]@{ class = 'missing-required'; section = $Section; key = $Key; reference = 'r'; candidate = $null }
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_VerifyFailed'
        $r.Detail | Should -Match ([regex]::Escape("missing-required $Section.$Key"))
        Assert-CleanedUp
    }
    It 'records, and does not fail on, missing-required in <Section>, which the image does not own' -TestCases @(
        @{ Section = 'image'; Key = 'label' }, @{ Section = 'infra'; Key = 'provisioner_version' }, @{ Section = 'run_identity'; Key = 'source_sha' },
        @{ Section = 'credential_env'; Key = 'GITHUB_TOKEN' }) {
        $w.CompareReport.inventory.differences += [ordered]@{ class = 'missing-required'; section = $Section; key = $Key; reference = 'r'; candidate = $null }
        (Invoke-Build).Status | Should -Be 'built'
        $ev = Get-Content -Raw (Join-Path (Get-EvidenceDir) 'build.json') | ConvertFrom-Json
        @($ev.verify.inventory_compare.recorded | ForEach-Object { "$($_.section).$($_.key)" }) | Should -Contain "$Section.$Key"
    }
    It 'records, and does not fail on, differences outside the gate (kernel build, tools, hardware, rig differences)' {
        $w.CompareReport.inventory.differences += [ordered]@{ class = 'version-mismatch'; section = 'tools'; key = 'gradle'; reference = '9.8.1'; candidate = '9.9.0' }
        $w.CompareReport.inventory.differences += [ordered]@{ class = 'documented-rig-difference'; section = 'tool_cache'; key = 'x'; reference = 1; candidate = 2 }
        (Invoke-Build).Status | Should -Be 'built'
        $ev = Get-Content -Raw (Join-Path (Get-EvidenceDir) 'build.json') | ConvertFrom-Json
        @($ev.verify.inventory_compare.recorded | ForEach-Object { "$($_.section).$($_.key)" }) | Should -Be @('image.kernel', 'image.runner_version', 'image.runner_os', 'image.runner_arch', 'tools.gradle')
    }
    It 'refuses a VM worker memory overhead of <Mib> MiB instead of recording it' -Tag 'mem-overhead' -TestCases @(@{ Mib = 5000 }, @{ Mib = 0 }) {
        $w.MemOverheadMib = $Mib
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_BudgetExceeded'
        $r.Detail | Should -Match 'worker overhead'
        Assert-CleanedUp
    }
    It 'fails when the inventory comparison cannot run' {
        $w.CompareExit = 2
        (Invoke-Build).Reason | Should -Be 'AAP_VerifyFailed'
    }
    It 'refuses when the sealed disk changes during the <Step>' -Tag 'base-changed' -TestCases @(@{ Step = 'scan'; Index = 0 }, @{ Step = 'verification'; Index = 1 }) {
        $w | Add-Member -NotePropertyName TamperAt -NotePropertyValue $Index -Force
        $w.Provider.NewDiffDisk = { param($a) Add-FakeCall 'NewDiffDisk' $a; [IO.File]::WriteAllText($a.Path, 'diff')
            if (@($w.Calls | Where-Object { $_.Op -eq 'NewDiffDisk' }).Count -eq $w.TamperAt + 1) { [IO.File]::AppendAllText($a.Parent, 'changed') } }
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_BaseChanged'
        Assert-CleanedUp
    }
    It 'refuses a phase environment with an unresolved variable' -Tag 'plan-variable' {
        Update-TestPlan $w { param($p) ($p.phases | Where-Object { $_.id -eq 'p04' }).env.HELPER_SCRIPTS = '${var.nope}' }
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_PlanInvalid'
        $r.Detail | Should -Match 'unresolved variable'
    }
    It 'refuses a phase environment value that could break out of the guest request' -Tag 'request-value' {
        Update-TestPlan $w { param($p) ($p.phases | Where-Object { $_.id -eq 'p04' }).env.HELPER_SCRIPTS = 'a b' }
        (Invoke-Build).Reason | Should -Be 'AAP_PlanInvalid'
        Assert-CleanedUp
    }
}

Describe 'secret scan of the sealed disk' {
    BeforeEach { $w = New-FakeWorld }
    AfterEach { Remove-World $w }
    It 'publishes on a clean scan and records it with the seal check and the large files' {
        (Invoke-Build).Status | Should -Be 'built'
        $s = Get-Content -Raw (Join-Path (Get-EvidenceDir) 'secret-scan.json') | ConvertFrom-Json
        $s.result | Should -Be 'clean'
        $s.large_files[0].path | Should -Be 'usr/lib/big.so'
        $s.seal.checked.Count | Should -Be 8
        $s.rules | Should -Contain 'build-credential'
    }
    It 'refuses to publish when the scanner found <Rule> and keeps only the scan record' -Tag 'secret-found' -TestCases @(
        @{ Rule = 'build-credential'; Path = 'var/log/installer/autoinstall-user-data' }, @{ Rule = 'runner-credentials'; Path = 'home/runner/actions-runner/.credentials' },
        @{ Rule = 'pem-private-key'; Path = 'etc/ssl/private/ssl-cert-snakeoil.key' }, @{ Rule = 'synthetic-marker'; Path = 'tmp/x' }) {
        $w.ScanReport.findings = @([ordered]@{ rule = $Rule; path = $Path; sha256 = (Get-TextSha 'f') }); $w.ScanReport.findings_count = 1
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_SecretFound'
        $r.Detail | Should -Match ([regex]::Escape("$Rule $Path"))
        Assert-CleanedUp
        $left = @(Get-ChildItem -LiteralPath (Get-EvidenceDir) | ForEach-Object { $_.Name })
        $left | Should -Be @('secret-scan.json')
        (Get-Content -Raw (Join-Path (Get-EvidenceDir) 'secret-scan.json') | ConvertFrom-Json).result | Should -Be 'found'
    }
    It 'turns incomplete when <Case>' -Tag 'scan-incomplete' -TestCases @(
        @{ Case = 'a path was unreadable'; Edit = { param($s) $s.unreadable_count = 1; $s.unreadable = @('find: x: Input/output error') } },
        @{ Case = 'a .gz was not read to its end'; Edit = { param($s) $s.findings = @([ordered]@{ rule = 'unreadable-stream'; path = 'var/log/x.gz'; sha256 = ('a' * 64) }); $s.findings_count = 1 } },
        @{ Case = 'the scanner cut its finding list'; Edit = { param($s) $s.findings_count = 3 } },
        @{ Case = 'there are more large files than listed'; Edit = { param($s) $s.large_files_count = 20000 } }) {
        & $Edit $w.ScanReport
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_ScanIncomplete'
        Assert-CleanedUp
    }
    It 'treats a scan report with <Case> as hostile' -Tag 'scan-shape' -TestCases @(
        @{ Case = 'non-JSON'; Text = 'clean, trust me' },
        @{ Case = 'a value field'; Edit = { param($s) $s.findings = @([ordered]@{ rule = 'pem-private-key'; path = 'x'; sha256 = ('a' * 64); value = 'secret' }) } },
        @{ Case = 'an unknown rule'; Edit = { param($s) $s.findings = @([ordered]@{ rule = 'nothing'; path = 'x'; sha256 = ('a' * 64) }) } },
        @{ Case = 'a missing rule in its rule list'; Edit = { param($s) $s.rules = @($s.rules | Select-Object -Skip 1) } },
        @{ Case = 'a non-printable path'; Edit = { param($s) $s.unreadable = @("a$([char]7)b"); $s.unreadable_count = 1 } },
        @{ Case = 'a negative count'; Edit = { param($s) $s.files_scanned = -1 } },
        @{ Case = 'a large file without a hash'; Edit = { param($s) $s.large_files[0].sha256 = 'x' } }) {
        if ($Text) { $w.ScanText = $Text } else { & $Edit $w.ScanReport }
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_HostileGuest'
        Assert-CleanedUp
    }
    It 'refuses a disk whose layout the scanner did not recognise' -Tag 'scan-layout' {
        $w.ScanText = '{"schema":1,"layout":"unexpected","detail":"partitions are sda1 sda2 sda3 "}'
        Set-GuestFault 'scan' { param($w, $req) '{"schema":1,"phase":"scan","status":"failed","message":"aap-scan: layout"}' }
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_HostileGuest'
        $r.Detail | Should -Match 'layout'
    }
    It 'reports a scanner failure without a report as incomplete' {
        $w.Provider.ReceiveFile = { param($a) Add-FakeCall 'ReceiveFile' $a; if ($a.Name -eq 'scan.json') { throw 'AAP_GuestUnreachable: the guest has no scan.json' }
            [IO.File]::WriteAllText($a.HostPath, $(if ($a.Name -eq 'job-inventory.json') { $w.InventoryText } else { $w.ReportText })) }
        Set-GuestFault 'scan' { param($w, $req) '{"schema":1,"phase":"scan","status":"failed","message":"mount failed"}' }
        (Invoke-Build).Reason | Should -Be 'AAP_ScanIncomplete'
    }
    It 'drops an oversized scan report, inventory or software report and keeps no partial file' -Tag 'receive-size' {
        $w.ReportText = 'x' * (16MB + 1)
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_HostileGuest'
        @(Get-ChildItem -LiteralPath $w.Staging -Recurse -Filter '*.part').Count | Should -Be 0
        Assert-CleanedUp
    }
}

Describe 'secret scan allowlist' {
    BeforeAll {
        $w = New-FakeWorld
        $script:Al = Join-Path $w.Root 'allow.json'
        $script:AlWorld = $w
        function Get-Report($Findings) { $s = Get-FakeScanReport; $s.findings = @($Findings); $s.findings_count = @($Findings).Count; [pscustomobject]($s | ConvertTo-Json -Depth 6 | ConvertFrom-Json) }
        function Set-Allow($Entries) { Write-TestJson ([ordered]@{ schema = 1; entries = @($Entries) }) $script:Al }
    }
    AfterAll { Remove-World $script:AlWorld }
    It 'suppresses a finding only for the exact path and bytes on the allowlist' -Tag 'allowlist-exact' {
        $sha = Get-TextSha 'snakeoil'
        Set-Allow @([ordered]@{ path = 'etc/ssl/private/ssl-cert-snakeoil.key'; sha256 = $sha; justification = 'reviewed in the D2 lab: per-image test key' })
        (Get-AapUbuntuScanResult -Report (Get-Report @([ordered]@{ rule = 'pem-private-key'; path = 'etc/ssl/private/ssl-cert-snakeoil.key'; sha256 = $sha })) -AllowlistPath $script:Al).result | Should -Be 'clean'
        (Get-AapUbuntuScanResult -Report (Get-Report @([ordered]@{ rule = 'pem-private-key'; path = 'etc/ssl/private/ssl-cert-snakeoil.key'; sha256 = (Get-TextSha 'other') })) -AllowlistPath $script:Al).result | Should -Be 'found'
        (Get-AapUbuntuScanResult -Report (Get-Report @([ordered]@{ rule = 'pem-private-key'; path = 'ETC/ssl/private/ssl-cert-snakeoil.key'; sha256 = $sha })) -AllowlistPath $script:Al).result | Should -Be 'found'
    }
    It 'never allowlists the build <Rule>' -Tag 'allowlist-exact' -TestCases @(@{ Rule = 'build-credential' }, @{ Rule = 'build-agent' }) {
        $sha = Get-TextSha 'f'
        Set-Allow @([ordered]@{ path = 'var/lib/x'; sha256 = $sha; justification = 'an attempt to hide the build token or agent' })
        $r = Get-AapUbuntuScanResult -Report (Get-Report @([ordered]@{ rule = $Rule; path = 'var/lib/x'; sha256 = $sha })) -AllowlistPath $script:Al
        $r.result | Should -Be 'found'
        @($r.findings | ForEach-Object { $_.rule }) | Should -Contain $Rule
    }
    It 'refuses an allowlist that lists a path twice' -Tag 'allowlist-duplicate' {
        Set-Allow @([ordered]@{ path = 'etc/x'; sha256 = ('a' * 64); justification = 'the first, reviewed entry' }, [ordered]@{ path = 'etc/x'; sha256 = ('b' * 64); justification = 'a second entry for other bytes' })
        { Read-AapUbuntuAllowlist -Path $script:Al } | Should -Throw 'AAP_AllowlistInvalid*listed twice*'
    }
    It 'counts a .gz the scanner could not read to its end as incomplete, not found, unless an exact entry covers it' -Tag 'allowlist-stream' {
        $sha = Get-TextSha 'damaged fixture'
        $f = [ordered]@{ rule = 'unreadable-stream'; path = 'opt/hostedtoolcache/x/test/corrupt.gz'; sha256 = $sha }
        Set-Allow @()
        $r = Get-AapUbuntuScanResult -Report (Get-Report @($f)) -AllowlistPath $script:Al
        $r.result | Should -Be 'incomplete'
        $r.unreadable_count | Should -Be 1
        @($r.unreadable) | Should -Contain 'unreadable-stream opt/hostedtoolcache/x/test/corrupt.gz'
        @($r.findings).Count | Should -Be 0
        Set-Allow @([ordered]@{ path = $f.path; sha256 = $sha; justification = 'reviewed in the D2 lab: an upstream test fixture shipped damaged' })
        (Get-AapUbuntuScanResult -Report (Get-Report @($f)) -AllowlistPath $script:Al).result | Should -Be 'clean'
        Set-Allow @([ordered]@{ path = $f.path; sha256 = (Get-TextSha 'other bytes'); justification = 'reviewed for other bytes than the image has' })
        (Get-AapUbuntuScanResult -Report (Get-Report @($f)) -AllowlistPath $script:Al).result | Should -Be 'found'   # the stale entry is itself a finding
    }
    It 'fails on an allowlist entry that matches nothing' -Tag 'allowlist-stale' {
        Set-Allow @([ordered]@{ path = 'etc/gone'; sha256 = (Get-TextSha 'g'); justification = 'a file the image no longer has' })
        $r = Get-AapUbuntuScanResult -Report (Get-Report @()) -AllowlistPath $script:Al
        $r.result | Should -Be 'found'
        $r.findings[0].rule | Should -Be 'allowlist-mismatch'
    }
    It 'refuses an allowlist entry with <Case>' -Tag 'allowlist' -TestCases @(
        @{ Case = 'a wildcard'; Entry = [ordered]@{ path = 'etc/*'; sha256 = ('a' * 64); justification = 'too broad to review' } },
        @{ Case = 'a parent step'; Entry = [ordered]@{ path = 'etc/../root/x'; sha256 = ('a' * 64); justification = 'escapes its folder' } },
        @{ Case = 'an absolute path'; Entry = [ordered]@{ path = '/etc/shadow'; sha256 = ('a' * 64); justification = 'absolute paths are not allowed' } },
        @{ Case = 'no hash'; Entry = [ordered]@{ path = 'etc/x'; justification = 'missing its hash' } },
        @{ Case = 'a short justification'; Entry = [ordered]@{ path = 'etc/x'; sha256 = ('a' * 64); justification = 'ok' } },
        @{ Case = 'an extra field'; Entry = [ordered]@{ path = 'etc/x'; sha256 = ('a' * 64); justification = 'has another field'; rule = 'pem-private-key' } }) {
        Set-Allow @($Entry)
        { Read-AapUbuntuAllowlist -Path $script:Al } | Should -Throw 'AAP_AllowlistInvalid*'
    }
    It 'the committed allowlist is valid and empty' {
        @(Read-AapUbuntuAllowlist -Path (Join-Path $script:Repo 'images\ubuntu-24.04\secret-allowlist.json')).Count | Should -Be 0
    }
}

Describe 'seeds and requests are host-authored and bounded' {
    BeforeAll {
        $script:SPlan = Get-PlanText | ConvertFrom-Json
        # A declaration as the host network module returns it for the build VM (the shared fake host's build switch).
        $script:Decl = [ordered]@{ schema = 1; kind = 'host_network_attach'; vm_id = '0b0b0b0b-1111-4222-8333-444455556666'; vm_name = 'aap-lbuild-0123abcd'; profile = 'linux'
            subnet = '172.31.253.0/24'; gateway = '172.31.253.1'; address = '172.31.253.2'; resolvers = @('192.0.2.53', '198.51.100.53'); endpoints = @() }
    }
    It 'refuses a malformed instance id, a scanner without the build token, a known token for any other guest, and a network for any but the build' -Tag 'seed-values' {
        $known = (New-AapUbuntuSeed -Mode build -Plan $script:SPlan -InstanceId 'aap-1-build' -Network $script:Decl).Token
        { New-AapUbuntuSeed -Mode build -Plan $script:SPlan -InstanceId 'aap-1-build' } | Should -Throw 'AAP_SeedInvalid*'
        { New-AapUbuntuSeed -Mode verify -Plan $script:SPlan -InstanceId 'aap-1-verify' -Network $script:Decl } | Should -Throw 'AAP_SeedInvalid*'
        { New-AapUbuntuSeed -Mode verify -Plan $script:SPlan -InstanceId "x`nlocal-hostname: evil" } | Should -Throw 'AAP_SeedInvalid*'
        { New-AapUbuntuSeed -Mode scan -Plan $script:SPlan -InstanceId 'aap-1-scan' } | Should -Throw 'AAP_SeedInvalid*'
        { New-AapUbuntuSeed -Mode scan -Plan $script:SPlan -InstanceId 'aap-1-scan' -Known ('a' * 64) } | Should -Throw 'AAP_SeedInvalid*'
        { New-AapUbuntuSeed -Mode verify -Plan $script:SPlan -InstanceId 'aap-1-verify' -Known $known } | Should -Throw 'AAP_SeedInvalid*'
        (New-AapUbuntuSeed -Mode scan -Plan $script:SPlan -InstanceId 'aap-1-scan' -Known $known).Files['user-data'] | Should -Match 'aap-build/known'
    }
    It 'refuses a plan value that could break out of the seed YAML: <Case>' -Tag 'seed-values' -TestCases @(
        @{ Case = 'kernel package'; Edit = { param($p) $p.base.kernel_package = "linux-azure`n  late-commands: [reboot]" } },
        @{ Case = 'masked service'; Edit = { param($p) $p.base.masked_services = @('walinuxagent.service; rm -rf /') } },
        @{ Case = 'job user group'; Edit = { param($p) $p.job_user.groups = @('sudo]', 'x') } }) {
        $p = Get-PlanText | ConvertFrom-Json
        & $Edit $p
        { New-AapUbuntuSeed -Mode build -Plan $p -InstanceId 'aap-1-build' -Network $script:Decl } | Should -Throw 'AAP_PlanInvalid*'
    }
    It 'refuses a declaration value that could break out of the seed YAML: <Case>' -Tag 'seed-network' -TestCases @(
        @{ Case = 'address'; Edit = { param($d) $d.address = "172.31.253.2]`n  late-commands: [reboot" } },
        @{ Case = 'gateway'; Edit = { param($d) $d.gateway = 'gw' } },
        @{ Case = 'resolver'; Edit = { param($d) $d.resolvers = @('192.0.2.53, 1.1.1.1') } },
        @{ Case = 'no resolver'; Edit = { param($d) $d.resolvers = @() } },
        @{ Case = 'prefix length'; Edit = { param($d) $d.subnet = '172.31.253.0/24]' } }) {
        $d = [ordered]@{}; foreach ($k in $script:Decl.Keys) { $d[$k] = $script:Decl[$k] }
        & $Edit $d
        { New-AapUbuntuSeed -Mode build -Plan $script:SPlan -InstanceId 'aap-1-build' -Network $d } | Should -Throw 'AAP_SeedInvalid*'
        (New-AapUbuntuSeed -Mode build -Plan $script:SPlan -InstanceId 'aap-1-build' -Network $script:Decl).Files['user-data'] | Should -Match 'addresses: \[172\.31\.253\.2/24\]'
    }
    It 'makes a distinct token per seed, which prints as [aap token] and never as its value' {
        $s = @(1..20 | ForEach-Object { New-AapUbuntuSeed -Mode verify -Plan $script:SPlan -InstanceId 'aap-1-verify' })
        $hex = @($s | ForEach-Object { [regex]::Match($_.Files['user-data'], "content: '([0-9a-f]{64})'").Groups[1].Value })
        @($hex | Sort-Object -Unique).Count | Should -Be 20
        foreach ($x in $hex) { $x | Should -MatchExactly '^[0-9a-f]{64}$' }
        $s[0].Token.Length | Should -Be 64
        "$($s[0].Token)" | Should -Be '[aap token]'
        $shown = (@("$($s[0])", ([pscustomobject]@{ Token = $s[0].Token } | Out-String), ($s[0].Token | Format-List * | Out-String), "$([pscustomobject]@{ Token = $s[0].Token })") -join "`n")
        $shown.Contains($hex[0]) | Should -BeFalse
        $ms = New-Object IO.MemoryStream
        $s[0].Token.WriteTo($ms)
        [Text.Encoding]::ASCII.GetString($ms.ToArray()) | Should -BeExactly $hex[0]
    }
    It 'turns token bytes into text only where the seed is assembled: no token parameter, interpolation or other byte read' {
        # Tokens travel as AapToken objects (they print as [aap token]); PowerShell module logging (event 4103) records command
        # parameters, so the raw value may become a string only in New-AapUbuntuSeed's two Replace calls, never in a parameter.
        foreach ($f in 'AapUbuntuImage.psm1', 'AapUbuntuImage.HyperV.psm1') {
            $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Repo "images\ubuntu-24.04\$f"), [ref]$null, [ref]$null)
            $seedFn = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'New-AapUbuntuSeed' }, $true))
            $inSeed = { param($n) $seedFn.Count -eq 1 -and $n.Extent.StartOffset -ge $seedFn[0].Extent.StartOffset -and $n.Extent.EndOffset -le $seedFn[0].Extent.EndOffset }
            $reads = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.MemberExpressionAst] -and $n.Member.Extent.Text -ceq 'Bytes' -and $n.Expression.Extent.Text -ne '$this' }, $true))
            @($reads | Where-Object { -not (& $inSeed $_) } | ForEach-Object { $_.Extent.Text }) | Should -BeNullOrEmpty -Because $f
            @($reads | Where-Object { $_.Parent.Extent.Text -notmatch '^\[Text\.Encoding\]::ASCII\.GetString\(' }).Count | Should -Be 0 -Because $f
            $made = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Extent.Text -eq '[AapToken]::new()' }, $true))
            @($made | Where-Object { -not (& $inSeed $_) }).Count | Should -Be 0 -Because $f
            $strings = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.ExpandableStringExpressionAst] -and $n.Extent.Text -match '(?i)token|known' -and $n.Extent.Text -match '\$' }, $true) |
                    Where-Object { @($_.NestedExpressions | Where-Object { $_.Extent.Text -match '(?i)\.Token\b|\$token\b|\.Known\b|\$known\b' }).Count })
            @($strings | ForEach-Object { $_.Extent.Text }) | Should -BeNullOrEmpty -Because $f
            @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.ParameterAst] -and $n.Name.VariablePath.UserPath -eq 'Token' }, $true)).Count | Should -Be 0 -Because $f
        }
        $seeds = @([Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Repo 'images\ubuntu-24.04\AapUbuntuImage.psm1'), [ref]$null, [ref]$null).FindAll({ param($n) $n -is [Management.Automation.Language.MemberExpressionAst] -and $n.Member.Extent.Text -ceq 'Bytes' -and $n.Expression.Extent.Text -ne '$this' }, $true))
        $seeds.Count | Should -Be 2
    }
    It 'writes a request the agent parses: fixed keys, then env, script and var lines' {
        $r = New-AapUbuntuRequest -Phase 'p04' -Kind 'scripts' -Fields @{ exec = 'root'; pause_before = 0 } -Env @('A=b') -Scripts @("x.sh $('a' * 64)") -Vars ([pscustomobject]@{ image_folder = '/imagegeneration' })
        $r | Should -Be ("schema=1`nphase=p04`nkind=scripts`nexec=root`npause_before=0`nenv=A=b`nscript=x.sh $('a' * 64)`nvar=image_folder=/imagegeneration`n")
    }
    It 'refuses a request line the agent would refuse: <Case>' -Tag 'request-value' -TestCases @(
        @{ Case = 'quote in env'; Env = @("A=it's") }, @{ Case = 'space in env'; Env = @('A=a b') }, @{ Case = 'newline in env'; Env = @("A=a`nkind=action") }) {
        { New-AapUbuntuRequest -Phase 'p04' -Kind 'scripts' -Env $Env } | Should -Throw 'AAP_PlanInvalid*'
    }
}

Describe 'budget record' {
    It 'refuses to write a budget from a size that was not measured' -Tag 'budget-measured' {
        { New-AapUbuntuBudgetRecord -GenerationId 'ubuntu-24.04-x64/20261012.334.1-aap.1' -BaseBytes 0 -ClonePeakBytes 1 -StagingPeakBytes 1 -MemOverheadMib 1 -EvidenceRef 'evidence/x' -MeasuredAt '2026-10-20T00:00:00Z' } | Should -Throw 'AAP_BudgetUnmeasured*'
        { New-AapUbuntuBudgetRecord -GenerationId 'ubuntu-24.04-x64/20261012.334.1-aap.1' -BaseBytes 1 -ClonePeakBytes 0 -StagingPeakBytes 1 -MemOverheadMib 1 -EvidenceRef 'evidence/x' -MeasuredAt '2026-10-20T00:00:00Z' } | Should -Throw 'AAP_BudgetUnmeasured*'
    }
    It 'sets every cap at or above its measured peak, with no scratch disk' {
        $b = New-AapUbuntuBudgetRecord -GenerationId 'ubuntu-24.04-x64/20261012.334.1-aap.1' -BaseBytes (59.2 * 1GB) -ClonePeakBytes (21.3 * 1GB) -StagingPeakBytes (80 * 1GB) -MemOverheadMib 300 -EvidenceRef 'evidence/x' -MeasuredAt '2026-10-20T00:00:00Z'
        $b.base_gib | Should -Be 60
        $b.clone_peak_gib | Should -Be 22
        $b.clone_gib_max | Should -BeGreaterOrEqual $b.clone_peak_gib
        $b.clone_gib_max | Should -Be 28
        $b.scratch_gib_max | Should -Be 0
        $b.replacement_gib | Should -Be $b.base_gib
    }
}

Describe 'partial builds and evidence ownership' {
    BeforeEach { $w = New-FakeWorld }
    AfterEach { Remove-World $w }
    It 'cleans a crashed build that had begun publishing, then builds' {
        $bd = Join-Path $w.Staging "build\$script:BuildId"; $gd = Join-Path $w.Base 'ubuntu-24.04-x64\20261012.334.1-aap.1'
        [void][IO.Directory]::CreateDirectory($bd); [void][IO.Directory]::CreateDirectory($gd)
        [IO.File]::WriteAllText((Join-Path $gd 'base.vhdx.partial'), 'half')
        Write-TestJson ([ordered]@{ schema = 1; status = 'running'; steps = [ordered]@{ publish = 'intent' }; written = @(); evidence_created = $false }) (Join-Path $bd 'state.json')
        $r = Invoke-Build
        $r.Status | Should -Be 'built'
        $r.PartialCleaned | Should -BeTrue
        (Get-Ops $w 'RemoveVm' | ForEach-Object { $_.Args.Name } | Select-Object -First 3) -join ',' | Should -Match '^aap-lbuild-[0-9a-f]{8},aap-lscan-[0-9a-f]{8},aap-lverify-[0-9a-f]{8}$'
    }
    It 'keeps a finished generation when only the build folder survived a crash' {
        (Invoke-Build).Status | Should -Be 'built'
        $bd = Join-Path $w.Staging "build\$script:BuildId"
        [void][IO.Directory]::CreateDirectory($bd)
        Write-TestJson ([ordered]@{ schema = 1; status = 'done'; steps = [ordered]@{ publish = 'done' }; written = @('generation.json'); evidence_created = $true }) (Join-Path $bd 'state.json')
        (Invoke-Build).Status | Should -Be 'unchanged'
        Test-Path (Join-Path (Get-EvidenceDir) 'generation.json') | Should -BeTrue
    }
    It 'cleans exactly the evidence files a crashed run listed' {
        $bd = Join-Path $w.Staging "build\$script:BuildId"; $ev = Get-EvidenceDir
        [void][IO.Directory]::CreateDirectory($bd); [void][IO.Directory]::CreateDirectory($ev)
        foreach ($f in 'software-report.md', 'secret-scan.json', 'other.txt') { [IO.File]::WriteAllText((Join-Path $ev $f), 'x') }
        Write-TestJson ([ordered]@{ schema = 1; status = 'running'; steps = [ordered]@{}; written = @('software-report.md', 'secret-scan.json', '..\..\x'); evidence_created = $true }) (Join-Path $bd 'state.json')
        Remove-AapUbuntuBuild -Storage (Read-AapStorageRecord -Path $w.StoragePath) -Provider $w.Provider -Names (Get-AapUbuntuNames $w.Plan 1) -EvidenceRoot $w.Evidence
        @(Get-ChildItem -LiteralPath $ev | ForEach-Object { $_.Name } | Sort-Object) | Should -Be @('other.txt', 'secret-scan.json')
        Test-Path $bd | Should -BeFalse
    }
    It 'leaves a generation folder that appeared during the build to whoever made it' -Tag 'gen-race' {
        $w.Provider.CompareInventory = { param($a) Add-FakeCall 'CompareInventory' $a; Write-TestJson $w.CompareReport $a.Out
            [void][IO.Directory]::CreateDirectory((Join-Path $w.Base 'ubuntu-24.04-x64\20261012.334.1-aap.1')); 1 }
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_GenerationExists'
        Test-Path (Join-Path $w.Base 'ubuntu-24.04-x64\20261012.334.1-aap.1') | Should -BeTrue
    }
    It 'removes the partial generation when the published copy does not match' -Tag 'publish-hash' {
        $w.Provider.SetReadOnlyAcl = { param($a) throw 'should not be reached' }
        Mock -ModuleName AapUbuntuImage Get-AapSha256File { if ($Path -like '*base.vhdx.partial') { '0' * 64 } else { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() } }
        $r = Invoke-Build
        $r.Reason | Should -Be 'AAP_PublishMismatch'
        Assert-CleanedUp
    }
    It 'refuses a junction where the evidence goes and writes nothing through it' {
        $target = Join-Path $w.Root 'elsewhere'; [void][IO.Directory]::CreateDirectory($target)
        $null = cmd /c mklink /J (Join-Path $w.Evidence 'P07') $target
        (Invoke-Build).Reason | Should -Be 'AAP_StorageUntrusted'
        @(Get-ChildItem -LiteralPath $target).Count | Should -Be 0
    }
}

Describe 'the production provider (static: it is never run here)' {
    BeforeAll {
        $script:ProvText = Get-Content -Raw (Join-Path $script:Repo 'images\ubuntu-24.04\AapUbuntuImage.HyperV.psm1')
        Import-Module (Join-Path $script:Repo 'images\ubuntu-24.04\AapUbuntuImage.HyperV.psm1') -Force
        $script:Prov = New-AapUbuntuHyperVProvider -PythonPath (Get-Process -Id $PID).Path
    }
    It 'implements every op the builder calls' {
        foreach ($op in (& (Get-Module AapUbuntuImage) { $script:ProviderOps })) { $script:Prov[$op] | Should -BeOfType [scriptblock] -Because $op }
    }
    It 'refuses a python path that is not an absolute file' {
        { New-AapUbuntuHyperVProvider -PythonPath 'python.exe' } | Should -Throw 'AAP_ProviderInvalid*'
    }
    It 'names the python install folder for the builder trust check' {
        @(& $script:Prov.ExecFolders @{}) | Should -Be @((Split-Path -Parent (Get-Process -Id $PID).Path))
    }
    It 'makes every VM with no network adapter and attaches none itself: the host network module does' {
        $script:ProvText | Should -Match '@\(Hyper-V\\Get-VMNetworkAdapter -VM \$vm\) \| Hyper-V\\Remove-VMNetworkAdapter'
        $script:ProvText | Should -Not -Match 'Connect-VMNetworkAdapter|Set-VMNetworkAdapter |Add-VMNetworkAdapter|ExtendedAcl -VMNetworkAdapter \$now|aap-guests|GuestNetwork|DenyRanges'
    }
    It 'reads a VM''s adapters back exactly in the provider shape host-network-module.md prescribes' {
        # Every code line of the contract's read-back block appears in GetVmNetwork, so the shared check sees what Hyper-V shows.
        $contract = Get-Content -Raw (Join-Path $script:Repo 'parity\contracts\host-network-module.md')
        $block = [regex]::Match($contract, '(?s)```powershell\r?\n(foreach \(\$n in .*?)```').Groups[1].Value
        $lines = @($block.Split("`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
        $lines.Count | Should -BeGreaterThan 10
        $prov = @($script:ProvText.Split("`n") | ForEach-Object { $_.Trim() })
        foreach ($l in $lines) { $prov | Should -Contain $l }
    }
    It 'puts the seed image into the last DVD drive, only while the VM is Off' {
        $script:ProvText | Should -Match "if \(\[string\]\`$vm.State -ne 'Off' -or \`$drives.Count -lt 1\) \{ throw"
        $script:ProvText | Should -Match 'Hyper-V\\Set-VMDvdDrive -VMDvdDrive \$drives\[-1\] -Path \$a\.Path'
        $script:ProvText | Should -Match '(?m)^        Hyper-V\\Add-VMDvdDrive -VM \$vm$'
    }
    It 'never attaches or mounts a guest disk, and never builds a seed by mounting one' {
        $script:ProvText | Should -Not -Match 'Mount-VHD|Mount-DiskImage|Add-PartitionAccessPath|Get-Partition|Expand-WindowsImage'
        $script:ProvText | Should -Match "Optimize-VHD -Path \`$a.Vhdx -Mode Pretrimmed"
    }
    It 'disables key-value exchange and guest services, automatic start and checkpoints' {
        $script:ProvText | Should -Match "'Guest Service Interface', 'Key-Value Pair Exchange'"
        $script:ProvText | Should -Match '-CheckpointType Disabled -AutomaticStopAction TurnOff -AutomaticStartAction Nothing'
        $script:ProvText | Should -Match 'AutomaticStartAction = \[string\]\$vm\.AutomaticStartAction; CheckpointType = \[string\]\$vm\.CheckpointType'
        $script:ProvText | Should -Not -Match 'EnhancedSession|ExposeVirtualizationExtensions'
    }
    It 'talks to a guest only through the capped hvsocket call, and writes bytes without a BOM' {
        $script:ProvText | Should -Match 'if \(total > maxBytes\)'
        $script:ProvText | Should -Match 'Text.UTF8Encoding\(\$false\)'
        $script:ProvText | Should -Not -Match 'StandardInput|Invoke-Command|New-PSSession|ssh\.exe'
    }
    It 'caps a guest reply while it arrives: <Bytes> bytes against a <Cap>-byte cap' -TestCases @(
        @{ Bytes = 0; Cap = 64; Ok = $true }, @{ Bytes = 64; Cap = 64; Ok = $true }, @{ Bytes = 65; Cap = 64; Ok = $false }, @{ Bytes = 200000; Cap = 65536; Ok = $false }) {
        $temp = $env:TEMP
        & (Get-Module AapUbuntuImage.HyperV) { param($d) Initialize-AapTypes $d } ([string]$TestDrive)
        $env:TEMP | Should -Be $temp
        $src = New-Object IO.MemoryStream(, (New-Object byte[] $Bytes)); $dst = New-Object IO.MemoryStream
        if ($Ok) { [AapHvChannel]::Copy($src, $dst, $Cap, 5000) | Should -Be $Bytes; $dst.Length | Should -Be $Bytes }
        else { { [AapHvChannel]::Copy($src, $dst, $Cap, 5000) } | Should -Throw '*AAP_HostileGuest*'; $dst.Length | Should -BeLessOrEqual $Cap }
    }
    It 'refuses a reply that is not printable ASCII, and reads a missing guest file as unreachable, never as empty' {
        Mock -ModuleName AapUbuntuImage.HyperV Invoke-AapChannel { $b = [byte[]](0x6f, 0x6b, 0x07); $Reply.Write($b, 0, 3); 3 }
        { & $script:Prov.InvokeGuest @{ Verb = 'run' } } | Should -Throw 'AAP_HostileGuest*'
        Mock -ModuleName AapUbuntuImage.HyperV Invoke-AapChannel { $b = [byte[]](0x72, 0x65, 0x61, 0x64, 0x79, 0x0a); $Reply.Write($b, 0, 6); 6 }
        & $script:Prov.InvokeGuest @{ Verb = 'ready' } | Should -Be "ready`n"
        Mock -ModuleName AapUbuntuImage.HyperV Invoke-AapChannel { 0 }
        $f = Join-Path $TestDrive 'recv.part'
        { & $script:Prov.ReceiveFile @{ VmId = [guid]::NewGuid().ToString(); Port = 5223; Token = ('a' * 64); Name = 'scan.json'; HostPath = $f; MaxBytes = 10; TimeoutSeconds = 1 } } | Should -Throw 'AAP_GuestUnreachable*'
        { & $script:Prov.ReceiveFile @{ VmId = [guid]::NewGuid().ToString(); Port = 5223; Token = ('a' * 64); Name = 'scan.json'; HostPath = $f; MaxBytes = 10; TimeoutSeconds = 1 } } | Should -Throw   # created new: an existing file is never written through
    }
    It 'starts its one child process without a window, as isolated python (-B -I -S), and its timeout is the only wait' {
        $script:ProvText | Should -Match ([regex]::Escape("`$psi.Arguments = ('-B -I -S `"{0}`" compare"))
        $script:ProvText | Should -Match 'CreateNoWindow = \$true'
        $script:ProvText | Should -Match 'UseShellExecute = \$false'
        $script:ProvText | Should -Match '\$out = \$proc\.StandardOutput\.ReadToEndAsync\(\); \$err = \$proc\.StandardError\.ReadToEndAsync\(\)'
        $script:ProvText | Should -Not -Match 'StandardOutput\.ReadToEnd\(\)'
    }
    It 'compiles its types with TEMP and TMP in the build folder, and writes the token into the channel header by bytes' {
        $script:ProvText | Should -Match '\$env:TEMP = \$TempDir; \$env:TMP = \$TempDir; Add-Type'
        $script:ProvText | Should -Match 'Initialize-AapTypes \(\[IO.Path\]::GetDirectoryName\(\$a.Path\)\)'
        $script:ProvText | Should -Match '\$A\.Token\.WriteTo\(\$hs\)'
    }
    It 'does not wait out a hostile guest while it waits for the guest to be ready' {
        Mock -ModuleName AapUbuntuImage.HyperV Start-Sleep { }
        Mock -ModuleName AapUbuntuImage.HyperV Invoke-AapChannel { throw 'AAP_HostileGuest: the guest sent over 64 bytes' }
        { & $script:Prov.WaitGuestReady @{ VmId = [guid]::NewGuid().ToString(); Port = 5223; Token = $null; TimeoutSeconds = 60 } } | Should -Throw 'AAP_HostileGuest*'
        Mock -ModuleName AapUbuntuImage.HyperV Invoke-AapChannel { throw 'AAP_GuestUnreachable: the guest channel failed' }
        & $script:Prov.WaitGuestReady @{ VmId = [guid]::NewGuid().ToString(); Port = 5223; Token = $null; TimeoutSeconds = 1 } | Should -BeFalse
    }
}

Describe 'the P06 helpers this builder shares (imported from images\windows, not copied)' {
    # The builder calls these five by name and parameter. A change to any of their signatures in images\windows must fail
    # here first (INTEGRATION.md, P06 dependency).
    It '<Name> keeps the parameters P07 calls it with' -TestCases @(
        @{ Name = 'Read-AapStorageRecord'; Params = @('Path') }, @{ Name = 'Get-AapPathKind'; Params = @('Path') },
        @{ Name = 'Assert-AapPlainPath'; Params = @('Root', 'Path', 'Reason', 'Create') }, @{ Name = 'Remove-AapTree'; Params = @('Path', 'Under') },
        @{ Name = 'Set-AapReadOnlyAcl'; Params = @('Path', 'Owner', 'Readers') }) {
        $c = Get-Command -Module AapWinImage -Name $Name
        $common = [Management.Automation.PSCmdlet]::CommonParameters + [Management.Automation.PSCmdlet]::OptionalCommonParameters
        @($c.Parameters.Values | Where-Object { $common -notcontains $_.Name } | ForEach-Object { $_.Name }) | Should -Be $Params
        $c.Module.Path | Should -Be ([IO.Path]::GetFullPath((Join-Path $script:Repo 'images\windows\AapWinImage.psm1')))
    }
    It 'is loaded by path from the folder beside the builder, which the self-check covers' {
        $text = Get-Content -Raw (Join-Path $script:Repo 'images\ubuntu-24.04\AapUbuntuImage.psm1')
        $text | Should -Match ([regex]::Escape("Import-Module (Join-Path `$PSScriptRoot '..\windows\AapWinImage.psm1')"))
        $text | Should -Match ([regex]::Escape("[IO.Path]::GetFullPath((Join-Path `$here '..\windows'))"))
    }
}

Describe 'source rules for everything P07 authors' {
    BeforeAll {
        $script:Dir = Join-Path $script:Repo 'images\ubuntu-24.04'
        $dir = $script:Dir
        $script:All = @(Get-ChildItem -LiteralPath $dir -Recurse -File) + @(Get-ChildItem -LiteralPath (Join-Path $script:Repo 'tests\images\ubuntu-24.04') -File)
        $script:PsFiles = @($script:All | Where-Object { $_.Extension -eq '.ps1' -or $_.Extension -eq '.psm1' })
        $script:ShFiles = @($script:All | Where-Object { $_.Extension -eq '.sh' })
    }
    It 'never downloads: no web cmdlet, client or fetch tool in the builder, provider or guest scripts' {
        foreach ($f in @($script:PsFiles + $script:ShFiles | Where-Object { $_.FullName.StartsWith($script:Dir) })) {
            (Get-Content -Raw $f.FullName) | Should -Not -Match 'Invoke-WebRequest|Invoke-RestMethod|WebClient|HttpClient|Start-BitsTransfer|\bcurl\b|\bwget\b|apt-get|DownloadFile' -Because $f.Name
        }
    }
    It 'uses none of the patterns the host AV flags' {
        foreach ($f in @($script:PsFiles | Where-Object { $_.FullName.StartsWith($script:Dir) })) {
            (Get-Content -Raw $f.FullName) | Should -Not -Match 'Invoke-Expression|\biex\b|-EncodedCommand|FromBase64String|SecureStringToBSTR|AsPlainText|ConvertTo-SecureString|\[char\]\s*0x|\[char\]\s*\d{2,}\s*\+' -Because $f.Name
        }
    }
    It 'is plain ASCII with LF endings, so Windows PowerShell 5.1 reads it as written and no bidi control hides in it' {
        foreach ($f in $script:All) {
            $b = [IO.File]::ReadAllBytes($f.FullName)
            @($b | Where-Object { $_ -gt 126 -or ($_ -lt 32 -and $_ -ne 10 -and $_ -ne 9) }).Count | Should -Be 0 -Because $f.Name
        }
    }
    It 'parses on this PowerShell host' {
        foreach ($f in $script:PsFiles) {
            $e = $null; [void][Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$e)
            @($e).Count | Should -Be 0 -Because $f.Name
        }
    }
    It 'every check tag in the builder guards an if-statement and has a test' {
        $text = Get-Content -Raw (Join-Path $script:Repo 'images\ubuntu-24.04\AapUbuntuImage.psm1')
        $tags = @([regex]::Matches($text, '# check:([a-z-]+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $tests = Get-Content -Raw (Join-Path $PSScriptRoot 'UbuntuImage.Tests.ps1')
        foreach ($t in $tags) { $tests | Should -Match ("-Tag[^\r\n]*'" + [regex]::Escape($t) + "'") -Because "check:$t needs a tagged test" }
    }
}
