# Pester 5 tests for the interim Windows runner start script. The process list, the Ctrl+C sender,
# Stop-Process, the sleeps, the log and the run.cmd start are mocked; nothing is started or stopped.
# Run under powershell.exe 5.1 and pwsh 7.

Describe 'interim Windows runner start script' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'start-runner.ps1') -NoRun
        $script:dir = 'C:\aap-win-interim\runner'
        function New-Proc([int]$Id, [string]$Name, [string]$Path, [int]$Parent = 0, [string]$Cmd = '') {
            [pscustomobject]@{ ProcessId = $Id; Name = $Name; ExecutablePath = $Path; ParentProcessId = $Parent; CommandLine = $Cmd }
        }
        $cmd = 'C:\Windows\System32\cmd.exe'
        $script:listener = New-Proc 20 'Runner.Listener.exe' "$dir\bin\Runner.Listener.exe" 11
        $script:helper = New-Proc 11 'cmd.exe' $cmd 10 "cmd.exe /d /s /c `"`"$dir\run-helper.cmd`" `""
        $script:runcmd = New-Proc 10 'cmd.exe' $cmd 5 'C:\Windows\system32\cmd.exe /c run.cmd'
        $script:shell = New-Proc 5 'powershell.exe' 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' 1 'powershell -File start-runner.ps1'
        $script:worker = New-Proc 30 'Runner.Worker.exe' "$dir\bin\Runner.Worker.exe" 20
        $script:other = New-Proc 40 'Runner.Listener.exe' 'D:\another\bin\Runner.Listener.exe' 41
        $script:otherHost = New-Proc 41 'cmd.exe' $cmd 1 'cmd /c "D:\another\run-helper.cmd"'
    }
    BeforeEach {
        # One shared table: the mocks change it, the tests read it.
        $script:st = @{ procs = @(); stopped = @(); ctrlc = @(); obeysCtrlC = $false; obeysKill = $true; jobAfterCtrlC = $false; starts = 0 }
        $st = $script:st
        Mock Get-CimInstance { $st.procs }
        Mock Start-Sleep { }
        Mock Write-AapInterimLog { }
        Mock Send-AapInterimCtrlC {
            $st.ctrlc += $ProcessId
            if ($st.obeysCtrlC) { $st.procs = @($st.procs | Where-Object { $_.ProcessId -notin 20, 11, 10 }) }
            if ($st.jobAfterCtrlC) { $st.procs += $script:worker }
            $true
        }
        Mock Stop-Process {
            $st.stopped += "$Id"
            if ($st.obeysKill) { $st.procs = @($st.procs | Where-Object { $_.ProcessId -notin $Id }) }
        }
        Mock Start-AapInterimProcess { $st.starts++; 7 }
    }

    Context 'finding the processes' {
        It 'finds only this folder''s listener, its hosts and no other runner' {
            $st.procs = @($listener, $helper, $runcmd, $shell, $other, $otherHost)
            $r = Get-AapInterimProcesses $dir
            @($r.Listeners.ProcessId) | Should -Be @(20)
            @($r.Hosts.ProcessId | Sort-Object) | Should -Be @(10, 11)
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
        It 'finds a host that is waiting to start the listener again' {
            $st.procs = @($helper, $runcmd, $shell)
            $r = Get-AapInterimProcesses $dir
            $r.Listeners.Count | Should -Be 0
            @($r.Hosts.ProcessId | Sort-Object) | Should -Be @(10, 11)
        }
        It 'does not take an unrelated cmd.exe above a listener for a host' {
            $odd = New-Proc 12 'cmd.exe' 'C:\Windows\System32\cmd.exe' 1 'cmd /k prerun.cmd'
            $st.procs = @((New-Proc 20 'Runner.Listener.exe' "$dir\bin\Runner.Listener.exe" 12), $odd)
            (Get-AapInterimProcesses $dir).Hosts.Count | Should -Be 0
        }
    }

    Context 'stopping an earlier listener' {
        It 'reports none and touches nothing when nothing of ours runs' {
            $st.procs = @($other, $otherHost, $shell)
            Stop-AapInterimStale $dir 1 | Should -Be 'none'
            $st.ctrlc.Count + $st.stopped.Count | Should -Be 0
        }
        It 'never touches a listener that is running a job' {
            $st.procs = @($listener, $helper, $runcmd, $worker)
            Stop-AapInterimStale $dir 1 | Should -Be 'busy'
            $st.ctrlc.Count + $st.stopped.Count | Should -Be 0
        }
        It 'touches nothing while a runner process is unreadable' {
            $st.procs = @($listener, (New-Proc 61 'Runner.Worker.exe' $null 999))
            Stop-AapInterimStale $dir 1 | Should -Be 'unknown'
            $st.ctrlc.Count + $st.stopped.Count | Should -Be 0
        }
        It 'asks first, and kills nothing when the listener obeys' {
            $st.procs = @($listener, $helper, $runcmd, $other)
            $st.obeysCtrlC = $true
            Stop-AapInterimStale $dir 1 | Should -Be 'stopped'
            $st.ctrlc | Should -Be @(20)
            $st.stopped.Count | Should -Be 0
        }
        It 'kills the hosts and then the listener when asking did not work, and no other runner' {
            $st.procs = @($listener, $helper, $runcmd, $other, $otherHost)
            Stop-AapInterimStale $dir 0 | Should -Be 'stopped'
            $st.ctrlc | Should -Be @(20)
            $st.stopped | Should -Be @('11', '10', '20')
            @($st.procs.ProcessId | Sort-Object) | Should -Be @(40, 41)
        }
        It 'kills a host left without a listener' {
            $st.procs = @($helper, $runcmd)
            Stop-AapInterimStale $dir 0 | Should -Be 'stopped'
            $st.stopped | Should -Be @('11', '10')
        }
        It 'does not kill the listener when a job started while it waited' {
            $st.procs = @($listener, $helper, $runcmd)
            $st.jobAfterCtrlC = $true
            Stop-AapInterimStale $dir 0 | Should -Be 'busy'
            $st.stopped.Count | Should -Be 0
        }
        It 'reports stuck when something survives the kill' {
            $st.procs = @($listener)
            $st.obeysKill = $false
            Stop-AapInterimStale $dir 0 | Should -Be 'stuck'
        }
    }

    Context 'the start decision' {
        BeforeEach {
            $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $root | Out-Null
            $script:oldPath = $env:Path
        }
        AfterEach { $env:Path = $script:oldPath }

        It 'does nothing until the runner is configured' {
            Start-AapInterimRunner $root 0 | Should -Be 0
            $st.starts | Should -Be 0
        }
        It 'starts run.cmd and returns its exit code when nothing was running' {
            Set-Content -LiteralPath (Join-Path $root '.runner') -Value '{}'
            Start-AapInterimRunner $root 0 | Should -Be 7
            $st.starts | Should -Be 1
        }
        It 'starts nothing and exits <Code> when the earlier listener is <State>' -TestCases @(
            @{ State = 'busy'; Code = 0 }, @{ State = 'unknown'; Code = 1 }, @{ State = 'stuck'; Code = 1 }
        ) {
            Set-Content -LiteralPath (Join-Path $root '.runner') -Value '{}'
            Mock Stop-AapInterimStale { $State }
            Start-AapInterimRunner $root 0 | Should -Be $Code
            $st.starts | Should -Be 0
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
}
