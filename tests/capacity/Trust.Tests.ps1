# The capacity folder must pass install-supervisor.ps1's owner, ACL and reparse checks before
# anything is read or written: junctions (on the folder, above it or as a file), a folder anyone
# can write (granted with icacls, never Set-Acl), inherited write, odd paths. Relaxed mode (tests
# only) trusts the current user and skips ancestor ACLs, but keeps every other check, warns and
# records it. Pester 5, Windows PowerShell 5.1 and PowerShell 7.5+.

BeforeAll {
    . (Join-Path $PSScriptRoot 'Fixture.ps1')
    Import-Module $script:CapModule -Force
    $PSDefaultParameterValues['*-Aap*:RelaxedTrustForTests'] = $true
    $PSDefaultParameterValues['*-Aap*:WarningAction'] = 'SilentlyContinue'
    $script:Now = [DateTime]::UtcNow
    function New-CapJunction([string]$Target) {
        $link = Join-Path $TestDrive ('link-' + [guid]::NewGuid().ToString('n').Substring(0, 8))
        [void](New-Item -ItemType Junction -Path $link -Target $Target)
        $link
    }
    function Invoke-CapIcacls([string[]]$Arguments) {
        $out = & icacls.exe @Arguments 2>&1
        if ($LASTEXITCODE -ne 0) { throw "icacls $($Arguments -join ' '): $out" }
    }
}

AfterAll {
    $PSDefaultParameterValues.Remove('*-Aap*:RelaxedTrustForTests')
    $PSDefaultParameterValues.Remove('*-Aap*:WarningAction')
}

Describe 'capacity folder trust' {
    It 'refuses a junction as the capacity folder and writes nothing through it' {
        $target = New-CapRoot
        $link = New-CapJunction $target
        $r = Initialize-AapAllocator -Root $link -HostInfo (New-CapHostInfo)
        $r.Status | Should -Be 'error'
        $r.Reason | Should -Be 'untrusted_folder'
        $r.Detail | Should -BeLike "*reparse point $link*"
        @(Get-ChildItem -LiteralPath $target -Force).Count | Should -Be 0
    }

    It 'refuses a capacity folder below a junction' {
        $real = New-CapRoot
        $root = Join-Path (New-CapJunction $real) 'capacity'
        $r = Initialize-AapAllocator -Root $root -HostInfo (New-CapHostInfo)
        $r.Reason | Should -Be 'untrusted_folder'
        $r.Detail | Should -BeLike '*reparse point*'
        @(Get-ChildItem -LiteralPath $real -Force).Count | Should -Be 0
    }

    It 'refuses a folder Everyone may write (icacls), for every operation' {
        $root = New-CapAllocator -Linux 1 -Windows 1
        $rev = (Get-CapDoc $root).revision
        Invoke-CapIcacls @($root, '/grant', '*S-1-1-0:(OI)(CI)M')
        foreach ($r in @(
                (Request-AapReservation -Root $root -Profile linux -ImageGeneration 'legacy-manager-2'),
                (Get-AapAllocatorState -Root $root),
                (Set-AapProfileCounts -Root $root -Linux 2 -Windows 1),
                (Invoke-AapReconcile -Root $root))) {
            $r.Status | Should -Be 'error'
            $r.Reason | Should -Be 'untrusted_folder'
            $r.Detail | Should -BeLike '*S-1-1-0*'
        }
        Invoke-CapIcacls @($root, '/remove:g', '*S-1-1-0')
        (Get-CapDoc $root).revision | Should -Be $rev
        (Request-AapReservation -Root $root -Profile linux -ImageGeneration 'legacy-manager-2').Ok | Should -BeTrue
    }

    It 'refuses write that only the files would inherit (an inherit-only ACE)' {
        $root = New-CapAllocator -Linux 1 -Windows 1
        Invoke-CapIcacls @($root, '/grant', '*S-1-5-11:(OI)(IO)W')
        $r = Get-AapAllocatorState -Root $root
        $r.Reason | Should -Be 'untrusted_folder'
        $r.Detail | Should -BeLike '*S-1-5-11*'
    }

    It 'refuses a folder that inherits Authenticated Users modify, as any folder under this scratch tree does' {
        $root = Join-Path $TestDrive ('inherit-' + [guid]::NewGuid().ToString('n').Substring(0, 8))
        [void](New-Item -ItemType Directory -Path $root)
        $r = Initialize-AapAllocator -Root $root -HostInfo (New-CapHostInfo)
        $r.Reason | Should -Be 'untrusted_folder'
        Test-Path -LiteralPath (Join-Path $root 'allocator.json') | Should -BeFalse
    }

    It 'refuses a junction planted where allocator.json or the lock file belongs' {
        foreach ($name in @('allocator.json', 'allocator.lock')) {
            $root = New-CapAllocator -Linux 1 -Windows 1
            $elsewhere = New-CapRoot
            $path = Join-Path $root $name
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
            [void](New-Item -ItemType Junction -Path $path -Target $elsewhere)
            $r = Request-AapReservation -Root $root -Profile linux -ImageGeneration 'legacy-manager-2'
            $r.Reason | Should -Be 'untrusted_folder'
            $r.Detail | Should -BeLike "*reparse point $path*"
            @(Get-ChildItem -LiteralPath $elsewhere -Force).Count | Should -Be 0
        }
    }

    It 'refuses relative, UNC, unnormalized and trailing-separator paths' {
        $base = New-CapRoot
        foreach ($p in @('capacity', '\\localhost\c$\capacity', (Join-Path $base 'x\..\capacity'), "$base\", ($base -replace '\\', '/'))) {
            $r = Initialize-AapAllocator -Root $p -HostInfo (New-CapHostInfo)
            $r.Reason | Should -Be 'untrusted_folder' -Because $p
        }
        @(Get-ChildItem -LiteralPath $base -Force).Count | Should -Be 0
    }

    It 'creates a missing capacity folder under a trusted parent, then checks it' {
        $root = Join-Path (New-CapRoot) 'capacity'
        (Initialize-AapAllocator -Root $root -HostInfo (New-CapHostInfo)).Ok | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $root 'allocator.json') | Should -BeTrue
    }

    It 'strict mode refuses this user-owned test folder; relaxed mode warns once and records it' {
        $root = New-CapRoot
        $strict = Initialize-AapAllocator -Root $root -HostInfo (New-CapHostInfo) -RelaxedTrustForTests:$false
        $strict.Reason | Should -Be 'untrusted_folder'
        $strict.TrustRelaxed | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $root 'allocator.json') | Should -BeFalse
        $warnings = @()
        $relaxed = Initialize-AapAllocator -Root $root -HostInfo (New-CapHostInfo) -WarningVariable warnings
        $relaxed.Ok | Should -BeTrue
        $relaxed.TrustRelaxed | Should -BeTrue
        ($warnings -join ' ') | Should -BeLike '*RELAXED FOR TESTS*'
        [IO.File]::ReadAllText((Join-Path $root 'allocator.log')) | Should -BeLike '*trust checks relaxed for tests*'
        (Get-AapAllocatorState -Root $root -RelaxedTrustForTests:$false).Reason | Should -Be 'untrusted_folder'
    }
}
