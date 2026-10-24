# A supervisor killed at every lifecycle boundary (backend-lifecycle.md, "Crash at every boundary"): a real child process
# builds the backend over a file-backed world and kills itself at a fault point (exit -1, P09's pattern: plain .ps1 files,
# hidden, nothing but paths on its command line). A fresh backend in this process, which never saw the child's memory,
# then steps the reservation until it is reconciled, and the invariants hold: never a second VM, never a second lease, no
# issued lease left unreleased, no command the guest refused (the seq mark carried the channel across the kill), the slot
# freed only with an observed teardown proof, every journal record valid, no secret in any file, the private key nowhere
# once the clone is gone. Pester 5, Windows PowerShell 5.1 and PowerShell 7.5+.

BeforeAll {
    . (Join-Path $PSScriptRoot 'LinBackendTestHelpers.ps1')
    Import-Module $script:CapModule -Force
    Import-Module $script:BackendModule -Force

    # Steps until reconciled; a release still pending for a lease call the broker never recorded is retried 16 minutes
    # later (the lease window), with the allocator's clock moved alike so the proof's time is accepted.
    function Invoke-LinRecover($B, $w, [string]$Id) {
        $res = @(Invoke-LinSteps $B $w $Id -Max 14)
        if ((Get-LinRes $w $Id).state -ne 'reconciled') {
            $B.Now = { [DateTime]::UtcNow.AddMinutes(16) }
            & (Get-Module AapCapacity) { function script:Get-AapUtcNow { [DateTime]::UtcNow.AddMinutes(16) } }
            try { $res += @(Invoke-LinSteps $B $w $Id -Max 4) } finally { & (Get-Module AapCapacity) { function script:Get-AapUtcNow { [DateTime]::UtcNow } } }
        }
        $res
    }

    function Assert-LinSound($w, [string]$Id, [string]$Name) {
        $r = Get-LinRes $w $Id
        $r.state | Should -Be 'reconciled'
        $r.teardown_proof.vm_absent | Should -BeTrue
        $r.teardown_proof.disks_absent | Should -BeTrue
        @(Get-LinVms $w).Count | Should -Be 0
        Test-Path -LiteralPath (Join-Path $w.Clones $Id) | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $w.Scratch $Id) | Should -BeFalse
        @(Get-LinCalls $w "NewVm $Name").Count | Should -BeLessOrEqual 1 -Because 'never a second VM'
        @(Get-LinCalls $w 'Broker lease_request *').Count | Should -BeLessOrEqual 1 -Because 'one lease id per reservation'
        @(Get-LinLeases $w | Where-Object { $_.state -eq 'issued' }).Count | Should -Be 0 -Because 'every issued lease is released'
        @(Get-ChildItem -LiteralPath (Join-Path $w.Fake 'exchanges') | ForEach-Object { Read-LinJson $_.FullName $null } | Where-Object { $_.reply.status -eq 'refused' }).Count |
            Should -Be 0 -Because 'the restarted supervisor never sent a seq the guest had already seen'
        Invoke-LinValidator $w 'backend-lifecycle' @(Get-LinJournalLines $w $Id) | Should -BeNullOrEmpty
        Find-LinSecret $w @('SYNTHETIC-JIT-MARKER', 'FAKE-PRIVATE-KEY') -All | Should -BeNullOrEmpty
    }
}

Describe 'killed at every lifecycle boundary' {
    It 'killed at <Fault>: recovered from the journal' -ForEach @(
        @{ Fault = 'create:after-intent'; Knobs = @{} }, @{ Fault = 'create:after-folders'; Knobs = @{} }, @{ Fault = 'create:after-disks'; Knobs = @{} }, @{ Fault = 'create:after-key'; Knobs = @{} }
        @{ Fault = 'create:after-seed'; Knobs = @{} }, @{ Fault = 'create:after-newvm'; Knobs = @{} }, @{ Fault = 'create:after-vm'; Knobs = @{} }, @{ Fault = 'create:after-done'; Knobs = @{} }
        @{ Fault = 'create:before-seed-publish'; Knobs = @{} }
        @{ Fault = 'create:after-attach'; Knobs = @{} }, @{ Fault = 'boot:after-checks'; Knobs = @{} }
        @{ Fault = 'boot:after-intent'; Knobs = @{} }, @{ Fault = 'boot:after-done'; Knobs = @{} }, @{ Fault = 'ready:after-pin'; Knobs = @{} }, @{ Fault = 'ready:after-eject'; Knobs = @{} }, @{ Fault = 'ready:after-done'; Knobs = @{} }
        @{ Fault = 'run_one:after-intent'; Knobs = @{} }, @{ Fault = 'run_one:after-lease'; Knobs = @{} }, @{ Fault = 'run_one:after-deliver'; Knobs = @{} }, @{ Fault = 'run_one:after-start'; Knobs = @{} }
        @{ Fault = 'collect:after-intent'; Knobs = @{ RunnerStatus = 'absent' } }
        @{ Fault = 'destroy:after-intent'; Knobs = @{ RunnerStatus = 'absent' } }, @{ Fault = 'destroy:after-release'; Knobs = @{ RunnerStatus = 'absent' } }
        @{ Fault = 'destroy:after-vm'; Knobs = @{ RunnerStatus = 'absent' } }, @{ Fault = 'destroy:after-done'; Knobs = @{ RunnerStatus = 'absent' } }
    ) {
        $w = New-LinWorld
        if ($Knobs) { Set-LinKnob $w $Knobs }
        $r = New-LinReservation $w
        $id = $r.reservation_id
        $name = Get-AapVmName -Profile linux -Slot $r.slot -LeaseGeneration $r.lease_generation -ReservationId $id
        $c = Start-LinChild $w $Fault $id 12
        $c.ExitCode | Should -Be -1 -Because "the child must be killed at $Fault (stdout: $($c.Out) stderr: $($c.Err))"
        Set-LinKnob $w @{ RunnerStatus = 'absent' }   # a recovered clone runs its job to the end; the job ends at once
        $B = New-LinBackend $w
        [void](Invoke-LinRecover $B $w $id)
        Assert-LinSound $w $id $name
        # The slot's next reservation takes a new generation.
        (New-LinReservation $w).lease_generation | Should -BeGreaterThan $r.lease_generation
    }

    It 'killed in a drain: the restarted supervisor finishes it (drain, collect, destroy)' {
        $w = New-LinWorld
        $r = New-LinReservation $w
        $id = $r.reservation_id
        $B = New-LinBackend $w
        [void](Invoke-LinSteps $B $w $id -Max 5 -Until { param($x) $x.state -eq 'ready' })
        [void](Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $id))   # running, listening
        [void](Set-AapSlotState -Root $w.Cap -ReservationId $id -LeaseGeneration $r.lease_generation -State draining -RelaxedTrustForTests)
        $c = Start-LinChild $w 'drain:after-intent' $id 4
        $c.ExitCode | Should -Be -1 -Because "stdout: $($c.Out) stderr: $($c.Err)"
        $B = New-LinBackend $w
        [void](Invoke-LinRecover $B $w $id)
        Assert-LinSound $w $id (Get-AapVmName -Profile linux -Slot $r.slot -LeaseGeneration $r.lease_generation -ReservationId $id)
    }

    It 'killed while a job runs: the restarted supervisor never cancels it, keeps its heartbeats, and tears down after it ended' {
        $w = New-LinWorld
        Set-LinKnob $w @{ RunnerBusy = $true }
        $r = New-LinReservation $w
        $id = $r.reservation_id
        $c = Start-LinChild $w 'run_one:after-start' $id 12
        $c.ExitCode | Should -Be -1
        $B = New-LinBackend $w
        $res = @(Invoke-LinSteps $B $w $id -Max 4)
        @($res | Where-Object { $_.Action -ne 'busy' -or $_.Code -ne 'ok' }).Count | Should -Be 0
        @(Get-LinVms $w).Count | Should -Be 1
        @(Get-LinCalls $w 'StopVm *').Count | Should -Be 0
        Set-LinKnob $w @{ RunnerBusy = $false; RunnerStatus = 'absent' }
        [void](Invoke-LinRecover $B $w $id)
        Assert-LinSound $w $id (Get-AapVmName -Profile linux -Slot $r.slot -LeaseGeneration $r.lease_generation -ReservationId $id)
    }
}
