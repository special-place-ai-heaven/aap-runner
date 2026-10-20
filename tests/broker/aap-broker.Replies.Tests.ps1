# Pester 5, Windows PowerShell 5.1 and PowerShell 7. Replies: how the client maps broker answers to outcomes.

BeforeAll { . (Join-Path $PSScriptRoot 'BrokerTestHelpers.ps1') }

Describe 'replies' {
    BeforeEach { Reset-Fake }

    It 'returns an issued lease whose JIT config shows nothing but its length' {
        $r = Invoke-Lease
        $r.Outcome | Should -Be 'issued'
        $r.Reason | Should -Be 'ok'
        $r.ExitCode | Should -Be 0
        $r.RunnerId | Should -Be 23
        $r.RunnerName | Should -BeExactly $script:RunnerName
        $r.ExpiresAt | Should -BeExactly '2026-10-19T18:10:00Z'
        @($r.JitConfig.PSObject.Properties | ForEach-Object { $_.Name }) -join ',' | Should -BeExactly 'Length'
        $r.JitConfig.Length | Should -Be $script:Jit.Length
        Get-Secret $r.JitConfig | Should -BeExactly $script:Jit
        Test-Zeroed $script:LastStdout | Should -BeTrue -Because 'the reply buffer is wiped once parsed'
    }

    It 'zeroes the JIT config on Clear' {
        $r = Invoke-Lease
        $r.JitConfig.Clear()
        $ms = New-Object IO.MemoryStream
        $r.JitConfig.WriteTo($ms)
        $ms.Length | Should -Be $script:Jit.Length
        Test-Zeroed $ms.ToArray() | Should -BeTrue
    }

    It 'returns every refusal reason without registration material' {
        foreach ($reason in @('replay', 'expired', 'clock_skew', 'stale_generation', 'malformed', 'unknown_profile', 'lease_limit', 'github_error', 'rate_limited', 'not_found')) {
            $script:Reply = New-RefusedReply $reason
            $r = Invoke-Lease
            $r.Outcome | Should -Be 'refused'
            $r.Reason | Should -BeExactly $reason
            $r.JitConfig | Should -BeNullOrEmpty
            $r.RunnerId | Should -BeNullOrEmpty
        }
    }

    It 'treats a broker that fails, times out or cannot start as unavailable' {
        $script:Reply = New-Result '' 1
        $r = Invoke-Lease
        $r.Outcome | Should -Be 'unavailable'
        $r.ExitCode | Should -Be 1
        $script:Reply = New-Result (ConvertTo-Wire (New-LeaseReply)) 2
        $r = Invoke-Lease
        $r.Outcome | Should -Be 'unavailable'
        $r.JitConfig | Should -BeNullOrEmpty
        Test-Zeroed $script:LastStdout | Should -BeTrue
        $script:Reply = [pscustomobject]@{ ExitCode = $null; Stdout = $null; TimedOut = $true; Overflow = $false }
        $r = Invoke-Lease
        $r.Outcome | Should -Be 'unavailable'
        $r.ExitCode | Should -BeNullOrEmpty
        $script:Reply = { throw 'wsl.exe is missing' }
        (Invoke-Lease).Outcome | Should -Be 'unavailable'
        $script:Reply = [pscustomobject]@{ ExitCode = $null; Stdout = $null; TimedOut = $false; Overflow = $true }
        (Invoke-Lease).Outcome | Should -Be 'bad_reply'
    }

    It 'refuses a lease reply that breaks the contract' {
        $broken = New-Object System.Collections.Generic.List[object]
        $broken.Add((New-LeaseReply -LeaseId $script:OtherLeaseId))
        $broken.Add((New-LeaseReply -RunnerName 'aap-w-4-3-ffffffff'))
        $broken.Add((New-LeaseReply -RunnerName 'aap-w-1-1-1a2b3c4d'))
        $broken.Add((New-LeaseReply -Jit $null))
        $broken.Add((New-LeaseReply -Result 'refused'))
        $broken.Add((New-LeaseReply -Result 'refused' -Reason 'replay'))
        $broken.Add((New-LeaseReply -Reason 'nope'))
        $broken.Add((New-LeaseReply -Reason 'jit_config'))
        $broken.Add((New-LeaseReply -Jit 'not a jit config'))
        $broken.Add((New-LeaseReply -Jit ('A' * 16385)))
        $broken.Add((New-LeaseReply -RunnerId 23.0))
        $d = New-LeaseReply; $d['kind'] = 'release_response'; $broken.Add($d)
        $d = New-LeaseReply; $d['token'] = 'x'; $broken.Add($d)
        $d = New-LeaseReply; $d.Remove('runner_id'); $broken.Add($d)
        # Byte-level shapes the broker never prints.
        $good = ConvertTo-Wire (New-LeaseReply)
        $broken.Add($good.Replace('5555"', '555\u0035"'))
        $broken.Add($good.Replace('"jit_config":', '"jit_config" :'))
        $broken.Add($good.Substring(0, $good.Length - 1) + ',"jit_config":null}')
        $broken.Add($good + ' x')
        $broken.Add($good + $good)
        $broken.Add($good.Insert($good.IndexOf(',') + 1, "`t"))
        $nonAscii = New-Result $good
        $nonAscii.Stdout[12] = 0xE9
        $broken.Add($nonAscii)
        $broken.Add($good + (' ' * 20480))
        $broken.Add('')
        foreach ($reply in $broken) {
            $script:Reply = $reply
            $r = Invoke-Lease
            $r.Outcome | Should -Be 'bad_reply'
            $r.JitConfig | Should -BeNullOrEmpty
            Test-Zeroed $script:LastStdout | Should -BeTrue
        }
    }

    It 'checks release and status replies against the request' {
        $busy = [ordered]@{ status = 'online'; busy = $true }
        $cases = @(
            @{ Op = 'release'; Reply = (New-ReleaseReply 'already_gone' 'ok'); Want = 'already_gone' },
            @{ Op = 'release'; Reply = (New-ReleaseReply 'retry' 'rate_limited'); Want = 'retry' },
            @{ Op = 'release'; Reply = (New-ReleaseReply 'refused' 'not_found'); Want = 'refused' },
            @{ Op = 'release'; Reply = (New-ReleaseReply 'deregistered' 'github_error'); Want = 'bad_reply' },
            @{ Op = 'release'; Reply = (New-ReleaseReply 'retry' 'ok'); Want = 'bad_reply' },
            @{ Op = 'release'; Reply = (New-ReleaseReply 'deregistered' 'ok' $script:OtherLeaseId); Want = 'bad_reply' },
            @{ Op = 'status'; Reply = (New-StatusReply 'ok' 'ok' $busy); Want = 'ok' },
            @{ Op = 'status'; Reply = (New-StatusReply 'refused' 'github_error' $null); Want = 'refused' },
            @{ Op = 'status'; Reply = (New-StatusReply 'refused' 'not_found' ([ordered]@{ status = 'offline'; busy = $false })); Want = 'bad_reply' },
            @{ Op = 'status'; Reply = (New-StatusReply 'ok' 'ok' $null); Want = 'bad_reply' },
            @{ Op = 'status'; Reply = (New-StatusReply 'ok' 'ok' ([ordered]@{ status = 'busy'; busy = $true })); Want = 'bad_reply' },
            @{ Op = 'status'; Reply = (New-StatusReply 'ok' 'ok' ([ordered]@{ status = 'online'; busy = 'yes' })); Want = 'bad_reply' },
            @{ Op = 'status'; Reply = (New-StatusReply 'ok' 'ok' ([ordered]@{ status = 'online'; busy = $true; id = 1 })); Want = 'bad_reply' }
        )
        $extra = New-ReleaseReply 'deregistered' 'ok'
        $extra['runner_id'] = 5
        $cases += @{ Op = 'release'; Reply = $extra; Want = 'bad_reply' }
        foreach ($c in $cases) {
            $script:Reply = $c.Reply
            if ($c.Op -eq 'release') { $r = Invoke-Release } else { $r = Invoke-Status }
            $r.Outcome | Should -Be $c.Want -Because (ConvertTo-Wire $c.Reply)
        }
        $script:Reply = New-StatusReply 'ok' 'ok' $busy
        $r = Invoke-Status
        $r.RunnerStatus | Should -Be 'online'
        $r.RunnerBusy | Should -BeTrue
    }
}
