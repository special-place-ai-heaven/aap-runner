# destroy (backend-lifecycle.md): release at every teardown, VM and folders (the clone folder with its key, seed and VM
# files) through reparse-checked paths, absence observed before the slot is freed. Release failure modes (broker
# INTEGRATION.md, rules for the callers), a VM or a folder that will not go, links planted in a clone folder, and no slot
# reuse before the teardown proof. Pester 5, Windows PowerShell 5.1 and PowerShell 7.5+.

BeforeAll {
    . (Join-Path $PSScriptRoot 'LinBackendTestHelpers.ps1')
    Import-Module $script:CapModule -Force
    Import-Module $script:BackendModule -Force

    # A world whose one reservation runs a job that has just ended (runner absent), so the next step tears it down.
    function New-LinEndedJob([hashtable]$Knobs = @{}) {
        $w = New-LinWorld
        $B = New-LinBackend $w
        $r = New-LinReservation $w
        [void](Invoke-LinSteps $B $w $r.reservation_id -Max 5 -Until { param($x) $x.state -eq 'ready' })
        [void](Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $r.reservation_id))   # running
        Set-LinKnob $w (@{ RunnerStatus = 'absent' } + $Knobs)
        [pscustomobject]@{ W = $w; B = $B; Id = $r.reservation_id; Gen = $r.lease_generation }
    }
    function Step-Lin($x) { $w = $x.W; Invoke-AapLinStep -Backend $x.B -Reservation (Get-LinRes $x.W $x.Id) }
    function New-LinRequest($w) { Request-AapReservation -Root $w.Cap -Profile linux -MemOverheadMib 512 -CloneGib 55 -ScratchGib 0 -IoMbps 100 -RelaxedTrustForTests }
}

Describe 'release at teardown' {
    It 'retry, unavailable and clock_skew keep the slot deleting with the VM already gone; the next release frees it' -ForEach @('retry', 'unavailable', 'clock_skew') {
        $x = New-LinEndedJob @{ ReleaseOutcome = $_ }
        $w = $x.W   # the fakes find their world as $w
        $s = Step-Lin $x
        $s.Action | Should -Be 'waiting'
        $s.Code | Should -Be 'release_pending'
        (Get-LinRes $x.W $x.Id).state | Should -Be 'deleting'
        @(Get-LinVms $x.W).Count | Should -Be 0
        Test-Path -LiteralPath (Join-Path $x.W.Clones "$($x.Id)\ssh") | Should -BeFalse   # the key went with the clone
        (Step-Lin $x).Code | Should -Be 'retry_later'   # asked again at most once a minute
        Set-LinKnob $x.W @{ ReleaseOutcome = 'normal' }
        $x.B.Now = { [DateTime]::UtcNow.AddSeconds(60) }
        [void](Step-Lin $x)
        $res = Get-LinRes $x.W $x.Id
        $res.state | Should -Be 'reconciled'
        $res.teardown_proof.runner_deregistered | Should -BeTrue
        @(Get-LinCalls $x.W 'RemoveVm *').Count | Should -Be 1
    }

    It 'already_gone is the github-removed proof' {
        $x = New-LinEndedJob
        $w = $x.W
        $l = @(Get-LinLeases $x.W); $l[0].state = 'released'; Save-LinLeases $x.W $l
        [void](Step-Lin $x)
        (Get-LinRes $x.W $x.Id).teardown_proof.runner_deregistered | Should -Be 'github-removed'
    }

    It 'not_found for a lease this process saw issued is uncertain: teardown_failed, capacity held' -Tag 'release-uncertain' {
        $x = New-LinEndedJob @{ ReleaseOutcome = 'not_found' }
        $w = $x.W
        $s = Step-Lin $x
        $s.Code | Should -Be 'release_uncertain'
        $res = Get-LinRes $x.W $x.Id
        $res.state | Should -Be 'quarantined'
        $res.quarantine_kind | Should -Be 'teardown_failed'
        $res.cleanup_uncertain | Should -BeTrue
        $q = New-LinRequest $x.W
        $q.Ok | Should -BeFalse -Because 'the held slot keeps its resources until the teardown is observed'
        $q.Status | Should -Be 'refused'
    }

    It 'not_found for a lease call whose answer died with the supervisor waits 15 minutes, then is never registered' -Tag 'lease-window', 'release-uncertain' {
        $w = New-LinWorld
        $B = New-LinBackend $w
        $r = New-LinReservation $w
        $rid = $r.reservation_id
        [void](Invoke-LinSteps $B $w $rid -Max 5 -Until { param($x) $x.state -eq 'ready' })
        # The lease call never reached the broker (crash after the run_one intent): journal it as such.
        $line = @(Get-LinJournalLines $w $rid | Where-Object { $_ -like '*"op":"ready"*"phase":"done"*' })[0]
        $intent = $line.Replace('"op":"ready"', '"op":"run_one"').Replace("/ready`"", "/run_one`"").Replace('"phase":"done"', '"phase":"intent"')
        $intent = [regex]::Replace($intent, '"result":\{[^}]*\}', '"result":null')
        [IO.File]::AppendAllText((Join-Path $w.Journal "$rid.jsonl"), $intent + "`n")
        Invoke-LinValidator $w 'backend-lifecycle' @($intent) | Should -BeNullOrEmpty
        $B2 = New-LinBackend $w   # a restarted supervisor: no memory of the lease outcome
        Set-LinKnob $w @{ ReleaseOutcome = 'not_found' }
        $s = Invoke-AapLinStep -Backend $B2 -Reservation (Get-LinRes $w $rid)
        $s.Code | Should -Be 'release_pending'
        (Get-LinRes $w $rid).state | Should -Be 'deleting'
        @(Get-LinVms $w).Count | Should -Be 0
        $B2.Now = { [DateTime]::UtcNow.AddMinutes(16) }
        $res = Get-LinRes $w $rid
        & (Get-Module AapCapacity) { function script:Get-AapUtcNow { [DateTime]::UtcNow.AddMinutes(16) } }
        try { $s = Invoke-AapLinStep -Backend $B2 -Reservation $res } finally { & (Get-Module AapCapacity) { function script:Get-AapUtcNow { [DateTime]::UtcNow } } }
        (Get-LinRes $w $rid).state | Should -Be 'reconciled'
        (Get-LinRes $w $rid).teardown_proof.runner_deregistered | Should -Be 'never_registered'
    }
}

Describe 'no slot reuse before the teardown is observed' {
    It 'a VM that will not go: three tries, teardown_failed, capacity held; freed once it is gone' -Tag 'observe-absent' {
        $x = New-LinEndedJob @{ RemoveVmFails = $true }
        $w = $x.W
        $s = Step-Lin $x
        $s.Code | Should -Be 'teardown_failed'
        @(Get-LinCalls $x.W 'RemoveVm *').Count | Should -Be 3
        $res = Get-LinRes $x.W $x.Id
        $res.state | Should -Be 'quarantined'
        $res.quarantine_kind | Should -Be 'teardown_failed'
        @(Get-LinVms $x.W).Count | Should -Be 1
        $q = New-LinRequest $x.W
        $q.Ok | Should -BeFalse -Because 'the held slot keeps its resources until the teardown is observed'
        $q.Status | Should -Be 'refused'
        Set-LinKnob $x.W @{ RemoveVmFails = $false }
        $x.B.Now = { [DateTime]::UtcNow.AddSeconds(60) }
        [void](Step-Lin $x)
        (Get-LinRes $x.W $x.Id).state | Should -Be 'reconciled'
        (New-LinRequest $x.W).Ok | Should -BeTrue
    }

    It 'a scratch folder that will not go, a network that will not detach, or a root on another volume holds the slot' -Tag 'observe-scratch', 'detach', 'gone-volume' {
        foreach ($case in @('scratch', 'detach', 'volume')) {
            $x = New-LinEndedJob
            $w = $x.W
            $h = $null
            if ($case -eq 'scratch') {
                # The Linux profile makes no scratch folder; one that appears there (planted, or left by anything) is
                # removed by destroy, and while it will not go, nothing is observed absent.
                [void][IO.Directory]::CreateDirectory((Join-Path $x.W.Scratch $x.Id))
                $h = [IO.File]::Open((Join-Path $x.W.Scratch "$($x.Id)\held.bin"), 'Create', 'ReadWrite', 'None')
            }
            if ($case -eq 'detach') { Set-AapFakeHostNetworkKnob -Root $w.Net -Fail Detach }
            if ($case -eq 'volume') { Set-LinKnob $w @{ WrongVolume = 'scratch' } }
            try { $s = Step-Lin $x } finally { if ($h) { $h.Dispose() } }
            $s.Code | Should -Be 'teardown_failed' -Because $case
            (Get-LinRes $x.W $x.Id).state | Should -Be 'quarantined'
            Set-LinKnob $w @{ WrongVolume = '' }
            Set-AapFakeHostNetworkKnob -Root $w.Net
            $x.B.Now = { [DateTime]::UtcNow.AddSeconds(60) }
            [void](Step-Lin $x)
            (Get-LinRes $x.W $x.Id).state | Should -Be 'reconciled' -Because $case
            Test-Path -LiteralPath (Join-Path $x.W.Scratch $x.Id) | Should -BeFalse
        }
    }

    It 'a key file or clone file that will not go holds the slot too' -Tag 'observe-absent' {
        foreach ($f in 'ssh\id_ed25519', 'held.bin') {
            $x = New-LinEndedJob
            $w = $x.W
            $p = Join-Path $x.W.Clones "$($x.Id)\$f"
            $h = [IO.File]::Open($p, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            try { $s = Step-Lin $x } finally { $h.Dispose() }
            $s.Code | Should -Be 'teardown_failed' -Because $f
            @(Get-LinVms $x.W).Count | Should -Be 0
            (Get-LinRes $x.W $x.Id).state | Should -Be 'quarantined'
            $x.B.Now = { [DateTime]::UtcNow.AddSeconds(60) }
            [void](Step-Lin $x)
            (Get-LinRes $x.W $x.Id).state | Should -Be 'reconciled'
            Test-Path -LiteralPath (Join-Path $x.W.Clones $x.Id) | Should -BeFalse
        }
    }

    It 'destroy is idempotent: a second destroy of a reconciled slot changes nothing and calls nothing' {
        $x = New-LinEndedJob
        $w = $x.W
        [void](Step-Lin $x)
        $r = Get-LinRes $x.W $x.Id
        $j = Invoke-LinInModule { param($B, $r) Read-AapLinJournal $B $r } @($x.B, $r)
        $out = Invoke-LinInModule { param($B, $r, $j) Invoke-AapLinDestroy $B $r $j -Force } @($x.B, $r, $j)
        $out.Action | Should -Be 'destroyed'
        @(Get-LinCalls $x.W 'RemoveVm *').Count | Should -Be 1
        (Get-LinRes $x.W $x.Id).state | Should -Be 'reconciled'
    }
}

Describe 'links in a clone folder never redirect a delete' {
    It 'a junction inside the clone folder (or in place of its ssh folder) is removed as a link; its target survives' -Tag 'safe-delete' {
        foreach ($at in 'escape', 'ssh') {
            $x = New-LinEndedJob
            $w = $x.W
            $outside = Join-Path $x.W.Root "precious-$at"
            [void][IO.Directory]::CreateDirectory($outside)
            [IO.File]::WriteAllText((Join-Path $outside 'keep.txt'), 'owner data')
            $link = Join-Path $x.W.Clones "$($x.Id)\$at"
            if ($at -eq 'ssh') { [IO.Directory]::Delete($link, $true) }
            & cmd.exe /c mklink /J $link $outside | Out-Null
            Test-Path -LiteralPath $link | Should -BeTrue
            [void](Step-Lin $x)
            (Get-LinRes $x.W $x.Id).state | Should -Be 'reconciled' -Because $at
            Test-Path -LiteralPath (Join-Path $outside 'keep.txt') | Should -BeTrue -Because $at
        }
    }

    It 'a reservation folder replaced by a junction is removed as a link, never entered' -Tag 'safe-delete' {
        $x = New-LinEndedJob
        $w = $x.W
        $outside = Join-Path $x.W.Root 'precious2'
        [void][IO.Directory]::CreateDirectory($outside)
        [IO.File]::WriteAllText((Join-Path $outside 'keep.txt'), 'owner data')
        $dir = Join-Path $x.W.Clones $x.Id
        [IO.Directory]::Delete($dir, $true)
        & cmd.exe /c mklink /J $dir $outside | Out-Null
        [void](Step-Lin $x)
        Test-Path -LiteralPath (Join-Path $outside 'keep.txt') | Should -BeTrue
        Test-Path -LiteralPath $dir | Should -BeFalse
    }

    It 'never re-permissions a link (an ACL write would land on its target)' -Tag 'grant-link' {
        $target = Join-Path $TestDrive 'acl-target'
        [void][IO.Directory]::CreateDirectory($target)
        $before = (Get-Acl -LiteralPath $target).Sddl
        $link = Join-Path $TestDrive 'acl-link'
        & cmd.exe /c mklink /J $link $target | Out-Null
        { Invoke-LinInModule { param($p) Grant-AapLinOwnerAccess $p $true } @($link) } | Should -Throw '*AAP_UnsafeDelete: a link*'
        (Get-Acl -LiteralPath $target).Sddl | Should -Be $before
    }

    It 'refuses to walk through a link on the way to the folder' -Tag 'safe-delete' {
        $root = Join-Path $TestDrive 'del-root'
        $real = Join-Path $TestDrive 'del-real'
        [void][IO.Directory]::CreateDirectory("$real\r-0000000000000001")
        & cmd.exe /c mklink /J $root $real | Out-Null
        { Invoke-LinInModule { param($p, $u) Remove-AapLinTree $p $u } @("$root\r-0000000000000001", $root) } | Should -Throw '*AAP_UnsafeDelete*link*'
        Test-Path -LiteralPath "$real\r-0000000000000001" | Should -BeTrue
    }
}
