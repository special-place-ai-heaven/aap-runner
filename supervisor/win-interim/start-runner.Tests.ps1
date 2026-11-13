# Pester 5 tests for the interim Windows runner start script. The process list, Stop-Process, the
# sleeps, the log and the run.cmd start are mocked. The job-object and mutex tests start real, hidden
# child processes (PowerShell and ping) and end them. Run under powershell.exe 5.1 and pwsh 7.

Describe 'interim Windows runner start script' {
    BeforeAll {
        $script:sut = Join-Path $PSScriptRoot 'start-runner.ps1'
        . $script:sut -NoRun
        $script:dir = 'C:\aap-win-interim\runner'
        function New-Proc([int]$Id, [string]$Name, [string]$Path, [int]$Parent = 0, [string]$Cmd = '') {
            [pscustomobject]@{ ProcessId = $Id; Name = $Name; ExecutablePath = $Path; ParentProcessId = $Parent; CommandLine = $Cmd }
        }
        $cmd = 'C:\Windows\System32\cmd.exe'
        $script:listener = New-Proc 20 'Runner.Listener.exe' "$dir\bin\Runner.Listener.exe" 10
        # The real layout: run.cmd calls run-helper.cmd in the same cmd.exe, started as `cmd /c run.cmd`.
        $script:runcmd = New-Proc 10 'cmd.exe' $cmd 5 'C:\Windows\system32\cmd.exe /c run.cmd'
        $script:shell = New-Proc 5 'powershell.exe' 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' 1 'powershell -File start-runner.ps1'
        $script:worker = New-Proc 30 'Runner.Worker.exe' "$dir\bin\Runner.Worker.exe" 20
        $script:other = New-Proc 40 'Runner.Listener.exe' 'D:\another\bin\Runner.Listener.exe' 41
        $script:otherHost = New-Proc 41 'cmd.exe' $cmd 1 'cmd /c run.cmd'
        $script:exe = (Get-Process -Id $PID).Path
    }
    BeforeEach {
        # One shared table: the mocks change it, the tests read it.
        $script:st = @{ procs = @(); stopped = @(); obeysKill = $true; jobOnHostKill = $false; starts = 0; jobs = 0 }
        $st = $script:st
        Mock Get-CimInstance { $st.procs }
        Mock Start-Sleep { }
        Mock Write-AapInterimLog { }
        Mock Stop-Process {
            $st.stopped += "$Id"
            if ($st.obeysKill) { $st.procs = @($st.procs | Where-Object { $_.ProcessId -notin $Id }) }
            if ($st.jobOnHostKill -and $Id -contains 10) { $st.procs += $script:worker }
        }
        Mock Start-AapInterimProcess { $st.starts++; 7 }
    }

    Context 'finding the processes' {
        It 'finds only this folder''s listener and its run.cmd shell, and no other runner' {
            $st.procs = @($listener, $runcmd, $shell, $other, $otherHost)
            $r = Get-AapInterimProcesses $dir
            @($r.Listeners.ProcessId) | Should -Be @(20)
            @($r.Hosts.ProcessId) | Should -Be @(10)
            $r.Workers.Count | Should -Be 0
            $r.Unknown.Count | Should -Be 0
        }
        It 'does not take a neighbouring folder for this one' {
            $st.procs = @(
                (New-Proc 50 'Runner.Listener.exe' 'C:\aap-win-interim\runner2\bin\Runner.Listener.exe' 1),
                (New-Proc 51 'Runner.Listener.exe' 'C:\aap-win-interim\runner\bin.old\Runner.Listener.exe' 1))
            (Get-AapInterimProcesses $dir).Listeners.Count | Should -Be 0
        }
        It 'accepts the folder with a trailing or forward slash' {
            $st.procs = @($listener)
            (Get-AapInterimProcesses 'C:/aap-win-interim/runner/').Listeners.Count | Should -Be 1
        }
        It 'reports a runner process with no readable path as unknown' {
            $st.procs = @((New-Proc 60 'Runner.Listener.exe' $null 1))
            $r = Get-AapInterimProcesses $dir
            $r.Listeners.Count | Should -Be 0
            @($r.Unknown.ProcessId) | Should -Be @(60)
        }
        It 'counts a worker started by our listener even when its path is elsewhere' {
            $st.procs = @($listener, (New-Proc 31 'Runner.Worker.exe' 'C:\aap-win-interim\runner\bin.2.338.0\Runner.Worker.exe' 20))
            @((Get-AapInterimProcesses $dir).Workers.ProcessId) | Should -Be @(31)
        }
        It 'does not count another runner''s worker' {
            $st.procs = @($listener, (New-Proc 32 'Runner.Worker.exe' 'D:\another\bin\Runner.Worker.exe' 40))
            (Get-AapInterimProcesses $dir).Workers.Count | Should -Be 0
        }
        It 'does not take an interactive or unrelated cmd.exe above a listener for its shell' -TestCases @(
            @{ Line = 'cmd /k prerun.cmd' }, @{ Line = '"C:\Windows\System32\cmd.exe"' }
        ) {
            $st.procs = @((New-Proc 20 'Runner.Listener.exe' "$dir\bin\Runner.Listener.exe" 12), (New-Proc 12 'cmd.exe' 'C:\Windows\System32\cmd.exe' 1 $Line))
            (Get-AapInterimProcesses $dir).Hosts.Count | Should -Be 0
        }
    }

    Context 'a listener this script did not start' {
        It 'reports none and touches nothing when nothing of ours runs' {
            $st.procs = @($other, $otherHost, $shell)
            Stop-AapInterimForeign $dir 1 | Should -Be 'none'
            $st.stopped.Count | Should -Be 0
        }
        It 'never touches a listener that is running a job' {
            $st.procs = @($listener, $runcmd, $worker)
            Stop-AapInterimForeign $dir 1 | Should -Be 'busy'
            $st.stopped.Count | Should -Be 0
        }
        It 'touches nothing while a runner process is unreadable' {
            $st.procs = @($listener, (New-Proc 61 'Runner.Worker.exe' $null 999))
            Stop-AapInterimForeign $dir 1 | Should -Be 'unknown'
            $st.stopped.Count | Should -Be 0
        }
        It 'kills the run.cmd shell and then the listener, and no other runner' {
            $st.procs = @($listener, $runcmd, $other, $otherHost)
            Stop-AapInterimForeign $dir 1 | Should -Be 'stopped'
            $st.stopped | Should -Be @('10', '20')
            @($st.procs.ProcessId | Sort-Object) | Should -Be @(40, 41)
        }
        It 'does not kill the listener when a job started just before' {
            $st.procs = @($listener, $runcmd)
            $st.jobOnHostKill = $true
            Stop-AapInterimForeign $dir 1 | Should -Be 'busy'
            $st.stopped | Should -Be @('10')
        }
        It 'reports stuck when the listener survives the kill' {
            $st.procs = @($listener)
            $st.obeysKill = $false
            Stop-AapInterimForeign $dir 0 | Should -Be 'stuck'
        }
    }

    Context 'the start decision' {
        BeforeEach {
            $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $root | Out-Null
            $script:oldPath = $env:Path
            Mock Enter-AapInterimJob { $st.jobs++ }
        }
        AfterEach { $env:Path = $script:oldPath }

        It 'does nothing until the runner is configured' {
            Start-AapInterimRunner $root 0 | Should -Be 0
            $st.starts + $st.jobs | Should -Be 0
        }
        It 'enters the job, then starts run.cmd, and reports 1 when run.cmd ends so the task restarts it' {
            Set-Content -LiteralPath (Join-Path $root '.runner') -Value '{}'
            Mock Start-AapInterimProcess { if ($st.jobs -ne 1) { throw 'run.cmd started outside the job' }; $st.starts++; 7 }
            Start-AapInterimRunner $root 0 | Should -Be 1
            $st.starts | Should -Be 1
        }
        It 'starts nothing and exits <Code> when a foreign listener is <State>' -TestCases @(
            @{ State = 'busy'; Code = 0 }, @{ State = 'unknown'; Code = 1 }, @{ State = 'stuck'; Code = 1 }
        ) {
            Set-Content -LiteralPath (Join-Path $root '.runner') -Value '{}'
            Mock Stop-AapInterimForeign { $State }
            Start-AapInterimRunner $root 0 | Should -Be $Code
            $st.starts + $st.jobs | Should -Be 0
        }
        It 'exits 0 before stopping or starting anything when the control file says off' -Tag 'interim-control-off' {
            Set-Content -LiteralPath (Join-Path $root '.runner') -Value '{}'
            $ctl = Join-Path $root 'host-runner.json'
            [IO.File]::WriteAllText($ctl, '{"schema":1,"desired":"off"}')
            Mock Stop-AapInterimForeign { throw 'a foreign listener was touched' }
            Start-AapInterimRunner $root 0 $ctl | Should -Be 0
            $st.starts + $st.jobs | Should -Be 0
            $st.stopped.Count | Should -Be 0
        }
        It 'starts as before when the control file says on' {
            Set-Content -LiteralPath (Join-Path $root '.runner') -Value '{}'
            $ctl = Join-Path $root 'host-runner.json'
            [IO.File]::WriteAllText($ctl, '{"schema":1,"desired":"on"}')
            Start-AapInterimRunner $root 0 $ctl | Should -Be 1
            $st.starts | Should -Be 1
        }
        It 'exits 0, not 1, when the runner was turned off while it ran' -Tag 'interim-control-off' {
            Set-Content -LiteralPath (Join-Path $root '.runner') -Value '{}'
            Mock Start-AapInterimProcess { $st.starts++; $null }
            Start-AapInterimRunner $root 0 | Should -Be 0
            $st.starts | Should -Be 1
        }
        It 'puts Git Bash first on PATH once, and reports a missing Git Bash' {
            $git = Join-Path $root 'Git\bin'
            New-Item -ItemType Directory -Path $git | Out-Null
            Add-AapInterimGitBash $git | Should -BeFalse
            $env:Path | Should -Be $script:oldPath
            Set-Content -LiteralPath (Join-Path $git 'bash.exe') -Value ''
            Add-AapInterimGitBash $git | Should -BeTrue
            Add-AapInterimGitBash $git | Should -BeTrue
            $env:Path | Should -Be "$git;$($script:oldPath)"
        }
    }

    Context 'the control file' {
        BeforeEach {
            $script:ctl = Join-Path $TestDrive 'host-runner.json'
            if (Test-Path -LiteralPath $ctl) { Remove-Item -LiteralPath $ctl }
            # A run.cmd that runs for $st.slices slices, then exits with 7.
            $st.slices = 99
            $script:proc = [pscustomobject]@{ ExitCode = 7 }
            $proc | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($ms) $script:st.slices--; return ($script:st.slices -lt 0) }
        }

        It 'reads <text> as off=<off>' -Tag 'interim-control-parse' -TestCases @(
            @{ text = '{"schema":1,"desired":"off"}'; off = $true }
            @{ text = '{"schema":1,"desired":"on"}'; off = $false }
            @{ text = '{"schema":1,"desired":"OFF"}'; off = $false }
            @{ text = '{"schema":2,"desired":"off"}'; off = $false }
            @{ text = '{"schema":"1","desired":"off"}'; off = $false }
            @{ text = '{"desired":"off"}'; off = $false }
            @{ text = '{nope'; off = $false }
            @{ text = ''; off = $false }
            @{ text = $null; off = $false }
        ) {
            if ($null -ne $text) { [IO.File]::WriteAllText($ctl, $text) }
            Test-AapInterimOff $ctl | Should -Be $off
        }

        It 'returns run.cmd''s exit code while the runner stays on' {
            $st.slices = 3
            [IO.File]::WriteAllText($ctl, '{"schema":1,"desired":"on"}')
            Wait-AapInterimProcess $proc $dir $ctl 0 | Should -Be 7
        }

        It 'returns $null once turned off with no job, so the job object ends the listener' -Tag 'interim-control-off' {
            [IO.File]::WriteAllText($ctl, '{"schema":1,"desired":"off"}')
            $st.procs = @($listener, $runcmd, $shell)
            $null -eq (Wait-AapInterimProcess $proc $dir $ctl 0) | Should -BeTrue
            $st.stopped.Count | Should -Be 0 -Because 'the script ends itself; it kills nothing'
        }

        It 'never ends a job in progress, logs the request once, and stops after the job' -Tag 'interim-control-busy' {
            [IO.File]::WriteAllText($ctl, '{"schema":1,"desired":"off"}')
            $st.procs = @($listener, $runcmd, $shell, $worker)
            $script:waits = 0
            $proc | Add-Member -Force -MemberType ScriptMethod -Name WaitForExit -Value {
                param($ms)
                $script:waits++
                if ($script:waits -eq 4) { $script:st.procs = @($script:listener, $script:runcmd, $script:shell) }
                return $false
            }
            $null -eq (Wait-AapInterimProcess $proc $dir $ctl 0) | Should -BeTrue
            $script:waits | Should -Be 4
            Should -Invoke Write-AapInterimLog -ParameterFilter { $Line -like '*waiting for the job in progress*' } -Times 1 -Exactly
            $st.stopped.Count | Should -Be 0
        }

        It 'forgets a stop request that is withdrawn during a job' -Tag 'interim-control-busy' {
            [IO.File]::WriteAllText($ctl, '{"schema":1,"desired":"off"}')
            $st.procs = @($listener, $runcmd, $shell, $worker)
            $script:waits = 0
            $proc | Add-Member -Force -MemberType ScriptMethod -Name WaitForExit -Value {
                param($ms)
                $script:waits++
                if ($script:waits -eq 3) { [IO.File]::WriteAllText($script:ctl, '{"schema":1,"desired":"on"}') }
                if ($script:waits -eq 4) { $script:st.procs = @($script:listener, $script:runcmd, $script:shell) }
                return ($script:waits -ge 6)
            }
            Wait-AapInterimProcess $proc $dir $ctl 0 | Should -Be 7
            Should -Invoke Write-AapInterimLog -ParameterFilter { $Line -like '*waiting for the job in progress*' } -Times 1 -Exactly
        }
    }

    Context 'real processes' {
        It 'a child started after Enter-AapInterimJob dies when the script process is killed' {
            $pidFile = Join-Path $TestDrive 'child.pid'
            $body = ". '$($script:sut)' -NoRun; Enter-AapInterimJob; " +
                "`$c = Start-Process ping.exe -ArgumentList '-n','120','127.0.0.1' -WindowStyle Hidden -PassThru; " +
                "Set-Content -LiteralPath '$pidFile' -Value `$c.Id; Start-Sleep -Seconds 120"
            $parent = Start-Process $script:exe -ArgumentList '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', $body -WindowStyle Hidden -PassThru
            try {
                $deadline = [DateTime]::UtcNow.AddSeconds(60)
                while (-not (Test-Path -LiteralPath $pidFile) -and [DateTime]::UtcNow -lt $deadline) { [Threading.Thread]::Sleep(200) }
                Test-Path -LiteralPath $pidFile | Should -BeTrue
                $child = [int](Get-Content -LiteralPath $pidFile)
                # Enumerate: a handle from Get-Process -Id would keep an ended process findable by id.
                $alive = { @([Diagnostics.Process]::GetProcesses() | Where-Object { $_.Id -eq $child -and $_.ProcessName -eq 'PING' }).Count }
                & $alive | Should -Be 1
                $parent.Kill()   # not Stop-Process: it is mocked in this file
                $deadline = [DateTime]::UtcNow.AddSeconds(20)
                while ((& $alive) -gt 0 -and [DateTime]::UtcNow -lt $deadline) { [Threading.Thread]::Sleep(200) }
                & $alive | Should -Be 0
            } finally {
                if (-not $parent.HasExited) { $parent.Kill() }
            }
        }
        It 'a second instance exits 0 and starts nothing while the first holds the mutex' {
            $root = Join-Path $TestDrive 'held'
            New-Item -ItemType Directory -Path $root | Out-Null
            Set-Content -LiteralPath (Join-Path $root '.runner') -Value '{}'
            Set-Content -LiteralPath (Join-Path $root 'run.cmd') -Value "@echo ran> `"$root\ran.txt`""
            $copy = Join-Path $root 'start-runner.ps1'
            Copy-Item -LiteralPath $script:sut -Destination $copy
            # Its own name: on the runner itself the real script holds the real one.
            $name = "Global\AapWinInterimTest-$([guid]::NewGuid().ToString('N'))"
            $m = New-Object Threading.Mutex($false, $name)
            $m.WaitOne(0) | Should -BeTrue
            try {
                $p = Start-Process $script:exe -ArgumentList '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $copy, '-Dir', $root, '-MutexName', $name -WindowStyle Hidden -PassThru -Wait
                $p.ExitCode | Should -Be 0
                Test-Path -LiteralPath (Join-Path $root 'ran.txt') | Should -BeFalse
                Get-Content -LiteralPath (Join-Path $root 'start-runner.log') -Raw | Should -Match 'another instance'
            } finally { $m.ReleaseMutex(); $m.Dispose() }
        }
    }
}
