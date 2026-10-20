# create refuses, before any guest runs, everything backend-lifecycle.md forbids: untrusted roots (the admin-only
# definition), a base that is not the pinned one or not a plain file, a VM whose settings or files are off, a guest
# network other than P10.0's verified internal switch, host settings that open another way into a guest. Each refusal is
# journaled and frees the slot as never registered (held instead when the roots cannot prove the folders gone).
# Also the storage document, the journal folder, and the offline disk helpers. Pester 5, Windows PowerShell 5.1 and
# PowerShell 7.5+.

BeforeAll {
    . (Join-Path $PSScriptRoot 'WinBackendTestHelpers.ps1')
    Import-Module $script:CapModule -Force
    Import-Module $script:BackendModule -Force

    # One create step in a fresh world after $Prepare; returns the result, the world and the journal's failure detail.
    function Invoke-WinCreate([scriptblock]$Prepare = {}, [hashtable]$Knobs = @{}, $Sha = $null) {
        $w = New-WinWorld
        Set-WinKnob $w $Knobs
        & $Prepare $w
        $B = New-WinBackend $w
        $r = New-WinReservation $w
        $pin = $(if ($null -ne $Sha) { $Sha } else { $w.BaseSha })
        $s = Invoke-AapWinStep -Backend $B -Reservation $r -BaseSha256 $pin
        $fail = @(Get-WinJournal $w $r.reservation_id | Where-Object { $_.op -eq 'create' -and $_.phase -eq 'failed' })
        [pscustomobject]@{ Step = $s; W = $w; Res = (Get-WinRes $w $r.reservation_id); Detail = $(if ($fail.Count) { $fail[0].result.detail } else { '' }) }
    }
    # A refused create: freed as never registered, no VM left, nothing booted. -Held: a root that cannot prove absence (a
    # link, another volume) keeps the slot instead.
    function Assert-WinRefused($x, [string]$Like, [switch]$Held) {
        $x.Detail | Should -BeLike $Like
        if ($Held) { $x.Res.state | Should -Be 'creating'; $x.Step.Code | Should -Be 'folders_remain' }
        else {
            $x.Res.state | Should -Be 'reconciled'
            $x.Res.teardown_proof.runner_deregistered | Should -Be 'never_registered'
        }
        @(Get-WinVms $x.W).Count | Should -Be 0
        @(Get-WinCalls $x.W 'StartVm *').Count | Should -Be 0
        @(Get-ChildItem -LiteralPath $x.W.Clones).Count | Should -Be 0
    }
    function Grant-WinAce([string]$Path, [string]$Grant) { $o = & icacls.exe $Path /grant $Grant 2>&1; if ($LASTEXITCODE) { throw "icacls: $o" } }
}

Describe 'trusted roots only' {
    It 'clone_root with a read ACE for Everyone is refused: admin-only means no other ACE at all' -Tag 'admin-only', 'root-trust' {
        $x = Invoke-WinCreate { param($w) Grant-WinAce $w.Clones '*S-1-1-0:(R)' }
        Assert-WinRefused $x '*AAP_StorageUntrusted*clone_root*grants S-1-1-0 access*'
    }

    It 'base_root may grant read, never write or an inheritable ACE' -Tag 'no-write', 'root-trust' {
        $x = Invoke-WinCreate { param($w) Grant-WinAce $w.Base '*S-1-1-0:(R)' }
        $x.Step.Action | Should -Be 'created'
        foreach ($g in '*S-1-1-0:(W)', '*S-1-1-0:(OI)(CI)(R)') {
            $x = Invoke-WinCreate { param($w) Grant-WinAce $w.Base $g }
            Assert-WinRefused $x '*AAP_StorageUntrusted*base_root*write or inheritable*'
        }
    }

    It 'a root that inherits its DACL is refused' -Tag 'acl-protected', 'root-trust' {
        $x = Invoke-WinCreate { param($w) & icacls.exe $w.Scratch /inheritance:e | Out-Null }
        Assert-WinRefused $x '*AAP_StorageUntrusted*scratch_root*inherits*'
    }

    It 'a root that is a junction is refused, even to a well-protected folder' -Tag 'root-reparse', 'root-trust' {
        $x = Invoke-WinCreate { param($w)
            $real = Join-Path $w.Root 'real-clones'
            New-WinAclDir $real
            [IO.Directory]::Delete($w.Clones)
            & cmd.exe /c mklink /J $w.Clones $real | Out-Null
        }
        Assert-WinRefused $x '*AAP_StorageUntrusted*clone_root*reparse point*' -Held
    }

    It 'a junction above a root is refused' -Tag 'ancestor-reparse', 'root-trust' {
        $x = Invoke-WinCreate { param($w)
            $j = Join-Path $w.Root 'via'
            & cmd.exe /c mklink /J $j (Join-Path $w.Root 'roots') | Out-Null
            $doc = Get-Content -Raw $w.StoragePath | ConvertFrom-Json
            $doc.roots.scratch_root.path = Join-Path $j 'scratch'
            Write-WinJson $w.StoragePath $doc
        }
        Assert-WinRefused $x '*AAP_StorageUntrusted*scratch_root: reparse point above the root*'
    }

    It 'a root on another volume than recorded is refused' -Tag 'volume', 'root-trust' {
        $x = Invoke-WinCreate -Knobs @{ WrongVolume = 'scratch' }
        Assert-WinRefused $x '*AAP_StorageUntrusted*scratch_root: on volume*recorded*' -Held
    }

    It 'an owner outside the trusted SIDs is a problem' -Tag 'root-owner' {
        $w = New-WinWorld
        $B = New-WinBackend $w
        $B.TrustedSids = @('S-1-5-18', 'S-1-5-32-544')   # the test user, who owns the test roots, no longer trusted
        $p = @(Get-AapWinStorageProblem -Backend $B)
        @($p | Where-Object { $_ -like 'clone_root: owner * is not an admin: *' }).Count | Should -Be 1
    }

    It 'a path on a drive that is not a fixed local drive is a problem' -Tag 'fixed-drive' {
        $w = New-WinWorld
        $B = New-WinBackend $w
        $free = @([char[]]'QRSTUVWXYZ' | Where-Object { -not (Test-Path "$($_):\") })[0]
        $p = Invoke-WinInModule { param($B, $path) Get-AapWinTrustProblem $B $path } @($B, "$($free):\aap\clones")
        @($p | Where-Object { $_ -like '*not on a fixed local drive*' }).Count | Should -Be 1
    }
}

Describe 'the base' {
    It 'create needs the pinned hash' -Tag 'base-pin' {
        $x = Invoke-WinCreate -Sha ''
        Assert-WinRefused $x '*AAP_BaseUnpinned*'
        @(Get-WinCalls $x.W 'HashFile *').Count | Should -Be 0
    }

    It 'a base whose hash differs from the pin is refused' -Tag 'base-hash' {
        $x = Invoke-WinCreate -Knobs @{ HashOverride = ('0' * 64) }
        Assert-WinRefused $x '*AAP_BaseHashMismatch*'
    }

    It 'a base that is not a plain file is refused, whatever its hash' -Tag 'base-kind' {
        $x = Invoke-WinCreate { param($w) [IO.File]::SetAttributes($w.BaseFile, 'Normal'); [IO.File]::Delete($w.BaseFile); [void][IO.Directory]::CreateDirectory($w.BaseFile) } -Knobs @{ HashOverride = ('a' * 64) } -Sha ('a' * 64)
        Assert-WinRefused $x '*AAP_BaseMissing*'
    }

    It 'a generation folder reached through a junction is refused' -Tag 'plain-path' {
        $x = Invoke-WinCreate { param($w)
            $gen = Split-Path -Parent $w.BaseFile
            $real = Join-Path $w.Root 'elsewhere'
            [void][IO.Directory]::CreateDirectory($real)
            [IO.File]::SetAttributes($w.BaseFile, 'Normal')
            Copy-Item -LiteralPath $w.BaseFile -Destination $real
            [IO.Directory]::Delete($gen, $true)
            & cmd.exe /c mklink /J $gen $real | Out-Null
        }
        Assert-WinRefused $x '*AAP_BaseUntrusted*a link*'
    }

    It 'a base that is not sealed read-only (<Name>) is refused' -Tag 'base-sealed', 'sealed-acl', 'sealed-readonly' -ForEach @(
        @{ Name = 'generation folder inherits'; Like = '*AAP_BaseUntrusted: inherits its DACL*'; Prep = { param($w) & icacls.exe (Split-Path -Parent $w.BaseFile) /inheritance:e | Out-Null } }
        @{ Name = 'Users may write the base'; Like = '*AAP_BaseUntrusted: grants S-1-5-32-545 more than Virtual Machines read*'; Prep = { param($w) [IO.File]::SetAttributes($w.BaseFile, 'Normal'); & icacls.exe $w.BaseFile /grant '*S-1-5-32-545:(W)' | Out-Null; [IO.File]::SetAttributes($w.BaseFile, 'ReadOnly') } }
        @{ Name = 'Virtual Machines may write'; Like = '*AAP_BaseUntrusted: grants S-1-5-83-0 more*'; Prep = { param($w) [IO.File]::SetAttributes($w.BaseFile, 'Normal'); & icacls.exe $w.BaseFile /grant '*S-1-5-83-0:(M)' | Out-Null; [IO.File]::SetAttributes($w.BaseFile, 'ReadOnly') } }
        @{ Name = 'no ReadOnly attribute'; Like = '*AAP_BaseUntrusted: not ReadOnly*'; Prep = { param($w) [IO.File]::SetAttributes($w.BaseFile, 'Normal') } }
    ) {
        $x = Invoke-WinCreate $Prep
        Assert-WinRefused $x $Like
        @(Get-WinCalls $x.W 'HashFile *').Count | Should -Be 0
    }

    It 'a sealed entry owned by anyone but an admin is a problem' -Tag 'sealed-owner' {
        $w = New-WinWorld
        $B = New-WinBackend $w
        Invoke-WinInModule { param($B, $p) Get-AapWinSealedProblem $B $p } @($B, $w.BaseFile) | Should -BeNullOrEmpty
        $B.TrustedSids = @('S-1-5-18', 'S-1-5-32-544')   # the test user owns the test base
        Invoke-WinInModule { param($B, $p) Get-AapWinSealedProblem $B $p } @($B, $w.BaseFile) | Should -BeLike 'owner * is not an admin: *'
    }

    It 'the hash reads the backend''s own read handle, and a reused os.avhdx must be a child of the pinned base' -Tag 'disk-parent' {
        $x = Invoke-WinCreate
        $x.Step.Action | Should -Be 'created'
        $x = Invoke-WinCreate -Knobs @{ VhdParent = 'C:\elsewhere\base.vhdx' }
        Assert-WinRefused $x '*AAP_UnsafePath: os.avhdx is not a child of its generation''s base*'
        # The handle shares reading only: while create holds it nobody can write the base.
        $w = New-WinWorld
        $B = New-WinBackend $w
        $probe = Join-Path $w.Root 'probe.txt'
        $B.Provider.HashFile = { param($a)
            [IO.File]::SetAttributes($a.Path, 'Normal')   # attribute writes ignore share modes; opening for write does not
            $res = try { $f = [IO.File]::Open($a.Path, 'Open', 'ReadWrite', 'ReadWrite'); $f.Dispose(); 'writable' } catch { 'locked' }
            [IO.File]::SetAttributes($a.Path, 'ReadOnly')
            [IO.File]::WriteAllText($probe, $res)
            'mismatch'
        }.GetNewClosure()
        $r = New-WinReservation $w
        [void](Invoke-AapWinStep -Backend $B -Reservation $r -BaseSha256 $w.BaseSha)
        [IO.File]::ReadAllText($probe) | Should -Be 'locked'
        @(Get-WinJournal $w $r.reservation_id | Where-Object { $_.phase -eq 'failed' })[0].result.detail | Should -BeLike '*AAP_BaseHashMismatch*'
    }

    It 'a clone disk path that is already a folder is refused' -Tag 'disk-kind' {
        $w = New-WinWorld
        $B = New-WinBackend $w
        $r = New-WinReservation $w
        [void][IO.Directory]::CreateDirectory((Join-Path $w.Clones "$($r.reservation_id)\os.avhdx"))
        $s = Invoke-AapWinStep -Backend $B -Reservation $r -BaseSha256 $w.BaseSha
        @(Get-WinJournal $w $r.reservation_id | Where-Object { $_.phase -eq 'failed' })[0].result.detail | Should -BeLike '*AAP_UnsafePath: os.avhdx is a dir*'
        @(Get-WinCalls $w 'NewVm *').Count | Should -Be 0
        $w2 = New-WinWorld
        $w = $w2
        $B = New-WinBackend $w
        $r = New-WinReservation $w
        [void][IO.Directory]::CreateDirectory((Join-Path $w.Scratch "$($r.reservation_id)\scratch.vhdx"))
        [void](Invoke-AapWinStep -Backend $B -Reservation $r -BaseSha256 $w.BaseSha)
        @(Get-WinJournal $w $r.reservation_id | Where-Object { $_.phase -eq 'failed' })[0].result.detail | Should -BeLike '*AAP_UnsafePath: scratch.vhdx is a dir*'
    }
}

Describe 'the host' {
    It 'refuses Enhanced Session Mode, a non-admin Hyper-V Administrator and an unreadable host' -Tag 'host-trust', 'enhanced-session', 'hyperv-admins' {
        Assert-WinRefused (Invoke-WinCreate -Knobs @{ EnhancedSession = $true }) '*AAP_EnhancedSession*'
        Assert-WinRefused (Invoke-WinCreate -Knobs @{ HyperVAdmins = @('S-1-5-21-1-2-3-1001') }) '*AAP_HyperVAdmins: S-1-5-21-1-2-3-1001 is a member*'
        Assert-WinRefused (Invoke-WinCreate -Knobs @{ HostFails = $true }) '*AAP_HostUnreadable*'
        (Invoke-WinCreate -Knobs @{ HyperVAdmins = @('S-1-5-32-544', 'S-1-5-18') }).Step.Action | Should -Be 'created'
        $w = New-WinWorld
        $B = New-WinBackend $w
        Get-AapWinHostProblem -Backend $B | Should -BeNullOrEmpty
    }
}

Describe 'the VM and its network' {
    It 'refuses VM setting <Field> = <Value>' -Tag 'vm-settings', 'vm-integration', 'vm-paths' -ForEach @(
        @{ Field = 'GuestServiceInterface'; Value = $true; Like = '*Guest Service Interface*' }
        @{ Field = 'KeyValuePairExchange'; Value = $true; Like = '*Key-Value Pair Exchange*' }
        @{ Field = 'CheckpointType'; Value = 'Standard'; Like = '*checkpoints*' }
        @{ Field = 'AutomaticStopAction'; Value = 'Save'; Like = '*automatic start or stop*' }
        @{ Field = 'AutomaticStartAction'; Value = 'StartIfRunning'; Like = '*automatic start or stop*' }
        @{ Field = 'Generation'; Value = 1; Like = '*generation 2*' }
        @{ Field = 'Cpus'; Value = 99; Like = '*CPU or memory*' }
        @{ Field = 'ConfigurationLocation'; Value = 'C:\ProgramData\Microsoft\Windows\Hyper-V'; Like = "*ConfigurationLocation is outside*" }
        @{ Field = 'SmartPagingFilePath'; Value = 'C:\ProgramData\Microsoft\Windows\Hyper-V'; Like = "*SmartPagingFilePath is outside*" }
        @{ Field = 'Disks'; Value = @('C:\other\os.avhdx'); Like = '*a disk is outside*' }
        @{ Field = 'DvdDrives'; Value = 1; Like = '*DvdDrives attached*' }
        @{ Field = 'ComPorts'; Value = 1; Like = '*ComPorts attached*' }
        @{ Field = 'GpuPartitions'; Value = 1; Like = '*GpuPartitions attached*' }
        @{ Field = 'AssignedDevices'; Value = 1; Like = '*AssignedDevices attached*' }
    ) {
        $x = Invoke-WinCreate -Knobs @{ VmOverride = @{ $Field = $Value } }
        Assert-WinRefused $x "*AAP_VmUntrusted*$($Like.Trim('*'))*"
        @(Get-WinCalls $x.W 'RemoveVm *').Count | Should -Be 1   # the VM it made is gone again
    }

    It 'refuses a VM with a disk create did not make, even inside the reservation folder' -Tag 'vm-devices' {
        Assert-WinRefused (Invoke-WinCreate -Knobs @{ ExtraDisk = $true }) '*AAP_VmUntrusted*not exactly os.avhdx and scratch.vhdx*'
    }

    It 'never adopts a VM found only by its name: create fails, the VM is destroyed, no second VM is made' -Tag 'vm-journaled' {
        $w = New-WinWorld
        $B = New-WinBackend $w
        $r = New-WinReservation $w
        $name = Get-AapVmName -Profile windows -Slot $r.slot -LeaseGeneration $r.lease_generation -ReservationId $r.reservation_id
        Save-WinVms $w @([pscustomobject]@{ Id = [guid]::NewGuid().ToString(); Name = $name; State = 'Off'; Cpus = 2; MemGib = 4; ConfigurationLocation = $w.Root })
        [void](Invoke-AapWinStep -Backend $B -Reservation $r -BaseSha256 $w.BaseSha)
        @(Get-WinJournal $w $r.reservation_id | Where-Object { $_.phase -eq 'failed' })[0].result.detail | Should -BeLike '*AAP_VmNotJournaled*'
        @(Get-WinCalls $w 'NewVm *').Count | Should -Be 0
        @(Get-WinVms $w).Count | Should -Be 0
        (Get-WinRes $w $r.reservation_id).state | Should -Be 'reconciled'
    }

    It 'reuses only the VM whose id the journal recorded: another VM under that name is refused' -Tag 'vm-journaled' {
        $w = New-WinWorld
        $B = New-WinBackend $w
        $r = New-WinReservation $w
        $rid = $r.reservation_id
        [void](Invoke-AapWinStep -Backend $B -Reservation $r -BaseSha256 $w.BaseSha)
        # A crash before create/done: drop that record, and swap the VM for another one with the same name.
        $path = Join-Path $w.Journal "$rid.jsonl"
        [IO.File]::WriteAllText($path, ((@(Get-WinJournalLines $w $rid | Where-Object { $_ -notlike '*"phase":"done"*' }) -join "`n") + "`n"))
        $vms = @(Get-WinVms $w); $vms[0].Id = [guid]::NewGuid().ToString(); Save-WinVms $w $vms
        $B2 = New-WinBackend $w
        [void](Invoke-AapWinStep -Backend $B2 -Reservation (Get-WinRes $w $rid) -BaseSha256 $w.BaseSha)
        @(Get-WinJournal $w $rid | Where-Object { $_.phase -eq 'failed' })[0].result.detail | Should -BeLike '*AAP_VmMismatch*'
        @(Get-WinCalls $w 'NewVm *').Count | Should -Be 1
    }

    It 'refuses a guest adapter on <Name> (<Type>), or without DHCP guard, or with MAC spoofing' -Tag 'switch' -ForEach @(
        @{ Name = 'Default Switch'; Type = 'Internal'; Guard = $true; Spoof = $false }
        @{ Name = 'aap-guests-win'; Type = 'External'; Guard = $true; Spoof = $false }
        @{ Name = 'aap-guests-linux'; Type = 'Internal'; Guard = $true; Spoof = $false }
        @{ Name = 'aap-guests-win'; Type = 'Internal'; Guard = $false; Spoof = $false }
        @{ Name = 'aap-guests-win'; Type = 'Internal'; Guard = $true; Spoof = $true }
    ) {
        $x = Invoke-WinCreate -Knobs @{ NetSwitch = $Name; NetSwitchType = $Type; NetDhcpGuard = $Guard; NetMacSpoofing = $Spoof }
        Assert-WinRefused $x '*AAP_VmUntrusted*adapter*'
    }

    It 'refuses when the network module''s own verification fails' -Tag 'network-verify' {
        $x = Invoke-WinCreate -Knobs @{ NetProblems = @('port ACL missing: 169.254.0.0/16') }
        Assert-WinRefused $x '*AAP_NetworkUntrusted*port ACL missing*'
    }

    It 'without the P10.0 module every create fails closed' {
        $w = New-WinWorld
        $B = New-AapWinBackend -Provider (New-WinProvider) -Transport (New-WinGuest) -BrokerInvoker (New-WinBroker) -AllocatorRoot $w.Cap -JournalRoot $w.Journal `
            -StoragePath $w.StoragePath -LockTimeoutSeconds 5 -RelaxedTrustForTests -WarningAction SilentlyContinue -Sleep { param($s) }
        $r = New-WinReservation $w
        [void](Invoke-AapWinStep -Backend $B -Reservation $r -BaseSha256 $w.BaseSha)
        $x = [pscustomobject]@{ W = $w; Res = (Get-WinRes $w $r.reservation_id); Detail = @(Get-WinJournal $w $r.reservation_id | Where-Object { $_.phase -eq 'failed' })[0].result.detail }
        Assert-WinRefused $x '*AAP_NetworkUnavailable*'
    }

    It 'a failed create is never run again: while its folders will not go, the next step only tears down' -Tag 'no-recreate' {
        $w = New-WinWorld
        $B = New-WinBackend $w
        $r = New-WinReservation $w
        Set-WinKnob $w @{ NewVmFails = $true }
        [void][IO.Directory]::CreateDirectory((Join-Path $w.Clones $r.reservation_id))
        $h = [IO.File]::Open((Join-Path $w.Clones "$($r.reservation_id)\held.bin"), [IO.FileMode]::Create, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try { (Invoke-AapWinStep -Backend $B -Reservation $r -BaseSha256 $w.BaseSha).Code | Should -Be 'folders_remain' } finally { $h.Dispose() }
        Set-WinKnob $w @{ NewVmFails = $false }
        $B.Now = { [DateTime]::UtcNow.AddSeconds(60) }   # a teardown retry runs at most once a minute
        (Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $r.reservation_id) -BaseSha256 $w.BaseSha).Action | Should -Be 'destroyed'
        @(Get-WinCalls $w 'NewVm *').Count | Should -Be 1
        (Get-WinRes $w $r.reservation_id).teardown_proof.runner_deregistered | Should -Be 'never_registered'
    }

    It 'a failed offline credential write refuses too, and never boots' {
        $x = Invoke-WinCreate -Knobs @{ UnattendFails = $true }
        Assert-WinRefused $x '*AAP_DiskLayout*'
    }
}

Describe 'the backend context' {
    It 'refuses a provider without every op' -Tag 'provider-ops' {
        $w = New-WinWorld
        $p = New-WinProvider
        $p.Remove('ListVms')
        { New-AapWinBackend -Provider $p -Network (New-WinNetwork) -AllocatorRoot $w.Cap -JournalRoot $w.Journal -StoragePath $w.StoragePath -RelaxedTrustForTests -WarningAction SilentlyContinue } |
            Should -Throw '*AAP_ProviderInvalid*ListVms*'
    }

    It 'refuses a journal folder anyone else can read' -Tag 'journal-trust' {
        $w = New-WinWorld
        [void](New-WinBackend $w)
        Grant-WinAce $w.Journal '*S-1-5-32-545:(R)'
        { New-WinBackend $w } | Should -Throw '*AAP_JournalUntrusted*S-1-5-32-545*'
    }

    It 'refuses a compile folder anyone else can read (Add-Type''s temporary files go there)' -Tag 'compile-trust' {
        $w = New-WinWorld
        [void](New-WinBackend $w)
        Grant-WinAce (Join-Path $w.Journal 'compile') '*S-1-1-0:(R)'
        { New-WinBackend $w } | Should -Throw '*AAP_CompileUntrusted*S-1-1-0*'
    }

    It 'creates a missing journal folder admin-only (protected, no other ACE)' {
        $w = New-WinWorld
        [void](New-WinBackend $w)
        $acl = Get-Acl -LiteralPath $w.Journal
        $acl.AreAccessRulesProtected | Should -BeTrue
        @($acl.Access | ForEach-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } | Sort-Object -Unique) |
            Should -Be @(@('S-1-5-18', 'S-1-5-32-544', $script:UserSid) | Sort-Object -Unique)
    }

    It 'refuses relaxed trust for folders below ProgramData' {
        $w = New-WinWorld
        { New-AapWinBackend -Provider (New-WinProvider) -Network (New-WinNetwork) -AllocatorRoot $w.Cap -JournalRoot 'C:\ProgramData\aap-runner\capacity\journal' -StoragePath $w.StoragePath -RelaxedTrustForTests -WarningAction SilentlyContinue } |
            Should -Throw '*AAP_RelaxedRefused*'
    }

    It 'refuses storage document <Name>' -Tag 'storage-form', 'storage-nesting' -ForEach @(
        @{ Name = 'a relative root'; Tier = 'clone_root'; Path = 'aap\clones'; Like = '*AAP_StorageInvalid*clone_root*' }
        @{ Name = 'a drive root'; Tier = 'clone_root'; Path = 'E:\'; Like = '*AAP_StorageInvalid*clone_root*' }
        @{ Name = 'a UNC root'; Tier = 'scratch_root'; Path = '\\server\share\x'; Like = '*AAP_StorageInvalid*scratch_root*' }
        @{ Name = 'a reserved name'; Tier = 'scratch_root'; Path = 'E:\aap\aux .d'; Like = '*AAP_StorageInvalid*reserved*' }
        @{ Name = 'a trailing dot'; Tier = 'base_root'; Path = 'E:\aap\base.'; Like = '*AAP_StorageInvalid*trailing*' }
        @{ Name = 'a dot-dot component'; Tier = 'base_root'; Path = 'E:\aap\..\base'; Like = '*AAP_StorageInvalid*' }
        @{ Name = 'a stream'; Tier = 'base_root'; Path = 'E:\aap\base::$INDEX_ALLOCATION'; Like = '*AAP_StorageInvalid*' }
        @{ Name = 'clone inside base'; Tier = 'clone_root'; Path = '<base>\clones'; Like = '*AAP_StorageInvalid*clone_root is equal to or inside base_root*' }
        @{ Name = 'scratch equal to clone'; Tier = 'scratch_root'; Path = '<clone>'; Like = '*AAP_StorageInvalid*is equal to or inside*' }
        @{ Name = 'a root in the data folder'; Tier = 'scratch_root'; Path = 'C:\ProgramData\aap-runner\scratch'; Like = '*AAP_StorageInvalid*overlaps*' }
        @{ Name = 'a root holding C:\wsl'; Tier = 'scratch_root'; Path = 'C:\wsl\x'; Like = '*AAP_StorageInvalid*overlaps*' }
    ) {
        $w = New-WinWorld
        $doc = Get-Content -Raw $w.StoragePath | ConvertFrom-Json
        $doc.roots.$Tier.path = $Path.Replace('<base>', $w.Base).Replace('<clone>', $w.Clones)
        Write-WinJson $w.StoragePath $doc
        { New-WinBackend $w } | Should -Throw $Like
    }
}

Describe 'offline disk helpers (the production provider uses them)' {
    It 'writes the answer file through plain folders only, SYSTEM/Administrators-only, replacing an old one' -Tag 'guest-write', 'own-sid', 'unattend-root' {
        # An elevated run (the supervisor, a hosted CI runner) gets no entry for its own account; an unelevated test does.
        $admin = (New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        $sids = @(@('S-1-5-18', 'S-1-5-32-544') + @($(if (-not $admin) { $script:UserSid })) | Sort-Object -Unique)
        $pw = New-WinSecret 'Abc123-def456-Ghi789-jkl012-MNO3'
        $root = Join-Path $TestDrive 'disk1'
        [void][IO.Directory]::CreateDirectory($root)
        Write-AapWinUnattend -Root $root -UserName 'runneradmin' -Password $pw
        $file = "$root\Windows\Panther\unattend.xml"
        [IO.File]::ReadAllText($file) | Should -Match '<Value>Abc123-def456-Ghi789-jkl012-MNO3</Value>'
        foreach ($p in "$root\Windows", "$root\Windows\Panther", $file) {
            $acl = Get-Acl -LiteralPath $p
            $acl.AreAccessRulesProtected | Should -BeTrue -Because $p
            @($acl.Access | ForEach-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } | Sort-Object -Unique) |
                Should -Be $sids -Because $p
        }
        Write-AapWinUnattend -Root $root -UserName 'runneradmin' -Password (New-WinSecret 'Second-pass-word-0123456789-abcd')
        [IO.File]::ReadAllText($file) | Should -Match 'Second-pass-word'
        $outside = Join-Path $TestDrive 'outside1'
        [void][IO.Directory]::CreateDirectory($outside)
        $root2 = Join-Path $TestDrive 'disk2'
        [void][IO.Directory]::CreateDirectory("$root2\Windows")
        & cmd.exe /c mklink /J "$root2\Windows\Panther" $outside | Out-Null
        { Write-AapWinUnattend -Root $root2 -UserName 'runneradmin' -Password $pw } | Should -Throw '*AAP_UnsafePath: a link, not a plain folder*Panther'
        @(Get-ChildItem -LiteralPath $outside).Count | Should -Be 0
        $root3 = Join-Path $TestDrive 'disk3'
        [void][IO.Directory]::CreateDirectory("$root3\Windows\Panther")
        & cmd.exe /c mklink /J "$root3\Windows\Panther\unattend.xml" $outside | Out-Null
        { Write-AapWinUnattend -Root $root3 -UserName 'runneradmin' -Password $pw } | Should -Throw '*AAP_UnsafePath: a link where the answer file goes*'
        @(Get-ChildItem -LiteralPath $outside).Count | Should -Be 0
        # The provider's root is a volume mount point, a reparse point: taken as the root, never below it.
        $vol5 = Join-Path $TestDrive 'vol5'
        [void][IO.Directory]::CreateDirectory($vol5)
        & cmd.exe /c mklink /J "$TestDrive\mnt5" $vol5 | Out-Null
        Write-AapWinUnattend -Root "$TestDrive\mnt5" -UserName 'runneradmin' -Password $pw
        [IO.File]::ReadAllText("$vol5\Windows\Panther\unattend.xml") | Should -Match '<Value>Abc123-def456-Ghi789-jkl012-MNO3</Value>'
        $vol6 = Join-Path $TestDrive 'vol6'
        [void][IO.Directory]::CreateDirectory("$vol6\Windows")
        & cmd.exe /c mklink /J "$vol6\Windows\Panther" $outside | Out-Null
        & cmd.exe /c mklink /J "$TestDrive\mnt6" $vol6 | Out-Null
        { Write-AapWinUnattend -Root "$TestDrive\mnt6" -UserName 'runneradmin' -Password $pw } | Should -Throw '*AAP_UnsafePath: a link, not a plain folder*Panther'
        @(Get-ChildItem -LiteralPath $outside).Count | Should -Be 0
    }

    It 'production entries are SYSTEM and Administrators only: never the elevated owner account' -Tag 'own-sid' {
        $m = Get-Module AapWinBackend
        (& $m { New-AapWinSecurity $true $true }).GetSecurityDescriptorSddlForm('Access') | Should -BeExactly 'D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)'
        (& $m { New-AapWinSecurity $false $true }).GetSecurityDescriptorSddlForm('Access') | Should -BeExactly 'D:P(A;;FA;;;SY)(A;;FA;;;BA)'
        (& $m { New-AapWinSecurity $false $false }).GetSecurityDescriptorSddlForm('Access') | Should -BeExactly "D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FA;;;$($script:UserSid))"
    }

    It 'takes the Windows partition only from the EFI, MSR, data layout' -Tag 'disk-layout' {
        $efi = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'; $msr = '{e3c9e316-0b5c-4db8-817d-f92df00215ae}'; $data = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
        $p = { param($n, $t) [pscustomobject]@{ PartitionNumber = $n; GptType = $t } }
        (Select-AapWinPartition -Partitions @((& $p 1 $efi), (& $p 2 $msr), (& $p 3 $data))).PartitionNumber | Should -Be 3
        { Select-AapWinPartition -Partitions @((& $p 1 $efi), (& $p 2 $msr), (& $p 3 $data), (& $p 4 $data)) } | Should -Throw '*AAP_DiskLayout*'
        { Select-AapWinPartition -Partitions @((& $p 1 $efi), (& $p 2 $data), (& $p 3 $msr)) } | Should -Throw '*AAP_DiskLayout*'
        { Select-AapWinPartition -Partitions @() } | Should -Throw '*AAP_DiskLayout*'
    }

    It 'the answer file escapes the password, never enables autologon and keeps SanPolicy 1' {
        $root = Join-Path $TestDrive 'disk4'
        [void][IO.Directory]::CreateDirectory($root)
        Write-AapWinUnattend -Root $root -UserName 'runneradmin' -Password (New-WinSecret 'a<b&c"d''e>f')
        $xml = [IO.File]::ReadAllText("$root\Windows\Panther\unattend.xml")
        ([xml]$xml).unattend | Should -Not -BeNullOrEmpty
        $xml | Should -Match 'a&lt;b&amp;c&quot;d&apos;e&gt;f'
        $xml | Should -Not -Match 'AutoLogon'
        $xml | Should -Match '<SanPolicy>1</SanPolicy>'
        { Write-AapWinUnattend -Root $root -UserName 'bad name' -Password (New-WinSecret 'x') } | Should -Throw '*AAP_UnattendInvalid*'
    }
}
