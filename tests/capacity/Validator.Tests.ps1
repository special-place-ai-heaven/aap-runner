# Test-AapAllocatorState against the reference validator, parity/contracts/validate.py: every
# allocator fixture and a set of single-fault mutations, judged by both on the same bytes. The
# verdict and the exact message must agree. Pester 5, Windows PowerShell 5.1 and PowerShell 7.5+.

BeforeDiscovery {
    $fx = Join-Path $PSScriptRoot '..\..\parity\contracts\fixtures\allocator'
    $script:ValidCases = @(Get-ChildItem -LiteralPath (Join-Path $fx 'valid') -Filter *.json | ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } })
    $script:InvalidCases = @(Get-ChildItem -LiteralPath (Join-Path $fx 'invalid') -Filter *.json | ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } })
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'Fixture.ps1')
    Import-Module $script:CapModule -Force
}

Describe 'the allocator contract fixtures' {
    BeforeAll {
        $script:Ref = @{}
        $script:Extracted = @{}
        $files = @()
        foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $script:FixtureDir 'valid') -Filter *.json)) { $files += $f.FullName }
        foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $script:FixtureDir 'invalid') -Filter *.json)) {
            $out = Join-Path $TestDrive "instance-$($f.Name)"
            $expect = Export-CapInstance $f.FullName $out
            $script:Extracted[$f.Name] = @{ Path = $out; Expect = $expect }
            $files += $out
        }
        $script:Ref = Invoke-CapReference $files
    }

    It 'has the fixtures the contract lists (8 valid, 25 invalid)' {
        $ValidCases.Count | Should -Be 8
        $InvalidCases.Count | Should -Be 25
    }

    It 'the reference validator passes on its own fixtures' {
        $ErrorActionPreference = 'Continue'
        $null = & python -B -I $script:Validator 2>&1
        $LASTEXITCODE | Should -Be 0
    }

    It 'the schema next to the module is a byte copy of the contract schema' {
        $a = [IO.File]::ReadAllBytes((Join-Path $script:RepoRoot 'parity\contracts\allocator.schema.json'))
        $b = [IO.File]::ReadAllBytes((Join-Path $script:RepoRoot 'supervisor\capacity\allocator.schema.json'))
        $b.Length | Should -Be $a.Length
        for ($i = 0; $i -lt $a.Length; $i++) { if ($b[$i] -ne $a[$i]) { throw "the schema copy differs at byte $i" } }
    }

    It 'valid/<Name>: both validators accept it' -ForEach $ValidCases {
        $script:Ref[$Path].Ok | Should -BeTrue
        $mine = Test-AapAllocatorState -Path $Path
        $mine.Error | Should -BeNullOrEmpty
        $mine.Valid | Should -BeTrue
    }

    It 'invalid/<Name>: both reject it with the same message, which names the expected error' -ForEach $InvalidCases {
        $x = $script:Extracted[$Name]
        $ref = $script:Ref[$x.Path]
        $ref.Ok | Should -BeFalse
        $mine = Test-AapAllocatorState -Path $x.Path
        $mine.Valid | Should -BeFalse
        $mine.Error | Should -BeExactly $ref.Message
        $mine.Error | Should -BeLike "*$($x.Expect)*"
    }
}

Describe 'single-fault mutations agree with the reference validator' {
    BeforeAll {
        $base = [IO.File]::ReadAllText((Join-Path $script:FixtureDir 'valid\owner-example-2win-3lin-30-60-10.json'))
        $emoji = [char]::ConvertFromUtf32(0x1F600)
        $quarantine = { param($d, $reason) $r = $d.reservations[3]; $r.state = 'quarantined'; $r.quarantine_kind = 'heartbeat'; $r.quarantine_reason = $reason }
        $edits = [ordered]@{
            'schema 1'                     = { param($d) $d.schema = 1 }
            'schema true'                  = { param($d) $d.schema = $true }
            'revision negative'            = { param($d) $d.revision = -1 }
            'revision fractional'          = { param($d) $d.revision = 1.5 }
            'revision too big'             = { param($d) $d.revision = 2147483648 }
            'written_at with an offset'    = { param($d) $d.written_at = '2026-10-19T18:00:00+00:00' }
            'written_at with fractions'    = { param($d) $d.written_at = '2026-10-19T18:00:00.5Z' }
            'max_slots 6'                  = { param($d) $d.max_slots = 6 }
            'extra top-level property'     = { param($d) $d | Add-Member -NotePropertyName extra -NotePropertyValue 1 }
            'host missing'                 = { param($d) $d.PSObject.Properties.Remove('host') }
            'host cpu 0'                   = { param($d) $d.host.cpu_cores = 0 }
            'host extra property'          = { param($d) $d.host | Add-Member -NotePropertyName gpu -NotePropertyValue 1 }
            'host measured_at missing'     = { param($d) $d.host.PSObject.Properties.Remove('measured_at') }
            'reserve 95'                   = { param($d) $d.host_reserve_percent = 95 }
            'reserve as a string'          = { param($d) $d.host_reserve_percent = '10' }
            'share_mode unknown'           = { param($d) $d.share_mode = 'uneven' }
            'linux count 6'                = { param($d) $d.profiles.linux.count = 6 }
            'linux backend unknown'        = { param($d) $d.profiles.linux.backend = 'docker' }
            'windows generation too long'  = { param($d) $d.profiles.windows.active_generation = 'x' * 81 }
            'windows on the legacy backend' = { param($d) $d.profiles.windows.backend = 'wsl-legacy' }
            'slot_generations 4 items'     = { param($d) $d.slot_generations = @(7, 7, 7, 3) }
            'slot_generations string item' = { param($d) $d.slot_generations = @('7', 7, 7, 3, 2) }
            'eleven reservations'          = { param($d) $d.reservations = @(@($d.reservations) * 3 | Select-Object -First 11) }
            'reservation id pattern'       = { param($d) $d.reservations[0].reservation_id = 'r-XYZ' }
            'slot 0'                       = { param($d) $d.reservations[0].slot = 0 }
            'profile unknown'              = { param($d) $d.reservations[0].profile = 'macos' }
            'state unknown'                = { param($d) $d.reservations[0].state = 'running' }
            'image generation pattern'     = { param($d) $d.reservations[3].image_generation = 'win25/1' }
            'heartbeat_at a number'        = { param($d) $d.reservations[0].heartbeat_at = 5 }
            'vm_id upper case'             = { param($d) $d.reservations[3].vm_id = $d.reservations[3].vm_id.ToUpperInvariant() }
            'runner_name with a space'     = { param($d) $d.reservations[0].runner_name = 'aap-crrr-bad name' }
            'quarantine kind unknown'      = { param($d) $d.reservations[0].quarantine_kind = 'other' }
            'quarantine reason 201 chars'  = { param($d) & $quarantine $d ('x' * 201) }
            'quarantine reason 200 astral' = { param($d) & $quarantine $d ($emoji * 200) }
            'quarantine reason 201 astral' = { param($d) & $quarantine $d ($emoji * 201) }
            'quarantine without reason'    = { param($d) & $quarantine $d $null }
            'proof shape on a live slot'   = { param($d) $d.reservations[0].teardown_proof = [pscustomobject]@{ kind = 'vm' } }
            'reservation extra property'   = { param($d) $d.reservations[0] | Add-Member -NotePropertyName extra -NotePropertyValue 1 }
            'cpus a boolean'               = { param($d) $d.reservations[0].cpus = $true }
            'overhead above maximum'       = { param($d) $d.reservations[3].mem_overhead_mib = 70000 }
            'token in a reason'            = { param($d) & $quarantine $d ('token ghp_' + ('a' * 36)) }
            'legacy_adopted a string'      = { param($d) $d.legacy_adopted = 'yes' }
            'duplicate reservation id'     = { param($d) $d.reservations[1].reservation_id = $d.reservations[0].reservation_id }
            'even mode with shares'        = { param($d) $d.share_mode = 'even' }
            'per_profile share missing'    = { param($d) $d.profiles.windows.share_percent = $null }
            'zero count with a share'      = { param($d) $d.profiles.windows.count = 0 }
            'stale lease generation'       = { param($d) $d.reservations[0].lease_generation = 6; $d.reservations[0].idempotency_key = 'r-00000000000000a1/6' }
            'legacy with a vm_id'          = { param($d) $d.reservations[1].vm_id = '6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4c' }
            'busy VM without vm_id'        = { param($d) $d.reservations[3].vm_id = $null }
            'idempotency key wrong'        = { param($d) $d.reservations[1].idempotency_key = 'r-00000000000000a2/8' }
            'IO budget exceeded'           = { param($d) $d.host.io_mbps = 150 }
            'disk budget exceeded'         = { param($d) $d.host.volumes[0].available_gib = 129 }
            'volumes missing'              = { param($d) $d.host.PSObject.Properties.Remove('volumes') }
            'disk_gib of schema 1'         = { param($d) $d.host | Add-Member -NotePropertyName disk_gib -NotePropertyValue 2000 }
            'tier listed twice'            = { param($d) $d.host.volumes[0].tiers = @('base', 'base', 'clone', 'scratch') }
            'tier unknown'                 = { param($d) $d.host.volumes[0].tiers = @('base', 'clone', 'scratch', 'cache') }
            'no tiers'                     = { param($d) $d.host.volumes[0].tiers = @() }
            'volume guid upper case'       = { param($d) $d.host.volumes[0].volume_guid = $d.host.volumes[0].volume_guid.ToUpperInvariant() + 'E' }
            'floor 9'                      = { param($d) $d.host.volumes[0].floor_gib = 9 }
            'five volumes'                 = { param($d) $v = $d.host.volumes[0]; $d.host.volumes = @($v, $v, $v, $v, $v) }
            'volume held over budget'      = { param($d) $d.host.volumes[0].held_gib = 1931 }
            'VM without storage'           = { param($d) $d.host.volumes = @() }
            'legacy reserves clone disk'   = { param($d) $d.reservations[0].clone_gib = 1 }
            'legacy reserves scratch disk' = { param($d) $d.reservations[0].scratch_gib = 1 }
            'VM without clone disk'        = { param($d) $d.reservations[3].clone_gib = 0 }
            'id with a final newline'      = { param($d) $d.reservations[0].reservation_id += "`n" }
            'pool exceeded by control VM'  = { param($d) $d.host.control_distro_mem_gib = 15 }
            'windows over its count'       = { param($d) $d.profiles.windows.count = 1; $d.profiles.linux.count = 4 }
        }
        $texts = [ordered]@{
            'max_slots 5.0 (accepted by both)' = { param($t) $t -creplace '"max_slots": 5', '"max_slots": 5.0' }
            'revision 42.0'                    = { param($t) $t -creplace '"revision": 42', '"revision": 42.0' }
            'schema key in another case'       = { param($t) $t -creplace '"schema": 2', '"Schema": 2' }
            'a top-level array'                = { param($t) '[]' }
            'a top-level string'               = { param($t) '"allocator"' }
        }
        $script:Mutations = @()
        $i = 0
        foreach ($name in $edits.Keys) {
            $d = ConvertFrom-CapJson $base
            & $edits[$name] $d
            $path = Join-Path $TestDrive ('mutation-{0:d2}.json' -f $i++)
            Write-CapJson $path $d
            $script:Mutations += @{ Name = $name; Path = $path }
        }
        foreach ($name in $texts.Keys) {
            $path = Join-Path $TestDrive ('mutation-{0:d2}.json' -f $i++)
            Write-CapText $path (& $texts[$name] $base)
            $script:Mutations += @{ Name = $name; Path = $path }
        }
        $script:MutRef = Invoke-CapReference @($script:Mutations | ForEach-Object { $_.Path })
    }

    It 'every mutation gets the reference verdict and message' {
        $mismatch = @()
        $rejected = 0
        foreach ($m in $script:Mutations) {
            $ref = $script:MutRef[$m.Path]
            $mine = Test-AapAllocatorState -Path $m.Path
            if (-not $ref.Ok) { $rejected++ }
            if ($mine.Valid -ne $ref.Ok -or ((-not $ref.Ok) -and $mine.Error -cne $ref.Message -and -not ($m.Name -like 'a top-level*'))) {
                $mismatch += "$($m.Name): reference [$($ref.Ok)] $($ref.Message) | mine [$($mine.Valid)] $($mine.Error)"
            }
        }
        $mismatch | Should -BeNullOrEmpty
        $script:Mutations.Count | Should -Be 73
        $rejected | Should -Be 71
    }
}

Describe 'VM and runner name derivation' {
    It 'is aap-(w|l)-slot-lease generation-first 8 hex of the reservation id' {
        Get-AapVmName -Profile windows -Slot 4 -LeaseGeneration 3 -ReservationId 'r-1a2b3c4d000000b1' | Should -BeExactly 'aap-w-4-3-1a2b3c4d'
        Get-AapVmName -Profile linux -Slot 1 -LeaseGeneration 12 -ReservationId 'r-00000000000000a1' | Should -BeExactly 'aap-l-1-12-00000000'
    }

    It 'refuses a malformed reservation id or slot' {
        { Get-AapVmName -Profile windows -Slot 6 -LeaseGeneration 1 -ReservationId 'r-1a2b3c4d000000b1' } | Should -Throw
        { Get-AapVmName -Profile windows -Slot 1 -LeaseGeneration 1 -ReservationId 'r-1A2B3C4D000000B1' } | Should -Throw
    }
}
