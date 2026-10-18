# First-run orchestration. Every host action is mocked; no WSL or task is started.
Describe 'helper first-run install' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\installer\helper-run.ps1')
        function Invoke-AapInstallCaptured([scriptblock]$Script) {
            $writer = New-Object IO.StringWriter
            $saved = [Console]::Out
            [Console]::SetOut($writer)
            try { $code = & $Script } finally { [Console]::SetOut($saved) }
            return [pscustomobject]@{ Code = [int]$code; Out = $writer.ToString() }
        }
    }

    It 'validates sizing without coercing strings, fractions, or excessive pools' {
        $good = [pscustomobject]@{ runner_count = 5; job_cpus = 26; job_memory_gib = 72; work_disk_gib = 100 }
        { Assert-AapInstallSizing $good } | Should -Not -Throw
        foreach ($pair in @(@('runner_count', 6), @('runner_count', '2'), @('job_cpus', 2), @('job_memory_gib', 4), @('work_disk_gib', 513), @('work_disk_gib', 59), @('job_cpus', 5.5))) {
            $bad = $good.PSObject.Copy()
            $bad.($pair[0]) = $pair[1]
            { Assert-AapInstallSizing $bad } | Should -Throw '*refusing*'
        }
    }

    It 'reads the strict schema 2 install request while keeping identity schema 1 separate' {
        Mock Get-AapRequestOwnerProfile { return 'C:\Users\fixture' }
        $path = Join-Path $TestDrive 'request.json'
        $body = [ordered]@{ schema = 2; id = '0123456789abcdef'; verb = 'install'; org = 'acme'; app_id = 123; installation_id = 456; group = 'aap-crrr'; labels = 'self-hosted,linux,crrr'; key_path = 'C:\Users\fixture\app.pem'; runner_count = 2; job_cpus = 8; job_memory_gib = 16; work_disk_gib = 100 }
        [IO.File]::WriteAllText($path, ($body | ConvertTo-Json -Compress))
        $req = Read-AapIdentityRequest $path '0123456789abcdef' 'install'
        $req.RunnerCount | Should -Be 2
        $req.WorkDiskGiB | Should -Be 100
        { Read-AapIdentityRequest $path '0123456789abcdef' } | Should -Throw '*request*'
        foreach ($bad in @(@{ schema = 1 }, @{ schema = '2' }, @{ org = 123 }, @{ runner_count = '2' }, @{ group = 'other' }, @{ labels = 'self-hosted,linux,crrr,extra' }, @{ labels = 'self-hosted,linux,fresh' }, @{ path = 'C:\Windows' })) {
            $changed = [ordered]@{}
            foreach ($name in $body.Keys) { $changed[$name] = $body[$name] }
            foreach ($name in $bad.Keys) { $changed[$name] = $bad[$name] }
            [IO.File]::WriteAllText($path, ($changed | ConvertTo-Json -Compress))
            { Read-AapIdentityRequest $path '0123456789abcdef' 'install' } | Should -Throw '*refusing*'
        }
    }

    It 'refuses existing hosts and active pools independently of a checkpoint' {
        Get-AapInstallRefusal $null 'missing' 'present' '' | Should -Match 'existing distro'
        Get-AapInstallRefusal $null 'ready' 'absent' '' | Should -Match 'supervisor'
        Get-AapInstallRefusal $null 'missing' 'unknown' '' | Should -Match 'inspect'
        $saved = [pscustomobject]@{ phase = 'identity' }
        Get-AapInstallRefusal $saved 'running' 'present' '' | Should -Match 'supervisor'
        Get-AapInstallRefusal $saved 'missing' 'present' 'running' | Should -Match 'active'
        Get-AapInstallRefusal $saved 'missing' 'present' '' | Should -BeNullOrEmpty
        Get-AapInstallRefusal $saved 'missing' 'absent' '' | Should -Match 'missing distro'
    }

    It 'binds checkpoint sizing and authenticated identity while allowing pre-authentication correction' {
        $req = [pscustomobject]@{ Org = 'acme'; AppId = '123'; InstallationId = '456'; Group = 'aap-crrr'; Labels = 'self-hosted,linux,crrr'; RunnerCount = 2; JobCpus = 8; JobMemoryGiB = 16; WorkDiskGiB = 100 }
        $saved = New-AapInstallState $req '0123456789abcdef' 'identity'
        { Assert-AapInstallState $saved $req } | Should -Not -Throw
        $saved.work_disk_gib = 200
        { Assert-AapInstallState $saved $req } | Should -Throw '*changed*'
        $saved = New-AapInstallState $req '0123456789abcdef' 'identity'
        $saved.org = 'other'
        { Assert-AapInstallState $saved $req } | Should -Not -Throw
        $saved = New-AapInstallState $req '0123456789abcdef' 'supervisor'
        $saved.org = 'other'
        { Assert-AapInstallState $saved $req } | Should -Throw '*changed*'
        $saved = New-AapInstallState $req '0123456789abcdef' 'identity'
        $saved.phase = 'shell'
        { Assert-AapInstallState $saved $req } | Should -Throw '*checkpoint*'
        ($saved | ConvertTo-Json) | Should -Not -Match 'key_path|Profile'
    }

    It 'does not execute host actions when existing installation is refused' {
        $req = [pscustomobject]@{ Org = 'acme'; AppId = '123'; InstallationId = '456'; Group = 'aap-crrr'; Labels = 'self-hosted,linux,crrr'; RunnerCount = 2; JobCpus = 8; JobMemoryGiB = 16; WorkDiskGiB = 100 }
        Mock Read-AapIdentityRequest { return $req }
        Mock Assert-AapInstallArea { }
        Mock Read-AapInstallState { return $null }
        Mock Get-AapSupervisorTaskState { return 'running' }
        Mock Get-AapInstallDistroState { return 'present' }
        Mock Read-AapJsonBounded { return $null }
        Mock Invoke-AapStreaming { throw 'host action must not run' }
        Mock Get-AapIdentityKeyView { throw 'key must not be opened' }
        $result = Invoke-AapInstallCaptured { Invoke-AapInstallSteps $TestDrive '0123456789abcdef' 'C:\Program Files\aap-runner\aap-runner-tray.exe' }
        $result.Code | Should -Be 2
        $result.Out | Should -Match 'supervisor'
        Should -Invoke Invoke-AapStreaming -Times 0
        Should -Invoke Get-AapIdentityKeyView -Times 0
    }

    Context 'install phase execution' {
        BeforeEach {
            $script:installReq = [pscustomobject]@{ Org = 'acme'; AppId = '123'; InstallationId = '456'; Group = 'aap-crrr'; Labels = 'self-hosted,linux,crrr'; KeyPath = 'C:\Users\fixture\app.pem'; Profile = 'C:\Users\fixture'; RunnerCount = 2; JobCpus = 8; JobMemoryGiB = 16; WorkDiskGiB = 100 }
            $script:checkpoint = $null
            $script:taskWord = 'missing'
            $script:hostExit = 0
            $script:startExit = 0
            $script:writes = New-Object System.Collections.Generic.List[object]
            $script:actions = New-Object System.Collections.Generic.List[string]
            $script:fakeHandle = New-Object IO.MemoryStream
            Mock Read-AapIdentityRequest { return $script:installReq }
            Mock Assert-AapInstallArea { }
            Mock Read-AapInstallState { return $script:checkpoint }
            Mock Get-AapSupervisorTaskState { return $script:taskWord }
            Mock Get-AapInstallDistroState { if ($script:checkpoint) { return 'present' }; return 'absent' }
            Mock Test-AapInstallManagerInactive { return $true }
            Mock Read-AapJsonBounded { return $null }
            Mock Write-AapInstallJson {
                $script:writes.Add(@{ Path = $Relative; Value = ($Value | ConvertTo-Json -Compress) })
            }
            Mock Get-AapIdentityKeyView { return [pscustomobject]@{ Problem = $null; Handle = $script:fakeHandle } }
            Mock Invoke-AapStreamingStdin {
                $StdinHandle | Should -Be $script:fakeHandle
                $script:actions.Add('identity')
                $script:AapSawKeyLine = $true
                return 0
            }
            Mock Invoke-AapStreaming {
                $argsText = $Arguments -join ' '
                if ($argsText -match 'install-host.ps1') {
                    $script:actions.Add('host')
                    $Arguments | Should -Contain '-FreshInstall'
                    $Arguments | Should -Contain 'Ubuntu-24.04'
                    $argsText | Should -Not -Match 'KeyPath|26.04'
                    return $script:hostExit
                }
                if ($argsText -match 'install-supervisor.ps1') { $script:actions.Add('supervisor'); return 0 }
                if ($argsText -match '/Run') { $script:actions.Add('start'); return $script:startExit }
                $script:actions.Add('limits')
                return 0
            }
        }

        It 'orders host, checked-handle identity, limits, supervisor, then startup and completion' {
            $result = Invoke-AapInstallCaptured { Invoke-AapInstallSteps $TestDrive '0123456789abcdef' 'C:\Program Files\aap-runner\aap-runner-tray.exe' }
            $result.Code | Should -Be 0
            ($script:actions -join ',') | Should -Be 'host,identity,limits,supervisor,start'
            $phases = @($script:writes | Where-Object { $_.Path -eq 'jobs\install\state.json' } | ForEach-Object { ($_.Value | ConvertFrom-Json).phase })
            ($phases -join ',') | Should -Be 'host,identity,supervisor,start,done'
            $settings = ($script:writes | Where-Object { $_.Path -eq 'inbox\settings.json' }).Value | ConvertFrom-Json
            $settings.runner_count | Should -Be 2
            $settings.job_cpus | Should -Be 8
            $settings.job_memory_gib | Should -Be 16
            $script:fakeHandle.CanRead | Should -BeFalse
        }

        It 'retains the host checkpoint and does not install identity or start after host failure' {
            $script:hostExit = 17
            $result = Invoke-AapInstallCaptured { Invoke-AapInstallSteps $TestDrive '0123456789abcdef' 'C:\Program Files\aap-runner\aap-runner-tray.exe' }
            $result.Code | Should -Be 1
            ($script:actions -join ',') | Should -Be 'host'
            ($script:writes[-1].Value | ConvertFrom-Json).phase | Should -Be 'host'
            $script:fakeHandle.CanRead | Should -BeFalse
        }

        It 'resumes identity without replaying the host installer' {
            $script:checkpoint = New-AapInstallState $script:installReq '1111111111111111' 'identity'
            $result = Invoke-AapInstallCaptured { Invoke-AapInstallSteps $TestDrive '0123456789abcdef' 'C:\Program Files\aap-runner\aap-runner-tray.exe' }
            $result.Code | Should -Be 0
            ($script:actions -join ',') | Should -Be 'identity,limits,supervisor,start'
            ($script:writes[-1].Value | ConvertFrom-Json).job_id | Should -Be '0123456789abcdef'
        }

        It 'corrects a rejected App id and retries identity without repeating host installation' {
            $script:checkpoint = New-AapInstallState $script:installReq '1111111111111111' 'identity'
            $script:installReq.AppId = '789'
            $result = Invoke-AapInstallCaptured { Invoke-AapInstallSteps $TestDrive '0123456789abcdef' 'C:\Program Files\aap-runner\aap-runner-tray.exe' }
            $result.Code | Should -Be 0
            ($script:actions -join ',') | Should -Be 'identity,limits,supervisor,start'
            ($script:writes[0].Value | ConvertFrom-Json).app_id | Should -Be '789'
        }

        It 'refuses a resumed inactive-looking checkpoint when the manager is active' {
            $script:checkpoint = New-AapInstallState $script:installReq '1111111111111111' 'supervisor'
            Mock Test-AapInstallManagerInactive { return $false }
            $result = Invoke-AapInstallCaptured { Invoke-AapInstallSteps $TestDrive '0123456789abcdef' 'C:\Program Files\aap-runner\aap-runner-tray.exe' }
            $result.Code | Should -Be 2
            $result.Out | Should -Match 'active or uncertain manager'
            $script:actions.Count | Should -Be 0
            $script:writes.Count | Should -Be 0
        }

        It 'leaves a failed task start resumable without reopening a key or reinstalling' {
            $script:checkpoint = New-AapInstallState $script:installReq '1111111111111111' 'start'
            $script:taskWord = 'ready'
            $script:startExit = 1
            $result = Invoke-AapInstallCaptured { Invoke-AapInstallSteps $TestDrive '0123456789abcdef' 'C:\Program Files\aap-runner\aap-runner-tray.exe' }
            $result.Code | Should -Be 1
            ($script:actions -join ',') | Should -Be 'start'
            Should -Invoke Get-AapIdentityKeyView -Times 0
            @($script:writes | Where-Object { $_.Value -match '"phase":"done"' }).Count | Should -Be 0
        }

        It 'acknowledges an already running task after a start crash without any host action' {
            $script:checkpoint = New-AapInstallState $script:installReq '1111111111111111' 'start'
            $script:taskWord = 'running'
            $result = Invoke-AapInstallCaptured { Invoke-AapInstallSteps $TestDrive '0123456789abcdef' 'C:\Program Files\aap-runner\aap-runner-tray.exe' }
            $result.Code | Should -Be 0
            $script:actions.Count | Should -Be 0
            Should -Invoke Get-AapIdentityKeyView -Times 0
            $script:writes.Count | Should -Be 1
            ($script:writes[0].Value | ConvertFrom-Json).phase | Should -Be 'done'
        }
    }

    It 'install fixture mode cannot execute the install' {
        $exe = (Get-Process -Id $PID).Path
        $out = & $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '..\installer\helper-run.ps1') -Verb install -Id 0123456789abcdef -DataDir $TestDrive -Fixture 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 2
        $out | Should -Match 'FAIL install fixture mode does not change the machine'
    }
}
