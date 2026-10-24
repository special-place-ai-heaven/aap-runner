# Backend first-probe admission and reply behavior with an offline seeded, simulated clone. No VM/live system.
BeforeAll {
    . (Join-Path $PSScriptRoot 'LinBackendTestHelpers.ps1')
    Import-Module $script:CapModule -Force
    Import-Module $script:BackendModule -Force
    function New-LinIdentityProbe($w, $B, $r, [string]$Change = '') {
        (Invoke-AapLinStep -Backend $B -Reservation $r -BaseSha256 $w.BaseSha -CatalogGuestRevision 2 -ApprovedGuestRevision 2).Action | Should -Be 'created'
        $path = Join-Path $w.Clones "$($r.reservation_id)\seed.iso"
        $seed = Read-LinSeed $path
        $text = [string]$seed.files.'user-data'
        $line = [regex]::Match($text, '(?m)^# aap-guest-identity: (.+)$').Value
        $record = $line.Substring('# aap-guest-identity: '.Length)
        $id = ConvertFrom-LinJson $record
        switch ($Change) {
            'vm' { $id.vm_id = '00000000-0000-4000-8000-000000000000' }
            'reservation' { $id.reservation_id = 'r-0000000000000000' }
            'generation' { $id.lease_generation++ }
            'schema1' { $id.schema = 1 }
        }
        $newLine = '# aap-guest-identity: ' + (ConvertTo-Json $id -Compress)
        $seed.files.'user-data' = $text.Replace($line, $newLine)
        if ($Change -eq 'missing') { $seed.files.'user-data' = $text.Replace($line + "`n", '') }
        if ($Change -eq 'duplicate') { $seed.files.'user-data' = $text + $line + "`n" }
        Write-LinJson $path $seed
        (Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $r.reservation_id)).Action | Should -Be 'booted'
        $record
    }
}

Describe 'offline identity and the first host probe' {
    It 'abandons a mismatched, missing, duplicate or old-schema offline record before registration (<Change>)' -ForEach @(
        @{ Change = 'vm' }, @{ Change = 'reservation' }, @{ Change = 'generation' }, @{ Change = 'missing' }, @{ Change = 'duplicate' }, @{ Change = 'schema1' }
    ) {
        $w = New-LinWorld; $B = New-LinBackend $w; $r = New-LinReservation $w
        $null = New-LinIdentityProbe $w $B $r $Change
        $step = Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $r.reservation_id)
        $step.Action | Should -Be 'destroyed'
        $step.Code | Should -Be 'fatal'
        $res = Get-LinRes $w $r.reservation_id
        $res.state | Should -Be 'reconciled'
        $res.teardown_proof.runner_deregistered | Should -Be 'never_registered'
        @(Get-LinCalls $w 'Broker lease_request *').Count | Should -Be 0
        @(Get-LinVms $w).Count | Should -Be 0
    }
    It 'checks every echoed identity field against the reservation even on the first probe (<Field>)' -Tag 'reply-echo' -ForEach @(
        @{ Field = 'vm_id' }, @{ Field = 'reservation_id' }, @{ Field = 'lease_generation' }
    ) {
        $w = New-LinWorld; $B = New-LinBackend $w; $r = New-LinReservation $w
        $null = New-LinIdentityProbe $w $B $r
        Set-LinKnob $w @{ Guest = @{ probe = ('echo-' + $Field) } }
        $step = Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $r.reservation_id)
        $step.Action | Should -Be 'destroyed'
        $step.Code | Should -Be 'wrong_echo'
        @(Get-LinJournal $w $r.reservation_id | Where-Object { $_.phase -eq 'failed' -and $_.result.code -eq 'hostile_guest' }).Count | Should -BeGreaterThan 0
        @(Get-LinCalls $w 'Broker lease_request *').Count | Should -Be 0
    }
    It 'validates the real seed writer record and first reply as identity_exchange, keeping wire replies schema 1' {
        $w = New-LinWorld; $B = New-LinBackend $w; $r = New-LinReservation $w
        $record = ConvertFrom-LinJson (New-LinIdentityProbe $w $B $r)
        (Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $r.reservation_id)).Action | Should -Be 'ready'
        $files = @(Get-ChildItem -LiteralPath (Join-Path $w.Fake 'exchanges'))
        $files.Count | Should -Be 1
        $exchange = Read-LinJson $files[0].FullName $null
        $exchange.reply.schema | Should -Be 1
        @($exchange.reply.PSObject.Properties.Name).Count | Should -Be 11
        $composite = [ordered]@{ schema = 2; kind = 'identity_exchange'; record = $record; cmd = $exchange.cmd; reply = $exchange.reply
            reread = @{ phase = 'before_cleanup'; record = $record } }
        Invoke-LinValidator $w 'guest-transport' @((ConvertTo-Json $composite -Depth 10 -Compress)) | Should -BeNullOrEmpty
    }
    It 'refuses any record after cleanup (same or different), including a later probe, without rebinding' {
        foreach ($different in @($false, $true)) {
            $w = New-LinWorld; $B = New-LinBackend $w; $r = New-LinReservation $w
            $record = New-LinIdentityProbe $w $B $r
            [void](Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $r.reservation_id))
            (Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $r.reservation_id)).Action | Should -Be 'running'
            if ($different) { $id = ConvertFrom-LinJson $record; $id.lease_generation++; $record = ConvertTo-Json $id -Compress }
            $vms = @(Get-LinVms $w); $vms[0] | Add-Member -NotePropertyName IdentityRecord -NotePropertyValue $record -Force; Save-LinVms $w $vms
            $res = Get-LinRes $w $r.reservation_id
            $p = Invoke-LinInModule { param($B, $r) Invoke-AapLinCommand $B $r 'probe' } @($B, $res)
            $p.Kind | Should -Be 'refused'
            $p.Reply.guest_state | Should -Be 'failed'
            $vms = @(Get-LinVms $w); $vms[0].IdentityRecord = ''; Save-LinVms $w $vms
            (Invoke-LinInModule { param($B, $r) Invoke-AapLinCommand $B $r 'probe' } @($B, $res)).Kind | Should -Be 'refused'
        }
    }
}
