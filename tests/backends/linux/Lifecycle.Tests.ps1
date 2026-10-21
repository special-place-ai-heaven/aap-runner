# The Linux backend's normal lifecycle against the real allocator and broker client, with fake Hyper-V, ssh-keygen,
# seed writer, guest, broker and network (LinBackendTestHelpers.ps1): create, boot, host key pin, ready, seed ejected,
# run_one, heartbeats, drain, collect, destroy; and the acceptance proof that nothing flows from one job to the next on the
# same slot. Every journal record and every guest exchange must pass parity/contracts/validate.py. Pester 5, Windows
# PowerShell 5.1 and PowerShell 7.5+.

BeforeAll {
    . (Join-Path $PSScriptRoot 'LinBackendTestHelpers.ps1')
    Import-Module $script:CapModule -Force
    Import-Module $script:BackendModule -Force
}

Describe 'one job, end to end' {
    It 'creates, boots, pins, registers, runs one job, collects and destroys, freeing the slot only with a proof' -Tag 'jobrunning', 'observe-absent', 'destroy-once' {
        $w = New-LinWorld
        $B = New-LinBackend $w
        $r = New-LinReservation $w
        $rid = $r.reservation_id
        $steps = @(Invoke-LinSteps $B $w $rid -Until { param($x) $x.state -eq 'ready' })
        ($steps | ForEach-Object { $_.Action }) -join ',' | Should -Be 'created,booted,ready'
        $vm = @(Get-LinVms $w)
        $vm.Count | Should -Be 1
        $vm[0].Name | Should -Be (Get-AapVmName -Profile linux -Slot $r.slot -LeaseGeneration $r.lease_generation -ReservationId $rid)
        $vm[0].State | Should -Be 'Running'
        (Get-LinRes $w $rid).vm_id | Should -Be $vm[0].Id
        # First boot is over: the seed is ejected and gone; the host key the guest published is pinned.
        @($vm[0].Dvds).Count | Should -Be 0
        Test-Path -LiteralPath (Join-Path $w.Clones "$rid\seed.iso") | Should -BeFalse
        [IO.File]::ReadAllText((Join-Path $w.Clones "$rid\ssh\known_hosts")) | Should -BeExactly "aap-guest $($vm[0].HostKey)`n"

        # run_one: the lease, the JIT config on the guest's stdin, the runner started.
        $s = Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid)
        $s.Action | Should -Be 'running'
        $lease = @(Get-LinLeases $w)
        $lease.Count | Should -Be 1
        $lease[0].state | Should -Be 'issued'
        $guest = Read-LinJson (Join-Path $w.Fake "guests\$($vm[0].Id).json") $null
        $guest.PayloadSha | Should -Be $lease[0].jit_sha
        $guest.Shots | Should -Be @('deliver_registration', 'start_runner')

        # The guest says busy; only the broker's record makes the job running.
        Set-LinKnob $w @{ GuestStatus = 'busy' }
        (Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid)).Action | Should -Be 'listening'
        (Get-LinRes $w $rid).state | Should -Be 'ready'
        Set-LinKnob $w @{ RunnerBusy = $true }
        (Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid)).Action | Should -Be 'busy'
        (Get-LinRes $w $rid).state | Should -Be 'busy'

        # The job ends: GitHub removed the ephemeral runner.
        Set-LinKnob $w @{ RunnerBusy = $false; RunnerStatus = 'absent'; GuestStatus = 'job_done' }
        $end = Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid)
        $end.Action | Should -Be 'destroyed'
        $end.Summary.GuestState | Should -Be 'job_done'
        $end.Summary.RunnerExitCode | Should -Be 0
        $done = Get-LinRes $w $rid
        $done.state | Should -Be 'reconciled'
        $done.teardown_proof.vm_absent | Should -BeTrue
        $done.teardown_proof.runner_deregistered | Should -BeTrue
        @(Get-LinVms $w).Count | Should -Be 0
        Test-Path -LiteralPath (Join-Path $w.Clones $rid) | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $w.Scratch $rid) | Should -BeFalse
        (@(Get-LinLeases $w))[0].state | Should -Be 'released'

        # Every journal record and guest exchange is a valid contract document.
        $lines = @(Get-LinJournalLines $w $rid)
        Invoke-LinValidator $w 'backend-lifecycle' $lines | Should -BeNullOrEmpty
        $ex = @([IO.Directory]::GetFiles((Join-Path $w.Fake 'exchanges')) | ForEach-Object { [IO.File]::ReadAllText($_) })
        $ex.Count | Should -BeGreaterOrEqual 6
        Invoke-LinValidator $w 'guest-transport' $ex | Should -BeNullOrEmpty
        # The ops in order, intent before every outcome; the VM id is journaled right after New-VM (a second create intent),
        # the lease outcome right after the lease call and the runner start after start_runner (repeated ready done).
        $j = Get-LinJournal $w $rid
        ($j | ForEach-Object { "$($_.op)/$($_.phase)" }) -join ' ' | Should -Be ('create/intent create/intent create/done boot/intent boot/done ready/intent ready/done ' +
            'run_one/intent ready/done ready/done run_one/done collect/intent collect/done destroy/intent destroy/done')
        $j[1].vm.vm_id | Should -Be $vm[0].Id
        @($j[0].disks | ForEach-Object { $_.role }) -join ',' | Should -Be 'base_ref,os_diff,seed'
        $j[8].result.detail | Should -Be 'lease issued by the broker'
        $j[9].result.detail | Should -Be 'runner started on the guest'
    }

    It 'makes no scratch disk and refuses a reservation that asks for one' -Tag 'no-scratch' {
        $w = New-LinWorld
        $B = New-LinBackend $w
        $r = New-LinReservation $w
        [void](Invoke-AapLinStep -Backend $B -Reservation $r -BaseSha256 $w.BaseSha)
        @(Get-ChildItem -LiteralPath $w.Scratch).Count | Should -Be 0
        @(Get-LinCalls $w 'NewDiffDisk *')[0] | Should -BeLike "*\$($r.reservation_id)\os.avhdx *base.vhdx"
        $w = New-LinWorld
        $B = New-LinBackend $w
        $q = Request-AapReservation -Root $w.Cap -Profile linux -MemOverheadMib 512 -CloneGib 55 -ScratchGib 10 -IoMbps 100 -ImageGeneration $script:LinGen -RelaxedTrustForTests
        $q.Ok | Should -BeTrue
        [void](Invoke-AapLinStep -Backend $B -Reservation $q.Reservation -BaseSha256 $w.BaseSha)
        @(Get-LinJournal $w $q.Reservation.reservation_id | Where-Object { $_.phase -eq 'failed' })[0].result.detail | Should -BeLike '*AAP_BadRequest: the Linux profile has no scratch disk*'
        @(Get-LinCalls $w 'NewVm *').Count | Should -Be 0
    }

    It 'waits for the host key, then probes; destroys a guest with no key or not ready 15 minutes after boot' -Tag 'boot-deadline' {
        foreach ($k in @(@{ KvpDelay = 100 }, @{ BootProbes = 100 })) {
            $w = New-LinWorld
            $B = New-LinBackend $w
            Set-LinKnob $w ($k + @{ ClockOffset = -16 * 60 })   # booted 16 minutes ago, by the backend's clock
            $r = New-LinReservation $w
            $rid = $r.reservation_id
            $acts = @(Invoke-LinSteps $B $w $rid -Max 4)
            ($acts | ForEach-Object { $_.Action }) -join ',' | Should -Be 'created,booted,probing,probing'
            $acts[-1].Code | Should -Be $(if ($k.ContainsKey('KvpDelay')) { 'host_key_pending' } else { 'ok' })
            (Get-LinRes $w $rid).state | Should -Be 'creating'
            Set-LinKnob $w @{ ClockOffset = 0 }
            $s = Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid)
            $s.Action | Should -Be 'destroyed'
            $s.Code | Should -Be 'timeout'
            (Get-LinRes $w $rid).teardown_proof.runner_deregistered | Should -Be 'never_registered'
            @(Get-LinVms $w).Count | Should -Be 0
        }
    }

    It 'a guest whose sshd is not up yet, or whose reply was lost, still gets to ready: seq only grows' {
        foreach ($k in @(@{ NotUp = 3 }, @{ LoseReply = 2 })) {
            $w = New-LinWorld
            $B = New-LinBackend $w
            Set-LinKnob $w $k
            $r = New-LinReservation $w
            $rid = $r.reservation_id
            $acts = @(Invoke-LinSteps $B $w $rid -Max 8 -Until { param($x) $x.state -eq 'ready' } | ForEach-Object { $_.Action })
            ($acts -join ',') | Should -Be $(if ($k.ContainsKey('NotUp')) { 'created,booted,probing,probing,probing,ready' } else { 'created,booted,probing,probing,ready' })
            (Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid)).Action | Should -Be 'running'
            $seqs = @(Get-ChildItem -LiteralPath (Join-Path $w.Fake 'exchanges') | ForEach-Object { (Read-LinJson $_.FullName $null).cmd.seq } | Sort-Object)
            $seqs[-1] | Should -BeGreaterThan $seqs.Count -Because 'the commands the guest never answered left gaps'
        }
    }

    It 'asks the guest and the broker at most every 30 s per reservation' {
        $w = New-LinWorld
        $B = New-LinBackend $w
        $r = New-LinReservation $w
        $rid = $r.reservation_id
        [void](Invoke-LinSteps $B $w $rid -Max 5 -Until { param($x) $x.state -eq 'ready' })
        [void](Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid))   # running
        $B.StatusSeconds = 30
        Set-LinKnob $w @{ RunnerBusy = $true }
        (Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid)).Action | Should -Be 'busy'
        $n = @(Get-LinCalls $w 'Broker status_request *').Count
        $s = Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid)
        $s.Action | Should -Be 'busy'
        $s.Code | Should -Be 'not_due'
        @(Get-LinCalls $w 'Broker status_request *').Count | Should -Be $n
        $B.Now = { [DateTime]::UtcNow.AddSeconds(31) }
        (Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid)).Code | Should -Not -Be 'not_due'
        @(Get-LinCalls $w 'Broker status_request *').Count | Should -Be ($n + 1)
    }

    It 'drains an idle runner: deregisters it and destroys the VM; a busy one keeps running' -Tag 'jobrunning' {
        $w = New-LinWorld
        $B = New-LinBackend $w
        $r = New-LinReservation $w
        $rid = $r.reservation_id
        [void](Invoke-LinSteps $B $w $rid -Max 5 -Until { param($x) $x.state -eq 'ready' })
        [void](Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid))   # running
        Set-LinKnob $w @{ RunnerBusy = $true }
        [void](Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid))
        [void](Set-AapSlotState -Root $w.Cap -ReservationId $rid -LeaseGeneration $r.lease_generation -State draining -RelaxedTrustForTests)
        (Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid)).Action | Should -Be 'busy'
        (Get-LinRes $w $rid).state | Should -Be 'draining'
        @(Get-LinVms $w).Count | Should -Be 1
        @(Get-LinCalls $w 'Broker release_request *').Count | Should -Be 0
        Set-LinKnob $w @{ RunnerBusy = $false }
        (Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid)).Action | Should -Be 'destroyed'
        (Get-LinRes $w $rid).teardown_proof.runner_deregistered | Should -BeTrue
        @(Get-LinJournal $w $rid | Where-Object { $_.op -eq 'drain' }).Count | Should -Be 2
    }

    It 'a runner that takes a job between the drain sample and the release keeps its VM and its job' -Tag 'release-busy' {
        $w = New-LinWorld
        $B = New-LinBackend $w
        $r = New-LinReservation $w
        $rid = $r.reservation_id
        [void](Invoke-LinSteps $B $w $rid -Max 5 -Until { param($x) $x.state -eq 'ready' })
        [void](Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid))   # running, listening, no job
        [void](Set-AapSlotState -Root $w.Cap -ReservationId $rid -LeaseGeneration $r.lease_generation -State draining -RelaxedTrustForTests)
        Set-LinKnob $w @{ BusyAfterStatus = $true }
        $s = Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid)
        $s.Code | Should -Be 'release_pending'
        @(Get-LinCalls $w 'Broker release_request *').Count | Should -Be 0
        @(Get-LinVms $w).Count | Should -Be 1
        @(Get-LinCalls $w 'RemoveVm *').Count | Should -Be 0
        # The job ends and the one-job runner leaves: now it is released and the VM goes.
        Set-LinKnob $w @{ RunnerBusy = $false; RunnerStatus = 'absent' }
        $B.Now = { [DateTime]::UtcNow.AddSeconds(60) }
        (Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid)).Action | Should -Be 'destroyed'
        @(Get-LinVms $w).Count | Should -Be 0
    }

    It 'a drained runner whose release is not final keeps its VM until it is' -Tag 'drain-keep' {
        $w = New-LinWorld
        $B = New-LinBackend $w
        $r = New-LinReservation $w
        $rid = $r.reservation_id
        [void](Invoke-LinSteps $B $w $rid -Max 5 -Until { param($x) $x.state -eq 'ready' })
        [void](Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid))   # running, listening, no job
        [void](Set-AapSlotState -Root $w.Cap -ReservationId $rid -LeaseGeneration $r.lease_generation -State draining -RelaxedTrustForTests)
        Set-LinKnob $w @{ ReleaseOutcome = 'retry' }
        $s = Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid)
        $s.Code | Should -Be 'release_pending'
        (Get-LinRes $w $rid).state | Should -Be 'deleting'
        @(Get-LinVms $w).Count | Should -Be 1
        @(Get-LinCalls $w 'RemoveVm *').Count | Should -Be 0
        Set-LinKnob $w @{ ReleaseOutcome = 'normal' }
        $B.Now = { [DateTime]::UtcNow.AddSeconds(60) }
        (Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid)).Action | Should -Be 'destroyed'
        @(Get-LinVms $w).Count | Should -Be 0
        (Get-LinRes $w $rid).teardown_proof.runner_deregistered | Should -BeTrue
    }

    It 'a drained VM kept past 6 h is flagged, never destroyed for time; a limit still removes it' -Tag 'drain-overdue', 'deleting-limits' {
        $w = New-LinWorld
        $B = New-LinBackend $w
        $r = New-LinReservation $w
        $rid = $r.reservation_id
        [void](Invoke-LinSteps $B $w $rid -Max 5 -Until { param($x) $x.state -eq 'ready' })
        [void](Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid))
        [void](Set-AapSlotState -Root $w.Cap -ReservationId $rid -LeaseGeneration $r.lease_generation -State draining -RelaxedTrustForTests)
        Set-LinKnob $w @{ ReleaseOutcome = 'retry' }
        (Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid)).Code | Should -Be 'release_pending'
        $B.Now = { [DateTime]::UtcNow.AddHours(6).AddMinutes(1) }
        (Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid)).Code | Should -Be 'drain_overdue'
        $B.Now = { [DateTime]::UtcNow.AddHours(6).AddMinutes(3) }
        (Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid)).Code | Should -Be 'drain_overdue'
        @(Get-LinVms $w).Count | Should -Be 1
        @(Get-LinCalls $w 'RemoveVm *').Count | Should -Be 0
        @(Get-LinJournal $w $rid | Where-Object { $_.result -and $_.result.detail -like 'drained VM kept 6 h*' }).Count | Should -Be 1
        Set-LinKnob $w @{ CloneBytes = 56 * $script:GiB }
        [void](Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid))
        @(Get-LinVms $w).Count | Should -Be 0
    }

    It 'binds the heartbeat to its own channel: a reply that names another reservation is hostile' -Tag 'reply-echo' {
        $w = New-LinWorld
        $B = New-LinBackend $w
        $r = New-LinReservation $w
        $rid = $r.reservation_id
        [void](Invoke-LinSteps $B $w $rid -Max 5 -Until { param($x) $x.state -eq 'ready' })
        [void](Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid))
        Set-LinKnob $w @{ Guest = @{ status = 'echo-reservation_id' } }
        $s = Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid)
        $s.Code | Should -Be 'wrong_echo'
        $s.Action | Should -Be 'destroyed'
        @(Get-LinVms $w).Count | Should -Be 0
    }

    It 'a heartbeat-quarantined slot returns to busy on a validated reply, with JobRunning from the broker' -Tag 'jobrunning', 'recover-broker' {
        $w = New-LinWorld
        $B = New-LinBackend $w
        $r = New-LinReservation $w
        $rid = $r.reservation_id
        [void](Invoke-LinSteps $B $w $rid -Max 5 -Until { param($x) $x.state -eq 'ready' })
        [void](Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid))
        Set-LinKnob $w @{ RunnerBusy = $true }
        [void](Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid))
        # Three missed heartbeats, as reconcile sees them 90 s later.
        & (Get-Module AapCapacity) { function script:Get-AapUtcNow { [DateTime]::UtcNow.AddSeconds(120) } }
        try { [void](Invoke-AapReconcile -Root $w.Cap -RelaxedTrustForTests) } finally { & (Get-Module AapCapacity) { function script:Get-AapUtcNow { [DateTime]::UtcNow } } }
        (Get-LinRes $w $rid).quarantine_kind | Should -Be 'heartbeat'
        Set-LinKnob $w @{ StatusOutcome = 'unavailable' }   # a reply alone is not enough: the broker must answer too
        (Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid)).Code | Should -Be 'broker_unavailable'
        (Get-LinRes $w $rid).state | Should -Be 'quarantined'
        Set-LinKnob $w @{ StatusOutcome = 'ok' }
        (Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid)).Action | Should -Be 'recovered'
        (Get-LinRes $w $rid).state | Should -Be 'busy'
    }
}

Describe 'the host-side limits hold on every step' {
    It 'destroys a VM whose clone passes clone_gib, cannot be measured, or is paused, in state <State>' -Tag 'clone-cap', 'vm-paused', 'limits-every-step' -ForEach @(
        @{ State = 'probing' }, @{ State = 'ready' }, @{ State = 'busy' }
    ) {
        foreach ($knob in @(@{ CloneBytes = 56 * $script:GiB }, @{ Paused = $true }, @{ MeasureFails = $true })) {
            $w = New-LinWorld
            $B = New-LinBackend $w
            $r = New-LinReservation $w
            $rid = $r.reservation_id
            if ($State -eq 'probing') { Set-LinKnob $w @{ BootProbes = 100 }; [void](Invoke-LinSteps $B $w $rid -Max 3) }
            else {
                [void](Invoke-LinSteps $B $w $rid -Max 5 -Until { param($x) $x.state -eq 'ready' })
                [void](Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid))
                if ($State -eq 'busy') { Set-LinKnob $w @{ RunnerBusy = $true }; [void](Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid)) }
            }
            Set-LinKnob $w $knob
            $s = Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid)
            $s.Action | Should -Be 'destroyed' -Because "$($knob.Keys) in $State"
            $fail = @(Get-LinJournal $w $rid | Where-Object { $_.phase -eq 'failed' -and $_.result.code -eq 'fatal' })
            $fail[0].result.detail | Should -BeIn @('clone over cap', 'vm paused', 'clone not measurable')
            @(Get-LinVms $w).Count | Should -Be 0
        }
    }

    It 'a heartbeat-quarantined clone over its cap or paused is destroyed from the host, with or without a restart' -Tag 'clone-cap', 'vm-paused', 'limits-every-step' {
        foreach ($case in @(@{ Knob = @{ CloneBytes = 56 * $script:GiB }; Restart = $false }, @{ Knob = @{ CloneBytes = 56 * $script:GiB }; Restart = $true }, @{ Knob = @{ Paused = $true }; Restart = $true })) {
            $w = New-LinWorld
            $B = New-LinBackend $w
            $r = New-LinReservation $w
            $rid = $r.reservation_id
            [void](Invoke-LinSteps $B $w $rid -Max 5 -Until { param($x) $x.state -eq 'ready' })
            [void](Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid))
            Set-LinKnob $w @{ RunnerBusy = $true; Guest = @{ status = 'timeout' } }   # the guest stops answering
            [void](Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid))
            & (Get-Module AapCapacity) { function script:Get-AapUtcNow { [DateTime]::UtcNow.AddSeconds(120) } }
            try { [void](Invoke-AapReconcile -Root $w.Cap -RelaxedTrustForTests) } finally { & (Get-Module AapCapacity) { function script:Get-AapUtcNow { [DateTime]::UtcNow } } }
            (Get-LinRes $w $rid).quarantine_kind | Should -Be 'heartbeat'
            Set-LinKnob $w $case.Knob
            if ($case.Restart) { $B = New-LinBackend $w }
            $s = Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid)
            $s.Action | Should -Be 'destroyed' -Because ($case.Knob.Keys -join ',')
            @(Get-LinVms $w).Count | Should -Be 0
            (Get-LinRes $w $rid).state | Should -Be 'reconciled'
            @(Get-LinJournal $w $rid | Where-Object { $_.op -eq 'run_one' -and $_.phase -eq 'failed' })[0].result.detail | Should -BeIn @('clone over cap', 'vm paused')
        }
    }

    It 'a drained VM kept for its release is held to its limits on every step, before the retry gate, after a restart too' -Tag 'deleting-limits' {
        foreach ($knob in @(@{ CloneBytes = 56 * $script:GiB }, @{ Paused = $true }, @{ MeasureFails = $true })) {
            foreach ($restart in $false, $true) {
                $w = New-LinWorld
                $B = New-LinBackend $w
                $r = New-LinReservation $w
                $rid = $r.reservation_id
                [void](Invoke-LinSteps $B $w $rid -Max 5 -Until { param($x) $x.state -eq 'ready' })
                [void](Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid))   # running, listening, no job
                [void](Set-AapSlotState -Root $w.Cap -ReservationId $rid -LeaseGeneration $r.lease_generation -State draining -RelaxedTrustForTests)
                Set-LinKnob $w @{ ReleaseOutcome = 'retry' }
                (Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid)).Code | Should -Be 'release_pending'
                @(Get-LinVms $w).Count | Should -Be 1
                # GitHub hands the still-listed runner a job; it writes past clone_gib, or the VM is paused.
                Set-LinKnob $w $knob
                if ($restart) { $B = New-LinBackend $w }
                $s = Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid)
                @(Get-LinVms $w).Count | Should -Be 0 -Because "$($knob.Keys) restart=$restart"
                $s.Code | Should -Be 'release_pending' -Because 'the VM is gone; the release still decides the slot'
                (Get-LinRes $w $rid).state | Should -Be 'deleting'
                @(Get-LinJournal $w $rid | Where-Object { $_.op -eq 'destroy' -and $_.result -and $_.result.detail -like 'limit broken while kept: *' }).Count | Should -Be 1
            }
        }
    }
}

Describe 'a subsequent job observes nothing of the previous one (ledger P11 acceptance)' {
    It 'two jobs on the same slot: new generation, VM name, VM, disk, key, seed and channel; the base unchanged; nothing planted survives' {
        $w = New-LinWorld
        $B = New-LinBackend $w
        $seen = @()
        foreach ($n in 1, 2) {
            $r = New-LinReservation $w
            $rid = $r.reservation_id
            [void](Invoke-LinSteps $B $w $rid -Max 5 -Until { param($x) $x.state -eq 'ready' })
            $vm = @(Get-LinVms $w)[0]
            $os = Join-Path $w.Clones "$rid\os.avhdx"
            $first = [IO.File]::ReadAllText($os)
            [void](Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid))   # the runner starts; the job plants its state in the clone
            [IO.File]::ReadAllText($os) | Should -Match 'job state: /home/runner planted'
            $seen += [pscustomobject]@{ Slot = $r.slot; Gen = $r.lease_generation; Name = $vm.Name; VmId = $vm.Id; Rid = $rid; Disk = $first
                Pub = [IO.File]::ReadAllText((Join-Path $w.Clones "$rid\ssh\id_ed25519.pub")); HostKey = $vm.HostKey; Guest = (Join-Path $w.Fake "guests\$($vm.Id).json")
                Key = [IO.File]::ReadAllBytes((Join-Path $w.Clones "$rid\ssh\id_ed25519"))
            }
            Set-LinKnob $w @{ RunnerStatus = 'absent' }
            [void](Invoke-LinSteps $B $w $rid -Max 3)
            (Get-LinRes $w $rid).state | Should -Be 'reconciled'
            Set-LinKnob $w @{ RunnerStatus = 'online' }
            Test-Path -LiteralPath (Join-Path $w.Clones $rid) | Should -BeFalse
        }
        $a, $b = $seen
        $b.Slot | Should -Be $a.Slot
        $b.Gen | Should -BeGreaterThan $a.Gen
        $b.Name | Should -Not -Be $a.Name
        $b.VmId | Should -Not -Be $a.VmId
        $b.Rid | Should -Not -Be $a.Rid
        $b.Pub | Should -Not -Be $a.Pub
        $b.HostKey | Should -Not -Be $a.HostKey
        # The second clone is a fresh differencing child of the pinned base, never of the first clone.
        $b.Disk | Should -BeExactly "differencing child of $($w.BaseFile)"
        $b.Disk | Should -Not -Match 'planted'
        (Get-FileHash -LiteralPath $w.BaseFile -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $w.BaseSha
        # The second guest's agent started from nothing: its own seq, nonces and one-shot commands.
        $g2 = Read-LinJson $b.Guest $null
        @($g2.Shots) | Should -Be @('deliver_registration', 'start_runner')
        # The first job's key opens nothing on the second VM (its seed authorized only the second key).
        (Get-LinPublicOf $a.Key) | Should -Not -Be (Get-LinPublicOf $b.Key)
        @(Get-LinLeases $w).Count | Should -Be 2
        @(Get-LinLeases $w | Where-Object { $_.state -eq 'issued' }).Count | Should -Be 0
    }
}
