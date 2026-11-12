# Pester 5 tests for the interim Windows runner start script. The process list, Stop-Process and
# the sleeps are mocked; nothing is started or stopped. Run under powershell.exe 5.1 and pwsh 7.

Describe 'interim Windows runner start script' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'start-runner.ps1') -NoRun
        $script:dir = 'C:\aap-win-interim\runner'
        function New-Proc([int]$Id, [string]$Name, [string]$Path, [int]$Parent = 0, [string]$Cmd = '') {
            [pscustomobject]@{ ProcessId = $Id; Name = $Name; ExecutablePath = $Path; ParentProcessId = $Parent; CommandLine = $Cmd }
        }
        $script:listener = New-Proc 20 'Runner.Listener.exe' "$dir\bin\Runner.Listener.exe" 11
        $script:helper = New-Proc 11 'cmd.exe' 'C:\Windows\System32\cmd.exe' 10 'cmd /c run-helper.cmd'
        $script:runcmd = New-Proc 10 'cmd.exe' 'C:\Windows\System32\cmd.exe' 5 'cmd.exe /c run.cmd'
        $script:shell = New-Proc 5 'powershell.exe' 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' 1 'powershell -File start-runner.ps1'
        $script:worker = New-Proc 30 'Runner.Worker.exe' "$dir\bin\Runner.Worker.exe" 20
        $script:other = New-Proc 40 'Runner.Listener.exe' 'D:\another\bin\Runner.Listener.exe' 1
    }
    BeforeEach {
        $script:st = @{ procs = @(); stopped = @(); ignoreStop = $false }
        $st = $script:st
        Mock Get-CimInstance { $st.procs }
        Mock Start-Sleep { }
        Mock Stop-Process {
            $st.stopped += "$Id$(if ($Force) { '!' })"
            if (-not $st.ignoreStop -or $Force) { $st.procs = @($st.procs | Where-Object { $_.ProcessId -notin $Id }) }
        }
    }

    It 'finds only this folder''s listener and the run.cmd hosts above it' {
        $script:st.procs = @($listener, $helper, $runcmd, $shell, $other)
        $r = Get-AapInterimProcesses $dir
        @($r.Listeners.ProcessId) | Should -Be @(20)
        @($r.Hosts.ProcessId) | Should -Be @(11, 10)
        $r.Workers.Count | Should -Be 0
    }

    It 'reports none and stops nothing when no listener runs' {
        $script:st.procs = @($other, $shell)
        Stop-AapInterimStale $dir 1 | Should -Be 'none'
        $script:st.stopped.Count | Should -Be 0
    }

    It 'leaves a listener that is running a job alone' {
        $script:st.procs = @($listener, $helper, $runcmd, $worker)
        Stop-AapInterimStale $dir 1 | Should -Be 'busy'
        $script:st.stopped.Count | Should -Be 0
    }

    It 'stops the hosts before the listener, and never another folder''s runner' {
        $script:st.procs = @($listener, $helper, $runcmd, $other)
        Stop-AapInterimStale $dir 1 | Should -Be 'stopped'
        $script:st.stopped | Should -Be @('11', '10', '20')
        @($script:st.procs.ProcessId) | Should -Be @(40)
    }

    It 'kills a listener that ignores the stop' {
        $script:st.procs = @($listener)
        $script:st.ignoreStop = $true
        Stop-AapInterimStale $dir 0 | Should -Be 'stopped'
        $script:st.stopped | Should -Be @('20', '20!')
    }

    It 'reports stuck when the listener survives the kill' {
        $script:st.procs = @($listener)
        Mock Stop-Process { $st.stopped += "$Id" }
        Stop-AapInterimStale $dir 0 | Should -Be 'stuck'
    }

    It 'puts Git Bash first on PATH and starts nothing over a stuck or busy listener' {
        $text = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'start-runner.ps1')
        $text.IndexOf('$env:Path = "$gitBash;$env:Path"') | Should -BeGreaterThan 0
        $text.IndexOf("'busy' { exit 0 }") | Should -BeLessThan $text.IndexOf('Start-Process -FilePath $env:ComSpec')
        $text.IndexOf("'stuck' {") | Should -BeLessThan $text.IndexOf('Start-Process -FilePath $env:ComSpec')
    }
}
