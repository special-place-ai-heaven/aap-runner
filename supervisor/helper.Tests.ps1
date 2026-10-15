# Verify against a fixture ProgramData tree. No wsl, no scheduled task, no ACL write.
# Pester 5. Windows PowerShell 5.1 and PowerShell 7.

Describe 'helper verify' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\installer\helper-run.ps1')
        Mock Test-AapDistroListed { return 'stopped' }
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

    It 'accepts status schema 4 and refuses schema 5' {
        $root = Join-Path $TestDrive 'schema4'
        $updated = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        New-AapFixture -Root $root -Updated $updated
        $enc = New-Object System.Text.UTF8Encoding $false
        $path = Join-Path $root 'status.json'
        $text = [IO.File]::ReadAllText($path).Replace('"schema":3', '"schema":4,"work_disk_gib":60,"work_disk_free_gb":40,"work_disk_floor_gb":15,"cleaning":false')
        [IO.File]::WriteAllText($path, $text, $enc)
        $report = Get-AapVerifyReport -DataDir $root
        ($report.Lines -join "`n") | Should -Match 'PASS status idle'
        [IO.File]::WriteAllText($path, $text.Replace('"schema":4', '"schema":5'), $enc)
        $report5 = Get-AapVerifyReport -DataDir $root
        ($report5.Lines -join "`n") | Should -Match 'FAIL status schema 5'
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

    It 'refuses repair when a fresh status.json says <state>' -TestCases @(
        @{ state = 'running' }
        @{ state = 'draining' }
        @{ state = 'starting' }
    ) {
        $root = Join-Path $TestDrive "repair-$state"
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        $enc = New-Object System.Text.UTF8Encoding $false
        $updated = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        $json = '{"state":"' + $state + '","updated":"' + $updated + '"}'
        [IO.File]::WriteAllText((Join-Path $root 'status.json'), $json, $enc)
        Get-AapRepairRefusal $root | Should -Be 'job running, repair refused; retry when idle or pause the runners first'
    }

    It 'allows a fresh idle status and refuses a missing status unless the task is gone' {
        $idle = Join-Path $TestDrive 'repair-idle'
        New-Item -ItemType Directory -Force -Path $idle | Out-Null
        $enc = New-Object System.Text.UTF8Encoding $false
        $updated = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        [IO.File]::WriteAllText((Join-Path $idle 'status.json'), ('{"state":"idle","updated":"' + $updated + '"}'), $enc)
        Get-AapRepairRefusal $idle | Should -BeNullOrEmpty
        $script:taskState = 'ready'
        Mock Get-AapSupervisorTaskState { return $script:taskState }
        $none = Join-Path $TestDrive 'repair-none'
        New-Item -ItemType Directory -Force -Path $none | Out-Null
        $unread = 'status unreadable, repair refused; retry when idle or pause the runners first'
        Get-AapRepairRefusal $none | Should -Be $unread
        $bad = Join-Path $TestDrive 'repair-bad'
        New-Item -ItemType Directory -Force -Path $bad | Out-Null
        [IO.File]::WriteAllText((Join-Path $bad 'status.json'), '{', $enc)
        Get-AapRepairRefusal $bad | Should -Be $unread
        $script:taskState = 'missing'
        Get-AapRepairRefusal $none | Should -BeNullOrEmpty
        Get-AapRepairRefusal $bad | Should -BeNullOrEmpty
    }

    It 'trusts the task state when status.json is older than 180 s' {
        $root = Join-Path $TestDrive 'repair-stale'
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        $enc = New-Object System.Text.UTF8Encoding $false
        $busy = 'job running, repair refused; retry when idle or pause the runners first'
        $unread = 'status unreadable, repair refused; retry when idle or pause the runners first'
        [IO.File]::WriteAllText((Join-Path $root 'status.json'), '{"state":"idle","updated":"2020-01-01T00:00:00Z"}', $enc)
        $script:taskState = 'running'
        Mock Get-AapSupervisorTaskState { return $script:taskState }
        Get-AapRepairRefusal $root | Should -Be $busy
        [IO.File]::WriteAllText((Join-Path $root 'status.json'), '{"state":"running","updated":"2020-01-01T00:00:00Z"}', $enc)
        $script:taskState = 'ready'
        Get-AapRepairRefusal $root | Should -BeNullOrEmpty
        $script:taskState = 'unknown'
        Get-AapRepairRefusal $root | Should -Be $unread
    }

    It 'treats a missing updated timestamp as stale and refuses a running distro' {
        $busy = 'job running, repair refused; retry when idle or pause the runners first'
        $root = Join-Path $TestDrive 'repair-no-stamp'
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        $enc = New-Object System.Text.UTF8Encoding $false
        [IO.File]::WriteAllText((Join-Path $root 'status.json'), '{"state":"running"}', $enc)
        $script:taskState = 'ready'
        Mock Get-AapSupervisorTaskState { return $script:taskState }
        Mock Test-AapDistroListed { return 'stopped' }
        Get-AapRepairRefusal $root | Should -BeNullOrEmpty
        Mock Test-AapDistroListed { return 'running' }
        Get-AapRepairRefusal $root | Should -Be $busy
        $idle = Join-Path $TestDrive 'repair-idle-live-distro'
        New-Item -ItemType Directory -Force -Path $idle | Out-Null
        $updated = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        [IO.File]::WriteAllText((Join-Path $idle 'status.json'), ('{"state":"idle","updated":"' + $updated + '"}'), $enc)
        Get-AapRepairRefusal $idle | Should -Be $busy
        Test-AapWslListHasDistro "Ubuntu`0`r`naap-runner`0`r`n" 'aap-runner' | Should -BeTrue
        Test-AapWslListHasDistro "Ubuntu-24.04`r`n" 'aap-runner' | Should -BeFalse
    }

    It 'reads status again before the remount and before the restart' {
        $script:checks = 0
        Mock Get-AapRepairRefusal {
            $script:checks++
            if ($script:checks -ge 2) {
                return 'job running, repair refused; retry when idle or pause the runners first'
            }
            return $null
        }
        Mock Invoke-AapStreaming { return 0 }
        Mock Test-Path { return $true }
        Mock Test-AapReparsePoint { return $false }
        $code = Invoke-AapRepairLive ''
        $code | Should -Be 1
        $script:checks | Should -Be 2
        Should -Invoke Invoke-AapStreaming -Times 0 -ParameterFilter { ($Arguments -join ' ') -match 'mount-work-vhdx\.ps1' -and ($Arguments -join ' ') -notmatch 'lock-acl' }
        $script:checks = 0
        Mock Get-AapRepairRefusal {
            $script:checks++
            if ($script:checks -ge 3) {
                return 'job running, repair refused; retry when idle or pause the runners first'
            }
            return $null
        }
        $code = Invoke-AapRepairLive ''
        $code | Should -Be 1
        $script:checks | Should -Be 3
        Should -Invoke Invoke-AapStreaming -Times 0 -ParameterFilter { $File -eq 'C:\Windows\System32\schtasks.exe' }
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
