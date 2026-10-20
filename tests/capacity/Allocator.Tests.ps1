# Behaviour of the mixed-fleet allocator (ledger item P09): admission, shares and budgets,
# resizing, heartbeats and quarantine, teardown, generations, legacy adoption and reconcile.
# The clock is mocked; every capacity folder is a fresh test folder. Pester 5, Windows
# PowerShell 5.1 and PowerShell 7.5+.

BeforeAll {
    . (Join-Path $PSScriptRoot 'Fixture.ps1')
    Import-Module $script:CapModule -Force
    $PSDefaultParameterValues['*-Aap*:RelaxedTrustForTests'] = $true
    $PSDefaultParameterValues['*-Aap*:WarningAction'] = 'SilentlyContinue'
}

AfterAll {
    $PSDefaultParameterValues.Remove('*-Aap*:RelaxedTrustForTests')
    $PSDefaultParameterValues.Remove('*-Aap*:WarningAction')
}

Describe 'initialize and read' {
    BeforeAll { Mock -ModuleName AapCapacity Get-AapUtcNow { $script:Now } }
    BeforeEach { Set-CapNow '2026-10-20T10:00:00Z' }

    It 'writes a valid revision 1 state once and leaves it alone afterwards' {
        $root = New-CapRoot
        $r = Initialize-AapAllocator -Root $root -HostInfo (New-CapHostInfo) -Linux 3 -Windows 2
        $r.Ok | Should -BeTrue
        (Test-AapAllocatorState -Path (Join-Path $root 'allocator.json')).Valid | Should -BeTrue
        $doc = Get-CapDoc $root
        $doc.revision | Should -Be 1
        $doc.legacy_adopted | Should -BeFalse
        @($doc.slot_generations) | Should -Be @(0, 0, 0, 0, 0)
        $again = Initialize-AapAllocator -Root $root -HostInfo (New-CapHostInfo -Cpu 8) -Linux 1
        $again.Status | Should -Be 'unchanged'
        (Get-CapDoc $root).host.cpu_cores | Should -Be 32
    }

    It 'stores the owner example: 3 Linux 60 %, 2 Windows 30 %, 10 % kept for the desktop' {
        $root = New-CapRoot
        (Initialize-AapAllocator -Root $root -HostInfo (New-CapHostInfo) -Linux 3 -Windows 2 -ShareMode per_profile -LinuxShare 60 -WindowsShare 30).Ok | Should -BeTrue
        $s = Get-AapAllocatorState -Root $root
        $s.Profiles.linux.EachCpus | Should -Be 6
        $s.Profiles.linux.EachMemGib | Should -Be 19
        $s.Profiles.windows.EachCpus | Should -Be 4
        $s.Profiles.windows.EachMemGib | Should -Be 14
        $s.PoolCpus | Should -Be 28
        $s.PoolMemGib | Should -Be 85
        $s.FreeSlots | Should -Be 5
    }

    It 'a call before initialize leaves no log behind, so initialize still runs' {
        $root = New-CapRoot
        (Request-AapReservation -Root $root -Profile linux).Reason | Should -Be 'not_initialized'
        Test-Path -LiteralPath (Join-Path $root 'allocator.log') | Should -BeFalse
        (Initialize-AapAllocator -Root $root -HostInfo (New-CapHostInfo)).Ok | Should -BeTrue
    }

    It 'names a corrupt unresolved.json instead of failing on it' {
        $root = New-CapAllocator -Linux 1 -Windows 1
        Write-CapText (Join-Path $root 'unresolved.json') '{"items": '
        $r = Request-AapReservation -Root $root -Profile linux -ImageGeneration 'legacy-manager-2'
        $r.Reason | Should -Be 'invalid_state'
        $r.Detail | Should -BeLike '*unresolved.json*'
        (Invoke-AapReconcile -Root $root -Inventory { @{ vms = @(); folders = @(); journaled = @() } }).Reason | Should -Be 'invalid_state'
        Remove-Item -LiteralPath (Join-Path $root 'unresolved.json')
        (Invoke-AapReconcile -Root $root -Inventory { @{ vms = @(); folders = @(); journaled = @() } }).Ok | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $root 'unresolved.json') | Should -BeTrue
    }

    It 'refuses a missing state, and a state file that fails the contract, without writing' {
        $root = New-CapRoot
        (Request-AapReservation -Root $root -Profile linux).Reason | Should -Be 'not_initialized'
        $doc = Read-CapJson (Join-Path $script:FixtureDir 'valid\owner-example-2win-3lin-30-60-10.json')
        $doc.host_reserve_percent = 5
        Write-CapJson (Join-Path $root 'allocator.json') $doc
        $r = Request-AapReservation -Root $root -Profile windows -MemOverheadMib 512 -CloneGib 150 -ScratchGib 40 -IoMbps 100
        $r.Status | Should -Be 'error'
        $r.Reason | Should -Be 'invalid_state'
        $r.Detail | Should -BeLike '*below minimum 10*'
    }

    It 'reports a missing capacity folder as not initialized and creates nothing' {
        $root = Join-Path (New-CapRoot) 'missing'
        (Request-AapReservation -Root $root -Profile linux).Reason | Should -Be 'not_initialized'
        (Get-AapAllocatorState -Root $root).Reason | Should -Be 'not_initialized'
        Test-Path -LiteralPath $root | Should -BeFalse
    }

    It 'stores a new host measurement as is while the live reservations still fit' {
        $root = New-CapAllocator -Linux 1 -Windows 1 -LegacySlots 1
        [void](New-CapVm $root)
        (Set-AapHostMeasurement -Root $root -HostInfo (New-CapHostInfo -Disk 1500)).Ok | Should -BeTrue
        (Get-CapDoc $root).host.volumes[0].available_gib | Should -Be 1510
        $rev = (Get-CapDoc $root).revision
        (Set-AapHostMeasurement -Root $root -HostInfo (New-CapHostInfo -Cpu 0)).Reason | Should -Be 'bad_request'
        (Get-CapDoc $root).revision | Should -Be $rev
    }

    It 'a smaller disk or IO measurement is stored clamped to the live reservations, so the next VM is refused' {
        $root = New-CapAllocator -Linux 1 -Windows 3 -HostInfo (New-CapHostInfo -Disk 600)
        [void](New-CapVm $root)
        [void](New-CapVm $root)
        $r = Set-AapHostMeasurement -Root $root -HostInfo (New-CapHostInfo -Disk 200 -Io 100)
        $r.Status | Should -Be 'refused'
        $r.Reason | Should -Be 'pool_over_live'
        @($r.Clamped) | Should -Be @('volumes', 'io_mbps')
        (Test-AapAllocatorState -Path (Join-Path $root 'allocator.json')).Valid | Should -BeTrue
        $h = (Get-CapDoc $root).host
        $h.volumes[0].available_gib | Should -Be 390
        $h.io_mbps | Should -Be 223
        $h.cpu_cores | Should -Be 32
        (Request-AapReservation -Root $root -Profile windows -MemOverheadMib 512 -CloneGib 150 -ScratchGib 40 -IoMbps 100).Reason | Should -Be 'disk'
        $r = Set-AapHostMeasurement -Root $root -HostInfo (New-CapHostInfo -Disk 600 -Io 100)
        @($r.Clamped) | Should -Be @('io_mbps')
        (Request-AapReservation -Root $root -Profile windows -MemOverheadMib 512 -CloneGib 150 -ScratchGib 40 -IoMbps 100).Reason | Should -Be 'io'
        (Set-AapHostMeasurement -Root $root -HostInfo (New-CapHostInfo -Disk 600)).Ok | Should -BeTrue
        (Request-AapReservation -Root $root -Profile windows -MemOverheadMib 512 -CloneGib 150 -ScratchGib 40 -IoMbps 100).Ok | Should -BeTrue
    }

    It 'a measurement without the storage tiers keeps the live VMs layout, exactly full' {
        $root = New-CapAllocator -Linux 1 -Windows 2
        [void](New-CapVm $root)
        $r = Set-AapHostMeasurement -Root $root -HostInfo (New-CapHostInfo -NoStorage)
        $r.Reason | Should -Be 'pool_over_live'
        @($r.Clamped) | Should -Be @('volumes')
        $v = @((Get-CapDoc $root).host.volumes)
        $v.Count | Should -Be 1
        $v[0].available_gib | Should -Be 200
        (Request-AapReservation -Root $root -Profile windows -MemOverheadMib 512 -CloneGib 1 -ScratchGib 0 -IoMbps 100).Reason | Should -Be 'disk'
        (Test-AapAllocatorState -Path (Join-Path $root 'allocator.json')).Valid | Should -BeTrue
    }

    It 'refuses a measurement that lists a volume twice or a tier on two volumes' {
        $root = New-CapAllocator -Linux 1 -Windows 1
        $rev = (Get-CapDoc $root).revision
        $twice = @((New-CapVolume 'e1' @('base', 'staging') 500), (New-CapVolume 'e1' @('clone', 'scratch') 500))
        (Set-AapHostMeasurement -Root $root -HostInfo (New-CapHostInfo -Volumes $twice)).Detail | Should -BeLike '*a volume is listed twice*'
        $split = @((New-CapVolume 'e1' @('base', 'clone') 500), (New-CapVolume 'e2' @('clone', 'scratch') 500))
        $r = Set-AapHostMeasurement -Root $root -HostInfo (New-CapHostInfo -Volumes $split)
        $r.Reason | Should -Be 'bad_request'
        $r.Detail | Should -BeLike '*tier clone is on more than one volume*'
        (Get-CapDoc $root).revision | Should -Be $rev
    }

    It 'a larger control VM is stored cut to what the live reservations leave, so nothing more is admitted' {
        $root = New-CapAllocator -Mode per_profile -Linux 1 -Windows 2 -LinuxShare 30 -WindowsShare 60
        [void](New-CapVm $root)
        [void](New-CapVm $root)
        $r = Set-AapHostMeasurement -Root $root -HostInfo (New-CapHostInfo -Ctl 40)
        $r.Reason | Should -Be 'pool_over_live'
        @($r.Clamped) | Should -Be @('control_distro_mem_gib')
        $s = Get-AapAllocatorState -Root $root
        $s.State.host.control_distro_mem_gib | Should -Be 30
        $s.UsedMemGib | Should -Be $s.PoolMemGib
        (Request-AapReservation -Root $root -Profile linux -ImageGeneration 'legacy-manager-2' -Cpus 1 -MemGib 1).Reason | Should -Be 'memory'
    }

    It 'a smaller CPU or RAM measurement is raised only to the least the admitted runners fit, and admits nothing more' {
        $root = New-CapAllocator -Linux 1 -Windows 2
        [void](New-CapVm $root)
        $r = Set-AapHostMeasurement -Root $root -HostInfo (New-CapHostInfo -Cpu 8 -Mem 16)
        $r.Reason | Should -Be 'pool_over_live'
        @($r.Clamped) | Should -Be @('cpu_cores', 'mem_gib', 'control_distro_mem_gib')
        $h = (Get-CapDoc $root).host
        $h.cpu_cores | Should -Be 30
        $h.mem_gib | Should -Be 94
        $h.control_distro_mem_gib | Should -Be 0
        (Test-AapAllocatorState -Path (Join-Path $root 'allocator.json')).Valid | Should -BeTrue
        (Get-AapAllocatorState -Root $root).MeasurementClamped | Should -BeTrue
        (Request-AapReservation -Root $root -Profile linux -ImageGeneration 'legacy-manager-2').Reason | Should -Be 'pool_over_live'
        (Request-AapReservation -Root $root -Profile windows -MemOverheadMib 512 -CloneGib 150 -ScratchGib 40 -IoMbps 100).Reason | Should -Be 'pool_over_live'
        (Set-AapHostMeasurement -Root $root -HostInfo (New-CapHostInfo)).Ok | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $root 'host.measured.json') | Should -BeFalse
        (Request-AapReservation -Root $root -Profile linux -ImageGeneration 'legacy-manager-2').Ok | Should -BeTrue
    }

    It 'a volume below its floor with nothing on it is storage_low, not pool_over_live; legacy slots go on' {
        $root = New-CapAllocator -Linux 1 -Windows 1
        $r = Set-AapHostMeasurement -Root $root -HostInfo (New-CapHostInfo -Volumes @(New-CapVolume 'e1' @('base', 'clone', 'scratch', 'staging') 5 10))
        $r.Reason | Should -Be 'storage_low'
        (Request-AapReservation -Root $root -Profile windows -MemOverheadMib 512 -CloneGib 150 -ScratchGib 40 -IoMbps 100).Reason | Should -Be 'disk'
        (Request-AapReservation -Root $root -Profile linux -ImageGeneration 'legacy-manager-2').Ok | Should -BeTrue
    }

    It 'never starts again at revision 1 over lost state: a missing allocator.json beside its log or backup is refused' {
        $root = New-CapAllocator -Linux 1 -Windows 1
        $doc = Get-CapDoc $root
        (Read-CapJson (Join-Path $root 'allocator.json.bak')).revision | Should -Be ($doc.revision - 1)
        Remove-Item -LiteralPath (Join-Path $root 'allocator.json')
        $r = Initialize-AapAllocator -Root $root -HostInfo (New-CapHostInfo) -Linux 1 -Windows 1
        $r.Status | Should -Be 'error'
        $r.Reason | Should -Be 'invalid_state'
        $r.Detail | Should -BeLike '*allocator.json.bak, allocator.log*'
        Test-Path -LiteralPath (Join-Path $root 'allocator.json') | Should -BeFalse
        Remove-Item -LiteralPath (Join-Path $root 'allocator.json.bak')
        (Initialize-AapAllocator -Root $root -HostInfo (New-CapHostInfo)).Reason | Should -Be 'invalid_state'
        Remove-Item -LiteralPath (Join-Path $root 'allocator.log')
        Write-CapText (Join-Path $root 'allocator.json.tmp') ([IO.File]::ReadAllText((Join-Path (New-CapAllocator) 'allocator.json')))
        (Initialize-AapAllocator -Root $root -HostInfo (New-CapHostInfo)).Detail | Should -BeLike '*allocator.json.tmp exist*'
    }

    It 'refuses a state whose revision went backwards in this process' {
        $root = New-CapAllocator
        $old = [IO.File]::ReadAllText((Join-Path $root 'allocator.json'))
        (Set-AapProfileCounts -Root $root -Linux 2 -Windows 2).Ok | Should -BeTrue
        Write-CapText (Join-Path $root 'allocator.json') $old
        $r = Request-AapReservation -Root $root -Profile linux -ImageGeneration 'legacy-manager-2'
        $r.Reason | Should -Be 'invalid_state'
        $r.Detail | Should -BeLike '*lower than revision*'
    }
}

Describe 'admission' {
    BeforeAll { Mock -ModuleName AapCapacity Get-AapUtcNow { $script:Now } }
    BeforeEach { Set-CapNow '2026-10-20T10:00:00Z' }

    It 'takes profile names, states and ids exactly as written' {
        { Get-AapVmName -Profile WINDOWS -Slot 1 -LeaseGeneration 1 -ReservationId 'r-0123456789abcdef' } | Should -Throw
        { Get-AapVmName -Profile windows -Slot 1 -LeaseGeneration 1 -ReservationId "r-0123456789abcdef`n" } | Should -Throw
        Get-AapVmName -Profile windows -Slot 1 -LeaseGeneration 1 -ReservationId 'r-0123456789abcdef' | Should -BeExactly 'aap-w-1-1-01234567'
        $root = New-CapAllocator -Linux 1 -Windows 1
        { Request-AapReservation -Root $root -Profile LINUX -ImageGeneration 'legacy-manager-2' } | Should -Throw
        $res = (Request-AapReservation -Root $root -Profile windows -MemOverheadMib 512 -CloneGib 150 -ScratchGib 40 -IoMbps 100).Reservation
        { Set-AapSlotState -Root $root -ReservationId $res.reservation_id -LeaseGeneration $res.lease_generation -State Ready -VmId (New-CapVmId) } | Should -Throw
        (Get-CapRes (Get-CapDoc $root) $res.reservation_id).state | Should -Be 'creating'
    }

    It 'echoes no control characters from rejected ids in its detail' {
        $root = New-CapAllocator -Linux 1 -Windows 1
        $res = (Request-AapReservation -Root $root -Profile windows -MemOverheadMib 512 -CloneGib 150 -ScratchGib 40 -IoMbps 100).Reservation
        $r = Set-AapSlotState -Root $root -ReservationId $res.reservation_id -LeaseGeneration $res.lease_generation -State ready -VmId "evil`r`nstatus: ok"
        $r.Reason | Should -Be 'bad_request'
        $r.Detail | Should -Not -Match '[\r\n]'
        $r.Detail | Should -BeLike '*evil  status: ok*'
        $n = Set-AapSlotState -Root $root -ReservationId "r-forged`nline" -LeaseGeneration 1 -State ready
        $n.Reason | Should -Be 'not_found'
        $n.Detail | Should -Not -Match '[\r\n]'
    }

    It 'persists the reservation, generation first, before it returns the derived VM and runner name' {
        $root = New-CapAllocator
        $r = Request-AapReservation -Root $root -Profile windows -MemOverheadMib 512 -CloneGib 150 -ScratchGib 40 -IoMbps 100
        $r.Ok | Should -BeTrue
        $res = $r.Reservation
        $doc = Get-CapDoc $root
        $onDisk = Get-CapRes $doc $res.reservation_id
        $onDisk.state | Should -Be 'creating'
        $onDisk.lease_generation | Should -Be 1
        $doc.slot_generations[0] | Should -Be 1
        $onDisk.idempotency_key | Should -Be "$($res.reservation_id)/1"
        $r.VmName | Should -BeExactly (Get-AapVmName -Profile windows -Slot $res.slot -LeaseGeneration 1 -ReservationId $res.reservation_id)
        $r.RunnerName | Should -BeExactly $r.VmName
        $r.VmName | Should -Match '^aap-w-1-1-[0-9a-f]{8}$'
        $onDisk.cpus | Should -Be 5
        $onDisk.mem_gib | Should -Be 16
        $onDisk.mem_overhead_mib | Should -Be 512
        $ready = Set-AapSlotState -Root $root -ReservationId $res.reservation_id -LeaseGeneration 1 -State ready -VmId (New-CapVmId)
        $ready.Reservation.runner_name | Should -BeExactly $r.VmName
    }

    It 'adopts the legacy pool before any admission' {
        $root = New-CapRoot
        (Initialize-AapAllocator -Root $root -HostInfo (New-CapHostInfo) -Linux 3 -Windows 2).Ok | Should -BeTrue
        [void](Set-AapProfileCounts -Root $root -Linux 3 -Windows 2 -WindowsGeneration $script:WinGen)
        (Request-AapReservation -Root $root -Profile windows -MemOverheadMib 512 -CloneGib 150 -ScratchGib 40 -IoMbps 100).Reason | Should -Be 'legacy_not_adopted'
        (Request-AapReservation -Root $root -Profile linux -ImageGeneration 'legacy-manager-2').Reason | Should -Be 'legacy_not_adopted'
    }

    It 'refuses a sixth worker: count when the profile is full, ceiling when all five slots are held' {
        $root = New-CapAllocator -LegacySlots 3
        [void](New-CapVm $root)
        [void](New-CapVm $root)
        (Get-AapAllocatorState -Root $root).UsedSlots | Should -Be 5
        (Request-AapReservation -Root $root -Profile windows -MemOverheadMib 512 -CloneGib 150 -ScratchGib 40 -IoMbps 100).Reason | Should -Be 'count'
        (Request-AapReservation -Root $root -Profile linux).Reason | Should -Be 'count'
        # 4 Linux + 1 Windows: a Windows VM drains, Linux has room in its count but no slot is free.
        $r = Set-AapProfileCounts -Root $root -Linux 4 -Windows 1
        $r.Ok | Should -BeTrue
        @($r.Drained).Count | Should -Be 1
        $sixth = Request-AapReservation -Root $root -Profile linux
        $sixth.Reason | Should -Be 'ceiling'
        $doc = Get-CapDoc $root
        @(Get-CapLive $doc).Count | Should -Be 5
        (Test-AapAllocatorState -State $doc).Valid | Should -BeTrue
    }

    It 'keeps per-runner shares: VM memory overhead is paid from the share, never from the reserve' {
        $root = New-CapAllocator -Mode per_profile -LinuxShare 60 -WindowsShare 30
        $r = Request-AapReservation -Root $root -Profile windows -MemGib 14 -MemOverheadMib 512 -CloneGib 150 -ScratchGib 40 -IoMbps 100
        $r.Reason | Should -Be 'share'
        (Request-AapReservation -Root $root -Profile windows -Cpus 5 -MemOverheadMib 512 -CloneGib 150 -ScratchGib 40 -IoMbps 100).Reason | Should -Be 'share'
        $ok = Request-AapReservation -Root $root -Profile windows -MemOverheadMib 512 -CloneGib 150 -ScratchGib 40 -IoMbps 100
        $ok.Ok | Should -BeTrue
        $ok.Reservation.cpus | Should -Be 4
        $ok.Reservation.mem_gib | Should -Be 13
    }

    It 'pays the control VM first: memory over the pool is refused (memory)' {
        $root = New-CapAllocator -Mode per_profile -LinuxShare 60 -WindowsShare 30 -HostInfo (New-CapHostInfo -Ctl 5) -LegacySlots 3
        [void](New-CapVm $root)
        $r = Request-AapReservation -Root $root -Profile windows -MemOverheadMib 512 -CloneGib 150 -ScratchGib 40 -IoMbps 100
        $r.Reason | Should -Be 'memory'
        @(Get-CapLive (Get-CapDoc $root)).Count | Should -Be 4
    }

    It 'counts clone and scratch caps on the volume that holds each tier' {
        $vols = @((New-CapVolume 'a1' @('base', 'staging') 520 50 140), (New-CapVolume 'b2' @('clone') 200 50), (New-CapVolume 'c3' @('scratch') 100 50))
        $root = New-CapAllocator -Linux 1 -Windows 3 -HostInfo (New-CapHostInfo -Volumes $vols)
        (Request-AapReservation -Root $root -Profile windows -MemOverheadMib 512 -CloneGib 100 -ScratchGib 40 -IoMbps 100).Ok | Should -BeTrue
        $r = Request-AapReservation -Root $root -Profile windows -MemOverheadMib 512 -CloneGib 40 -ScratchGib 20 -IoMbps 100
        $r.Reason | Should -Be 'disk'
        $r.Detail | Should -BeLike '*0000000000c3*'
        (Request-AapReservation -Root $root -Profile windows -MemOverheadMib 512 -CloneGib 60 -ScratchGib 10 -IoMbps 100).Detail | Should -BeLike '*0000000000b2*'
        (Request-AapReservation -Root $root -Profile windows -MemOverheadMib 512 -CloneGib 50 -ScratchGib 10 -IoMbps 100).Ok | Should -BeTrue
        (Test-AapAllocatorState -Path (Join-Path $root 'allocator.json')).Valid | Should -BeTrue
    }

    It 'admits no VM without a trusted storage layout, a legacy slot still' {
        $root = New-CapAllocator -HostInfo (New-CapHostInfo -NoStorage)
        (Request-AapReservation -Root $root -Profile windows -MemOverheadMib 512 -CloneGib 150 -ScratchGib 40 -IoMbps 100).Reason | Should -Be 'storage'
        (Request-AapReservation -Root $root -Profile windows -MemOverheadMib 512 -CloneGib 0 -ScratchGib 40 -IoMbps 100).Reason | Should -Be 'bad_request'
        (Request-AapReservation -Root $root -Profile linux -ImageGeneration 'legacy-manager-2').Ok | Should -BeTrue
    }

    It 'refuses storage pressure (disk) and unmeasured or exhausted IO' {
        $root = New-CapAllocator -HostInfo (New-CapHostInfo -Disk 300)
        [void](New-CapVm $root)
        (Request-AapReservation -Root $root -Profile windows -MemOverheadMib 512 -CloneGib 150 -ScratchGib 40 -IoMbps 100).Reason | Should -Be 'disk'
        $root = New-CapAllocator -HostInfo (New-CapHostInfo -Io 0)
        (Request-AapReservation -Root $root -Profile windows -MemOverheadMib 512 -CloneGib 150 -ScratchGib 40 -IoMbps 0).Reason | Should -Be 'io_unmeasured'
        (Request-AapReservation -Root $root -Profile linux -ImageGeneration 'legacy-manager-2').Ok | Should -BeTrue
        $root = New-CapAllocator -HostInfo (New-CapHostInfo -Io 200)
        [void](New-CapVm $root -Io 100)
        (Request-AapReservation -Root $root -Profile windows -MemOverheadMib 512 -CloneGib 150 -ScratchGib 40 -IoMbps 100).Reason | Should -Be 'io'
    }

    It 'admits a VM only on the active generation with its measured budget' {
        $root = New-CapAllocator
        (Request-AapReservation -Root $root -Profile windows -MemOverheadMib 512 -CloneGib 150 -ScratchGib 40).Reason | Should -Be 'bad_request'
        (Request-AapReservation -Root $root -Profile windows -ImageGeneration 'win25-vs2026-x64/20261007.264.1-aap.2' -MemOverheadMib 512 -CloneGib 150 -ScratchGib 40 -IoMbps 100).Reason | Should -Be 'generation'
        (Request-AapReservation -Root $root -Profile linux -ImageGeneration 'legacy-manager-2' -CloneGib 10).Reason | Should -Be 'bad_request'
        (Request-AapReservation -Root $root -Profile linux -ImageGeneration 'legacy-manager-2' -ScratchGib 1).Reason | Should -Be 'bad_request'
    }

    It 'never puts two live reservations in one slot (duplicate lease)' {
        $root = New-CapAllocator
        $a = (Request-AapReservation -Root $root -Profile windows -MemOverheadMib 512 -CloneGib 150 -ScratchGib 40 -IoMbps 100).Reservation
        $b = (Request-AapReservation -Root $root -Profile windows -MemOverheadMib 512 -CloneGib 150 -ScratchGib 40 -IoMbps 100).Reservation
        $a.slot | Should -Not -Be $b.slot
        $a.reservation_id | Should -Not -Be $b.reservation_id
        # A replayed transition for a lease that is no longer live changes nothing.
        $vm = New-CapVmId
        (Set-AapSlotState -Root $root -ReservationId $a.reservation_id -LeaseGeneration $a.lease_generation -State ready -VmId $vm).Ok | Should -BeTrue
        (Set-AapSlotState -Root $root -ReservationId $a.reservation_id -LeaseGeneration ($a.lease_generation + 1) -State busy).Status | Should -Be 'ignored'
        (Get-CapRes (Get-CapDoc $root) $a.reservation_id).state | Should -Be 'ready'
    }
}

Describe 'profile counts and shares' {
    BeforeAll { Mock -ModuleName AapCapacity Get-AapUtcNow { $script:Now } }
    BeforeEach { Set-CapNow '2026-10-20T10:00:00Z' }

    It 'takes Linux 0-5 and Windows 0-5 with a sum of 1-5, each maximum following the other' {
        $root = New-CapAllocator
        (Set-AapProfileCounts -Root $root -Linux 3 -Windows 3).Reason | Should -Be 'bad_request'
        (Set-AapProfileCounts -Root $root -Linux 0 -Windows 0).Reason | Should -Be 'bad_request'
        (Set-AapProfileCounts -Root $root -Linux 6 -Windows 0).Reason | Should -Be 'bad_request'
        (Set-AapProfileCounts -Root $root -Linux 3 -Windows 2).Ok | Should -BeTrue
        (Set-AapProfileCounts -Root $root -Linux 0 -Windows 5).Ok | Should -BeTrue
        (Set-AapProfileCounts -Root $root -Linux 5 -Windows 0).Ok | Should -BeTrue
        (Set-AapProfileCounts -Root $root -Linux 5 -Windows 0).Status | Should -Be 'unchanged'
    }

    It 'never gives away the host reserve' {
        $root = New-CapAllocator -Mode per_profile -LinuxShare 60 -WindowsShare 30
        (Set-AapProfileCounts -Root $root -Linux 3 -Windows 2 -LinuxShare 65 -WindowsShare 30).Detail | Should -BeLike '*must equal 100*'
        (Set-AapProfileCounts -Root $root -Linux 3 -Windows 2 -HostReservePercent 5 -LinuxShare 65 -WindowsShare 30).Reason | Should -Be 'bad_request'
        (Set-AapProfileCounts -Root $root -Linux 3 -Windows 0 -LinuxShare 60 -WindowsShare 30).Detail | Should -BeLike '*share 0 exactly when its count is 0*'
        (Set-AapProfileCounts -Root $root -Linux 3 -Windows 0 -LinuxShare 90 -WindowsShare 0).Ok | Should -BeTrue
        (Set-AapProfileCounts -Root $root -Linux 3 -Windows 1 -ShareMode even).Ok | Should -BeTrue
        (Get-CapDoc $root).profiles.linux.share_percent | Should -BeNullOrEmpty
    }

    It 'refuses a larger reserve the live reservations cannot fit, and changes nothing' {
        $root = New-CapAllocator -Mode per_profile -LinuxShare 60 -WindowsShare 30 -LegacySlots 3
        $rev = (Get-CapDoc $root).revision
        $r = Set-AapProfileCounts -Root $root -Linux 3 -Windows 2 -HostReservePercent 40 -LinuxShare 40 -WindowsShare 20
        $r.Reason | Should -Be 'pool_over_live'
        (Get-CapDoc $root).revision | Should -Be $rev
        (Get-CapDoc $root).host_reserve_percent | Should -Be 10
    }

    It 'Windows 2 -> 0 with a job running: the busy VM drains, nothing is cancelled, Linux waits for the overhang' {
        $root = New-CapAllocator -Linux 2 -Windows 2 -LegacySlots 2
        $busy = New-CapVm $root -Busy
        $idle = New-CapVm $root
        $r = Set-AapProfileCounts -Root $root -Linux 2 -Windows 0
        $r.Ok | Should -BeTrue
        @($r.Drained) | Should -Contain $busy.reservation_id
        @($r.Drained) | Should -Contain $idle.reservation_id
        @($r.Cancelled).Count | Should -Be 0
        $doc = Get-CapDoc $root
        (Get-CapRes $doc $busy.reservation_id).state | Should -Be 'draining'
        Add-CapSeconds 20
        (Update-AapHeartbeat -Root $root -ReservationId $busy.reservation_id -LeaseGeneration $busy.lease_generation -JobRunning).Status | Should -Be 'unchanged'
        Add-CapSeconds 20
        (Update-AapHeartbeat -Root $root -ReservationId $busy.reservation_id -LeaseGeneration $busy.lease_generation -JobRunning).Ok | Should -BeTrue
        (Get-CapRes (Get-CapDoc $root) $busy.reservation_id).state | Should -Be 'draining'
        # Linux grows to 4: its new share would fit only once the draining VMs are reconciled.
        (Set-AapProfileCounts -Root $root -Linux 4 -Windows 0).Ok | Should -BeTrue
        (Request-AapReservation -Root $root -Profile linux).Reason | Should -Be 'pool'
        [void](Remove-CapVm $root $busy)
        [void](Remove-CapVm $root $idle)
        (Request-AapReservation -Root $root -Profile linux).Ok | Should -BeTrue
    }

    It '3 Linux + 2 Windows -> 4 Linux + 1 Windows: the fourth Linux slot waits until the Windows VM is reconciled' {
        $root = New-CapAllocator -LegacySlots 3
        $w4 = New-CapVm $root -Busy
        $w5 = New-CapVm $root
        $r = Set-AapProfileCounts -Root $root -Linux 4 -Windows 1
        @($r.Drained) | Should -Be @($w5.reservation_id)
        (Get-CapRes (Get-CapDoc $root) $w4.reservation_id).state | Should -Be 'busy'
        (Request-AapReservation -Root $root -Profile linux).Reason | Should -Be 'ceiling'
        (Remove-CapVm $root $w5).Ok | Should -BeTrue
        $g = Request-AapReservation -Root $root -Profile linux
        $g.Ok | Should -BeTrue
        $g.Reservation.slot | Should -Be $w5.slot
        $g.Reservation.lease_generation | Should -Be ($w5.lease_generation + 1)
        $g.Reservation.backend | Should -Be 'wsl-legacy'
        $l = Get-AapLegacyLimits -Root $root
        $l.RunnerCount | Should -Be 4
        $l.JobCpus | Should -Be 20
        $l.JobMemoryGib | Should -Be 68
    }

    It 'Linux 0 drains and stops the legacy pool; Windows is admitted once the legacy slots are gone' {
        $root = New-CapAllocator -LegacySlots 3
        $r = Set-AapProfileCounts -Root $root -Linux 0 -Windows 2
        @($r.Drained).Count | Should -Be 3
        $l = Get-AapLegacyLimits -Root $root
        $l.Stop | Should -BeTrue
        $l.RunnerCount | Should -Be 0
        (Request-AapReservation -Root $root -Profile windows -MemOverheadMib 512 -CloneGib 150 -ScratchGib 40 -IoMbps 100).Reason | Should -Be 'pool'
        (Request-AapReservation -Root $root -Profile linux).Reason | Should -Be 'count'
        $u = Update-AapHeartbeat -Root $root -ManagerStopped
        $u.Ok | Should -BeTrue
        $doc = Get-CapDoc $root
        @($doc.reservations | Where-Object { $_.backend -eq 'wsl-legacy' -and $_.state -eq 'reconciled' -and $_.teardown_proof.kind -eq 'legacy' }).Count | Should -Be 3
        (Request-AapReservation -Root $root -Profile windows -MemOverheadMib 512 -CloneGib 150 -ScratchGib 40 -IoMbps 100).Ok | Should -BeTrue
    }

    It 'cancels a creating legacy slot and waits for a heartbeat quarantine instead of cancelling a job' {
        $root = New-CapAllocator -Linux 2 -Windows 2 -LegacySlots 1
        $grant = (Request-AapReservation -Root $root -Profile linux).Reservation
        $w = New-CapVm $root -Busy
        Add-CapSeconds 95
        (Invoke-AapReconcile -Root $root).Ok | Should -BeTrue
        (Get-CapRes (Get-CapDoc $root) $w.reservation_id).quarantine_kind | Should -Be 'heartbeat'
        $r = Set-AapProfileCounts -Root $root -Linux 1 -Windows 0
        $r.Reason | Should -Be 'resize_waits'
        $r.Detail | Should -BeLike "*$($w.reservation_id)*"
        (Update-AapHeartbeat -Root $root -ReservationId $w.reservation_id -LeaseGeneration $w.lease_generation -JobRunning).Ok | Should -BeTrue
        $r = Set-AapProfileCounts -Root $root -Linux 1 -Windows 0
        $r.Ok | Should -BeTrue
        @($r.Cancelled) | Should -Be @($grant.reservation_id)
        @($r.Drained) | Should -Be @($w.reservation_id)
    }

    It 'drains admitted runners that no longer fit a smaller per-runner share' {
        $root = New-CapAllocator -Linux 2 -Windows 2 -LegacySlots 2
        $w = New-CapVm $root
        # even, 4 runners: 7 CPUs each; 5 runners: 5 each, so every admitted runner is over its share.
        $r = Set-AapProfileCounts -Root $root -Linux 3 -Windows 2
        @($r.Drained).Count | Should -Be 3
        (Test-AapAllocatorState -Path (Join-Path $root 'allocator.json')).Valid | Should -BeTrue
    }
}

Describe 'heartbeats and quarantine' {
    BeforeAll { Mock -ModuleName AapCapacity Get-AapUtcNow { $script:Now } }
    BeforeEach { Set-CapNow '2026-10-20T10:00:00Z' }

    It 'a lost heartbeat quarantines the slot after 90 s and never frees its capacity' {
        $root = New-CapAllocator -Linux 1 -Windows 1
        $w = New-CapVm $root -Busy
        Add-CapSeconds 89
        (Invoke-AapReconcile -Root $root).Status | Should -Be 'unchanged'
        Add-CapSeconds 1
        $r = Invoke-AapReconcile -Root $root
        $r.Ok | Should -BeTrue
        $q = Get-CapRes (Get-CapDoc $root) $w.reservation_id
        $q.state | Should -Be 'quarantined'
        $q.quarantine_kind | Should -Be 'heartbeat'
        $q.cleanup_uncertain | Should -BeTrue
        (Get-AapAllocatorState -Root $root).UsedSlots | Should -Be 1
        (Request-AapReservation -Root $root -Profile windows -MemOverheadMib 512 -CloneGib 150 -ScratchGib 40 -IoMbps 100).Reason | Should -Be 'count'
        (Complete-AapTeardown -Root $root -ReservationId $w.reservation_id -LeaseGeneration $w.lease_generation -Proof $null).Reason | Should -Be 'invalid_proof'
        Add-CapSeconds 3600
        [void](Invoke-AapReconcile -Root $root)
        (Get-CapRes (Get-CapDoc $root) $w.reservation_id).state | Should -Be 'quarantined'
    }

    It 'a validated heartbeat returns a heartbeat quarantine to busy or ready' {
        $root = New-CapAllocator -Linux 1 -Windows 2
        $a = New-CapVm $root -Busy
        $b = New-CapVm $root
        Add-CapSeconds 120
        [void](Invoke-AapReconcile -Root $root)
        (Update-AapHeartbeat -Root $root -ReservationId $a.reservation_id -LeaseGeneration $a.lease_generation -JobRunning).Ok | Should -BeTrue
        (Update-AapHeartbeat -Root $root -ReservationId $b.reservation_id -LeaseGeneration $b.lease_generation).Ok | Should -BeTrue
        $doc = Get-CapDoc $root
        (Get-CapRes $doc $a.reservation_id).state | Should -Be 'busy'
        (Get-CapRes $doc $b.reservation_id).state | Should -Be 'ready'
        (Get-CapRes $doc $a.reservation_id).cleanup_uncertain | Should -BeFalse
        (Get-CapRes $doc $a.reservation_id).quarantine_kind | Should -BeNullOrEmpty
    }

    It 'writes heartbeat_at at most every 30 s' {
        $root = New-CapAllocator -Linux 1 -Windows 1
        $w = New-CapVm $root -Busy
        $rev = (Get-CapDoc $root).revision
        Add-CapSeconds 29
        (Update-AapHeartbeat -Root $root -ReservationId $w.reservation_id -LeaseGeneration $w.lease_generation -JobRunning).Status | Should -Be 'unchanged'
        (Get-CapDoc $root).revision | Should -Be $rev
        Add-CapSeconds 1
        (Update-AapHeartbeat -Root $root -ReservationId $w.reservation_id -LeaseGeneration $w.lease_generation -JobRunning).Status | Should -Be 'ok'
        (Get-CapRes (Get-CapDoc $root) $w.reservation_id).heartbeat_at | Should -Be (Get-CapTime)
    }

    It 'destroys a heartbeat quarantine only when the broker reports the runner offline or absent and not busy' {
        $root = New-CapAllocator -Linux 1 -Windows 1
        $w = New-CapVm $root -Busy
        Add-CapSeconds 100
        [void](Invoke-AapReconcile -Root $root)
        foreach ($answer in @(@{ status = 'online'; busy = $false }, @{ status = 'offline'; busy = $true }, @{ status = 'absent'; busy = 'false' })) {
            $r = Invoke-AapReconcile -Root $root -BrokerStatus { param($res) $answer }.GetNewClosure()
            @($r.Actions).Count | Should -Be 0
            (Get-CapRes (Get-CapDoc $root) $w.reservation_id).state | Should -Be 'quarantined'
        }
        [void](Invoke-AapReconcile -Root $root -BrokerStatus { throw 'broker unavailable' })
        (Get-CapRes (Get-CapDoc $root) $w.reservation_id).state | Should -Be 'quarantined'
        $r = Invoke-AapReconcile -Root $root -BrokerStatus { param($res) @{ status = 'offline'; busy = $false } }
        (Get-CapRes (Get-CapDoc $root) $w.reservation_id).state | Should -Be 'deleting'
        @($r.Actions | Where-Object { $_.action -eq 'destroy' -and $_.reservation_id -eq $w.reservation_id }).Count | Should -Be 1
    }

    It 'a job known to have ended allows destroy; a busy runner past the wall clock is held and flagged' {
        $root = New-CapAllocator -Linux 1 -Windows 2
        $a = New-CapVm $root -Busy
        $b = New-CapVm $root -Busy
        Add-CapSeconds (7 * 3600)
        [void](Invoke-AapReconcile -Root $root)
        $r = Invoke-AapReconcile -Root $root -BrokerStatus { param($res) if ($res.slot -eq 1) { @{ status = 'online'; busy = $true } } else { @{ status = 'online'; busy = $false; job_ended = $true } } }
        $doc = Get-CapDoc $root
        (Get-CapRes $doc $a.reservation_id).state | Should -Be 'quarantined'
        (Get-CapRes $doc $a.reservation_id).cleanup_uncertain | Should -BeTrue
        (Get-CapRes $doc $b.reservation_id).state | Should -Be 'deleting'
        @($r.Flags).Count | Should -Be 1
        $r.Flags[0] | Should -BeLike 'slot 1 *wall clock*busy True*held*'
    }

    It 'a hostile guest is immediate and final: straight to deleting, never back to service' {
        $root = New-CapAllocator -Linux 1 -Windows 1
        $w = New-CapVm $root -Busy
        (Set-AapSlotState -Root $root -ReservationId $w.reservation_id -LeaseGeneration $w.lease_generation -State deleting).Reason | Should -Be 'illegal_edge'
        $rev = (Get-CapDoc $root).revision
        $r = Set-AapSlotState -Root $root -ReservationId $w.reservation_id -LeaseGeneration $w.lease_generation -State quarantined -QuarantineKind hostile_guest -Reason 'wrong_echo'
        $r.Ok | Should -BeTrue
        $r.Reservation.state | Should -Be 'deleting'
        $r.Reservation.cleanup_uncertain | Should -BeTrue
        (Get-CapDoc $root).revision | Should -Be ($rev + 1)
        (Update-AapHeartbeat -Root $root -ReservationId $w.reservation_id -LeaseGeneration $w.lease_generation -JobRunning).Status | Should -Be 'ignored'
        (Set-AapSlotState -Root $root -ReservationId $w.reservation_id -LeaseGeneration $w.lease_generation -State ready).Reason | Should -Be 'illegal_edge'
        (Complete-AapTeardown -Root $root -ReservationId $w.reservation_id -LeaseGeneration $w.lease_generation -Proof (New-CapProof 'vm')).Ok | Should -BeTrue
        [IO.File]::ReadAllText((Join-Path $root 'allocator.log')) | Should -BeLike '*busy->deleting hostile_guest wrong_echo*'
    }

    It 'reconcile finishes a hostile quarantine an interrupted write left, with one destroy' {
        $root = New-CapAllocator -Linux 1 -Windows 1
        $w = New-CapVm $root -Busy
        [void](Set-AapSlotState -Root $root -ReservationId $w.reservation_id -LeaseGeneration $w.lease_generation -State quarantined -QuarantineKind crash -Reason 'journal_unreadable')
        $doc = Get-CapDoc $root
        $doc.revision = $doc.revision + 1
        (Get-CapRes $doc $w.reservation_id).quarantine_kind = 'hostile_guest'
        Write-CapJson (Join-Path $root 'allocator.json') $doc
        $name = Get-AapVmName -Profile windows -Slot $w.slot -LeaseGeneration $w.lease_generation -ReservationId $w.reservation_id
        $r = Invoke-AapReconcile -Root $root -Inventory { @{ vms = @(@{ name = $name; vm_id = $w.vm_id; cpus = 9; mem_gib = 28 }); folders = @($w.reservation_id); journaled = @($w.reservation_id) } }.GetNewClosure()
        $q = Get-CapRes (Get-CapDoc $root) $w.reservation_id
        $q.state | Should -Be 'deleting'
        $q.quarantine_kind | Should -BeNullOrEmpty
        $q.cleanup_uncertain | Should -BeTrue
        @($r.Actions | Where-Object { $_.action -eq 'destroy' }).Count | Should -Be 1
        $r.Actions[0].vm_name | Should -BeExactly $name
        (Update-AapHeartbeat -Root $root -ReservationId $w.reservation_id -LeaseGeneration $w.lease_generation -JobRunning).Status | Should -Be 'ignored'
        (Set-AapSlotState -Root $root -ReservationId $w.reservation_id -LeaseGeneration $w.lease_generation -State quarantined -QuarantineKind hostile_guest -Reason 'wrong_echo').Status | Should -Be 'unchanged'
    }

    It 'an unknown VM goes to deleting only on reconcile, when a journal entry names it' {
        $root = New-CapAllocator -Linux 1 -Windows 1
        $vmId = New-CapVmId
        $inv = { param($j) @{ vms = @(@{ name = 'aap-w-3-7-deadbeef'; vm_id = $vmId; cpus = 4; mem_gib = 8 }); folders = @(); journaled = @($j) } }.GetNewClosure()
        [void](Invoke-AapReconcile -Root $root -Inventory { & $inv @() }.GetNewClosure())
        $q = @((Get-CapDoc $root).reservations | Where-Object { $_.quarantine_kind -eq 'unknown_vm' })[0]
        (Set-AapSlotState -Root $root -ReservationId $q.reservation_id -LeaseGeneration $q.lease_generation -State deleting).Reason | Should -Be 'illegal_edge'
        $id = $q.reservation_id
        $r = Invoke-AapReconcile -Root $root -Inventory { & $inv @($id) }.GetNewClosure()
        (Get-CapRes (Get-CapDoc $root) $id).state | Should -Be 'deleting'
        @($r.Actions | Where-Object { $_.action -eq 'destroy' -and $_.reservation_id -eq $id }).Count | Should -Be 1
    }

    It 'refuses a reason with a DEL or a Unicode line separator' {
        $root = New-CapAllocator -Linux 1 -Windows 1
        $w = New-CapVm $root -Busy
        foreach ($bad in @('\u007f', '\u0085', '\u2028')) {
            $reason = 'journal' + [regex]::Unescape($bad) + 'unreadable'
            (Set-AapSlotState -Root $root -ReservationId $w.reservation_id -LeaseGeneration $w.lease_generation -State quarantined -QuarantineKind crash -Reason $reason).Reason | Should -Be 'bad_request' -Because $bad
        }
    }

    It 'hostile_guest applies to VM guests only' {
        $root = New-CapAllocator -Linux 1 -Windows 1 -LegacySlots 1
        $l = @((Get-CapDoc $root).reservations | Where-Object { $_.backend -eq 'wsl-legacy' })[0]
        (Set-AapSlotState -Root $root -ReservationId $l.reservation_id -LeaseGeneration $l.lease_generation -State quarantined -QuarantineKind hostile_guest -Reason 'wrong_echo').Reason | Should -Be 'bad_request'
    }

    It 'a heartbeat quarantine goes to deleting only through reconcile, never on a provider call' {
        $root = New-CapAllocator -Linux 1 -Windows 1
        $w = New-CapVm $root -Busy
        Add-CapSeconds 100
        [void](Invoke-AapReconcile -Root $root)
        $r = Set-AapSlotState -Root $root -ReservationId $w.reservation_id -LeaseGeneration $w.lease_generation -State deleting
        $r.Reason | Should -Be 'illegal_edge'
        (Get-CapRes (Get-CapDoc $root) $w.reservation_id).state | Should -Be 'quarantined'
    }

    It 'a credential-shaped hostile reason is withheld, and the quarantine is still recorded' {
        $root = New-CapAllocator -Linux 1 -Windows 1
        $w = New-CapVm $root -Busy
        [void](Set-AapSlotState -Root $root -ReservationId $w.reservation_id -LeaseGeneration $w.lease_generation -State quarantined -QuarantineKind crash -Reason 'journal_unreadable')
        $r = Set-AapSlotState -Root $root -ReservationId $w.reservation_id -LeaseGeneration $w.lease_generation -State quarantined -QuarantineKind hostile_guest -Reason 'guest replied SYNTHETIC-JIT-MARKER'
        $r.Ok | Should -BeTrue
        $r.Detail | Should -BeLike '*reason withheld*'
        (Get-CapRes (Get-CapDoc $root) $w.reservation_id).state | Should -Be 'deleting'
        $log = [IO.File]::ReadAllText((Join-Path $root 'allocator.log'))
        $log | Should -BeLike '*quarantined->quarantined hostile_guest reason withheld*'
        $log | Should -Not -BeLike '*SYNTHETIC*'
        (Test-AapAllocatorState -Path (Join-Path $root 'allocator.json')).Valid | Should -BeTrue
    }

    It 'flags every live VM past the lease wall clock and destroys none for it' {
        $root = New-CapAllocator -Linux 1 -Windows 1
        $w = New-CapVm $root -Busy
        Add-CapSeconds (7 * 3600)
        [void](Update-AapHeartbeat -Root $root -ReservationId $w.reservation_id -LeaseGeneration $w.lease_generation -JobRunning)
        $r = Invoke-AapReconcile -Root $root
        @($r.Flags).Count | Should -Be 1
        $r.Flags[0] | Should -BeLike 'slot 1 *wall clock in state busy*status not read*never destroyed*'
        @($r.Actions).Count | Should -Be 0
        (Get-CapRes (Get-CapDoc $root) $w.reservation_id).state | Should -Be 'busy'
    }

    It 'a heartbeat or crash quarantine can still turn hostile, and a heartbeat never lifts that' {
        $root = New-CapAllocator -Linux 1 -Windows 2
        $a = New-CapVm $root -Busy
        $b = New-CapVm $root
        Add-CapSeconds 100
        [void](Set-AapSlotState -Root $root -ReservationId $b.reservation_id -LeaseGeneration $b.lease_generation -State quarantined -QuarantineKind crash -Reason 'journal unreadable')
        [void](Invoke-AapReconcile -Root $root)
        (Get-CapRes (Get-CapDoc $root) $a.reservation_id).quarantine_kind | Should -Be 'heartbeat'
        foreach ($w in @($a, $b)) {
            $rev = (Get-CapDoc $root).revision
            $r = Set-AapSlotState -Root $root -ReservationId $w.reservation_id -LeaseGeneration $w.lease_generation -State quarantined -QuarantineKind hostile_guest -Reason 'wrong_echo'
            $r.Ok | Should -BeTrue
            $r.Reservation.state | Should -Be 'deleting'
            (Get-CapDoc $root).revision | Should -Be ($rev + 2)
            (Update-AapHeartbeat -Root $root -ReservationId $w.reservation_id -LeaseGeneration $w.lease_generation -JobRunning).Status | Should -Be 'ignored'
            (Set-AapSlotState -Root $root -ReservationId $w.reservation_id -LeaseGeneration $w.lease_generation -State quarantined -QuarantineKind heartbeat -Reason 'x').Reason | Should -Be 'illegal_edge'
            $q = Get-CapRes (Get-CapDoc $root) $w.reservation_id
            $q.state | Should -Be 'deleting'
            $q.quarantine_kind | Should -BeNullOrEmpty
        }
        [IO.File]::ReadAllText((Join-Path $root 'allocator.log')) | Should -BeLike '*quarantined->quarantined hostile_guest wrong_echo*quarantined->deleting hostile_guest wrong_echo*'
        (Test-AapAllocatorState -Path (Join-Path $root 'allocator.json')).Valid | Should -BeTrue
    }
}

Describe 'teardown, edges and generations' {
    BeforeAll { Mock -ModuleName AapCapacity Get-AapUtcNow { $script:Now } }
    BeforeEach { Set-CapNow '2026-10-20T10:00:00Z' }

    It 'refuses every edge that is not in the state machine' {
        $root = New-CapAllocator -Linux 1 -Windows 1
        $res = (Request-AapReservation -Root $root -Profile windows -MemOverheadMib 512 -CloneGib 150 -ScratchGib 40 -IoMbps 100).Reservation
        $set = { param($state, $extra) Set-AapSlotState -Root $root -ReservationId $res.reservation_id -LeaseGeneration $res.lease_generation -State $state @extra }
        (& $set 'busy' @{}).Reason | Should -Be 'illegal_edge'
        (& $set 'draining' @{}).Reason | Should -Be 'illegal_edge'
        (& $set 'ready' @{}).Reason | Should -Be 'bad_request'
        (& $set 'ready' @{ VmId = (New-CapVmId) }).Ok | Should -BeTrue
        (& $set 'collecting' @{}).Reason | Should -Be 'illegal_edge'
        (& $set 'quarantined' @{ QuarantineKind = 'teardown_failed'; Reason = 'x' }).Reason | Should -Be 'illegal_edge'
        (& $set 'draining' @{}).Ok | Should -BeTrue
        (& $set 'busy' @{}).Reason | Should -Be 'illegal_edge'
        (& $set 'deleting' @{}).Reason | Should -Be 'illegal_edge'
        (& $set 'quarantined' @{ QuarantineKind = 'heartbeat'; Reason = 'x' }).Reason | Should -Be 'illegal_edge'
        (& $set 'collecting' @{}).Ok | Should -BeTrue
        (& $set 'ready' @{}).Reason | Should -Be 'illegal_edge'
        (& $set 'deleting' @{}).Ok | Should -BeTrue
        (& $set 'busy' @{}).Reason | Should -Be 'illegal_edge'
        (Test-AapAllocatorState -Path (Join-Path $root 'allocator.json')).Valid | Should -BeTrue
    }

    It 'frees a slot only with a valid teardown proof of the right kind' {
        $root = New-CapAllocator -Linux 1 -Windows 1
        $w = New-CapVm $root -Busy
        $complete = { param($proof) Complete-AapTeardown -Root $root -ReservationId $w.reservation_id -LeaseGeneration $w.lease_generation -Proof $proof }
        (& $complete (New-CapProof 'vm')).Reason | Should -Be 'illegal_edge'
        [void](Set-AapSlotState -Root $root -ReservationId $w.reservation_id -LeaseGeneration $w.lease_generation -State collecting)
        [void](Set-AapSlotState -Root $root -ReservationId $w.reservation_id -LeaseGeneration $w.lease_generation -State deleting)
        (& $complete (New-CapProof 'legacy')).Reason | Should -Be 'invalid_proof'
        $p = New-CapProof 'vm'; $p.vm_absent = $false
        (& $complete $p).Reason | Should -Be 'invalid_proof'
        $p = New-CapProof 'vm'; $p.extra = 1
        (& $complete $p).Reason | Should -Be 'invalid_proof'
        (& $complete (New-CapProof 'vm' 'deregistered')).Reason | Should -Be 'invalid_proof'
        (& $complete (New-CapProof 'vm' $true '2026-10-19T00:00:00Z')).Reason | Should -Be 'invalid_proof'
        (Get-AapAllocatorState -Root $root).UsedSlots | Should -Be 1
        $ok = & $complete (New-CapProof 'vm' 'github-removed')
        $ok.Ok | Should -BeTrue
        $ok.Reservation.teardown_proof.runner_deregistered | Should -Be 'github-removed'
        (& $complete (New-CapProof 'vm')).Status | Should -Be 'unchanged'
        (Get-AapAllocatorState -Root $root).UsedSlots | Should -Be 0
    }

    It 'a failed reset keeps the slot quarantined and its capacity held until a proof arrives' {
        $root = New-CapAllocator -Linux 1 -Windows 1 -LegacySlots 1
        $w = New-CapVm $root -Busy
        [void](Set-AapSlotState -Root $root -ReservationId $w.reservation_id -LeaseGeneration $w.lease_generation -State collecting)
        [void](Set-AapSlotState -Root $root -ReservationId $w.reservation_id -LeaseGeneration $w.lease_generation -State deleting)
        $f = Set-AapSlotState -Root $root -ReservationId $w.reservation_id -LeaseGeneration $w.lease_generation -State quarantined -QuarantineKind teardown_failed -Reason 'Remove-VM failed 3 times in 15 s'
        $f.Ok | Should -BeTrue
        Add-CapSeconds 3600
        [void](Invoke-AapReconcile -Root $root -BrokerStatus { param($r) @{ status = 'absent'; busy = $false } })
        $q = Get-CapRes (Get-CapDoc $root) $w.reservation_id
        $q.state | Should -Be 'quarantined'
        $q.quarantine_kind | Should -Be 'teardown_failed'
        (Get-AapAllocatorState -Root $root).UsedSlots | Should -Be 2
        (Request-AapReservation -Root $root -Profile windows -MemOverheadMib 512 -CloneGib 150 -ScratchGib 40 -IoMbps 100).Reason | Should -Be 'pool'
        (Complete-AapTeardown -Root $root -ReservationId $w.reservation_id -LeaseGeneration $w.lease_generation -Proof (New-CapProof 'vm')).Ok | Should -BeTrue
        (Request-AapReservation -Root $root -Profile windows -MemOverheadMib 512 -CloneGib 150 -ScratchGib 40 -IoMbps 100).Ok | Should -BeTrue
    }

    It 'ignores and logs a late completion for an older lease generation after the slot was reset' {
        $root = New-CapAllocator -Linux 1 -Windows 1
        $old = New-CapVm $root -Busy
        [void](Remove-CapVm $root $old)
        $new = New-CapVm $root -Busy
        $new.slot | Should -Be $old.slot
        $new.lease_generation | Should -Be ($old.lease_generation + 1)
        $late = Set-AapSlotState -Root $root -ReservationId $old.reservation_id -LeaseGeneration $old.lease_generation -State collecting
        $late.Status | Should -Be 'ignored'
        $late.Reason | Should -Be 'stale_generation'
        (Update-AapHeartbeat -Root $root -ReservationId $old.reservation_id -LeaseGeneration $old.lease_generation).Status | Should -Be 'ignored'
        (Complete-AapTeardown -Root $root -ReservationId $new.reservation_id -LeaseGeneration $old.lease_generation -Proof (New-CapProof 'vm')).Status | Should -Be 'ignored'
        (Get-CapRes (Get-CapDoc $root) $new.reservation_id).state | Should -Be 'busy'
        [IO.File]::ReadAllText((Join-Path $root 'allocator.log')) | Should -Match "ignored late collecting: $($old.reservation_id) generation $($old.lease_generation)"
    }

    It 'keeps each slot generation counting after reconciled entries are pruned' {
        $root = New-CapAllocator -Linux 1 -Windows 1
        $ids = @()
        for ($i = 1; $i -le 8; $i++) {
            Add-CapSeconds 1
            $w = New-CapVm $root
            $w.slot | Should -Be 1
            $w.lease_generation | Should -Be $i
            $ids += $w.reservation_id
            [void](Remove-CapVm $root $w)
        }
        $doc = Get-CapDoc $root
        @($doc.reservations).Count | Should -Be 5
        @($doc.reservations | ForEach-Object { $_.reservation_id }) | Should -Not -Contain $ids[0]
        $doc.slot_generations[0] | Should -Be 8
        (New-CapVm $root).lease_generation | Should -Be 9
    }

    It 'releases a VM that never got one (create failed before any lease) straight from creating' {
        $root = New-CapAllocator -Linux 1 -Windows 1
        $res = (Request-AapReservation -Root $root -Profile windows -MemOverheadMib 512 -CloneGib 150 -ScratchGib 40 -IoMbps 100).Reservation
        (Complete-AapTeardown -Root $root -ReservationId $res.reservation_id -LeaseGeneration 1 -Proof (New-CapProof 'vm')).Reason | Should -Be 'illegal_edge'
        (Complete-AapTeardown -Root $root -ReservationId $res.reservation_id -LeaseGeneration 1 -Proof (New-CapProof 'vm' 'never_registered')).Ok | Should -BeTrue
    }
}

Describe 'legacy pool' {
    BeforeAll { Mock -ModuleName AapCapacity Get-AapUtcNow { $script:Now } }
    BeforeEach { Set-CapNow '2026-10-20T10:00:00Z' }

    It 'adopts each manager slot from a fresh status.json, sized at the limits it was given' {
        $root = New-CapRoot
        [void](Initialize-AapAllocator -Root $root -HostInfo (New-CapHostInfo) -Linux 3 -Windows 2)
        $status = New-CapStatus 3 14 50 @('running', 'idle', '')
        $r = Register-AapLegacySlots -Root $root -ManagerStatus $status -ManagerVersion 'manager-2'
        $r.Ok | Should -BeTrue
        $doc = Get-CapDoc $root
        $doc.legacy_adopted | Should -BeTrue
        $legacy = @($doc.reservations | Sort-Object slot)
        @($legacy | ForEach-Object { $_.state }) | Should -Be @('busy', 'ready', 'ready')
        @($legacy | ForEach-Object { $_.cpus }) | Should -Be @(5, 5, 5)
        @($legacy | ForEach-Object { $_.mem_gib }) | Should -Be @(17, 17, 17)
        $legacy[0].image_generation | Should -Be 'legacy-manager-2'
        $legacy[2].heartbeat_at | Should -BeNullOrEmpty
        (Register-AapLegacySlots -Root $root -ManagerStatus $status).Status | Should -Be 'unchanged'
        # The retired slot never heartbeats, so it is quarantined after 90 s, capacity held.
        Add-CapSeconds 90
        [void](Invoke-AapReconcile -Root $root)
        (Get-CapRes (Get-CapDoc $root) $legacy[2].reservation_id).quarantine_kind | Should -Be 'heartbeat'
    }

    It 'never lets the legacy pool run five beside Windows: adoption waits and returns the limits.conf target' {
        $root = New-CapRoot
        [void](Initialize-AapAllocator -Root $root -HostInfo (New-CapHostInfo) -Linux 3 -Windows 2)
        [void](Set-AapProfileCounts -Root $root -Linux 3 -Windows 2 -WindowsGeneration $script:WinGen)
        $r = Register-AapLegacySlots -Root $root -ManagerStatus (New-CapStatus 5 25 85 @('running', 'idle', 'idle', 'idle', 'idle'))
        $r.Reason | Should -Be 'legacy_over_count'
        $r.Target.RunnerCount | Should -Be 3
        $r.Target.JobCpus | Should -Be 15
        $r.Target.JobMemoryGib | Should -Be 51
        (Request-AapReservation -Root $root -Profile windows -MemOverheadMib 512 -CloneGib 150 -ScratchGib 40 -IoMbps 100).Reason | Should -Be 'legacy_not_adopted'
        (Register-AapLegacySlots -Root $root -ManagerStatus (New-CapStatus 3 21 60 @('idle', 'idle', 'idle'))).Reason | Should -Be 'legacy_over_share'
        $l = Get-AapLegacyLimits -Root $root -JobCpus 26 -JobMemoryGib 80
        $l.Adopted | Should -BeFalse
        $l.RunnerCount | Should -Be 3
        $l.JobCpus | Should -Be 15
        (Register-AapLegacySlots -Root $root -ManagerStatus (New-CapStatus 3 15 51 @('idle', 'idle', 'idle'))).Ok | Should -BeTrue
        (Request-AapReservation -Root $root -Profile windows -MemOverheadMib 512 -CloneGib 150 -ScratchGib 40 -IoMbps 100).Ok | Should -BeTrue
    }

    It 'adopts only from a sample at most 90 s old (and not from the future)' {
        $root = New-CapRoot
        [void](Initialize-AapAllocator -Root $root -HostInfo (New-CapHostInfo) -Linux 3 -Windows 2)
        $old = $script:Now.AddSeconds(-91).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        (Register-AapLegacySlots -Root $root -ManagerStatus (New-CapStatus 3 15 51 @('idle', 'idle', 'idle') -SampledAt $old)).Reason | Should -Be 'legacy_status_stale'
        $future = $script:Now.AddSeconds(31).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        (Register-AapLegacySlots -Root $root -ManagerStatus (New-CapStatus 3 15 51 @('idle', 'idle', 'idle') -SampledAt $future)).Reason | Should -Be 'legacy_status_stale'
        (Register-AapLegacySlots -Root $root -ManagerStatus (New-CapStatus 3 15 51 @('idle', 'idle', 'idle') -State 'paused')).Reason | Should -Be 'legacy_status_stale'
        $offset = $script:Now.AddSeconds(-30).AddHours(2).ToString("yyyy-MM-dd'T'HH:mm:ss'+02:00'")
        (Register-AapLegacySlots -Root $root -ManagerStatus (New-CapStatus 3 15 51 @('idle', 'idle', 'idle') -SampledAt $offset)).Ok | Should -BeTrue
    }

    It 'takes legacy heartbeats from the manager slot entries and mirrors running and idle' {
        $root = New-CapAllocator -LegacySlots 2 -Linux 2 -Windows 2
        Add-CapSeconds 60
        $r = Update-AapHeartbeat -Root $root -ManagerStatus (New-CapStatus 2 14 42 @('running', 'idle'))
        $r.Ok | Should -BeTrue
        $legacy = @((Get-CapDoc $root).reservations | Sort-Object slot)
        $legacy[0].state | Should -Be 'busy'
        $legacy[0].heartbeat_at | Should -Be (Get-CapTime)
        Add-CapSeconds 60
        [void](Update-AapHeartbeat -Root $root -ManagerStatus (New-CapStatus 2 14 42 @('idle', 'idle')))
        (@((Get-CapDoc $root).reservations | Sort-Object slot))[0].state | Should -Be 'ready'
        Add-CapSeconds 95
        (Update-AapHeartbeat -Root $root -ManagerStatus (New-CapStatus 2 14 42 @('idle', 'idle') -SampledAt '2026-10-20T09:00:00Z')).Reason | Should -Be 'legacy_status_stale'
        [void](Invoke-AapReconcile -Root $root)
        @((Get-CapDoc $root).reservations | Where-Object { $_.quarantine_kind -eq 'heartbeat' }).Count | Should -Be 2
        [void](Update-AapHeartbeat -Root $root -ManagerStatus (New-CapStatus 2 14 42 @('running', 'idle')))
        @((Get-CapDoc $root).reservations | ForEach-Object { $_.state } | Sort-Object) | Should -Be @('busy', 'ready')
    }

    It 'releases a drained legacy slot only once the manager runs the granted configuration' {
        $root = New-CapAllocator -LegacySlots 3 -Linux 3 -Windows 2
        $r = Set-AapProfileCounts -Root $root -Linux 2 -Windows 2
        @($r.Drained).Count | Should -Be 1
        $l = Get-AapLegacyLimits -Root $root
        $l.RunnerCount | Should -Be 2
        $l.JobCpus | Should -Be 10
        # Still the old configuration (3 slots), or draining: held.
        [void](Update-AapHeartbeat -Root $root -ManagerStatus (New-CapStatus 3 15 51 @('idle', 'idle', 'idle')))
        [void](Update-AapHeartbeat -Root $root -ManagerStatus (New-CapStatus 2 10 34 @('draining', 'draining') -State 'draining'))
        @((Get-CapDoc $root).reservations | Where-Object { $_.state -eq 'reconciled' }).Count | Should -Be 0
        $u = Update-AapHeartbeat -Root $root -ManagerStatus (New-CapStatus 2 10 34 @('idle', 'idle') -State 'idle')
        $u.Ok | Should -BeTrue
        $gone = @((Get-CapDoc $root).reservations | Where-Object { $_.state -eq 'reconciled' })
        $gone.Count | Should -Be 1
        $gone[0].teardown_proof.kind | Should -Be 'legacy'
        $gone[0].reservation_id | Should -Be $r.Drained[0]
    }
}

Describe 'reconcile repairs' {
    BeforeAll { Mock -ModuleName AapCapacity Get-AapUtcNow { $script:Now } }

    It 'an inventory callback that returns <Name> changes nothing' -ForEach @(
        @{ Name = 'nothing'; Reason = 'invalid_inventory'; Inv = { $null } }
        @{ Name = 'an empty hashtable'; Reason = 'invalid_inventory'; Inv = { @{} } }
        @{ Name = 'no vms'; Reason = 'invalid_inventory'; Inv = { @{ folders = @(); journaled = @() } } }
        @{ Name = 'no folders'; Reason = 'invalid_inventory'; Inv = { @{ vms = @(); journaled = @() } } }
        @{ Name = 'no journaled'; Reason = 'invalid_inventory'; Inv = { @{ vms = @(); folders = @() } } }
        @{ Name = 'vms as a string'; Reason = 'invalid_inventory'; Inv = { @{ vms = 'none'; folders = @(); journaled = @() } } }
        @{ Name = 'folders as a hashtable'; Reason = 'invalid_inventory'; Inv = { @{ vms = @(); folders = @{}; journaled = @() } } }
        @{ Name = 'journaled as null'; Reason = 'invalid_inventory'; Inv = { @{ vms = @(); folders = @(); journaled = $null } } }
        @{ Name = 'two results'; Reason = 'invalid_inventory'; Inv = { @{ vms = @(); folders = @(); journaled = @() }; @{ vms = @(); folders = @(); journaled = @() } } }
        @{ Name = 'a VM without vm_id'; Reason = 'invalid_inventory'; Inv = { @{ vms = @(@{ name = 'aap-w-1-1-00000000' }); folders = @(); journaled = @() } } }
        @{ Name = 'a VM as a bare GUID'; Reason = 'invalid_inventory'; Inv = { @{ vms = @('6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4c'); folders = @(); journaled = @() } } }
        @{ Name = 'a VM name outside the pattern'; Reason = 'invalid_inventory'; Inv = { @{ vms = @(@{ name = 'build-agent'; vm_id = '6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4c' }); folders = @(); journaled = @() } } }
        @{ Name = 'a VM id in upper case'; Reason = 'invalid_inventory'; Inv = { @{ vms = @(@{ name = 'aap-w-1-1-00000000'; vm_id = '6F1D2C3B-4A59-4E6F-8A7B-9C0D1E2F3A4C' }); folders = @(); journaled = @() } } }
        @{ Name = 'a folder that is no reservation id'; Reason = 'invalid_inventory'; Inv = { @{ vms = @(); folders = @('clones'); journaled = @() } } }
        @{ Name = 'a journaled id with a final newline'; Reason = 'invalid_inventory'; Inv = { @{ vms = @(); folders = @(); journaled = @("r-00000000000000ff`n") } } }
        @{ Name = 'a throw'; Reason = 'failed'; Inv = { throw 'Get-VM failed' } }
    ) {
        Set-CapNow '2026-10-20T10:00:00Z'
        $root = New-CapAllocator -Linux 1 -Windows 2
        $w = New-CapVm $root -Busy
        $c = (Request-AapReservation -Root $root -Profile windows -MemOverheadMib 512 -CloneGib 150 -ScratchGib 40 -IoMbps 100).Reservation
        $rev = (Get-CapDoc $root).revision
        $r = Invoke-AapReconcile -Root $root -Inventory $Inv
        $r.Status | Should -Be 'error'
        $r.Reason | Should -Be $Reason
        $doc = Get-CapDoc $root
        $doc.revision | Should -Be $rev
        (Get-CapRes $doc $w.reservation_id).state | Should -Be 'busy'
        (Get-CapRes $doc $c.reservation_id).state | Should -Be 'creating'
        (Get-CapRes $doc $c.reservation_id).teardown_proof | Should -BeNullOrEmpty
    }

    It 'takes an inventory object as well as a hashtable' {
        Set-CapNow '2026-10-20T10:00:00Z'
        $root = New-CapAllocator -Linux 1 -Windows 2
        $w = New-CapVm $root -Busy
        $name = Get-AapVmName -Profile windows -Slot $w.slot -LeaseGeneration $w.lease_generation -ReservationId $w.reservation_id
        $r = Invoke-AapReconcile -Root $root -Inventory { [pscustomobject]@{ vms = @([pscustomobject]@{ name = $name; vm_id = $w.vm_id; cpus = 9; mem_gib = 28 }); folders = @($w.reservation_id); journaled = @($w.reservation_id) } }.GetNewClosure()
        $r.Ok | Should -BeTrue
        (Get-CapRes (Get-CapDoc $root) $w.reservation_id).state | Should -Be 'busy'
    }
    BeforeEach { Set-CapNow '2026-10-20T10:00:00Z' }

    It 'frees a reservation that never reached create (no VM, folder or journal) with a never_registered proof' {
        $root = New-CapAllocator -Linux 1 -Windows 2
        $orphan = (Request-AapReservation -Root $root -Profile windows -MemOverheadMib 512 -CloneGib 150 -ScratchGib 40 -IoMbps 100).Reservation
        $kept = (Request-AapReservation -Root $root -Profile windows -MemOverheadMib 512 -CloneGib 150 -ScratchGib 40 -IoMbps 100).Reservation
        $r = Invoke-AapReconcile -Root $root -Inventory { @{ vms = @(); folders = @($kept.reservation_id); journaled = @($kept.reservation_id) } }.GetNewClosure()
        $doc = Get-CapDoc $root
        $o = Get-CapRes $doc $orphan.reservation_id
        $o.state | Should -Be 'reconciled'
        $o.teardown_proof.runner_deregistered | Should -Be 'never_registered'
        (Get-CapRes $doc $kept.reservation_id).state | Should -Be 'creating'
        @($r.Actions | Where-Object { $_.action -eq 'replay' }).reservation_id | Should -Be $kept.reservation_id
        $doc.slot_generations[$orphan.slot - 1] | Should -Be 1
    }

    It 'sends a reservation whose VM is gone to deleting, never straight to free' {
        $root = New-CapAllocator -Linux 1 -Windows 1
        $w = New-CapVm $root -Busy
        $r = Invoke-AapReconcile -Root $root -Inventory { @{ vms = @(); folders = @(); journaled = @() } }
        (Get-CapRes (Get-CapDoc $root) $w.reservation_id).state | Should -Be 'deleting'
        @($r.Actions).action | Should -Be @('destroy')
        (Get-AapAllocatorState -Root $root).UsedSlots | Should -Be 1
    }

    It 'quarantines an unknown VM in a free slot and never adopts it' {
        $root = New-CapAllocator -Linux 1 -Windows 1
        $vmId = New-CapVmId
        $r = Invoke-AapReconcile -Root $root -Inventory { @{ vms = @(@{ name = 'aap-w-3-7-deadbeef'; vm_id = $vmId; cpus = 4; mem_gib = 8 }); folders = @(); journaled = @() } }.GetNewClosure()
        $r.Ok | Should -BeTrue
        $q = @((Get-CapDoc $root).reservations | Where-Object { $_.quarantine_kind -eq 'unknown_vm' })
        $q.Count | Should -Be 1
        $q[0].vm_id | Should -Be $vmId
        $q[0].quarantine_reason | Should -BeLike '*aap-w-3-7-deadbeef*'
        (Update-AapHeartbeat -Root $root -ReservationId $q[0].reservation_id -LeaseGeneration $q[0].lease_generation).Reason | Should -Be 'quarantine_final'
        $again = Invoke-AapReconcile -Root $root -Inventory { @{ vms = @(@{ name = 'aap-w-3-7-deadbeef'; vm_id = $vmId; cpus = 4; mem_gib = 8 }); folders = @(); journaled = @() } }.GetNewClosure()
        @((Get-CapDoc $root).reservations | Where-Object { $_.quarantine_kind -eq 'unknown_vm' }).Count | Should -Be 1
    }

    It 'refuses new admissions while an unknown VM or folder has no slot, until it is resolved' {
        $root = New-CapAllocator -Linux 3 -Windows 2 -LegacySlots 3
        [void](New-CapVm $root)
        [void](New-CapVm $root)
        $vmId = New-CapVmId
        $r = Invoke-AapReconcile -Root $root -Inventory {
            $vms = @(Get-AapAllocatorState -Root $root -RelaxedTrustForTests -WarningAction SilentlyContinue).State.reservations | Where-Object { $_.vm_id } | Where-Object { $_.state -ne 'reconciled' } | ForEach-Object { @{ name = (Get-AapVmName -Profile $_.profile -Slot $_.slot -LeaseGeneration $_.lease_generation -ReservationId $_.reservation_id); vm_id = $_.vm_id; cpus = 5; mem_gib = 16 } }
            @{ vms = @($vms) + @(@{ name = 'aap-l-2-3-cafecafe'; vm_id = $vmId; cpus = 2; mem_gib = 4 }); folders = @('r-00000000000000ff'); journaled = @() }
        }.GetNewClosure()
        @($r.Unresolved).Count | Should -Be 2
        [void](Set-AapProfileCounts -Root $root -Linux 4 -Windows 1)
        (Request-AapReservation -Root $root -Profile linux).Reason | Should -Be 'unresolved_unknown'
        [void](Invoke-AapReconcile -Root $root -Inventory {
                $vms = @(Get-AapAllocatorState -Root $root -RelaxedTrustForTests -WarningAction SilentlyContinue).State.reservations | Where-Object { $_.vm_id } | Where-Object { $_.state -ne 'reconciled' } | ForEach-Object { @{ name = (Get-AapVmName -Profile $_.profile -Slot $_.slot -LeaseGeneration $_.lease_generation -ReservationId $_.reservation_id); vm_id = $_.vm_id; cpus = 5; mem_gib = 16 } }
                @{ vms = @($vms); folders = @(); journaled = @() }
            }.GetNewClosure())
        (Request-AapReservation -Root $root -Profile linux).Reason | Should -Be 'ceiling'
    }

    It 'removes a temp file left by an interrupted write' {
        $root = New-CapAllocator -Linux 1 -Windows 1
        Write-CapText (Join-Path $root 'allocator.json.tmp') '{"half":'
        (Invoke-AapReconcile -Root $root).Status | Should -Be 'ok'
        Test-Path -LiteralPath (Join-Path $root 'allocator.json.tmp') | Should -BeFalse
    }
}

Describe 'a clamped host measurement across a restart' {
    It 'refuses every admission the raw measurement cannot hold, also after the module is loaded again' {
        $script:Now = [DateTime]::UtcNow
        $root = New-CapAllocator -Linux 1 -Windows 3
        [void](New-CapVm $root)
        (Set-AapHostMeasurement -Root $root -HostInfo (New-CapHostInfo -Cpu 8)).Reason | Should -Be 'pool_over_live'
        (Get-CapDoc $root).host.cpu_cores | Should -Be 32
        $linux = { Request-AapReservation -Root $root -Profile linux -ImageGeneration 'legacy-manager-2' }
        $windows = { Request-AapReservation -Root $root -Profile windows -MemOverheadMib 512 -CloneGib 150 -ScratchGib 40 -IoMbps 100 }
        (& $linux).Reason | Should -Be 'pool_over_live'
        (& $windows).Reason | Should -Be 'pool_over_live'
        Import-Module $script:CapModule -Force
        (& $linux).Reason | Should -Be 'pool_over_live'
        (& $windows).Reason | Should -Be 'pool_over_live'
        (Set-AapHostMeasurement -Root $root -HostInfo (New-CapHostInfo)).Ok | Should -BeTrue
        (& $windows).Ok | Should -BeTrue
    }
}
