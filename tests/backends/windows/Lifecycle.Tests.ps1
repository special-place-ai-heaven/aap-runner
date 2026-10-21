# The Windows backend's normal lifecycle against the real allocator and broker client, with fake Hyper-V, guest, broker
# and network (WinBackendTestHelpers.ps1): create, boot, ready, run_one, heartbeats, drain, collect, destroy. Every
# journal record and every guest exchange must pass parity/contracts/validate.py. Pester 5, Windows PowerShell 5.1 and
# PowerShell 7.5+.

BeforeAll {
    . (Join-Path $PSScriptRoot 'WinBackendTestHelpers.ps1')
    Import-Module $script:CapModule -Force
    Import-Module $script:BackendModule -Force
}

Describe 'one job, end to end' {
    It 'creates, boots, registers, runs one job, collects and destroys, freeing the slot only with a proof' -Tag 'jobrunning', 'observe-absent' {
        $w = New-WinWorld
        $B = New-WinBackend $w
        $r = New-WinReservation $w
        $rid = $r.reservation_id
        $steps = @(Invoke-WinSteps $B $w $rid -Until { param($x) $x.state -eq 'ready' })
        ($steps | ForEach-Object { $_.Action }) -join ',' | Should -Be 'created,booted,ready'
        $vm = @(Get-WinVms $w)
        $vm.Count | Should -Be 1
        $vm[0].Name | Should -Be (Get-AapVmName -Profile windows -Slot $r.slot -LeaseGeneration $r.lease_generation -ReservationId $rid)
        $vm[0].State | Should -Be 'Running'
        (Get-WinRes $w $rid).vm_id | Should -Be $vm[0].Id

        # run_one: the lease, the JIT config on the guest's stdin, the runner started.
        $s = Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid)
        $s.Action | Should -Be 'running'
        $lease = @(Get-WinLeases $w)
        $lease.Count | Should -Be 1
        $lease[0].state | Should -Be 'issued'
        $guest = Read-WinJson (Join-Path $w.Fake "guests\$($vm[0].Id).json") $null
        $guest.PayloadSha | Should -Be $lease[0].jit_sha
        $guest.Shots | Should -Be @('deliver_registration', 'start_runner')

        # The guest says busy; only the broker's record makes the job running.
        Set-WinKnob $w @{ GuestStatus = 'busy' }
        (Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid)).Action | Should -Be 'listening'
        (Get-WinRes $w $rid).state | Should -Be 'ready'
        Set-WinKnob $w @{ RunnerBusy = $true }
        (Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid)).Action | Should -Be 'busy'
        (Get-WinRes $w $rid).state | Should -Be 'busy'

        # The job ends: GitHub removed the ephemeral runner.
        Set-WinKnob $w @{ RunnerBusy = $false; RunnerStatus = 'absent'; GuestStatus = 'job_done' }
        $end = Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid)
        $end.Action | Should -Be 'destroyed'
        $end.Summary.GuestState | Should -Be 'job_done'
        $end.Summary.RunnerExitCode | Should -Be 0
        $done = Get-WinRes $w $rid
        $done.state | Should -Be 'reconciled'
        $done.teardown_proof.vm_absent | Should -BeTrue
        $done.teardown_proof.runner_deregistered | Should -BeTrue
        @(Get-WinVms $w).Count | Should -Be 0
        Test-Path -LiteralPath (Join-Path $w.Clones $rid) | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $w.Scratch $rid) | Should -BeFalse
        (@(Get-WinLeases $w))[0].state | Should -Be 'released'

        # Every journal record and guest exchange is a valid contract document.
        $lines = @(Get-WinJournalLines $w $rid)
        $lines.Count | Should -BeGreaterThan 10
        Invoke-WinValidator $w 'backend-lifecycle' $lines | Should -BeNullOrEmpty
        $ex = @([IO.Directory]::GetFiles((Join-Path $w.Fake 'exchanges')) | ForEach-Object { [IO.File]::ReadAllText($_) })
        $ex.Count | Should -BeGreaterOrEqual 6
        Invoke-WinValidator $w 'guest-transport' $ex | Should -BeNullOrEmpty
        # The ops in order, intent before every outcome; the VM id is journaled right after New-VM (a second create intent)
        # and the lease outcome right after the lease call (a repeated ready done).
        $j = Get-WinJournal $w $rid
        ($j | ForEach-Object { "$($_.op)/$($_.phase)" }) -join ' ' | Should -Be ('create/intent create/intent create/done boot/intent boot/done ready/intent ready/done ' +
            'run_one/intent ready/done run_one/done collect/intent collect/done destroy/intent destroy/done')
        $j[1].vm.vm_id | Should -Be $vm[0].Id
        $j[8].result.detail | Should -Be 'lease issued by the broker'
    }

    It 'sizes the scratch disk inside scratch_gib and records the hard caps' -Tag 'disk-kind' {
        $w = New-WinWorld
        $B = New-WinBackend $w
        $r = New-WinReservation $w
        [void](Invoke-AapWinStep -Backend $B -Reservation $r -BaseSha256 $w.BaseSha)
        $call = @(Get-WinCalls $w 'NewDisk *')
        $call.Count | Should -Be 1
        [long]($call[0] -split ' ')[-1] | Should -BeLessThan ([long]$r.scratch_gib * $script:GiB)
        [long]($call[0] -split ' ')[-1] | Should -BeGreaterThan ([long]($r.scratch_gib - 1) * $script:GiB)
        @(Get-WinCalls $w 'NewDiffDisk *')[0] | Should -BeLike "*\$($r.reservation_id)\os.avhdx *base.vhdx"
    }

    It 'probes until the guest is ready, and destroys a guest not ready 15 minutes after boot' -Tag 'boot-deadline' {
        $w = New-WinWorld
        $B = New-WinBackend $w
        Set-WinKnob $w @{ BootProbes = 100; ClockOffset = -16 * 60 }   # booted 16 minutes ago, by the backend's clock
        $r = New-WinReservation $w
        $rid = $r.reservation_id
        @(Invoke-WinSteps $B $w $rid -Max 4 | ForEach-Object { $_.Action }) -join ',' | Should -Be 'created,booted,probing,probing'
        (Get-WinRes $w $rid).state | Should -Be 'creating'
        Set-WinKnob $w @{ ClockOffset = 0 }
        $s = Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid)
        $s.Action | Should -Be 'destroyed'
        (Get-WinRes $w $rid).teardown_proof.runner_deregistered | Should -Be 'never_registered'
        @(Get-WinVms $w).Count | Should -Be 0
    }

    It 'a guest whose PowerShell Direct is not up yet, or whose reply was lost, still gets to ready: seq only grows' {
        foreach ($k in @(@{ NotUp = 3 }, @{ LoseReply = 2 })) {
            $w = New-WinWorld
            $B = New-WinBackend $w
            Set-WinKnob $w $k
            $r = New-WinReservation $w
            $rid = $r.reservation_id
            $acts = @(Invoke-WinSteps $B $w $rid -Max 8 -Until { param($x) $x.state -eq 'ready' } | ForEach-Object { $_.Action })
            ($acts -join ',') | Should -Be $(if ($k.NotUp) { 'created,booted,probing,probing,probing,ready' } else { 'created,booted,probing,probing,ready' })
            (Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid)).Action | Should -Be 'running'
            $seqs = @(Get-ChildItem -LiteralPath (Join-Path $w.Fake 'exchanges') | ForEach-Object { (Read-WinJson $_.FullName $null).cmd.seq } | Sort-Object)
            $seqs[-1] | Should -BeGreaterThan $seqs.Count -Because 'the commands the guest never answered left gaps'
        }
    }

    It 'asks the guest and the broker at most every 30 s per reservation' {
        $w = New-WinWorld
        $B = New-WinBackend $w
        $r = New-WinReservation $w
        $rid = $r.reservation_id
        [void](Invoke-WinSteps $B $w $rid -Max 5 -Until { param($x) $x.state -eq 'ready' })
        [void](Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid))   # running
        $B.StatusSeconds = 30
        Set-WinKnob $w @{ RunnerBusy = $true }
        (Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid)).Action | Should -Be 'busy'
        $n = @(Get-WinCalls $w 'Broker status_request *').Count
        $s = Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid)
        $s.Action | Should -Be 'busy'
        $s.Code | Should -Be 'not_due'
        @(Get-WinCalls $w 'Broker status_request *').Count | Should -Be $n
        $B.Now = { [DateTime]::UtcNow.AddSeconds(31) }
        (Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid)).Code | Should -Not -Be 'not_due'
        @(Get-WinCalls $w 'Broker status_request *').Count | Should -Be ($n + 1)
    }

    It 'a runner that takes a job between the drain sample and the release keeps its VM and its job' -Tag 'release-busy' {
        $w = New-WinWorld
        $B = New-WinBackend $w
        $r = New-WinReservation $w
        $rid = $r.reservation_id
        [void](Invoke-WinSteps $B $w $rid -Max 5 -Until { param($x) $x.state -eq 'ready' })
        [void](Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid))   # running, listening, no job
        [void](Set-AapSlotState -Root $w.Cap -ReservationId $rid -LeaseGeneration $r.lease_generation -State draining -RelaxedTrustForTests)
        Set-WinKnob $w @{ BusyAfterStatus = $true }
        $s = Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid)
        $s.Code | Should -Be 'release_pending'
        @(Get-WinCalls $w 'Broker release_request *').Count | Should -Be 0
        @(Get-WinVms $w).Count | Should -Be 1
        @(Get-WinCalls $w 'RemoveVm *').Count | Should -Be 0
        # The job ends and the one-job runner leaves: now it is released and the VM goes.
        Set-WinKnob $w @{ RunnerBusy = $false; RunnerStatus = 'absent' }
        $B.Now = { [DateTime]::UtcNow.AddSeconds(60) }
        (Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid)).Action | Should -Be 'destroyed'
        @(Get-WinVms $w).Count | Should -Be 0
    }

    It 'a broker that cannot say the drained runner is still idle (<how>) keeps the runner and its VM' -Tag 'release-busy' -ForEach @(
        @{ how = 'unavailable' }, @{ how = 'timeout' }, @{ how = 'bad_reply' }
    ) {
        $w = New-WinWorld
        $B = New-WinBackend $w
        $r = New-WinReservation $w
        $rid = $r.reservation_id
        [void](Invoke-WinSteps $B $w $rid -Max 5 -Until { param($x) $x.state -eq 'ready' })
        [void](Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid))   # running, listening, no job
        [void](Set-AapSlotState -Root $w.Cap -ReservationId $rid -LeaseGeneration $r.lease_generation -State draining -RelaxedTrustForTests)
        Set-WinKnob $w @{ StatusAfterStatus = $how }
        $s = Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid)
        $s.Code | Should -Be 'release_pending'
        @(Get-WinCalls $w 'Broker release_request *').Count | Should -Be 0
        @(Get-WinVms $w).Count | Should -Be 1
        Set-WinKnob $w @{ StatusOutcome = 'ok'; RunnerStatus = 'absent' }
        $B.Now = { [DateTime]::UtcNow.AddSeconds(60) }
        (Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid)).Action | Should -Be 'destroyed'
    }

    It 'a drained runner whose release is not final keeps its VM until it is' -Tag 'drain-keep' {
        $w = New-WinWorld
        $B = New-WinBackend $w
        $r = New-WinReservation $w
        $rid = $r.reservation_id
        [void](Invoke-WinSteps $B $w $rid -Max 5 -Until { param($x) $x.state -eq 'ready' })
        [void](Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid))   # running, listening, no job
        [void](Set-AapSlotState -Root $w.Cap -ReservationId $rid -LeaseGeneration $r.lease_generation -State draining -RelaxedTrustForTests)
        Set-WinKnob $w @{ ReleaseOutcome = 'retry' }
        $s = Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid)
        $s.Code | Should -Be 'release_pending'
        (Get-WinRes $w $rid).state | Should -Be 'deleting'
        @(Get-WinVms $w).Count | Should -Be 1
        @(Get-WinCalls $w 'RemoveVm *').Count | Should -Be 0
        Set-WinKnob $w @{ ReleaseOutcome = 'normal' }
        $B.Now = { [DateTime]::UtcNow.AddSeconds(60) }
        (Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid)).Action | Should -Be 'destroyed'
        @(Get-WinVms $w).Count | Should -Be 0
        (Get-WinRes $w $rid).teardown_proof.runner_deregistered | Should -BeTrue
    }

    It 'verifies a running guest''s network again: a host that changed (a public address) ends the clone' -Tag 'net-running' -ForEach @(
        @{ Tamper = 'public-host'; Fail = '' }, @{ Tamper = 'dhcp-guard-off'; Fail = '' }, @{ Tamper = ''; Fail = 'Verify' }
    ) {
        $w = New-WinWorld
        $B = New-WinBackend $w
        $r = New-WinReservation $w
        $rid = $r.reservation_id
        [void](Invoke-WinSteps $B $w $rid -Max 5 -Until { param($x) $x.state -eq 'ready' })
        [void](Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid))   # running
        Set-WinKnob $w @{ RunnerBusy = $true }
        Set-WinNet $w -Tamper @($Tamper | Where-Object { $_ }) -Fail @($Fail | Where-Object { $_ })
        $s = Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid)
        $s.Action | Should -Be 'destroyed'
        @(Get-WinVms $w).Count | Should -Be 0
        @(Get-WinNetRecords $w).Count | Should -Be 0
        @(Get-WinJournal $w $rid | Where-Object { $_.op -eq 'run_one' -and $_.phase -eq 'failed' })[0].result.detail | Should -BeLike 'network: *'
    }

    It 'verifies a running guest''s network again: a non-terminating error Verify writes ends the clone' -Tag 'net-running' {
        $w = New-WinWorld
        $B = New-WinBackend $w
        $r = New-WinReservation $w
        $rid = $r.reservation_id
        [void](Invoke-WinSteps $B $w $rid -Max 5 -Until { param($x) $x.state -eq 'ready' })
        [void](Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid))   # running
        Set-WinKnob $w @{ RunnerBusy = $true; NetVerifyError = $true }
        (Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid)).Action | Should -Be 'destroyed'
        @(Get-WinVms $w).Count | Should -Be 0
        @(Get-WinJournal $w $rid | Where-Object { $_.op -eq 'run_one' -and $_.phase -eq 'failed' })[0].result.detail | Should -BeLike 'network: Verify wrote an error*'
    }

    It 'reads a running guest''s adapter back again: a silent Verify does not pass <Tamper>' -Tag 'net-running-readback' -ForEach @(
        @{ Tamper = 'dhcp-guard-off' }, @{ Tamper = 'foreign-peer' }
    ) {
        $w = New-WinWorld
        $B = New-WinBackend $w
        $r = New-WinReservation $w
        $rid = $r.reservation_id
        [void](Invoke-WinSteps $B $w $rid -Max 5 -Until { param($x) $x.state -eq 'ready' })
        [void](Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid))   # running
        Set-WinKnob $w @{ RunnerBusy = $true; NetVerifySilent = $true }
        Set-WinNet $w -Tamper $Tamper
        (Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid)).Action | Should -Be 'destroyed'
        @(Get-WinVms $w).Count | Should -Be 0
        @(Get-WinJournal $w $rid | Where-Object { $_.op -eq 'run_one' -and $_.phase -eq 'failed' })[0].result.detail | Should -BeLike 'network: read-back: *'
    }

    It 'verifies a running guest''s network at least every 60 s, not on every step' {
        $w = New-WinWorld
        $B = New-WinBackend $w
        $B.NetSeconds = 60
        $r = New-WinReservation $w
        $rid = $r.reservation_id
        [void](Invoke-WinSteps $B $w $rid -Max 5 -Until { param($x) $x.state -eq 'ready' })
        [void](Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid))
        $n = @(Get-WinCalls $w 'NetVerify *').Count
        [void](Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid))
        @(Get-WinCalls $w 'NetVerify *').Count | Should -Be $n
        $B.Now = { [DateTime]::UtcNow.AddSeconds(61) }
        [void](Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid))
        @(Get-WinCalls $w 'NetVerify *').Count | Should -Be ($n + 1)
    }

    It 'a drained VM kept for its release is held to its limits on every step, before the retry gate, after a restart too' -Tag 'deleting-limits' {
        foreach ($knob in @(@{ CloneBytes = 61 * $script:GiB }, @{ Paused = $true }, @{ MeasureFails = $true })) {
            foreach ($restart in $false, $true) {
                $w = New-WinWorld
                $B = New-WinBackend $w
                $r = New-WinReservation $w
                $rid = $r.reservation_id
                [void](Invoke-WinSteps $B $w $rid -Max 5 -Until { param($x) $x.state -eq 'ready' })
                [void](Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid))   # running, listening, no job
                [void](Set-AapSlotState -Root $w.Cap -ReservationId $rid -LeaseGeneration $r.lease_generation -State draining -RelaxedTrustForTests)
                Set-WinKnob $w @{ ReleaseOutcome = 'retry' }
                (Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid)).Code | Should -Be 'release_pending'
                @(Get-WinVms $w).Count | Should -Be 1
                # GitHub hands the still-listed runner a job; it writes past clone_gib, or the VM is paused.
                Set-WinKnob $w $knob
                if ($restart) { $B = New-WinBackend $w }
                $s = Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid)
                @(Get-WinVms $w).Count | Should -Be 0 -Because "$($knob.Keys) restart=$restart"
                $s.Code | Should -Be 'release_pending' -Because 'the VM is gone; the release still decides the slot'
                (Get-WinRes $w $rid).state | Should -Be 'deleting'
                @(Get-WinJournal $w $rid | Where-Object { $_.op -eq 'destroy' -and $_.result.detail -like 'limit broken while kept: *' }).Count | Should -Be 1
            }
        }
    }

    It 'a drained VM kept past 6 h is flagged, never destroyed for time; a limit still removes it' -Tag 'drain-overdue', 'deleting-limits' {
        $w = New-WinWorld
        $B = New-WinBackend $w
        $r = New-WinReservation $w
        $rid = $r.reservation_id
        [void](Invoke-WinSteps $B $w $rid -Max 5 -Until { param($x) $x.state -eq 'ready' })
        [void](Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid))
        [void](Set-AapSlotState -Root $w.Cap -ReservationId $rid -LeaseGeneration $r.lease_generation -State draining -RelaxedTrustForTests)
        Set-WinKnob $w @{ ReleaseOutcome = 'retry' }
        (Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid)).Code | Should -Be 'release_pending'
        $B.Now = { [DateTime]::UtcNow.AddHours(6).AddMinutes(1) }
        (Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid)).Code | Should -Be 'drain_overdue'
        $B.Now = { [DateTime]::UtcNow.AddHours(6).AddMinutes(3) }
        (Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid)).Code | Should -Be 'drain_overdue'
        @(Get-WinVms $w).Count | Should -Be 1
        @(Get-WinCalls $w 'RemoveVm *').Count | Should -Be 0
        @(Get-WinJournal $w $rid | Where-Object { $_.result.detail -like 'drained VM kept 6 h*' }).Count | Should -Be 1
        Set-WinKnob $w @{ CloneBytes = 61 * $script:GiB }
        [void](Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid))
        @(Get-WinVms $w).Count | Should -Be 0
    }

    It 'drains an idle runner: deregisters it and destroys the VM; a busy one keeps running' -Tag 'jobrunning' {
        $w = New-WinWorld
        $B = New-WinBackend $w
        $r = New-WinReservation $w
        $rid = $r.reservation_id
        [void](Invoke-WinSteps $B $w $rid -Max 5 -Until { param($x) $x.state -eq 'ready' })
        [void](Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid))   # running
        Set-WinKnob $w @{ RunnerBusy = $true }
        [void](Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid))
        [void](Set-AapSlotState -Root $w.Cap -ReservationId $rid -LeaseGeneration $r.lease_generation -State draining -RelaxedTrustForTests)
        (Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid)).Action | Should -Be 'busy'
        (Get-WinRes $w $rid).state | Should -Be 'draining'
        @(Get-WinVms $w).Count | Should -Be 1
        @(Get-WinCalls $w 'Broker release_request *').Count | Should -Be 0
        Set-WinKnob $w @{ RunnerBusy = $false }
        (Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid)).Action | Should -Be 'destroyed'
        (Get-WinRes $w $rid).teardown_proof.runner_deregistered | Should -BeTrue
        @(Get-WinJournal $w $rid | Where-Object { $_.op -eq 'drain' }).Count | Should -Be 2
    }

    It 'binds the heartbeat to its own channel: a reply that names another reservation is hostile' -Tag 'reply-echo' {
        $w = New-WinWorld
        $B = New-WinBackend $w
        $r = New-WinReservation $w
        $rid = $r.reservation_id
        [void](Invoke-WinSteps $B $w $rid -Max 5 -Until { param($x) $x.state -eq 'ready' })
        [void](Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid))
        Set-WinKnob $w @{ Guest = @{ status = 'echo-reservation_id' } }
        $s = Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid)
        $s.Code | Should -Be 'wrong_echo'
        $s.Action | Should -Be 'destroyed'
        @(Get-WinVms $w).Count | Should -Be 0
    }

    It 'destroys a VM whose clone folder passes clone_gib (fatal, clone over cap) or cannot be measured, and a paused VM' -Tag 'clone-cap', 'vm-paused' {
        foreach ($knob in @(@{ CloneBytes = 61 * $script:GiB }, @{ Paused = $true }, @{ MeasureFails = $true })) {
            $w = New-WinWorld
            $B = New-WinBackend $w
            $r = New-WinReservation $w
            $rid = $r.reservation_id
            [void](Invoke-WinSteps $B $w $rid -Max 5 -Until { param($x) $x.state -eq 'ready' })
            [void](Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid))
            Set-WinKnob $w @{ RunnerBusy = $true }
            Set-WinKnob $w $knob
            $s = Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid)
            $s.Action | Should -Be 'destroyed'
            $fail = @(Get-WinJournal $w $rid | Where-Object { $_.op -eq 'run_one' -and $_.phase -eq 'failed' })
            $fail[0].result.code | Should -Be 'fatal'
            $fail[0].result.detail | Should -BeIn @('clone over cap', 'vm paused', 'clone not measurable')
            @(Get-WinVms $w).Count | Should -Be 0
        }
    }

    It 'a heartbeat-quarantined clone over its cap or paused is destroyed from the host, with or without a guest channel' -Tag 'clone-cap', 'vm-paused' {
        foreach ($case in @(@{ Knob = @{ CloneBytes = 61 * $script:GiB }; Restart = $false }, @{ Knob = @{ CloneBytes = 61 * $script:GiB }; Restart = $true }, @{ Knob = @{ Paused = $true }; Restart = $true })) {
            $w = New-WinWorld
            $B = New-WinBackend $w
            $r = New-WinReservation $w
            $rid = $r.reservation_id
            [void](Invoke-WinSteps $B $w $rid -Max 5 -Until { param($x) $x.state -eq 'ready' })
            [void](Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid))
            Set-WinKnob $w @{ RunnerBusy = $true; Guest = @{ status = 'silent' } }   # the guest stops answering
            [void](Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid))
            & (Get-Module AapCapacity) { function script:Get-AapUtcNow { [DateTime]::UtcNow.AddSeconds(120) } }
            try { [void](Invoke-AapReconcile -Root $w.Cap -RelaxedTrustForTests) } finally { & (Get-Module AapCapacity) { function script:Get-AapUtcNow { [DateTime]::UtcNow } } }
            (Get-WinRes $w $rid).quarantine_kind | Should -Be 'heartbeat'
            Set-WinKnob $w $case.Knob
            if ($case.Restart) { $B = New-WinBackend $w }
            $s = Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid)
            $s.Action | Should -Be 'destroyed' -Because ($case.Knob.Keys -join ',')
            @(Get-WinVms $w).Count | Should -Be 0
            (Get-WinRes $w $rid).state | Should -Be 'reconciled'
            @(Get-WinJournal $w $rid | Where-Object { $_.op -eq 'run_one' -and $_.phase -eq 'failed' })[0].result.detail | Should -BeIn @('clone over cap', 'vm paused')
        }
    }

    It 'a heartbeat-quarantined slot returns to busy on a validated reply, with JobRunning from the broker' -Tag 'jobrunning', 'recover-broker' {
        $w = New-WinWorld
        $B = New-WinBackend $w
        $r = New-WinReservation $w
        $rid = $r.reservation_id
        [void](Invoke-WinSteps $B $w $rid -Max 5 -Until { param($x) $x.state -eq 'ready' })
        [void](Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid))
        Set-WinKnob $w @{ RunnerBusy = $true }
        [void](Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid))
        # Three missed heartbeats, as reconcile sees them 90 s later.
        & (Get-Module AapCapacity) { function script:Get-AapUtcNow { [DateTime]::UtcNow.AddSeconds(120) } }
        try { [void](Invoke-AapReconcile -Root $w.Cap -RelaxedTrustForTests) } finally { & (Get-Module AapCapacity) { Remove-Item function:script:Get-AapUtcNow; function script:Get-AapUtcNow { [DateTime]::UtcNow } } }
        (Get-WinRes $w $rid).quarantine_kind | Should -Be 'heartbeat'
        Set-WinKnob $w @{ StatusOutcome = 'unavailable' }   # a reply alone is not enough: the broker must answer too
        (Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid)).Code | Should -Be 'broker_unavailable'
        (Get-WinRes $w $rid).state | Should -Be 'quarantined'
        Set-WinKnob $w @{ StatusOutcome = 'ok' }
        (Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid)).Action | Should -Be 'recovered'
        (Get-WinRes $w $rid).state | Should -Be 'busy'
    }
}
