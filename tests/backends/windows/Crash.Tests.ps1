# A supervisor killed at every lifecycle boundary (backend-lifecycle.md, "Crash at every boundary"): a real child process
# builds the backend over a file-backed world and kills itself at a fault point (exit -1, P09's pattern: plain .ps1 files,
# hidden, nothing but paths on its command line). A fresh backend in this process, which never saw the child's memory and
# so holds no guest credential, then steps the reservation until it is reconciled, and the invariants hold: never a second
# VM, never a second lease, no issued lease left unreleased, the slot freed only with an observed teardown proof, every
# journal record valid, no secret in any file. Pester 5, Windows PowerShell 5.1 and PowerShell 7.5+.

BeforeAll {
    . (Join-Path $PSScriptRoot 'WinBackendTestHelpers.ps1')
    Import-Module $script:CapModule -Force
    Import-Module $script:BackendModule -Force

    # Steps until reconciled; a release still pending for a lease call the broker never recorded is retried 16 minutes
    # later (the lease window), with the allocator's clock moved alike so the proof's time is accepted.
    function Invoke-WinRecover($B, $w, [string]$Id) {
        $res = @(Invoke-WinSteps $B $w $Id -Max 12)
        if ((Get-WinRes $w $Id).state -ne 'reconciled') {
            $B.Now = { [DateTime]::UtcNow.AddMinutes(16) }
            & (Get-Module AapCapacity) { function script:Get-AapUtcNow { [DateTime]::UtcNow.AddMinutes(16) } }
            try { $res += @(Invoke-WinSteps $B $w $Id -Max 4) } finally { & (Get-Module AapCapacity) { function script:Get-AapUtcNow { [DateTime]::UtcNow } } }
        }
        $res
    }

    function Assert-WinSound($w, [string]$Id, [string]$Name) {
        $r = Get-WinRes $w $Id
        $r.state | Should -Be 'reconciled'
        $r.teardown_proof.vm_absent | Should -BeTrue
        $r.teardown_proof.disks_absent | Should -BeTrue
        @(Get-WinVms $w).Count | Should -Be 0
        Test-Path -LiteralPath (Join-Path $w.Clones $Id) | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $w.Scratch $Id) | Should -BeFalse
        @(Get-WinCalls $w "NewVm $Name").Count | Should -BeLessOrEqual 1 -Because 'never a second VM'
        @(Get-WinCalls $w 'Broker lease_request *').Count | Should -BeLessOrEqual 1 -Because 'one lease id per reservation'
        @(Get-WinLeases $w | Where-Object { $_.state -eq 'issued' }).Count | Should -Be 0 -Because 'every issued lease is released'
        Invoke-WinValidator $w 'backend-lifecycle' @(Get-WinJournalLines $w $Id) | Should -BeNullOrEmpty
        Find-WinSecret $w @('SYNTHETIC-JIT-MARKER') | Should -BeNullOrEmpty
    }
}

Describe 'killed at every lifecycle boundary' {
    It 'killed at <Fault>: recovered from the journal' -ForEach @(
        @{ Fault = 'create:after-intent' }, @{ Fault = 'create:after-folders' }, @{ Fault = 'create:after-disks' }, @{ Fault = 'create:after-unattend' }
        @{ Fault = 'create:after-newvm' }, @{ Fault = 'create:after-vm' }, @{ Fault = 'create:after-done' }, @{ Fault = 'boot:after-intent' }, @{ Fault = 'boot:after-done' }
        @{ Fault = 'ready:after-done' }, @{ Fault = 'run_one:after-intent' }, @{ Fault = 'run_one:after-lease' }, @{ Fault = 'run_one:after-deliver' }
        @{ Fault = 'run_one:after-start' }, @{ Fault = 'collect:after-intent'; Knobs = @{ RunnerStatus = 'absent' } }
        @{ Fault = 'destroy:after-intent'; Knobs = @{ RunnerStatus = 'absent' } }, @{ Fault = 'destroy:after-release'; Knobs = @{ RunnerStatus = 'absent' } }
        @{ Fault = 'destroy:after-vm'; Knobs = @{ RunnerStatus = 'absent' } }, @{ Fault = 'destroy:after-done'; Knobs = @{ RunnerStatus = 'absent' } }
    ) {
        $w = New-WinWorld
        if ($Knobs) { Set-WinKnob $w $Knobs }
        $r = New-WinReservation $w
        $id = $r.reservation_id
        $name = Get-AapVmName -Profile windows -Slot $r.slot -LeaseGeneration $r.lease_generation -ReservationId $id
        $c = Start-WinChild $w $Fault $id 12
        $c.ExitCode | Should -Be -1 -Because "the child must be killed at $Fault (stdout: $($c.Out) stderr: $($c.Err))"
        Set-WinKnob $w @{ RunnerStatus = 'absent' }   # a recovered clone runs its job to the end; the job ends at once
        $B = New-WinBackend $w
        [void](Invoke-WinRecover $B $w $id)
        Assert-WinSound $w $id $name
        # The slot's next reservation takes a new generation.
        (New-WinReservation $w).lease_generation | Should -BeGreaterThan $r.lease_generation
    }

    It 'killed in a drain: the restarted supervisor finishes it (drain, collect, destroy)' {
        $w = New-WinWorld
        $r = New-WinReservation $w
        $id = $r.reservation_id
        $B = New-WinBackend $w
        [void](Invoke-WinSteps $B $w $id -Max 5 -Until { param($x) $x.state -eq 'ready' })
        [void](Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $id))   # running, listening
        [void](Set-AapSlotState -Root $w.Cap -ReservationId $id -LeaseGeneration $r.lease_generation -State draining -RelaxedTrustForTests)
        $c = Start-WinChild $w 'drain:after-intent' $id 4
        $c.ExitCode | Should -Be -1 -Because "stdout: $($c.Out) stderr: $($c.Err)"
        $B = New-WinBackend $w
        [void](Invoke-WinRecover $B $w $id)
        Assert-WinSound $w $id (Get-AapVmName -Profile windows -Slot $r.slot -LeaseGeneration $r.lease_generation -ReservationId $id)
    }

    It 'killed while a job runs: the restarted supervisor never cancels it, and tears down after it ended' {
        $w = New-WinWorld
        Set-WinKnob $w @{ RunnerBusy = $true }
        $r = New-WinReservation $w
        $id = $r.reservation_id
        $c = Start-WinChild $w 'run_one:after-start' $id 12
        $c.ExitCode | Should -Be -1
        $B = New-WinBackend $w
        $res = @(Invoke-WinSteps $B $w $id -Max 4)
        @($res | Where-Object { $_.Action -ne 'busy' }).Count | Should -Be 0
        @(Get-WinVms $w).Count | Should -Be 1
        @(Get-WinCalls $w 'StopVm *').Count | Should -Be 0
        Set-WinKnob $w @{ RunnerBusy = $false; RunnerStatus = 'absent' }
        [void](Invoke-WinRecover $B $w $id)
        Assert-WinSound $w $id (Get-AapVmName -Profile windows -Slot $r.slot -LeaseGeneration $r.lease_generation -ReservationId $id)
    }
}
