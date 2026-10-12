# Pester 5 tests for the host supervisor and its installer. Everything that
# touches the host (wsl.exe, Task Scheduler, the clock, sleep) is mocked; no
# test starts a process except the -DryRun runs at the end.
#
# Windows ships Pester 3.4. Do not Install-Module over it. Instead:
#   Save-Module Pester -RequiredVersion 5.7.1 -Path <scratch dir>
#   Import-Module <scratch dir>\Pester\5.7.1\Pester.psd1
#   Invoke-Pester -Path .\supervisor.Tests.ps1 -Output Detailed
# Run under both powershell.exe (5.1) and pwsh (7).

Describe 'aap-runner host supervisor' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'aap-runner-supervisor.ps1')

        function Get-AapFakeResult([int]$Code, [string]$Out) {
            return [pscustomobject]@{ Code = $Code; Out = $Out; Err = ''; TimedOut = $false }
        }

        function Get-AapFakeProcess {
            $p = [pscustomobject]@{ Id = 4242; HasExited = $false; Killed = $false }
            $p | Add-Member -MemberType ScriptMethod -Name Kill -Value { $this.HasExited = $true; $this.Killed = $true }
            $p | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { return $true }
            return $p
        }

        function Write-AapStateFile([string]$Text) {
            [IO.File]::WriteAllText((Join-Path $AapCfg.DataDir 'state.json'), $Text)
        }

        function Write-AapSettingsFile([string]$Text) {
            [IO.File]::WriteAllText((Join-Path $AapCfg.DataDir 'settings.json'), $Text)
        }

        function Get-AapStatusFile {
            return Get-Content -Raw -LiteralPath (Join-Path $AapCfg.DataDir 'status.json') | ConvertFrom-Json
        }

        function Get-AapLogText {
            $log = Join-Path $AapCfg.DataDir 'logs\supervisor.log'
            if (-not (Test-Path -LiteralPath $log)) { return '' }
            return Get-Content -Raw -LiteralPath $log
        }

        # Healthy distro unless a test swaps the responder.
        $script:healthy = {
            param($line)
            switch -Wildcard ($line) {
                '*is-active sysbox aap-runner-manager' { return (Get-AapFakeResult 0 "active`nactive") }
                '*cat /run/aap-runner/status.json' { return (Get-AapFakeResult 0 '{"state":"idle","job":"","slots":4,"busy":0,"updated":1,"runner_count":4,"job_cpus":28,"job_memory":"72g"}') }
                '*is-active aap-runner-manager' { return (Get-AapFakeResult 3 'inactive') }
                default { return (Get-AapFakeResult 0 '') }
            }
        }
    }

    BeforeEach {
        $AapCfg.DataDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Force -Path $AapCfg.DataDir | Out-Null
        $AapCfg.DryRun = $false
        $AapCfg.DrainTimeoutSeconds = 21600
        $AapCfg.LogMaxBytes = 5MB
        Initialize-AapRuntime
        $script:calls = New-Object System.Collections.Generic.List[string]
        $script:stdin = New-Object System.Collections.Generic.List[string]
        $script:clock = @{ Now = [DateTimeOffset]::new(2026, 10, 12, 12, 0, 0, [TimeSpan]::FromHours(2)) }
        $script:responder = $script:healthy
        $script:mountResult = 0

        Mock Get-AapNow { return $script:clock.Now }
        Mock Wait-AapInterval {
            $script:calls.Add("sleep $Seconds")
            $script:clock.Now = $script:clock.Now.AddSeconds($Seconds)
        }
        Mock Invoke-AapWsl {
            $line = $Arguments -join ' '
            $script:calls.Add("wsl $line")
            if ($null -ne $StdIn) { $script:stdin.Add([string]$StdIn) }
            if ($Background) { return (Get-AapFakeProcess) }
            return (& $script:responder $line)
        }
        Mock Start-ScheduledTask { $script:calls.Add("task $TaskName") }
        Mock Get-ScheduledTask { return [pscustomobject]@{ State = 'Ready' } }
        Mock Get-ScheduledTaskInfo { return [pscustomobject]@{ LastTaskResult = $script:mountResult } }
        # Never touch the live vmmemWSL from a test.
        Mock Set-AapVmPriority { }
    }

    Describe 'state.json parsing' {
        It 'accepts <text> as <want>' -TestCases @(
            @{ text = '{"desired":"on"}'; want = 'on' }
            @{ text = '{"desired":"off"}'; want = 'off' }
            @{ text = ([char]0xFEFF + '{"desired":"on"}'); want = 'on' }
            @{ text = '{"desired":"ON"}'; want = 'off' }
            @{ text = '{"desired":"on; wsl --shutdown"}'; want = 'off' }
            @{ text = '{"desired":1}'; want = 'off' }
            @{ text = '{"desired":["on"]}'; want = 'off' }
            @{ text = '"on"'; want = 'off' }
            @{ text = 'garbage'; want = 'off' }
            @{ text = ''; want = 'off' }
        ) {
            Write-AapStateFile $text
            Read-AapDesired | Should -Be $want
        }

        It 'treats a missing file as off' {
            Read-AapDesired | Should -Be 'off'
            Get-AapLogText | Should -Match 'WARN state.json is missing'
        }

        It 'treats a file over 4 KB as off' {
            Write-AapStateFile ('{"desired":"on","pad":"' + ('x' * 5000) + '"}')
            Read-AapDesired | Should -Be 'off'
        }

        It 'logs a repeated warning once' {
            Write-AapStateFile 'garbage'
            1..3 | ForEach-Object { [void](Read-AapDesired) }
            ([regex]::Matches((Get-AapLogText), 'WARN')).Count | Should -Be 1
        }
    }

    Describe 'status.json' {
        It 'writes the contract schema atomically' {
            Write-AapStatus 'running' 'ci-123' ''
            Write-AapStatus 'idle' '' 'second write replaces the first'
            $path = Join-Path $AapCfg.DataDir 'status.json'
            $s = Get-AapStatusFile
            @($s.PSObject.Properties.Name) -join ',' | Should -Be 'state,job,updated,detail,runner_count,job_cpus,job_memory_gib'
            $s.runner_count | Should -BeNullOrEmpty
            $s.state | Should -Be 'idle'
            $s.detail | Should -Be 'second write replaces the first'
            [string](Get-Content -Raw -LiteralPath $path) | Should -Match '"updated":"2026-10-12T12:00:00\+02:00"'
            Test-Path -LiteralPath "$path.tmp" | Should -BeFalse
            $bytes = [IO.File]::ReadAllBytes($path)
            $bytes[0] | Should -Be ([byte][char]'{')
        }

        It 'refuses an unknown state' {
            { Write-AapStatus 'bogus' } | Should -Throw
        }

        It 'strips control characters from the job name' {
            Write-AapStatus 'running' ("job`r`nfake") ''
            (Get-AapStatusFile).job | Should -Be 'job fake'
        }

        It 'rotates the log at the size cap' {
            $AapCfg.LogMaxBytes = 200
            1..10 | ForEach-Object { Write-AapLog ('line ' + ('x' * 40)) }
            Test-Path -LiteralPath (Join-Path $AapCfg.DataDir 'logs\supervisor.log.1') | Should -BeTrue
            (Get-Item -LiteralPath (Join-Path $AapCfg.DataDir 'logs\supervisor.log')).Length | Should -BeLessThan 400
        }
    }

    Describe 'On sequence' {
        It 'runs mount task, keep-alive, undrain, then starts services' {
            Write-AapStateFile '{"desired":"on"}'
            Invoke-AapCycle
            $want = @(
                'task AAP-CRRR-Mount-Work-Disk'
                'sleep 2'
                'wsl -d aap-runner --exec /bin/sleep infinity'
                'wsl -d aap-runner -u root -- /usr/local/sbin/aap-runner-manager --undrain'
                'wsl -d aap-runner -u root -- /bin/systemctl start sysbox aap-runner-manager'
                'wsl -d aap-runner -u root -- /bin/systemctl is-active sysbox aap-runner-manager'
                'wsl -d aap-runner -u root -- /bin/cat /run/aap-runner/status.json'
            )
            @($script:calls) | Should -Be $want
            $AapRt.Mode | Should -Be 'on'
            $s = Get-AapStatusFile
            $s.state | Should -Be 'idle'
            $s.runner_count | Should -Be 4
            $s.job_cpus | Should -Be 28
            $s.job_memory_gib | Should -Be 72
        }

        It 'ignores a failing --undrain' {
            $script:responder = {
                param($line)
                if ($line -like '*--undrain') { return (Get-AapFakeResult 1 '') }
                return (& $script:healthy $line)
            }
            Write-AapStateFile '{"desired":"on"}'
            Invoke-AapCycle
            $AapRt.Mode | Should -Be 'on'
            Get-AapLogText | Should -Match 'undrain exit 1 \(ignored\)'
        }

        It 'mirrors a running job from the manager' {
            $script:responder = {
                param($line)
                if ($line -like '*cat /run/aap-runner/status.json') { return (Get-AapFakeResult 0 '{"state":"running","job":"ci-123","slots":4,"busy":1}') }
                return (& $script:healthy $line)
            }
            Write-AapStateFile '{"desired":"on"}'
            Invoke-AapCycle
            $s = Get-AapStatusFile
            $s.state | Should -Be 'running'
            $s.job | Should -Be 'ci-123'
        }

        It 'stops at a failed mount task, sets error, and retries after backoff' {
            $script:mountResult = 1
            Write-AapStateFile '{"desired":"on"}'
            Invoke-AapCycle
            @($script:calls | Where-Object { $_ -like 'wsl *' }).Count | Should -Be 0
            (Get-AapStatusFile).state | Should -Be 'error'
            (Get-AapStatusFile).detail | Should -Match 'LastTaskResult 1; retry in 10 s'
            $AapRt.Mode | Should -Be 'off'
            $script:calls.Clear()
            Invoke-AapCycle
            $script:calls.Count | Should -Be 0
            $script:clock.Now = $script:clock.Now.AddSeconds(10)
            Invoke-AapCycle
            $script:calls[0] | Should -Be 'task AAP-CRRR-Mount-Work-Disk'
        }
    }

    Describe 'Off sequence' {
        BeforeEach {
            $AapRt.Mode = 'on'
            $AapRt.KeepAlive = Get-AapFakeProcess
            $script:keep = $AapRt.KeepAlive
            $script:activeLeft = 2
            $script:responder = {
                param($line)
                if ($line -like '*is-active aap-runner-manager') {
                    if ($script:activeLeft -gt 0) { $script:activeLeft--; return (Get-AapFakeResult 0 'active') }
                    return (Get-AapFakeResult 3 'inactive')
                }
                return (Get-AapFakeResult 0 '')
            }
            Write-AapStateFile '{"desired":"off"}'
        }

        It 'drains, waits for inactive, terminates, stops keep-alive' {
            Invoke-AapCycle
            $want = @(
                'wsl -d aap-runner -u root -- /usr/local/sbin/aap-runner-manager --drain'
                'wsl -d aap-runner -u root -- /bin/systemctl is-active aap-runner-manager'
                'sleep 10'
                'wsl -d aap-runner -u root -- /bin/systemctl is-active aap-runner-manager'
                'sleep 10'
                'wsl -d aap-runner -u root -- /bin/systemctl is-active aap-runner-manager'
                'wsl --terminate aap-runner'
            )
            @($script:calls) | Should -Be $want
            $script:keep.Killed | Should -BeTrue
            $AapRt.KeepAlive | Should -BeNullOrEmpty
            $AapRt.Mode | Should -Be 'off'
            (Get-AapStatusFile).state | Should -Be 'off'
        }

        It 'terminates anyway after the drain timeout' {
            $AapCfg.DrainTimeoutSeconds = 30
            $script:activeLeft = 1000
            Invoke-AapCycle
            @($script:calls | Where-Object { $_ -eq 'sleep 10' }).Count | Should -Be 3
            $script:calls[-1] | Should -Be 'wsl --terminate aap-runner'
            Get-AapLogText | Should -Match 'drain timeout after 30 s'
            (Get-AapStatusFile).state | Should -Be 'off'
        }

        It 'undrains instead of terminating when desired flips back to on' {
            $script:activeLeft = 1000
            Mock Wait-AapInterval { Write-AapStateFile '{"desired":"on"}' }
            Invoke-AapCycle
            $script:calls[-1] | Should -Be 'wsl -d aap-runner -u root -- /usr/local/sbin/aap-runner-manager --undrain'
            $script:calls | Should -Not -Contain 'wsl --terminate aap-runner'
            $AapRt.Mode | Should -Be 'on'
            $script:keep.Killed | Should -BeFalse
        }
    }

    Describe 'health loop' {
        BeforeEach {
            $AapRt.Mode = 'on'
            $AapRt.KeepAlive = Get-AapFakeProcess
            Write-AapStateFile '{"desired":"on"}'
        }

        It 'restarts with backoff 10 30 60 120 300 300 and errors after 5' {
            $script:responder = {
                param($line)
                if ($line -like '*is-active sysbox aap-runner-manager') { return (Get-AapFakeResult 3 "inactive`nfailed") }
                return (Get-AapFakeResult 0 '')
            }
            $delays = @()
            $states = @()
            foreach ($i in 1..6) {
                $before = $script:clock.Now
                Invoke-AapCycle
                $delays += [int]($AapRt.NextHealth - $before).TotalSeconds
                $states += (Get-AapStatusFile).state
                $script:clock.Now = $AapRt.NextHealth
            }
            $delays | Should -Be @(10, 30, 60, 120, 300, 300)
            $states | Should -Be @('starting', 'starting', 'starting', 'starting', 'error', 'error')
            (Get-AapStatusFile).detail | Should -Match 'sysbox=inactive manager=failed'
            @($script:calls | Where-Object { $_ -like '*systemctl start sysbox' }).Count | Should -Be 6
            @($script:calls | Where-Object { $_ -like '*systemctl start aap-runner-manager' }).Count | Should -Be 6
        }

        It 'does not check again before the next health time' {
            Invoke-AapCycle
            $script:calls.Clear()
            $script:clock.Now = $script:clock.Now.AddSeconds(55)
            Invoke-AapCycle
            $script:calls.Count | Should -Be 0
            $script:clock.Now = $script:clock.Now.AddSeconds(5)
            Invoke-AapCycle
            $script:calls | Should -Contain 'wsl -d aap-runner -u root -- /bin/systemctl is-active sysbox aap-runner-manager'
        }

        It 'resets the backoff after 10 minutes healthy' {
            $AapRt.Failures = 3
            Invoke-AapCycle
            $AapRt.Failures | Should -Be 3
            $script:clock.Now = $script:clock.Now.AddSeconds(600)
            Invoke-AapCycle
            $AapRt.Failures | Should -Be 0
        }

        It 'restarts a dead keep-alive' {
            $AapRt.KeepAlive.HasExited = $true
            Invoke-AapCycle
            $script:calls[0] | Should -Be 'wsl -d aap-runner --exec /bin/sleep infinity'
            $AapRt.KeepAlive.HasExited | Should -BeFalse
        }
    }

    Describe 'Off mode and DryRun' {
        It 'makes zero wsl calls while off and keeps status fresh' {
            Write-AapStateFile '{"desired":"off"}'
            Invoke-AapCycle
            $first = (Get-AapStatusFile).updated
            foreach ($i in 1..30) {
                $script:clock.Now = $script:clock.Now.AddSeconds(5)
                Invoke-AapCycle
            }
            Should -Invoke Invoke-AapWsl -Times 0 -Exactly
            Should -Invoke Start-ScheduledTask -Times 0 -Exactly
            $s = Get-AapStatusFile
            $s.state | Should -Be 'off'
            $s.updated | Should -Not -Be $first
        }

        It 'DryRun makes zero wsl or task calls and writes no status' {
            $AapCfg.DryRun = $true
            Write-AapStateFile '{"desired":"on"}'
            Invoke-AapCycle
            $AapRt.Mode | Should -Be 'on'
            Invoke-AapCycle
            Write-AapStateFile '{"desired":"off"}'
            Invoke-AapCycle
            $AapRt.Mode | Should -Be 'off'
            Should -Invoke Invoke-AapWsl -Times 0 -Exactly
            Should -Invoke Start-ScheduledTask -Times 0 -Exactly
            Test-Path -LiteralPath (Join-Path $AapCfg.DataDir 'status.json') | Should -BeFalse
        }

        It 'drains a distro left running when desired is off at startup' {
            $script:responder = { param($line) if ($line -eq '--list --running --quiet') { return (Get-AapFakeResult 0 "Ubuntu-24.04`naap-runner") }; return (Get-AapFakeResult 0 '') }
            Write-AapStateFile '{"desired":"off"}'
            Initialize-AapMode
            $AapRt.Mode | Should -Be 'on'
        }
    }

    Describe 'vmmemWSL priority' {
        It 'is set on health ticks while On and never while Off' {
            Write-AapStateFile '{"desired":"on"}'
            Invoke-AapCycle
            Should -Invoke Set-AapVmPriority -Times 1 -Exactly
            Write-AapStateFile '{"desired":"off"}'
            foreach ($i in 1..20) {
                $script:clock.Now = $script:clock.Now.AddSeconds(5)
                Invoke-AapCycle
            }
            $AapRt.Mode | Should -Be 'off'
            Should -Invoke Set-AapVmPriority -Times 1 -Exactly
        }

        It 'lowers only vmmemWSL and is idempotent when already BelowNormal' {
            $script:vm = [pscustomobject]@{ Id = 77; PriorityClass = 'Normal' }
            Mock Get-Process { throw 'unexpected Get-Process' }
            Mock Get-Process { return $script:vm } -ParameterFilter { $Name -eq 'vmmemWSL' }
            # Proves the mock is live before the real function runs.
            (Get-Process -Name 'vmmemWSL') | Should -Be $script:vm
            $real = (Get-Command Set-AapVmPriority -CommandType Function).ScriptBlock
            & $real
            $script:vm.PriorityClass | Should -Be 'BelowNormal'
            & $real
            & $real
            ([regex]::Matches((Get-AapLogText), 'vmmemWSL pid=77')).Count | Should -Be 1
        }
    }

    Describe 'settings.json parsing' {
        BeforeAll {
            $script:valid = '{"runner_count":2,"job_cpus":8,"job_memory_gib":32,"paused":false}'
        }

        It 'reads a valid file' {
            Write-AapSettingsFile '{"runner_count":2,"job_cpus":8,"job_memory_gib":32,"paused":true}'
            $s = Read-AapSettingsFile
            Get-AapLimitsKey $s.Limits | Should -Be '2,8,32'
            $s.Paused | Should -BeTrue
        }

        It 'treats a missing file as no override and not paused' {
            $s = Read-AapSettingsFile
            $s.Limits | Should -BeNullOrEmpty
            $s.Paused | Should -BeFalse
            Get-AapLogText | Should -Not -Match 'WARN'
        }

        It 'ignores <name> and keeps the last valid settings' -TestCases @(
            @{ name = 'runner_count 0'; text = '{"runner_count":0,"job_cpus":8,"job_memory_gib":32,"paused":false}' }
            @{ name = 'runner_count 5'; text = '{"runner_count":5,"job_cpus":8,"job_memory_gib":32,"paused":false}' }
            @{ name = 'job_cpus 0'; text = '{"runner_count":2,"job_cpus":0,"job_memory_gib":32,"paused":false}' }
            @{ name = 'job_cpus 29'; text = '{"runner_count":2,"job_cpus":29,"job_memory_gib":32,"paused":false}' }
            @{ name = 'job_memory_gib 0'; text = '{"runner_count":2,"job_cpus":8,"job_memory_gib":0,"paused":false}' }
            @{ name = 'job_memory_gib 81'; text = '{"runner_count":2,"job_cpus":8,"job_memory_gib":81,"paused":false}' }
            @{ name = 'a fraction'; text = '{"runner_count":1.5,"job_cpus":8,"job_memory_gib":32,"paused":false}' }
            @{ name = 'a string number'; text = '{"runner_count":"2","job_cpus":8,"job_memory_gib":32,"paused":false}' }
            @{ name = 'a string boolean'; text = '{"runner_count":2,"job_cpus":8,"job_memory_gib":32,"paused":"true"}' }
            @{ name = 'a numeric boolean'; text = '{"runner_count":2,"job_cpus":8,"job_memory_gib":32,"paused":1}' }
            @{ name = 'an extra key'; text = '{"runner_count":2,"job_cpus":8,"job_memory_gib":32,"paused":false,"cmd":"x"}' }
            @{ name = 'a missing key'; text = '{"runner_count":2,"job_cpus":8,"paused":false}' }
            @{ name = 'garbage'; text = 'garbage' }
            @{ name = 'an array'; text = '[1,2,3]' }
        ) {
            Write-AapSettingsFile '{"runner_count":3,"job_cpus":12,"job_memory_gib":48,"paused":true}'
            [void](Read-AapSettingsFile)
            Write-AapSettingsFile $text
            $s = Read-AapSettingsFile
            Get-AapLimitsKey $s.Limits | Should -Be '3,12,48'
            $s.Paused | Should -BeTrue
            Get-AapLogText | Should -Match 'WARN settings.json'
        }
    }

    Describe 'limits apply' {
        BeforeEach {
            $AapRt.Mode = 'on'
            $AapRt.KeepAlive = Get-AapFakeProcess
            $AapRt.NextHealth = $script:clock.Now.AddHours(1)
            Write-AapStateFile '{"desired":"on"}'
            Write-AapSettingsFile '{"runner_count":2,"job_cpus":8,"job_memory_gib":32,"paused":false}'
            $script:W = 'wsl -d aap-runner -u root -- '
            $script:writeLine = $script:W + '/bin/sh -c ' + $AapWriteLimits
            $script:old = "AAP_RUNNER_COUNT=4`nAAP_JOB_CPUS=28`nAAP_JOB_MEMORY=72g`n"
            $script:prevCode = 0
            $script:checkCode = 0
            $script:activeLeft = 1
            $script:responder = {
                param($line)
                if ($line -eq '-d aap-runner -u root -- /bin/cat /etc/aap-runner/limits.conf') { return (Get-AapFakeResult $script:prevCode $script:old) }
                if ($line -like '*--check-limits') {
                    if ($script:checkCode -ne 0) { return (Get-AapFakeResult 1 "AAP_JOB_CPUS=8 exceeds 4 host cpus`n") }
                    return (Get-AapFakeResult 0 "AAP_RUNNER_COUNT=2`nAAP_JOB_CPUS=8`nAAP_JOB_MEMORY=32g`n")
                }
                if ($line -like '*is-active aap-runner-manager') {
                    if ($script:activeLeft -gt 0) { $script:activeLeft--; return (Get-AapFakeResult 0 'active') }
                    return (Get-AapFakeResult 3 'inactive')
                }
                return (Get-AapFakeResult 0 '')
            }
        }

        It 'writes, checks, drains, waits, undrains, then starts the manager' {
            Invoke-AapCycle
            $want = @(
                ($script:W + '/bin/cat /etc/aap-runner/limits.conf')
                $script:writeLine
                ($script:W + '/usr/local/sbin/aap-runner-manager --check-limits')
                ($script:W + '/usr/local/sbin/aap-runner-manager --drain')
                ($script:W + '/bin/systemctl is-active aap-runner-manager')
                'sleep 10'
                ($script:W + '/bin/systemctl is-active aap-runner-manager')
                ($script:W + '/usr/local/sbin/aap-runner-manager --undrain')
                ($script:W + '/bin/systemctl start aap-runner-manager')
            )
            @($script:calls)[0..8] | Should -Be $want
            $script:stdin[0] | Should -BeExactly "AAP_RUNNER_COUNT=2`nAAP_JOB_CPUS=8`nAAP_JOB_MEMORY=32g`n"
            $AapRt.Applied | Should -Be '2,8,32'
            $script:calls.Clear()
            $AapRt.NextHealth = $script:clock.Now.AddHours(1)
            Invoke-AapCycle
            $script:calls.Count | Should -Be 0
        }

        It 'puts the previous limits.conf back when check-limits refuses' {
            $script:checkCode = 1
            Invoke-AapCycle
            $want = @(
                ($script:W + '/bin/cat /etc/aap-runner/limits.conf')
                $script:writeLine
                ($script:W + '/usr/local/sbin/aap-runner-manager --check-limits')
                $script:writeLine
            )
            @($script:calls) | Should -Be $want
            $script:stdin[1] | Should -BeExactly $script:old
            $s = Get-AapStatusFile
            $s.state | Should -Be 'error'
            $s.detail | Should -Match 'limits 2,8,32 refused: AAP_JOB_CPUS=8 exceeds 4 host cpus'
            Get-AapLogText | Should -Match 'previous limits.conf restored'
            $script:calls.Clear()
            Invoke-AapCycle
            $script:calls.Count | Should -Be 0
        }

        It 'removes limits.conf on refusal when there was none before' {
            $script:prevCode = 1
            $script:checkCode = 1
            Invoke-AapCycle
            $script:calls[-1] | Should -Be ($script:W + '/bin/rm -f /etc/aap-runner/limits.conf')
            $script:calls | Should -Not -Contain ($script:W + '/usr/local/sbin/aap-runner-manager --drain')
        }

        It 'counts limits the manager already reports as applied' {
            $AapRt.Effective = @{ RunnerCount = 2; JobCpus = 8; JobMemoryGib = 32 }
            Invoke-AapCycle
            $script:calls.Count | Should -Be 0
            $AapRt.Applied | Should -Be '2,8,32'
        }

        It 'only writes and checks while paused' {
            $AapRt.Paused = $true
            Write-AapSettingsFile '{"runner_count":2,"job_cpus":8,"job_memory_gib":32,"paused":true}'
            Invoke-AapCycle
            $script:calls.Count | Should -Be 3
            $script:calls[2] | Should -Be ($script:W + '/usr/local/sbin/aap-runner-manager --check-limits')
            $AapRt.Applied | Should -Be '2,8,32'
        }
    }

    Describe 'pause and resume' {
        BeforeEach {
            $AapRt.Mode = 'on'
            $AapRt.KeepAlive = Get-AapFakeProcess
            $script:keep = $AapRt.KeepAlive
            $AapRt.NextHealth = $script:clock.Now.AddHours(1)
            $AapRt.Effective = @{ RunnerCount = 4; JobCpus = 28; JobMemoryGib = 72 }
            Write-AapStateFile '{"desired":"on"}'
            Write-AapSettingsFile '{"runner_count":4,"job_cpus":28,"job_memory_gib":72,"paused":true}'
            $script:W = 'wsl -d aap-runner -u root -- '
            $script:activeLeft = 1
            $script:responder = {
                param($line)
                if ($line -like '*is-active aap-runner-manager') {
                    if ($script:activeLeft -gt 0) { $script:activeLeft--; return (Get-AapFakeResult 0 'active') }
                    return (Get-AapFakeResult 3 'inactive')
                }
                return (Get-AapFakeResult 0 '')
            }
        }

        It 'pause drains, waits for the job, reports paused, keeps the distro' {
            Invoke-AapCycle
            $want = @(
                ($script:W + '/usr/local/sbin/aap-runner-manager --drain')
                ($script:W + '/bin/systemctl is-active aap-runner-manager')
                'sleep 10'
                ($script:W + '/bin/systemctl is-active aap-runner-manager')
            )
            @($script:calls) | Should -Be $want
            $AapRt.Paused | Should -BeTrue
            (Get-AapStatusFile).state | Should -Be 'paused'
            $script:keep.Killed | Should -BeFalse
        }

        It 'resume undrains and starts the manager' {
            $AapRt.Paused = $true
            Write-AapSettingsFile '{"runner_count":4,"job_cpus":28,"job_memory_gib":72,"paused":false}'
            Invoke-AapCycle
            $script:calls[0] | Should -Be ($script:W + '/usr/local/sbin/aap-runner-manager --undrain')
            $script:calls[1] | Should -Be ($script:W + '/bin/systemctl start aap-runner-manager')
            $AapRt.Paused | Should -BeFalse
        }

        It 'restarts sysbox but not the manager while paused' {
            $AapRt.Paused = $true
            $AapRt.NextHealth = [DateTimeOffset]::MinValue
            $script:responder = {
                param($line)
                if ($line -like '*is-active sysbox aap-runner-manager') { return (Get-AapFakeResult 3 "inactive`ninactive") }
                return (Get-AapFakeResult 0 '')
            }
            Invoke-AapCycle
            $script:calls | Should -Contain ($script:W + '/bin/systemctl start sysbox')
            $script:calls | Should -Not -Contain ($script:W + '/bin/systemctl start aap-runner-manager')
            $script:responder = {
                param($line)
                if ($line -like '*is-active sysbox aap-runner-manager') { return (Get-AapFakeResult 3 "active`ninactive") }
                return (Get-AapFakeResult 0 '')
            }
            $script:calls.Clear()
            $script:clock.Now = $AapRt.NextHealth
            Invoke-AapCycle
            $script:calls | Should -Not -Contain ($script:W + '/bin/systemctl start aap-runner-manager')
            (Get-AapStatusFile).state | Should -Be 'paused'
        }

        It 'Off beats paused' {
            $AapRt.Paused = $true
            $script:activeLeft = 0
            Write-AapStateFile '{"desired":"off"}'
            Invoke-AapCycle
            $script:calls[-1] | Should -Be 'wsl --terminate aap-runner'
            $AapRt.Mode | Should -Be 'off'
            $AapRt.Paused | Should -BeFalse
            (Get-AapStatusFile).state | Should -Be 'off'
        }
    }

    Describe 'Invoke-AapWsl guard' {
        It 'refuses an argument outside the allow-list before starting wsl.exe' {
            $f = Get-Command Invoke-AapWsl -CommandType Function
            { & $f.ScriptBlock -Arguments @('-d', 'aap-runner; calc') } | Should -Throw '*refusing wsl.exe argument*'
            { & $f.ScriptBlock -Arguments @('-d', 'aap-runner', '--', '/bin/sh', '-c', 'rm -rf /') } | Should -Throw '*refusing wsl.exe argument*'
        }

        It 'is the only place wsl.exe is started' {
            $src = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'aap-runner-supervisor.ps1')
            ([regex]::Matches($src, "FileName = 'wsl.exe'")).Count | Should -Be 1
            $src | Should -Not -Match '&\s*wsl(\.exe)?\s'
        }
    }

    Describe 'install-supervisor.ps1' {
        BeforeAll {
            . (Join-Path $PSScriptRoot 'install-supervisor.ps1')
            $script:template = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'aap-runner-supervisor-task.xml')
            $script:sid = 'S-1-5-21-111-222-333-1001'
            $script:ps1 = 'C:\aap-runner\windows\aap-runner-supervisor.ps1'
        }

        It 'replaces every placeholder for the logon task' {
            $xml = Get-AapSupervisorTaskXml -Template $script:template -UserSid $script:sid -Ps1 $script:ps1
            $xml | Should -Not -Match '__AAP_'
            $xml | Should -Match '<UserId>S-1-5-21-111-222-333-1001</UserId>'
            $xml | Should -Match ([regex]::Escape("&amp; 'C:\aap-runner\windows\aap-runner-supervisor.ps1'"))
            $xml | Should -Match '<LogonTrigger>'
            $xml | Should -Match '<LogonType>InteractiveToken</LogonType>'
            $xml | Should -Match '<RunLevel>HighestAvailable</RunLevel>'
            $xml | Should -Match '<Hidden>true</Hidden>'
            $xml | Should -Match '<ExecutionTimeLimit>PT0S</ExecutionTimeLimit>'
            $xml | Should -Match '-WindowStyle Hidden'
            [void]([xml]$xml)
        }


        It 'refuses <name>' -TestCases @(
            @{ name = 'SYSTEM'; sid = 'S-1-5-18'; path = 'C:\aap-runner\windows\a.ps1' }
            @{ name = 'markup in the SID'; sid = 'S-1-5-21-1-2-3-1001</UserId>'; path = 'C:\aap-runner\windows\a.ps1' }
            @{ name = 'a quote in the path'; sid = 'S-1-5-21-1-2-3-1001'; path = "C:\x'; calc; '.ps1" }
        ) {
            { Get-AapSupervisorTaskXml -Template $script:template -UserSid $sid -Ps1 $path } | Should -Throw '*refusing*'
        }

        It 'plans with exit 0 on a non-elevated dry run' {
            $plan = Get-AapSupervisorPlan @{ Elevated = $false; DryRun = $true; DataDir = 'D'; ScriptDir = 'S'; TaskName = 'T'; UserSid = $script:sid }
            $plan.ExitCode | Should -Be 0
            ($plan.Lines -join "`n") | Should -Match 'INFO elevation not-admin'
            ($plan.Lines -join "`n") | Should -Match 'Start-ScheduledTask T'
        }

        It 'refuses a non-elevated real run before any change' {
            Mock Test-AapElevated { return $false }
            Mock Protect-AapDataDir { throw 'must not be reached' }
            Mock schtasks.exe { throw 'must not be reached' }
            $DryRun = $false
            $DataDir = Join-Path $TestDrive 'pd-refuse'
            $ScriptDir = Join-Path $TestDrive 'sd-refuse'
            $code = @(Invoke-AapInstallSupervisor | Where-Object { $_ -is [int] })[-1]
            $code | Should -Be 1
            Test-Path -LiteralPath $DataDir | Should -BeFalse
            Test-Path -LiteralPath $ScriptDir | Should -BeFalse
            Should -Invoke Protect-AapDataDir -Times 0 -Exactly
        }
    }

    Describe 'tray autostart' {
        BeforeAll {
            . (Join-Path $PSScriptRoot 'install-supervisor.ps1')
            . (Join-Path $PSScriptRoot 'uninstall-supervisor.ps1')
            $script:sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        }

        BeforeEach {
            # Pester's TestRegistry is a throwaway key under HKCU, removed after the test.
            $script:runKey = 'TestRegistry:\Run'
        }

        It 'writes the quoted exe path' {
            Write-AapTrayRunValue $script:runKey 'C:\Program Files\AAP\aap-runner-tray.exe'
            (Get-ItemProperty -LiteralPath $script:runKey).'AAP-Runner-Tray' | Should -BeExactly '"C:\Program Files\AAP\aap-runner-tray.exe"'
        }

        It 'refuses a tray path with a quote' {
            { Write-AapTrayRunValue $script:runKey 'C:\x" & calc & ".exe' } | Should -Throw '*refusing*'
        }

        It 'removes the value on uninstall and tolerates it being absent' {
            Write-AapTrayRunValue $script:runKey 'C:\TOOLS\git_runner\aap-runner-tray.exe'
            Clear-AapTrayRunValue $script:runKey
            Get-ItemProperty -LiteralPath $script:runKey -Name 'AAP-Runner-Tray' -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
            { Clear-AapTrayRunValue $script:runKey } | Should -Not -Throw
        }

        It 'targets HKEY_USERS of the installing SID' {
            Get-AapRunKey $script:sid | Should -Be "Registry::HKEY_USERS\$($script:sid)\Software\Microsoft\Windows\CurrentVersion\Run"
        }

        Context 'install and uninstall runs with every host change mocked' {
            BeforeEach {
                Mock Test-AapElevated { return $true }
                Mock Protect-AapDataDir { }
                Mock Test-AapAdminAcl { return $true }
                Mock Write-AapTrayRunValue { }
                Mock Clear-AapTrayRunValue { }
                Mock Stop-ScheduledTask { throw 'must not be reached' }
                Mock Unregister-ScheduledTask { throw 'must not be reached' }
                Mock Get-ScheduledTask { return $null }
                $script:schtasks = New-Object System.Collections.Generic.List[string]
                Mock schtasks.exe { $script:schtasks.Add(($args -join ' ')); $global:LASTEXITCODE = 0 }
                # Proves the schtasks mock is live before an install run.
                schtasks.exe /Probe
                $script:schtasks.Count | Should -Be 1
                $DryRun = $false
                $DataDir = Join-Path $TestDrive ('pd-' + [guid]::NewGuid().ToString('n'))
                $ScriptDir = Join-Path $TestDrive ('sd-' + [guid]::NewGuid().ToString('n'))
                $TaskName = 'AAP-Test-NotRegistered'
            }

            It 'writes the Run value when the tray exe exists' {
                $TrayExe = Join-Path $TestDrive 'aap-runner-tray.exe'
                Set-Content -LiteralPath $TrayExe -Value 'x'
                $code = @(Invoke-AapInstallSupervisor | Where-Object { $_ -is [int] })[-1]
                $code | Should -Be 0
                Should -Invoke Write-AapTrayRunValue -Times 1 -Exactly -ParameterFilter {
                    $Exe -eq $TrayExe -and $RunKey -eq "Registry::HKEY_USERS\$($script:sid)\Software\Microsoft\Windows\CurrentVersion\Run"
                }
            }

            It 'skips the Run value when the tray exe is missing' {
                $TrayExe = Join-Path $TestDrive 'missing-tray.exe'
                $code = @(Invoke-AapInstallSupervisor | Where-Object { $_ -is [int] })[-1]
                $code | Should -Be 0
                Should -Invoke Write-AapTrayRunValue -Times 0 -Exactly
            }

            It 'uninstall removes the Run value of the installing SID' {
                $code = @(Invoke-AapUninstallSupervisor | Where-Object { $_ -is [int] })[-1]
                $code | Should -Be 0
                Should -Invoke Clear-AapTrayRunValue -Times 1 -Exactly -ParameterFilter {
                    $RunKey -eq "Registry::HKEY_USERS\$($script:sid)\Software\Microsoft\Windows\CurrentVersion\Run"
                }
            }
        }
    }

    Describe 'dry-run processes' {
        BeforeAll {
            $script:exe = (Get-Process -Id $PID).Path
        }

        It 'install-supervisor.ps1 -DryRun exits 0' {
            $pd = Join-Path $TestDrive 'pd'
            $out = & $script:exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'install-supervisor.ps1') -DryRun -DataDir $pd -ScriptDir (Join-Path $TestDrive 'sd') -TaskName 'AAP-Test-NotRegistered' -TrayExe (Join-Path $TestDrive 'missing-tray.exe') 2>&1 | Out-String
            $LASTEXITCODE | Should -Be 0
            $out | Should -Match 'WOULD task AAP-Test-NotRegistered logon trigger'
            $out | Should -Match 'INFO tray .*missing-tray.exe not found; Run value skipped'
            Test-Path -LiteralPath $pd | Should -BeFalse
        }


        It 'install-supervisor.ps1 -DryRun prints the Run value for an existing tray exe' {
            $tray = Join-Path $TestDrive 'aap-runner-tray.exe'
            Set-Content -LiteralPath $tray -Value 'x'
            $out = & $script:exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'install-supervisor.ps1') -DryRun -DataDir (Join-Path $TestDrive 'pd') -ScriptDir (Join-Path $TestDrive 'sd') -TaskName 'AAP-Test-NotRegistered' -TrayExe $tray 2>&1 | Out-String
            $LASTEXITCODE | Should -Be 0
            $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            $out | Should -Match ([regex]::Escape("WOULD run-key Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Run AAP-Runner-Tray = `"$tray`""))
        }

        It 'uninstall-supervisor.ps1 -DryRun exits 0' {
            $out = & $script:exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'uninstall-supervisor.ps1') -DryRun -DataDir (Join-Path $TestDrive 'pd') -ScriptDir (Join-Path $TestDrive 'sd') -TaskName 'AAP-Test-NotRegistered' 2>&1 | Out-String
            $LASTEXITCODE | Should -Be 0
            $out | Should -Match 'KEEP'
            $out | Should -Match 'WOULD remove Run value AAP-Runner-Tray from Registry::HKEY_USERS'
        }

        It 'aap-runner-supervisor.ps1 -Once -DryRun exits 0 without calling wsl.exe' {
            $pd = Join-Path $TestDrive 'pd-sup'
            New-Item -ItemType Directory -Force -Path $pd | Out-Null
            [IO.File]::WriteAllText((Join-Path $pd 'state.json'), '{"desired":"on"}')
            $out = & $script:exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'aap-runner-supervisor.ps1') -Once -DryRun -DataDir $pd 2>&1 | Out-String
            $LASTEXITCODE | Should -Be 0
            $out | Should -Match 'DRYRUN would Start-ScheduledTask AAP-CRRR-Mount-Work-Disk'
            Test-Path -LiteralPath (Join-Path $pd 'status.json') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $pd 'logs') | Should -BeFalse
        }
    }
}
