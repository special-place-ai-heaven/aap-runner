# Verify against a fixture ProgramData tree, and the identity verb against a
# fixture request. No wsl, no scheduled task, no ACL write. Pester 5. Windows
# PowerShell 5.1 and PowerShell 7.

Describe 'helper verify' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\installer\helper-run.ps1')
        Mock Test-AapDistroListed { return 'stopped' }
        $script:junctions = New-Object System.Collections.Generic.List[string]
        function Invoke-AapCaptured([scriptblock]$Script) {
            $sw = New-Object IO.StringWriter
            $orig = [Console]::Out
            [Console]::SetOut($sw)
            try { $code = & $Script } finally { [Console]::SetOut($orig) }
            return [pscustomobject]@{ Code = [int]$code; Out = $sw.ToString() }
        }
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

    It 'passes the configured work-disk size to install-host -DryRun' {
        Mock Get-AapDistroManagerConf { return "AAP_WORK_DISK_GIB=200`nAAP_DISK_FLOOR_GB=20`n" }
        Mock Get-AapVhdxBytes { return [long]64424509440 }
        Mock Invoke-AapStreaming { return 0 }
        Mock Get-AapVerifyReport { return [pscustomobject]@{ ExitCode = 0; Lines = @('PASS data-dir') } }
        Get-AapWorkDiskGiB | Should -Be 200
        $null = Invoke-AapVerifyLive -DataDir 'C:\ProgramData\aap-runner'
        Should -Invoke Invoke-AapStreaming -Times 1 -Exactly -ParameterFilter {
            ($Arguments -join ' ') -match 'install-host\.ps1 -DryRun -WorkDiskGiB 200$'
        }
    }

    It 'falls back to the measured VHDX size when the distro is absent' {
        Mock Get-AapDistroManagerConf { return $null }
        Mock Get-AapVhdxBytes { return [long]214748364800 + 4MB }
        Mock Invoke-AapStreaming { return 0 }
        Mock Get-AapVerifyReport { return [pscustomobject]@{ ExitCode = 0; Lines = @('PASS data-dir') } }
        Get-AapWorkDiskGiB | Should -Be 200
        $null = Invoke-AapVerifyLive -DataDir 'C:\ProgramData\aap-runner'
        Should -Invoke Invoke-AapStreaming -Times 1 -Exactly -ParameterFilter {
            ($Arguments -join ' ') -match 'install-host\.ps1 -DryRun -WorkDiskGiB 200$'
        }
        Mock Get-AapVhdxBytes { return [long]0 }
        Get-AapWorkDiskGiB | Should -Be 0
        $null = Invoke-AapVerifyLive -DataDir 'C:\ProgramData\aap-runner'
        Should -Invoke Invoke-AapStreaming -Times 1 -Exactly -ParameterFilter {
            ($Arguments -join ' ') -match 'install-host\.ps1 -DryRun$'
        }
    }

    It 'verify adds an app-token row from the manager check' {
        Mock Get-AapDistroManagerConf { return $null }
        Mock Get-AapVhdxBytes { return [long]0 }
        Mock Get-AapVerifyReport { return [pscustomobject]@{ ExitCode = 0; Lines = @('PASS data-dir') } }
        Mock Invoke-AapStreaming { if (($Arguments -join ' ') -match '--check-token$') { return $script:tokenCode }; return 0 }
        $script:tokenCode = 0
        $ok = Invoke-AapCaptured { Invoke-AapVerifyLive -DataDir 'C:\ProgramData\aap-runner' }
        $ok.Code | Should -Be 0
        $ok.Out | Should -Match 'STEP app-token'
        $ok.Out | Should -Match 'PASS app-token obtainable'
        Should -Invoke Invoke-AapStreaming -Times 1 -Exactly -ParameterFilter {
            $File -eq 'C:\Windows\System32\wsl.exe' -and ($Arguments -join ' ') -eq '-d aap-runner -u root -- /usr/local/sbin/aap-runner-manager --check-token'
        }
        $script:tokenCode = 1
        $bad = Invoke-AapCaptured { Invoke-AapVerifyLive -DataDir 'C:\ProgramData\aap-runner' }
        $bad.Code | Should -Be 1
        $bad.Out | Should -Match 'FAIL app-token exit 1'
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

Describe 'helper identity' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\installer\helper-run.ps1')
        $script:junctions = New-Object System.Collections.Generic.List[string]
        $script:enc = New-Object System.Text.UTF8Encoding $false
        $script:pemBody = 'MIIEowIBAAKCAQEAnotarealkeybodyjustbytesforthetest'
        $script:pem = "-----BEGIN RSA PRIVATE KEY-----`n$($script:pemBody)`n-----END RSA PRIVATE KEY-----`n"
        $script:gitBash = 'C:\Program Files\Git\bin\bash.exe'
        $script:profileDir = Join-Path $TestDrive 'Users\me'
        New-Item -ItemType Directory -Force -Path (Join-Path $script:profileDir 'Downloads') | Out-Null
        Mock Get-AapRequestOwnerProfile { return $script:profileDir }
        $script:wslCalls = New-Object System.Collections.Generic.List[object]
        # The distro side, run through Git bash when it is present: the real script in
        # library mode with the paths, chown, chmod, systemctl, and the manager replaced.
        Mock Invoke-AapStreamingStdin {
            $script:wslCalls.Add(@{ File = $File; Arguments = $Arguments; StdinPath = $StdinPath })
            if (-not (Test-Path -LiteralPath $script:gitBash)) { return 0 }
            $m = [regex]::Match($Arguments[-1], '^bash <\(echo ([A-Za-z0-9+/=]+) \| base64 -d\) (.+)$')
            if (-not $m.Success) { return 97 }
            $text = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($m.Groups[1].Value))
            $w = $script:scriptWork
            [IO.File]::WriteAllText((Join-Path $w 'identity.sh'), $text, $script:enc)
            $drive = "export AAP_IDENTITY_LIB=1`nsource `"`$1`"; shift`nconf=`"`$W/manager.conf`"; key=`"`$W/app.pem`"; manager=`"`$W/fakemgr.sh`"`nchown() { :; }`nchmod() { :; }`nsystemctl() { echo inactive; }`nmain `"`$@`"`n"
            [IO.File]::WriteAllText((Join-Path $w 'drive.sh'), $drive, $script:enc)
            $mgr = "#!/bin/bash`n[[ `"`$1`" == --check-limits ]] || exit 0`ngrep -q '^AAP_GITHUB_APP_ID=[1-9][0-9]*`$' `"`$AAP_MANAGER_CONF`"`n"
            [IO.File]::WriteAllText((Join-Path $w 'fakemgr.sh'), $mgr, $script:enc)
            $posix = { param($p) ($p -replace '\\', '/') }
            $env:W = & $posix $w
            # stderr is merged inside bash: Windows PowerShell 5.1 under Stop turns native stderr into an error.
            $cmd = "exec bash '$(& $posix (Join-Path $w 'drive.sh'))' '$(& $posix (Join-Path $w 'identity.sh'))' $($m.Groups[2].Value) < '$(& $posix $StdinPath)' 2>&1"
            $out = & $script:gitBash --noprofile --norc -c $cmd | ForEach-Object { "$_" }
            foreach ($line in @($out)) { [Console]::Out.WriteLine($line) }
            return $LASTEXITCODE
        }
        function Invoke-AapCaptured([scriptblock]$Script) {
            $sw = New-Object IO.StringWriter
            $orig = [Console]::Out
            [Console]::SetOut($sw)
            try { $code = & $Script } finally { [Console]::SetOut($orig) }
            return [pscustomobject]@{ Code = [int]$code; Out = $sw.ToString() }
        }
        function New-AapIdentityRequest {
            param([string]$Root, [string]$Id, [string]$KeyPath, [hashtable]$Override = @{})
            $jobs = Join-Path (Join-Path $Root 'inbox') 'jobs'
            New-Item -ItemType Directory -Force -Path $jobs | Out-Null
            $req = [ordered]@{
                schema = 1; id = $Id; verb = 'identity'; org = 'acme'; app_id = 123; installation_id = 456
                group = 'aap-crrr'; labels = 'self-hosted,linux,crrr'; key_path = $KeyPath
            }
            foreach ($k in $Override.Keys) { $req[$k] = $Override[$k] }
            [IO.File]::WriteAllText((Join-Path $jobs "$Id.json"), ($req | ConvertTo-Json -Compress), $script:enc)
        }
        function New-AapKey([string]$Name, [string]$Text = $script:pem) {
            $path = Join-Path (Join-Path $script:profileDir 'Downloads') $Name
            [IO.File]::WriteAllText($path, $Text, $script:enc)
            return $path
        }
    }

    BeforeEach {
        $script:wslCalls.Clear()
        $script:scriptWork = Join-Path $TestDrive ('distro-' + [guid]::NewGuid().ToString('n').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $script:scriptWork | Out-Null
    }

    AfterEach {
        foreach ($j in @($script:junctions)) {
            & C:\Windows\System32\cmd.exe /d /c rmdir "$j" | Out-Null
        }
        $script:junctions.Clear()
    }

    It 'checks each field the way the tray does' {
        Test-AapIdentityId '1' | Should -BeTrue
        Test-AapIdentityId '1234567890123456789' | Should -BeTrue
        foreach ($bad in @('', '0', '007', '+5', '-5', '1.5', '12a', '12345678901234567890')) {
            Test-AapIdentityId $bad | Should -BeFalse -Because $bad
        }
        Test-AapIdentitySlug 'acme' | Should -BeTrue
        Test-AapIdentitySlug ('x' * 39) | Should -BeTrue
        foreach ($bad in @('', '-acme', 'acme-', 'ac--me', 'ac_me', 'ac me', ('x' * 40))) {
            Test-AapIdentitySlug $bad | Should -BeFalse -Because $bad
        }
        Test-AapIdentityLabels 'self-hosted,linux,crrr' | Should -BeTrue
        foreach ($bad in @('', 'Linux', 'a,a', 'a, b', 'a,,b', 'a_b')) {
            Test-AapIdentityLabels $bad | Should -BeFalse -Because $bad
        }
    }

    It 'rewrites a fixture manager.conf keeping other lines and installs the key once' {
        if (-not (Test-Path -LiteralPath $script:gitBash)) {
            Set-ItResult -Skipped -Because 'Git bash is not installed; the distro script cannot run here'
            return
        }
        $root = Join-Path $TestDrive 'id-good'
        $key = New-AapKey 'good.pem'
        $id = '0123456789abcdef'
        New-AapIdentityRequest -Root $root -Id $id -KeyPath $key
        $before = "# keep me`nAAP_GITHUB_ORG=old`nAAP_GITHUB_APP_ID=`nAAP_RUNNER_IMAGE=aap-crrr-runner:local`n`nAAP_RUNNER_LABELS=self-hosted,linux,crrr`nAAP_WORK_DISK_GIB=60`n"
        [IO.File]::WriteAllText((Join-Path $script:scriptWork 'manager.conf'), $before, $script:enc)
        $r = Invoke-AapCaptured { Invoke-AapIdentityLive -DataDir $root -Id $id }
        $r.Code | Should -Be 0
        Should -Invoke Invoke-AapStreamingStdin -Times 1 -Exactly
        $call = $script:wslCalls[0]
        $call.File | Should -Be 'C:\Windows\System32\wsl.exe'
        ($call.Arguments[0..6] -join ' ') | Should -Be '-d aap-runner -u root -- /bin/bash -c'
        $call.Arguments[7] | Should -Match ' acme 123 456 aap-crrr self-hosted,linux,crrr$'
        $call.Arguments[7] | Should -Not -Match '"'
        $call.StdinPath | Should -Be $key
        $after = [IO.File]::ReadAllText((Join-Path $script:scriptWork 'manager.conf'))
        $after | Should -Be "# keep me`nAAP_GITHUB_ORG=acme`nAAP_GITHUB_APP_ID=123`nAAP_RUNNER_IMAGE=aap-crrr-runner:local`n`nAAP_RUNNER_LABELS=self-hosted,linux,crrr`nAAP_WORK_DISK_GIB=60`nAAP_GITHUB_APP_INSTALLATION_ID=456`nAAP_RUNNER_GROUP=aap-crrr`n"
        [IO.File]::ReadAllText((Join-Path $script:scriptWork 'app.pem')) | Should -Be $script:pem
        Test-Path -LiteralPath (Join-Path $script:scriptWork 'app.pem.tmp') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:scriptWork 'manager.conf.tmp') | Should -BeFalse
        $r.Out | Should -Match "key installed: 1 file, $($script:pem.Length) bytes"
        $r.Out | Should -Match 'INFO identity org acme app 123 installation 456 group aap-crrr labels self-hosted,linux,crrr'
        $r.Out | Should -Match 'PASS identity'
        $r.Out | Should -Not -Match $script:pemBody
        $r.Out | Should -Not -Match 'PRIVATE KEY'
        $r.Out | Should -Not -Match ([regex]::Escape($key))
    }

    It 'keeps the old key and conf when the manager refuses the new conf' {
        if (-not (Test-Path -LiteralPath $script:gitBash)) {
            Set-ItResult -Skipped -Because 'Git bash is not installed; the distro script cannot run here'
            return
        }
        $root = Join-Path $TestDrive 'id-refused'
        $key = New-AapKey 'refused.pem'
        $id = '0123456789abcd00'
        New-AapIdentityRequest -Root $root -Id $id -KeyPath $key
        $oldConf = "AAP_GITHUB_APP_ID=notanumber`n"
        [IO.File]::WriteAllText((Join-Path $script:scriptWork 'manager.conf'), $oldConf, $script:enc)
        [IO.File]::WriteAllText((Join-Path $script:scriptWork 'app.pem'), 'old key bytes', $script:enc)
        # The fake manager refuses a conf whose app id is not digits; make the rewrite produce one by
        # handing it a request the PowerShell side accepts but the "manager" does not: mark via env.
        Mock Invoke-AapStreamingStdin {
            $script:wslCalls.Add(@{ File = $File; Arguments = $Arguments; StdinPath = $StdinPath })
            $m = [regex]::Match($Arguments[-1], '^bash <\(echo ([A-Za-z0-9+/=]+) \| base64 -d\) (.+)$')
            $text = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($m.Groups[1].Value))
            $w = $script:scriptWork
            [IO.File]::WriteAllText((Join-Path $w 'identity.sh'), $text, $script:enc)
            $drive = "export AAP_IDENTITY_LIB=1`nsource `"`$1`"; shift`nconf=`"`$W/manager.conf`"; key=`"`$W/app.pem`"; manager=`"`$W/fakemgr.sh`"`nchown() { :; }`nchmod() { :; }`nsystemctl() { echo inactive; }`nmain `"`$@`"`n"
            [IO.File]::WriteAllText((Join-Path $w 'drive.sh'), $drive, $script:enc)
            [IO.File]::WriteAllText((Join-Path $w 'fakemgr.sh'), "#!/bin/bash`necho 'refusing: AAP_RUNNER_LABELS must be self-hosted,linux,crrr' >&2`nexit 1`n", $script:enc)
            $posix = { param($p) ($p -replace '\\', '/') }
            $env:W = & $posix $w
            # stderr is merged inside bash: Windows PowerShell 5.1 under Stop turns native stderr into an error.
            $cmd = "exec bash '$(& $posix (Join-Path $w 'drive.sh'))' '$(& $posix (Join-Path $w 'identity.sh'))' $($m.Groups[2].Value) < '$(& $posix $StdinPath)' 2>&1"
            $out = & $script:gitBash --noprofile --norc -c $cmd | ForEach-Object { "$_" }
            foreach ($line in @($out)) { [Console]::Out.WriteLine($line) }
            return $LASTEXITCODE
        }
        $r = Invoke-AapCaptured { Invoke-AapIdentityLive -DataDir $root -Id $id }
        $r.Code | Should -Be 1
        $r.Out | Should -Match 'refusing: AAP_RUNNER_LABELS'
        $r.Out | Should -Match 'FAIL identity: the manager refused the new manager.conf'
        $r.Out | Should -Match 'FAIL identity exit 1'
        [IO.File]::ReadAllText((Join-Path $script:scriptWork 'manager.conf')) | Should -Be $oldConf
        [IO.File]::ReadAllText((Join-Path $script:scriptWork 'app.pem')) | Should -Be 'old key bytes'
        Test-Path -LiteralPath (Join-Path $script:scriptWork 'app.pem.tmp') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:scriptWork 'manager.conf.tmp') | Should -BeFalse
        $r.Out | Should -Not -Match $script:pemBody
    }

    It 'refuses a key outside the profile' {
        $root = Join-Path $TestDrive 'id-outside'
        $key = Join-Path $TestDrive 'outside.pem'
        [IO.File]::WriteAllText($key, $script:pem, $script:enc)
        $id = '0123456789abcd01'
        New-AapIdentityRequest -Root $root -Id $id -KeyPath $key
        $r = Invoke-AapCaptured { Invoke-AapIdentityLive -DataDir $root -Id $id }
        $r.Code | Should -Be 2
        $r.Out | Should -Match ('FAIL identity key file is not under ' + [regex]::Escape($script:profileDir))
        Should -Invoke Invoke-AapStreamingStdin -Times 0
        $r.Out | Should -Not -Match $script:pemBody
    }

    It 'refuses a reparse point on the key or on the way to it' {
        $root = Join-Path $TestDrive 'id-junction'
        $target = Join-Path $TestDrive 'junction-target'
        New-Item -ItemType Directory -Force -Path $target | Out-Null
        [IO.File]::WriteAllText((Join-Path $target 'k.pem'), $script:pem, $script:enc)
        $link = Join-Path $script:profileDir 'link'
        New-Item -ItemType Junction -Path $link -Target $target | Out-Null
        $script:junctions.Add($link)
        $id = '0123456789abcd02'
        New-AapIdentityRequest -Root $root -Id $id -KeyPath (Join-Path $link 'k.pem')
        $r = Invoke-AapCaptured { Invoke-AapIdentityLive -DataDir $root -Id $id }
        $r.Code | Should -Be 2
        $r.Out | Should -Match 'FAIL identity key path crosses a reparse point'
        New-AapIdentityRequest -Root $root -Id $id -KeyPath $link
        $r2 = Invoke-AapCaptured { Invoke-AapIdentityLive -DataDir $root -Id $id }
        $r2.Code | Should -Be 2
        $r2.Out | Should -Match 'FAIL identity key file is a reparse point'
        Should -Invoke Invoke-AapStreamingStdin -Times 0
    }

    It 'refuses a non-PEM file, an empty file, and a 16 KiB + 1 file' {
        $root = Join-Path $TestDrive 'id-shape'
        $id = '0123456789abcd03'
        $cert = New-AapKey 'cert.pem' "-----BEGIN CERTIFICATE-----`nabc`n"
        New-AapIdentityRequest -Root $root -Id $id -KeyPath $cert
        (Invoke-AapCaptured { Invoke-AapIdentityLive -DataDir $root -Id $id }).Out | Should -Match 'FAIL identity key file is not a PEM private key'
        $empty = New-AapKey 'empty.pem' ''
        New-AapIdentityRequest -Root $root -Id $id -KeyPath $empty
        (Invoke-AapCaptured { Invoke-AapIdentityLive -DataDir $root -Id $id }).Out | Should -Match 'FAIL identity key file is empty'
        $big = New-AapKey 'big.pem' ($script:pem + ('x' * (16384 + 1 - $script:pem.Length)))
        (Get-Item -LiteralPath $big).Length | Should -Be 16385
        New-AapIdentityRequest -Root $root -Id $id -KeyPath $big
        (Invoke-AapCaptured { Invoke-AapIdentityLive -DataDir $root -Id $id }).Out | Should -Match 'FAIL identity key file is larger than 16 KiB'
        $missing = Join-Path (Join-Path $script:profileDir 'Downloads') 'missing.pem'
        New-AapIdentityRequest -Root $root -Id $id -KeyPath $missing
        (Invoke-AapCaptured { Invoke-AapIdentityLive -DataDir $root -Id $id }).Out | Should -Match 'FAIL identity key file was not found'
        $pkcs8 = New-AapKey 'p8.pem' "-----BEGIN PRIVATE KEY-----`r`nabc`r`n"
        Get-AapIdentityKeyProblem $pkcs8 $script:profileDir | Should -BeNullOrEmpty
        Should -Invoke Invoke-AapStreamingStdin -Times 0
    }

    It 'refuses a request with a bad or extra field' {
        $root = Join-Path $TestDrive 'id-fields'
        $key = New-AapKey 'fields.pem'
        $id = '0123456789abcd04'
        $cases = @(
            @{ org = '-acme' }, @{ app_id = 0 }, @{ app_id = '123' }, @{ installation_id = -1 }
            @{ group = 'a--b' }, @{ labels = 'Linux' }, @{ labels = 'a,a' }, @{ schema = 2 }
            @{ verb = 'verify' }, @{ id = 'fedcba9876543210' }, @{ extra = 'x' }, @{ key_path = '' }
        )
        foreach ($case in $cases) {
            New-AapIdentityRequest -Root $root -Id $id -KeyPath $key -Override $case
            $r = Invoke-AapCaptured { Invoke-AapIdentityLive -DataDir $root -Id $id }
            $r.Code | Should -Be 2 -Because ($case | ConvertTo-Json -Compress)
            $r.Out | Should -Match 'FAIL identity refusing: '
        }
        Should -Invoke Invoke-AapStreamingStdin -Times 0
        $r = Invoke-AapCaptured { Invoke-AapIdentityLive -DataDir $root -Id 'nothex' }
        $r.Code | Should -Be 2
        $r.Out | Should -Match 'FAIL identity id'
    }

    It 'identity -Fixture changes nothing' {
        $exe = (Get-Process -Id $PID).Path
        $out = & $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '..\installer\helper-run.ps1') -Verb identity -Id 0123456789abcdef -DataDir (Join-Path $TestDrive 'nope') -Fixture 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 2
        $out | Should -Match 'FAIL identity fixture mode does not change the machine'
        $out | Should -Not -Match 'wsl'
    }
}

Describe 'install-supervisor defaults' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'install-supervisor.ps1')
    }

    It 'defaults TrayExe to the aap-runner folder under Program Files' {
        $TrayExe | Should -Be (Join-Path $env:ProgramFiles 'aap-runner\aap-runner-tray.exe')
        $TrayExe | Should -Not -Match 'TOOLS'
    }
}
