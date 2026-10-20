# The guest channel (guest-transport.md): every reply is hostile input. Bounded size, printable ASCII, strict JSON, exact
# fields, echoed ids, a state the command can produce; anything else is hostile_guest with a fixed code, the slot goes
# straight to deleting and the VM is destroyed, even when the allocator call fails. ssh.exe's own failure (exit 255) is a
# failed guest, never a hostile one. The call child is a real hidden process in a job object (a stand-in for ssh.exe):
# oversized output, a hang, a memory flood and a grandchild are all cut off, and its stdin is byte-exact. The per-clone
# ssh_config is hardened as guest-transport.md lists, and the hvsocket relay takes nothing but a VM id. Pester 5, Windows
# PowerShell 5.1 and PowerShell 7.5+.

BeforeAll {
    . (Join-Path $PSScriptRoot 'LinBackendTestHelpers.ps1')
    Import-Module $script:CapModule -Force
    Import-Module $script:BackendModule -Force

    $script:Cmd = [ordered]@{ vm_id = '6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b'; reservation_id = 'r-1a2b3c4d000000b1'; lease_generation = 3L; seq = 2L
        nonce = '99999999999999999999999999999999'; cmd = 'status'; payload_bytes = 0; expires_at = '2026-10-19T18:02:00Z'
    }
    function New-LinReplyBytes([hashtable]$Change = @{}, [string[]]$Drop = @()) {
        $o = [ordered]@{ schema = 1; kind = 'guest_reply'; vm_id = $script:Cmd.vm_id; reservation_id = $script:Cmd.reservation_id; lease_generation = 3
            seq = 2; nonce = $script:Cmd.nonce; status = 'ok'; guest_state = 'busy'; runner_exit_code = $null; diag = 'fine'
        }
        foreach ($k in $Change.Keys) { $o[$k] = $Change[$k] }
        foreach ($k in $Drop) { $o.Remove($k) }
        $script:Utf8.GetBytes((ConvertTo-Json $o -Compress))
    }
    function Test-LinReply($Raw) { Invoke-LinInModule { param($r, $c) Test-AapLinReply $r $c } @($Raw, $script:Cmd) }
    function New-LinRaw([byte[]]$Bytes, $Exit = 0) { @{ ExitCode = $Exit; Stdout = $Bytes; TimedOut = $false; Overflow = $false } }
}

Describe 'reply checks' {
    It 'accepts the exact reply, with or without one trailing newline' -Tag 'reply-values' {
        (Test-LinReply (New-LinRaw (New-LinReplyBytes))).Kind | Should -Be 'ok'
        (Test-LinReply (New-LinRaw ((New-LinReplyBytes) + [byte[]]@(10)))).Kind | Should -Be 'ok'
        (Test-LinReply (New-LinRaw (New-LinReplyBytes @{ status = 'refused' }))).Kind | Should -Be 'refused'
        (Test-LinReply (New-LinRaw (New-LinReplyBytes @{ runner_exit_code = -1 }))).Kind | Should -Be 'ok'
    }

    It 'a timeout, no reply and ssh.exe''s own failure (exit 255, whatever it printed) are failed guests, never hostile' -Tag 'transport-drop' {
        (Test-LinReply @{ ExitCode = $null; Stdout = $null; TimedOut = $true; Overflow = $false }).Kind | Should -Be 'timeout'
        (Test-LinReply (New-LinRaw ([byte[]]@()))).Kind | Should -Be 'no_reply'
        (Test-LinReply $null).Kind | Should -Be 'no_reply'
        (Test-LinReply (New-LinRaw ([byte[]]@()) 255)).Kind | Should -Be 'no_reply'
        (Test-LinReply (New-LinRaw ($script:Utf8.GetBytes('{"schema":1,"ki')) 255)).Kind | Should -Be 'no_reply'
        (Test-LinReply (New-LinRaw (New-LinReplyBytes) 255)).Kind | Should -Be 'no_reply'
    }

    It 'over 8192 bytes or an overflowing read is oversized_reply' -Tag 'reply-size' {
        $big = New-LinReplyBytes @{ diag = 'x' * 512 }
        $pad = New-Object byte[] (8193 - $big.Length); for ($i = 0; $i -lt $pad.Length; $i++) { $pad[$i] = 32 }
        (Test-LinReply (New-LinRaw ($big + $pad))).Code | Should -Be 'oversized_reply'
        (Test-LinReply (New-LinRaw ($big + $pad[0..($pad.Length - 2)]))).Kind | Should -Be 'ok'   # exactly 8192 bytes (trailing JSON whitespace): in bound
        (Test-LinReply @{ ExitCode = $null; Stdout = $null; TimedOut = $false; Overflow = $true }).Code | Should -Be 'oversized_reply'
        (Test-LinReply @{ ExitCode = 255; Stdout = $null; TimedOut = $false; Overflow = $true }).Code | Should -Be 'oversized_reply'
    }

    It 'any other non-zero exit is child_exit (the forced agent broke the contract)' -Tag 'child-exit' {
        (Test-LinReply (New-LinRaw (New-LinReplyBytes) 4)).Code | Should -Be 'child_exit'
        (Test-LinReply (New-LinRaw (New-LinReplyBytes) 1)).Code | Should -Be 'child_exit'
        (Test-LinReply (New-LinRaw (New-LinReplyBytes) $null)).Code | Should -Be 'child_exit'
    }

    It 'a control byte, a newline inside or a non-ASCII byte is non_printable' -Tag 'printable' {
        foreach ($b in 7, 9, 10, 13, 127, 0xc3) {
            $x = New-LinReplyBytes @{ diag = 'aZb' }
            $x[[Array]::IndexOf($x, [byte][char]'Z')] = $b
            (Test-LinReply (New-LinRaw $x)).Code | Should -Be 'non_printable' -Because "byte $b"
        }
    }

    It 'not one strict JSON object is bad_json (truncated, duplicate key, too deep, an array, a unicode escape)' -Tag 'reply-json' {
        foreach ($t in @('{"schema":1', '[1]', '{"schema":1,"schema":1}', '{"a":{"b":{"c":{"d":{"e":1}}}}}', '{"diag":"\u0041"}', 'null')) {
            (Test-LinReply (New-LinRaw ($script:Utf8.GetBytes($t)))).Code | Should -Be 'bad_json' -Because $t
        }
    }

    It 'a missing or an extra field is extra_fields' -Tag 'reply-fields' {
        (Test-LinReply (New-LinRaw (New-LinReplyBytes @{ command = 'id' }))).Code | Should -Be 'extra_fields'
        (Test-LinReply (New-LinRaw (New-LinReplyBytes -Drop 'diag'))).Code | Should -Be 'extra_fields'
        (Test-LinReply (New-LinRaw (New-LinReplyBytes @{ Diag = 'case' } -Drop 'diag'))).Code | Should -Be 'extra_fields'
    }

    It 'a wrong type or value is bad_value' -Tag 'reply-values' {
        foreach ($c in @(@{ schema = 2 }, @{ kind = 'host_cmd' }, @{ status = 'maybe' }, @{ guest_state = 'hacked' }, @{ seq = '2' }, @{ runner_exit_code = 'zero' },
                @{ runner_exit_code = 4294967296 }, @{ diag = 'd' * 513 }, @{ vm_id = 'NOT-A-GUID' }, @{ nonce = 'short' }, @{ lease_generation = 3.5 })) {
            (Test-LinReply (New-LinRaw (New-LinReplyBytes $c))).Code | Should -Be 'bad_value' -Because ($c.Keys -join ',')
        }
    }

    It 'every echoed id must be this command''s own: wrong_echo' -Tag 'reply-echo' {
        foreach ($c in @(@{ vm_id = '00000000-0000-4000-8000-000000000001' }, @{ reservation_id = 'r-00000000000000ff' }, @{ lease_generation = 4 }, @{ seq = 1 }, @{ nonce = 'a' * 32 })) {
            (Test-LinReply (New-LinRaw (New-LinReplyBytes $c))).Code | Should -Be 'wrong_echo' -Because ($c.Keys -join ',')
        }
    }

    It 'a token-shaped diag is secret_value, never kept' -Tag 'reply-secret' {
        # Synthetic shapes, built at run time (no key-shaped literal in the repository).
        foreach ($d in @('SYNTHETIC-JIT-MARKER-1', ('ghs_' + 'A' * 30), (('-' * 5) + 'BEGIN OPENSSH PRIVATE KEY' + ('-' * 5)))) {
            (Test-LinReply (New-LinRaw (New-LinReplyBytes @{ diag = $d }))).Code | Should -Be 'secret_value'
        }
    }

    It 'a state the command cannot produce is bad_state' -Tag 'reply-state' {
        (Test-LinReply (New-LinRaw (New-LinReplyBytes @{ guest_state = 'booting' }))).Code | Should -Be 'bad_state'
        (Test-LinReply (New-LinRaw (New-LinReplyBytes @{ guest_state = 'job_done' }))).Kind | Should -Be 'ok'
    }
}

Describe 'the JIT config' {
    It 'is cleared once run_one is done with it' -Tag 'jit-clear' {
        $w = New-LinWorld
        $guest = New-LinGuest
        $held = New-Object Collections.Generic.List[object]
        $spy = { param($Call) if ($Call.PayloadLength -gt 0) { $held.Add($Call.WritePayload) }; & $guest $Call }.GetNewClosure()
        $B = New-AapLinBackend -Provider (New-LinProvider) -Network (New-LinNetwork) -Transport $spy -BrokerInvoker (New-LinBroker) -AllocatorRoot $w.Cap `
            -JournalRoot $w.Journal -StoragePath $w.StoragePath -LockTimeoutSeconds 5 -RelaxedTrustForTests -WarningAction SilentlyContinue -Sleep { param($s) }
        $r = New-LinReservation $w
        [void](Invoke-LinSteps $B $w $r.reservation_id -Max 5 -Until { param($x) $x.state -eq 'ready' })
        (Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $r.reservation_id)).Action | Should -Be 'running'
        $held.Count | Should -Be 1
        $ms = New-Object IO.MemoryStream
        & $held[0] $ms
        $bytes = $ms.ToArray()
        $bytes.Length | Should -BeGreaterThan 20
        @($bytes | Where-Object { $_ -ne 0 }).Count | Should -Be 0
    }
}

Describe 'a hostile guest is final' {
    It 'misbehaviour <How> on <Cmd> gives hostile_guest <Code>: slot to deleting, VM destroyed, fixed reason' -Tag 'reply-size', 'printable', 'reply-json', 'reply-fields', 'reply-values', 'reply-echo', 'reply-secret', 'reply-state', 'child-exit' -ForEach @(
        @{ How = 'oversized'; Cmd = 'probe'; Code = 'oversized_reply' }, @{ How = 'overflow'; Cmd = 'probe'; Code = 'oversized_reply' }
        @{ How = 'extra'; Cmd = 'probe'; Code = 'extra_fields' }, @{ How = 'missing'; Cmd = 'probe'; Code = 'extra_fields' }
        @{ How = 'echo-seq'; Cmd = 'probe'; Code = 'wrong_echo' }, @{ How = 'echo-nonce'; Cmd = 'probe'; Code = 'wrong_echo' }
        @{ How = 'echo-vm_id'; Cmd = 'probe'; Code = 'wrong_echo' }, @{ How = 'echo-lease_generation'; Cmd = 'probe'; Code = 'wrong_echo' }
        @{ How = 'nonprintable'; Cmd = 'probe'; Code = 'non_printable' }, @{ How = 'banner'; Cmd = 'probe'; Code = 'non_printable' }
        @{ How = 'badjson'; Cmd = 'probe'; Code = 'bad_json' }, @{ How = 'dupkey'; Cmd = 'probe'; Code = 'bad_json' }, @{ How = 'nested'; Cmd = 'probe'; Code = 'bad_json' }
        @{ How = 'badvalue'; Cmd = 'probe'; Code = 'bad_value' }, @{ How = 'state'; Cmd = 'probe'; Code = 'bad_state' }
        @{ How = 'secret'; Cmd = 'probe'; Code = 'secret_value' }, @{ How = 'exit'; Cmd = 'probe'; Code = 'child_exit' }
        @{ How = 'extra'; Cmd = 'deliver_registration'; Code = 'extra_fields' }, @{ How = 'echo-seq'; Cmd = 'start_runner'; Code = 'wrong_echo' }
        @{ How = 'oversized'; Cmd = 'status'; Code = 'oversized_reply' }, @{ How = 'exit'; Cmd = 'collect'; Code = 'child_exit' }
    ) {
        $w = New-LinWorld
        $B = New-LinBackend $w
        $r = New-LinReservation $w
        $rid = $r.reservation_id
        Set-LinKnob $w @{ Guest = @{ $Cmd = $How }; RunnerStatus = $(if ($Cmd -eq 'collect') { 'absent' } else { 'online' }) }
        $res = @(Invoke-LinSteps $B $w $rid -Max 8)
        $last = $res[-1]
        $last.Code | Should -Be $Code
        $last.Action | Should -Be 'destroyed'
        (Get-LinRes $w $rid).state | Should -Be 'reconciled'
        @(Get-LinVms $w).Count | Should -Be 0
        Test-Path -LiteralPath (Join-Path $w.Clones $rid) | Should -BeFalse
        $h = @(Get-LinJournal $w $rid | Where-Object { $_.result -and $_.result.code -eq 'hostile_guest' })
        $h.Count | Should -Be 1
        $h[0].result.detail | Should -Be $Code
        # The allocator recorded the fixed code, never guest text.
        $log = [IO.File]::ReadAllText((Join-Path $w.Cap 'allocator.log'))
        $log | Should -Match "->deleting hostile_guest $Code"
        $log | Should -Not -Match 'SYNTHETIC|Welcome|ESCMARK|refused by the agent'
        # Issued leases are released at teardown.
        @(Get-LinLeases $w | Where-Object { $_.state -eq 'issued' }).Count | Should -Be 0
    }

    It 'a host key the guest published in the wrong shape is hostile (bad_host_key); nothing is sent to it' -Tag 'host-key' {
        foreach ($bad in @('ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQ', ('ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI' + 'A' * 43 + ' trailing'), "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI$('A' * 42)`n")) {
            $w = New-LinWorld
            $B = New-LinBackend $w
            Set-LinKnob $w @{ HostKeyOverride = $bad }
            $r = New-LinReservation $w
            $res = @(Invoke-LinSteps $B $w $r.reservation_id -Max 4)
            $res[-1].Code | Should -Be 'bad_host_key'
            (Get-LinRes $w $r.reservation_id).state | Should -Be 'reconciled'
            @(Get-ChildItem -LiteralPath (Join-Path $w.Fake 'exchanges')).Count | Should -Be 0
            @(Get-ChildItem -LiteralPath (Join-Path $w.Fake 'guests')).Count | Should -Be 0
        }
    }

    It 'a guest whose host key changed after the pin is never talked to: ssh refuses it, a failed guest until the deadline' {
        $w = New-LinWorld
        $B = New-LinBackend $w
        Set-LinKnob $w @{ BootProbes = 1 }
        $r = New-LinReservation $w
        $rid = $r.reservation_id
        @(Invoke-LinSteps $B $w $rid -Max 3 | ForEach-Object { $_.Action }) -join ',' | Should -Be 'created,booted,probing'
        $vms = @(Get-LinVms $w); $vms[0].HostKey = Get-LinPublicOf ([guid]::NewGuid().ToByteArray()); Save-LinVms $w $vms   # guest root replaced sshd's key
        $s = Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid)
        $s.Action | Should -Be 'probing'
        $s.Code | Should -Be 'no_reply'
        @(Get-LinCalls $w 'GuestHostKeyRefused *').Count | Should -Be 1
    }

    It 'timeout, silence and ssh failures are failed guests: probing goes on until the boot deadline' -Tag 'transport-drop' {
        foreach ($how in 'timeout', 'silent', 'drop') {
            $w = New-LinWorld
            $B = New-LinBackend $w
            $r = New-LinReservation $w
            Set-LinKnob $w @{ Guest = @{ probe = $how } }
            $res = @(Invoke-LinSteps $B $w $r.reservation_id -Max 3)
            $res[-1].Action | Should -Be 'probing' -Because $how
            $res[-1].Code | Should -BeIn @('timeout', 'no_reply')
            (Get-LinRes $w $r.reservation_id).state | Should -Be 'creating'
            @(Get-LinVms $w).Count | Should -Be 1
        }
    }

    It 'a refused probe is not hostile: the VM is destroyed as a failed create, never registered' {
        $w = New-LinWorld
        $B = New-LinBackend $w
        $r = New-LinReservation $w
        Set-LinKnob $w @{ Guest = @{ probe = 'refuse' } }
        $res = @(Invoke-LinSteps $B $w $r.reservation_id -Max 3)
        $res[-1].Action | Should -Be 'destroyed'
        (Get-LinRes $w $r.reservation_id).teardown_proof.runner_deregistered | Should -Be 'never_registered'
        @(Get-LinJournal $w $r.reservation_id | Where-Object { $_.result -and $_.result.code -eq 'hostile_guest' }).Count | Should -Be 0
    }

    It 'the VM is destroyed even when the allocator call fails; the next step finishes the slot' -Tag 'hostile-final' {
        $w = New-LinWorld
        $B = New-LinBackend $w
        $B.AllocArgs.LockTimeoutSeconds = 1
        $r = New-LinReservation $w
        $rid = $r.reservation_id
        [void](Invoke-LinSteps $B $w $rid -Max 2)   # created, booted
        Set-LinKnob $w @{ Guest = @{ probe = 'extra' } }
        $res = Get-LinRes $w $rid
        $lock = [IO.File]::Open((Join-Path $w.Cap 'allocator.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            $s = Invoke-AapLinStep -Backend $B -Reservation $res
        } finally { $lock.Dispose() }
        $s.Code | Should -Be 'extra_fields'
        @(Get-LinVms $w).Count | Should -Be 0
        Test-Path -LiteralPath (Join-Path $w.Clones $rid) | Should -BeFalse
        (Get-LinRes $w $rid).state | Should -Be 'creating'
        # The journal says hostile: the next step only goes down.
        Set-LinKnob $w @{ Guest = $null }
        $s = Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid)
        (Get-LinRes $w $rid).state | Should -Be 'reconciled'
        (Get-LinRes $w $rid).teardown_proof.runner_deregistered | Should -Be 'never_registered'
    }

    It 'a hostile reply in a heartbeat quarantine rewrites the kind and destroys' -Tag 'hostile-final' {
        $w = New-LinWorld
        $B = New-LinBackend $w
        $r = New-LinReservation $w
        $rid = $r.reservation_id
        [void](Invoke-LinSteps $B $w $rid -Max 5 -Until { param($x) $x.state -eq 'ready' })
        [void](Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid))
        [void](Set-AapSlotState -Root $w.Cap -ReservationId $rid -LeaseGeneration $r.lease_generation -State quarantined -QuarantineKind heartbeat -Reason 'test' -RelaxedTrustForTests)
        Set-LinKnob $w @{ Guest = @{ status = 'echo-nonce' } }
        $s = Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid)
        $s.Code | Should -Be 'wrong_echo'
        (Get-LinRes $w $rid).state | Should -Be 'reconciled'
        (Get-LinRes $w $rid).teardown_proof.runner_deregistered | Should -BeTrue
    }

    It 'no command is ever sent before the host key is pinned, nor through a channel folder that is a link' -Tag 'pin-first' {
        $w = New-LinWorld
        $B = New-LinBackend $w
        $r = New-LinReservation $w
        $rid = $r.reservation_id
        [void](Invoke-LinSteps $B $w $rid -Max 2)   # created, booted: not pinned yet
        $v = Invoke-LinInModule { param($B, $r) Invoke-AapLinCommand $B $r 'probe' } @($B, (Get-LinRes $w $rid))
        $v.Kind | Should -Be 'no_reply'
        $v.Code | Should -Be 'channel_unusable'
        @(Get-LinCalls $w 'Guest*').Count | Should -Be 0 -Because 'the transport was never called'
        # Pinned, then the ssh folder is swapped for a junction to a copy: refused before any send.
        [void](Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid))   # pins and probes: ready
        $ssh = Join-Path $w.Clones "$rid\ssh"
        $copy = Join-Path $w.Root 'ssh-copy'
        Copy-Item -LiteralPath $ssh -Destination $copy -Recurse
        [IO.Directory]::Delete($ssh, $true)
        & cmd.exe /c mklink /J $ssh $copy | Out-Null
        $n = @(Get-ChildItem -LiteralPath (Join-Path $w.Fake 'exchanges')).Count
        $v = Invoke-LinInModule { param($B, $r) Invoke-AapLinCommand $B $r 'status' } @($B, (Get-LinRes $w $rid))
        $v.Code | Should -Be 'channel_unusable'
        @(Get-ChildItem -LiteralPath (Join-Path $w.Fake 'exchanges')).Count | Should -Be $n
    }
}

Describe 'the per-clone ssh client configuration' {
    It 'is hardened as guest-transport.md lists, names only this clone''s files and the relay, and expands nothing' -Tag 'ssh-path' {
        $w = New-LinWorld
        $B = New-LinBackend $w
        $r = New-LinReservation $w
        [void](Invoke-AapLinStep -Backend $B -Reservation $r -BaseSha256 $w.BaseSha)
        $dir = Join-Path $w.Clones "$($r.reservation_id)\ssh"
        $vmId = @(Get-LinVms $w)[0].Id
        $cfg = [IO.File]::ReadAllText((Join-Path $dir 'ssh_config'))
        foreach ($line in 'IdentitiesOnly yes', 'IdentityAgent none', 'ForwardAgent no', 'ClearAllForwardings yes', 'PermitLocalCommand no', 'StrictHostKeyChecking yes',
            'BatchMode yes', 'PasswordAuthentication no', 'KbdInteractiveAuthentication no', 'RequestTTY no', 'ForwardX11 no', 'ControlMaster no', 'User root', "HostName $vmId") {
            $cfg | Should -Match ("(?m)^  $([regex]::Escape($line))$")
        }
        $fwd = $dir.Replace('\', '/')
        $cfg | Should -Match ([regex]::Escape("IdentityFile `"$fwd/id_ed25519`""))
        $cfg | Should -Match ([regex]::Escape("UserKnownHostsFile `"$fwd/known_hosts`""))
        $cfg | Should -Match ([regex]::Escape("GlobalKnownHostsFile `"$fwd/known_hosts_global`""))
        $relay = Join-Path (Split-Path -Parent $script:BackendModule) 'hvsock-relay.ps1'
        $cfg | Should -Match ([regex]::Escape("ProxyCommand `"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe`" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$relay`" $vmId"))
        [IO.File]::ReadAllBytes((Join-Path $dir 'known_hosts_global')).Length | Should -Be 0
        { Invoke-LinInModule { param($p) ConvertTo-AapLinSshPath $p } @('C:\x\%d\key') } | Should -Throw '*AAP_UnsafePath*'
        { Invoke-LinInModule { param($p) ConvertTo-AapLinSshPath $p } @('C:\x\"q\key') } | Should -Throw '*AAP_UnsafePath*'
        Invoke-LinInModule { param($p) ConvertTo-AapLinSshPath $p } @('C:\x y\key') | Should -Be 'C:/x y/key'
    }

    It 'the ssh folder is SYSTEM/Administrators-only and protected from its creation (own SID only when unelevated)' -Tag 'own-sid' {
        $w = New-LinWorld
        $B = New-LinBackend $w
        $r = New-LinReservation $w
        [void](Invoke-AapLinStep -Backend $B -Reservation $r -BaseSha256 $w.BaseSha)
        $admin = (New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        $sids = @(@('S-1-5-18', 'S-1-5-32-544') + @($(if (-not $admin) { $script:UserSid })) | Sort-Object -Unique)
        $acl = Get-Acl -LiteralPath (Join-Path $w.Clones "$($r.reservation_id)\ssh")
        $acl.AreAccessRulesProtected | Should -BeTrue
        @($acl.Access | ForEach-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } | Sort-Object -Unique) | Should -Be $sids
        $m = Get-Module AapLinBackend
        (& $m { New-AapLinSecurity $true $true }).GetSecurityDescriptorSddlForm('Access') | Should -BeExactly 'D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)'
        # Not an SDDL string comparison: the SDDL writer renders the built-in Administrator (RID 500, the hosted runner's user)
        # as the alias LA, not as its SID, so compare the protected flag and each ACE's type, SID, mask and flags.
        $sddl = (& $m { New-AapLinSecurity $true $false }).GetSecurityDescriptorSddlForm('Access')
        $raw = New-Object Security.AccessControl.RawSecurityDescriptor $sddl
        ([int]$raw.ControlFlags -band 0x1000) | Should -Be 0x1000
        @($raw.DiscretionaryAcl | ForEach-Object { '{0}|{1}|{2:x}|{3}' -f $_.AceType, $_.SecurityIdentifier.Value, $_.AccessMask, [int]$_.AceFlags }) |
            Should -Be @('AccessAllowed|S-1-5-18|1f01ff|3', 'AccessAllowed|S-1-5-32-544|1f01ff|3', "AccessAllowed|$($script:UserSid)|1f01ff|3")
    }
}

Describe 'the capped call child' {
    BeforeAll {
        $script:Kids = Join-Path $TestDrive 'kids'
        [void][IO.Directory]::CreateDirectory($script:Kids)
        $script:Side = Join-Path $script:Kids 'side.txt'
        # A stand-in for ssh.exe and its forced agent: reads the envelope line and the payload from stdin, answers like an
        # agent, and records only lengths, hashes, its arguments and its module path.
        [IO.File]::WriteAllText((Join-Path $script:Kids 'echo.ps1'), @"
`$in = [Console]::OpenStandardInput()
`$b = New-Object Collections.Generic.List[byte]; while (`$true) { `$c = `$in.ReadByte(); if (`$c -lt 0 -or `$c -eq 10) { break }; `$b.Add([byte]`$c) }
`$env1 = [Text.Encoding]::ASCII.GetString(`$b.ToArray())
`$n = [int]([regex]::Match(`$env1, '"payload_bytes":([0-9]+)').Groups[1].Value)
`$p = New-Object byte[] `$n; `$got = 0; while (`$got -lt `$n) { `$got += `$in.Read(`$p, `$got, `$n - `$got) }
`$extra = `$in.ReadByte()
`$h = [Security.Cryptography.SHA256]::Create()
`$sha = ([BitConverter]::ToString(`$h.ComputeHash(`$p)) -replace '-', '').ToLowerInvariant()
`$o = ConvertFrom-Json `$env1
[IO.File]::WriteAllText('$($script:Side)', "first=`$(if (`$b.Count) { `$b[0] } else { -1 }) envlen=`$(`$env1.Length) payload=`$sha extra=`$extra args=`$(`$args -join '|') modpath=`$(`$env:PSModulePath)")
`$r = '{"schema":1,"kind":"guest_reply","vm_id":"' + `$o.vm_id + '","reservation_id":"' + `$o.reservation_id + '","lease_generation":' + `$o.lease_generation + ',"seq":' + `$o.seq + ',"nonce":"' + `$o.nonce + '","status":"ok","guest_state":"registered","runner_exit_code":null,"diag":"ok"}'
[Console]::Out.Write(`$r)
"@)
        [IO.File]::WriteAllText((Join-Path $script:Kids 'flood.ps1'), "[Console]::Out.Write('x' * 20000)")
        [IO.File]::WriteAllText((Join-Path $script:Kids 'errflood.ps1'), "`$e = [Console]::OpenStandardError(); `$b = New-Object byte[] 65536; for (`$i = 0; `$i -lt 64; `$i++) { `$e.Write(`$b, 0, `$b.Length) }; [Console]::Out.Write('ok')")
        [IO.File]::WriteAllText((Join-Path $script:Kids 'hang.ps1'), 'Start-Sleep -Seconds 600')
        [IO.File]::WriteAllText((Join-Path $script:Kids 'exit.ps1'), 'exit 3')
        [IO.File]::WriteAllText((Join-Path $script:Kids 'sshfail.ps1'), "[Console]::Out.Write('{`"schema`":1,`"ki'); exit 255")
        [IO.File]::WriteAllText((Join-Path $script:Kids 'hog.ps1'), "`$ErrorActionPreference = 'Stop'; `$l = New-Object Collections.Generic.List[object]; for (`$i = 0; `$i -lt 40; `$i++) { `$l.Add((New-Object byte[] 50MB)) }; [IO.File]::WriteAllText('$($script:Side)', 'allocated'); [Console]::Out.Write('x')")
        [IO.File]::WriteAllText((Join-Path $script:Kids 'spawn.ps1'), @"
`$psi = New-Object Diagnostics.ProcessStartInfo 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe', '-NoProfile -NonInteractive -Command Start-Sleep -Seconds 300'
`$psi.UseShellExecute = `$false; `$psi.CreateNoWindow = `$true
`$c = [Diagnostics.Process]::Start(`$psi)
[IO.File]::WriteAllText('$($script:Side)', [string]`$c.Id)
Start-Sleep -Seconds 600
"@)
        $script:SavedExe = Get-LinModuleVar 'ChildExe'
        $script:SavedArgs = Get-LinModuleVar 'ChildArgs'
        function Invoke-LinChild([string]$Kid, [int]$Timeout = 5, $Jit = $null) {
            Set-LinModuleVar 'ChildExe' 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
            Set-LinModuleVar 'ChildArgs' ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + (Join-Path $script:Kids $Kid) + '" "{0}"')
            if (Test-Path $script:Side) { Remove-Item $script:Side }
            $env1 = '{"schema":1,"kind":"host_cmd","vm_id":"6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b","reservation_id":"r-1a2b3c4d000000b1","lease_generation":3,"seq":2,"nonce":"99999999999999999999999999999999","cmd":"deliver_registration","payload_bytes":' + $(if ($Jit) { $Jit.Length } else { 0 }) + ',"expires_at":"2026-10-19T18:02:00Z"}'
            $call = @{ VmId = '6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b'; Config = 'C:\clones\r-1a2b3c4d000000b1\ssh\ssh_config'; Envelope = $env1; PayloadLength = $(if ($Jit) { $Jit.Length } else { 0 }); TimeoutSeconds = $Timeout
                WritePayload = { param($s) $s.Write($Jit, 0, $Jit.Length) }.GetNewClosure()
            }
            $sw = [Diagnostics.Stopwatch]::StartNew()
            try { $raw = Invoke-LinInModule { param($c) Invoke-AapLinGuestChild $c } @($call) }
            finally { Set-LinModuleVar 'ChildExe' $script:SavedExe; Set-LinModuleVar 'ChildArgs' $script:SavedArgs }
            $sw.Stop()
            [pscustomobject]@{ Raw = $raw; Seconds = $sw.Elapsed.TotalSeconds }
        }
        $null = New-LinBackend (New-LinWorld)   # compiles the job object type, as the supervisor does at start
    }

    It 'production starts ssh.exe by absolute path with only the per-clone configuration on its command line' {
        $script:SavedExe | Should -BeExactly 'C:\Windows\System32\OpenSSH\ssh.exe'
        ($script:SavedArgs -f 'C:\clones\r-1\ssh\ssh_config') | Should -BeExactly '-F "C:\clones\r-1\ssh\ssh_config" -T aap-guest'
    }

    It 'hands the envelope and the payload over stdin only, with the machine PSModulePath' {
        $jit = [Text.Encoding]::ASCII.GetBytes('SYNTHETIC-JIT-MARKER-' + [guid]::NewGuid().ToString('n'))
        $c = Invoke-LinChild 'echo.ps1' 5 $jit
        $c.Raw.ExitCode | Should -Be 0
        (Test-LinReply $c.Raw).Code | Should -Be 'bad_state'   # parsed and echoed; 'registered' does not answer a status command
        $side = [IO.File]::ReadAllText($script:Side)
        $side | Should -Match "payload=$(Get-LinSha $jit) extra=-1 args=C:\\clones\\r-1a2b3c4d000000b1\\ssh\\ssh_config modpath="
        $side | Should -Not -Match 'SYNTHETIC|host_cmd|6f1d2c3b'
        $machine = [Environment]::GetEnvironmentVariable('PSModulePath', 'Machine')
        [regex]::Match($side, 'modpath=(.*)$').Groups[1].Value.EndsWith($machine) | Should -BeTrue
    }

    It 'stdin arrives byte-exact under the <Name> console input encoding (no preamble)' -Tag 'stdin-bom' -ForEach @(
        @{ Name = 'current'; Cp = 0 }, @{ Name = '65001'; Cp = 65001 }, @{ Name = '850'; Cp = 850 }
    ) {
        try { $saved = [Console]::InputEncoding } catch { Set-ItResult -Skipped -Because 'this host has no console'; return }
        try {
            if ($Cp -ne 0) { [Console]::InputEncoding = [Text.Encoding]::GetEncoding($Cp) }
            $jit = [Text.Encoding]::ASCII.GetBytes('SYNTHETIC-JIT-MARKER-' + [guid]::NewGuid().ToString('n'))
            $c = Invoke-LinChild 'echo.ps1' 5 $jit
        } finally { [Console]::InputEncoding = $saved }
        $c.Raw.ExitCode | Should -Be 0
        [IO.File]::ReadAllText($script:Side) | Should -Match "^first=123 envlen=\d+ payload=$(Get-LinSha $jit) extra=-1 "
    }

    It 'stops reading at 8193 bytes and kills the child: Overflow' -Tag 'child-cap' {
        $c = Invoke-LinChild 'flood.ps1'
        $c.Raw.Overflow | Should -BeTrue
        $c.Raw.Stdout | Should -BeNullOrEmpty
    }

    It 'drains a stderr flood without keeping it, and still reads the reply' {
        $c = Invoke-LinChild 'errflood.ps1' 20
        $c.Raw.ExitCode | Should -Be 0
        [Text.Encoding]::ASCII.GetString($c.Raw.Stdout) | Should -BeExactly 'ok'
    }

    It 'kills a hung child at its wall cap (timeout + 10 s): TimedOut' {
        $c = Invoke-LinChild 'hang.ps1' 1
        $c.Raw.TimedOut | Should -BeTrue
        $c.Seconds | Should -BeLessThan 30
    }

    It 'a memory flood is cut by the job object, never reaching the supervisor' {
        [IO.File]::WriteAllText((Join-Path $script:Kids 'small.ps1'), (Get-Content -Raw (Join-Path $script:Kids 'hog.ps1')).Replace('-lt 40', '-lt 2'))
        $c = Invoke-LinChild 'small.ps1' 20   # the control: 100 MB fits under the cap
        $c.Raw.ExitCode | Should -Be 0
        Test-Path $script:Side | Should -BeTrue
        $c = Invoke-LinChild 'hog.ps1' 20
        $c.Raw.ExitCode | Should -Not -Be 0
        Test-Path $script:Side | Should -BeFalse
    }

    It 'kill on close: a process the child started dies with it (the relay is ssh.exe''s child)' {
        $c = Invoke-LinChild 'spawn.ps1' 1
        $c.Raw.TimedOut | Should -BeTrue
        $grand = [int][IO.File]::ReadAllText($script:Side)
        Start-Sleep -Milliseconds 500
        Get-Process -Id $grand -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'the exit code reaches the check: 3 is child_exit, ssh.exe''s 255 is a failed guest even with half a reply' -Tag 'transport-drop', 'child-exit' {
        $c = Invoke-LinChild 'exit.ps1'
        $c.Raw.ExitCode | Should -Be 3
        (Test-LinReply $c.Raw).Code | Should -Be 'child_exit'
        $c = Invoke-LinChild 'sshfail.ps1'
        $c.Raw.ExitCode | Should -Be 255
        (Test-LinReply $c.Raw).Kind | Should -Be 'no_reply'
    }

    It 'the backend''s call site turns an ssh failure into probing, never hostile, end to end through the real child' -Tag 'transport-drop' {
        $w = New-LinWorld
        $B = New-AapLinBackend -Provider (New-LinProvider) -Network (New-LinNetwork) -BrokerInvoker (New-LinBroker) -AllocatorRoot $w.Cap -JournalRoot $w.Journal `
            -StoragePath $w.StoragePath -LockTimeoutSeconds 5 -RelaxedTrustForTests -WarningAction SilentlyContinue -Sleep { param($s) }
        $r = New-LinReservation $w
        [void](Invoke-LinSteps $B $w $r.reservation_id -Max 2)   # created, booted
        Set-LinModuleVar 'ChildExe' 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
        Set-LinModuleVar 'ChildArgs' ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + (Join-Path $script:Kids 'sshfail.ps1') + '" "{0}"')
        try { $s = Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $r.reservation_id) } finally { Set-LinModuleVar 'ChildExe' $script:SavedExe; Set-LinModuleVar 'ChildArgs' $script:SavedArgs }
        $s.Action | Should -Be 'probing'
        $s.Code | Should -Be 'no_reply'
        (Get-LinRes $w $r.reservation_id).state | Should -Be 'creating'
        @(Get-LinJournal $w $r.reservation_id | Where-Object { $_.result -and $_.result.code -eq 'hostile_guest' }).Count | Should -Be 0
    }
}

Describe 'the hvsocket relay' {
    BeforeAll { $script:Relay = Join-Path (Split-Path -Parent $script:BackendModule) 'hvsock-relay.ps1' }

    It 'refuses anything but one VM id, before any socket exists: exit 2' -Tag 'relay-args' {
        foreach ($argv in @(@(), @('not-a-guid'), @('6F1D2C3B-4A59-4E6F-8A7B-9C0D1E2F3A4B'), @('x', 'y'), @('6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b;calc'))) {
            $psi = New-Object Diagnostics.ProcessStartInfo 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
            $psi.Arguments = (@('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $script:Relay) + $argv | ForEach-Object { '"' + $_ + '"' }) -join ' '
            $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
            $p = [Diagnostics.Process]::Start($psi)
            $p.StandardInput.Close()
            $null = $p.StandardOutput.ReadToEnd(); $null = $p.StandardError.ReadToEnd()
            if (-not $p.WaitForExit(60000)) { $p.Kill() }
            $p.ExitCode | Should -Be 2 -Because ($argv -join ' ')
        }
    }

    It 'addresses the VM and the runtime service as SOCKADDR_HV (family 34, VM id at 4, service id at 20)' {
        . $script:Relay
        $vm = [guid]'6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b'
        $ep = [AapHvEndPoint]::new($vm, [guid]$script:ServiceId)
        [int][System.Net.EndPoint].GetProperty('AddressFamily').GetValue($ep) | Should -Be 34
        $sa = $ep.Serialize()
        $sa.Size | Should -Be 36
        [int]$sa.Family | Should -Be 34
        $bytes = @(for ($i = 0; $i -lt 36; $i++) { $sa[$i] })
        [byte[]]$bytes[4..19] | Should -Be $vm.ToByteArray()
        [byte[]]$bytes[20..35] | Should -Be ([guid]'00001466-facb-11e6-bd58-64006a7986d3').ToByteArray()
        $script:ServiceId | Should -BeExactly '00001466-facb-11e6-bd58-64006a7986d3'
    }

    It 'opens no listening socket, reads and writes no file, and takes no data but the VM id' {
        $t = [IO.File]::ReadAllText($script:Relay)
        $t | Should -Not -Match '\.(Bind|Listen|Accept)\(|TcpListener|\[IO\.File\]|Out-File|Set-Content|Add-Content'
        $t | Should -Match 'exit \(Invoke-AapRelay \$args\)'
    }
}
