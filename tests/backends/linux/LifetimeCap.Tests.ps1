# The hard VM lifetime cap in the Linux backend (ledger item P11.3, owner decision Q4: "Hard VM lifetime cap of 6 hours
# for all repositories"; allocator.md L1 to L8, B1 and B7; backend-lifecycle.md revision 3). Fake-backed
# (LinBackendTestHelpers.ps1): the reservation's start is moved back in allocator.json and the backend's wall clock pinned
# with knob ClockAt, so the boundary is exact to the second. Every journal record and every Notes record must pass
# parity/contracts/validate.py. Pester 5, Windows PowerShell 5.1 and PowerShell 7.5+.

BeforeAll {
    . (Join-Path $PSScriptRoot 'LinBackendTestHelpers.ps1')
    Import-Module $script:CapModule -Force
    Import-Module $script:BackendModule -Force

    $script:Cap = 6 * 3600
    # A reservation started $Ago seconds ago by the real clock, and the backend's clocks pinned: the wall clock 60 s after
    # that start (knob ClockAt), the boot-bound counter frozen (knob MonoMs) unless the test moves it. Returns the start.
    function Set-LinCapStart($w, [string]$Rid, [int]$Ago = (6 * 3600 + 120)) {
        $t0 = Set-LinStart $w $Rid $Ago
        if ($null -eq (Get-LinKnob $w 'MonoMs' $null)) { Set-LinKnob $w @{ MonoMs = 1000 } }
        Set-LinKnob $w @{ ClockAt = (Format-LinTime $t0.AddSeconds(60)) }
        $t0
    }
    # The same, stepped to ready, a runner started and a job running (the guest says busy, the broker says busy).
    function Start-LinCapJob($w, $B, [string]$Rid, [int]$Ago = (6 * 3600 + 120)) {
        $t0 = Set-LinCapStart $w $Rid $Ago
        $acts = @(Invoke-LinSteps $B $w $Rid -Max 5 -Until { param($x) $x.state -eq 'ready' } | ForEach-Object { $_.Action })
        ($acts -join ',') | Should -Be 'created,booted,ready'
        (Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $Rid)).Action | Should -Be 'running'
        Set-LinKnob $w @{ GuestStatus = 'busy'; RunnerBusy = $true }
        (Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $Rid)).Action | Should -Be 'busy'
        $t0
    }
    function Set-LinAt($w, [datetime]$T0, [long]$Seconds) { Set-LinKnob $w @{ ClockAt = (Format-LinTime $T0.AddSeconds($Seconds)) } }
    function Step-Lin($B, $w, [string]$Rid) { Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $Rid) -BaseSha256 $w.BaseSha }
    function Get-LinExchangeCount($w) { @([IO.Directory]::GetFiles((Join-Path $w.Fake 'exchanges'))).Count }
    function Get-LinCapRecords($w, [string]$Rid) { @(Get-LinJournal $w $Rid | Where-Object { $_.PSObject.Properties['lifetime_cap'] }) }
    function Get-LinCapFailed($w, [string]$Rid) { @(Get-LinJournal $w $Rid | Where-Object { $_.result -and $_.result.code -eq 'vm_lifetime_cap' }) }
}

Describe 'the cap fires at the boundary, from the host, whatever the guest or GitHub says' {
    It 'not one second before 6 h; at 6 h exactly: powered off, the job failed, evidence journaled, verified teardown' -Tag 'cap-deadline', 'cap-first', 'cap-once' {
        $w = New-LinWorld
        $B = New-LinBackend $w
        $rid = (New-LinReservation $w).reservation_id
        $t0 = Start-LinCapJob $w $B $rid
        $vmId = (Get-LinRes $w $rid).vm_id

        # 1 s before: a heartbeat as usual (the guest answers, the runner is busy on GitHub); nothing stops.
        Set-LinAt $w $t0 ($script:Cap - 1)
        (Step-Lin $B $w $rid).Action | Should -Be 'busy'
        @(Get-LinCalls $w 'StopVm *').Count | Should -Be 0
        Get-LinCapFailed $w $rid | Should -BeNullOrEmpty

        # At the cap: the guest still says busy and GitHub still says busy. Neither postpones it, and the guest is asked
        # nothing more: no status, no shutdown.
        $before = Get-LinExchangeCount $w
        $calls = @(Get-LinCalls $w).Count
        Set-LinAt $w $t0 $script:Cap
        $s = Step-Lin $B $w $rid
        $s.Code | Should -Be 'vm_lifetime_cap'
        $s.Action | Should -Be 'destroyed'
        Get-LinExchangeCount $w | Should -Be $before
        $after = @(Get-LinCalls $w | Select-Object -Skip $calls)
        $after[0] | Should -Be "StopVm $vmId" -Because 'the power-off comes before the release and every other call'
        @($after | Where-Object { $_ -like 'Broker status_request *' }).Count | Should -Be 0
        @($after | Where-Object { $_ -like 'Broker release_request *' }).Count | Should -Be 1

        # The job is reported failed with the reason; the destroy intent carries the evidence; all of it is contract.
        $j = @(Get-LinJournal $w $rid)
        $failed = @(Get-LinCapFailed $w $rid)
        @($failed | ForEach-Object { $_.op }) -join ',' | Should -Be 'run_one'
        $failed[0].result.detail | Should -Be 'vm lifetime cap reached; the VM was powered off'
        $cap = @(Get-LinCapRecords $w $rid)
        $cap.Count | Should -Be 1
        $cap[0].op | Should -Be 'destroy'
        $cap[0].phase | Should -Be 'intent'
        $cap[0].lifetime_cap.trigger | Should -Be 'deadline'
        $cap[0].lifetime_cap.cap_hours | Should -Be 6
        $cap[0].lifetime_cap.elapsed_s | Should -Be $script:Cap
        $cap[0].lifetime_cap.started_utc | Should -Be (Format-LinTime $t0)
        $cap[0].lifetime_cap.deadline_utc | Should -Be (Format-LinTime $t0.AddHours(6))
        $cap[0].lifetime_cap.power_off_utc | Should -Be (Format-LinTime $t0.AddHours(6))
        ($j | ForEach-Object { "$($_.op)/$($_.phase)" }) -join ' ' | Should -BeLike '* run_one/intent * run_one/failed destroy/intent destroy/done'
        Invoke-LinValidator $w 'backend-lifecycle' @(Get-LinJournalLines $w $rid) | Should -BeNullOrEmpty
        $s.LifetimeCap.reason | Should -Be 'vm_lifetime_cap'

        # The slot is freed only by the teardown proof: VM, clone folder, key and network gone, runner deregistered.
        $done = Get-LinRes $w $rid
        $done.state | Should -Be 'reconciled'
        $done.teardown_proof.vm_absent | Should -BeTrue
        $done.teardown_proof.runner_deregistered | Should -BeTrue
        @(Get-LinVms $w).Count | Should -Be 0
        Test-Path -LiteralPath (Join-Path $w.Clones $rid) | Should -BeFalse
    }

    It 'reclaims a guest that ignores shutdown and keeps working: the hypervisor turns it off, the guest is never asked' {
        $w = New-LinWorld
        $B = New-LinBackend $w
        $rid = (New-LinReservation $w).reservation_id
        $t0 = Start-LinCapJob $w $B $rid
        # The agent answers everything but would never shut down; it is never sent a shutdown in the first place.
        Set-LinKnob $w @{ Guest = @{ shutdown = 'silent' } }
        Set-LinAt $w $t0 ($script:Cap + 5)
        (Step-Lin $B $w $rid).Code | Should -Be 'vm_lifetime_cap'
        $cmds = @([IO.Directory]::GetFiles((Join-Path $w.Fake 'exchanges')) | ForEach-Object { (Read-LinJson $_ $null).cmd.cmd })
        $cmds | Should -Not -Contain 'shutdown'
        @(Get-LinCalls $w 'StopVm *').Count | Should -BeGreaterOrEqual 1
        (Get-LinRes $w $rid).state | Should -Be 'reconciled'
    }

    It 'a heartbeat, a busy runner or a guest reply just before the cap never moves it' -Tag 'cap-deadline' {
        $w = New-LinWorld
        $B = New-LinBackend $w
        $rid = (New-LinReservation $w).reservation_id
        $t0 = Start-LinCapJob $w $B $rid
        foreach ($t in @(($script:Cap - 30), ($script:Cap - 10), ($script:Cap - 1))) {
            Set-LinAt $w $t0 $t
            (Step-Lin $B $w $rid).Action | Should -Be 'busy'
        }
        Set-LinKnob $w @{ GuestStatus = 'listening'; RunnerBusy = $false; RunnerStatus = 'online' }
        Set-LinAt $w $t0 $script:Cap
        (Step-Lin $B $w $rid).Code | Should -Be 'vm_lifetime_cap'
    }

    It 'a lower cap in force applies at once; a cap outside 1..6 counts as the 6 h ceiling' -Tag 'cap-hours' {
        $w = New-LinWorld
        $B = New-LinBackend $w -CapArgs @{ CapHours = 1 }
        $rid = (New-LinReservation $w).reservation_id
        $t0 = Start-LinCapJob $w $B $rid -Ago (3600 + 120)
        Set-LinAt $w $t0 3599
        (Step-Lin $B $w $rid).Action | Should -Be 'busy'
        $B.CapHours = 9   # never above the ceiling
        Set-LinAt $w $t0 3600
        (Step-Lin $B $w $rid).Action | Should -Be 'busy'
        $B.CapHours = 1
        $s = Step-Lin $B $w $rid
        $s.Code | Should -Be 'vm_lifetime_cap'
        $s.LifetimeCap.cap_hours | Should -Be 1
        $s.LifetimeCap.deadline_utc | Should -Be (Format-LinTime $t0.AddHours(1))
        Invoke-LinValidator $w 'backend-lifecycle' @(Get-LinJournalLines $w $rid) | Should -BeNullOrEmpty
    }
}

Describe 'the cap survives a supervisor restart and a clock stepped back' {
    It 'a restarted supervisor decides again from the persisted start, not from memory' {
        $w = New-LinWorld
        $B = New-LinBackend $w
        $rid = (New-LinReservation $w).reservation_id
        $t0 = Start-LinCapJob $w $B $rid
        Set-LinAt $w $t0 ($script:Cap - 600)
        (Step-Lin $B $w $rid).Action | Should -Be 'busy'
        $B2 = New-LinBackend $w   # a new supervisor process: nothing of the first one's memory
        Set-LinAt $w $t0 $script:Cap
        $s = Step-Lin $B2 $w $rid
        $s.Code | Should -Be 'vm_lifetime_cap'
        (Get-LinRes $w $rid).state | Should -Be 'reconciled'
    }

    It 'a restart after the evidence was written writes none again and never un-caps, even with the clock far behind' -Tag 'cap-journal', 'cap-once' {
        $w = New-LinWorld
        $B = New-LinBackend $w
        $rid = (New-LinReservation $w).reservation_id
        $t0 = Start-LinCapJob $w $B $rid
        Set-LinKnob $w @{ ReleaseOutcome = 'retry' }   # GitHub keeps the runner: the slot waits in deleting
        Set-LinAt $w $t0 $script:Cap
        $s = Step-Lin $B $w $rid
        $s.Code | Should -Be 'release_pending'
        $s.LifetimeCap.trigger | Should -Be 'deadline'
        (Get-LinRes $w $rid).state | Should -Be 'deleting'
        @(Get-LinVms $w).Count | Should -Be 0

        # Restart with the wall clock 5 h behind the start of the cap: the journal is the durable latch.
        $B2 = New-LinBackend $w
        Set-LinAt $w $t0 3600
        Set-LinKnob $w @{ ReleaseOutcome = 'normal' }
        $s2 = Step-Lin $B2 $w $rid
        $s2.Action | Should -Be 'destroyed'
        $s2.Code | Should -Be 'vm_lifetime_cap'
        $s2.LifetimeCap.power_off_utc | Should -Be (Format-LinTime $t0.AddHours(6))
        @(Get-LinCapRecords $w $rid).Count | Should -Be 1
        @(Get-LinCapFailed $w $rid).Count | Should -Be 1
        (Get-LinRes $w $rid).state | Should -Be 'reconciled'
        Invoke-LinValidator $w 'backend-lifecycle' @(Get-LinJournalLines $w $rid) | Should -BeNullOrEmpty
    }

    It 'a clock stepped back an hour 10 s before the cap does not extend it: true time runs on the boot-bound counter' -Tag 'true-now' {
        $w = New-LinWorld
        Set-LinKnob $w @{ MonoMs = 1000 }
        $B = New-LinBackend $w
        $rid = (New-LinReservation $w).reservation_id
        $t0 = Start-LinCapJob $w $B $rid
        Set-LinKnob $w @{ MonoMs = 5000000 }
        Set-LinAt $w $t0 ($script:Cap - 10)
        (Step-Lin $B $w $rid).Action | Should -Be 'busy'
        Set-LinKnob $w @{ MonoMs = 5010000 }        # 10 s later by the counter,
        Set-LinAt $w $t0 ($script:Cap - 3610)      # but the wall clock now reads an hour earlier
        $s = Step-Lin $B $w $rid
        $s.Code | Should -Be 'vm_lifetime_cap'
        $s.LifetimeCap.elapsed_s | Should -Be $script:Cap
        $s.LifetimeCap.power_off_utc | Should -Be (Format-LinTime $t0.AddHours(6))
        Invoke-LinValidator $w 'backend-lifecycle' @(Get-LinJournalLines $w $rid) | Should -BeNullOrEmpty
    }

    It 'both rollback windows: the wall clock behind the start, and stepped back while the power-off runs' -Tag 'true-now' {
        # Window 1: at the cap the wall clock reads an hour before the reservation started.
        $w = New-LinWorld
        Set-LinKnob $w @{ MonoMs = 1000 }
        $B = New-LinBackend $w
        $rid = (New-LinReservation $w).reservation_id
        $t0 = Start-LinCapJob $w $B $rid
        Set-LinKnob $w @{ MonoMs = 9000000 }
        Set-LinAt $w $t0 ($script:Cap - 5)
        (Step-Lin $B $w $rid).Action | Should -Be 'busy'
        Set-LinKnob $w @{ MonoMs = 9005000 }
        Set-LinAt $w $t0 -3600
        $s = Step-Lin $B $w $rid
        $s.LifetimeCap.trigger | Should -Be 'deadline'
        @(Get-LinVms $w).Count | Should -Be 0
        # The allocator takes no teardown proof observed before the reservation started: the slot waits for the wall clock.
        $s.Code | Should -Be 'invalid_proof'
        (Get-LinRes $w $rid).state | Should -Be 'deleting'
        $rec = @(Get-LinCapRecords $w $rid)[0]
        [string]$rec.at | Should -Be (Format-LinTime $t0.AddHours(6))
        Invoke-LinValidator $w 'backend-lifecycle' @(Get-LinJournalLines $w $rid) | Should -BeNullOrEmpty

        # Window 2: the wall clock steps back two hours while Stop-Vm runs; the evidence's at never precedes the power-off.
        $w = New-LinWorld
        $B = New-LinBackend $w
        $rid = (New-LinReservation $w).reservation_id
        $t0 = Start-LinCapJob $w $B $rid
        Set-LinKnob $w @{ StopVmSetsClock = (Format-LinTime $t0.AddSeconds($script:Cap + 20 - 7200)) }
        Set-LinAt $w $t0 ($script:Cap + 20)
        (Step-Lin $B $w $rid).Code | Should -Be 'vm_lifetime_cap'
        $rec = @(Get-LinCapRecords $w $rid)[0]
        $rec.lifetime_cap.power_off_utc | Should -Be (Format-LinTime $t0.AddSeconds($script:Cap + 20))
        [string]$rec.at | Should -Be (Format-LinTime $t0.AddSeconds($script:Cap + 20))
        Invoke-LinValidator $w 'backend-lifecycle' @(Get-LinJournalLines $w $rid) | Should -BeNullOrEmpty
    }

    It 'after a host reboot or a lost clock record, every VM found at the first look is capped, without invented age' -Tag 'cap-safety' {
        foreach ($trigger in 'host_reboot', 'clock_unavailable') {
            $w = New-LinWorld
            $B = New-LinBackend $w
            $rid = (New-LinReservation $w).reservation_id
            $t0 = Start-LinCapJob $w $B $rid -Ago 7200
            Set-LinAt $w $t0 7260
            $B2 = New-LinBackend $w -CapArgs @{ ClockSafety = $trigger }
            $s = Step-Lin $B2 $w $rid
            $s.Code | Should -Be 'vm_lifetime_cap'
            $s.LifetimeCap.trigger | Should -Be $trigger
            $s.LifetimeCap.elapsed_s | Should -Be 7260 -Because 'the measured age, below the cap, never six invented hours'
            (Get-LinRes $w $rid).state | Should -Be 'reconciled'
            Invoke-LinValidator $w 'backend-lifecycle' @(Get-LinJournalLines $w $rid) | Should -BeNullOrEmpty
        }
        # A reservation with no VM yet is not capped by a clock-safety decision: it gets its first VM normally.
        $w = New-LinWorld
        $B = New-LinBackend $w -CapArgs @{ ClockSafety = 'host_reboot' }
        $rid = (New-LinReservation $w).reservation_id
        (Step-Lin $B $w $rid).Action | Should -Be 'created'
        # A VM found off at the first look is capped too: recovery never starts it.
        $B2 = New-LinBackend $w -CapArgs @{ ClockSafety = 'host_reboot' }
        $s = Step-Lin $B2 $w $rid
        $s.Code | Should -Be 'vm_lifetime_cap'
        $s.LifetimeCap.trigger | Should -Be 'host_reboot'
        @(Get-LinCalls $w 'StartVm *').Count | Should -Be 0
        (Get-LinRes $w $rid).state | Should -Be 'reconciled'
        Invoke-LinValidator $w 'backend-lifecycle' @(Get-LinJournalLines $w $rid) | Should -BeNullOrEmpty
    }
}

Describe 'a VM that will not go off, and nothing ever starts a capped VM' {
    It 'a VM still running after the power-off is an unresolved cap_breach: held, the power-off repeated, nothing reused' -Tag 'cap-breach' {
        $w = New-LinWorld
        $B = New-LinBackend $w
        $rid = (New-LinReservation $w).reservation_id
        $t0 = Start-LinCapJob $w $B $rid
        Set-LinKnob $w @{ StopVmNoop = $true }
        $before = Get-LinExchangeCount $w
        Set-LinAt $w $t0 $script:Cap
        $s = Step-Lin $B $w $rid
        $s.Action | Should -Be 'held'
        $s.Code | Should -Be 'cap_breach'
        Set-LinAt $w $t0 ($script:Cap + 5)
        (Step-Lin $B $w $rid).Code | Should -Be 'cap_breach'
        @(Get-LinCalls $w 'StopVm *').Count | Should -Be 2
        @(Get-LinCalls $w 'RemoveVm *').Count | Should -Be 0
        @(Get-LinCalls $w 'Broker release_request *').Count | Should -Be 0
        Get-LinExchangeCount $w | Should -Be $before
        (Get-LinRes $w $rid).state | Should -Be 'deleting'
        @(Get-LinJournal $w $rid | Where-Object { $_.result -and $_.result.detail -eq 'cap_breach' }).Count | Should -Be 1
        # Once the VM is observed off the ordinary teardown completes.
        Set-LinKnob $w @{ StopVmNoop = $false }
        Set-LinAt $w $t0 ($script:Cap + 10)
        (Step-Lin $B $w $rid).Action | Should -Be 'destroyed'
        Invoke-LinValidator $w 'backend-lifecycle' @(Get-LinJournalLines $w $rid) | Should -BeNullOrEmpty
    }

    It 'a replayed boot of a reservation past its cap issues no start; a start that returns past the deadline is powered off' -Tag 'cap-deadline', 'cap-after-start' {
        # Created, the supervisor gone before the start, back after the cap.
        $w = New-LinWorld
        $B = New-LinBackend $w
        $rid = (New-LinReservation $w).reservation_id
        $t0 = Set-LinCapStart $w $rid ($script:Cap + 120)
        Set-LinAt $w $t0 60
        (Step-Lin $B $w $rid).Action | Should -Be 'created'
        $B2 = New-LinBackend $w
        Set-LinAt $w $t0 $script:Cap
        (Step-Lin $B2 $w $rid).Code | Should -Be 'vm_lifetime_cap'
        @(Get-LinCalls $w 'StartVm *').Count | Should -Be 0
        (Get-LinRes $w $rid).state | Should -Be 'reconciled'

        # The start itself returns at the deadline: powered off at once, boot closed with the code, never ready.
        $w = New-LinWorld
        $B = New-LinBackend $w
        $rid = (New-LinReservation $w).reservation_id
        $t0 = Set-LinCapStart $w $rid ($script:Cap + 120)
        Set-LinAt $w $t0 ($script:Cap - 60)
        (Step-Lin $B $w $rid).Action | Should -Be 'created'
        Set-LinKnob $w @{ StartVmSetsClock = (Format-LinTime $t0.AddSeconds($script:Cap)) }
        $s = Step-Lin $B $w $rid
        $s.Code | Should -Be 'vm_lifetime_cap'
        @(Get-LinCapFailed $w $rid | ForEach-Object { $_.op }) -join ',' | Should -Be 'boot'
        @(Get-LinCalls $w 'StopVm *').Count | Should -BeGreaterOrEqual 1
        (Get-LinRes $w $rid).state | Should -Be 'reconciled'
        Invoke-LinValidator $w 'backend-lifecycle' @(Get-LinJournalLines $w $rid) | Should -BeNullOrEmpty
    }

    It 'a reservation past its cap before any VM exists: no VM, the create closed with the code, freed as never registered' -Tag 'cap-deadline' {
        $w = New-LinWorld
        $B = New-LinBackend $w
        $rid = (New-LinReservation $w).reservation_id
        $t0 = Set-LinCapStart $w $rid ($script:Cap + 120)
        Set-LinAt $w $t0 $script:Cap
        $s = Step-Lin $B $w $rid
        $s.Code | Should -Be 'vm_lifetime_cap'
        @(Get-LinCalls $w 'NewVm *').Count | Should -Be 0
        @(Get-LinCapFailed $w $rid | ForEach-Object { $_.op }) -join ',' | Should -Be 'create'
        $done = Get-LinRes $w $rid
        $done.state | Should -Be 'reconciled'
        $done.teardown_proof.runner_deregistered | Should -Be 'never_registered'
        Invoke-LinValidator $w 'backend-lifecycle' @(Get-LinJournalLines $w $rid) | Should -BeNullOrEmpty
    }

    It 'Invoke-AapLinCapPass powers off every due VM before any teardown of any of them' {
        $w = New-LinWorld -Linux 2
        $B = New-LinBackend $w
        $ids = @((New-LinReservation $w).reservation_id, (New-LinReservation $w).reservation_id)
        $t0 = Set-LinCapStart $w $ids[0] ($script:Cap + 120)
        [void](Set-LinCapStart $w $ids[1] ($script:Cap + 120))
        Set-LinAt $w $t0 60
        foreach ($id in $ids) { [void](Invoke-LinSteps $B $w $id -Max 5 -Until { param($x) $x.state -eq 'ready' }) }
        Set-LinAt $w $t0 ($script:Cap + 1)
        $calls = @(Get-LinCalls $w).Count
        $res = @((Get-AapAllocatorState -Root $w.Cap -RelaxedTrustForTests).State.reservations | Where-Object { $ids -contains $_.reservation_id })
        $latched = @(Invoke-AapLinCapPass -Backend $B -Reservations $res)
        @($latched | Sort-Object) -join ',' | Should -Be (@($ids | Sort-Object) -join ',')
        $after = @(Get-LinCalls $w | Select-Object -Skip $calls)
        @($after | Where-Object { $_ -like 'StopVm *' }).Count | Should -Be 2
        @($after | Where-Object { $_ -like 'RemoveVm *' -or $_ -like 'Broker *' -or $_ -like 'NetDetach *' }).Count | Should -Be 0
        @(Get-LinVms $w | Where-Object { $_.State -ne 'Off' }).Count | Should -Be 0
        foreach ($id in $ids) { (Step-Lin $B $w $id).Code | Should -Be 'vm_lifetime_cap' }
        @($ids | ForEach-Object { (Get-LinRes $w $_).state }) -join ',' | Should -Be 'reconciled,reconciled'
    }
}

Describe 'the deadline record in the VM Notes and the start gate' {
    It 'writes the B1 record into the VM Notes before the first start, reads it back, and it validates' -Tag 'create-notes' {
        $w = New-LinWorld
        $B = New-LinBackend $w
        $r = New-LinReservation $w
        $rid = $r.reservation_id
        [void](Invoke-LinSteps $B $w $rid -Max 5 -Until { param($x) $x.state -eq 'ready' })
        $vm = @(Get-LinVms $w)[0]
        $calls = @(Get-LinCalls $w)
        [array]::IndexOf($calls, "SetVmNotes $($vm.Id)") | Should -BeLessThan ([array]::IndexOf($calls, "StartVm $($vm.Id)"))
        $n = ConvertFrom-LinJson ([string]$vm.Notes)
        $n.vm_id | Should -Be $vm.Id
        $n.vm_name | Should -Be $vm.Name
        $n.reservation_id | Should -Be $rid
        $a = (Get-LinRes $w $rid).acquired_at
        $start = $(if ($a -is [datetime]) { $a.ToUniversalTime() } else { [DateTime]::ParseExact([string]$a, "yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture, 'AssumeUniversal, AdjustToUniversal') })
        $n.started_utc | Should -Be (Format-LinTime $start)
        $n.deadline_utc | Should -Be (Format-LinTime $start.AddHours(6)) -Because 'the 6 h ceiling, never the configured cap'
        ([string]$vm.Notes).Length | Should -BeLessThan 1024
        Invoke-LinValidator $w 'vm-cap-notes' @([string]$vm.Notes) | Should -BeNullOrEmpty

        # Notes that do not read back as written: the clone is given up before it ever starts.
        $w = New-LinWorld
        $B = New-LinBackend $w
        Set-LinKnob $w @{ NotesLost = $true }
        $rid = (New-LinReservation $w).reservation_id
        [void](Invoke-LinSteps $B $w $rid -Max 4)
        @(Get-LinCalls $w 'StartVm *').Count | Should -Be 0
        @(Get-LinJournal $w $rid | Where-Object { $_.result -and $_.result.detail -like '*AAP_NotesInvalid*' }).Count | Should -Be 1
        (Get-LinRes $w $rid).state | Should -Be 'reconciled'
    }

    It 'starts nothing while the watchdog record is missing, stale, of another boot or reports a breach, or the Notes changed' -Tag 'start-gate', 'start-notes', 'backstop-boot', 'backstop-fresh', 'backstop-breach' {
        foreach ($how in 'missing', 'stale', 'reboot', 'breach', 'notes', 'unconfigured') {
            $w = New-LinWorld
            $B = $(if ($how -eq 'unconfigured') { New-LinBackend $w -CapArgs @{ WatchdogClockPath = '' } } else { New-LinBackend $w })
            $rid = (New-LinReservation $w).reservation_id
            (Step-Lin $B $w $rid).Action | Should -Be 'created'
            if ($how -eq 'notes') { $vms = @(Get-LinVms $w); $vms[0].Notes = ([string]$vms[0].Notes).Replace('"schema":1', '"schema":1 '); Save-LinVms $w $vms }
            elseif ($how -ne 'unconfigured') { Set-LinKnob $w @{ Watchdog = $how } }
            $s = Step-Lin $B $w $rid
            $s.Action | Should -Be 'waiting' -Because $how
            $s.Code | Should -Be $(if ($how -eq 'notes') { 'notes_unverified' } else { 'backstop_down' }) -Because $how
            (Step-Lin $B $w $rid).Action | Should -Be 'waiting' -Because $how
            @(Get-LinCalls $w 'StartVm *').Count | Should -Be 0 -Because $how
            (Get-LinRes $w $rid).state | Should -Be 'creating' -Because $how
            @(Get-LinJournal $w $rid | Where-Object { $_.op -eq 'boot' }).Count | Should -Be 0 -Because 'a refused start journals nothing'
        }
        # A healthy watchdog lets it boot.
        Set-LinKnob $w @{ Watchdog = 'fresh' }
        $B = New-LinBackend $w
        (Step-Lin $B $w $rid).Action | Should -Be 'booted'
    }

    It 'refuses a start whose 6 h deadline has passed by true time even under a higher cap in memory' -Tag 'start-deadline' {
        $w = New-LinWorld
        $B = New-LinBackend $w
        $rid = (New-LinReservation $w).reservation_id
        $t0 = Set-LinCapStart $w $rid ($script:Cap + 120)
        Set-LinAt $w $t0 60
        (Step-Lin $B $w $rid).Action | Should -Be 'created'
        # Inside the backend: the gate itself, called for a reservation the cap has not latched (a cap check skipped).
        Set-LinAt $w $t0 $script:Cap
        $why = Invoke-LinInModule { param($B, $r, $id) Get-AapLinStartProblem $B $r $id } @($B, (Get-LinRes $w $rid), @(Get-LinVms $w)[0].Id)
        $why | Should -Be 'deadline_passed'
    }
}
