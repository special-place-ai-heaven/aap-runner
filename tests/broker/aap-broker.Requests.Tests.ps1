# Pester 5, Windows PowerShell 5.1 and PowerShell 7. Requests: what the client writes to the broker.

BeforeAll { . (Join-Path $PSScriptRoot 'BrokerTestHelpers.ps1') }

Describe 'requests' {
    BeforeEach { Reset-Fake }

    It 'sends exactly the fixed lease request, compact, on stdin only' {
        $r = Invoke-Lease
        $r.Outcome | Should -Be 'issued'
        $script:Sent.Count | Should -Be 1
        $text = $script:Sent[0]
        $text | Should -Match '^\{"schema":1,"kind":"lease_request",'
        $text | Should -Not -Match '\s'
        $doc = ConvertFrom-AapBrokerJson $text
        @($doc.Keys) -join ',' | Should -BeExactly 'schema,kind,lease_id,reservation_id,lease_generation,slot,profile,image_generation,nonce,issued_at'
        Test-AapBrokerDocument $doc | Should -BeNullOrEmpty
        $doc['lease_id'] | Should -BeExactly $script:LeaseId
        $doc['reservation_id'] | Should -BeExactly 'r-1a2b3c4d000000b1'
        $doc['lease_generation'] | Should -Be 3
        $doc['slot'] | Should -Be 4
        $doc['profile'] | Should -BeExactly 'win25-vs2026-x64'
        $doc['image_generation'] | Should -BeExactly 'win25-vs2026-x64/20261007.264.1-aap.1'
        $doc['nonce'] | Should -Match '^[0-9a-f]{32}\z'
        $sent = [DateTimeOffset]::Parse($doc['issued_at'], [Globalization.CultureInfo]::InvariantCulture)
        [Math]::Abs(($sent - [DateTimeOffset]::UtcNow).TotalSeconds) | Should -BeLessThan 10
        $script:Timeouts[0] | Should -Be 60
    }

    It 'uses a fresh nonce on every call and sends release and status with the lease id only' {
        $script:Reply = New-ReleaseReply 'deregistered' 'ok'
        (Invoke-Release).Outcome | Should -Be 'deregistered'
        (Invoke-Release).Outcome | Should -Be 'deregistered'
        $script:Reply = New-StatusReply 'ok' 'ok' ([ordered]@{ status = 'offline'; busy = $false })
        (Invoke-Status).Outcome | Should -Be 'ok'
        $docs = @($script:Sent | ForEach-Object { ConvertFrom-AapBrokerJson $_ })
        $docs.Count | Should -Be 3
        foreach ($d in $docs) {
            @($d.Keys) -join ',' | Should -BeExactly 'schema,kind,lease_id,nonce,issued_at'
            Test-AapBrokerDocument $d | Should -BeNullOrEmpty
        }
        $docs[0]['kind'] | Should -BeExactly 'release_request'
        $docs[2]['kind'] | Should -BeExactly 'status_request'
        $docs[0]['nonce'] | Should -Not -Be $docs[1]['nonce']
    }

    It 'starts nothing but the fixed hidden wsl.exe command line' {
        Mock -ModuleName aap-broker Invoke-AapBrokerProcess {
            [pscustomobject]@{ ExitCode = 1; Stdout = [byte[]]@(); TimedOut = $false; Overflow = $false }
        }
        $r = Invoke-AapBrokerStatus -LeaseId $script:LeaseId
        $r.Outcome | Should -Be 'unavailable'
        $r.ExitCode | Should -Be 1
        Should -Invoke -ModuleName aap-broker Invoke-AapBrokerProcess -Times 1 -Exactly -ParameterFilter {
            $FileName -ceq 'C:\Windows\System32\wsl.exe' -and
            $Arguments -ceq '-d aap-runner -u root --exec /usr/local/sbin/aap-runner-broker' -and
            $TimeoutSeconds -eq 60 -and $MaxStdoutBytes -eq 20480 -and
            (ConvertFrom-AapBrokerJson ([Text.Encoding]::ASCII.GetString($StdIn)))['kind'] -ceq 'status_request'
        }
    }

    It 'throws before any call on an argument outside the contract' {
        $bad = @(
            @{ LeaseId = 'l-5555/../../etc/passwd' }, @{ LeaseId = 'L-55555555555555555555555555555555' },
            @{ ReservationId = 'r-1a2b3c4d' }, @{ LeaseGeneration = 0 }, @{ LeaseGeneration = 1000000000 }, @{ Slot = 6 }, @{ Slot = 0 },
            @{ RunnerProfile = 'windows-latest' }, @{ RunnerProfile = 'WIN25-VS2026-X64' },
            @{ ImageGeneration = 'ubuntu-24.04-x64/20261007.264.1-aap.1' }, @{ ImageGeneration = 'win25-vs2026-x64/latest' },
            @{ Distro = 'aap-runner -u root --exec /bin/sh' }, @{ TimeoutSeconds = 0 }
        )
        foreach ($b in $bad) {
            $a = @{} + $script:LeaseArgs
            foreach ($k in $b.Keys) { $a[$k] = $b[$k] }
            { Invoke-AapBrokerLease @a -Invoker $script:Fake } | Should -Throw '*invalid broker argument*'
        }
        { Invoke-AapBrokerRelease -LeaseId 'l-1' -Invoker $script:Fake } | Should -Throw '*invalid broker argument*'
        { Invoke-AapBrokerStatus -LeaseId $script:LeaseId -Distro 'x;y' -Invoker $script:Fake } | Should -Throw '*invalid broker argument*'
        $script:Sent.Count | Should -Be 0
    }

    It 'makes lease ids from the CSPRNG' {
        $ids = @(1..20 | ForEach-Object { New-AapBrokerLeaseId })
        foreach ($id in $ids) { $id | Should -Match '^l-[0-9a-f]{32}\z' }
        @($ids | Select-Object -Unique).Count | Should -Be 20
    }
}
