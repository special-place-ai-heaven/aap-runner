# Revision-2 admission, offline identity writer and atomic seed publication; simulated providers only.
BeforeAll {
    . (Join-Path $PSScriptRoot 'LinBackendTestHelpers.ps1')
    Import-Module $script:CapModule -Force
    Import-Module $script:BackendModule -Force
    $script:IdentityAdmission = @{ CatalogGuestRevision = 2; ApprovedGuestRevision = 2 }
    function New-IdentitySeedArgs {
        $prefix = '192' + '.168.241.'
        @{ VmName = 'aap-l-1-7-1a2b3c4d'; InstanceId = 'aap-x'
            ReservationId = 'r-1a2b3c4d000000b1'; LeaseGeneration = 7
            PublicKey = ('ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI' + ('A' * 43))
            Network = [ordered]@{ schema = 1; kind = 'host_network_attach'; vm_id = '6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b'; vm_name = 'aap-l-1-7-1a2b3c4d'; profile = 'linux'
                subnet = ($prefix + '0/24'); gateway = ($prefix + '1'); address = ($prefix + '2'); resolvers = @(('1.1.' + '1.1'), ('8.8.' + '8.8')); endpoints = @() } }
    }
    function Read-IdentityRecord([string]$UserData) {
        $m = [regex]::Matches($UserData, '(?m)^# aap-guest-identity: (.+)$')
        $m.Count | Should -Be 1
        $m[0].Groups[1].Value
    }
    function Remove-CreateDone($w, $r) {
        $path = Join-Path $w.Journal "$($r.reservation_id).jsonl"
        [IO.File]::WriteAllText($path, ((@(Get-LinJournalLines $w $r.reservation_id | Where-Object { $_ -notlike '*"phase":"done"*' }) -join "`n") + "`n"))
    }
}

Describe 'revision-2 admission' {
    It 'refuses missing, unsupported, mismatched or non-integer revisions before any create intent or provider effect' -Tag 'guest-revision' {
        foreach ($revisions in @(@{}, @{ CatalogGuestRevision = 2 }, @{ ApprovedGuestRevision = 2 },
                @{ CatalogGuestRevision = 1; ApprovedGuestRevision = 1 }, @{ CatalogGuestRevision = 0; ApprovedGuestRevision = 0 },
                @{ CatalogGuestRevision = 3; ApprovedGuestRevision = 3 }, @{ CatalogGuestRevision = 2; ApprovedGuestRevision = 1 },
                @{ CatalogGuestRevision = '2'; ApprovedGuestRevision = 2 }, @{ CatalogGuestRevision = 2; ApprovedGuestRevision = '2' },
                @{ CatalogGuestRevision = 2.0; ApprovedGuestRevision = 2 }, @{ CatalogGuestRevision = 2; ApprovedGuestRevision = $true })) {
            $w = New-LinWorld; $B = New-LinBackend $w; $r = New-LinReservation $w
            { Invoke-AapLinStep -Backend $B -Reservation $r -BaseSha256 $w.BaseSha @revisions } | Should -Throw '*AAP_GuestRevision:*'
            @(Get-LinJournal $w $r.reservation_id).Count | Should -Be 0
            @(Get-LinCalls $w).Count | Should -Be 0
            @(Get-ChildItem -LiteralPath $w.Clones).Count | Should -Be 0
        }
    }
    It 'admits only matching integer revision 2 including a recovered create' -Tag 'guest-revision' {
        $w = New-LinWorld; $B = New-LinBackend $w; $r = New-LinReservation $w
        (Invoke-AapLinStep -Backend $B -Reservation $r -BaseSha256 $w.BaseSha @script:IdentityAdmission).Action | Should -Be 'created'
        Remove-CreateDone $w $r
        $n = @(Get-LinJournal $w $r.reservation_id).Count
        { Invoke-AapLinStep -Backend $B -Reservation $r -BaseSha256 $w.BaseSha -CatalogGuestRevision 1 -ApprovedGuestRevision 1 } | Should -Throw '*AAP_GuestRevision:*'
        @(Get-LinJournal $w $r.reservation_id).Count | Should -Be $n
        (Invoke-AapLinStep -Backend $B -Reservation $r -BaseSha256 $w.BaseSha @script:IdentityAdmission).Action | Should -Be 'created'
    }
}

Describe 'canonical identity in NoCloud user-data' {
    It 'writes the golden ignored YAML comment, closed canonical JSON, no host data or secret' -Tag 'seed-identity' {
        $seedArgs = New-IdentitySeedArgs
        $seed = New-AapLinSeed @seedArgs
        [string]$seed['user-data'] | Should -BeExactly ([IO.File]::ReadAllText((Join-Path $script:Repo 'tests/guests/linux/fixtures/seed-user-data.golden')))
        $record = Read-IdentityRecord $seed['user-data']
        $record | Should -BeExactly '{"schema":2,"kind":"guest_identity","vm_id":"6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b","reservation_id":"r-1a2b3c4d000000b1","lease_generation":7,"scratch":null}'
        $w = New-LinWorld
        Invoke-LinValidator $w 'guest-transport' @($record) | Should -BeNullOrEmpty
        $record | Should -Not -Match 'hostname|host_path|runner|ssh|token|password|private|[A-Z]:\\'
    }
    It 'refuses identity values outside the Linux schema before writing YAML' -Tag 'seed-identity' {
        foreach ($change in @(@{ ReservationId = $null }, @{ ReservationId = 'r-1A2b3c4d000000b1' }, @{ ReservationId = "r-1a2b3c4d000000b1`n# injected" },
                @{ LeaseGeneration = $null }, @{ LeaseGeneration = 0 }, @{ LeaseGeneration = (999999999 + 1) }, @{ LeaseGeneration = '7' }, @{ LeaseGeneration = 7.0 }, @{ LeaseGeneration = $true })) {
            $seedArgs = New-IdentitySeedArgs
            foreach ($k in $change.Keys) { $seedArgs[$k] = $change[$k] }
            { New-AapLinSeed @seedArgs } | Should -Throw '*AAP_SeedInvalid: identity record:*'
        }
        $seedArgs = New-IdentitySeedArgs; $seedArgs.Network.vm_id = $seedArgs.Network.vm_id.ToUpperInvariant()
        { New-AapLinSeed @seedArgs } | Should -Throw '*AAP_SeedInvalid:*'
    }
    It 'create writes its journaled VM and reservation, keeps KVP host-key-only, and retry replaces the seed whole' -Tag 'seed-identity', 'seed-atomic' {
        $w = New-LinWorld; $B = New-LinBackend $w; $r = New-LinReservation $w
        (Invoke-AapLinStep -Backend $B -Reservation $r -BaseSha256 $w.BaseSha @script:IdentityAdmission).Action | Should -Be 'created'
        $seedPath = Join-Path $w.Clones "$($r.reservation_id)\seed.iso"
        $record = Read-IdentityRecord (Read-LinSeed $seedPath).files.'user-data'
        $id = ConvertFrom-LinJson $record
        $vm = @(Get-LinVms $w)[0]
        $id.vm_id | Should -BeExactly $vm.Id
        $id.reservation_id | Should -BeExactly $r.reservation_id
        $id.lease_generation | Should -Be $r.lease_generation
        $id.scratch | Should -BeNullOrEmpty
        $vm.KeyValuePairExchange | Should -BeTrue
        @($B.Provider.Keys | Where-Object { $_ -match 'Set.*Kvp|Write.*Kvp|ExchangeItem' }).Count | Should -Be 0
        Remove-CreateDone $w $r
        [IO.File]::WriteAllText($seedPath + '.tmp', 'interrupted ISO')
        [void][IO.Directory]::CreateDirectory($seedPath + '.tmp.files')
        [IO.File]::WriteAllText($seedPath + '.tmp.files/user-data', 'interrupted user-data')
        (Invoke-AapLinStep -Backend (New-LinBackend $w) -Reservation $r -BaseSha256 $w.BaseSha @script:IdentityAdmission).Action | Should -Be 'created'
        (Read-IdentityRecord (Read-LinSeed $seedPath).files.'user-data') | Should -BeExactly $record
        Test-Path -LiteralPath ($seedPath + '.tmp') | Should -BeFalse
        Test-Path -LiteralPath ($seedPath + '.tmp.files') | Should -BeFalse
        @(Get-LinCalls $w 'StartVm *').Count | Should -Be 0
    }
    It 'does not replace a published seed with a failed or short new ISO' -Tag 'seed-atomic' {
        foreach ($knob in @(@{ SeedFails = $true }, @{ SeedLost = 'short' })) {
            $w = New-LinWorld; $B = New-LinBackend $w; $r = New-LinReservation $w
            [void](Invoke-AapLinStep -Backend $B -Reservation $r -BaseSha256 $w.BaseSha @script:IdentityAdmission)
            $path = Join-Path $w.Clones "$($r.reservation_id)\seed.iso"
            $old = [IO.File]::ReadAllText($path)
            # Directly exercise create so teardown does not delete the evidence after the injected failure.
            $j = Invoke-LinInModule { param($B, $r) Read-AapLinJournal $B $r } @($B, $r)
            Set-LinKnob $w $knob
            { Invoke-LinInModule { param($B, $r, $sha, $j) Invoke-AapLinCreate $B $r $sha $j } @($B, $r, $w.BaseSha, $j) } | Should -Throw
            [IO.File]::ReadAllText($path) | Should -BeExactly $old
        }
    }
    It 'never rewrites identity in a VM that has booted' -Tag 'seed-never-booted' {
        $w = New-LinWorld; $B = New-LinBackend $w; $r = New-LinReservation $w
        [void](Invoke-AapLinStep -Backend $B -Reservation $r -BaseSha256 $w.BaseSha @script:IdentityAdmission)
        $vms = @(Get-LinVms $w); $vms[0].State = 'Running'; $vms[0].Booted = $true; Save-LinVms $w $vms
        $j = Invoke-LinInModule { param($B, $r) Read-AapLinJournal $B $r } @($B, $r)
        { Invoke-LinInModule { param($B, $r, $sha, $j) Invoke-AapLinCreate $B $r $sha $j } @($B, $r, $w.BaseSha, $j) } | Should -Throw '*AAP_VmMismatch:*'
        @(Get-LinCalls $w 'NewSeedImage *').Count | Should -Be 1
        @(Get-LinCalls $w 'NewKeyPair *').Count | Should -Be 1
    }
}
