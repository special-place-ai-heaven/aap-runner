# Recovery without this process's memory: the journal as the state (unreadable journals quarantine, a lost credential
# destroys a clone that is not yet running a job, a hostile record is final), the reconcile callbacks (inventory complete
# or throws, orphan VMs and folders found and never adopted, the broker status of a runner), and the delivery rule for the
# JIT config. Pester 5, Windows PowerShell 5.1 and PowerShell 7.5+.

BeforeAll {
    . (Join-Path $PSScriptRoot 'WinBackendTestHelpers.ps1')
    Import-Module $script:CapModule -Force
    Import-Module $script:BackendModule -Force

    # A reservation driven to $State: creating (booted), ready (runner started) or busy.
    function New-WinAt([string]$State, [int]$Windows = 1) {
        $w = New-WinWorld -Windows $Windows
        $B = New-WinBackend $w
        $r = New-WinReservation $w
        $rid = $r.reservation_id
        if ($State -eq 'creating') { [void](Invoke-WinSteps $B $w $rid -Max 2) }
        else {
            [void](Invoke-WinSteps $B $w $rid -Max 5 -Until { param($x) $x.state -eq 'ready' })
            [void](Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid))
            if ($State -eq 'busy') { Set-WinKnob $w @{ RunnerBusy = $true }; [void](Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid)) }
        }
        [pscustomobject]@{ W = $w; B = $B; Id = $rid; Gen = $r.lease_generation }
    }
}

Describe 'the journal is the state' {
    It 'a journal line of another lease quarantines the slot (crash), capacity held' -Tag 'journal-owner' {
        $x = New-WinAt 'busy'
        $w = $x.W
        $line = @(Get-WinJournalLines $w $x.Id)[0].Replace($x.Id, 'r-00000000000000aa')
        [IO.File]::AppendAllText((Join-Path $w.Journal "$($x.Id).jsonl"), $line + "`n")
        $s = Invoke-AapWinStep -Backend $x.B -Reservation (Get-WinRes $w $x.Id)
        $s.Code | Should -Be 'journal_unreadable'
        $res = Get-WinRes $w $x.Id
        $res.quarantine_kind | Should -Be 'crash'
        @(Get-WinVms $w).Count | Should -Be 1
    }

    It 'a journal past its size bound is unreadable too' -Tag 'journal-shape' {
        $x = New-WinAt 'busy'
        $w = $x.W
        $path = Join-Path $w.Journal "$($x.Id).jsonl"
        $line = @(Get-WinJournalLines $w $x.Id)[-1] + "`n"
        $sb = New-Object Text.StringBuilder
        while ($sb.Length -lt 4194304) { [void]$sb.Append($line) }
        [IO.File]::AppendAllText($path, $sb.ToString())
        (Invoke-AapWinStep -Backend $x.B -Reservation (Get-WinRes $w $x.Id)).Code | Should -Be 'journal_unreadable'
        (Get-WinRes $w $x.Id).quarantine_kind | Should -Be 'crash'
    }

    It 'a torn last line (no newline: the write never finished) is ignored, and cut off by the next record' -Tag 'journal-torn' {
        $x = New-WinAt 'busy'
        $w = $x.W
        [IO.File]::AppendAllText((Join-Path $w.Journal "$($x.Id).jsonl"), '{"schema":2,"kind":"op","reserv')
        (Invoke-AapWinStep -Backend $x.B -Reservation (Get-WinRes $w $x.Id)).Action | Should -Be 'busy'
        Set-WinKnob $w @{ RunnerBusy = $false; RunnerStatus = 'absent' }
        (Invoke-AapWinStep -Backend $x.B -Reservation (Get-WinRes $w $x.Id)).Action | Should -Be 'destroyed'
        (Get-WinRes $w $x.Id).state | Should -Be 'reconciled'
        Invoke-WinValidator $w 'backend-lifecycle' @(Get-WinJournalLines $w $x.Id) | Should -BeNullOrEmpty
    }

    It 'a deleting reservation with an unreadable journal is quarantined (teardown_failed), never left deleting' -Tag 'journal-deleting' {
        $x = New-WinAt 'busy'
        $w = $x.W
        Set-WinKnob $w @{ RunnerBusy = $false; RunnerStatus = 'absent'; ReleaseOutcome = 'retry' }
        (Invoke-AapWinStep -Backend $x.B -Reservation (Get-WinRes $w $x.Id)).Code | Should -Be 'release_pending'
        (Get-WinRes $w $x.Id).state | Should -Be 'deleting'
        [IO.File]::AppendAllText((Join-Path $w.Journal "$($x.Id).jsonl"), "not json`n")
        (Invoke-AapWinStep -Backend $x.B -Reservation (Get-WinRes $w $x.Id)).Code | Should -Be 'journal_unreadable'
        (Get-WinRes $w $x.Id).state | Should -Be 'quarantined'
        (Get-WinRes $w $x.Id).quarantine_kind | Should -Be 'teardown_failed'
    }

    It 'a teardown that keeps failing the same way writes its failure once' -Tag 'journal-dedup' {
        $x = New-WinAt 'busy'
        $w = $x.W
        Set-WinKnob $w @{ RunnerBusy = $false; RunnerStatus = 'absent'; ReleaseOutcome = 'retry' }
        foreach ($i in 1..4) {
            $x.B.Now = { [DateTime]::UtcNow.AddMinutes($i) }.GetNewClosure()
            (Invoke-AapWinStep -Backend $x.B -Reservation (Get-WinRes $w $x.Id)).Code | Should -Be 'release_pending'
        }
        @(Get-WinCalls $w 'Broker release_request *').Count | Should -Be 4
        @(Get-WinJournal $w $x.Id | Where-Object { $_.op -eq 'destroy' }).Count | Should -Be 2   # one intent, one failure
    }

    It 'one step at a time per reservation: a held step lock is never waited on' -Tag 'step-lock' {
        $x = New-WinAt 'busy'
        $w = $x.W
        $n = @(Get-WinCalls $w).Count
        $lock = [IO.File]::Open((Join-Path $w.Journal "$($x.Id).lock"), 'OpenOrCreate', 'ReadWrite', 'None')
        try { $s = Invoke-AapWinStep -Backend $x.B -Reservation (Get-WinRes $w $x.Id) } finally { $lock.Dispose() }
        $s.Code | Should -Be 'step_in_progress'
        @(Get-WinCalls $w).Count | Should -Be $n
        (Invoke-AapWinStep -Backend $x.B -Reservation (Get-WinRes $w $x.Id)).Action | Should -Be 'busy'
        Test-Path -LiteralPath (Join-Path $w.Journal "$($x.Id).lock") | Should -BeFalse   # deleted on close
    }

    It 'a booted clone whose credential died with the supervisor is destroyed, never probed' -Tag 'lost-credential' {
        $x = New-WinAt 'creating'
        $w = $x.W
        $B2 = New-WinBackend $w
        $s = Invoke-AapWinStep -Backend $B2 -Reservation (Get-WinRes $w $x.Id)
        $s.Action | Should -Be 'destroyed'
        (Get-WinRes $w $x.Id).teardown_proof.runner_deregistered | Should -Be 'never_registered'
        @(Get-ChildItem -LiteralPath (Join-Path $w.Fake 'guests')).Count | Should -Be 0   # no command reached the guest
    }

    It 'a hostile record is final even when the allocator never heard of it (crash in between)' -Tag 'hostile-final' {
        $x = New-WinAt 'busy'
        $w = $x.W
        $line = @(Get-WinJournalLines $w $x.Id | Where-Object { $_ -like '*"op":"run_one"*"phase":"intent"*' })[0]
        $line = $line.Replace('"phase":"intent"', '"phase":"failed"').Replace('"result":null', '"result":{"code":"hostile_guest","detail":"wrong_echo"}')
        [IO.File]::AppendAllText((Join-Path $w.Journal "$($x.Id).jsonl"), $line + "`n")
        $B2 = New-WinBackend $w
        $s = Invoke-AapWinStep -Backend $B2 -Reservation (Get-WinRes $w $x.Id)
        $s.Code | Should -Be 'wrong_echo'
        (Get-WinRes $w $x.Id).state | Should -Be 'reconciled'
        @(Get-WinVms $w).Count | Should -Be 0
        $n = @(Get-WinCalls $w).Count   # a reconciled reservation stays reconciled: nothing runs again
        (Invoke-AapWinStep -Backend $B2 -Reservation (Get-WinRes $w $x.Id)).Code | Should -Be 'state'
        @(Get-WinCalls $w).Count | Should -Be $n
    }

    It 'a restarted supervisor never cancels a busy job: it waits on the broker, then tears down once the job ended' {
        $x = New-WinAt 'busy'
        $w = $x.W
        $B2 = New-WinBackend $w
        foreach ($i in 1..3) { (Invoke-AapWinStep -Backend $B2 -Reservation (Get-WinRes $w $x.Id)).Action | Should -Be 'busy' }
        @(Get-WinVms $w).Count | Should -Be 1
        @(Get-WinCalls $w 'Broker release_request *').Count | Should -Be 0
        @(Get-WinCalls $w 'StopVm *').Count | Should -Be 0
        Set-WinKnob $w @{ RunnerBusy = $false; RunnerStatus = 'absent' }
        (Invoke-AapWinStep -Backend $B2 -Reservation (Get-WinRes $w $x.Id)).Action | Should -Be 'destroyed'
        (Get-WinRes $w $x.Id).teardown_proof.runner_deregistered | Should -BeTrue
    }

    It 'a restarted supervisor never takes a lost issued lease for one never recorded: uncertain, capacity held' -Tag 'release-uncertain' {
        $x = New-WinAt 'busy'
        $w = $x.W
        $B2 = New-WinBackend $w   # no memory of the lease outcome; the journal has it
        Set-WinKnob $w @{ RunnerBusy = $false; RunnerStatus = 'absent'; ReleaseOutcome = 'not_found' }
        (Invoke-AapWinStep -Backend $B2 -Reservation (Get-WinRes $w $x.Id)).Code | Should -Be 'release_uncertain'
        (Get-WinRes $w $x.Id).quarantine_kind | Should -Be 'teardown_failed'
    }

    It 'a restarted supervisor retires a listening runner it can no longer reach (drain, release, destroy)' {
        $x = New-WinAt 'ready'
        $w = $x.W
        $B2 = New-WinBackend $w
        (Invoke-AapWinStep -Backend $B2 -Reservation (Get-WinRes $w $x.Id)).Action | Should -Be 'destroyed'
        (Get-WinRes $w $x.Id).teardown_proof.runner_deregistered | Should -BeTrue
    }
}

Describe 'the JIT config goes only to its own fresh VM' {
    It 'a lease past its delivery deadline is never delivered' -Tag 'jit-target' {
        $w = New-WinWorld
        $B = New-WinBackend $w
        $r = New-WinReservation $w
        [void](Invoke-WinSteps $B $w $r.reservation_id -Max 5 -Until { param($x) $x.state -eq 'ready' })
        $B.Now = { [DateTime]::UtcNow.AddMinutes(11) }   # the fake broker's leases expire 10 minutes after issue
        [void](Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $r.reservation_id))
        $vm = @(Get-ChildItem -LiteralPath (Join-Path $w.Fake 'guests'))[0]
        (Read-WinJson $vm.FullName $null).PayloadLen | Should -Be 0
        @(Get-WinJournal $w $r.reservation_id | Where-Object { $_.op -eq 'run_one' -and $_.phase -eq 'failed' })[0].result.detail | Should -Be 'the lease does not fit this VM'
        @(Get-WinLeases $w)[0].state | Should -Be 'released'
    }

    It 'a refused, unavailable or malformed lease registers nothing and tears the VM down' -ForEach @('refused', 'unavailable', 'bad_reply', 'wrong_name') {
        $w = New-WinWorld
        $B = New-WinBackend $w
        Set-WinKnob $w @{ LeaseOutcome = $_ }
        $r = New-WinReservation $w
        [void](Invoke-WinSteps $B $w $r.reservation_id -Max 6)
        @(Get-ChildItem -LiteralPath (Join-Path $w.Fake 'guests') | ForEach-Object { (Read-WinJson $_.FullName $null).PayloadLen } | Where-Object { $_ -ne 0 }).Count | Should -Be 0
        @(Get-WinVms $w).Count | Should -Be 0
        @(Get-WinCalls $w 'Broker release_request *').Count | Should -BeGreaterThan 0
        @(Get-WinCalls $w 'Broker lease_request *').Count | Should -Be 1
    }
}

Describe 'reconcile callbacks' {
    It 'the inventory lists every aap VM, every reservation folder and every journal, and reconcile accepts it' {
        $x = New-WinAt 'busy' -Windows 2
        $w = $x.W
        $inv = Get-AapWinInventory -Backend $x.B
        @($inv.vms).Count | Should -Be 1
        $inv.vms[0].vm_id | Should -Be (Get-WinRes $w $x.Id).vm_id
        @($inv.folders) | Should -Be @($x.Id)
        @($inv.journaled) | Should -Be @($x.Id)
        $B = $x.B
        $rec = Invoke-AapReconcile -Root $w.Cap -Inventory { Get-AapWinInventory -Backend $B } -BrokerStatus { param($r) Get-AapWinBrokerStatus -Backend $B -Reservation $r } -RelaxedTrustForTests
        $rec.Ok | Should -BeTrue
        @($rec.Actions).Count | Should -Be 0
    }

    It 'a listing error throws, so reconcile changes nothing' {
        $x = New-WinAt 'busy'
        $w = $x.W
        Set-WinKnob $w @{ ListFails = $true }
        { Get-AapWinInventory -Backend $x.B } | Should -Throw '*Get-VM failed*'
        $B = $x.B
        $rev = (Get-AapAllocatorState -Root $w.Cap -RelaxedTrustForTests).Revision
        $rec = Invoke-AapReconcile -Root $w.Cap -Inventory { Get-AapWinInventory -Backend $B } -RelaxedTrustForTests
        $rec.Status | Should -Be 'error'
        (Get-AapAllocatorState -Root $w.Cap -RelaxedTrustForTests).Revision | Should -Be $rev
    }

    It 'an entry in a tier root that is not a reservation folder throws (it sits outside every cap)' -Tag 'inventory-strict' {
        $x = New-WinAt 'busy'
        $w = $x.W
        foreach ($junk in @('notes.txt', 'tmp-folder')) {
            $p = Join-Path $x.W.Scratch $junk
            if ($junk -like '*.txt') { [IO.File]::WriteAllText($p, 'x') } else { [void][IO.Directory]::CreateDirectory($p) }
            { Get-AapWinInventory -Backend $x.B } | Should -Throw "*AAP_InventoryIncomplete*$junk*"
            if ($junk -like '*.txt') { [IO.File]::Delete($p) } else { [IO.Directory]::Delete($p) }
        }
    }

    It 'a VM entry without a usable id throws' -Tag 'vm-entry' {
        $x = New-WinAt 'busy'
        $w = $x.W
        Save-WinVms $w (@(Get-WinVms $w) + [pscustomobject]@{ Id = 'not-a-guid'; Name = 'aap-w-2-1-00000000'; State = 'Running'; Cpus = 2; MemGib = 4 })
        { Get-AapWinInventory -Backend $x.B } | Should -Throw '*AAP_InventoryIncomplete*'
    }

    It 'an orphan VM is quarantined unknown_vm and never adopted or deleted; an orphan folder blocks admission' {
        $x = New-WinAt 'busy' -Windows 2
        $w = $x.W
        $orphan = [guid]::NewGuid().ToString()
        Save-WinVms $w (@(Get-WinVms $w) + [pscustomobject]@{ Id = $orphan; Name = 'aap-w-4-9-0badc0de'; State = 'Running'; Cpus = 2; MemGib = 4; ConfigurationLocation = $w.Root })
        $B = $x.B
        $rec = Invoke-AapReconcile -Root $w.Cap -Inventory { Get-AapWinInventory -Backend $B } -RelaxedTrustForTests
        $rec.Ok | Should -BeTrue
        $q = @((Get-AapAllocatorState -Root $w.Cap -RelaxedTrustForTests).State.reservations | Where-Object { $_.vm_id -eq $orphan })
        $q.Count | Should -Be 1
        $q[0].quarantine_kind | Should -Be 'unknown_vm'
        (Invoke-AapWinStep -Backend $B -Reservation $q[0]).Action | Should -Be 'held'
        @(Get-WinVms $w | Where-Object { $_.Id -eq $orphan }).Count | Should -Be 1
        # A reservation folder nobody owns.
        [void][IO.Directory]::CreateDirectory((Join-Path $w.Clones 'r-00000000000000ee'))
        [void](Invoke-AapReconcile -Root $w.Cap -Inventory { Get-AapWinInventory -Backend $B } -RelaxedTrustForTests)
        (Request-AapReservation -Root $w.Cap -Profile windows -MemOverheadMib 512 -CloneGib 60 -ScratchGib 40 -IoMbps 100 -RelaxedTrustForTests).Reason | Should -Be 'unresolved_unknown'
    }

    It 'the broker status callback: busy holds a heartbeat quarantine, absent lets reconcile destroy it' {
        $x = New-WinAt 'busy'
        $w = $x.W
        $B = $x.B
        (Get-AapWinBrokerStatus -Backend $B -Reservation (Get-WinRes $w $x.Id)).busy | Should -BeTrue
        & (Get-Module AapCapacity) { function script:Get-AapUtcNow { [DateTime]::UtcNow.AddSeconds(120) } }
        try {
            $rec = Invoke-AapReconcile -Root $w.Cap -Inventory { Get-AapWinInventory -Backend $B } -BrokerStatus { param($r) Get-AapWinBrokerStatus -Backend $B -Reservation $r } -RelaxedTrustForTests
            (Get-WinRes $w $x.Id).quarantine_kind | Should -Be 'heartbeat'
            @($rec.Actions).Count | Should -Be 0
            Set-WinKnob $w @{ RunnerBusy = $false; RunnerStatus = 'offline' }
            $rec = Invoke-AapReconcile -Root $w.Cap -Inventory { Get-AapWinInventory -Backend $B } -BrokerStatus { param($r) Get-AapWinBrokerStatus -Backend $B -Reservation $r } -RelaxedTrustForTests
        } finally { & (Get-Module AapCapacity) { function script:Get-AapUtcNow { [DateTime]::UtcNow } } }
        @($rec.Actions | Where-Object { $_.action -eq 'destroy' }).Count | Should -Be 1
        (Get-WinRes $w $x.Id).state | Should -Be 'deleting'
        $B.Now = { [DateTime]::UtcNow }
        (Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $x.Id)).Action | Should -Be 'destroyed'
        (Get-WinRes $w $x.Id).state | Should -Be 'reconciled'
    }

    It 'the broker status callback without a lease, after a journaled job end, and with the broker down' {
        $x = New-WinAt 'creating'
        (Get-AapWinBrokerStatus -Backend $x.B -Reservation (Get-WinRes $x.W $x.Id)).status | Should -Be 'absent'
        $y = New-WinAt 'busy'
        $w = $y.W
        Set-WinKnob $w @{ StatusOutcome = 'unavailable' }
        Get-AapWinBrokerStatus -Backend $y.B -Reservation (Get-WinRes $w $y.Id) | Should -BeNullOrEmpty
    }
}
