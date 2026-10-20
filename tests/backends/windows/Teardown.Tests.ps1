# destroy (backend-lifecycle.md): release at every teardown, VM and folders through reparse-checked paths, absence
# observed before the slot is freed. Release failure modes (broker INTEGRATION.md, rules for the callers), a VM or a
# folder that will not go, links planted in a clone folder, and no slot reuse before the teardown proof. Pester 5,
# Windows PowerShell 5.1 and PowerShell 7.5+.

BeforeAll {
    . (Join-Path $PSScriptRoot 'WinBackendTestHelpers.ps1')
    Import-Module $script:CapModule -Force
    Import-Module $script:BackendModule -Force

    # A world whose one reservation runs a job that has just ended (runner absent), so the next step tears it down.
    function New-WinEndedJob([hashtable]$Knobs = @{}) {
        $w = New-WinWorld
        $B = New-WinBackend $w
        $r = New-WinReservation $w
        [void](Invoke-WinSteps $B $w $r.reservation_id -Max 5 -Until { param($x) $x.state -eq 'ready' })
        [void](Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $r.reservation_id))   # running
        Set-WinKnob $w (@{ RunnerStatus = 'absent' } + $Knobs)
        [pscustomobject]@{ W = $w; B = $B; Id = $r.reservation_id; Gen = $r.lease_generation }
    }
    function Step-Win($x) { $w = $x.W; Invoke-AapWinStep -Backend $x.B -Reservation (Get-WinRes $x.W $x.Id) }
}

Describe 'release at teardown' {
    It 'retry, unavailable and clock_skew keep the slot deleting with the VM already gone; the next release frees it' -ForEach @('retry', 'unavailable', 'clock_skew') {
        $x = New-WinEndedJob @{ ReleaseOutcome = $_ }
        $w = $x.W   # the fakes find their world as $w
        $s = Step-Win $x
        $s.Action | Should -Be 'waiting'
        $s.Code | Should -Be 'release_pending'
        (Get-WinRes $x.W $x.Id).state | Should -Be 'deleting'
        @(Get-WinVms $x.W).Count | Should -Be 0
        (Step-Win $x).Code | Should -Be 'retry_later'   # asked again at most once a minute
        # The throttle reads the journal's last failed destroy; a minute later the release goes through.
        Set-WinKnob $x.W @{ ReleaseOutcome = 'normal' }
        $x.B.Now = { [DateTime]::UtcNow.AddSeconds(60) }
        [void](Step-Win $x)
        $res = Get-WinRes $x.W $x.Id
        $res.state | Should -Be 'reconciled'
        $res.teardown_proof.runner_deregistered | Should -BeTrue
        @(Get-WinCalls $x.W 'RemoveVm *').Count | Should -Be 1
    }

    It 'already_gone is the github-removed proof' {
        $x = New-WinEndedJob
        $w = $x.W   # the fakes find their world as $w
        $l = @(Get-WinLeases $x.W); $l[0].state = 'released'; Save-WinLeases $x.W $l
        [void](Step-Win $x)
        (Get-WinRes $x.W $x.Id).teardown_proof.runner_deregistered | Should -Be 'github-removed'
    }

    It 'not_found for a lease this process saw issued is uncertain: teardown_failed, capacity held' -Tag 'release-uncertain' {
        $x = New-WinEndedJob @{ ReleaseOutcome = 'not_found' }
        $w = $x.W   # the fakes find their world as $w
        $s = Step-Win $x
        $s.Code | Should -Be 'release_uncertain'
        $res = Get-WinRes $x.W $x.Id
        $res.state | Should -Be 'quarantined'
        $res.quarantine_kind | Should -Be 'teardown_failed'
        $res.cleanup_uncertain | Should -BeTrue
        $q = Request-AapReservation -Root $x.W.Cap -Profile windows -MemOverheadMib 512 -CloneGib 60 -ScratchGib 40 -IoMbps 100 -RelaxedTrustForTests
        $q.Ok | Should -BeFalse -Because 'the held slot keeps its resources until the teardown is observed'
        $q.Status | Should -Be 'refused'
    }

    It 'not_found for a lease call whose answer died with the supervisor waits 15 minutes, then is never registered' -Tag 'lease-window', 'release-uncertain' {
        $w = New-WinWorld
        $B = New-WinBackend $w
        $r = New-WinReservation $w
        $rid = $r.reservation_id
        [void](Invoke-WinSteps $B $w $rid -Max 5 -Until { param($x) $x.state -eq 'ready' })
        # The lease call never reached the broker (crash after the run_one intent): journal it as such.
        $line = @(Get-WinJournalLines $w $rid | Where-Object { $_ -like '*"op":"ready"*"phase":"done"*' })[0]
        $intent = $line.Replace('"op":"ready"', '"op":"run_one"').Replace("/ready`"", "/run_one`"").Replace('"phase":"done"', '"phase":"intent"')
        $intent = [regex]::Replace($intent, '"result":\{[^}]*\}', '"result":null')
        [IO.File]::AppendAllText((Join-Path $w.Journal "$rid.jsonl"), $intent + "`n")
        Invoke-WinValidator $w 'backend-lifecycle' @($intent) | Should -BeNullOrEmpty
        $B2 = New-WinBackend $w   # a restarted supervisor: no credential, no memory of the lease outcome
        Set-WinKnob $w @{ ReleaseOutcome = 'not_found' }
        $s = Invoke-AapWinStep -Backend $B2 -Reservation (Get-WinRes $w $rid)
        $s.Code | Should -Be 'release_pending'
        (Get-WinRes $w $rid).state | Should -Be 'deleting'
        @(Get-WinVms $w).Count | Should -Be 0
        $B2.Now = { [DateTime]::UtcNow.AddMinutes(16) }
        $res = Get-WinRes $w $rid
        & (Get-Module AapCapacity) { function script:Get-AapUtcNow { [DateTime]::UtcNow.AddMinutes(16) } }
        try { $s = Invoke-AapWinStep -Backend $B2 -Reservation $res } finally { & (Get-Module AapCapacity) { function script:Get-AapUtcNow { [DateTime]::UtcNow } } }
        (Get-WinRes $w $rid).state | Should -Be 'reconciled'
        (Get-WinRes $w $rid).teardown_proof.runner_deregistered | Should -Be 'never_registered'
    }
}

Describe 'no slot reuse before the teardown is observed' {
    It 'a VM that will not go: three tries, teardown_failed, capacity held; freed once it is gone' -Tag 'observe-absent' {
        $x = New-WinEndedJob @{ RemoveVmFails = $true }
        $w = $x.W   # the fakes find their world as $w
        $s = Step-Win $x
        $s.Code | Should -Be 'teardown_failed'
        @(Get-WinCalls $x.W 'RemoveVm *').Count | Should -Be 3
        $res = Get-WinRes $x.W $x.Id
        $res.state | Should -Be 'quarantined'
        $res.quarantine_kind | Should -Be 'teardown_failed'
        @(Get-WinVms $x.W).Count | Should -Be 1
        $q = Request-AapReservation -Root $x.W.Cap -Profile windows -MemOverheadMib 512 -CloneGib 60 -ScratchGib 40 -IoMbps 100 -RelaxedTrustForTests
        $q.Ok | Should -BeFalse -Because 'the held slot keeps its resources until the teardown is observed'
        $q.Status | Should -Be 'refused'
        Set-WinKnob $x.W @{ RemoveVmFails = $false }
        $x.B.Now = { [DateTime]::UtcNow.AddSeconds(60) }
        [void](Step-Win $x)
        (Get-WinRes $x.W $x.Id).state | Should -Be 'reconciled'
        (Request-AapReservation -Root $x.W.Cap -Profile windows -MemOverheadMib 512 -CloneGib 60 -ScratchGib 40 -IoMbps 100 -RelaxedTrustForTests).Ok | Should -BeTrue
    }

    It 'a scratch folder that will not go, a network that will not detach, or a root on another volume holds the slot' -Tag 'observe-scratch', 'detach', 'gone-volume' {
        foreach ($case in @('scratch', 'detach', 'volume')) {
            $x = New-WinEndedJob
            $w = $x.W   # the fakes find their world as $w
            $h = $null
            if ($case -eq 'scratch') { $h = [IO.File]::Open((Join-Path $x.W.Scratch "$($x.Id)\held.bin"), 'Create', 'ReadWrite', 'None') }
            if ($case -eq 'detach') { Set-WinKnob $w @{ DetachFails = $true } }
            if ($case -eq 'volume') { Set-WinKnob $w @{ WrongVolume = 'scratch' } }
            try { $s = Step-Win $x } finally { if ($h) { $h.Dispose() } }
            $s.Code | Should -Be 'teardown_failed' -Because $case
            (Get-WinRes $x.W $x.Id).state | Should -Be 'quarantined'
            Set-WinKnob $w @{ DetachFails = $false; WrongVolume = '' }
            $x.B.Now = { [DateTime]::UtcNow.AddSeconds(60) }
            [void](Step-Win $x)
            (Get-WinRes $x.W $x.Id).state | Should -Be 'reconciled' -Because $case
        }
    }

    It 'a reservation folder that will not go holds the slot too' -Tag 'observe-absent' {
        $x = New-WinEndedJob
        $w = $x.W   # the fakes find their world as $w
        $f = Join-Path $x.W.Clones "$($x.Id)\held.bin"
        $h = [IO.File]::Open($f, [IO.FileMode]::Create, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try { $s = Step-Win $x } finally { $h.Dispose() }
        $s.Code | Should -Be 'teardown_failed'
        @(Get-WinVms $x.W).Count | Should -Be 0
        (Get-WinRes $x.W $x.Id).state | Should -Be 'quarantined'
        $x.B.Now = { [DateTime]::UtcNow.AddSeconds(60) }
        [void](Step-Win $x)
        (Get-WinRes $x.W $x.Id).state | Should -Be 'reconciled'
        Test-Path -LiteralPath (Join-Path $x.W.Clones $x.Id) | Should -BeFalse
    }

    It 'destroy is idempotent: a second destroy of a reconciled slot changes nothing and calls nothing' {
        $x = New-WinEndedJob
        $w = $x.W   # the fakes find their world as $w
        [void](Step-Win $x)
        $before = @(Get-WinCalls $x.W).Count
        $r = Get-WinRes $x.W $x.Id
        $j = Invoke-WinInModule { param($B, $r) Read-AapWinJournal $B $r } @($x.B, $r)
        $out = Invoke-WinInModule { param($B, $r, $j) Invoke-AapWinDestroy $B $r $j -Force } @($x.B, $r, $j)
        $out.Action | Should -Be 'destroyed'
        @(Get-WinCalls $x.W 'RemoveVm *').Count | Should -Be 1
        (Get-WinRes $x.W $x.Id).state | Should -Be 'reconciled'
    }
}

Describe 'links in a clone folder never redirect a delete' {
    It 'a junction inside the clone folder is removed as a link; its target survives' -Tag 'safe-delete' {
        $x = New-WinEndedJob
        $w = $x.W   # the fakes find their world as $w
        $outside = Join-Path $x.W.Root 'precious'
        [void][IO.Directory]::CreateDirectory($outside)
        [IO.File]::WriteAllText((Join-Path $outside 'keep.txt'), 'owner data')
        $link = Join-Path $x.W.Clones "$($x.Id)\escape"
        & cmd.exe /c mklink /J $link $outside | Out-Null
        Test-Path -LiteralPath $link | Should -BeTrue
        [void](Step-Win $x)
        (Get-WinRes $x.W $x.Id).state | Should -Be 'reconciled'
        Test-Path -LiteralPath (Join-Path $outside 'keep.txt') | Should -BeTrue
    }

    It 'a reservation folder replaced by a junction is removed as a link, never entered' -Tag 'safe-delete' {
        $x = New-WinEndedJob
        $w = $x.W   # the fakes find their world as $w
        $outside = Join-Path $x.W.Root 'precious2'
        [void][IO.Directory]::CreateDirectory($outside)
        [IO.File]::WriteAllText((Join-Path $outside 'keep.txt'), 'owner data')
        $dir = Join-Path $x.W.Scratch $x.Id
        [IO.Directory]::Delete($dir, $true)
        & cmd.exe /c mklink /J $dir $outside | Out-Null
        [void](Step-Win $x)
        Test-Path -LiteralPath (Join-Path $outside 'keep.txt') | Should -BeTrue
        Test-Path -LiteralPath $dir | Should -BeFalse
    }

    It 'never re-permissions a link (an ACL write would land on its target)' -Tag 'grant-link' {
        $target = Join-Path $TestDrive 'acl-target'
        [void][IO.Directory]::CreateDirectory($target)
        $before = (Get-Acl -LiteralPath $target).Sddl
        $link = Join-Path $TestDrive 'acl-link'
        & cmd.exe /c mklink /J $link $target | Out-Null
        { Invoke-WinInModule { param($p) Grant-AapWinOwnerAccess $p $true } @($link) } | Should -Throw '*AAP_UnsafeDelete: a link*'
        (Get-Acl -LiteralPath $target).Sddl | Should -Be $before
    }

    It 'refuses to walk through a link on the way to the folder' -Tag 'safe-delete' {
        $root = Join-Path $TestDrive 'del-root'
        $real = Join-Path $TestDrive 'del-real'
        [void][IO.Directory]::CreateDirectory("$real\r-0000000000000001")
        & cmd.exe /c mklink /J $root $real | Out-Null
        { Invoke-WinInModule { param($p, $u) Remove-AapWinTree $p $u } @("$root\r-0000000000000001", $root) } | Should -Throw '*AAP_UnsafeDelete*link*'
        Test-Path -LiteralPath "$real\r-0000000000000001" | Should -BeTrue
    }
}
