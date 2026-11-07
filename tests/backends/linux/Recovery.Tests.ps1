# Recovery without this process's memory: the journal as the state (unreadable journals quarantine, a hostile record is
# final), the guest channel kept across a supervisor restart (the key, the pin and the seq mark persist in the clone's ssh
# folder; a lost or damaged one fails closed), the reconcile callbacks (inventory complete or throws, orphan VMs and
# folders found and never adopted, the broker status of a runner), and the delivery rule for the JIT config. Pester 5,
# Windows PowerShell 5.1 and PowerShell 7.5+.

BeforeAll {
    . (Join-Path $PSScriptRoot 'LinBackendTestHelpers.ps1')
    Import-Module $script:CapModule -Force
    Import-Module $script:BackendModule -Force

    # A reservation driven to $State: creating (booted, probing), ready (runner started) or busy.
    function New-LinAt([string]$State, [int]$Linux = 1) {
        $w = New-LinWorld -Linux $Linux
        $B = New-LinBackend $w
        $r = New-LinReservation $w
        $rid = $r.reservation_id
        if ($State -eq 'creating') { Set-LinKnob $w @{ BootProbes = 2 }; [void](Invoke-LinSteps $B $w $rid -Max 3) }
        else {
            [void](Invoke-LinSteps $B $w $rid -Max 5 -Until { param($x) $x.state -eq 'ready' })
            [void](Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid))
            if ($State -eq 'busy') { Set-LinKnob $w @{ RunnerBusy = $true }; [void](Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid)) }
        }
        [pscustomobject]@{ W = $w; B = $B; Id = $rid; Gen = $r.lease_generation }
    }
    function Get-LinRefusals($w) { @(Get-ChildItem -LiteralPath (Join-Path $w.Fake 'exchanges') | ForEach-Object { Read-LinJson $_.FullName $null } | Where-Object { $_.reply.status -eq 'refused' }) }
}

Describe 'the journal is the state' {
    It 'a journal line of another lease quarantines the slot (crash), capacity held' -Tag 'journal-owner' {
        $x = New-LinAt 'busy'
        $w = $x.W
        $line = @(Get-LinJournalLines $w $x.Id)[0].Replace($x.Id, 'r-00000000000000aa')
        [IO.File]::AppendAllText((Join-Path $w.Journal "$($x.Id).jsonl"), $line + "`n")
        $s = Invoke-AapLinStep -Backend $x.B -Reservation (Get-LinRes $w $x.Id)
        $s.Code | Should -Be 'journal_unreadable'
        (Get-LinRes $w $x.Id).quarantine_kind | Should -Be 'crash'
        @(Get-LinVms $w).Count | Should -Be 1
    }

    It 'a journal line of the other profile is not a record of this lease either' -Tag 'journal-owner' {
        $x = New-LinAt 'busy'
        $w = $x.W
        $line = @(Get-LinJournalLines $w $x.Id)[-1].Replace('"profile":"linux"', '"profile":"windows"')
        [IO.File]::AppendAllText((Join-Path $w.Journal "$($x.Id).jsonl"), $line + "`n")
        (Invoke-AapLinStep -Backend $x.B -Reservation (Get-LinRes $w $x.Id)).Code | Should -Be 'journal_unreadable'
    }

    It 'a journal past its size bound is unreadable too' -Tag 'journal-shape' {
        $x = New-LinAt 'busy'
        $w = $x.W
        $path = Join-Path $w.Journal "$($x.Id).jsonl"
        $line = @(Get-LinJournalLines $w $x.Id)[-1] + "`n"
        $sb = New-Object Text.StringBuilder
        while ($sb.Length -lt 4194304) { [void]$sb.Append($line) }
        [IO.File]::AppendAllText($path, $sb.ToString())
        (Invoke-AapLinStep -Backend $x.B -Reservation (Get-LinRes $w $x.Id)).Code | Should -Be 'journal_unreadable'
        (Get-LinRes $w $x.Id).quarantine_kind | Should -Be 'crash'
    }

    It 'a torn last line (no newline: the write never finished) is ignored, and cut off by the next record' -Tag 'journal-torn' {
        $x = New-LinAt 'busy'
        $w = $x.W
        [IO.File]::AppendAllText((Join-Path $w.Journal "$($x.Id).jsonl"), '{"schema":2,"kind":"op","reserv')
        (Invoke-AapLinStep -Backend $x.B -Reservation (Get-LinRes $w $x.Id)).Action | Should -Be 'busy'
        Set-LinKnob $w @{ RunnerBusy = $false; RunnerStatus = 'absent' }
        (Invoke-AapLinStep -Backend $x.B -Reservation (Get-LinRes $w $x.Id)).Action | Should -Be 'destroyed'
        (Get-LinRes $w $x.Id).state | Should -Be 'reconciled'
        Invoke-LinValidator $w 'backend-lifecycle' @(Get-LinJournalLines $w $x.Id) | Should -BeNullOrEmpty
    }

    It 'a deleting reservation with an unreadable journal is quarantined (teardown_failed), never left deleting' -Tag 'journal-deleting' {
        $x = New-LinAt 'busy'
        $w = $x.W
        Set-LinKnob $w @{ RunnerBusy = $false; RunnerStatus = 'absent'; ReleaseOutcome = 'retry' }
        (Invoke-AapLinStep -Backend $x.B -Reservation (Get-LinRes $w $x.Id)).Code | Should -Be 'release_pending'
        (Get-LinRes $w $x.Id).state | Should -Be 'deleting'
        [IO.File]::AppendAllText((Join-Path $w.Journal "$($x.Id).jsonl"), "not json`n")
        (Invoke-AapLinStep -Backend $x.B -Reservation (Get-LinRes $w $x.Id)).Code | Should -Be 'journal_unreadable'
        (Get-LinRes $w $x.Id).state | Should -Be 'quarantined'
        (Get-LinRes $w $x.Id).quarantine_kind | Should -Be 'teardown_failed'
    }

    It 'a teardown that keeps failing the same way writes its failure once and its intent once' -Tag 'journal-dedup', 'destroy-once' {
        $x = New-LinAt 'busy'
        $w = $x.W
        Set-LinKnob $w @{ RunnerBusy = $false; RunnerStatus = 'absent'; ReleaseOutcome = 'retry' }
        foreach ($i in 1..4) {
            $x.B.Now = { [DateTime]::UtcNow.AddMinutes($i) }.GetNewClosure()
            (Invoke-AapLinStep -Backend $x.B -Reservation (Get-LinRes $w $x.Id)).Code | Should -Be 'release_pending'
        }
        @(Get-LinCalls $w 'Broker release_request *').Count | Should -Be 4
        @(Get-LinJournal $w $x.Id | Where-Object { $_.op -eq 'destroy' } | ForEach-Object { $_.phase }) -join ',' | Should -Be 'intent,failed'
    }

    It 'one step at a time per reservation: a held step lock is never waited on' -Tag 'step-lock' {
        $x = New-LinAt 'busy'
        $w = $x.W
        $n = @(Get-LinCalls $w).Count
        $lock = [IO.File]::Open((Join-Path $w.Journal "$($x.Id).lock"), 'OpenOrCreate', 'ReadWrite', 'None')
        try { $s = Invoke-AapLinStep -Backend $x.B -Reservation (Get-LinRes $w $x.Id) } finally { $lock.Dispose() }
        $s.Code | Should -Be 'step_in_progress'
        @(Get-LinCalls $w).Count | Should -Be $n
        (Invoke-AapLinStep -Backend $x.B -Reservation (Get-LinRes $w $x.Id)).Action | Should -Be 'busy'
        Test-Path -LiteralPath (Join-Path $w.Journal "$($x.Id).lock") | Should -BeFalse   # deleted on close
    }

    It 'a hostile record is final even when the allocator never heard of it (crash in between)' -Tag 'hostile-final' {
        $x = New-LinAt 'busy'
        $w = $x.W
        $line = @(Get-LinJournalLines $w $x.Id | Where-Object { $_ -like '*"op":"run_one"*"phase":"intent"*' })[0]
        $line = $line.Replace('"phase":"intent"', '"phase":"failed"').Replace('"result":null', '"result":{"code":"hostile_guest","detail":"wrong_echo"}')
        [IO.File]::AppendAllText((Join-Path $w.Journal "$($x.Id).jsonl"), $line + "`n")
        $B2 = New-LinBackend $w
        $s = Invoke-AapLinStep -Backend $B2 -Reservation (Get-LinRes $w $x.Id)
        $s.Code | Should -Be 'wrong_echo'
        (Get-LinRes $w $x.Id).state | Should -Be 'reconciled'
        @(Get-LinVms $w).Count | Should -Be 0
        $n = @(Get-LinCalls $w).Count   # a reconciled reservation stays reconciled: nothing runs again
        (Invoke-AapLinStep -Backend $B2 -Reservation (Get-LinRes $w $x.Id)).Code | Should -Be 'state'
        @(Get-LinCalls $w).Count | Should -Be $n
    }
}

Describe 'a restarted supervisor keeps the guest channel' {
    It 'a clone still probing reaches ready after a restart: seq continues above the persisted mark, nothing refused' -Tag 'seq-mark' {
        $x = New-LinAt 'creating'
        $w = $x.W
        (Get-LinRes $w $x.Id).state | Should -Be 'creating'
        [IO.File]::ReadAllText((Join-Path $w.Clones "$($x.Id)\ssh\seq")) | Should -Be '1000'
        $B2 = New-LinBackend $w
        @(Invoke-LinSteps $B2 $w $x.Id -Max 4 -Until { param($r) $r.state -eq 'ready' } | ForEach-Object { $_.Action }) -join ',' | Should -Be 'probing,ready'
        Get-LinRefusals $w | Should -BeNullOrEmpty
        $seqs = @(Get-ChildItem -LiteralPath (Join-Path $w.Fake 'exchanges') | ForEach-Object { [long](Read-LinJson $_.FullName $null).cmd.seq } | Sort-Object)
        $seqs[-1] | Should -BeGreaterThan 1000
        [IO.File]::ReadAllText((Join-Path $w.Clones "$($x.Id)\ssh\seq")) | Should -Be '2000'
        (Invoke-AapLinStep -Backend $B2 -Reservation (Get-LinRes $w $x.Id)).Action | Should -Be 'running'
    }

    It 'a running job keeps its guest heartbeats after a restart; its summary is collected; it is never cancelled' {
        $x = New-LinAt 'busy'
        $w = $x.W
        $B2 = New-LinBackend $w
        foreach ($i in 1..3) { (Invoke-AapLinStep -Backend $B2 -Reservation (Get-LinRes $w $x.Id)).Code | Should -Be 'ok' }
        @(Get-LinVms $w).Count | Should -Be 1
        @(Get-LinCalls $w 'Broker release_request *').Count | Should -Be 0
        @(Get-LinCalls $w 'StopVm *').Count | Should -Be 0
        Get-LinRefusals $w | Should -BeNullOrEmpty
        Set-LinKnob $w @{ RunnerBusy = $false; RunnerStatus = 'absent' }
        $end = Invoke-AapLinStep -Backend $B2 -Reservation (Get-LinRes $w $x.Id)
        $end.Action | Should -Be 'destroyed'
        $end.Summary.GuestState | Should -Be 'job_done'
        (Get-LinRes $w $x.Id).teardown_proof.runner_deregistered | Should -BeTrue
    }

    It 'a seq mark that is damaged or past its bound drops the channel: a probing clone is destroyed, never refused' -Tag 'seq-file', 'lost-credential' {
        foreach ($bad in '99999999999', 'garbage', '') {
            $x = New-LinAt 'creating'
            $w = $x.W
            [IO.File]::WriteAllText((Join-Path $w.Clones "$($x.Id)\ssh\seq"), $bad)
            $n = @(Get-ChildItem -LiteralPath (Join-Path $w.Fake 'exchanges')).Count
            $B2 = New-LinBackend $w
            $s = Invoke-AapLinStep -Backend $B2 -Reservation (Get-LinRes $w $x.Id)
            $s.Action | Should -Be 'destroyed' -Because "seq '$bad'"
            @(Get-LinJournal $w $x.Id | Where-Object { $_.phase -eq 'failed' })[0].result.detail | Should -Be 'guest channel lost before ready'
            @(Get-ChildItem -LiteralPath (Join-Path $w.Fake 'exchanges')).Count | Should -Be $n
            (Get-LinRes $w $x.Id).teardown_proof.runner_deregistered | Should -Be 'never_registered'
        }
    }

    It 'a seq mark that is missing is as lost as a damaged one: nothing is sent, the probing clone is destroyed' -Tag 'seq-absent', 'lost-credential' {
        $x = New-LinAt 'creating'
        $w = $x.W
        [IO.File]::Delete((Join-Path $w.Clones "$($x.Id)\ssh\seq"))
        $n = @(Get-ChildItem -LiteralPath (Join-Path $w.Fake 'exchanges')).Count
        $B2 = New-LinBackend $w
        $s = Invoke-AapLinStep -Backend $B2 -Reservation (Get-LinRes $w $x.Id)
        $s.Action | Should -Be 'destroyed'
        @(Get-LinJournal $w $x.Id | Where-Object { $_.phase -eq 'failed' })[0].result.detail | Should -Be 'guest channel lost before ready'
        @(Get-ChildItem -LiteralPath (Join-Path $w.Fake 'exchanges')).Count | Should -Be $n
        Get-LinRefusals $w | Should -BeNullOrEmpty
    }

    It 'a channel that never sent a command keeps its initial mark across a restart and starts at seq 1' {
        $w = New-LinWorld
        $B = New-LinBackend $w
        $r = New-LinReservation $w
        $rid = $r.reservation_id
        [void](Invoke-AapLinStep -Backend $B -Reservation $r -BaseSha256 $w.BaseSha -CatalogGuestRevision 2 -ApprovedGuestRevision 2)   # created: nothing sent yet
        [IO.File]::ReadAllText((Join-Path $w.Clones "$rid\ssh\seq")) | Should -BeExactly '0'
        $B2 = New-LinBackend $w
        @(Invoke-LinSteps $B2 $w $rid -Max 3 -Until { param($x) $x.state -eq 'ready' } | ForEach-Object { $_.Action }) -join ',' | Should -Be 'booted,ready'
        Get-LinRefusals $w | Should -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath (Join-Path $w.Fake 'exchanges') | ForEach-Object { [long](Read-LinJson $_.FullName $null).cmd.seq } | Sort-Object)[0] | Should -Be 1
    }

    It 'a key folder lost before boot: the clone is destroyed, never booted or probed' -Tag 'lost-credential' {
        $w = New-LinWorld
        $B = New-LinBackend $w
        $r = New-LinReservation $w
        [void](Invoke-AapLinStep -Backend $B -Reservation $r -BaseSha256 $w.BaseSha -CatalogGuestRevision 2 -ApprovedGuestRevision 2)   # created
        [IO.Directory]::Delete((Join-Path $w.Clones "$($r.reservation_id)\ssh"), $true)
        $B2 = New-LinBackend $w
        (Invoke-AapLinStep -Backend $B2 -Reservation (Get-LinRes $w $r.reservation_id)).Action | Should -Be 'destroyed'
        @(Get-LinCalls $w 'StartVm *').Count | Should -Be 0
        (Get-LinRes $w $r.reservation_id).teardown_proof.runner_deregistered | Should -Be 'never_registered'
    }

    It 'a busy runner without a usable channel after a restart is never cancelled: broker status only, then torn down' {
        $x = New-LinAt 'busy'
        $w = $x.W
        [IO.Directory]::Delete((Join-Path $w.Clones "$($x.Id)\ssh"), $true)
        $B2 = New-LinBackend $w
        foreach ($i in 1..3) { (Invoke-AapLinStep -Backend $B2 -Reservation (Get-LinRes $w $x.Id)).Action | Should -Be 'busy' }
        @(Get-LinCalls $w 'StopVm *').Count | Should -Be 0
        Set-LinKnob $w @{ RunnerBusy = $false; RunnerStatus = 'absent' }
        (Invoke-AapLinStep -Backend $B2 -Reservation (Get-LinRes $w $x.Id)).Action | Should -Be 'destroyed'
        (Get-LinRes $w $x.Id).teardown_proof.runner_deregistered | Should -BeTrue
    }

    It 'a restart between the JIT delivery and the runner start never asks the guest for status: drain, release, destroy' {
        $w = New-LinWorld
        $B = New-LinBackend $w
        $r = New-LinReservation $w
        $rid = $r.reservation_id
        [void](Invoke-LinSteps $B $w $rid -Max 5 -Until { param($x) $x.state -eq 'ready' })
        [void](Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid))
        # Drop the runner-start record: as if the supervisor died after start_runner was sent, before it was journaled.
        $path = Join-Path $w.Journal "$rid.jsonl"
        [IO.File]::WriteAllText($path, ((@(Get-LinJournalLines $w $rid | Where-Object { $_ -notlike '*runner started on the guest*' }) -join "`n") + "`n"))
        $n = @(Get-ChildItem -LiteralPath (Join-Path $w.Fake 'exchanges')).Count
        $B2 = New-LinBackend $w
        (Invoke-AapLinStep -Backend $B2 -Reservation (Get-LinRes $w $rid)).Action | Should -Be 'destroyed'
        @(Get-ChildItem -LiteralPath (Join-Path $w.Fake 'exchanges')).Count | Should -Be $n -Because 'no status or collect went to a guest whose runner start is not journaled'
        (Get-LinRes $w $rid).teardown_proof.runner_deregistered | Should -BeTrue
    }

    It 'a restarted supervisor never takes a lost issued lease for one never recorded: uncertain, capacity held' -Tag 'release-uncertain' {
        $x = New-LinAt 'busy'
        $w = $x.W
        $B2 = New-LinBackend $w   # no memory of the lease outcome; the journal has it
        Set-LinKnob $w @{ RunnerBusy = $false; RunnerStatus = 'absent'; ReleaseOutcome = 'not_found' }
        (Invoke-AapLinStep -Backend $B2 -Reservation (Get-LinRes $w $x.Id)).Code | Should -Be 'release_uncertain'
        (Get-LinRes $w $x.Id).quarantine_kind | Should -Be 'teardown_failed'
    }
}

Describe 'the JIT config goes only to its own fresh VM' {
    It 'a lease past its delivery deadline is never delivered' -Tag 'jit-target' {
        $w = New-LinWorld
        $B = New-LinBackend $w
        $r = New-LinReservation $w
        [void](Invoke-LinSteps $B $w $r.reservation_id -Max 5 -Until { param($x) $x.state -eq 'ready' })
        $B.Now = { [DateTime]::UtcNow.AddMinutes(11) }   # the fake broker's leases expire 10 minutes after issue
        [void](Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $r.reservation_id))
        $vm = @(Get-ChildItem -LiteralPath (Join-Path $w.Fake 'guests'))[0]
        (Read-LinJson $vm.FullName $null).PayloadLen | Should -Be 0
        @(Get-LinJournal $w $r.reservation_id | Where-Object { $_.op -eq 'run_one' -and $_.phase -eq 'failed' })[0].result.detail | Should -Be 'the lease does not fit this VM'
        @(Get-LinLeases $w)[0].state | Should -Be 'released'
    }

    It 'a refused, unavailable or malformed lease, or one for another runner name, registers nothing and tears the VM down' -ForEach @('refused', 'unavailable', 'bad_reply', 'wrong_name') {
        $w = New-LinWorld
        $B = New-LinBackend $w
        Set-LinKnob $w @{ LeaseOutcome = $_ }
        $r = New-LinReservation $w
        [void](Invoke-LinSteps $B $w $r.reservation_id -Max 6)
        @(Get-ChildItem -LiteralPath (Join-Path $w.Fake 'guests') | ForEach-Object { (Read-LinJson $_.FullName $null).PayloadLen } | Where-Object { $_ -ne 0 }).Count | Should -Be 0
        @(Get-LinVms $w).Count | Should -Be 0
        @(Get-LinCalls $w 'Broker release_request *').Count | Should -BeGreaterThan 0
        @(Get-LinCalls $w 'Broker lease_request *').Count | Should -Be 1
    }
}

Describe 'reconcile callbacks' {
    It 'the inventory lists every aap VM, every reservation folder and every journal, and reconcile accepts it' {
        $x = New-LinAt 'busy' -Linux 2
        $w = $x.W
        $inv = Get-AapLinInventory -Backend $x.B
        @($inv.vms).Count | Should -Be 1
        $inv.vms[0].vm_id | Should -Be (Get-LinRes $w $x.Id).vm_id
        @($inv.folders) | Should -Be @($x.Id)
        @($inv.journaled) | Should -Be @($x.Id)
        $B = $x.B
        $rec = Invoke-AapReconcile -Root $w.Cap -Inventory { Get-AapLinInventory -Backend $B } -BrokerStatus { param($r) Get-AapLinBrokerStatus -Backend $B -Reservation $r } -RelaxedTrustForTests
        $rec.Ok | Should -BeTrue
        @($rec.Actions).Count | Should -Be 0
    }

    It 'a listing error throws, so reconcile changes nothing' {
        $x = New-LinAt 'busy'
        $w = $x.W
        Set-LinKnob $w @{ ListFails = $true }
        { Get-AapLinInventory -Backend $x.B } | Should -Throw '*Get-VM failed*'
        $B = $x.B
        $rev = (Get-AapAllocatorState -Root $w.Cap -RelaxedTrustForTests).Revision
        $rec = Invoke-AapReconcile -Root $w.Cap -Inventory { Get-AapLinInventory -Backend $B } -RelaxedTrustForTests
        $rec.Status | Should -Be 'error'
        (Get-AapAllocatorState -Root $w.Cap -RelaxedTrustForTests).Revision | Should -Be $rev
    }

    It 'an entry in a tier root that is not a reservation folder throws (it sits outside every cap)' -Tag 'inventory-strict' {
        $x = New-LinAt 'busy'
        $w = $x.W
        foreach ($junk in @('notes.txt', 'tmp-folder')) {
            $p = Join-Path $x.W.Scratch $junk
            if ($junk -like '*.txt') { [IO.File]::WriteAllText($p, 'x') } else { [void][IO.Directory]::CreateDirectory($p) }
            { Get-AapLinInventory -Backend $x.B } | Should -Throw "*AAP_InventoryIncomplete*$junk*"
            if ($junk -like '*.txt') { [IO.File]::Delete($p) } else { [IO.Directory]::Delete($p) }
        }
    }

    It 'a VM entry without a usable id throws' -Tag 'vm-entry' {
        $x = New-LinAt 'busy'
        $w = $x.W
        Save-LinVms $w (@(Get-LinVms $w) + [pscustomobject]@{ Id = 'not-a-guid'; Name = 'aap-l-2-1-00000000'; State = 'Running'; Cpus = 2; MemGib = 4 })
        { Get-AapLinInventory -Backend $x.B } | Should -Throw '*AAP_InventoryIncomplete*'
    }

    It 'an orphan VM is quarantined unknown_vm and never adopted or deleted; an orphan folder blocks admission' {
        $x = New-LinAt 'busy' -Linux 2
        $w = $x.W
        $orphan = [guid]::NewGuid().ToString()
        Save-LinVms $w (@(Get-LinVms $w) + [pscustomobject]@{ Id = $orphan; Name = 'aap-l-4-9-0badc0de'; State = 'Running'; Cpus = 2; MemGib = 4; ConfigurationLocation = $w.Root })
        $B = $x.B
        $rec = Invoke-AapReconcile -Root $w.Cap -Inventory { Get-AapLinInventory -Backend $B } -RelaxedTrustForTests
        $rec.Ok | Should -BeTrue
        $q = @((Get-AapAllocatorState -Root $w.Cap -RelaxedTrustForTests).State.reservations | Where-Object { $_.vm_id -eq $orphan })
        $q.Count | Should -Be 1
        $q[0].quarantine_kind | Should -Be 'unknown_vm'
        (Invoke-AapLinStep -Backend $B -Reservation $q[0]).Action | Should -Be 'held'
        @(Get-LinVms $w | Where-Object { $_.Id -eq $orphan }).Count | Should -Be 1
        [void][IO.Directory]::CreateDirectory((Join-Path $w.Clones 'r-00000000000000ee'))
        [void](Invoke-AapReconcile -Root $w.Cap -Inventory { Get-AapLinInventory -Backend $B } -RelaxedTrustForTests)
        (Request-AapReservation -Root $w.Cap -Profile linux -MemOverheadMib 512 -CloneGib 55 -ScratchGib 0 -IoMbps 100 -RelaxedTrustForTests).Reason | Should -Be 'unresolved_unknown'
    }

    It 'the broker status callback: busy holds a heartbeat quarantine, absent lets reconcile destroy it' {
        $x = New-LinAt 'busy'
        $w = $x.W
        $B = $x.B
        (Get-AapLinBrokerStatus -Backend $B -Reservation (Get-LinRes $w $x.Id)).busy | Should -BeTrue
        & (Get-Module AapCapacity) { function script:Get-AapUtcNow { [DateTime]::UtcNow.AddSeconds(120) } }
        try {
            $rec = Invoke-AapReconcile -Root $w.Cap -Inventory { Get-AapLinInventory -Backend $B } -BrokerStatus { param($r) Get-AapLinBrokerStatus -Backend $B -Reservation $r } -RelaxedTrustForTests
            (Get-LinRes $w $x.Id).quarantine_kind | Should -Be 'heartbeat'
            @($rec.Actions).Count | Should -Be 0
            Set-LinKnob $w @{ RunnerBusy = $false; RunnerStatus = 'offline' }
            $rec = Invoke-AapReconcile -Root $w.Cap -Inventory { Get-AapLinInventory -Backend $B } -BrokerStatus { param($r) Get-AapLinBrokerStatus -Backend $B -Reservation $r } -RelaxedTrustForTests
        } finally { & (Get-Module AapCapacity) { function script:Get-AapUtcNow { [DateTime]::UtcNow } } }
        @($rec.Actions | Where-Object { $_.action -eq 'destroy' }).Count | Should -Be 1
        (Get-LinRes $w $x.Id).state | Should -Be 'deleting'
        (Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $x.Id)).Action | Should -Be 'destroyed'
        (Get-LinRes $w $x.Id).state | Should -Be 'reconciled'
    }

    It 'the broker status callback without a lease, after a journaled job end, and with the broker down' {
        $x = New-LinAt 'creating'
        (Get-AapLinBrokerStatus -Backend $x.B -Reservation (Get-LinRes $x.W $x.Id)).status | Should -Be 'absent'
        $y = New-LinAt 'busy'
        $w = $y.W
        Set-LinKnob $w @{ StatusOutcome = 'unavailable' }
        Get-AapLinBrokerStatus -Backend $y.B -Reservation (Get-LinRes $w $y.Id) | Should -BeNullOrEmpty
    }
}
