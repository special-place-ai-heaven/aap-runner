# The guest channel (guest-transport.md): every reply is hostile input. Bounded size, printable ASCII, strict JSON, exact
# fields, echoed ids, a state the command can produce; anything else is hostile_guest with a fixed code, the slot goes
# straight to deleting and the VM is destroyed, even when the allocator call fails. The call child is a real hidden
# process in a job object: oversized output, a hang, a memory flood and a grandchild are all cut off. Pester 5, Windows
# PowerShell 5.1 and PowerShell 7.5+.

BeforeAll {
    . (Join-Path $PSScriptRoot 'WinBackendTestHelpers.ps1')
    Import-Module $script:CapModule -Force
    Import-Module $script:BackendModule -Force

    # A world with one reservation probed by a guest that misbehaves on $Cmd as $How; returns the step result.
    function Invoke-WinHostileProbe([string]$How, [string]$Cmd = 'probe') {
        $w = New-WinWorld
        $B = New-WinBackend $w
        $r = New-WinReservation $w
        Set-WinKnob $w @{ Guest = @{ $Cmd = $How } }
        $res = @(Invoke-WinSteps $B $w $r.reservation_id -Max 3)
        [pscustomobject]@{ World = $w; Last = $res[-1]; Res = (Get-WinRes $w $r.reservation_id); Id = $r.reservation_id }
    }

    $script:Cmd = [ordered]@{ vm_id = '6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b'; reservation_id = 'r-1a2b3c4d000000b1'; lease_generation = 3L; seq = 2L
        nonce = '99999999999999999999999999999999'; cmd = 'status'; payload_bytes = 0; expires_at = '2026-10-19T18:02:00Z'
    }
    function New-WinReplyBytes([hashtable]$Change = @{}, [string[]]$Drop = @()) {
        $o = [ordered]@{ schema = 1; kind = 'guest_reply'; vm_id = $script:Cmd.vm_id; reservation_id = $script:Cmd.reservation_id; lease_generation = 3
            seq = 2; nonce = $script:Cmd.nonce; status = 'ok'; guest_state = 'busy'; runner_exit_code = $null; diag = 'fine'
        }
        foreach ($k in $Change.Keys) { $o[$k] = $Change[$k] }
        foreach ($k in $Drop) { $o.Remove($k) }
        $script:Utf8.GetBytes((ConvertTo-Json $o -Compress))
    }
    function Test-WinReply($Raw) { Invoke-WinInModule { param($r, $c) Test-AapWinReply $r $c } @($Raw, $script:Cmd) }
    function New-WinRaw([byte[]]$Bytes, $Exit = 0) { @{ ExitCode = $Exit; Stdout = $Bytes; TimedOut = $false; Overflow = $false } }
}

Describe 'reply checks' {
    It 'accepts the exact reply, with or without one trailing newline' -Tag 'reply-values' {
        (Test-WinReply (New-WinRaw (New-WinReplyBytes))).Kind | Should -Be 'ok'
        (Test-WinReply (New-WinRaw ((New-WinReplyBytes) + [byte[]]@(10)))).Kind | Should -Be 'ok'
        (Test-WinReply (New-WinRaw (New-WinReplyBytes @{ status = 'refused' }))).Kind | Should -Be 'refused'
        (Test-WinReply (New-WinRaw (New-WinReplyBytes @{ runner_exit_code = -1 }))).Kind | Should -Be 'ok'
    }

    It 'times out and no_reply are failures, never hostile' {
        (Test-WinReply @{ ExitCode = $null; Stdout = $null; TimedOut = $true; Overflow = $false }).Kind | Should -Be 'timeout'
        (Test-WinReply (New-WinRaw ([byte[]]@()))).Kind | Should -Be 'no_reply'
        (Test-WinReply $null).Kind | Should -Be 'no_reply'
    }

    It 'over 8192 bytes or an overflowing read is oversized_reply' -Tag 'reply-size' {
        $big = New-WinReplyBytes @{ diag = 'x' * 512 }
        $pad = New-Object byte[] (8193 - $big.Length); for ($i = 0; $i -lt $pad.Length; $i++) { $pad[$i] = 32 }
        (Test-WinReply (New-WinRaw ($big + $pad))).Code | Should -Be 'oversized_reply'
        (Test-WinReply (New-WinRaw ($big + $pad[0..($pad.Length - 2)]))).Kind | Should -Be 'ok'   # exactly 8192 bytes (trailing JSON whitespace): in bound
        (Test-WinReply @{ ExitCode = $null; Stdout = $null; TimedOut = $false; Overflow = $true }).Code | Should -Be 'oversized_reply'
    }

    It 'a non-zero child exit is child_exit' -Tag 'child-exit' {
        (Test-WinReply (New-WinRaw (New-WinReplyBytes) 4)).Code | Should -Be 'child_exit'
        (Test-WinReply (New-WinRaw (New-WinReplyBytes) $null)).Code | Should -Be 'child_exit'
    }

    It 'a control byte, a newline inside or a non-ASCII byte is non_printable' -Tag 'printable' {
        foreach ($b in 7, 9, 10, 13, 127, 0xc3) {
            $x = New-WinReplyBytes @{ diag = 'aZb' }
            $x[[Array]::IndexOf($x, [byte][char]'Z')] = $b
            (Test-WinReply (New-WinRaw $x)).Code | Should -Be 'non_printable' -Because "byte $b"
        }
    }

    It 'not one strict JSON object is bad_json (truncated, duplicate key, too deep, an array, a unicode escape)' -Tag 'reply-json' {
        foreach ($t in @('{"schema":1', '[1]', '{"schema":1,"schema":1}', '{"a":{"b":{"c":{"d":{"e":1}}}}}', '{"diag":"\u0041"}', 'null')) {
            (Test-WinReply (New-WinRaw ($script:Utf8.GetBytes($t)))).Code | Should -Be 'bad_json' -Because $t
        }
    }

    It 'a missing or an extra field is extra_fields' -Tag 'reply-fields' {
        (Test-WinReply (New-WinRaw (New-WinReplyBytes @{ command = 'whoami' }))).Code | Should -Be 'extra_fields'
        (Test-WinReply (New-WinRaw (New-WinReplyBytes -Drop 'diag'))).Code | Should -Be 'extra_fields'
        (Test-WinReply (New-WinRaw (New-WinReplyBytes @{ Diag = 'case' } -Drop 'diag'))).Code | Should -Be 'extra_fields'
    }

    It 'a wrong type or value is bad_value' -Tag 'reply-values' {
        foreach ($c in @(@{ schema = 2 }, @{ kind = 'host_cmd' }, @{ status = 'maybe' }, @{ guest_state = 'hacked' }, @{ seq = '2' }, @{ runner_exit_code = 'zero' },
                @{ runner_exit_code = 4294967296 }, @{ diag = 'd' * 513 }, @{ vm_id = 'NOT-A-GUID' }, @{ nonce = 'short' }, @{ lease_generation = 3.5 })) {
            (Test-WinReply (New-WinRaw (New-WinReplyBytes $c))).Code | Should -Be 'bad_value' -Because ($c.Keys -join ',')
        }
    }

    It 'every echoed id must be this command''s own: wrong_echo' -Tag 'reply-echo' {
        foreach ($c in @(@{ vm_id = '00000000-0000-4000-8000-000000000001' }, @{ reservation_id = 'r-00000000000000ff' }, @{ lease_generation = 4 }, @{ seq = 1 }, @{ nonce = 'a' * 32 })) {
            (Test-WinReply (New-WinRaw (New-WinReplyBytes $c))).Code | Should -Be 'wrong_echo' -Because ($c.Keys -join ',')
        }
    }

    It 'a token-shaped diag is secret_value, never kept' -Tag 'reply-secret' {
        # Synthetic shapes, built at run time (no key-shaped literal in the repository).
        foreach ($d in @('SYNTHETIC-JIT-MARKER-1', ('ghs_' + 'A' * 30), (('-' * 5) + 'BEGIN RSA PRIVATE KEY' + ('-' * 5)))) {
            (Test-WinReply (New-WinRaw (New-WinReplyBytes @{ diag = $d }))).Code | Should -Be 'secret_value'
        }
    }

    It 'a state the command cannot produce is bad_state' -Tag 'reply-state' {
        (Test-WinReply (New-WinRaw (New-WinReplyBytes @{ guest_state = 'booting' }))).Code | Should -Be 'bad_state'
        (Test-WinReply (New-WinRaw (New-WinReplyBytes @{ guest_state = 'job_done' }))).Kind | Should -Be 'ok'
    }
}

Describe 'a hostile guest is final' {
    It 'misbehaviour <How> on <Cmd> gives hostile_guest <Code>: slot to deleting, VM destroyed, fixed reason' -Tag 'reply-size', 'printable', 'reply-json', 'reply-fields', 'reply-values', 'reply-echo', 'reply-secret', 'reply-state', 'child-exit' -ForEach @(
        @{ How = 'oversized'; Cmd = 'probe'; Code = 'oversized_reply' }, @{ How = 'overflow'; Cmd = 'probe'; Code = 'oversized_reply' }
        @{ How = 'extra'; Cmd = 'probe'; Code = 'extra_fields' }, @{ How = 'missing'; Cmd = 'probe'; Code = 'extra_fields' }
        @{ How = 'echo-seq'; Cmd = 'probe'; Code = 'wrong_echo' }, @{ How = 'echo-nonce'; Cmd = 'probe'; Code = 'wrong_echo' }
        @{ How = 'echo-vm_id'; Cmd = 'probe'; Code = 'wrong_echo' }, @{ How = 'echo-lease_generation'; Cmd = 'probe'; Code = 'wrong_echo' }
        @{ How = 'nonprintable'; Cmd = 'probe'; Code = 'non_printable' }, @{ How = 'hostui'; Cmd = 'probe'; Code = 'non_printable' }
        @{ How = 'badjson'; Cmd = 'probe'; Code = 'bad_json' }, @{ How = 'dupkey'; Cmd = 'probe'; Code = 'bad_json' }, @{ How = 'nested'; Cmd = 'probe'; Code = 'bad_json' }
        @{ How = 'badvalue'; Cmd = 'probe'; Code = 'bad_value' }, @{ How = 'state'; Cmd = 'probe'; Code = 'bad_state' }
        @{ How = 'secret'; Cmd = 'probe'; Code = 'secret_value' }, @{ How = 'exit'; Cmd = 'probe'; Code = 'child_exit' }
        @{ How = 'extra'; Cmd = 'deliver_registration'; Code = 'extra_fields' }, @{ How = 'echo-seq'; Cmd = 'start_runner'; Code = 'wrong_echo' }
        @{ How = 'oversized'; Cmd = 'status'; Code = 'oversized_reply' }, @{ How = 'exit'; Cmd = 'collect'; Code = 'child_exit' }
    ) {
        $w = New-WinWorld
        $B = New-WinBackend $w
        $r = New-WinReservation $w
        $rid = $r.reservation_id
        Set-WinKnob $w @{ Guest = @{ $Cmd = $How }; RunnerStatus = $(if ($Cmd -eq 'collect') { 'absent' } else { 'online' }) }
        $res = @(Invoke-WinSteps $B $w $rid -Max 8)
        $last = $res[-1]
        $last.Code | Should -Be $Code
        $last.Action | Should -Be 'destroyed'
        (Get-WinRes $w $rid).state | Should -Be 'reconciled'
        @(Get-WinVms $w).Count | Should -Be 0
        Test-Path -LiteralPath (Join-Path $w.Clones $rid) | Should -BeFalse
        $h = @(Get-WinJournal $w $rid | Where-Object { $_.result -and $_.result.code -eq 'hostile_guest' })
        $h.Count | Should -Be 1
        $h[0].result.detail | Should -Be $Code
        # The allocator recorded the fixed code, never guest text.
        $log = [IO.File]::ReadAllText((Join-Path $w.Cap 'allocator.log'))
        $log | Should -Match "->deleting hostile_guest $Code"
        $log | Should -Not -Match 'SYNTHETIC|remote host call|ESCMARK|refused by the agent'
        # Issued leases are released at teardown.
        @(Get-WinLeases $w | Where-Object { $_.state -eq 'issued' }).Count | Should -Be 0
    }

    It 'timeout and silence are failed guests: probing goes on until the boot deadline' {
        foreach ($how in 'timeout', 'silent') {
            $x = Invoke-WinHostileProbe $how
            $x.Last.Action | Should -Be 'probing'
            $x.Last.Code | Should -BeIn @('timeout', 'no_reply')
            $x.Res.state | Should -Be 'creating'
            @(Get-WinVms $x.World).Count | Should -Be 1
        }
    }

    It 'a refused probe is not hostile: the VM is destroyed as a failed create, never registered' {
        $x = Invoke-WinHostileProbe 'refuse'
        $x.Last.Action | Should -Be 'destroyed'
        $x.Res.teardown_proof.runner_deregistered | Should -Be 'never_registered'
        @(Get-WinJournal $x.World $x.Id | Where-Object { $_.result -and $_.result.code -eq 'hostile_guest' }).Count | Should -Be 0
    }

    It 'the VM is destroyed even when the allocator call fails; the next step finishes the slot' -Tag 'hostile-final' {
        $w = New-WinWorld
        $B = New-WinBackend $w
        $B.AllocArgs.LockTimeoutSeconds = 1
        $r = New-WinReservation $w
        $rid = $r.reservation_id
        [void](Invoke-WinSteps $B $w $rid -Max 2)   # created, booted
        Set-WinKnob $w @{ Guest = @{ probe = 'extra' } }
        $res = Get-WinRes $w $rid
        $lock = [IO.File]::Open((Join-Path $w.Cap 'allocator.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            $s = Invoke-AapWinStep -Backend $B -Reservation $res
        } finally { $lock.Dispose() }
        $s.Code | Should -Be 'extra_fields'
        @(Get-WinVms $w).Count | Should -Be 0
        Test-Path -LiteralPath (Join-Path $w.Clones $rid) | Should -BeFalse
        (Get-WinRes $w $rid).state | Should -Be 'creating'
        # The journal says hostile: the next step only goes down.
        Set-WinKnob $w @{ Guest = $null }
        $s = Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid)
        (Get-WinRes $w $rid).state | Should -Be 'reconciled'
        (Get-WinRes $w $rid).teardown_proof.runner_deregistered | Should -Be 'never_registered'
    }

    It 'a hostile reply in a heartbeat quarantine rewrites the kind and destroys' -Tag 'hostile-final' {
        $w = New-WinWorld
        $B = New-WinBackend $w
        $r = New-WinReservation $w
        $rid = $r.reservation_id
        [void](Invoke-WinSteps $B $w $rid -Max 5 -Until { param($x) $x.state -eq 'ready' })
        [void](Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid))
        [void](Set-AapSlotState -Root $w.Cap -ReservationId $rid -LeaseGeneration $r.lease_generation -State quarantined -QuarantineKind heartbeat -Reason 'test' -RelaxedTrustForTests)
        Set-WinKnob $w @{ Guest = @{ status = 'echo-nonce' } }
        $s = Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid)
        $s.Code | Should -Be 'wrong_echo'
        (Get-WinRes $w $rid).state | Should -Be 'reconciled'
        (Get-WinRes $w $rid).teardown_proof.runner_deregistered | Should -BeTrue
    }
}

Describe 'the capped call child' {
    BeforeAll {
        $script:Kids = Join-Path $TestDrive 'kids'
        [void][IO.Directory]::CreateDirectory($script:Kids)
        $script:Side = Join-Path $script:Kids 'side.txt'
        # A stand-in for psdirect-call.ps1: reads the four lines and the payload, answers like an agent, and records only
        # lengths, hashes and its own command line.
        [IO.File]::WriteAllText((Join-Path $script:Kids 'echo.ps1'), @"
`$in = [Console]::OpenStandardInput()
function Read-L { `$b = New-Object Collections.Generic.List[byte]; while (`$true) { `$c = `$in.ReadByte(); if (`$c -lt 0 -or `$c -eq 10) { break }; `$b.Add([byte]`$c) }; [Text.Encoding]::ASCII.GetString(`$b.ToArray()) }
`$vm = Read-L; `$user = Read-L; `$pw = Read-L; `$env1 = Read-L
`$n = [int]([regex]::Match(`$env1, '"payload_bytes":([0-9]+)').Groups[1].Value)
`$p = New-Object byte[] `$n; `$got = 0; while (`$got -lt `$n) { `$got += `$in.Read(`$p, `$got, `$n - `$got) }
`$h = [Security.Cryptography.SHA256]::Create()
`$sha = ([BitConverter]::ToString(`$h.ComputeHash(`$p)) -replace '-', '').ToLowerInvariant()
`$o = ConvertFrom-Json `$env1
[IO.File]::WriteAllText('$($script:Side)', "vmlen=`$(`$vm.Length) pwlen=`$(`$pw.Length) user=`$user payload=`$sha cmdline=`$([Environment]::CommandLine) modpath=`$(`$env:PSModulePath)")
`$r = '{"schema":1,"kind":"guest_reply","vm_id":"' + `$o.vm_id + '","reservation_id":"' + `$o.reservation_id + '","lease_generation":' + `$o.lease_generation + ',"seq":' + `$o.seq + ',"nonce":"' + `$o.nonce + '","status":"ok","guest_state":"registered","runner_exit_code":null,"diag":"ok"}'
[Console]::Out.Write(`$r)
"@)
        [IO.File]::WriteAllText((Join-Path $script:Kids 'flood.ps1'), "[Console]::Out.Write('x' * 20000)")
        [IO.File]::WriteAllText((Join-Path $script:Kids 'hang.ps1'), 'Start-Sleep -Seconds 600')
        [IO.File]::WriteAllText((Join-Path $script:Kids 'exit.ps1'), 'exit 3')
        [IO.File]::WriteAllText((Join-Path $script:Kids 'hog.ps1'), "`$ErrorActionPreference = 'Stop'; `$l = New-Object Collections.Generic.List[object]; for (`$i = 0; `$i -lt 40; `$i++) { `$l.Add((New-Object byte[] 50MB)) }; [IO.File]::WriteAllText('$($script:Side)', 'allocated'); [Console]::Out.Write('x')")
        [IO.File]::WriteAllText((Join-Path $script:Kids 'spawn.ps1'), @"
`$psi = New-Object Diagnostics.ProcessStartInfo 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe', '-NoProfile -NonInteractive -Command Start-Sleep -Seconds 300'
`$psi.UseShellExecute = `$false; `$psi.CreateNoWindow = `$true
`$c = [Diagnostics.Process]::Start(`$psi)
[IO.File]::WriteAllText('$($script:Side)', [string]`$c.Id)
Start-Sleep -Seconds 600
"@)
        $script:Saved = Get-WinModuleVar 'ChildScript'
        function Invoke-WinChild([string]$Kid, [int]$Timeout = 5, $Jit = $null) {
            Set-WinModuleVar 'ChildScript' (Join-Path $script:Kids $Kid)
            if (Test-Path $script:Side) { Remove-Item $script:Side }
            $env1 = '{"schema":1,"kind":"host_cmd","vm_id":"6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b","reservation_id":"r-1a2b3c4d000000b1","lease_generation":3,"seq":2,"nonce":"99999999999999999999999999999999","cmd":"deliver_registration","payload_bytes":' + $(if ($Jit) { $Jit.Length } else { 0 }) + ',"expires_at":"2026-10-19T18:02:00Z"}'
            $call = @{ VmId = '6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b'; User = 'runneradmin'; Password = $script:Pw; Envelope = $env1; PayloadLength = $(if ($Jit) { $Jit.Length } else { 0 }); TimeoutSeconds = $Timeout
                WritePayload = { param($s) $s.Write($Jit, 0, $Jit.Length) }.GetNewClosure()
            }
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $raw = Invoke-WinInModule { param($c) Invoke-AapWinGuestChild $c } @($call)
            $sw.Stop()
            [pscustomobject]@{ Raw = $raw; Seconds = $sw.Elapsed.TotalSeconds }
        }
        $script:Pw = Invoke-WinInModule { New-AapWinPassword }
    }
    AfterAll { Set-WinModuleVar 'ChildScript' $script:Saved }

    It 'hands the four lines and the payload over stdin only, with the machine PSModulePath' {
        $jit = [Text.Encoding]::ASCII.GetBytes('SYNTHETIC-JIT-MARKER-' + [guid]::NewGuid().ToString('n'))
        $c = Invoke-WinChild 'echo.ps1' 5 $jit
        $c.Raw.ExitCode | Should -Be 0
        (Test-WinReply $c.Raw).Code | Should -Be 'bad_state'   # parsed and echoed; 'registered' does not answer a status command
        $side = [IO.File]::ReadAllText($script:Side)
        $side | Should -Match "pwlen=32 user=runneradmin payload=$(Get-WinSha $jit) "
        $side | Should -Not -Match 'SYNTHETIC|host_cmd|6f1d2c3b'
        $side.Contains($script:Pw) | Should -BeFalse
        # The supervisor passes the machine value; Windows PowerShell itself prepends the user's own module folder at start,
        # which psdirect-call.ps1 drops again. Nothing of this process's PSModulePath beyond the machine value is inherited.
        $machine = [Environment]::GetEnvironmentVariable('PSModulePath', 'Machine')
        $mod = [regex]::Match($side, 'modpath=(.*)$').Groups[1].Value
        $mod.EndsWith($machine) | Should -BeTrue
        foreach ($p in @($env:PSModulePath -split ';' | Where-Object { $_ -and ($machine -split ';') -notcontains $_ -and $_ -notlike '*\Documents\WindowsPowerShell\Modules' })) { $mod | Should -Not -BeLike "*$p*" }
    }

    It 'stdin arrives byte-exact under the <Name> console input encoding (no preamble)' -Tag 'stdin-bom' -ForEach @(
        @{ Name = 'current'; Cp = 0 }, @{ Name = '65001'; Cp = 65001 }, @{ Name = '850'; Cp = 850 }
    ) {
        try { $saved = [Console]::InputEncoding } catch { Set-ItResult -Skipped -Because 'this host has no console'; return }
        try {
            if ($Cp -ne 0) { [Console]::InputEncoding = [Text.Encoding]::GetEncoding($Cp) }
            $jit = [Text.Encoding]::ASCII.GetBytes('SYNTHETIC-JIT-MARKER-' + [guid]::NewGuid().ToString('n'))
            $c = Invoke-WinChild 'echo.ps1' 5 $jit
        } finally { [Console]::InputEncoding = $saved }
        $c.Raw.ExitCode | Should -Be 0
        [IO.File]::ReadAllText($script:Side) | Should -Match "^vmlen=36 pwlen=32 user=runneradmin payload=$(Get-WinSha $jit) "
    }

    It 'stops reading at 8193 bytes and kills the child: Overflow' -Tag 'child-cap' {
        $c = Invoke-WinChild 'flood.ps1'
        $c.Raw.Overflow | Should -BeTrue
        $c.Raw.Stdout | Should -BeNullOrEmpty
    }

    It 'kills a hung child at its wall cap (timeout + 10 s): TimedOut' {
        $c = Invoke-WinChild 'hang.ps1' 1
        $c.Raw.TimedOut | Should -BeTrue
        $c.Seconds | Should -BeLessThan 30
    }

    It 'a memory flood is cut by the job object, never reaching the supervisor' {
        [IO.File]::WriteAllText((Join-Path $script:Kids 'small.ps1'), (Get-Content -Raw (Join-Path $script:Kids 'hog.ps1')).Replace('-lt 40', '-lt 2'))
        $c = Invoke-WinChild 'small.ps1' 20   # the control: 100 MB fits under the cap
        $c.Raw.ExitCode | Should -Be 0
        Test-Path $script:Side | Should -BeTrue
        $c = Invoke-WinChild 'hog.ps1' 20
        $c.Raw.ExitCode | Should -Not -Be 0
        Test-Path $script:Side | Should -BeFalse
        (Test-WinReply $c.Raw).Code | Should -Be 'child_exit'
    }

    It 'kill on close: a process the child started dies with it' {
        $c = Invoke-WinChild 'spawn.ps1' 1
        $c.Raw.TimedOut | Should -BeTrue
        $grand = [int][IO.File]::ReadAllText($script:Side)
        Start-Sleep -Milliseconds 500
        Get-Process -Id $grand -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'an exit code reaches the check as child_exit' {
        $c = Invoke-WinChild 'exit.ps1'
        $c.Raw.ExitCode | Should -Be 3
        (Test-WinReply $c.Raw).Code | Should -Be 'child_exit'
    }

    It 'the real psdirect-call.ps1 refuses a malformed stdin with exit 2, before any session is opened' {
        # Only the input checks run: no PowerShell Direct session is attempted (no Hyper-V call in this suite).
        Set-WinModuleVar 'ChildScript' $script:Saved
        foreach ($bad in @(@{ VmId = 'not-a-guid'; Envelope = '{"payload_bytes":0}' }, @{ VmId = [guid]::NewGuid().ToString(); Envelope = '{"payload_bytes":99999}' }, @{ VmId = [guid]::NewGuid().ToString(); Envelope = '{}' })) {
            $raw = Invoke-WinInModule { param($c) Invoke-AapWinGuestChild $c } @(@{ VmId = $bad.VmId; User = 'runneradmin'; Password = $script:Pw; Envelope = $bad.Envelope; PayloadLength = 0; TimeoutSeconds = 30 })
            $raw.ExitCode | Should -Be 2
            (Test-WinReply $raw).Code | Should -Be 'child_exit'
        }
    }
}
