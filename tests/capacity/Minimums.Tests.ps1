# Minimum guest CPU and memory per image generation (ledger item P22.2): a VM admission whose
# guest would be smaller than its image generation can boot is refused before any boot.
# Pester 5, Windows PowerShell 5.1 and PowerShell 7.5+.

BeforeAll {
    . (Join-Path $PSScriptRoot 'Fixture.ps1')
    Import-Module $script:CapModule -Force
    $PSDefaultParameterValues['*-Aap*:RelaxedTrustForTests'] = $true
    $PSDefaultParameterValues['*-Aap*:WarningAction'] = 'SilentlyContinue'
    $script:LinVmGen = 'ubuntu-24.04-x64/20261012.334.1-aap.1'
}

AfterAll {
    $PSDefaultParameterValues.Remove('*-Aap*:RelaxedTrustForTests')
    $PSDefaultParameterValues.Remove('*-Aap*:WarningAction')
}

Describe 'minimum guest size per image generation' {
    BeforeAll { Mock -ModuleName AapCapacity Get-AapUtcNow { $script:Now } }
    BeforeEach { Set-CapNow '2026-10-20T10:00:00Z' }

    It 'records a minimum for each image family and none for a legacy generation' {
        $w = Get-AapGenerationMinimum -ImageGeneration $script:WinGen
        $w.MinCpus | Should -Be 2
        $w.MinMemGib | Should -Be 4
        $l = Get-AapGenerationMinimum -ImageGeneration $script:LinVmGen
        $l.MinCpus | Should -Be 2
        $l.MinMemGib | Should -Be 2
        Get-AapGenerationMinimum -ImageGeneration 'legacy-manager-2' | Should -BeNullOrEmpty
        Get-AapGenerationMinimum -ImageGeneration 'win99-unknown-x64/20261007.264.1-aap.1' | Should -BeNullOrEmpty
    }

    It 'admits a Windows guest that fits on an 8 CPU / 16 GiB host and states the minimums in the result' {
        $root = New-CapAllocator -Linux 1 -Windows 1 -HostInfo (New-CapHostInfo -Cpu 8 -Mem 16)
        $r = Request-AapReservation -Root $root -Profile windows -MemOverheadMib 512 -CloneGib 150 -ScratchGib 40 -IoMbps 100
        $r.Ok | Should -BeTrue
        $r.Reservation.cpus | Should -BeGreaterOrEqual 2
        $r.Reservation.mem_gib | Should -BeGreaterOrEqual 4
        $r.MinCpus | Should -Be 2
        $r.MinMemGib | Should -Be 4
    }

    It 'refuses a Windows guest of about 2 GiB before boot: 5 runners share the 8 CPU / 16 GiB pool' {
        $root = New-CapAllocator -Linux 3 -Windows 2 -HostInfo (New-CapHostInfo -Cpu 8 -Mem 16)
        $before = (Get-AapAllocatorState -Root $root).Revision
        $r = Request-AapReservation -Root $root -Profile windows -MemOverheadMib 512 -CloneGib 150 -ScratchGib 40 -IoMbps 100
        $r.Ok | Should -BeFalse
        $r.Status | Should -Be 'refused'
        $r.Reason | Should -Be 'minimum'
        $r.Detail | Should -BeLike '*win25-vs2026-x64*at least 2 CPUs and 4 GiB*'
        $after = Get-AapAllocatorState -Root $root
        $after.Revision | Should -Be $before
        @(Get-CapLive $after.State).Count | Should -Be 0
    }

    It 'admits the owner example (3 Linux at 60 %, 2 Windows at 30 %) only where its Windows guests reach the minimum: <cpu> CPUs, <mem> GiB' -ForEach @(
        @{ cpu = 16; mem = 32 }, @{ cpu = 8; mem = 16 }
    ) {
        $root = New-CapAllocator -Mode per_profile -LinuxShare 60 -WindowsShare 30 -HostInfo (New-CapHostInfo -Cpu $cpu -Mem $mem -Ctl 2)
        foreach ($i in 1..3) { (Request-AapReservation -Root $root -Profile linux -ImageGeneration 'legacy-manager-2').Ok | Should -BeTrue }
        $r = Request-AapReservation -Root $root -Profile windows -MemOverheadMib 512 -CloneGib 150 -ScratchGib 40 -IoMbps 100
        $r.Reason | Should -Be 'minimum'
        @(Get-CapLive (Get-CapDoc $root)).Count | Should -Be 3
    }

    It 'refuses an explicit 2 GiB Windows guest even where the share would hold more' {
        $root = New-CapAllocator -Linux 1 -Windows 1
        $r = Request-AapReservation -Root $root -Profile windows -MemGib 2 -MemOverheadMib 512 -CloneGib 150 -ScratchGib 40 -IoMbps 100
        $r.Reason | Should -Be 'minimum'
        $r.Detail | Should -BeLike '*2 GiB*'
        (Request-AapReservation -Root $root -Profile windows -Cpus 1 -MemOverheadMib 512 -CloneGib 150 -ScratchGib 40 -IoMbps 100).Reason | Should -Be 'minimum'
    }

    It 'admits a guest of exactly the minimum' {
        $root = New-CapAllocator -Linux 1 -Windows 1
        $r = Request-AapReservation -Root $root -Profile windows -Cpus 2 -MemGib 4 -MemOverheadMib 512 -CloneGib 150 -ScratchGib 40 -IoMbps 100
        $r.Ok | Should -BeTrue
        $r.Reservation.mem_gib | Should -Be 4
    }

    It 'lets a caller raise the minimum but never lower it' {
        $root = New-CapAllocator -Linux 1 -Windows 1
        $up = Request-AapReservation -Root $root -Profile windows -MemGib 6 -MinMemGib 8 -MemOverheadMib 512 -CloneGib 150 -ScratchGib 40 -IoMbps 100
        $up.Reason | Should -Be 'minimum'
        $up.Detail | Should -BeLike '*at least 2 CPUs and 8 GiB*'
        $down = Request-AapReservation -Root $root -Profile windows -MemGib 2 -MinMemGib 1 -MemOverheadMib 512 -CloneGib 150 -ScratchGib 40 -IoMbps 100
        $down.Reason | Should -Be 'minimum'
        (Request-AapReservation -Root $root -Profile windows -MinCpus 4 -Cpus 3 -MemOverheadMib 512 -CloneGib 150 -ScratchGib 40 -IoMbps 100).Reason | Should -Be 'minimum'
        (Request-AapReservation -Root $root -Profile windows -MinMemGib 0 -MemOverheadMib 512 -CloneGib 150 -ScratchGib 40 -IoMbps 100).Ok | Should -BeTrue
    }

    It 'refuses a bad minimum' {
        $root = New-CapAllocator -Linux 1 -Windows 1
        (Request-AapReservation -Root $root -Profile windows -MinMemGib 'x' -MemOverheadMib 512 -CloneGib 150 -ScratchGib 40 -IoMbps 100).Reason | Should -Be 'bad_request'
    }

    It 'applies the Linux family minimum to a Linux VM and none to a legacy slot' {
        $root = New-CapAllocator -Linux 1 -Windows 1
        [void](Set-AapProfileCounts -Root $root -Linux 1 -Windows 1 -LinuxBackend hyperv-vm -LinuxGeneration $script:LinVmGen)
        (Request-AapReservation -Root $root -Profile linux -ImageGeneration $script:LinVmGen -MemGib 1 -MemOverheadMib 512 -CloneGib 55 -ScratchGib 10 -IoMbps 100).Reason | Should -Be 'minimum'
        (Request-AapReservation -Root $root -Profile linux -ImageGeneration $script:LinVmGen -MemOverheadMib 512 -CloneGib 55 -ScratchGib 10 -IoMbps 100).Ok | Should -BeTrue
        $legacy = New-CapAllocator -Linux 1 -Windows 0
        (Request-AapReservation -Root $legacy -Profile linux -ImageGeneration 'legacy-manager-2' -Cpus 1 -MemGib 1).Ok | Should -BeTrue
    }

    It 'refuses a VM generation with no recorded minimum (fail closed)' {
        $root = New-CapAllocator -Linux 1 -Windows 1
        [void](Set-AapProfileCounts -Root $root -Linux 1 -Windows 1 -WindowsGeneration 'win99-unknown-x64/20261007.264.1-aap.1')
        $r = Request-AapReservation -Root $root -Profile windows -MemOverheadMib 512 -CloneGib 150 -ScratchGib 40 -IoMbps 100
        $r.Reason | Should -Be 'minimum'
        $r.Detail | Should -BeLike '*no minimum*'
    }

    It 'shows the active generation minimums per profile in the state' {
        $root = New-CapAllocator -Linux 1 -Windows 1
        $s = Get-AapAllocatorState -Root $root
        $s.Profiles.windows.MinCpus | Should -Be 2
        $s.Profiles.windows.MinMemGib | Should -Be 4
        $s.Profiles.linux.MinCpus | Should -BeNullOrEmpty
    }

    It 'writes the minimums into the allocator log line of the reservation' {
        $root = New-CapAllocator -Linux 1 -Windows 1
        [void](Request-AapReservation -Root $root -Profile windows -MemOverheadMib 512 -CloneGib 150 -ScratchGib 40 -IoMbps 100)
        (Get-Content -LiteralPath (Join-Path $root 'allocator.log') -Raw) | Should -BeLike '*min_cpus=2 min_mem=4*'
    }
}
