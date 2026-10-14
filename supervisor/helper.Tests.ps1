# Verify against a fixture ProgramData tree. No wsl, no scheduled task, no ACL write.
# Pester 5. Windows PowerShell 5.1 and PowerShell 7.

Describe 'helper verify' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\installer\helper-run.ps1')
        $script:junctions = New-Object System.Collections.Generic.List[string]
        function New-AapFixture {
            param([string]$Root, [string]$Updated, [string]$Desired = 'on', [string]$State = 'idle')
            New-Item -ItemType Directory -Force -Path (Join-Path $Root 'inbox') | Out-Null
            New-Item -ItemType Directory -Force -Path (Join-Path $Root 'logs') | Out-Null
            $enc = New-Object System.Text.UTF8Encoding $false
            [IO.File]::WriteAllText((Join-Path $Root 'inbox\state.json'), "{`"desired`":`"$Desired`"}", $enc)
            $status = '{"schema":3,"state":"' + $State + '","job":"","updated":"' + $Updated + '","detail":"","runner_count":1,"job_cpus":8,"job_memory_gib":24}'
            [IO.File]::WriteAllText((Join-Path $Root 'status.json'), $status, $enc)
            [IO.File]::WriteAllText((Join-Path $Root 'logs\supervisor.log'), '', $enc)
        }
    }

    AfterEach {
        foreach ($j in @($script:junctions)) {
            & C:\Windows\System32\cmd.exe /d /c rmdir "$j" | Out-Null
        }
        $script:junctions.Clear()
    }

    It 'passes a fresh fixture tree' {
        $root = Join-Path $TestDrive 'fresh'
        $updated = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        New-AapFixture -Root $root -Updated $updated
        $report = Get-AapVerifyReport -DataDir $root
        $report.ExitCode | Should -Be 0
        ($report.Lines -join "`n") | Should -Match 'PASS data-dir'
        ($report.Lines -join "`n") | Should -Match 'PASS reparse none'
        ($report.Lines -join "`n") | Should -Match 'PASS state on'
        ($report.Lines -join "`n") | Should -Match 'PASS supervisor-status fresh'
        ($report.Lines -join "`n") | Should -Match 'PASS status idle'
        @($report.Lines | Where-Object { $_.StartsWith('FAIL') }).Count | Should -Be 0
    }

    It 'runs verify -Fixture against that tree and does not mention wsl' {
        $root = Join-Path $TestDrive 'file'
        $updated = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        New-AapFixture -Root $root -Updated $updated
        $exe = (Get-Process -Id $PID).Path
        $out = & $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '..\installer\helper-run.ps1') -Verb verify -DataDir $root -Fixture 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $out | Should -Match 'PASS supervisor-status fresh'
        $out | Should -Not -Match 'wsl'
        $out | Should -Not -Match 'schtasks'
    }

    It 'fails a stale status.json' {
        $root = Join-Path $TestDrive 'stale'
        New-AapFixture -Root $root -Updated '2020-01-01T00:00:00Z'
        $report = Get-AapVerifyReport -DataDir $root -Now ([datetime]::Parse('2020-01-01T00:10:00Z').ToUniversalTime())
        $report.ExitCode | Should -Be 1
        ($report.Lines -join "`n") | Should -Match 'FAIL supervisor-status stale'
        ($report.Lines -join "`n") | Should -Match 'PASS status idle'
    }

    It 'fails a missing tree' {
        $report = Get-AapVerifyReport -DataDir (Join-Path $TestDrive 'missing-tree')
        $report.ExitCode | Should -Be 1
        ($report.Lines -join "`n") | Should -Match 'FAIL data-dir missing'
        @($report.Lines).Count | Should -Be 1
    }

    It 'refuses a junction and does not read through it' {
        $root = Join-Path $TestDrive 'link-root'
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        $target = Join-Path $TestDrive 'link-target'
        New-Item -ItemType Directory -Force -Path $target | Out-Null
        $enc = New-Object System.Text.UTF8Encoding $false
        [IO.File]::WriteAllText((Join-Path $target 'secret.txt'), 'super-secret-key-material', $enc)
        $link = Join-Path $root 'inbox'
        & C:\Windows\System32\cmd.exe /d /c mklink /J "$link" "$target" | Out-Null
        $LASTEXITCODE | Should -Be 0
        $script:junctions.Add($link)
        $report = Get-AapVerifyReport -DataDir $root
        $report.ExitCode | Should -Be 1
        ($report.Lines -join "`n") | Should -Match 'FAIL reparse'
        ($report.Lines -join "`n") | Should -Not -Match 'super-secret'
    }

    It 'refuses a DataDir that climbs out of the tree' {
        $report = Get-AapVerifyReport -DataDir 'C:\ProgramData\aap-runner\..\Windows'
        $report.ExitCode | Should -Be 1
        ($report.Lines -join "`n") | Should -Match 'FAIL data-dir refused'
    }

    It 'repair -Fixture changes nothing' {
        $exe = (Get-Process -Id $PID).Path
        $out = & $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '..\installer\helper-run.ps1') -Verb repair -DataDir (Join-Path $TestDrive 'nope') -Fixture 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 2
        $out | Should -Match 'FAIL repair fixture mode does not change the machine'
        $out | Should -Not -Match 'wsl'
        $out | Should -Not -Match 'schtasks'
        $out | Should -Not -Match 'Set-Acl'
    }

    It 'refuses repair when status.json says <state>' -TestCases @(
        @{ state = 'running' }
        @{ state = 'draining' }
    ) {
        $root = Join-Path $TestDrive "repair-$state"
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        $enc = New-Object System.Text.UTF8Encoding $false
        [IO.File]::WriteAllText((Join-Path $root 'status.json'), ('{"state":"' + $state + '"}'), $enc)
        Get-AapRepairRefusal $root | Should -Be 'job running, repair refused; retry when idle or pause the runners first'
    }

    It 'does not refuse repair when the runners are idle or status is missing' {
        $idle = Join-Path $TestDrive 'repair-idle'
        New-Item -ItemType Directory -Force -Path $idle | Out-Null
        $enc = New-Object System.Text.UTF8Encoding $false
        [IO.File]::WriteAllText((Join-Path $idle 'status.json'), '{"state":"idle"}', $enc)
        Get-AapRepairRefusal $idle | Should -BeNullOrEmpty
        $none = Join-Path $TestDrive 'repair-none'
        New-Item -ItemType Directory -Force -Path $none | Out-Null
        Get-AapRepairRefusal $none | Should -BeNullOrEmpty
    }

    It 'names only the fixed repair paths' {
        $plan = @(Get-AapRepairPlan)
        ($plan.Name -join ',') | Should -Be 'lock-acl,lock-acl,lock-acl,lock-acl,lock-acl,install-supervisor,remount,restart-supervisor'
        ($plan.Path -join "`n") | Should -Be (@(
            'C:\wsl',
            'C:\wsl\aap-runner-work.vhdx',
            'C:\wsl\mount-work-vhdx.ps1',
            'C:\wsl\mount-work-vhdx-task.xml',
            'C:\wsl\aap-runner-supervisor',
            'C:\ProgramData\aap-runner',
            'C:\wsl\aap-runner-work.vhdx',
            'AAP-CRRR-Supervisor'
        ) -join "`n")
        ($plan.Path -join "`n") | Should -Not -Match '\.\.'
    }
}
