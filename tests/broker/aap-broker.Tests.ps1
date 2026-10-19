# Pester 5 tests for the registration broker client (supervisor/broker/aap-broker.psm1).
# Windows PowerShell 5.1 and PowerShell 7. No test starts wsl.exe: replies come
# from a fake invoker, and the transport tests start cmd.exe, findstr.exe and
# PING.EXE, hidden. Broker replies are built as dictionaries and written by the
# module's own serializer.

BeforeAll {
    $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:ModulePath = Join-Path $script:Repo 'supervisor\broker\aap-broker.psm1'
    Import-Module $script:ModulePath -Force
    $script:Module = Get-Module aap-broker
    $script:Fixtures = Join-Path $script:Repo 'parity\contracts\fixtures\broker'
    $script:System32 = 'C:\Windows\System32'
    # The synthetic JIT config: a marker within the schema's jit_config charset.
    $script:Jit = 'SYNTHETIC-JIT-MARKER-' + [guid]::NewGuid().ToString('n')
    $script:LeaseId = 'l-55555555555555555555555555555555'
    $script:OtherLeaseId = 'l-66666666666666666666666666666666'
    $script:RunnerName = 'aap-w-4-3-1a2b3c4d'
    $script:LeaseArgs = @{
        LeaseId         = $script:LeaseId
        ReservationId   = 'r-1a2b3c4d000000b1'
        LeaseGeneration = 3
        Slot            = 4
        RunnerProfile   = 'win25-vs2026-x64'
        ImageGeneration = 'win25-vs2026-x64/20261007.264.1-aap.1'
    }
    $script:Sent = New-Object 'System.Collections.Generic.List[string]'
    $script:Timeouts = New-Object 'System.Collections.Generic.List[int]'
    $script:Reply = $null
    $script:LastStdout = $null

    # Compact JSON exactly as the module writes requests.
    function ConvertTo-Wire($Map) {
        return & $script:Module { param($m) ConvertTo-AapBrokerJson $m } $Map
    }

    function New-LeaseReply {
        param([string]$LeaseId = $script:LeaseId, [string]$Result = 'issued', [string]$Reason = 'ok', $RunnerId = 23,
            $RunnerName = $script:RunnerName, $ExpiresAt = '2026-10-19T18:10:00Z', $Jit = $script:Jit)
        return [ordered]@{
            schema = 1; kind = 'lease_response'; lease_id = $LeaseId; result = $Result; reason = $Reason
            runner_id = $RunnerId; runner_name = $RunnerName; expires_at = $ExpiresAt; jit_config = $Jit
        }
    }

    function New-RefusedReply([string]$Reason) {
        return New-LeaseReply -Result 'refused' -Reason $Reason -RunnerId $null -RunnerName $null -ExpiresAt $null -Jit $null
    }

    function New-ReleaseReply([string]$Result, [string]$Reason, [string]$LeaseId = $script:LeaseId) {
        return [ordered]@{ schema = 1; kind = 'release_response'; lease_id = $LeaseId; result = $Result; reason = $Reason }
    }

    function New-StatusReply([string]$Result, [string]$Reason, $Runner) {
        return [ordered]@{ schema = 1; kind = 'status_response'; lease_id = $script:LeaseId; result = $Result; reason = $Reason; runner = $Runner }
    }

    function New-Result([string]$Text, [int]$ExitCode = 0) {
        return [pscustomobject]@{ ExitCode = $ExitCode; Stdout = [Text.Encoding]::UTF8.GetBytes($Text); TimedOut = $false; Overflow = $false }
    }

    # The fake wsl.exe: records the request and the timeout, answers $script:Reply
    # (a dictionary, a text, a result object, or a script block that throws).
    $script:Fake = {
        param([byte[]]$StdIn, [int]$TimeoutSeconds)
        $script:Sent.Add([Text.Encoding]::ASCII.GetString($StdIn))
        $script:Timeouts.Add($TimeoutSeconds)
        $answer = $script:Reply
        if ($answer -is [scriptblock]) { $answer = & $answer }
        if ($answer -is [Collections.IDictionary]) { $answer = ConvertTo-Wire $answer }
        if ($answer -is [string]) { $answer = New-Result $answer }
        $script:LastStdout = $answer.Stdout
        return $answer
    }

    function Invoke-Lease {
        $a = $script:LeaseArgs
        return Invoke-AapBrokerLease @a -Invoker $script:Fake
    }

    function Invoke-Release {
        return Invoke-AapBrokerRelease -LeaseId $script:LeaseId -Invoker $script:Fake
    }

    function Invoke-Status {
        return Invoke-AapBrokerStatus -LeaseId $script:LeaseId -Invoker $script:Fake
    }

    # What JitConfig.WriteTo writes, as text (tests only).
    function Get-Secret($Secret) {
        $ms = New-Object IO.MemoryStream
        $Secret.WriteTo($ms)
        return [Text.Encoding]::ASCII.GetString($ms.ToArray())
    }

    function Test-Zeroed($Bytes) {
        return @($Bytes | Where-Object { $_ -ne 0 }).Count -eq 0
    }

    function Copy-Document($Document) {
        $copy = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)
        foreach ($k in $Document.Keys) { $copy[$k] = $Document[$k] }
        return $copy
    }

    # The module's own process runner, started on a System32 tool.
    function Invoke-Child([string]$Tool, [string]$Arguments, [byte[]]$StdIn = @(), [int]$TimeoutSeconds = 60) {
        $exe = Join-Path $script:System32 $Tool
        return & $script:Module {
            param($File, $ArgumentLine, $In, $Timeout)
            Invoke-AapBrokerProcess -FileName $File -Arguments $ArgumentLine -StdIn $In -TimeoutSeconds $Timeout -MaxStdoutBytes 20480
        } $exe $Arguments $StdIn $TimeoutSeconds
    }

    function Get-Text([byte[]]$Bytes) {
        return [Text.Encoding]::ASCII.GetString($Bytes).TrimEnd("`r", "`n")
    }

    function Reset-Fake {
        $script:Sent.Clear()
        $script:Timeouts.Clear()
        $script:LastStdout = $null
        $script:Reply = New-LeaseReply
    }
}

Describe 'contract fixtures' {
    BeforeEach { Reset-Fake }

    It 'accepts every valid fixture and refuses every invalid one, as validate.py does' {
        $valid = @(Get-ChildItem -LiteralPath (Join-Path $script:Fixtures 'valid') -Filter *.json)
        $invalid = @(Get-ChildItem -LiteralPath (Join-Path $script:Fixtures 'invalid') -Filter *.json)
        $valid.Count | Should -BeGreaterThan 0
        $invalid.Count | Should -BeGreaterThan 2
        foreach ($f in $valid) {
            $doc = ConvertFrom-AapBrokerJson ([IO.File]::ReadAllText($f.FullName))
            $doc | Should -Not -BeNullOrEmpty -Because $f.Name
            Test-AapBrokerDocument $doc | Should -BeNullOrEmpty -Because $f.Name
        }
        foreach ($f in $invalid) {
            $case = ConvertFrom-AapBrokerJson ([IO.File]::ReadAllText($f.FullName))
            $case | Should -Not -BeNullOrEmpty -Because $f.Name
            $why = Test-AapBrokerDocument $case['instance']
            $why | Should -Not -BeNullOrEmpty -Because $f.Name
            # The same reason as validate.py. Errors name fields and never quote a value.
            if ($case['expect'].Contains('"')) {
                $why | Should -BeLike '*profile*' -Because $f.Name
            } else {
                $why | Should -BeLike ('*' + $case['expect'] + '*') -Because $f.Name
            }
        }
    }

    It 'agrees with validate.py itself on the same fixtures' {
        $py = Get-Command python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $py) {
            Set-ItResult -Skipped -Because 'python is not installed'
            return
        }
        $out = & $py.Source -B -I (Join-Path $script:Repo 'parity\contracts\validate.py') 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($out | Out-String)
    }

    It 'refuses what the strict parser must refuse' {
        $deep = '1'
        foreach ($i in 1..5) { $deep = '{"a":' + $deep + '}' }
        $texts = @('', 'null', '[]', '{"a":[1]}', '{"a":1,"a":1}', '{"a":1} x', '{"a":1}{"b":2}', '{"a":NaN}',
            "{`"a`":`"x`ty`"}", '{"a":1,}', '{a:1}', '{"a":01}', $deep, '{"a":"\x"}', '{"a":"\u0041"}')
        foreach ($text in $texts) {
            ConvertFrom-AapBrokerJson $text | Should -BeNullOrEmpty -Because $text
        }
        $d = ConvertFrom-AapBrokerJson '{ "n" : 3 , "f" : 3.0 , "s" : "a\/b\n" , "t" : true , "z" : null , "o" : { "k" : false } }'
        $d['n'] | Should -BeOfType [long]
        $d['f'] | Should -BeOfType [double]
        $d['s'] | Should -BeExactly "a/b`n"
        $d['t'] | Should -BeTrue
        $d['z'] | Should -BeNullOrEmpty
        $d['o']['k'] | Should -BeFalse
        $d.Contains('N') | Should -BeFalse
    }

    It 'refuses wrong case, a trailing newline, a float generation and a request over 4096 bytes' {
        $base = ConvertFrom-AapBrokerJson ([IO.File]::ReadAllText((Join-Path $script:Fixtures 'valid\lease-request.json')))
        Test-AapBrokerDocument $base | Should -BeNullOrEmpty
        $cases = New-Object System.Collections.Generic.List[object]
        $d = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)
        foreach ($k in $base.Keys) { if ($k -ceq 'kind') { $d['Kind'] = $base[$k] } else { $d[$k] = $base[$k] } }
        $cases.Add($d)
        $d = Copy-Document $base; $d['lease_id'] = $base['lease_id'] + "`n"; $cases.Add($d)
        $d = Copy-Document $base; $d['lease_id'] = $base['lease_id'].ToUpperInvariant(); $cases.Add($d)
        $d = Copy-Document $base; $d['lease_generation'] = 3.0; $cases.Add($d)
        $d = Copy-Document $base; $d['profile'] = 'WIN25-VS2026-X64'; $cases.Add($d)
        $d = Copy-Document $base; $d['slot'] = $true; $cases.Add($d)
        $d = Copy-Document $base; $d['image_generation'] = $base['image_generation'] + ('9' * 4000); $cases.Add($d)
        $d = Copy-Document $base; $d['image_generation'] = 'ubuntu-24.04-x64/20261007.264.1-aap.1'; $d['profile'] = 'ubuntu-24.04-x64'; $d['issued_at'] = '2026-10-19T18:00:00z'; $cases.Add($d)
        foreach ($c in $cases) {
            Test-AapBrokerDocument $c | Should -Not -BeNullOrEmpty
        }
    }
}

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

Describe 'secret marker' {
    BeforeEach { Reset-Fake }

    It 'never surfaces the JIT config in output, streams, errors, a transcript or serialized results' {
        $transcript = Join-Path $TestDrive 'transcript.txt'
        $results = New-Object 'System.Collections.Generic.List[object]'
        $good = ConvertTo-Wire (New-LeaseReply)
        $replies = @(
            (New-LeaseReply -LeaseId $script:OtherLeaseId),
            ($good + ' x'),
            $good.Replace('"jit_config":', '"jit_config" :'),
            ($good + (' ' * 20480)),
            ($good.Substring(0, $good.IndexOf('"jit_config"')) + '"jit_config":"' + $script:Jit + '"'),
            (New-Result $good 3)
        )
        $replies.Count | Should -Be 6
        $errorsBefore = $Error.Count
        Start-Transcript -LiteralPath $transcript | Out-Null
        try {
            $VerbosePreference = 'Continue'
            $DebugPreference = 'Continue'
            $InformationPreference = 'Continue'
            $streams = & {
                $script:Reply = New-LeaseReply
                $results.Add((Invoke-Lease))
                foreach ($reply in $replies) {
                    $script:Reply = $reply
                    $results.Add((Invoke-Lease))
                }
            } *>&1 | Out-String
        } finally {
            $VerbosePreference = 'SilentlyContinue'
            $DebugPreference = 'SilentlyContinue'
            $InformationPreference = 'SilentlyContinue'
            Stop-Transcript | Out-Null
        }
        $results[0].Outcome | Should -Be 'issued'
        @($results | Select-Object -Skip 1 | ForEach-Object { $_.Outcome }) -join ',' | Should -Be 'bad_reply,bad_reply,bad_reply,bad_reply,bad_reply,unavailable'
        $newErrors = @($Error | Select-Object -First ($Error.Count - $errorsBefore))
        $texts = @(
            $streams,
            [IO.File]::ReadAllText($transcript),
            ($newErrors | Out-String),
            ($results | Format-List * | Out-String),
            (($results | ForEach-Object { "$_" }) -join "`n"),
            (ConvertTo-Json -InputObject $results.ToArray() -Depth 5 -Compress),
            (ConvertTo-Json -InputObject @{ state = 'running'; detail = ('lease ' + $results[0].Outcome); slots = $results.ToArray() } -Depth 5)
        )
        foreach ($t in $texts) {
            $t.Contains($script:Jit) | Should -BeFalse
            $t.Contains('SYNTHETIC-JIT-MARKER') | Should -BeFalse
        }
        # Status- and log-shaped files written from the result the way the supervisor writes them.
        [IO.File]::WriteAllText((Join-Path $TestDrive 'status.json'), (ConvertTo-Json -InputObject @{ lease = $results[0] } -Compress -Depth 5))
        $results[0] | Export-Clixml -LiteralPath (Join-Path $TestDrive 'result.clixml')
        Add-Content -LiteralPath (Join-Path $TestDrive 'supervisor.log') -Value ('lease {0} {1} {2}' -f $results[0].LeaseId, $results[0].Outcome, $results[0])
        foreach ($f in Get-ChildItem -LiteralPath $TestDrive -File) {
            [IO.File]::ReadAllText($f.FullName).Contains($script:Jit) | Should -BeFalse -Because $f.Name
        }
        Get-Secret $results[0].JitConfig | Should -BeExactly $script:Jit
    }

    It 'has no code that logs, writes files or prints' {
        $source = [IO.File]::ReadAllText($script:ModulePath)
        $words = @('Write-Host', 'Write-Output', 'Write-Verbose', 'Write-Warning', 'Write-Information', 'Write-Debug', 'Write-Error',
            'Out-File', 'Out-Host', 'Set-Content', 'Add-Content', 'Export-Clixml', 'Export-Csv', 'Start-Transcript', 'New-Item',
            'WriteAll', 'AppendAll', 'FileStream', 'Tee-Object')
        foreach ($word in $words) {
            $source.Contains($word) | Should -BeFalse -Because $word
        }
    }
}

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
