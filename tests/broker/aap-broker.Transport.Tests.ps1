# Pester 5, Windows PowerShell 5.1 and PowerShell 7. The hidden process runner, driven with cmd.exe, findstr.exe and PING.EXE.

BeforeAll { . (Join-Path $PSScriptRoot 'BrokerTestHelpers.ps1') }

Describe 'hidden process transport' {
    It 'writes the request to stdin, returns stdout bytes and passes the exit code through' {
        $r = Invoke-Child 'findstr.exe' '"^"' ([Text.Encoding]::ASCII.GetBytes('{"schema":1}'))
        $r.ExitCode | Should -Be 0
        $r.TimedOut | Should -BeFalse
        Get-Text $r.Stdout | Should -BeExactly '{"schema":1}'
        $r = Invoke-Child 'cmd.exe' '/d /c exit 3'
        $r.ExitCode | Should -Be 3
        $r.Stdout.Length | Should -Be 0
    }

    It 'stops at 20 KiB of stdout' {
        $big = Join-Path $TestDrive 'big.txt'
        [IO.File]::WriteAllText($big, ('A' * 30000))
        $r = Invoke-Child 'cmd.exe' ('/d /c type "{0}"' -f $big)
        $r.Overflow | Should -BeTrue
        $r.Stdout | Should -BeNullOrEmpty
        $r.ExitCode | Should -BeNullOrEmpty
    }

    It 'kills a child that outlives the timeout' {
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-Child 'PING.EXE' '-n 30 127.0.0.1' -TimeoutSeconds 2
        $r.TimedOut | Should -BeTrue
        $r.ExitCode | Should -BeNullOrEmpty
        $r.Stdout | Should -BeNullOrEmpty
        $clock.Elapsed.TotalSeconds | Should -BeLessThan 15
    }

    It 'drains a stderr flood without deadlock and keeps it out of the result' {
        $mega = Join-Path $TestDrive 'mega.txt'
        [IO.File]::WriteAllText($mega, ('E' * 1048576))
        $r = Invoke-Child 'cmd.exe' ('/d /c type "{0}" 1>&2 & echo ok' -f $mega)
        $r.ExitCode | Should -Be 0
        Get-Text $r.Stdout | Should -BeExactly 'ok'
    }

    It 'gives the child WSL_UTF8=1 and no WSLENV' {
        $saved = $env:WSLENV
        $env:WSLENV = 'BASH_ENV/u:SHELLOPTS/u'
        try {
            $r = Invoke-Child 'cmd.exe' '/d /c set WSL'
        } finally {
            $env:WSLENV = $saved
        }
        $lines = @((Get-Text $r.Stdout) -split "`r`n")
        $lines | Should -Contain 'WSL_UTF8=1'
        @($lines | Where-Object { $_ -like 'WSLENV=*' }).Count | Should -Be 0
    }

    It 'carries an issued lease end to end through a real child without exposing it' {
        # The child plays the broker and answers with the synthetic JIT config from
        # its environment, never from its command line.
        $exe = Join-Path $script:System32 'cmd.exe'
        $arguments = '/d /c echo ' + (ConvertTo-Wire (New-LeaseReply -Jit '%AAP_TEST_JIT%'))
        $module = $script:Module
        $invoker = {
            param([byte[]]$StdIn, [int]$TimeoutSeconds)
            & $module {
                param($File, $ArgumentLine, $In, $Timeout)
                Invoke-AapBrokerProcess -FileName $File -Arguments $ArgumentLine -StdIn $In -TimeoutSeconds $Timeout -MaxStdoutBytes 20480
            } $exe $arguments $StdIn $TimeoutSeconds
        }.GetNewClosure()
        $env:AAP_TEST_JIT = $script:Jit
        try {
            $a = $script:LeaseArgs
            $r = Invoke-AapBrokerLease @a -Invoker $invoker
        } finally {
            Remove-Item Env:\AAP_TEST_JIT
        }
        $r.Outcome | Should -Be 'issued'
        $r.RunnerName | Should -BeExactly $script:RunnerName
        Get-Secret $r.JitConfig | Should -BeExactly $script:Jit
        "$r".Contains($script:Jit) | Should -BeFalse
    }
}
