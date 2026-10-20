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
        # The ops in order, intent before every outcome.
        $j = Get-WinJournal $w $rid
        ($j | ForEach-Object { "$($_.op)/$($_.phase)" }) -join ' ' | Should -Be ('create/intent create/done boot/intent boot/done ready/intent ready/done run_one/intent run_one/done ' +
            'collect/intent collect/done destroy/intent destroy/done')
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

    It 'destroys a VM whose clone folder passes clone_gib (fatal, clone over cap), and a paused VM' -Tag 'clone-cap', 'vm-paused' {
        foreach ($knob in @(@{ CloneBytes = 61 * $script:GiB }, @{ Paused = $true })) {
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
            $fail[0].result.detail | Should -BeIn @('clone over cap', 'vm paused')
            @(Get-WinVms $w).Count | Should -Be 0
        }
    }

    It 'a heartbeat-quarantined slot returns to busy on a validated reply, with JobRunning from the broker' -Tag 'jobrunning' {
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
        (Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid)).Action | Should -Be 'recovered'
        (Get-WinRes $w $rid).state | Should -Be 'busy'
    }
}
