# Real processes against one capacity folder: two hidden PowerShell processes racing for the last
# slot through the lock file, a lock held past the bounded wait, and a controller killed at every
# persisted boundary (the child kills itself at a fault point: after the temp file is written but
# before the atomic replace, or right after the replace). After each kill this process reconciles
# and checks: the state still validates, no slot holds two live leases, no generation is reused,
# and no slot is freed without a teardown proof. Real clock: a child cannot see a mocked one.
# Pester 5, Windows PowerShell 5.1 and PowerShell 7.5+.

BeforeAll {
    . (Join-Path $PSScriptRoot 'Fixture.ps1')
    Import-Module $script:CapModule -Force
    $PSDefaultParameterValues['*-Aap*:RelaxedTrustForTests'] = $true
    $PSDefaultParameterValues['*-Aap*:WarningAction'] = 'SilentlyContinue'
    $script:Now = [DateTime]::UtcNow

    # Runs Body in a child that kills itself at Fault (exit code -1: not an error exit, not a
    # return). 'after-temp' is the allocator.json temp file written and not yet swapped in; the
    # temp file must then exist.
    function Invoke-CapCrash([string]$Root, [string]$Body, [string]$Fault) {
        if ($Fault -eq 'after-temp') { $Fault = 'after-temp allocator.json' }
        $w = Wait-CapChild (Start-CapChild -Root $Root -Body $Body -Fault $Fault)
        $w.ExitCode | Should -Be -1 -Because "the child must be killed at $Fault ($($w.StdErr))"
        $w.Result | Should -BeNullOrEmpty
        if ($Fault -eq 'after-temp allocator.json') { Test-Path -LiteralPath (Join-Path $Root 'allocator.json.tmp') | Should -BeTrue }
    }

    # The invariants every crash must keep.
    function Assert-CapSound([string]$Root) {
        (Test-AapAllocatorState -Path (Join-Path $Root 'allocator.json')).Valid | Should -BeTrue
        $doc = Get-CapDoc $Root
        $live = @(Get-CapLive $doc)
        @($live | ForEach-Object { $_.slot } | Sort-Object -Unique).Count | Should -Be $live.Count
        foreach ($r in $live) { $r.lease_generation | Should -Be $doc.slot_generations[$r.slot - 1] }
        foreach ($r in @($doc.reservations | Where-Object { $_.state -eq 'reconciled' })) { $r.teardown_proof | Should -Not -BeNullOrEmpty }
    }

    $script:VmArgs = '-MemOverheadMib 512 -DiskGib 190 -IoMbps 100'
}

AfterAll {
    $PSDefaultParameterValues.Remove('*-Aap*:RelaxedTrustForTests')
    $PSDefaultParameterValues.Remove('*-Aap*:WarningAction')
}

Describe 'two processes race for the last slot' {
    It 'exactly one of two real processes wins the last slot (round <_>)' -ForEach @(1, 2, 3) {
        $round = $_
        $script:Now = [DateTime]::UtcNow
        $root = New-CapAllocator -Linux 1 -Windows 4
        [void](Set-AapProfileCounts -Root $root -Linux 0 -Windows 5)
        $vms = @(1..4 | ForEach-Object { New-CapVm $root })
        [void](Set-AapSlotState -Root $root -ReservationId $vms[3].reservation_id -LeaseGeneration $vms[3].lease_generation -State draining)
        $go = Join-Path $TestDrive "go-$round"
        $children = foreach ($n in 'a', 'b') {
            Start-CapChild -Root $root -Body "param(`$root) Request-AapReservation -Root `$root -Profile windows $($script:VmArgs)" -Go $go -Ready (Join-Path $TestDrive "ready-$round-$n")
        }
        $deadline = [DateTime]::UtcNow.AddSeconds(90)
        while (-not ((Test-Path (Join-Path $TestDrive "ready-$round-a")) -and (Test-Path (Join-Path $TestDrive "ready-$round-b")))) {
            if ([DateTime]::UtcNow -gt $deadline) { throw 'children did not get ready' }
            Start-Sleep -Milliseconds 20
        }
        [IO.File]::WriteAllText($go, 'go')
        $results = @($children | ForEach-Object { (Wait-CapChild $_).Result })
        @($results | Where-Object { $_.Status -eq 'ok' }).Count | Should -Be 1
        $loser = @($results | Where-Object { $_.Status -ne 'ok' })
        $loser.Count | Should -Be 1
        $loser[0].Status | Should -Be 'refused'
        $loser[0].Reason | Should -Be 'ceiling'
        Assert-CapSound $root
        $doc = Get-CapDoc $root
        @(Get-CapLive $doc).Count | Should -Be 5
        $doc.slot_generations[4] | Should -Be 1
    }
}

Describe 'the lock file' {
    It 'a held lock fails the operation visibly after the bounded wait and admits nothing' {
        $root = New-CapAllocator -Linux 1 -Windows 1
        $rev = (Get-CapDoc $root).revision
        $fs = [IO.File]::Open((Join-Path $root 'allocator.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $r = Request-AapReservation -Root $root -Profile windows -MemOverheadMib 512 -DiskGib 190 -IoMbps 100 -LockTimeoutSeconds 2
            $sw.Stop()
            $r.Status | Should -Be 'error'
            $r.Reason | Should -Be 'lock_timeout'
            $r.Detail | Should -BeLike '*nothing admitted*'
            $sw.Elapsed.TotalSeconds | Should -BeGreaterOrEqual 1.9
        } finally { $fs.Dispose() }
        (Get-CapDoc $root).revision | Should -Be $rev
        @(Get-CapLive (Get-CapDoc $root)).Count | Should -Be 0
    }

    It 'a lock held by a process that dies is free again at once' {
        $root = New-CapAllocator -Linux 1 -Windows 1
        $marker = Join-Path $TestDrive 'lock-held'
        $c = Start-CapChild -Root $root -Body "param(`$root) `$fs = [IO.File]::Open((Join-Path `$root 'allocator.lock'), 'OpenOrCreate', 'ReadWrite', 'None'); [IO.File]::WriteAllText('$marker', 'held'); Start-Sleep -Seconds 120"
        $deadline = [DateTime]::UtcNow.AddSeconds(90)
        while (-not (Test-Path $marker)) {
            if ([DateTime]::UtcNow -gt $deadline) { throw 'child did not take the lock' }
            Start-Sleep -Milliseconds 20
        }
        (Request-AapReservation -Root $root -Profile windows -MemOverheadMib 512 -DiskGib 190 -IoMbps 100 -LockTimeoutSeconds 1).Reason | Should -Be 'lock_timeout'
        $c.Process.Kill()
        $c.Process.WaitForExit()
        (Request-AapReservation -Root $root -Profile windows -MemOverheadMib 512 -DiskGib 190 -IoMbps 100 -LockTimeoutSeconds 2).Ok | Should -BeTrue
    }
}

Describe 'a controller killed at every persisted boundary' {
    BeforeEach { $script:Now = [DateTime]::UtcNow }

    It 'initialize, killed before its first file is in place: initialize again' {
        $root = New-CapRoot
        $h = '@{ cpu_cores = 32; mem_gib = 96; disk_gib = 2000; io_mbps = 1000; control_distro_mem_gib = 1 }'
        Invoke-CapCrash $root "param(`$root) Initialize-AapAllocator -Root `$root -HostInfo ($h) -Linux 1 -Windows 1" 'after-temp'
        Test-Path -LiteralPath (Join-Path $root 'allocator.json') | Should -BeFalse
        (Initialize-AapAllocator -Root $root -HostInfo (New-CapHostInfo) -Linux 1 -Windows 1).Ok | Should -BeTrue
        Assert-CapSound $root
    }

    It 'request, killed between the temp file and the replace: nothing was admitted, the generation was not spent' {
        $root = New-CapAllocator -Linux 1 -Windows 2
        $rev = (Get-CapDoc $root).revision
        Invoke-CapCrash $root "param(`$root) Request-AapReservation -Root `$root -Profile windows $($script:VmArgs)" 'after-temp'
        $doc = Get-CapDoc $root
        $doc.revision | Should -Be $rev
        @(Get-CapLive $doc).Count | Should -Be 0
        @($doc.slot_generations) | Should -Be @(0, 0, 0, 0, 0)
        Test-Path -LiteralPath (Join-Path $root 'allocator.json.tmp') | Should -BeTrue
        [void](Invoke-AapReconcile -Root $root -Inventory { @{ vms = @(); folders = @(); journaled = @() } })
        Test-Path -LiteralPath (Join-Path $root 'allocator.json.tmp') | Should -BeFalse
        $r = (Request-AapReservation -Root $root -Profile windows -MemOverheadMib 512 -DiskGib 190 -IoMbps 100).Reservation
        $r.slot | Should -Be 1
        $r.lease_generation | Should -Be 1
        Assert-CapSound $root
    }

    It 'request, killed after the replace (the caller never saw it): reconcile frees it with a proof, no generation reused' {
        $root = New-CapAllocator -Linux 1 -Windows 2
        Invoke-CapCrash $root "param(`$root) Request-AapReservation -Root `$root -Profile windows $($script:VmArgs)" 'after-replace'
        $orphan = @(Get-CapLive (Get-CapDoc $root))
        $orphan.Count | Should -Be 1
        $orphan[0].state | Should -Be 'creating'
        Assert-CapSound $root
        $r = Invoke-AapReconcile -Root $root -Inventory { @{ vms = @(); folders = @(); journaled = @() } }
        $r.Ok | Should -BeTrue
        $o = Get-CapRes (Get-CapDoc $root) $orphan[0].reservation_id
        $o.state | Should -Be 'reconciled'
        $o.teardown_proof.runner_deregistered | Should -Be 'never_registered'
        $again = (Request-AapReservation -Root $root -Profile windows -MemOverheadMib 512 -DiskGib 190 -IoMbps 100).Reservation
        $again.slot | Should -Be $orphan[0].slot
        $again.lease_generation | Should -Be ($orphan[0].lease_generation + 1)
        Assert-CapSound $root
    }

    It 'request, killed after the replace while the provider already journaled create: the slot stays held for replay' {
        $root = New-CapAllocator -Linux 1 -Windows 2
        Invoke-CapCrash $root "param(`$root) Request-AapReservation -Root `$root -Profile windows $($script:VmArgs)" 'after-replace'
        $orphan = @(Get-CapLive (Get-CapDoc $root))[0]
        $r = Invoke-AapReconcile -Root $root -Inventory { @{ vms = @(); folders = @(); journaled = @($orphan.reservation_id) } }.GetNewClosure()
        @($r.Actions | Where-Object { $_.action -eq 'replay' }).Count | Should -Be 1
        (Get-CapRes (Get-CapDoc $root) $orphan.reservation_id).state | Should -Be 'creating'
        $next = (Request-AapReservation -Root $root -Profile windows -MemOverheadMib 512 -DiskGib 190 -IoMbps 100).Reservation
        $next.slot | Should -Not -Be $orphan.slot
        Assert-CapSound $root
    }

    It 'creating -> ready, killed before the replace: still creating, kept for replay while its VM exists' {
        $root = New-CapAllocator -Linux 1 -Windows 2
        $res = (Request-AapReservation -Root $root -Profile windows -MemOverheadMib 512 -DiskGib 190 -IoMbps 100).Reservation
        $vmId = New-CapVmId
        Invoke-CapCrash $root "param(`$root) Set-AapSlotState -Root `$root -ReservationId $($res.reservation_id) -LeaseGeneration $($res.lease_generation) -State ready -VmId $vmId" 'after-temp'
        (Get-CapRes (Get-CapDoc $root) $res.reservation_id).state | Should -Be 'creating'
        $name = Get-AapVmName -Profile windows -Slot $res.slot -LeaseGeneration $res.lease_generation -ReservationId $res.reservation_id
        $r = Invoke-AapReconcile -Root $root -Inventory { @{ vms = @(@{ name = $name; vm_id = $vmId; cpus = 9; mem_gib = 28 }); folders = @($res.reservation_id); journaled = @($res.reservation_id) } }.GetNewClosure()
        @($r.Actions).action | Should -Be @('replay')
        @($r.Unresolved).Count | Should -Be 0
        (Set-AapSlotState -Root $root -ReservationId $res.reservation_id -LeaseGeneration $res.lease_generation -State ready -VmId $vmId).Ok | Should -BeTrue
        Assert-CapSound $root
    }

    It 'ready -> busy, killed after the replace: busy is kept, nothing is released while the VM runs' {
        $root = New-CapAllocator -Linux 1 -Windows 2
        $w = New-CapVm $root
        Invoke-CapCrash $root "param(`$root) Set-AapSlotState -Root `$root -ReservationId $($w.reservation_id) -LeaseGeneration $($w.lease_generation) -State busy" 'after-replace'
        (Get-CapRes (Get-CapDoc $root) $w.reservation_id).state | Should -Be 'busy'
        $name = Get-AapVmName -Profile windows -Slot $w.slot -LeaseGeneration $w.lease_generation -ReservationId $w.reservation_id
        $r = Invoke-AapReconcile -Root $root -Inventory { @{ vms = @(@{ name = $name; vm_id = $w.vm_id; cpus = 9; mem_gib = 28 }); folders = @($w.reservation_id); journaled = @($w.reservation_id) } }.GetNewClosure()
        $r.Status | Should -Be 'unchanged'
        (Get-AapAllocatorState -Root $root).UsedSlots | Should -Be 1
        Assert-CapSound $root
    }

    It 'busy -> collecting, killed before the replace: still busy, still held' {
        $root = New-CapAllocator -Linux 1 -Windows 2
        $w = New-CapVm $root -Busy
        Invoke-CapCrash $root "param(`$root) Set-AapSlotState -Root `$root -ReservationId $($w.reservation_id) -LeaseGeneration $($w.lease_generation) -State collecting" 'after-temp'
        (Get-CapRes (Get-CapDoc $root) $w.reservation_id).state | Should -Be 'busy'
        (Get-AapAllocatorState -Root $root).UsedSlots | Should -Be 1
        Assert-CapSound $root
    }

    It 'collecting -> deleting, killed after the replace: reconcile asks for the destroy again and frees nothing' {
        $root = New-CapAllocator -Linux 1 -Windows 2
        $w = New-CapVm $root -Busy
        [void](Set-AapSlotState -Root $root -ReservationId $w.reservation_id -LeaseGeneration $w.lease_generation -State collecting)
        Invoke-CapCrash $root "param(`$root) Set-AapSlotState -Root `$root -ReservationId $($w.reservation_id) -LeaseGeneration $($w.lease_generation) -State deleting" 'after-replace'
        $name = Get-AapVmName -Profile windows -Slot $w.slot -LeaseGeneration $w.lease_generation -ReservationId $w.reservation_id
        $r = Invoke-AapReconcile -Root $root -Inventory { @{ vms = @(@{ name = $name; vm_id = $w.vm_id; cpus = 9; mem_gib = 28 }); folders = @(); journaled = @($w.reservation_id) } }.GetNewClosure()
        @($r.Actions | Where-Object { $_.action -eq 'destroy' }).reservation_id | Should -Be $w.reservation_id
        (Get-CapRes (Get-CapDoc $root) $w.reservation_id).state | Should -Be 'deleting'
        (Get-AapAllocatorState -Root $root).UsedSlots | Should -Be 1
        Assert-CapSound $root
    }

    It 'teardown, killed before the replace: still deleting, never released early; the proof frees it once' {
        $root = New-CapAllocator -Linux 1 -Windows 2
        $w = New-CapVm $root -Busy
        [void](Set-AapSlotState -Root $root -ReservationId $w.reservation_id -LeaseGeneration $w.lease_generation -State collecting)
        [void](Set-AapSlotState -Root $root -ReservationId $w.reservation_id -LeaseGeneration $w.lease_generation -State deleting)
        $at = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        $proof = "@{ kind = 'vm'; observed_at = '$at'; vm_absent = `$true; disks_absent = `$true; vm_files_absent = `$true; runner_deregistered = `$true }"
        Invoke-CapCrash $root "param(`$root) Complete-AapTeardown -Root `$root -ReservationId $($w.reservation_id) -LeaseGeneration $($w.lease_generation) -Proof ($proof)" 'after-temp'
        (Get-CapRes (Get-CapDoc $root) $w.reservation_id).state | Should -Be 'deleting'
        $r = Invoke-AapReconcile -Root $root -Inventory { @{ vms = @(); folders = @(); journaled = @($w.reservation_id) } }.GetNewClosure()
        @($r.Actions).action | Should -Be @('destroy')
        (Get-AapAllocatorState -Root $root).UsedSlots | Should -Be 1
        (Complete-AapTeardown -Root $root -ReservationId $w.reservation_id -LeaseGeneration $w.lease_generation -Proof (New-CapProof 'vm' $true $at)).Ok | Should -BeTrue
        (Get-AapAllocatorState -Root $root).UsedSlots | Should -Be 0
        Assert-CapSound $root
    }

    It 'resize Windows 2 -> 0, killed before the replace: the old counts stand and nothing drained' {
        $root = New-CapAllocator -Linux 1 -Windows 2
        $w = New-CapVm $root -Busy
        Invoke-CapCrash $root "param(`$root) Set-AapProfileCounts -Root `$root -Linux 1 -Windows 0" 'after-temp'
        $doc = Get-CapDoc $root
        $doc.profiles.windows.count | Should -Be 2
        (Get-CapRes $doc $w.reservation_id).state | Should -Be 'busy'
        $r = Set-AapProfileCounts -Root $root -Linux 1 -Windows 0
        @($r.Drained) | Should -Be @($w.reservation_id)
        Assert-CapSound $root
    }

    It 'legacy adoption, killed before the replace: not adopted, so no VM is admitted' {
        $root = New-CapRoot
        [void](Initialize-AapAllocator -Root $root -HostInfo (New-CapHostInfo) -Linux 3 -Windows 2)
        [void](Set-AapProfileCounts -Root $root -Linux 3 -Windows 2 -WindowsGeneration $script:WinGen)
        $at = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        $status = "[pscustomobject]@{ state = 'idle'; runner_count = 3; job_cpus = 15; job_memory_gib = 51; sampled_at = '$at'; slots = @([pscustomobject]@{ slot = 1; state = 'idle' }, [pscustomobject]@{ slot = 2; state = 'idle' }, [pscustomobject]@{ slot = 3; state = 'idle' }) }"
        Invoke-CapCrash $root "param(`$root) Register-AapLegacySlots -Root `$root -ManagerStatus ($status) -ManagerVersion manager-2" 'after-temp'
        (Get-CapDoc $root).legacy_adopted | Should -BeFalse
        (Request-AapReservation -Root $root -Profile windows -MemOverheadMib 512 -DiskGib 190 -IoMbps 100).Reason | Should -Be 'legacy_not_adopted'
        $script:Now = [DateTime]::UtcNow
        (Register-AapLegacySlots -Root $root -ManagerVersion 'manager-2' -ManagerStatus (New-CapStatus 3 15 51 @('idle', 'idle', 'idle') -State 'idle')).Ok | Should -BeTrue
        Assert-CapSound $root
    }

    It 'reconcile, killed before the replace: nothing applied; run again, applied once' {
        $root = New-CapAllocator -Linux 1 -Windows 2
        $w = New-CapVm $root -Busy
        Invoke-CapCrash $root "param(`$root) Invoke-AapReconcile -Root `$root -Inventory { @{ vms = @(); folders = @(); journaled = @() } }" 'after-temp'
        (Get-CapRes (Get-CapDoc $root) $w.reservation_id).state | Should -Be 'busy'
        $r = Invoke-AapReconcile -Root $root -Inventory { @{ vms = @(); folders = @(); journaled = @() } }
        (Get-CapRes (Get-CapDoc $root) $w.reservation_id).state | Should -Be 'deleting'
        @($r.Actions).action | Should -Be @('destroy')
        Assert-CapSound $root
    }

    It 'legacy release, killed after the replace: released exactly once, with a legacy proof' {
        $root = New-CapAllocator -Linux 3 -Windows 2 -LegacySlots 3
        $drained = @((Set-AapProfileCounts -Root $root -Linux 2 -Windows 2).Drained)
        $at = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        $status = "[pscustomobject]@{ state = 'idle'; runner_count = 2; job_cpus = 10; job_memory_gib = 34; sampled_at = '$at'; slots = @([pscustomobject]@{ slot = 1; state = 'idle' }, [pscustomobject]@{ slot = 2; state = 'idle' }) }"
        Invoke-CapCrash $root "param(`$root) Update-AapHeartbeat -Root `$root -ManagerStatus ($status)" 'after-replace'
        $gone = @((Get-CapDoc $root).reservations | Where-Object { $_.state -eq 'reconciled' })
        $gone.Count | Should -Be 1
        $drained.Count | Should -Be 1
        $gone[0].reservation_id | Should -Be $drained[0]
        $gone[0].teardown_proof.kind | Should -Be 'legacy'
        $script:Now = [DateTime]::UtcNow
        (Update-AapHeartbeat -Root $root -ManagerStatus (New-CapStatus 2 10 34 @('idle', 'idle') -State 'idle')).Status | Should -Be 'unchanged'
        Assert-CapSound $root
    }
}
