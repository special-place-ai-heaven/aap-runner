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
        # The mutation runner (tests/supervisor) points this at a mutated copy.
        $script:sup = Join-Path $PSScriptRoot 'aap-runner-supervisor.ps1'
        if ($env:AAP_SUPERVISOR_SCRIPT) { $script:sup = $env:AAP_SUPERVISOR_SCRIPT }
        . $script:sup
        $script:fixtures = Join-Path $PSScriptRoot '..\parity\contracts\fixtures'
        $script:validator = Join-Path $PSScriptRoot '..\parity\contracts\validate.py'

        # A contract fixture as the file a writer would produce: an invalid one is
        # wrapped as {"expect": ..., "instance": ...}.
        function Get-AapFixture([string]$Path) {
            $text = Get-Content -Raw -LiteralPath (Join-Path $script:fixtures $Path)
            $o = $text | ConvertFrom-Json
            if ($o.PSObject.Properties['instance']) { return (ConvertTo-Json $o.instance -Compress -Depth 8) }
            return $text
        }

        function Get-AapV5File {
            return Get-Content -Raw -LiteralPath (Join-Path $AapCfg.DataDir 'status.v5.json') | ConvertFrom-Json
        }

        # parity/contracts/validate.py on the status.v5.json just written: 'ok' or its verdict.
        function Test-AapV5Contract {
            $out = & python $script:validator status-v5 (Join-Path $AapCfg.DataDir 'status.v5.json') 2>&1
            if ($LASTEXITCODE -eq 0) { return 'ok' }
            return ($out | Out-String).Trim()
        }

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
            [IO.File]::WriteAllText((Join-Path $AapCfg.DataDir 'inbox\state.json'), $Text)
        }

        function Write-AapSettingsFile([string]$Text) {
            [IO.File]::WriteAllText((Join-Path $AapCfg.DataDir 'inbox\settings.json'), $Text)
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
                '*cat /run/aap-runner/status.json' { return (Get-AapFakeResult 0 '{"state":"idle","job":"","slots":3,"busy":0,"updated":1,"runner_count":3,"job_cpus":28,"job_memory":"72g"}') }
                '*is-active aap-runner-manager' { return (Get-AapFakeResult 3 'inactive') }
                default { return (Get-AapFakeResult 0 '') }
            }
        }
    }

    BeforeEach {
        $AapCfg.DataDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Force -Path (Join-Path $AapCfg.DataDir 'inbox') | Out-Null
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
        # A fixed host: 32 logical CPUs, 96 GiB.
        Mock Get-AapHostInfo {
            return [ordered]@{ cpu_cores = [long]32; mem_gib = [long]96; volumes = @(Get-AapHostVolumes $Doc); io_mbps = [long]$script:hostIo; control_distro_mem_gib = [long]2 }
        }
        $script:hostIo = 0
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

        It 'reads exactly 4096 bytes and refuses <size> bytes' -TestCases @(
            @{ size = 4097 }
            @{ size = 4098 }
        ) {
            $head = '{"desired":"on"}'
            Write-AapStateFile ($head + (' ' * (4096 - $head.Length)))
            (Get-Item -LiteralPath (Join-Path $AapCfg.DataDir 'inbox\state.json')).Length | Should -Be 4096
            Read-AapDesired | Should -Be 'on'
            Write-AapStateFile ($head + (' ' * ($size - $head.Length)))
            Read-AapDesired | Should -Be 'off'
            Get-AapLogText | Should -Match 'WARN state.json is larger than 4 KB'
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
            @($s.PSObject.Properties.Name) -join ',' | Should -Be 'state,job,updated,detail,runner_count,job_cpus,job_memory_gib,repo,run_url,schema,sampled_at,pool,slots,job_io_mbps,sharing,work_disk_gib,work_disk_free_gb,work_disk_floor_gb,cleaning'
            $s.runner_count | Should -BeNullOrEmpty
            $s.schema | Should -Be 4
            @($s.slots).Count | Should -Be 0
            @($s.pool.PSObject.Properties.Name) -join ',' | Should -Be 'cpu_cores,mem_gib,io_mbps'
            $s.work_disk_gib | Should -BeNullOrEmpty
            $s.cleaning | Should -BeFalse
            $s.pool.cpu_cores | Should -BeNullOrEmpty
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
                'wsl -d aap-runner -u root -- /bin/grep -q -- --undrain /usr/local/sbin/aap-runner-manager'
                'wsl -d aap-runner -u root -- /usr/local/sbin/aap-runner-manager --undrain'
                'wsl -d aap-runner -u root -- /bin/systemctl start sysbox aap-runner-manager'
                'wsl -d aap-runner -u root -- /bin/systemctl is-active sysbox aap-runner-manager'
                'wsl -d aap-runner -u root -- /bin/systemctl is-active sysbox aap-runner-manager'
                'wsl -d aap-runner -u root -- /bin/cat /run/aap-runner/status.json'
            )
            @($script:calls) | Should -Be $want
            $AapRt.Mode | Should -Be 'on'
            $s = Get-AapStatusFile
            $s.state | Should -Be 'idle'
            $s.runner_count | Should -Be 3
            $s.job_cpus | Should -Be 28
            $s.job_memory_gib | Should -Be 72
        }

        It 'logs a failing --undrain and continues' {
            $script:responder = {
                param($line)
                if ($line -like '*--undrain') { return (Get-AapFakeResult 1 '') }
                return (& $script:healthy $line)
            }
            Write-AapStateFile '{"desired":"on"}'
            Invoke-AapCycle
            $AapRt.Mode | Should -Be 'on'
            Get-AapLogText | Should -Match 'undrain exit 1'
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

        It 'mirrors <name>' -TestCases @(
            @{ name = 'a valid repo and run_url'; extra = ',"repo":"Org-1/my.repo_x","run_url":"https://github.com/Org-1/my.repo_x/actions/runs/123"'; repo = 'Org-1/my.repo_x'; url = 'https://github.com/Org-1/my.repo_x/actions/runs/123' }
            @{ name = 'absent fields as empty'; extra = ''; repo = ''; url = '' }
            @{ name = 'another host as empty'; extra = ',"repo":"o/r","run_url":"https://evil.example/o/r/actions/runs/1"'; repo = 'o/r'; url = '' }
            @{ name = 'http as empty'; extra = ',"repo":"o/r","run_url":"http://github.com/o/r/actions/runs/1"'; repo = 'o/r'; url = '' }
            @{ name = 'an upper-case host as empty'; extra = ',"repo":"o/r","run_url":"https://GITHUB.com/o/r/actions/runs/1"'; repo = 'o/r'; url = '' }
            @{ name = 'a trailing newline as empty'; extra = ',"repo":"o/r\n","run_url":"https://github.com/o/r/actions/runs/1\n"'; repo = ''; url = '' }
            @{ name = 'a query string as empty'; extra = ',"repo":"o/r","run_url":"https://github.com/o/r/actions/runs/1?x=javascript:1"'; repo = 'o/r'; url = '' }
            @{ name = 'a non-string as empty'; extra = ',"repo":["o/r"],"run_url":{"u":"https://github.com/o/r/actions/runs/1"}'; repo = ''; url = '' }
            @{ name = 'an invalid repo as empty'; extra = ',"repo":"o/r/x","run_url":""'; repo = ''; url = '' }
        ) {
            $script:extra = $extra
            $script:responder = {
                param($line)
                if ($line -like '*cat /run/aap-runner/status.json') { return (Get-AapFakeResult 0 ('{"state":"running","job":"ci-123","slots":3,"busy":1' + $script:extra + '}')) }
                return (& $script:healthy $line)
            }
            Write-AapStateFile '{"desired":"on"}'
            Invoke-AapCycle
            $s = Get-AapStatusFile
            $s.state | Should -Be 'running'
            $s.repo | Should -BeExactly $repo
            $s.run_url | Should -BeExactly $url
        }

        It 'keeps repo and run_url on the heartbeat and clears them on Off' {
            $script:responder = {
                param($line)
                if ($line -like '*cat /run/aap-runner/status.json') { return (Get-AapFakeResult 0 '{"state":"running","job":"ci-1","repo":"o/r","run_url":"https://github.com/o/r/actions/runs/9"}') }
                return (& $script:healthy $line)
            }
            Write-AapStateFile '{"desired":"on"}'
            Invoke-AapCycle
            $script:clock.Now = $AapRt.StatusAt.AddSeconds($AapCfg.HeartbeatSeconds)
            $AapRt.NextHealth = $script:clock.Now.AddHours(1)
            Invoke-AapCycle
            (Get-AapStatusFile).run_url | Should -Be 'https://github.com/o/r/actions/runs/9'
            Write-AapStateFile '{"desired":"off"}'
            Invoke-AapCycle
            $s = Get-AapStatusFile
            $s.state | Should -Be 'off'
            $s.repo | Should -BeExactly ''
            $s.run_url | Should -BeExactly ''
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

        It 'keeps mount failures out of the restart counter' {
            # Live on Fresh 2026-10-14: three mount failures made the first
            # manager restart log "restart 4" and the fifth go to error.
            $script:mountResult = 1
            Write-AapStateFile '{"desired":"on"}'
            foreach ($want in 10, 30, 60) {
                Invoke-AapCycle
                (Get-AapStatusFile).detail | Should -Match "LastTaskResult 1; retry in $want s"
                $script:clock.Now = $AapRt.RetryAt
            }
            $AapRt.Failures | Should -Be 0
            $script:mountResult = 0
            $script:responder = {
                param($line)
                if ($line -like '*is-active sysbox aap-runner-manager') { return (Get-AapFakeResult 3 "active`nfailed") }
                return (& $script:healthy $line)
            }
            Invoke-AapCycle
            $AapRt.OnFailures | Should -Be 0
            Get-AapLogText | Should -Match 'manager=failed; restart 1; next check in 10 s'
            Get-AapLogText | Should -Not -Match 'restart [2-9]'
            (Get-AapStatusFile).state | Should -Be 'starting'
        }
    }

    Describe 'status mirror schema 3' {
        BeforeAll {
            # 1760436000 = 2025-10-14T10:00:00Z. The manager writes unix seconds.
            $script:slot1 = '{"slot":1,"state":"running","job":"ci-1","repo":"o/r","run_url":"https://github.com/o/r/actions/runs/9","job_url":"https://github.com/o/r/actions/runs/9/job/77","started_at":1760436000,"cpu_cores":6.2,"mem_gib":12.5}'
            $script:slot2 = '{"slot":2,"state":"idle","job":"","repo":"","run_url":"","job_url":null,"started_at":null,"cpu_cores":null,"mem_gib":null}'
            $script:full = '{"schema":3,"state":"running","job":"ci-1","runner_count":2,"job_cpus":16,"job_memory":"32g","job_io_mbps":120,"sharing":"slice","sampled_at":1760436000,"pool":{"cpu_cores":6.2,"mem_gib":12.5,"io_mbps":240},"slots":[' + $script:slot1 + ',' + $script:slot2 + ']}'

            function Invoke-AapMirror([string]$Text) {
                $script:managerJson = $Text
                $script:responder = {
                    param($line)
                    if ($line -like '*cat /run/aap-runner/status.json') { return (Get-AapFakeResult 0 $script:managerJson) }
                    return (& $script:healthy $line)
                }
                Write-AapStateFile '{"desired":"on"}'
                Invoke-AapCycle
                return Get-AapStatusFile
            }

            # pwsh 7's ConvertFrom-Json turns times into DateTime; check them as text.
            function Get-AapStatusText {
                return [IO.File]::ReadAllText((Join-Path $AapCfg.DataDir 'status.json'))
            }
        }

        It 'mirrors pool, slots, job_io_mbps and sharing from a schema 3 manager' {
            $s = Invoke-AapMirror $script:full
            $s.schema | Should -Be 4
            $s.state | Should -Be 'running'
            $s.work_disk_gib | Should -BeNullOrEmpty
            $s.cleaning | Should -BeFalse
            $s.pool.cpu_cores | Should -Be 6.2
            $s.pool.mem_gib | Should -Be 12.5
            $s.pool.io_mbps | Should -Be 240
            $s.job_io_mbps | Should -Be 120
            $s.sharing | Should -BeExactly 'slice'
            @($s.slots).Count | Should -Be 2
            @($s.slots[0].PSObject.Properties.Name) -join ',' | Should -Be 'slot,state,job,repo,run_url,job_url,started_at,cpu_cores,mem_gib'
            $s.slots[0].slot | Should -Be 1
            $s.slots[0].state | Should -BeExactly 'running'
            $s.slots[0].job | Should -BeExactly 'ci-1'
            $s.slots[0].repo | Should -BeExactly 'o/r'
            $s.slots[0].run_url | Should -BeExactly 'https://github.com/o/r/actions/runs/9'
            $s.slots[0].job_url | Should -BeExactly 'https://github.com/o/r/actions/runs/9/job/77'
            $s.slots[0].cpu_cores | Should -Be 6.2
            $s.slots[0].mem_gib | Should -Be 12.5
            $s.slots[1].state | Should -BeExactly 'idle'
            $s.slots[1].job_url | Should -BeExactly ''
            $s.slots[1].cpu_cores | Should -BeNullOrEmpty
            $t = Get-AapStatusText
            $t | Should -Match '"sampled_at":"2025-10-14T10:00:00Z"'
            $t | Should -Match '"started_at":"2025-10-14T10:00:00Z"'
            $t | Should -Match '"started_at":null'
        }

        It 'mirrors work disk and cleaning from a schema 4 manager' {
            $s = Invoke-AapMirror '{"schema":4,"state":"running","job":"ci-1","runner_count":2,"job_cpus":16,"job_memory":"32g","work_disk_gib":100,"work_disk_free_gb":40,"work_disk_floor_gb":15,"cleaning":true,"slots":[]}'
            $s.schema | Should -Be 4
            $s.work_disk_gib | Should -Be 100
            $s.work_disk_free_gb | Should -Be 40
            $s.work_disk_floor_gb | Should -Be 15
            $s.cleaning | Should -BeTrue
            $parsed = ConvertFrom-AapManagerStatus '{"schema":4,"state":"idle","job":"","work_disk_gib":-1,"work_disk_free_gb":"x","work_disk_floor_gb":9000,"cleaning":"yes","slots":[]}'
            Write-AapStatus 'running' 'ci-1' '' '' '' $parsed
            $bad = Get-AapStatusFile
            $bad.work_disk_gib | Should -BeNullOrEmpty
            $bad.work_disk_free_gb | Should -BeNullOrEmpty
            $bad.work_disk_floor_gb | Should -BeNullOrEmpty
            $bad.cleaning | Should -BeFalse
        }

        It 'passes an RFC 3339 sampled_at through' {
            [void](Invoke-AapMirror '{"state":"idle","job":"","sampled_at":"2026-10-14T10:00:00Z","slots":[]}')
            Get-AapStatusText | Should -Match '"sampled_at":"2026-10-14T10:00:00Z"'
        }

        It 'mirrors job_url <name>' -TestCases @(
            @{ name = 'a valid job link'; url = 'https://github.com/Org-1/my.repo_x/actions/runs/123/job/456'; want = 'https://github.com/Org-1/my.repo_x/actions/runs/123/job/456' }
            @{ name = 'a run link as empty'; url = 'https://github.com/o/r/actions/runs/1'; want = '' }
            @{ name = 'another host as empty'; url = 'https://evil.example/o/r/actions/runs/1/job/2'; want = '' }
            @{ name = 'http as empty'; url = 'http://github.com/o/r/actions/runs/1/job/2'; want = '' }
            @{ name = 'a query string as empty'; url = 'https://github.com/o/r/actions/runs/1/job/2?x=1'; want = '' }
            @{ name = 'a trailing newline as empty'; url = "https://github.com/o/r/actions/runs/1/job/2`n"; want = '' }
            @{ name = 'a non-numeric job as empty'; url = 'https://github.com/o/r/actions/runs/1/job/x'; want = '' }
        ) {
            $slot = [ordered]@{ slot = 1; state = 'running'; job_url = $url }
            $text = '{"state":"running","job":"j","slots":[' + (ConvertTo-Json -InputObject $slot -Compress) + ']}'
            $s = Invoke-AapMirror $text
            $s.slots[0].job_url | Should -BeExactly $want
        }

        It 'nulls or empties out-of-range and mistyped values and drops non-object slots' {
            $bad = '{"slot":"1","state":"busy","job":["x"],"repo":"o/r/x","run_url":"http://github.com/o/r/actions/runs/1","job_url":"https://github.com/o/r/actions/runs/1","started_at":"yesterday","cpu_cores":2000,"mem_gib":true}'
            $s = Invoke-AapMirror ('{"state":"running","job":"j","job_io_mbps":true,"sharing":"Slice","sampled_at":"2026-10-14","pool":{"cpu_cores":-1,"mem_gib":5000,"io_mbps":"240"},"slots":[42,"x",null,' + $bad + ']}')
            $s.pool.cpu_cores | Should -BeNullOrEmpty
            $s.pool.mem_gib | Should -BeNullOrEmpty
            $s.pool.io_mbps | Should -BeNullOrEmpty
            $s.job_io_mbps | Should -BeNullOrEmpty
            $s.sharing | Should -BeNullOrEmpty
            @($s.slots).Count | Should -Be 1
            $s.slots[0].slot | Should -BeNullOrEmpty
            $s.slots[0].state | Should -BeExactly ''
            $s.slots[0].job | Should -BeExactly ''
            $s.slots[0].repo | Should -BeExactly ''
            $s.slots[0].run_url | Should -BeExactly ''
            $s.slots[0].job_url | Should -BeExactly ''
            $s.slots[0].cpu_cores | Should -BeNullOrEmpty
            $s.slots[0].mem_gib | Should -BeNullOrEmpty
            $t = Get-AapStatusText
            $t | Should -Match '"sampled_at":null'
            $t | Should -Match '"started_at":null'
        }

        It 'nulls a pool that is not an object' {
            $s = Invoke-AapMirror '{"state":"idle","job":"","pool":[1,2,3],"slots":[]}'
            $s.pool.cpu_cores | Should -BeNullOrEmpty
            @($s.pool.PSObject.Properties.Name) -join ',' | Should -Be 'cpu_cores,mem_gib,io_mbps'
        }

        It 'keeps at most 5 slots' {
            $six = (1..6 | ForEach-Object { '{"slot":' + $_ + ',"state":"idle"}' }) -join ','
            $s = Invoke-AapMirror ('{"state":"idle","job":"","slots":[' + $six + ']}')
            @($s.slots).Count | Should -Be 5
            $s.slots[4].slot | Should -Be 5
        }

        It 'reads runner_count 5' {
            Write-AapSettingsFile '{"runner_count":5,"job_cpus":24,"job_memory_gib":72,"paused":false}'
            $s = Read-AapSettingsFile
            Get-AapLimitsKey $s.Limits | Should -Be '5,24,72'
            Get-AapLogText | Should -Not -Match 'WARN'
        }

        It 'mirrors an older manager <name> with slots [] and schema 3' -TestCases @(
            @{ name = 'with a slots count'; text = '{"state":"running","job":"ci-9","slots":3,"busy":1,"runner_count":3,"job_cpus":28,"job_memory":"72g","repo":"o/r"}' }
            @{ name = 'without slots'; text = '{"state":"running","job":"ci-9","repo":"o/r"}' }
        ) {
            $s = Invoke-AapMirror $text
            $s.schema | Should -Be 4
            $s.state | Should -Be 'running'
            $s.job | Should -Be 'ci-9'
            $s.work_disk_gib | Should -BeNullOrEmpty
            $s.cleaning | Should -BeFalse
            $s.repo | Should -Be 'o/r'
            @($s.slots).Count | Should -Be 0
            $s.pool.cpu_cores | Should -BeNullOrEmpty
            $t = Get-AapStatusText
            $t | Should -Match '"slots":\[\]'
            $t | Should -Match '"sampled_at":null'
        }

        It 'writes no pool or slots while <state>' -TestCases @(
            @{ state = 'off' }
            @{ state = 'paused' }
            @{ state = 'starting' }
            @{ state = 'error' }
        ) {
            $m = ConvertFrom-AapManagerStatus $script:full
            Write-AapStatus 'running' 'ci-1' '' '' '' $m
            @((Get-AapStatusFile).slots).Count | Should -Be 2
            Write-AapStatus $state '' '' '' '' $m
            $s = Get-AapStatusFile
            @($s.slots).Count | Should -Be 0
            $s.pool.cpu_cores | Should -BeNullOrEmpty
            $s.job_io_mbps | Should -BeNullOrEmpty
            $s.sharing | Should -BeNullOrEmpty
            $s.work_disk_gib | Should -BeNullOrEmpty
            $s.cleaning | Should -BeFalse
            Get-AapStatusText | Should -Match '"sampled_at":null'
        }

        It 'keeps slots on the heartbeat and clears them on Off' {
            [void](Invoke-AapMirror $script:full)
            $script:clock.Now = $AapRt.StatusAt.AddSeconds($AapCfg.HeartbeatSeconds)
            $AapRt.NextHealth = $script:clock.Now.AddHours(1)
            $script:calls.Clear()
            Invoke-AapCycle
            $script:calls.Count | Should -Be 0
            @((Get-AapStatusFile).slots).Count | Should -Be 2
            (Get-AapStatusFile).updated | Should -Not -BeNullOrEmpty
            Write-AapStateFile '{"desired":"off"}'
            Invoke-AapCycle
            $s = Get-AapStatusFile
            $s.state | Should -Be 'off'
            @($s.slots).Count | Should -Be 0
            $s.pool.cpu_cores | Should -BeNullOrEmpty
        }
    }

    Describe 'Off sequence' {
        BeforeEach {
            $AapRt.Mode = 'on'
            $AapRt.ManagerOk = $true
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

    Describe 'retry from state.json' {
        It 'resets the On backoff and runs the mount task now' {
            $script:mountResult = 1
            Write-AapStateFile '{"desired":"on"}'
            Invoke-AapCycle
            $script:clock.Now = $AapRt.RetryAt
            Invoke-AapCycle
            (Get-AapStatusFile).detail | Should -Match 'retry in 30 s'
            $script:calls.Clear()
            Write-AapStateFile '{"desired":"on","retry":1760436000}'
            Invoke-AapCycle
            $script:calls[0] | Should -Be 'task AAP-CRRR-Mount-Work-Disk'
            (Get-AapStatusFile).detail | Should -Match 'retry in 10 s'
            Get-AapLogText | Should -Match 'retry requested \(1760436000\); backoff reset'
            $script:calls.Clear()
            Invoke-AapCycle
            $script:calls.Count | Should -Be 0
        }

        It 'resets the restart counter and checks health now' {
            $AapRt.Mode = 'on'
            $AapRt.KeepAlive = Get-AapFakeProcess
            $AapRt.Failures = 5
            $AapRt.OnFailures = 2
            $AapRt.NextHealth = $script:clock.Now.AddSeconds(300)
            $script:responder = {
                param($line)
                if ($line -like '*is-active sysbox aap-runner-manager') { return (Get-AapFakeResult 3 "active`nfailed") }
                return (Get-AapFakeResult 0 '')
            }
            Write-AapStateFile '{"desired":"on","retry":1760436000}'
            Invoke-AapCycle
            $script:calls | Should -Contain 'wsl -d aap-runner -u root -- /bin/systemctl is-active sysbox aap-runner-manager'
            $AapRt.Failures | Should -Be 1
            $AapRt.OnFailures | Should -Be 0
            Get-AapLogText | Should -Match 'manager=failed; restart 1; next check in 10 s'
            (Get-AapStatusFile).state | Should -Be 'starting'
        }

        It 'ignores retry <name>' -TestCases @(
            @{ name = 'equal to the last one'; value = '100' }
            @{ name = 'older than the last one'; value = '50' }
            @{ name = 'as a string'; value = '"200"' }
            @{ name = 'as a fraction'; value = '200.5' }
            @{ name = 'as a boolean'; value = 'true' }
            @{ name = 'as a command'; value = '"200; wsl --shutdown"' }
        ) {
            $AapRt.LastRetry = 100
            $AapRt.Failures = 3
            Write-AapStateFile ('{"desired":"off","retry":' + $value + '}')
            Read-AapDesired | Should -Be 'off'
            $AapRt.Failures | Should -Be 3
            $AapRt.LastRetry | Should -Be 100
            Get-AapLogText | Should -Not -Match 'retry requested'
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

        It 'reads a schema-less v1 file with no IO or sharing keys' {
            Write-AapSettingsFile '{"runner_count":2,"job_cpus":8,"job_memory_gib":32,"paused":false}'
            $s = Read-AapSettingsFile
            $s.Limits.IoPercent | Should -BeNullOrEmpty
            $s.Limits.Sharing | Should -BeNullOrEmpty
            Get-AapLimitsContent $s.Limits | Should -BeExactly "AAP_RUNNER_COUNT=2`nAAP_JOB_CPUS=8`nAAP_JOB_MEMORY=32g`n"
        }

        It 'reads a schema 2 file with <name>' -TestCases @(
            @{ name = 'io_percent and sharing'; text = '{"schema":2,"runner_count":2,"job_cpus":8,"job_memory_gib":32,"paused":false,"io_percent":50,"sharing":"fixed"}'; key = '2,8,32,io=50,sharing=fixed' }
            @{ name = 'io_percent 0 only'; text = '{"schema":2,"runner_count":2,"job_cpus":8,"job_memory_gib":32,"paused":false,"io_percent":0}'; key = '2,8,32,io=0' }
            @{ name = 'sharing slice only, no schema'; text = '{"runner_count":2,"job_cpus":8,"job_memory_gib":32,"paused":false,"sharing":"slice"}'; key = '2,8,32,sharing=slice' }
            @{ name = 'schema only'; text = '{"schema":2,"runner_count":2,"job_cpus":8,"job_memory_gib":32,"paused":false}'; key = '2,8,32' }
            @{ name = 'windows_runner_count 2, not applied'; text = '{"schema":2,"runner_count":3,"job_cpus":8,"job_memory_gib":32,"paused":false,"windows_runner_count":2}'; key = '3,8,32' }
            @{ name = 'windows_runner_count 0'; text = '{"schema":2,"runner_count":5,"job_cpus":8,"job_memory_gib":32,"paused":false,"windows_runner_count":0}'; key = '5,8,32' }
            @{ name = 'windows_runner_count 4'; text = '{"schema":2,"runner_count":1,"job_cpus":8,"job_memory_gib":32,"paused":false,"windows_runner_count":4}'; key = '1,8,32' }
        ) {
            Write-AapSettingsFile $text
            Get-AapLimitsKey (Read-AapSettingsFile).Limits | Should -Be $key
            Get-AapLogText | Should -Not -Match 'WARN'
        }

        It 'treats a missing file as no override and not paused' {
            $s = Read-AapSettingsFile
            $s.Limits | Should -BeNullOrEmpty
            $s.Paused | Should -BeFalse
            Get-AapLogText | Should -Not -Match 'WARN'
        }

        It 'ignores <name> and keeps the last valid settings' -TestCases @(
            @{ name = 'runner_count 0'; text = '{"runner_count":0,"job_cpus":8,"job_memory_gib":32,"paused":false}' }
            @{ name = 'runner_count 6'; text = '{"runner_count":6,"job_cpus":8,"job_memory_gib":32,"paused":false}' }
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
            @{ name = 'io_percent 101'; text = '{"runner_count":2,"job_cpus":8,"job_memory_gib":32,"paused":false,"io_percent":101}' }
            @{ name = 'io_percent -1'; text = '{"runner_count":2,"job_cpus":8,"job_memory_gib":32,"paused":false,"io_percent":-1}' }
            @{ name = 'io_percent a string'; text = '{"runner_count":2,"job_cpus":8,"job_memory_gib":32,"paused":false,"io_percent":"50"}' }
            @{ name = 'io_percent a fraction'; text = '{"runner_count":2,"job_cpus":8,"job_memory_gib":32,"paused":false,"io_percent":50.5}' }
            @{ name = 'io_percent null'; text = '{"runner_count":2,"job_cpus":8,"job_memory_gib":32,"paused":false,"io_percent":null}' }
            @{ name = 'sharing Slice'; text = '{"runner_count":2,"job_cpus":8,"job_memory_gib":32,"paused":false,"sharing":"Slice"}' }
            @{ name = 'sharing with a newline'; text = '{"runner_count":2,"job_cpus":8,"job_memory_gib":32,"paused":false,"sharing":"fixed\nAAP_X=1"}' }
            @{ name = 'sharing a number'; text = '{"runner_count":2,"job_cpus":8,"job_memory_gib":32,"paused":false,"sharing":1}' }
            @{ name = 'schema 3'; text = '{"schema":3,"runner_count":2,"job_cpus":8,"job_memory_gib":32,"paused":false}' }
            @{ name = 'schema a string'; text = '{"schema":"2","runner_count":2,"job_cpus":8,"job_memory_gib":32,"paused":false}' }
            @{ name = 'Schema in another case'; text = '{"Schema":2,"runner_count":2,"job_cpus":8,"job_memory_gib":32,"paused":false}' }
            @{ name = 'windows_runner_count over the total'; text = '{"runner_count":3,"job_cpus":8,"job_memory_gib":32,"paused":false,"windows_runner_count":3}' }
            @{ name = 'windows_runner_count 5'; text = '{"runner_count":1,"job_cpus":8,"job_memory_gib":32,"paused":false,"windows_runner_count":5}' }
            @{ name = 'windows_runner_count -1'; text = '{"runner_count":2,"job_cpus":8,"job_memory_gib":32,"paused":false,"windows_runner_count":-1}' }
            @{ name = 'windows_runner_count a string'; text = '{"runner_count":2,"job_cpus":8,"job_memory_gib":32,"paused":false,"windows_runner_count":"2"}' }
            @{ name = 'windows_runner_count a fraction'; text = '{"runner_count":2,"job_cpus":8,"job_memory_gib":32,"paused":false,"windows_runner_count":1.5}' }
            @{ name = 'windows_runner_count null'; text = '{"runner_count":2,"job_cpus":8,"job_memory_gib":32,"paused":false,"windows_runner_count":null}' }
            @{ name = 'Windows_runner_count in another case'; text = '{"runner_count":2,"job_cpus":8,"job_memory_gib":32,"paused":false,"Windows_runner_count":2}' }
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
            $AapRt.ManagerOk = $true
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

        It 'writes io_percent and sharing into limits.conf and restarts the manager' {
            Write-AapSettingsFile '{"schema":2,"runner_count":2,"job_cpus":8,"job_memory_gib":32,"paused":false,"io_percent":50,"sharing":"fixed"}'
            Invoke-AapCycle
            $script:stdin[0] | Should -BeExactly "AAP_RUNNER_COUNT=2`nAAP_JOB_CPUS=8`nAAP_JOB_MEMORY=32g`nAAP_JOB_IO_PERCENT=50`nAAP_POOL_SHARING=fixed`n"
            $script:calls | Should -Contain ($script:W + '/usr/local/sbin/aap-runner-manager --drain')
            $script:calls | Should -Contain ($script:W + '/bin/systemctl start aap-runner-manager')
            $AapRt.Applied | Should -Be '2,8,32,io=50,sharing=fixed'
        }

        It 'drains and restarts when only <name> changes' -TestCases @(
            @{ name = 'io_percent'; text = '{"schema":2,"runner_count":2,"job_cpus":8,"job_memory_gib":32,"paused":false,"io_percent":30}'; line = 'AAP_JOB_IO_PERCENT=30' }
            @{ name = 'sharing'; text = '{"schema":2,"runner_count":2,"job_cpus":8,"job_memory_gib":32,"paused":false,"sharing":"fixed"}'; line = 'AAP_POOL_SHARING=fixed' }
        ) {
            Invoke-AapCycle
            $AapRt.Applied | Should -Be '2,8,32'
            $script:calls.Clear()
            $script:activeLeft = 1
            $AapRt.NextHealth = $script:clock.Now.AddHours(1)
            Write-AapSettingsFile $text
            Invoke-AapCycle
            $script:calls | Should -Contain $script:writeLine
            $script:calls | Should -Contain ($script:W + '/usr/local/sbin/aap-runner-manager --drain')
            $script:calls | Should -Contain ($script:W + '/usr/local/sbin/aap-runner-manager --undrain')
            $script:calls | Should -Contain ($script:W + '/bin/systemctl start aap-runner-manager')
            $script:stdin[-1] | Should -Match $line
        }

        # The reserved key on top of a tray-written file, as a future tray with a Windows backend
        # would write it (the current tray never does: settings::tests::no_write_path_emits_...).
        It 'leaves limits.conf and the manager alone when only windows_runner_count changes' {
            Write-AapSettingsFile '{"schema":2,"runner_count":2,"job_cpus":8,"job_memory_gib":32,"paused":false,"io_percent":90,"sharing":"slice"}'
            Invoke-AapCycle
            $AapRt.Applied | Should -Be '2,8,32,io=90,sharing=slice'
            $script:calls.Clear()
            $AapRt.NextHealth = $script:clock.Now.AddHours(1)
            Write-AapSettingsFile '{"schema":2,"runner_count":2,"job_cpus":8,"job_memory_gib":32,"paused":false,"io_percent":90,"sharing":"slice","windows_runner_count":3}'
            Invoke-AapCycle
            $script:calls.Count | Should -Be 0
            $AapRt.Applied | Should -Be '2,8,32,io=90,sharing=slice'
            Get-AapLogText | Should -Not -Match 'WARN'
        }

        It 'counts an identical limits.conf as applied after a supervisor start' {
            Write-AapSettingsFile '{"schema":2,"runner_count":2,"job_cpus":8,"job_memory_gib":32,"paused":false,"io_percent":50}'
            $script:old = "AAP_RUNNER_COUNT=2`nAAP_JOB_CPUS=8`nAAP_JOB_MEMORY=32g`nAAP_JOB_IO_PERCENT=50`n"
            Invoke-AapCycle
            @($script:calls) | Should -Be @(($script:W + '/bin/cat /etc/aap-runner/limits.conf'))
            $AapRt.Applied | Should -Be '2,8,32,io=50'
            Get-AapLogText | Should -Match 'limits.conf already has 2,8,32,io=50'
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
            $AapRt.ManagerOk = $true
            $AapRt.KeepAlive = Get-AapFakeProcess
            $script:keep = $AapRt.KeepAlive
            $AapRt.NextHealth = $script:clock.Now.AddHours(1)
            $AapRt.Effective = @{ RunnerCount = 3; JobCpus = 28; JobMemoryGib = 72 }
            Write-AapStateFile '{"desired":"on"}'
            Write-AapSettingsFile '{"runner_count":3,"job_cpus":28,"job_memory_gib":72,"paused":true}'
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
            Write-AapSettingsFile '{"runner_count":3,"job_cpus":28,"job_memory_gib":72,"paused":false}'
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

    Describe 'status.v5.json without the capacity module' {
        It 'is written beside status.json and passes the contract check' -Tag 'v5' {
            Write-AapStatus 'off' '' ''
            $v = Get-AapV5File
            $v.schema | Should -Be 5
            $v.state | Should -BeExactly 'off'
            @($v.settings_schemas) -join ',' | Should -Be '1,2'
            $v.applied_settings_schema | Should -BeNullOrEmpty
            $v.profiles[0].profile | Should -BeExactly 'linux'
            $v.profiles[0].backend | Should -BeExactly 'wsl-legacy'
            $v.profiles[1].backend | Should -BeExactly 'none'
            $v.profiles[1].available | Should -BeFalse
            $v.profiles[1].unavailable_reason | Should -BeExactly 'capacity module not installed'
            $v.storage.state | Should -BeExactly 'unconfigured'
            $v.capacity.host.cpus | Should -Be 32
            Test-AapV5Contract | Should -Be 'ok'
        }

        It 'mirrors the legacy pool slots with Linux on every slot' -Tag 'v5' {
            $script:managerJson = '{"schema":4,"state":"running","job":"ci-1","runner_count":2,"job_cpus":16,"job_memory":"32g","job_io_mbps":120,"sharing":"fixed","sampled_at":1760436000,"work_disk_gib":200,"work_disk_free_gb":120.7,"work_disk_floor_gb":15,"cleaning":false,"slots":[{"slot":1,"state":"running","job":"ci\u202e-1\u0007","repo":"o/r","run_url":"https://github.com/o/r/actions/runs/9","job_url":"https://github.com/o/r/actions/runs/9/job/77","started_at":1760436000,"cpu_cores":6.2,"mem_gib":12.5},{"slot":2,"state":"idle"}]}'
            $script:responder = {
                param($line)
                if ($line -like '*cat /run/aap-runner/status.json') { return (Get-AapFakeResult 0 $script:managerJson) }
                return (& $script:healthy $line)
            }
            Write-AapStateFile '{"desired":"on"}'
            Write-AapSettingsFile '{"schema":2,"runner_count":2,"job_cpus":16,"job_memory_gib":32,"paused":false,"windows_runner_count":3}'
            Invoke-AapCycle
            $v = Get-AapV5File
            $v.state | Should -BeExactly 'running'
            $v.applied_settings_schema | Should -Be 2
            $v.profiles[0].count | Should -Be 2
            $v.profiles[1].count | Should -Be 0
            $v.profiles[0].profile_cap.cpus | Should -Be 16
            $v.profiles[0].per_runner.mem_gib | Should -Be 16
            @($v.slots).Count | Should -Be 2
            $v.slots[0].os | Should -BeExactly 'Linux'
            $v.slots[0].lifecycle | Should -BeExactly 'busy'
            $v.slots[0].job | Should -BeExactly 'ci -1'
            $v.slots[1].lifecycle | Should -BeExactly 'ready'
            $v.slots[1].job_url | Should -BeNullOrEmpty
            $v.legacy_pool.work_disk_free_gb | Should -Be 120
            $v.legacy_pool.sharing | Should -BeExactly 'fixed'
            [IO.File]::ReadAllText((Join-Path $AapCfg.DataDir 'status.v5.json')) | Should -Match '"started_at":"2025-10-14T10:00:00Z"'
            Test-AapV5Contract | Should -Be 'ok'
        }

        It 'refuses settings schema 3 and names the newer schema in the detail' -Tag 'settings-newer' {
            $AapRt.Mode = 'on'
            $AapRt.ManagerOk = $true
            $AapRt.KeepAlive = Get-AapFakeProcess
            Write-AapStateFile '{"desired":"on"}'
            Write-AapSettingsFile '{"runner_count":3,"job_cpus":12,"job_memory_gib":48,"paused":false}'
            [void](Read-AapSettingsFile)
            Write-AapSettingsFile (Get-AapFixture 'settings-v3\valid\owner-example-per-profile.json')
            Invoke-AapCycle
            Get-AapLimitsKey $AapRt.Settings.Limits | Should -Be '3,12,48'
            (Get-AapStatusFile).detail | Should -Match 'settings.json schema 3 is newer than this supervisor accepts \(1, 2\)'
            (Get-AapV5File).detail | Should -Match 'schema 3 is newer'
            Test-AapV5Contract | Should -Be 'ok'
        }
    }

    Describe 'settings.json schema 3' {
        BeforeEach {
            $AapRt.Cap = $true
            $AapRt.Generation.linux = $null
            Write-AapSettingsFile '{"runner_count":3,"job_cpus":12,"job_memory_gib":48,"paused":true}'
            [void](Read-AapSettingsFile)
        }

        It 'accepts the valid contract fixture <name>' -TestCases @(
            @{ name = 'owner-example-per-profile'; linux = 3; windows = 2; mode = 'per_profile'; shares = '60,30' }
            @{ name = 'legacy-totals-capped-by-share'; linux = 3; windows = 2; mode = 'per_profile'; shares = '60,30' }
            @{ name = 'windows-only-even'; linux = 0; windows = 2; mode = 'even'; shares = ',' }
        ) {
            Write-AapSettingsFile (Get-AapFixture "settings-v3\valid\$name.json")
            $s = Read-AapSettingsFile
            $s.Schema | Should -Be 3
            $s.Profiles.Linux | Should -Be $linux
            $s.Profiles.Windows | Should -Be $windows
            $s.Profiles.ShareMode | Should -BeExactly $mode
            "$($s.Profiles.LinuxShare),$($s.Profiles.WindowsShare)" | Should -Be $shares
            $s.Profiles.Reserve | Should -Be 10
            $s.Profiles.LeaseHours | Should -Be 6
            $s.Limits.RunnerCount | Should -Be $linux
            Get-AapLogText | Should -Not -Match 'WARN'
        }

        It 'refuses the invalid contract fixture <name> and keeps the last valid settings' -Tag 'v3-counts', 'v3-reserve', 'v3-zero-share' -TestCases @(
            @{ name = 'future-schema-4'; tag = 'settings-newer' }
            @{ name = 'share-for-zero-count'; tag = 'v3-zero-share' }
            @{ name = 'shares-plus-reserve-not-100'; tag = 'v3-reserve' }
            @{ name = 'shares-sum-95'; tag = 'v3-reserve' }
            @{ name = 'string-count'; tag = '' }
            @{ name = 'three-plus-three'; tag = 'v3-counts' }
            @{ name = 'unknown-linux-backend'; tag = '' }
            @{ name = 'zero-plus-zero'; tag = 'v3-counts' }
        ) {
            Write-AapSettingsFile (Get-AapFixture "settings-v3\invalid\$name.json")
            $s = Read-AapSettingsFile
            Get-AapLimitsKey $s.Limits | Should -Be '3,12,48'
            $s.Paused | Should -BeTrue
            Get-AapLogText | Should -Match 'WARN settings.json'
        }

        It 'names a newer schema for the status detail until a valid file arrives' -Tag 'settings-newer' {
            Write-AapSettingsFile (Get-AapFixture 'settings-v3\invalid\future-schema-4.json')
            [void](Read-AapSettingsFile)
            $AapRt.SettingsWhy | Should -BeExactly 'settings.json schema 4 is newer than this supervisor accepts (1, 2, 3)'
            Get-AapDetail | Should -Match 'schema 4 is newer'
            Write-AapSettingsFile (Get-AapFixture 'settings-v3\valid\windows-only-even.json')
            [void](Read-AapSettingsFile)
            $AapRt.SettingsWhy | Should -BeNullOrEmpty
        }

        It 'refuses <name>' -Tag 'v3-even', 'v3-zero-share', 'v3-linux-vm' -TestCases @(
            @{ name = 'even shares that are not null'; tag = 'v3-even'; patch = @{ linux_share_percent = 60; windows_share_percent = 30 } }
            @{ name = 'a 0 count with a share'; tag = 'v3-zero-share'; patch = @{ share_mode = 'per_profile'; runner_count = 0; windows_runner_count = 2; linux_share_percent = 30; windows_share_percent = 60 } }
            @{ name = 'reserve 5'; tag = ''; patch = @{ host_reserve_percent = 5 } }
            @{ name = 'lease hours 0'; tag = ''; patch = @{ lease_wall_clock_hours = 0 } }
            @{ name = 'Linux on VMs without an Ubuntu generation'; tag = 'v3-linux-vm'; patch = @{ linux_backend = 'hyperv-vm' } }
            @{ name = 'an extra key'; tag = ''; patch = @{ extra = 1 } }
            @{ name = 'a fraction'; tag = ''; patch = @{ windows_runner_count = 1.5 } }
        ) {
            $o = Get-AapFixture 'settings-v3\valid\windows-only-even.json' | ConvertFrom-Json
            foreach ($k in $patch.Keys) { $o | Add-Member -NotePropertyName $k -NotePropertyValue $patch[$k] -Force }
            Write-AapSettingsFile (ConvertTo-Json $o -Compress)
            $s = Read-AapSettingsFile
            Get-AapLimitsKey $s.Limits | Should -Be '3,12,48'
            Get-AapLogText | Should -Match 'WARN settings.json'
        }

        It 'accepts Linux on VMs while an Ubuntu generation is active' {
            $AapRt.Generation.linux = @{ Id = 'ubuntu-24.04-x64/20261012.334.1-aap.1'; State = 'active' }
            $o = Get-AapFixture 'settings-v3\valid\windows-only-even.json' | ConvertFrom-Json
            $o.linux_backend = 'hyperv-vm'
            Write-AapSettingsFile (ConvertTo-Json $o -Compress)
            (Read-AapSettingsFile).Profiles.LinuxBackend | Should -BeExactly 'hyperv-vm'
        }

        It 'puts an allocator hold-back first in the detail' {
            $AapRt.RefusedWhy = 'limits refused'
            $AapRt.CapWhy = 'resize_waits: slot 5 must leave first'
            $AapRt.CapFlags = @('slot 2 is past the 6 h lease wall clock')
            Get-AapDetail | Should -BeExactly 'resize_waits: slot 5 must leave first; limits refused; slot 2 is past the 6 h lease wall clock'
        }

        It 'still reads schema 1 and 2 as Windows 0, even shares and reserve 10' {
            Write-AapSettingsFile '{"schema":2,"runner_count":4,"job_cpus":8,"job_memory_gib":32,"paused":false,"windows_runner_count":1}'
            $s = Read-AapSettingsFile
            $s.Schema | Should -Be 2
            $s.Profiles.Linux | Should -Be 4
            $s.Profiles.Windows | Should -Be 0
            $s.Profiles.ShareMode | Should -BeExactly 'even'
            Write-AapSettingsFile '{"runner_count":4,"job_cpus":8,"job_memory_gib":32,"paused":false}'
            (Read-AapSettingsFile).Schema | Should -Be 1
        }
    }

    Describe 'capacity: the allocator drives the pool' {
        BeforeAll {
            Import-Module (Join-Path $PSScriptRoot 'capacity\AapCapacity.psm1') -Force

            # A legacy manager and its distro: limits.conf, drain, the unit, status.json.
            function Reset-AapFakeDistro([int]$Count = 3, [int]$Cpus = 28, [int]$Mem = 72, [string[]]$Slots = @('idle', 'idle', 'idle')) {
                $script:mgr = @{
                    Active = $true; Drained = $false; Count = $Count; Cpus = $Cpus; Mem = $Mem; Slots = $Slots
                    Conf = "AAP_RUNNER_COUNT=$Count`nAAP_JOB_CPUS=$Cpus`nAAP_JOB_MEMORY=${Mem}g`n"; Stops = 0; Starts = 0
                }
                $script:responder = {
                    param($line)
                    $m = $script:mgr
                    switch -Wildcard ($line) {
                        '*is-active sysbox aap-runner-manager' { return (Get-AapFakeResult 0 ("active`n" + $(if ($m.Active) { 'active' } else { 'inactive' }))) }
                        '*is-active aap-runner-manager' {
                            # A drained manager exits once its jobs end; the fake's jobs end at once unless held.
                            if ($m.Drained -and -not $script:holdJobs) { if ($m.Active) { $m.Stops++ }; $m.Active = $false }
                            if ($m.Active) { return (Get-AapFakeResult 0 'active') }
                            return (Get-AapFakeResult 3 'inactive')
                        }
                        '*aap-runner-manager --drain' { $m.Drained = $true; return (Get-AapFakeResult 0 '') }
                        '*aap-runner-manager --undrain' { $m.Drained = $false; return (Get-AapFakeResult 0 '') }
                        '*systemctl start*aap-runner-manager' {
                            if (-not $m.Active) { $m.Starts++ }
                            $m.Active = $true
                            if ($m.Conf -match 'AAP_RUNNER_COUNT=(\d+)\nAAP_JOB_CPUS=(\d+)\nAAP_JOB_MEMORY=(\d+)g') { $m.Count = [int]$Matches[1]; $m.Cpus = [int]$Matches[2]; $m.Mem = [int]$Matches[3] }
                            return (Get-AapFakeResult 0 '')
                        }
                        '*cat /etc/aap-runner/limits.conf' { return (Get-AapFakeResult 0 $m.Conf) }
                        '*/bin/sh -c *' { $m.Conf = $script:stdin[-1]; return (Get-AapFakeResult 0 '') }
                        '*cat /run/aap-runner/status.json' {
                            $states = @(for ($i = 0; $i -lt $m.Count; $i++) { if ($i -lt $m.Slots.Count) { $m.Slots[$i] } else { 'idle' } })
                            $slots = @(for ($i = 0; $i -lt $m.Count; $i++) { [ordered]@{ slot = $i + 1; state = $states[$i]; job = $(if ($states[$i] -eq 'running') { "job-$($i + 1)" } else { '' }) } })
                            $state = $(if ($states -contains 'running') { 'running' } else { 'idle' })
                            # The allocator reads sample times against the real clock.
                            $at = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                            if ($script:sampleAt) { $at = $script:sampleAt }
                            $doc = [ordered]@{ schema = 4; state = $state; job = ''; runner_count = $m.Count; job_cpus = $m.Cpus; job_memory = "$($m.Mem)g"; sampled_at = $at; slots = $slots }
                            return (Get-AapFakeResult 0 (ConvertTo-Json $doc -Compress -Depth 4))
                        }
                        default { return (Get-AapFakeResult 0 '') }
                    }
                }
            }

            # One cycle a minute later, so every cycle runs health.
            function Invoke-AapMinute([int]$Times = 1) {
                for ($i = 0; $i -lt $Times; $i++) {
                    $script:clock.Now = $script:clock.Now.AddSeconds(60)
                    Invoke-AapCycle
                }
            }

            function Get-AapCapDoc { return (Get-AapAllocatorState -Root $AapRt.CapRoot -RelaxedTrustForTests -WarningAction SilentlyContinue).State }
            function Get-AapCapLive { return @((Get-AapCapDoc).reservations | Where-Object { $_.state -cne 'reconciled' }) }

            # A VM backend fake, by the names the supervisor calls (Kind 'Fake'): creating
            # becomes ready with a VM id, draining runs on through teardown.
            function Invoke-AapFakeStep {
                param($Backend, $Reservation, $BaseSha256)
                $r = $Reservation
                $script:steps.Add("$($r.reservation_id) $($r.state) $BaseSha256")
                if ($script:stepThrows -contains $r.reservation_id) { throw 'AAP_FakeBroken: the fake provider failed' }
                $cap = @{ Root = $AapRt.CapRoot; ReservationId = $r.reservation_id; LeaseGeneration = [long]$r.lease_generation; RelaxedTrustForTests = $true; WarningAction = 'SilentlyContinue' }
                if ($r.state -ceq 'creating') { [void](Set-AapSlotState @cap -State ready -VmId ([guid]::NewGuid().ToString())); return @{ Action = 'ready'; Code = '' } }
                if ($r.state -ceq 'draining' -and -not $script:holdVms) {
                    [void](Set-AapSlotState @cap -State collecting)
                    [void](Set-AapSlotState @cap -State deleting)
                    $proof = @{ kind = 'vm'; observed_at = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"); vm_absent = $true; disks_absent = $true; vm_files_absent = $true; runner_deregistered = $true }
                    [void](Complete-AapTeardown @cap -Proof $proof)
                    return @{ Action = 'destroyed'; Code = '' }
                }
                return @{ Action = 'waiting'; Code = '' }
            }
            function Get-AapFakeInventory {
                param($Backend)
                $live = @(Get-AapCapLive | Where-Object { $_.backend -ceq 'hyperv-vm' })
                $vms = @($live | Where-Object { $_.vm_id } | ForEach-Object { @{ name = (Get-AapVmName -Profile $_.profile -Slot $_.slot -LeaseGeneration $_.lease_generation -ReservationId $_.reservation_id); vm_id = $_.vm_id; cpus = [int]$_.cpus; mem_gib = [int]$_.mem_gib } })
                $ids = @($live | ForEach-Object { [string]$_.reservation_id })
                return @{ vms = [object[]]$vms; folders = [object[]]$ids; journaled = [object[]]$ids }
            }
            function Get-AapFakeBrokerStatus { param($Backend, $Reservation) return @{ status = 'online'; busy = $true; job_ended = $false } }
            function Get-AapFakeStorageProblem { param($Backend) return @($script:storageProblems) }
            function Get-AapFakeHostProblem { param($Backend) return @($script:hostProblems) }

            # The short (8.3) names CI's TEMP has would not pass the root pattern.
            function Get-AapLongPath([string]$Path) {
                $parts = $Path.TrimEnd('\').Split('\')
                $long = $parts[0] + '\'
                foreach ($p in $parts[1..($parts.Count - 1)]) { $long = Join-Path $long (New-Object IO.DirectoryInfo $long).GetDirectories($p)[0].Name }
                return $long
            }

            function Enable-AapFakeVm([string[]]$Profiles = @('windows')) {
                $base = Get-AapLongPath $TestDrive
                $roots = @{}
                foreach ($t in 'base', 'clone', 'scratch') {
                    $roots[$t] = Join-Path $base "vm-$t-$([guid]::NewGuid().ToString('n').Substring(0, 6))"
                    [void](New-Item -ItemType Directory -Path $roots[$t])
                }
                $guid = '00000000-0000-4000-8000-000000000001'
                $b = @{ Storage = @{ FloorGib = 30; base_root = @{ Path = $roots.base; Guid = $guid }; clone_root = @{ Path = $roots.clone; Guid = $guid }; scratch_root = @{ Path = $roots.scratch; Guid = $guid } } }
                foreach ($p in $Profiles) {
                    $AapRt.Vm[$p] = @{ Kind = 'Fake'; B = $b }
                    $AapRt.Generation[$p] = @{ Id = $script:gen[$p]; State = 'active'; BaseSha256 = ('ab' * 32); MemOverheadMib = 512; CloneGib = 40; ScratchGib = $(if ($p -eq 'windows') { 20 } else { 0 }); IoMbps = 50 }
                }
                $script:hostIo = 400
            }
        }

        BeforeEach {
            $AapRt.Cap = $true
            $AapRt.CapRoot = Join-Path $AapCfg.DataDir 'capacity'
            $AapRt.CapArgs = @{ RelaxedTrustForTests = $true; WarningAction = 'SilentlyContinue' }
            $AapRt.VmWhy = @{ linux = 'the host network module (P10.0) is not installed'; windows = 'the host network module (P10.0) is not installed' }
            $script:gen = @{ windows = 'win25-vs2026-x64/20261007.264.1-aap.1'; linux = 'ubuntu-24.04-x64/20261012.334.1-aap.1' }
            $script:steps = New-Object System.Collections.Generic.List[string]
            $script:stepThrows = @()
            $script:storageProblems = @()
            $script:hostProblems = @()
            $script:holdJobs = $false
            $script:holdVms = $false
            $script:sampleAt = $null
            Mock Get-AapFreeGib { return [long]500 }
            Reset-AapFakeDistro
            Write-AapStateFile '{"desired":"on"}'
        }

        It 'adopts the running legacy pool and reports each slot with its job' -Tag 'v5' {
            Reset-AapFakeDistro 3 27 72 @('running', 'idle', 'idle')
            Write-AapSettingsFile '{"schema":2,"runner_count":3,"job_cpus":27,"job_memory_gib":72,"paused":false}'
            Invoke-AapCycle
            Invoke-AapMinute
            $doc = Get-AapCapDoc
            $doc.legacy_adopted | Should -BeTrue
            @(Get-AapCapLive | Where-Object { $_.backend -ceq 'wsl-legacy' }).Count | Should -Be 3
            $script:mgr.Starts | Should -Be 0 -Because 'adopting the pool as it runs restarts nothing'
            $v = Get-AapV5File
            @($v.settings_schemas) -join ',' | Should -Be '1,2,3'
            $v.capacity.used_slots | Should -Be 3
            $v.profiles[0].generation_state | Should -BeExactly 'active'
            $v.profiles[1].unavailable_reason | Should -Match 'P10.0'
            @($v.slots | Where-Object { $_.job -eq 'job-1' }).Count | Should -Be 1
            Test-AapV5Contract | Should -Be 'ok'
        }

        It 'caps the legacy pool to the Linux share and keeps the reserve (owner example)' -Tag 'adopt-target', 'settings-max' {
            Write-AapSettingsFile (Get-AapFixture 'settings-v3\valid\owner-example-per-profile.json')
            Invoke-AapCycle
            # 32 CPUs and 96 GiB: Linux 60 % = 19 CPUs and 57 GiB, 6 CPUs and 19 GiB each.
            $script:stdin | Should -Contain "AAP_RUNNER_COUNT=3`nAAP_JOB_CPUS=18`nAAP_JOB_MEMORY=57g`nAAP_JOB_IO_PERCENT=90`nAAP_POOL_SHARING=slice`n"
            Invoke-AapMinute 2
            (Get-AapCapDoc).legacy_adopted | Should -BeTrue
            $v = Get-AapV5File
            $v.capacity.share_mode | Should -BeExactly 'per_profile'
            $v.profiles[0].share_percent | Should -Be 60
            $v.profiles[0].profile_cap.cpus | Should -Be 19
            $v.profiles[0].per_runner.mem_gib | Should -Be 19
            $v.profiles[1].share_percent | Should -Be 30
            $v.profiles[1].profile_cap.mem_gib | Should -Be 28
            $v.profiles[1].count | Should -Be 2
            $v.profiles[1].available | Should -BeFalse
            ($v.profiles[0].profile_cap.cpus + $v.profiles[1].profile_cap.cpus) | Should -BeLessOrEqual ([Math]::Floor(32 * 0.9))
            Test-AapV5Contract | Should -Be 'ok'
        }

        It 'never writes limits.conf above the settings' -Tag 'settings-max' {
            Reset-AapFakeDistro 3 27 72
            Write-AapSettingsFile '{"schema":2,"runner_count":3,"job_cpus":27,"job_memory_gib":72,"paused":false}'
            Invoke-AapCycle
            Invoke-AapMinute
            (Get-AapCapDoc).legacy_adopted | Should -BeTrue
            Write-AapSettingsFile '{"schema":2,"runner_count":3,"job_cpus":12,"job_memory_gib":36,"paused":false}'
            Invoke-AapMinute
            $script:stdin[-1] | Should -BeExactly "AAP_RUNNER_COUNT=3`nAAP_JOB_CPUS=12`nAAP_JOB_MEMORY=36g`n"
        }

        It 'grants a legacy slot before the manager runs it' -Tag 'legacy-stop' {
            Reset-AapFakeDistro 3 27 72
            Write-AapSettingsFile '{"schema":2,"runner_count":3,"job_cpus":27,"job_memory_gib":72,"paused":false}'
            Invoke-AapCycle
            Invoke-AapMinute
            Write-AapSettingsFile '{"schema":2,"runner_count":4,"job_cpus":28,"job_memory_gib":72,"paused":false}'
            Invoke-AapMinute 2
            @(Get-AapCapLive | Where-Object { $_.backend -ceq 'wsl-legacy' -and (Test-AapGranted $_) }).Count | Should -Be 4
            $script:mgr.Count | Should -Be 4
            $script:stdin -join '|' | Should -Not -Match 'AAP_RUNNER_COUNT=0'
        }

        It 'waits for a fresh manager sample before adopting' -Tag 'adopt-target' {
            # A sample from 2025: adoption is refused as stale and limits.conf stays as it is.
            $script:sampleAt = 1760436000
            Write-AapSettingsFile '{"schema":2,"runner_count":2,"job_cpus":28,"job_memory_gib":72,"paused":false}'
            Invoke-AapCycle
            Invoke-AapMinute 2
            (Get-AapCapDoc).legacy_adopted | Should -BeFalse
            @($script:stdin).Count | Should -Be 0
            $script:mgr.Count | Should -Be 3
        }

        It 'drains and stops a running legacy pool when Linux goes to 0' -Tag 'legacy-stop' {
            Reset-AapFakeDistro 3 27 72
            Write-AapSettingsFile '{"schema":2,"runner_count":3,"job_cpus":27,"job_memory_gib":72,"paused":false}'
            Invoke-AapCycle
            Invoke-AapMinute
            $AapRt.ManagerStopped | Should -BeFalse
            Write-AapSettingsFile (Get-AapFixture 'settings-v3\valid\windows-only-even.json')
            Invoke-AapMinute 2
            $AapRt.ManagerStopped | Should -BeTrue
            $script:mgr.Active | Should -BeFalse
            @(Get-AapCapLive | Where-Object { $_.backend -ceq 'wsl-legacy' }).Count | Should -Be 0 -Because 'the stopped manager releases its slots'
            (Get-AapStatusFile).detail | Should -Match 'legacy pool stopped'
        }

        It 'stops the manager for Linux 0, keeps the distro up and adopts the stopped pool' -Tag 'legacy-stop', 'stop-inactive' {
            Write-AapSettingsFile (Get-AapFixture 'settings-v3\valid\windows-only-even.json')
            Invoke-AapCycle
            $script:calls | Should -Not -Contain 'wsl -d aap-runner -u root -- /usr/local/sbin/aap-runner-manager --undrain'
            $script:calls | Should -Contain 'wsl -d aap-runner -u root -- /usr/local/sbin/aap-runner-manager --drain'
            $AapRt.ManagerStopped | Should -BeTrue
            Invoke-AapMinute 2
            $script:mgr.Active | Should -BeFalse
            $script:calls | Should -Not -Contain 'wsl --terminate aap-runner'
            $script:calls | Should -Contain 'wsl -d aap-runner --exec /bin/sleep infinity'
            $script:stdin -join '|' | Should -Not -Match 'AAP_RUNNER_COUNT=0'
            (Get-AapCapDoc).legacy_adopted | Should -BeTrue
            $s = Get-AapStatusFile
            $s.state | Should -BeExactly 'idle'
            $s.detail | Should -Match 'legacy pool stopped'
            $v = Get-AapV5File
            $v.profiles[0].count | Should -Be 0
            $v.profiles[0].image_generation | Should -BeNullOrEmpty
            Test-AapV5Contract | Should -Be 'ok'
        }

        It 'does not stop the manager while its job still runs' -Tag 'stop-inactive' {
            Reset-AapFakeDistro 3 27 72
            Write-AapSettingsFile '{"schema":2,"runner_count":3,"job_cpus":27,"job_memory_gib":72,"paused":false}'
            Invoke-AapCycle
            Invoke-AapMinute
            $AapCfg.DrainTimeoutSeconds = 30
            $script:holdJobs = $true
            Write-AapSettingsFile (Get-AapFixture 'settings-v3\valid\windows-only-even.json')
            Invoke-AapMinute
            $AapRt.ManagerStopped | Should -BeFalse
            $script:mgr.Active | Should -BeTrue
            Get-AapLogText | Should -Match 'drain timeout'
        }

        It 'starts the manager again once Linux slots are granted' {
            Write-AapSettingsFile (Get-AapFixture 'settings-v3\valid\windows-only-even.json')
            Invoke-AapCycle
            Invoke-AapMinute
            $AapRt.ManagerStopped | Should -BeTrue
            $o = Get-AapFixture 'settings-v3\valid\windows-only-even.json' | ConvertFrom-Json
            $o.runner_count = 2
            $o.windows_runner_count = 0
            Write-AapSettingsFile (ConvertTo-Json $o -Compress)
            Invoke-AapMinute 2
            $AapRt.ManagerStopped | Should -BeFalse
            $script:mgr.Active | Should -BeTrue
            $script:mgr.Count | Should -Be 2
        }

        It 'shows an allocator error, admits nothing and leaves the legacy pool running' {
            Write-AapSettingsFile '{"schema":2,"runner_count":3,"job_cpus":28,"job_memory_gib":72,"paused":false}'
            Invoke-AapCycle
            Invoke-AapMinute
            [IO.File]::WriteAllText((Join-Path $AapRt.CapRoot 'allocator.json'), '{"schema":2,"revision":')
            $script:calls.Clear()
            Invoke-AapMinute
            $s = Get-AapStatusFile
            $s.state | Should -BeExactly 'error'
            $s.detail | Should -Match 'allocator invalid_state'
            $script:calls | Should -Not -Contain 'wsl -d aap-runner -u root -- /usr/local/sbin/aap-runner-manager --drain'
            (Get-AapV5File).state | Should -BeExactly 'error'
            Test-AapV5Contract | Should -Be 'ok'
        }

        It 'refuses to initialize over a lost allocator state' {
            [void](New-Item -ItemType Directory -Force -Path $AapRt.CapRoot)
            $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            $out = & icacls.exe $AapRt.CapRoot /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' "*${me}:(OI)(CI)F" 2>&1
            if ($LASTEXITCODE -ne 0) { throw "icacls failed: $out" }
            [IO.File]::WriteAllText((Join-Path $AapRt.CapRoot 'allocator.log'), 'old')
            Write-AapSettingsFile '{"schema":2,"runner_count":3,"job_cpus":28,"job_memory_gib":72,"paused":false}'
            Invoke-AapCycle
            Invoke-AapMinute
            (Get-AapStatusFile).detail | Should -Match 'invalid_state'
            Test-Path -LiteralPath (Join-Path $AapRt.CapRoot 'allocator.json') | Should -BeFalse
        }

        Context 'VM profiles through the backend calls' {
            It 'admits Windows slots on the generation budget and steps each with its pinned hash' -Tag 'vm-admit', 'admit-after-adoption' {
                Enable-AapFakeVm
                Write-AapSettingsFile '{"schema":3,"linux_backend":"wsl-legacy","runner_count":1,"windows_runner_count":2,"job_cpus":28,"job_memory_gib":72,"paused":false,"io_percent":90,"sharing":"slice","host_reserve_percent":10,"share_mode":"per_profile","linux_share_percent":30,"windows_share_percent":60,"lease_wall_clock_hours":6}'
                Reset-AapFakeDistro 1 9 28 @('idle')
                Invoke-AapCycle
                @(Get-AapCapLive | Where-Object { $_.backend -ceq 'hyperv-vm' }).Count | Should -Be 0 -Because 'no VM before the legacy pool is adopted'
                Invoke-AapMinute 3
                $vms = @(Get-AapCapLive | Where-Object { $_.backend -ceq 'hyperv-vm' })
                $vms.Count | Should -Be 2
                $vms[0].clone_gib | Should -Be 40
                $vms[0].scratch_gib | Should -Be 20
                $vms[0].mem_overhead_mib | Should -Be 512
                $vms[0].image_generation | Should -BeExactly $script:gen.windows
                @($script:steps | Where-Object { $_ -like "* $('ab' * 32)" }).Count | Should -BeGreaterThan 1
                $v = Get-AapV5File
                $v.profiles[1].available | Should -BeTrue
                $v.profiles[1].generation_state | Should -BeExactly 'active'
                @($v.slots | Where-Object { $_.os -eq 'Windows' -and $_.backend -eq 'hyperv-vm' }).Count | Should -Be 2
                @($v.slots | Where-Object { $_.os -eq 'Linux' -and $_.backend -eq 'wsl-legacy' }).Count | Should -Be 1
                $v.storage.state | Should -BeExactly 'ok'
                Test-AapV5Contract | Should -Be 'ok'
            }

            It 'admits nothing while storage is untrusted and says why' -Tag 'vm-storage', 'vm-admit' {
                Enable-AapFakeVm
                $script:storageProblems = @('clone_root: owner S-1-5-21-1 is not an admin: X:\c')
                Write-AapSettingsFile '{"schema":3,"linux_backend":"wsl-legacy","runner_count":1,"windows_runner_count":2,"job_cpus":28,"job_memory_gib":72,"paused":false,"io_percent":90,"sharing":"slice","host_reserve_percent":10,"share_mode":"even","linux_share_percent":null,"windows_share_percent":null,"lease_wall_clock_hours":6}'
                Reset-AapFakeDistro 1 9 28 @('idle')
                Invoke-AapCycle
                Invoke-AapMinute 3
                @(Get-AapCapLive | Where-Object { $_.backend -ceq 'hyperv-vm' }).Count | Should -Be 0
                $v = Get-AapV5File
                $v.storage.state | Should -BeExactly 'untrusted'
                $v.storage.detail | Should -BeExactly 'clone: owner'
                $v.profiles[1].available | Should -BeFalse
                $v.profiles[1].unavailable_reason | Should -BeExactly 'storage is untrusted'
                Test-AapV5Contract | Should -Be 'ok'
            }

            It 'admits nothing on a host problem or without an active generation' -Tag 'vm-host', 'vm-generation', 'vm-admit' {
                Enable-AapFakeVm
                $script:hostProblems = @('AAP_EnhancedSession: Enhanced Session Mode is not off on this Hyper-V host')
                Write-AapSettingsFile '{"schema":3,"linux_backend":"wsl-legacy","runner_count":1,"windows_runner_count":2,"job_cpus":28,"job_memory_gib":72,"paused":false,"io_percent":90,"sharing":"slice","host_reserve_percent":10,"share_mode":"even","linux_share_percent":null,"windows_share_percent":null,"lease_wall_clock_hours":6}'
                Reset-AapFakeDistro 1 9 28 @('idle')
                Invoke-AapCycle
                Invoke-AapMinute 2
                @(Get-AapCapLive | Where-Object { $_.backend -ceq 'hyperv-vm' }).Count | Should -Be 0
                (Get-AapV5File).profiles[1].unavailable_reason | Should -Match '^AAP_EnhancedSession'
                $script:hostProblems = @()
                $AapRt.ChecksAt = [DateTimeOffset]::MinValue
                $AapRt.Generation.windows = $null
                Invoke-AapMinute 2
                @(Get-AapCapLive | Where-Object { $_.backend -ceq 'hyperv-vm' }).Count | Should -Be 0
                (Get-AapV5File).profiles[1].unavailable_reason | Should -BeExactly 'no approved active generation'
                Test-AapV5Contract | Should -Be 'ok'
            }

            It 'pause drains ready and busy VM slots and never ends a running job' -Tag 'vm-drain' {
                Enable-AapFakeVm
                $script:holdVms = $true
                Write-AapSettingsFile '{"schema":3,"linux_backend":"wsl-legacy","runner_count":1,"windows_runner_count":2,"job_cpus":28,"job_memory_gib":72,"paused":false,"io_percent":90,"sharing":"slice","host_reserve_percent":10,"share_mode":"even","linux_share_percent":null,"windows_share_percent":null,"lease_wall_clock_hours":6}'
                Reset-AapFakeDistro 1 9 28 @('idle')
                Invoke-AapCycle
                Invoke-AapMinute 4
                $vms = @(Get-AapCapLive | Where-Object { $_.backend -ceq 'hyperv-vm' })
                $vms.Count | Should -Be 2
                [void](Set-AapSlotState -Root $AapRt.CapRoot -ReservationId $vms[0].reservation_id -LeaseGeneration $vms[0].lease_generation -State busy -RelaxedTrustForTests -WarningAction SilentlyContinue)
                Write-AapSettingsFile '{"schema":3,"linux_backend":"wsl-legacy","runner_count":1,"windows_runner_count":2,"job_cpus":28,"job_memory_gib":72,"paused":true,"io_percent":90,"sharing":"slice","host_reserve_percent":10,"share_mode":"even","linux_share_percent":null,"windows_share_percent":null,"lease_wall_clock_hours":6}'
                Invoke-AapMinute 2
                $after = @(Get-AapCapLive | Where-Object { $_.backend -ceq 'hyperv-vm' })
                @($after | ForEach-Object { $_.state }) -join ',' | Should -Be 'draining,draining'
                @($after | Where-Object { $_.reservation_id -ceq $vms[0].reservation_id }).Count | Should -Be 1 -Because 'the busy one keeps its job'
                (Get-AapStatusFile).state | Should -BeExactly 'paused'
                @(Get-AapCapLive | Where-Object { $_.backend -ceq 'hyperv-vm' -and $_.state -ceq 'creating' }).Count | Should -Be 0 -Because 'nothing is admitted while paused'
                Test-AapV5Contract | Should -Be 'ok'
            }

            It 'resizing Windows down drains the idle slot first and keeps the busy one' {
                Enable-AapFakeVm
                $script:holdVms = $true
                $set = '{"schema":3,"linux_backend":"wsl-legacy","runner_count":1,"windows_runner_count":2,"job_cpus":28,"job_memory_gib":72,"paused":false,"io_percent":90,"sharing":"slice","host_reserve_percent":10,"share_mode":"per_profile","linux_share_percent":30,"windows_share_percent":60,"lease_wall_clock_hours":6}'
                Write-AapSettingsFile $set
                Reset-AapFakeDistro 1 9 28 @('idle')
                Invoke-AapCycle
                Invoke-AapMinute 4
                $vms = @(Get-AapCapLive | Where-Object { $_.backend -ceq 'hyperv-vm' })
                [void](Set-AapSlotState -Root $AapRt.CapRoot -ReservationId $vms[0].reservation_id -LeaseGeneration $vms[0].lease_generation -State busy -RelaxedTrustForTests -WarningAction SilentlyContinue)
                Write-AapSettingsFile ($set -replace '"windows_runner_count":2', '"windows_runner_count":1')
                Invoke-AapMinute
                $busy = @(Get-AapCapLive | Where-Object { $_.reservation_id -ceq $vms[0].reservation_id })[0]
                $busy.state | Should -BeExactly 'busy'
                @(Get-AapCapLive | Where-Object { $_.reservation_id -ceq $vms[1].reservation_id })[0].state | Should -BeExactly 'draining'
            }

            It 'Off waits for the VM slots before the distro stops' {
                Enable-AapFakeVm
                Write-AapSettingsFile '{"schema":3,"linux_backend":"wsl-legacy","runner_count":1,"windows_runner_count":2,"job_cpus":28,"job_memory_gib":72,"paused":false,"io_percent":90,"sharing":"slice","host_reserve_percent":10,"share_mode":"even","linux_share_percent":null,"windows_share_percent":null,"lease_wall_clock_hours":6}'
                Reset-AapFakeDistro 1 9 28 @('idle')
                Invoke-AapCycle
                Invoke-AapMinute 4
                @(Get-AapCapLive | Where-Object { $_.backend -ceq 'hyperv-vm' }).Count | Should -Be 2
                $script:holdVms = $true
                $script:released = $false
                Mock Wait-AapInterval {
                    $script:calls.Add("sleep $Seconds")
                    $script:clock.Now = $script:clock.Now.AddSeconds($Seconds)
                    # The VM jobs end after the first wait.
                    $script:holdVms = $false
                }
                Write-AapStateFile '{"desired":"off"}'
                Invoke-AapCycle
                $i = [array]::IndexOf(@($script:calls), 'wsl --terminate aap-runner')
                $i | Should -BeGreaterThan 0
                @($script:calls)[0..$i] | Should -Contain 'sleep 10'
                @(Get-AapCapLive | Where-Object { $_.backend -ceq 'hyperv-vm' }).Count | Should -Be 0
                $AapRt.Mode | Should -BeExactly 'off'
            }

            It 'Off turned back on while VM slots drain keeps the distro' {
                Enable-AapFakeVm
                Write-AapSettingsFile '{"schema":3,"linux_backend":"wsl-legacy","runner_count":1,"windows_runner_count":2,"job_cpus":28,"job_memory_gib":72,"paused":false,"io_percent":90,"sharing":"slice","host_reserve_percent":10,"share_mode":"even","linux_share_percent":null,"windows_share_percent":null,"lease_wall_clock_hours":6}'
                Reset-AapFakeDistro 1 9 28 @('idle')
                Invoke-AapCycle
                Invoke-AapMinute 4
                $script:holdVms = $true
                Mock Wait-AapInterval {
                    $script:calls.Add("sleep $Seconds")
                    $script:clock.Now = $script:clock.Now.AddSeconds($Seconds)
                    Write-AapStateFile '{"desired":"on"}'
                }
                Write-AapStateFile '{"desired":"off"}'
                Invoke-AapCycle
                $script:calls | Should -Not -Contain 'wsl --terminate aap-runner'
                $AapRt.Mode | Should -BeExactly 'on'
                Get-AapLogText | Should -Match 'desired is on again while VM slots drain'
            }

            It 'reports what generation the VM slots run' -Tag 'v5' {
                Enable-AapFakeVm
                $script:holdVms = $true
                Write-AapSettingsFile '{"schema":3,"linux_backend":"wsl-legacy","runner_count":1,"windows_runner_count":1,"job_cpus":28,"job_memory_gib":72,"paused":false,"io_percent":90,"sharing":"slice","host_reserve_percent":10,"share_mode":"even","linux_share_percent":null,"windows_share_percent":null,"lease_wall_clock_hours":6}'
                Reset-AapFakeDistro 1 9 28 @('idle')
                Invoke-AapCycle
                Invoke-AapMinute 3
                (Get-AapV5File).profiles[1].generation_state | Should -BeExactly 'active'
                # A newer generation is promoted while the slot still runs the old one.
                $AapRt.Generation.windows = @{ Id = 'win25-vs2026-x64/20261007.264.1-aap.2'; State = 'active'; BaseSha256 = ('cd' * 32); MemOverheadMib = 512; CloneGib = 40; ScratchGib = 20; IoMbps = 50 }
                Invoke-AapMinute
                $v = Get-AapV5File
                $v.profiles[1].image_generation | Should -BeExactly 'win25-vs2026-x64/20261007.264.1-aap.2'
                $v.profiles[1].generation_state | Should -BeExactly 'draining_old'
                @($v.slots | Where-Object { $_.os -eq 'Windows' })[0].image_generation | Should -BeExactly $script:gen.windows
                Test-AapV5Contract | Should -Be 'ok'
                $AapRt.Generation.windows.State = 'stale'
                Invoke-AapMinute
                (Get-AapV5File).profiles[1].generation_state | Should -BeExactly 'stale'
                $AapRt.Generation.windows.State = 'quarantined'
                Invoke-AapMinute
                $v = Get-AapV5File
                $v.profiles[1].generation_state | Should -BeExactly 'quarantined'
                $v.profiles[1].available | Should -BeFalse
                (Get-AapCapDoc).profiles.windows.active_generation | Should -BeNullOrEmpty
                Test-AapV5Contract | Should -Be 'ok'
            }

            It 'runs Linux on VMs with the legacy manager stopped' {
                Enable-AapFakeVm @('linux')
                Write-AapSettingsFile '{"schema":3,"linux_backend":"hyperv-vm","runner_count":2,"windows_runner_count":0,"job_cpus":28,"job_memory_gib":72,"paused":false,"io_percent":90,"sharing":"slice","host_reserve_percent":10,"share_mode":"even","linux_share_percent":null,"windows_share_percent":null,"lease_wall_clock_hours":6}'
                Invoke-AapCycle
                Invoke-AapMinute 3
                $AapRt.ManagerStopped | Should -BeTrue
                $vms = @(Get-AapCapLive | Where-Object { $_.backend -ceq 'hyperv-vm' })
                $vms.Count | Should -Be 2
                $vms[0].profile | Should -BeExactly 'linux'
                $vms[0].scratch_gib | Should -Be 0
                $v = Get-AapV5File
                $v.profiles[0].backend | Should -BeExactly 'hyperv-vm'
                $v.legacy_pool | Should -BeNullOrEmpty
                Test-AapV5Contract | Should -Be 'ok'
            }

            It 'logs a failing step and steps the others' {
                Enable-AapFakeVm
                $script:holdVms = $true
                Write-AapSettingsFile '{"schema":3,"linux_backend":"wsl-legacy","runner_count":1,"windows_runner_count":2,"job_cpus":28,"job_memory_gib":72,"paused":false,"io_percent":90,"sharing":"slice","host_reserve_percent":10,"share_mode":"even","linux_share_percent":null,"windows_share_percent":null,"lease_wall_clock_hours":6}'
                Reset-AapFakeDistro 1 9 28 @('idle')
                Invoke-AapCycle
                Invoke-AapMinute 4
                $vms = @(Get-AapCapLive | Where-Object { $_.backend -ceq 'hyperv-vm' })
                $script:stepThrows = @($vms[0].reservation_id)
                $script:steps.Clear()
                Invoke-AapMinute
                Get-AapLogText | Should -Match "$($vms[0].reservation_id): step failed: AAP_FakeBroken"
                @($script:steps | Where-Object { $_ -like "$($vms[1].reservation_id) *" }).Count | Should -BeGreaterThan 0
            }
        }
    }

    Describe 'code the supervisor imports' {
        BeforeEach {
            $script:dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
            [void](New-Item -ItemType Directory -Path $script:dir)
            [IO.File]::WriteAllText((Join-Path $script:dir 'AapCapacity.psm1'), '')
            # Owned by the test user, also when the test runs elevated (then new files belong to Administrators).
            $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            if ((Get-Acl -LiteralPath $script:dir).GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $me) {
                $out = & icacls.exe $script:dir /setowner "*$me" /T 2>&1
                if ($LASTEXITCODE -ne 0) { throw "icacls failed: $out" }
            }
        }

        It 'refuses a folder owned by someone else' -Tag 'code-owner' {
            @(Get-AapCodeProblem $script:dir) -join '; ' | Should -Match 'is not an admin'
        }

        It 'refuses a folder anyone else may write' -Tag 'code-write' {
            $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            $out = & icacls.exe $script:dir /grant "*${me}:(M)" 2>&1
            if ($LASTEXITCODE -ne 0) { throw "icacls failed: $out" }
            @(Get-AapCodeProblem $script:dir) -join '; ' | Should -Match "$me may write"
        }

        It 'refuses a junction' -Tag 'code-reparse' {
            $link = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
            $out = & cmd.exe /c mklink /J $link $script:dir 2>&1
            if ($LASTEXITCODE -ne 0) { throw "mklink failed: $out" }
            @(Get-AapCodeProblem $link) -join '; ' | Should -Match 'reparse point'
        }

        It 'trusts an admin-only folder' {
            @(Get-AapCodeProblem (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules\Microsoft.PowerShell.Utility')).Count | Should -Be 0
        }

        It 'stays the schema 2 supervisor when the capacity module is not admin-only' -Tag 'code-trusted' {
            $mod = Join-Path $script:dir 'capacity'
            [void](New-Item -ItemType Directory -Path $mod)
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'capacity\AapCapacity.psm1') -Destination $mod
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'capacity\allocator.schema.json') -Destination $mod
            $AapCfg.ModuleDir = $script:dir
            try { Initialize-AapProviders } finally { $AapCfg.ModuleDir = $PSScriptRoot }
            $AapRt.Cap | Should -BeFalse
            Get-AapLogText | Should -Match 'capacity module not loaded, it is not admin-only'
        }

        It 'stays the schema 2 supervisor without the capacity module' {
            $AapCfg.ModuleDir = $script:dir
            try { Initialize-AapProviders } finally { $AapCfg.ModuleDir = $PSScriptRoot }
            $AapRt.Cap | Should -BeFalse
            Get-AapLogText | Should -Match 'capacity module not installed'
        }
    }

    Describe 'trust split in the supervisor' {
        It 'never writes under inbox across a full On and Off cycle' {
            $inbox = Join-Path $AapCfg.DataDir 'inbox'
            Write-AapStateFile '{"desired":"on"}'
            Write-AapSettingsFile '{"runner_count":2,"job_cpus":8,"job_memory_gib":32,"paused":false}'
            $snap = { @(Get-ChildItem -LiteralPath $inbox -Force | ForEach-Object { '{0}|{1}|{2}' -f $_.Name, $_.Length, $_.LastWriteTimeUtc.Ticks }) -join ';' }
            $before = & $snap
            $script:writes = New-Object System.Collections.Generic.List[string]
            # Record every bound argument of the cmdlets that can write. The
            # inbox snapshot covers the [IO.File] writes.
            $rec = { $script:writes.Add(((@($Path) + @($LiteralPath) + @($Destination) | Where-Object { $_ }) -join '|')) }
            Mock Move-Item $rec
            Mock Add-Content $rec
            Mock New-Item $rec
            Mock Set-Content $rec
            Mock Remove-Item $rec
            $script:activeLeft = 0
            $script:responder = {
                param($line)
                if ($line -like '*is-active aap-runner-manager') { return (Get-AapFakeResult 3 'inactive') }
                return (& $script:healthy $line)
            }
            Invoke-AapCycle
            $AapRt.Mode | Should -Be 'on'
            $AapRt.Applied | Should -Be '2,8,32'
            $script:clock.Now = $script:clock.Now.AddMinutes(5)
            Invoke-AapCycle
            (& $snap) | Should -Be $before
            Write-AapStateFile '{"desired":"off"}'
            $before = & $snap
            Invoke-AapCycle
            $AapRt.Mode | Should -Be 'off'
            (& $snap) | Should -Be $before
            $script:writes.Count | Should -BeGreaterThan 0
            @($script:writes | Where-Object { $_ -and $_.StartsWith($inbox, [StringComparison]::OrdinalIgnoreCase) }).Count | Should -Be 0
            ($script:writes -join "`n") | Should -Match ([regex]::Escape((Join-Path $AapCfg.DataDir 'status.json')))
            ($script:writes -join "`n") | Should -Match ([regex]::Escape((Join-Path $AapCfg.DataDir 'logs\supervisor.log')))
        }

        It 'reads state and settings from inbox only' {
            [IO.File]::WriteAllText((Join-Path $AapCfg.DataDir 'state.json'), '{"desired":"on"}')
            Read-AapDesired | Should -Be 'off'
            Write-AapStateFile '{"desired":"on"}'
            Read-AapDesired | Should -Be 'on'
        }
    }

    Describe 'manager flag probe' {
        BeforeEach {
            $script:probe = 'wsl -d aap-runner -u root -- /bin/grep -q -- --undrain /usr/local/sbin/aap-runner-manager'
            $script:probeCode = 0
            $script:responder = {
                param($line)
                if ($line -like '*/bin/grep -q -- --undrain *') { return (Get-AapFakeResult $script:probeCode '') }
                if ($line -like '*is-active aap-runner-manager') { return (Get-AapFakeResult 3 'inactive') }
                return (& $script:healthy $line)
            }
            # Paused plus new limits: every settings path that would use a flag.
            Write-AapSettingsFile '{"runner_count":2,"job_cpus":8,"job_memory_gib":32,"paused":true}'
        }

        It 'makes zero manager-flag calls across On, settings, health and Off when the probe fails' {
            $script:probeCode = 1
            Write-AapStateFile '{"desired":"on"}'
            Invoke-AapCycle
            $AapRt.Mode | Should -Be 'on'
            $s = Get-AapStatusFile
            $s.state | Should -Be 'error'
            $s.detail | Should -Be 'manager on the distro predates this supervisor; re-run install-host.ps1 from this branch'
            $script:calls | Should -Contain 'wsl -d aap-runner -u root -- /bin/systemctl start sysbox aap-runner-manager'
            $script:clock.Now = $script:clock.Now.AddMinutes(2)
            Invoke-AapCycle
            Write-AapStateFile '{"desired":"off"}'
            Invoke-AapCycle
            $AapRt.Mode | Should -Be 'off'
            $script:calls[-1] | Should -Be 'wsl --terminate aap-runner'
            @($script:calls | Where-Object { $_ -like '*/usr/local/sbin/aap-runner-manager -*' }).Count | Should -Be 0
            @($script:calls | Where-Object { $_ -like '*limits.conf*' }).Count | Should -Be 0
            Get-AapLogText | Should -Match 'WARN no drain'
            (Get-AapStatusFile).state | Should -Be 'off'
        }

        It 'probes once and keeps the normal sequence when the probe passes' {
            Write-AapSettingsFile '{"runner_count":3,"job_cpus":28,"job_memory_gib":72,"paused":false}'
            Write-AapStateFile '{"desired":"on"}'
            Invoke-AapCycle
            foreach ($i in 1..5) {
                $script:clock.Now = $script:clock.Now.AddMinutes(2)
                Invoke-AapCycle
            }
            @($script:calls | Where-Object { $_ -eq $script:probe }).Count | Should -Be 1
            $script:calls | Should -Contain 'wsl -d aap-runner -u root -- /usr/local/sbin/aap-runner-manager --undrain'
            (Get-AapStatusFile).state | Should -Be 'idle'
        }

        It 'probes again at the next health tick after a failure' {
            $script:probeCode = 1
            Write-AapStateFile '{"desired":"on"}'
            Invoke-AapCycle
            $script:probeCode = 0
            $script:clock.Now = $AapRt.NextHealth
            Invoke-AapCycle
            @($script:calls | Where-Object { $_ -eq $script:probe }).Count | Should -Be 2
            $AapRt.ManagerOk | Should -BeTrue
        }

        It 'logs the journal when a unit is not active after start' {
            $script:responder = {
                param($line)
                if ($line -like '*is-active sysbox aap-runner-manager') { return (Get-AapFakeResult 3 "active`nfailed") }
                if ($line -like '*journalctl -u aap-runner-manager -n 5 --no-pager') { return (Get-AapFakeResult 0 "line one`nexit-code=1 FAILURE") }
                return (Get-AapFakeResult 0 '')
            }
            $ok = Invoke-AapUnitStart @('sysbox', 'aap-runner-manager')
            $ok | Should -BeFalse
            $script:calls | Should -Contain 'wsl -d aap-runner -u root -- /bin/journalctl -u aap-runner-manager -n 5 --no-pager'
            $script:calls | Should -Not -Contain 'wsl -d aap-runner -u root -- /bin/journalctl -u sysbox -n 5 --no-pager'
            Get-AapLogText | Should -Match 'aap-runner-manager is failed after start; journal: line one exit-code=1 FAILURE'
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
            ([regex]::Matches($src, "FileName = 'C:\\Windows\\System32\\wsl.exe'")).Count | Should -Be 1
            ([regex]::Matches($src, "FileName = ")).Count | Should -Be 1
            $src | Should -Not -Match '&\s*wsl(\.exe)?\s'
        }
    }

    Describe 'install-supervisor.ps1' {
        BeforeAll {
            . (Join-Path $PSScriptRoot 'install-supervisor.ps1')
            $script:template = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'aap-runner-supervisor-task.xml')
            $script:sid = 'S-1-5-21-111-222-333-1001'
            $script:ps1 = 'C:\wsl\aap-runner-supervisor\aap-runner-supervisor.ps1'
        }

        It 'replaces every placeholder for the logon task' {
            $xml = Get-AapSupervisorTaskXml -Template $script:template -UserSid $script:sid -Ps1 $script:ps1
            $xml | Should -Not -Match '__AAP_'
            $xml | Should -Match '<UserId>S-1-5-21-111-222-333-1001</UserId>'
            $xml | Should -Match ([regex]::Escape("&amp; 'C:\wsl\aap-runner-supervisor\aap-runner-supervisor.ps1'"))
            $xml | Should -Match ([regex]::Escape('<Command>C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe</Command>'))
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
            Mock Register-AapTask { throw 'must not be reached' }
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

    Describe 'installer trust checks' {
        BeforeAll {
            . (Join-Path $PSScriptRoot 'install-supervisor.ps1')
            $script:admins = New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'
            $script:op = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            $script:mkAcl = {
                param([string]$Owner, [object[]]$Rules)
                $a = New-Object System.Security.AccessControl.DirectorySecurity
                $a.SetOwner((New-Object Security.Principal.SecurityIdentifier $Owner))
                foreach ($r in @($Rules)) { if ($r) { $a.AddAccessRule($r) } }
                return $a
            }
            $script:junctions = New-Object System.Collections.Generic.List[string]
            $script:mkJunction = {
                param([string]$Link, [string]$Target)
                New-Item -ItemType Directory -Force -Path $Target | Out-Null
                & C:\Windows\System32\cmd.exe /d /c mklink /J "$Link" "$Target" | Out-Null
                $LASTEXITCODE | Should -Be 0
                $script:junctions.Add($Link)
            }
        }

        AfterEach {
            # rmdir removes a junction without touching its target.
            foreach ($j in $script:junctions) { & C:\Windows\System32\cmd.exe /d /c rmdir "$j" | Out-Null }
            $script:junctions.Clear()
        }

        It 'refuses a junction at the data folder' {
            $link = Join-Path $TestDrive 'pd-junction'
            & $script:mkJunction $link (Join-Path $TestDrive 'elsewhere')
            $r = Get-AapDataDirProblem $link
            @($r.Problems) -join "`n" | Should -Match ([regex]::Escape("reparse point $link"))
            @($r.Problems) -join "`n" | Should -Match 'cmd /c rmdir'
        }

        It 'refuses a junction at inbox\jobs without reading the target' {
            $pd = Join-Path $TestDrive 'pd-jobs-link'
            New-Item -ItemType Directory -Force -Path (Join-Path $pd 'inbox') | Out-Null
            $target = Join-Path $TestDrive 'jobs-target'
            New-Item -ItemType Directory -Force -Path $target | Out-Null
            Set-Content -LiteralPath (Join-Path $target 'secret.txt') -Value 'super-secret-key-material'
            $link = Join-Path $pd 'inbox\jobs'
            & $script:mkJunction $link $target
            $r = Get-AapDataDirProblem $pd
            @($r.Problems) -join "`n" | Should -Match 'reparse point .*jobs'
            @($r.Problems) -join "`n" | Should -Not -Match 'super-secret'
        }

        It 'accepts a user-owned request file inside inbox\jobs' {
            $pd = Join-Path $TestDrive 'pd-jobs-file'
            New-Item -ItemType Directory -Force -Path (Join-Path $pd 'inbox\jobs') | Out-Null
            Set-Content -LiteralPath (Join-Path $pd 'inbox\jobs\0123456789abcdef.json') -Value '{"schema":1}'
            Mock Get-Acl { & $script:mkAcl 'S-1-5-32-544' @() }
            Mock Get-Acl { & $script:mkAcl $script:op @() } -ParameterFilter { $LiteralPath -like '*\inbox\*' }
            $r = Get-AapDataDirProblem $pd
            @($r.Problems).Count | Should -Be 0
        }

        It 'refuses a junction inside the data folder without following it' {
            $pd = Join-Path $TestDrive 'pd-child'
            New-Item -ItemType Directory -Force -Path $pd | Out-Null
            $target = Join-Path $TestDrive 'elsewhere2'
            & $script:mkJunction (Join-Path $pd 'inbox') $target
            Set-Content -LiteralPath (Join-Path $target 'secret.txt') -Value 'x'
            $r = Get-AapDataDirProblem $pd
            @($r.Problems) -join "`n" | Should -Match 'reparse point .*inbox'
            @($r.Problems) -join "`n" | Should -Not -Match 'secret'
        }

        It 'install -DryRun exits 1 on a junction at the data folder' {
            $link = Join-Path $TestDrive 'pd-junction-dry'
            & $script:mkJunction $link (Join-Path $TestDrive 'elsewhere3')
            $exe = (Get-Process -Id $PID).Path
            $out = & $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'install-supervisor.ps1') -DryRun -DataDir $link -TaskName 'AAP-Test-NotRegistered' 2>&1 | Out-String
            $LASTEXITCODE | Should -Be 1
            $out | Should -Match 'FAIL reparse point'
            $out | Should -Not -Match 'WOULD acl'
        }

        It 'refuses a non-admin owner outside inbox' {
            $pd = Join-Path $TestDrive 'pd-owner'
            New-Item -ItemType Directory -Force -Path (Join-Path $pd 'logs') | Out-Null
            Mock Get-Acl { & $script:mkAcl $script:op @() }
            $r = Get-AapDataDirProblem $pd
            @($r.Problems) -join "`n" | Should -Match ([regex]::Escape("owner $($script:op) on $pd is not an admin"))
            @($r.Problems) -join "`n" | Should -Match 'logs is not an admin'
        }

        It 'accepts user-owned files inside inbox when everything else is admin-owned' {
            $pd = Join-Path $TestDrive 'pd-inbox'
            New-Item -ItemType Directory -Force -Path (Join-Path $pd 'inbox') | Out-Null
            Set-Content -LiteralPath (Join-Path $pd 'inbox\state.json') -Value '{"desired":"on"}'
            Mock Get-Acl { & $script:mkAcl 'S-1-5-32-544' @() }
            Mock Get-Acl { & $script:mkAcl $script:op @() } -ParameterFilter { $LiteralPath -like '*\inbox\*' }
            $r = Get-AapDataDirProblem $pd
            @($r.Problems).Count | Should -Be 0
        }

        It 'refuses an ancestor that lets <who> <rights>' -TestCases @(
            @{ who = 'Users'; sid = 'S-1-5-32-545'; rights = 'Modify' }
            @{ who = 'Everyone'; sid = 'S-1-1-0'; rights = 'ChangePermissions' }
            @{ who = 'Authenticated Users'; sid = 'S-1-5-11'; rights = 'DeleteSubdirectoriesAndFiles' }
            @{ who = 'the operator'; sid = 'OP'; rights = 'TakeOwnership' }
        ) {
            if ($sid -eq 'OP') { $sid = $script:op }
            $none = [Security.AccessControl.InheritanceFlags]::None
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier $sid), $rights, $none, 'None', 'Allow')
            Mock Get-Acl { & $script:mkAcl 'S-1-5-32-544' @() }
            Mock Get-Acl { & $script:mkAcl 'S-1-5-32-544' @($rule) } -ParameterFilter { $LiteralPath -eq 'C:\wsl' }
            $r = Get-AapAncestorProblem 'C:\wsl\aap-runner-supervisor'
            @($r.Problems).Count | Should -Be 1
            $r.Problems[0] | Should -Match ([regex]::Escape("C:\wsl grants $sid"))
        }

        It 'accepts the default drive-root entries (create folders, inherit-only Modify)' {
            $all = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
            $au = New-Object Security.Principal.SecurityIdentifier 'S-1-5-11'
            $create = New-Object System.Security.AccessControl.FileSystemAccessRule($au, 'AppendData', 'None', 'None', 'Allow')
            $sub = New-Object System.Security.AccessControl.FileSystemAccessRule($au, 'Modify', $all, 'InheritOnly', 'Allow')
            $users = New-Object System.Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-545'), 'ReadAndExecute', $all, 'None', 'Allow')
            Mock Get-Acl { & $script:mkAcl 'S-1-5-32-544' @($create, $sub, $users) }
            $r = Get-AapAncestorProblem 'C:\wsl\aap-runner-supervisor'
            @($r.Problems).Count | Should -Be 0
            Should -Invoke Get-Acl -Times 2 -Exactly
        }

        It 'refuses an ancestor owned by the operator' {
            Mock Get-Acl { & $script:mkAcl $script:op @() }
            $r = Get-AapAncestorProblem 'C:\wsl\aap-runner-supervisor'
            @($r.Problems) -join "`n" | Should -Match 'is not an admin'
        }

        It 'refuses an ancestor ACE that is not allow or deny' {
            $raw = New-Object System.Security.AccessControl.RawSecurityDescriptor 'O:BA D:(OA;;RPWP;c9651a32-5a0b-4e8c-9a55-6b9a0a0a0a0a;;BU)'
            $ds = New-Object System.Security.AccessControl.DirectorySecurity
            $bytes = New-Object byte[] $raw.BinaryLength
            $raw.GetBinaryForm($bytes, 0)
            $ds.SetSecurityDescriptorBinaryForm($bytes)
            Mock Get-Acl { $ds }
            $r = Get-AapAncestorProblem 'C:\wsl\aap-runner-supervisor'
            @($r.Problems) -join "`n" | Should -Match 'not a plain allow or deny'
        }

        It 'refuses a junction ancestor without reading its target' {
            $link = Join-Path $TestDrive 'anc-link'
            & $script:mkJunction $link (Join-Path $TestDrive 'anc-target')
            Mock Get-Acl { & $script:mkAcl 'S-1-5-32-544' @() }
            $r = Get-AapAncestorProblem (Join-Path $link 'sub\leaf.ps1')
            @($r.Problems) -join "`n" | Should -Match ([regex]::Escape("reparse point $link"))
            Should -Invoke Get-Acl -Times 0 -Exactly -ParameterFilter { $LiteralPath -eq $link }
        }

        It 'refuses an ancestor with a null DACL' {
            $raw = New-Object System.Security.AccessControl.RawSecurityDescriptor 'O:BA'
            $ds = New-Object System.Security.AccessControl.DirectorySecurity
            $bytes = New-Object byte[] $raw.BinaryLength
            $raw.GetBinaryForm($bytes, 0)
            $ds.SetSecurityDescriptorBinaryForm($bytes)
            Mock Get-Acl { $ds }
            $r = Get-AapAncestorProblem 'C:\wsl\aap-runner-supervisor'
            @($r.Problems) -join "`n" | Should -Match 'C:\\wsl has no DACL'
        }

        It 'does not treat write-attributes on a parent as a replace right' {
            $users = New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-545'
            $attr = New-Object System.Security.AccessControl.FileSystemAccessRule($users, 'WriteAttributes', 'None', 'None', 'Allow')
            Mock Get-Acl { & $script:mkAcl 'S-1-5-32-544' @($attr) }
            $r = Get-AapAncestorProblem 'C:\wsl\aap-runner-supervisor'
            @($r.Problems).Count | Should -Be 0
        }

        It 'resolves notepad to a fixed local drive and refuses a UNC path' {
            $final = Get-AapFinalDosPath 'C:\Windows\System32\notepad.exe'
            $final | Should -Match '^[A-Za-z]:\\'
            Test-AapFixedLocalPath $final | Should -BeTrue
            Test-AapFixedLocalPath '\\server\share\tray.exe' | Should -BeFalse
            Test-AapFixedLocalPath 'C:notepad.exe' | Should -BeFalse
        }

        It 'resolves a folder through a junction to its target and a plain folder to itself' {
            $target = Join-Path $TestDrive 'final-target'
            $link = Join-Path $TestDrive 'final-link'
            & $script:mkJunction $link $target
            $resolved = Get-AapFinalDosPath $link
            $resolved | Should -Be (Get-AapFinalDosPath $target)
            $resolved | Should -Match 'final-target$'
            Get-AapFinalDosPath $env:SystemRoot | Should -Be $env:SystemRoot
        }

        It 'gives the user read only on the root and no folder creation in inbox' {
            $op = $script:op
            $rootRules = @((Get-AapDataDirAcl $op).GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object { $_.IdentityReference.Value -eq $op })
            $rootRules.Count | Should -Be 1
            $rootRules[0].FileSystemRights | Should -Be ([Security.AccessControl.FileSystemRights]'ReadAndExecute, Synchronize')
            $inboxRules = @((Get-AapInboxAcl $op).GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object { $_.IdentityReference.Value -eq $op })
            $folder = @($inboxRules | Where-Object { $_.PropagationFlags -eq 'None' -and $_.InheritanceFlags -eq 'None' })
            $folder.Count | Should -Be 1
            ($folder[0].FileSystemRights -band [Security.AccessControl.FileSystemRights]::CreateFiles) | Should -Not -Be 0
            ([int]$folder[0].FileSystemRights -band [int][Security.AccessControl.FileSystemRights]::CreateDirectories) | Should -Be 0
            $files = @($inboxRules | Where-Object { $_.PropagationFlags -eq 'InheritOnly' })
            $files.Count | Should -Be 1
            $files[0].InheritanceFlags | Should -Be 'ObjectInherit'
            $files[0].FileSystemRights | Should -Be ([Security.AccessControl.FileSystemRights]'Modify, Synchronize')
            (Get-AapInboxAcl $op).AreAccessRulesProtected | Should -BeTrue
            (Get-AapDataDirAcl $op).GetOwner([Security.Principal.SecurityIdentifier]).Value | Should -Be 'S-1-5-32-544'
        }

        It 'uses the tray allowlist for the exe directory' {
            Test-AapAdminOwned 'C:\Program Files' | Should -BeTrue
            $users = New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-545'
            $rx = New-Object System.Security.AccessControl.FileSystemAccessRule($users, 'ReadAndExecute', 'None', 'None', 'Allow')
            $ti = 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
            $files = New-Object System.Security.AccessControl.RawSecurityDescriptor((& $script:mkAcl $ti @($rx)).GetSecurityDescriptorBinaryForm(), 0)
            Test-AapAdminDescriptor $files | Should -BeTrue
            $owned = New-Object System.Security.AccessControl.RawSecurityDescriptor((& $script:mkAcl $script:op @()).GetSecurityDescriptorBinaryForm(), 0)
            Test-AapAdminDescriptor $owned | Should -BeFalse
            $me = New-Object Security.Principal.SecurityIdentifier $script:op
            $modify = New-Object System.Security.AccessControl.FileSystemAccessRule($me, 'Modify', 'None', 'None', 'Allow')
            $modRaw = New-Object System.Security.AccessControl.RawSecurityDescriptor((& $script:mkAcl 'S-1-5-32-544' @($modify)).GetSecurityDescriptorBinaryForm(), 0)
            Test-AapAdminDescriptor $modRaw | Should -BeFalse
            $wdac = New-Object System.Security.AccessControl.FileSystemAccessRule($me, 'ChangePermissions', 'None', 'None', 'Allow')
            $wdacRaw = New-Object System.Security.AccessControl.RawSecurityDescriptor((& $script:mkAcl 'S-1-5-32-544' @($wdac)).GetSecurityDescriptorBinaryForm(), 0)
            Test-AapAdminDescriptor $wdacRaw | Should -BeFalse
            $attr = New-Object System.Security.AccessControl.FileSystemAccessRule($me, 'WriteAttributes', 'None', 'None', 'Allow')
            $attrRaw = New-Object System.Security.AccessControl.RawSecurityDescriptor((& $script:mkAcl 'S-1-5-32-544' @($attr)).GetSecurityDescriptorBinaryForm(), 0)
            Test-AapAdminDescriptor $attrRaw | Should -BeFalse
            $objectAce = New-Object System.Security.AccessControl.RawSecurityDescriptor 'O:BA D:(OA;;RPWP;c9651a32-5a0b-4e8c-9a55-6b9a0a0a0a0a;;BU)'
            Test-AapAdminDescriptor $objectAce | Should -BeFalse
        }

        It 'accepts an admin owner for the tray directory and refuses the operator' {
            $dir = Join-Path $TestDrive 'tray-owner'
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            $script:ownerSid = 'S-1-5-32-544'
            Mock Get-Acl { & $script:mkAcl $script:ownerSid @() }
            foreach ($sid in @('S-1-5-32-544', 'S-1-5-18', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')) {
                $script:ownerSid = $sid
                Test-AapAdminOwned $dir | Should -BeTrue
            }
            $script:ownerSid = $script:op
            Test-AapAdminOwned $dir | Should -BeFalse
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
                Mock Test-AapAdminOwned { return $true }
                Mock Write-AapTrayRunValue { }
                Mock Clear-AapTrayRunValue { }
                Mock Stop-ScheduledTask { throw 'must not be reached' }
                Mock Unregister-ScheduledTask { throw 'must not be reached' }
                Mock Get-ScheduledTask { return $null }
                Mock Register-AapTask { }
                $empty = { [pscustomobject]@{ Problems = @(); Unreadable = @() } }
                Mock Get-AapDataDirProblem $empty
                Mock Get-AapAncestorProblem $empty
                $DryRun = $false
                $DataDir = Join-Path $TestDrive ('pd-' + [guid]::NewGuid().ToString('n'))
                $ScriptDir = Join-Path $TestDrive ('sd-' + [guid]::NewGuid().ToString('n'))
                $TaskName = 'AAP-Test-NotRegistered'
            }

            It 'refuses a tray exe whose directory is not admin-owned' {
                Mock Test-AapAdminOwned { return $false }
                $TrayExe = Join-Path $TestDrive 'aap-runner-tray.exe'
                Set-Content -LiteralPath $TrayExe -Value 'x'
                $code = @(Invoke-AapInstallSupervisor | Where-Object { $_ -is [int] })[-1]
                $code | Should -Be 1
                Should -Invoke Write-AapTrayRunValue -Times 0 -Exactly
            }

            It 'refuses a tray exe under a parent a non-admin can rename' {
                Mock Get-AapAncestorProblem {
                    param($Path)
                    if ($Path -eq $TrayExe) {
                        return [pscustomobject]@{ Problems = @('C:\writable grants S-1-5-32-545 Delete'); Unreadable = @() }
                    }
                    return [pscustomobject]@{ Problems = @(); Unreadable = @() }
                }
                $TrayExe = Join-Path $TestDrive 'aap-runner-tray.exe'
                Set-Content -LiteralPath $TrayExe -Value 'x'
                $code = @(Invoke-AapInstallSupervisor | Where-Object { $_ -is [int] })[-1]
                $code | Should -Be 1
                Should -Invoke Write-AapTrayRunValue -Times 0 -Exactly
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
                Get-Content -Raw -LiteralPath (Join-Path $DataDir 'inbox\state.json') | Should -Be '{"desired":"off"}'
                Should -Invoke Register-AapTask -Times 1 -Exactly
            }

            It 'uninstall removes the Run value of the installing SID and writes nothing in the data folder' {
                New-Item -ItemType Directory -Force -Path (Join-Path $DataDir 'inbox') | Out-Null
                $code = @(Invoke-AapUninstallSupervisor | Where-Object { $_ -is [int] })[-1]
                $code | Should -Be 0
                Should -Invoke Clear-AapTrayRunValue -Times 1 -Exactly -ParameterFilter {
                    $RunKey -eq "Registry::HKEY_USERS\$($script:sid)\Software\Microsoft\Windows\CurrentVersion\Run"
                }
                @(Get-ChildItem -LiteralPath $DataDir -Recurse -File -Force).Count | Should -Be 0
            }
        }
    }

    Describe 'dry-run processes' {
        BeforeAll {
            $script:exe = (Get-Process -Id $PID).Path
        }

        It 'install-supervisor.ps1 -DryRun exits 0' {
            $pd = Join-Path $TestDrive 'pd'
            $out = & $script:exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'install-supervisor.ps1') -DryRun -DataDir $pd -TaskName 'AAP-Test-NotRegistered' -TrayExe (Join-Path $TestDrive 'missing-tray.exe') 2>&1 | Out-String
            $LASTEXITCODE | Should -Be 0
            $out | Should -Match 'WOULD task AAP-Test-NotRegistered logon trigger'
            $out | Should -Match 'inbox\\jobs'
            $out | Should -Match 'INFO tray .*missing-tray.exe not found; Run value skipped'
            Test-Path -LiteralPath $pd | Should -BeFalse
        }


        It 'install-supervisor.ps1 -DryRun prints the Run value for an existing tray exe' {
            $tray = 'C:\Windows\System32\notepad.exe'
            $out = & $script:exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'install-supervisor.ps1') -DryRun -DataDir (Join-Path $TestDrive 'pd') -TaskName 'AAP-Test-NotRegistered' -TrayExe $tray 2>&1 | Out-String
            $LASTEXITCODE | Should -Be 0
            $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            $out | Should -Match ([regex]::Escape("WOULD run-key Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Run AAP-Runner-Tray = `"$tray`""))
        }

        It 'uninstall-supervisor.ps1 -DryRun exits 0' {
            $out = & $script:exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'uninstall-supervisor.ps1') -DryRun -DataDir (Join-Path $TestDrive 'pd') -ScriptDir (Join-Path $TestDrive 'sd') -TaskName 'AAP-Test-NotRegistered' 2>&1 | Out-String
            $LASTEXITCODE | Should -Be 0
            $out | Should -Match 'KEEP'
            $out | Should -Not -Match 'state.json'
            $out | Should -Match 'distro keeps running until logoff'
            $out | Should -Match 'WOULD remove Run value AAP-Runner-Tray from Registry::HKEY_USERS'
        }

        It 'aap-runner-supervisor.ps1 -Once -DryRun exits 0 without calling wsl.exe' {
            $pd = Join-Path $TestDrive 'pd-sup'
            New-Item -ItemType Directory -Force -Path $pd | Out-Null
            New-Item -ItemType Directory -Force -Path (Join-Path $pd 'inbox') | Out-Null
            [IO.File]::WriteAllText((Join-Path $pd 'inbox\state.json'), '{"desired":"on"}')
            $out = & $script:exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'aap-runner-supervisor.ps1') -Once -DryRun -DataDir $pd 2>&1 | Out-String
            $LASTEXITCODE | Should -Be 0
            $out | Should -Match 'DRYRUN would Start-ScheduledTask AAP-CRRR-Mount-Work-Disk'
            Test-Path -LiteralPath (Join-Path $pd 'status.json') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $pd 'logs') | Should -BeFalse
        }
    }
}
