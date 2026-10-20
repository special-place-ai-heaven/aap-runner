# create refuses, before any guest runs, everything backend-lifecycle.md forbids: untrusted roots (the admin-only
# definition), a base that is not the pinned one or not a plain file, a VM whose settings or files are off, a guest
# network other than P10.0's verified internal switch, host settings that open another way into a guest, a key pair or a
# seed that is not what it must be. Each refusal is journaled and frees the slot as never registered (held instead when the
# roots cannot prove the folders gone). Also the seed's content, the storage document, the journal folder and the
# backend context. Pester 5, Windows PowerShell 5.1 and PowerShell 7.5+.

BeforeAll {
    . (Join-Path $PSScriptRoot 'LinBackendTestHelpers.ps1')
    Import-Module $script:CapModule -Force
    Import-Module $script:BackendModule -Force

    # One create step in a fresh world after $Prepare; returns the result, the world and the journal's failure detail.
    function Invoke-LinCreate([scriptblock]$Prepare = {}, [hashtable]$Knobs = @{}, $Sha = $null) {
        $w = New-LinWorld
        Set-LinKnob $w $Knobs
        & $Prepare $w
        $B = New-LinBackend $w
        $r = New-LinReservation $w
        $pin = $(if ($null -ne $Sha) { $Sha } else { $w.BaseSha })
        $s = Invoke-AapLinStep -Backend $B -Reservation $r -BaseSha256 $pin
        $fail = @(Get-LinJournal $w $r.reservation_id | Where-Object { $_.op -eq 'create' -and $_.phase -eq 'failed' })
        [pscustomobject]@{ Step = $s; W = $w; B = $B; Res = (Get-LinRes $w $r.reservation_id); Detail = $(if ($fail.Count) { $fail[0].result.detail } else { '' }) }
    }
    # A refused create: freed as never registered, no VM left, nothing booted. -Held: a root that cannot prove absence (a
    # link, another volume) keeps the slot instead.
    function Assert-LinRefused($x, [string]$Like, [switch]$Held) {
        $x.Detail | Should -BeLike $Like
        if ($Held) { $x.Res.state | Should -Be 'creating'; $x.Step.Code | Should -Be 'folders_remain' }
        else {
            $x.Res.state | Should -Be 'reconciled'
            $x.Res.teardown_proof.runner_deregistered | Should -Be 'never_registered'
        }
        @(Get-LinVms $x.W).Count | Should -Be 0
        @(Get-LinCalls $x.W 'StartVm *').Count | Should -Be 0
        @(Get-ChildItem -LiteralPath $x.W.Clones).Count | Should -Be 0
    }
    function Grant-LinAce([string]$Path, [string]$Grant) { $o = & icacls.exe $Path /grant $Grant 2>&1; if ($LASTEXITCODE) { throw "icacls: $o" } }
}

Describe 'trusted roots only' {
    It 'clone_root with a read ACE for Everyone is refused: admin-only means no other ACE at all' -Tag 'admin-only', 'root-trust' {
        $x = Invoke-LinCreate { param($w) Grant-LinAce $w.Clones '*S-1-1-0:(R)' }
        Assert-LinRefused $x '*AAP_StorageUntrusted*clone_root*grants S-1-1-0 access*'
    }

    It 'base_root may grant read, never write or an inheritable ACE' -Tag 'no-write', 'root-trust' {
        $x = Invoke-LinCreate { param($w) Grant-LinAce $w.Base '*S-1-1-0:(R)' }
        $x.Step.Action | Should -Be 'created'
        foreach ($g in '*S-1-1-0:(W)', '*S-1-1-0:(OI)(CI)(R)') {
            $x = Invoke-LinCreate { param($w) Grant-LinAce $w.Base $g }
            Assert-LinRefused $x '*AAP_StorageUntrusted*base_root*write or inheritable*'
        }
    }

    It 'a root that inherits its DACL is refused' -Tag 'acl-protected', 'root-trust' {
        $x = Invoke-LinCreate { param($w) & icacls.exe $w.Scratch /inheritance:e | Out-Null }
        Assert-LinRefused $x '*AAP_StorageUntrusted*scratch_root*inherits*'
    }

    It 'a root that is a junction is refused, even to a well-protected folder' -Tag 'root-reparse', 'root-trust' {
        $x = Invoke-LinCreate { param($w)
            $real = Join-Path $w.Root 'real-clones'
            New-LinAclDir $real
            [IO.Directory]::Delete($w.Clones)
            & cmd.exe /c mklink /J $w.Clones $real | Out-Null
        }
        Assert-LinRefused $x '*AAP_StorageUntrusted*clone_root*reparse point*' -Held
    }

    It 'a junction above a root is refused' -Tag 'ancestor-reparse', 'root-trust' {
        $x = Invoke-LinCreate { param($w)
            $j = Join-Path $w.Root 'via'
            & cmd.exe /c mklink /J $j (Join-Path $w.Root 'roots') | Out-Null
            $doc = Get-Content -Raw $w.StoragePath | ConvertFrom-Json
            $doc.roots.scratch_root.path = Join-Path $j 'scratch'
            Write-LinJson $w.StoragePath $doc
        }
        Assert-LinRefused $x '*AAP_StorageUntrusted*scratch_root: reparse point above the root*'
    }

    It 'a root on another volume than recorded is refused' -Tag 'volume', 'root-trust' {
        $x = Invoke-LinCreate -Knobs @{ WrongVolume = 'scratch' }
        Assert-LinRefused $x '*AAP_StorageUntrusted*scratch_root: on volume*recorded*' -Held
    }

    It 'an owner outside the trusted SIDs is a problem' -Tag 'root-owner' {
        $w = New-LinWorld
        $B = New-LinBackend $w
        $B.TrustedSids = @('S-1-5-18', 'S-1-5-32-544')   # the test user, who owns the test roots, no longer trusted
        $p = @(Get-AapLinStorageProblem -Backend $B)
        @($p | Where-Object { $_ -like 'clone_root: owner * is not an admin: *' }).Count | Should -Be 1
    }

    It 'a path on a drive that is not a fixed local drive is a problem' -Tag 'fixed-drive' {
        $w = New-LinWorld
        $B = New-LinBackend $w
        $free = @([char[]]'QRSTUVWXYZ' | Where-Object { -not (Test-Path "$($_):\") })[0]
        $p = Invoke-LinInModule { param($B, $path) Get-AapLinTrustProblem $B $path } @($B, "$($free):\aap\clones")
        @($p | Where-Object { $_ -like '*not on a fixed local drive*' }).Count | Should -Be 1
    }
}

Describe 'the base' {
    It 'create needs the pinned hash' -Tag 'base-pin' {
        $x = Invoke-LinCreate -Sha ''
        Assert-LinRefused $x '*AAP_BaseUnpinned*'
        @(Get-LinCalls $x.W 'HashFile *').Count | Should -Be 0
    }

    It 'a base whose hash differs from the pin is refused' -Tag 'base-hash' {
        $x = Invoke-LinCreate -Knobs @{ HashOverride = ('0' * 64) }
        Assert-LinRefused $x '*AAP_BaseHashMismatch*'
    }

    It 'a base that is not a plain file is refused, whatever its hash' -Tag 'base-kind' {
        $x = Invoke-LinCreate { param($w) [IO.File]::SetAttributes($w.BaseFile, 'Normal'); [IO.File]::Delete($w.BaseFile); [void][IO.Directory]::CreateDirectory($w.BaseFile) } -Knobs @{ HashOverride = ('a' * 64) } -Sha ('a' * 64)
        Assert-LinRefused $x '*AAP_BaseMissing*'
    }

    It 'a generation folder reached through a junction is refused' -Tag 'plain-path' {
        $x = Invoke-LinCreate { param($w)
            $gen = Split-Path -Parent $w.BaseFile
            $real = Join-Path $w.Root 'elsewhere'
            [void][IO.Directory]::CreateDirectory($real)
            [IO.File]::SetAttributes($w.BaseFile, 'Normal')
            Copy-Item -LiteralPath $w.BaseFile -Destination $real
            [IO.Directory]::Delete($gen, $true)
            & cmd.exe /c mklink /J $gen $real | Out-Null
        }
        Assert-LinRefused $x '*AAP_BaseUntrusted*a link*'
    }

    It 'a base that is not sealed read-only (<Name>) is refused' -Tag 'base-sealed', 'sealed-acl', 'sealed-readonly' -ForEach @(
        @{ Name = 'generation folder inherits'; Like = '*AAP_BaseUntrusted: inherits its DACL*'; Prep = { param($w) & icacls.exe (Split-Path -Parent $w.BaseFile) /inheritance:e | Out-Null } }
        @{ Name = 'Users may write the base'; Like = '*AAP_BaseUntrusted: grants S-1-5-32-545 more than Virtual Machines read*'; Prep = { param($w) [IO.File]::SetAttributes($w.BaseFile, 'Normal'); & icacls.exe $w.BaseFile /grant '*S-1-5-32-545:(W)' | Out-Null; [IO.File]::SetAttributes($w.BaseFile, 'ReadOnly') } }
        @{ Name = 'Virtual Machines may write'; Like = '*AAP_BaseUntrusted: grants S-1-5-83-0 more*'; Prep = { param($w) [IO.File]::SetAttributes($w.BaseFile, 'Normal'); & icacls.exe $w.BaseFile /grant '*S-1-5-83-0:(M)' | Out-Null; [IO.File]::SetAttributes($w.BaseFile, 'ReadOnly') } }
        @{ Name = 'no ReadOnly attribute'; Like = '*AAP_BaseUntrusted: not ReadOnly*'; Prep = { param($w) [IO.File]::SetAttributes($w.BaseFile, 'Normal') } }
    ) {
        $x = Invoke-LinCreate $Prep
        Assert-LinRefused $x $Like
        @(Get-LinCalls $x.W 'HashFile *').Count | Should -Be 0
    }

    It 'a sealed entry owned by anyone but an admin is a problem' -Tag 'sealed-owner' {
        $w = New-LinWorld
        $B = New-LinBackend $w
        Invoke-LinInModule { param($B, $p) Get-AapLinSealedProblem $B $p } @($B, $w.BaseFile) | Should -BeNullOrEmpty
        $B.TrustedSids = @('S-1-5-18', 'S-1-5-32-544')   # the test user owns the test base
        Invoke-LinInModule { param($B, $p) Get-AapLinSealedProblem $B $p } @($B, $w.BaseFile) | Should -BeLike 'owner * is not an admin: *'
    }

    It 'the hash reads the backend''s own read handle, and a reused os.avhdx must be a child of the pinned base' -Tag 'disk-parent' {
        $x = Invoke-LinCreate
        $x.Step.Action | Should -Be 'created'
        $x = Invoke-LinCreate -Knobs @{ VhdParent = 'C:\elsewhere\base.vhdx' }
        Assert-LinRefused $x '*AAP_UnsafePath: os.avhdx is not a child of its generation''s base*'
        # The handle shares reading only: while create holds it nobody can write the base.
        $w = New-LinWorld
        $B = New-LinBackend $w
        $probe = Join-Path $w.Root 'probe.txt'
        $B.Provider.HashFile = { param($a)
            [IO.File]::SetAttributes($a.Path, 'Normal')   # attribute writes ignore share modes; opening for write does not
            $res = try { $f = [IO.File]::Open($a.Path, 'Open', 'ReadWrite', 'ReadWrite'); $f.Dispose(); 'writable' } catch { 'locked' }
            [IO.File]::SetAttributes($a.Path, 'ReadOnly')
            [IO.File]::WriteAllText($probe, $res)
            'mismatch'
        }.GetNewClosure()
        $r = New-LinReservation $w
        [void](Invoke-AapLinStep -Backend $B -Reservation $r -BaseSha256 $w.BaseSha)
        [IO.File]::ReadAllText($probe) | Should -Be 'locked'
        @(Get-LinJournal $w $r.reservation_id | Where-Object { $_.phase -eq 'failed' })[0].result.detail | Should -BeLike '*AAP_BaseHashMismatch*'
    }

    It 'a clone disk path that is already a folder is refused' -Tag 'disk-kind' {
        $w = New-LinWorld
        $B = New-LinBackend $w
        $r = New-LinReservation $w
        [void][IO.Directory]::CreateDirectory((Join-Path $w.Clones "$($r.reservation_id)\os.avhdx"))
        [void](Invoke-AapLinStep -Backend $B -Reservation $r -BaseSha256 $w.BaseSha)
        @(Get-LinJournal $w $r.reservation_id | Where-Object { $_.phase -eq 'failed' })[0].result.detail | Should -BeLike '*AAP_UnsafePath: os.avhdx is a dir*'
        @(Get-LinCalls $w 'NewVm *').Count | Should -Be 0
    }
}

Describe 'the host' {
    It 'refuses Enhanced Session Mode, a non-admin Hyper-V Administrator and an unreadable host' -Tag 'host-trust', 'enhanced-session', 'hyperv-admins' {
        Assert-LinRefused (Invoke-LinCreate -Knobs @{ EnhancedSession = $true }) '*AAP_EnhancedSession*'
        Assert-LinRefused (Invoke-LinCreate -Knobs @{ HyperVAdmins = @('S-1-5-21-1-2-3-1001') }) '*AAP_HyperVAdmins: S-1-5-21-1-2-3-1001 is a member*'
        Assert-LinRefused (Invoke-LinCreate -Knobs @{ HostFails = $true }) '*AAP_HostUnreadable*'
        (Invoke-LinCreate -Knobs @{ HyperVAdmins = @('S-1-5-32-544', 'S-1-5-18') }).Step.Action | Should -Be 'created'
        $w = New-LinWorld
        $B = New-LinBackend $w
        Get-AapLinHostProblem -Backend $B | Should -BeNullOrEmpty
    }
}

Describe 'the per-clone key and seed' {
    It 'the seed holds only public material: the job user (uid 1001, no uid 1000, no default user), the public key behind the forced agent command' -Tag 'seed-values' {
        $w = New-LinWorld
        $B = New-LinBackend $w
        $r = New-LinReservation $w
        $rid = $r.reservation_id
        [void](Invoke-AapLinStep -Backend $B -Reservation $r -BaseSha256 $w.BaseSha)
        $seed = Read-LinSeed (Join-Path $w.Clones "$rid\seed.iso")
        $seed.label | Should -BeExactly 'CIDATA'
        @($seed.files.PSObject.Properties.Name) -join ',' | Should -Be 'user-data,meta-data'
        $ud = [string]$seed.files.'user-data'
        $pub = ([IO.File]::ReadAllText((Join-Path $w.Clones "$rid\ssh\id_ed25519.pub")) -split ' ')[0..1] -join ' '
        $name = Get-AapVmName -Profile linux -Slot $r.slot -LeaseGeneration $r.lease_generation -ReservationId $rid
        $ud.StartsWith("#cloud-config`n") | Should -BeTrue
        $ud | Should -Match "(?m)^      restrict,command=`"/usr/local/libexec/aap-guest/agent`" $([regex]::Escape($pub)) aap-management$"
        $ud | Should -Match '(?m)^  - name: runner$'
        $ud | Should -Match '(?m)^    uid: 1001$'
        $ud | Should -Match '(?m)^    lock_passwd: true$'
        $ud | Should -Match '(?m)^ssh_pwauth: false$'
        $ud -cmatch 'uid: 1000|default|(?m)^ *passwd:|plain_text_passwd|hashed_passwd|ssh_keys:|PRIVATE|SYNTHETIC|JITCONFIG|jit_config' | Should -BeFalse
        @([regex]::Matches($ud, '(?m)^  - name: ')).Count | Should -Be 1
        $ud | Should -Match "(?m)^hostname: $name$"
        [string]$seed.files.'meta-data' | Should -Match "^instance-id: aap-$($rid.Substring(2))-$($r.lease_generation)-[0-9a-f]{8}`nlocal-hostname: $name`n\z"
        # The private key never left its folder.
        Find-LinSecret $w @('FAKE-PRIVATE-KEY') | Should -BeNullOrEmpty
        @(Find-LinSecret $w @('FAKE-PRIVATE-KEY') -All).Count | Should -Be 1
    }

    It 'New-AapLinSeed refuses a value it cannot vouch for' -Tag 'seed-values' {
        $pub = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI' + ('A' * 43)
        (New-AapLinSeed -VmName 'aap-l-1-1-0123abcd' -InstanceId 'aap-x' -PublicKey $pub).Keys -join ',' | Should -Be 'user-data,meta-data'
        foreach ($bad in @(@('aap-w-1-1-0123abcd', 'aap-x', $pub), @('aap-l-1-1-0123abcd', 'AAP X', $pub), @('aap-l-1-1-0123abcd', 'aap-x', ($pub + "`nruncmd: [reboot]")),
                @('aap-l-1-1-0123abcd', 'aap-x', 'ssh-rsa AAAAB3NzaC1yc2E'), @("aap-l-1-1-0123abcd`nruncmd", 'aap-x', $pub))) {
            { New-AapLinSeed -VmName $bad[0] -InstanceId $bad[1] -PublicKey $bad[2] } | Should -Throw '*AAP_SeedInvalid*'
        }
    }

    It 'a key pair ssh-keygen did not make, or a public key of another shape, is refused' -Tag 'key-shape' {
        Assert-LinRefused (Invoke-LinCreate -Knobs @{ KeyFails = $true }) '*AAP_KeyInvalid*'
        Assert-LinRefused (Invoke-LinCreate -Knobs @{ PublicOverride = 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQAB' }) '*AAP_KeyInvalid: ssh-keygen gave no ed25519 public key*'
        Assert-LinRefused (Invoke-LinCreate -Knobs @{ SeedFails = $true }) '*IMAPI2 failed*'
    }

    It 'a seed image whose bytes on disk are not the ones written (<How>) is refused before any VM exists' -Tag 'seed-written' -ForEach @(
        @{ How = 'short'; Hashed = 0 }, @{ How = 'stale'; Hashed = 1 }   # the size is checked first, then the re-read hash
    ) {
        $x = Invoke-LinCreate -Knobs @{ SeedLost = $How }
        Assert-LinRefused $x '*AAP_SeedInvalid: the seed image on disk is not the image that was written*'
        @(Get-LinCalls $x.W 'NewVm *').Count | Should -Be 0
        @(Get-LinCalls $x.W 'HashFile *seed.iso').Count | Should -Be $Hashed
    }

    It 'the ISO writer takes only full blocks from the image stream and returns the SHA-256 of what it wrote' {
        # A managed stand-in for IMAPI2's result stream (IStream::Read writes its count where pcbRead points): its read
        # number ShortAt hands out half a block before the end of the data.
        $src = @'
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
public class AapLinTestImageStream : IStream {
    byte[] data; int pos; int reads; int shortAt;
    public AapLinTestImageStream(byte[] data, int shortAt) { this.data = data; this.shortAt = shortAt; }
    public void Read(byte[] pv, int cb, IntPtr pcbRead) {
        reads++;
        int n = Math.Min(cb, data.Length - pos);
        if (reads == shortAt) n = Math.Min(n, cb / 2);
        Array.Copy(data, pos, pv, 0, n);
        pos += n;
        if (pcbRead != IntPtr.Zero) Marshal.WriteInt32(pcbRead, n);
    }
    public void Write(byte[] pv, int cb, IntPtr pcbWritten) { throw new NotSupportedException(); }
    public void Seek(long dlibMove, int dwOrigin, IntPtr plibNewPosition) { throw new NotSupportedException(); }
    public void SetSize(long libNewSize) { throw new NotSupportedException(); }
    public void CopyTo(IStream pstm, long cb, IntPtr pcbRead, IntPtr pcbWritten) { throw new NotSupportedException(); }
    public void Commit(int grfCommitFlags) { throw new NotSupportedException(); }
    public void Revert() { throw new NotSupportedException(); }
    public void LockRegion(long libOffset, long cb, int dwLockType) { throw new NotSupportedException(); }
    public void UnlockRegion(long libOffset, long cb, int dwLockType) { throw new NotSupportedException(); }
    // Qualified: .NET Framework also has an obsolete System.Runtime.InteropServices.STATSTG.
    public void Stat(out System.Runtime.InteropServices.ComTypes.STATSTG pstatstg, int grfStatFlag) { throw new NotSupportedException(); }
    public void Clone(out IStream ppstm) { throw new NotSupportedException(); }
}
'@
        $null = New-LinBackend (New-LinWorld)   # compiles AapLinIsoWriter, as the supervisor does at start
        if (-not ('AapLinTestImageStream' -as [type])) {
            $saved = $env:TMP, $env:TEMP
            $tmp = Join-Path $TestDrive 'compile'
            [void][IO.Directory]::CreateDirectory($tmp)
            try { $env:TMP = $tmp; $env:TEMP = $tmp; Add-Type -TypeDefinition $src } finally { $env:TMP, $env:TEMP = $saved }
        }
        $data = New-Object byte[] (3 * 2048)
        (New-Object Random 7).NextBytes($data)
        $iso = Join-Path $TestDrive 'full.iso'
        [AapLinIsoWriter]::Save((New-Object AapLinTestImageStream($data, 0)), $iso, 2048, 3) | Should -BeExactly (Get-LinSha $data)
        Get-LinSha ([IO.File]::ReadAllBytes($iso)) | Should -BeExactly (Get-LinSha $data)
        # A short read, in the middle or at an early end of the stream, fails the image instead of leaving stale bytes in it.
        { [AapLinIsoWriter]::Save((New-Object AapLinTestImageStream($data, 2)), (Join-Path $TestDrive 'middle.iso'), 2048, 3) } | Should -Throw '*AAP_SeedInvalid: a short read from the image stream*'
        { [AapLinIsoWriter]::Save((New-Object AapLinTestImageStream($data, 0)), (Join-Path $TestDrive 'end.iso'), 2048, 4) } | Should -Throw '*AAP_SeedInvalid: a short read from the image stream*'
    }

    It 'a re-run create (the clone never booted) makes a fresh key and seed, and reuses only its journaled VM' -Tag 'vm-journaled' {
        $w = New-LinWorld
        $B = New-LinBackend $w
        $r = New-LinReservation $w
        $rid = $r.reservation_id
        [void](Invoke-AapLinStep -Backend $B -Reservation $r -BaseSha256 $w.BaseSha)
        $pub1 = [IO.File]::ReadAllText((Join-Path $w.Clones "$rid\ssh\id_ed25519.pub"))
        # A crash before create/done: drop that record; a restarted supervisor re-runs create.
        $path = Join-Path $w.Journal "$rid.jsonl"
        [IO.File]::WriteAllText($path, ((@(Get-LinJournalLines $w $rid | Where-Object { $_ -notlike '*"phase":"done"*' }) -join "`n") + "`n"))
        $B2 = New-LinBackend $w
        (Invoke-AapLinStep -Backend $B2 -Reservation (Get-LinRes $w $rid) -BaseSha256 $w.BaseSha).Action | Should -Be 'created'
        @(Get-LinCalls $w 'NewVm *').Count | Should -Be 1
        $pub2 = [IO.File]::ReadAllText((Join-Path $w.Clones "$rid\ssh\id_ed25519.pub"))
        $pub2 | Should -Not -Be $pub1
        [string](Read-LinSeed (Join-Path $w.Clones "$rid\seed.iso")).files.'user-data' | Should -Match ([regex]::Escape(($pub2 -split ' ')[1]))
        # It still boots and reaches ready with the new key.
        @(Invoke-LinSteps $B2 $w $rid -Max 3 -Until { param($x) $x.state -eq 'ready' } | ForEach-Object { $_.Action }) -join ',' | Should -Be 'booted,ready'
    }

    It 'never adopts a VM found only by its name: create fails, the VM is destroyed, no second VM is made' -Tag 'vm-journaled' {
        $w = New-LinWorld
        $B = New-LinBackend $w
        $r = New-LinReservation $w
        $name = Get-AapVmName -Profile linux -Slot $r.slot -LeaseGeneration $r.lease_generation -ReservationId $r.reservation_id
        Save-LinVms $w @([pscustomobject]@{ Id = [guid]::NewGuid().ToString(); Name = $name; State = 'Off'; Cpus = 2; MemGib = 4; ConfigurationLocation = $w.Root })
        [void](Invoke-AapLinStep -Backend $B -Reservation $r -BaseSha256 $w.BaseSha)
        @(Get-LinJournal $w $r.reservation_id | Where-Object { $_.phase -eq 'failed' })[0].result.detail | Should -BeLike '*AAP_VmNotJournaled*'
        @(Get-LinCalls $w 'NewVm *').Count | Should -Be 0
        @(Get-LinVms $w).Count | Should -Be 0
        (Get-LinRes $w $r.reservation_id).state | Should -Be 'reconciled'
    }

    It 'reuses only the VM whose id the journal recorded: another VM under that name is refused' -Tag 'vm-journaled' {
        $w = New-LinWorld
        $B = New-LinBackend $w
        $r = New-LinReservation $w
        $rid = $r.reservation_id
        [void](Invoke-AapLinStep -Backend $B -Reservation $r -BaseSha256 $w.BaseSha)
        $path = Join-Path $w.Journal "$rid.jsonl"
        [IO.File]::WriteAllText($path, ((@(Get-LinJournalLines $w $rid | Where-Object { $_ -notlike '*"phase":"done"*' }) -join "`n") + "`n"))
        $vms = @(Get-LinVms $w); $vms[0].Id = [guid]::NewGuid().ToString(); Save-LinVms $w $vms
        $B2 = New-LinBackend $w
        [void](Invoke-AapLinStep -Backend $B2 -Reservation (Get-LinRes $w $rid) -BaseSha256 $w.BaseSha)
        @(Get-LinJournal $w $rid | Where-Object { $_.phase -eq 'failed' })[0].result.detail | Should -BeLike '*AAP_VmMismatch*'
        @(Get-LinCalls $w 'NewVm *').Count | Should -Be 1
    }
}

Describe 'the VM and its network' {
    It 'refuses VM setting <Field> = <Value>' -Tag 'vm-settings', 'vm-integration', 'vm-paths', 'vm-devices' -ForEach @(
        @{ Field = 'GuestServiceInterface'; Value = $true; Like = '*Guest Service Interface is on*' }
        @{ Field = 'KeyValuePairExchange'; Value = $false; Like = '*Key-Value Pair Exchange is off*' }
        @{ Field = 'SecureBoot'; Value = $false; Like = '*Secure Boot is not on*' }
        @{ Field = 'SecureBootTemplate'; Value = 'MicrosoftWindows'; Like = '*Secure Boot is not on*' }
        @{ Field = 'CheckpointType'; Value = 'Standard'; Like = '*checkpoints*' }
        @{ Field = 'AutomaticStopAction'; Value = 'Save'; Like = '*automatic start or stop*' }
        @{ Field = 'AutomaticStartAction'; Value = 'StartIfRunning'; Like = '*automatic start or stop*' }
        @{ Field = 'DynamicMemory'; Value = $true; Like = '*dynamic memory*' }
        @{ Field = 'NestedVirtualization'; Value = $false; Like = '*nested virtualization*' }
        @{ Field = 'Generation'; Value = 1; Like = '*generation 2*' }
        @{ Field = 'Cpus'; Value = 99; Like = '*CPU or memory*' }
        @{ Field = 'ConfigurationLocation'; Value = 'C:\ProgramData\Microsoft\Windows\Hyper-V'; Like = '*ConfigurationLocation is outside*' }
        @{ Field = 'SmartPagingFilePath'; Value = 'C:\ProgramData\Microsoft\Windows\Hyper-V'; Like = '*SmartPagingFilePath is outside*' }
        @{ Field = 'Disks'; Value = @('C:\other\os.avhdx'); Like = '*not exactly os.avhdx*' }
        @{ Field = 'Dvds'; Value = @('C:\other\seed.iso'); Like = '*DVD is not exactly the seed*' }
        @{ Field = 'ComPorts'; Value = 1; Like = '*ComPorts attached*' }
        @{ Field = 'GpuPartitions'; Value = 1; Like = '*GpuPartitions attached*' }
        @{ Field = 'AssignedDevices'; Value = 1; Like = '*AssignedDevices attached*' }
    ) {
        $x = Invoke-LinCreate -Knobs @{ VmOverride = @{ $Field = $Value } }
        Assert-LinRefused $x "*AAP_VmUntrusted*$($Like.Trim('*'))*"
        @(Get-LinCalls $x.W 'RemoveVm *').Count | Should -Be 1   # the VM it made is gone again
    }

    It 'refuses a VM with a disk create did not make, even inside the reservation folder' -Tag 'vm-devices' {
        Assert-LinRefused (Invoke-LinCreate -Knobs @{ ExtraDisk = $true }) '*AAP_VmUntrusted*not exactly os.avhdx*'
    }

    It 'refuses a guest adapter with <Case>' -Tag 'switch' -ForEach @(
        @{ Case = 'the Default Switch'; K = @{ NetSwitch = 'Default Switch' } }, @{ Case = 'an External switch'; K = @{ NetSwitchType = 'External' } }
        @{ Case = 'the Windows switch'; K = @{ NetSwitch = 'aap-guests-win' } }, @{ Case = 'no DHCP guard'; K = @{ NetDhcpGuard = $false } }
        @{ Case = 'no router guard'; K = @{ NetRouterGuard = $false } }, @{ Case = 'MAC spoofing'; K = @{ NetMacSpoofing = $true } }, @{ Case = 'no adapter at all'; K = @{ NetNoAdapter = $true } }
    ) {
        $x = Invoke-LinCreate -Knobs $K
        Assert-LinRefused $x '*AAP_NetworkUntrusted*'
    }

    It 'refuses when the network module''s own verification fails, or cannot look' -Tag 'network-verify' {
        Assert-LinRefused (Invoke-LinCreate -Knobs @{ NetProblems = @('port ACL missing: 169.254.0.0/16') }) '*AAP_NetworkUntrusted*port ACL missing*'
        Assert-LinRefused (Invoke-LinCreate -Knobs @{ VerifyThrows = $true }) '*AAP_NetworkUntrusted: the guest network cannot be verified*'
    }

    It 'without the P10.0 module every create fails closed' {
        $w = New-LinWorld
        $B = New-AapLinBackend -Provider (New-LinProvider) -Transport (New-LinGuest) -BrokerInvoker (New-LinBroker) -AllocatorRoot $w.Cap -JournalRoot $w.Journal `
            -StoragePath $w.StoragePath -LockTimeoutSeconds 5 -RelaxedTrustForTests -WarningAction SilentlyContinue -Sleep { param($s) }
        $r = New-LinReservation $w
        [void](Invoke-AapLinStep -Backend $B -Reservation $r -BaseSha256 $w.BaseSha)
        $x = [pscustomobject]@{ W = $w; Res = (Get-LinRes $w $r.reservation_id); Detail = @(Get-LinJournal $w $r.reservation_id | Where-Object { $_.phase -eq 'failed' })[0].result.detail }
        Assert-LinRefused $x '*AAP_NetworkUnavailable*'
    }

    It 'a failed create is never run again: while its folders will not go, the next step only tears down' -Tag 'no-recreate' {
        $w = New-LinWorld
        $B = New-LinBackend $w
        $r = New-LinReservation $w
        Set-LinKnob $w @{ NewVmFails = $true }
        [void][IO.Directory]::CreateDirectory((Join-Path $w.Clones $r.reservation_id))
        $h = [IO.File]::Open((Join-Path $w.Clones "$($r.reservation_id)\held.bin"), [IO.FileMode]::Create, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try { (Invoke-AapLinStep -Backend $B -Reservation $r -BaseSha256 $w.BaseSha).Code | Should -Be 'folders_remain' } finally { $h.Dispose() }
        Set-LinKnob $w @{ NewVmFails = $false }
        $B.Now = { [DateTime]::UtcNow.AddSeconds(60) }   # a teardown retry runs at most once a minute
        (Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $r.reservation_id) -BaseSha256 $w.BaseSha).Action | Should -Be 'destroyed'
        @(Get-LinCalls $w 'NewVm *').Count | Should -Be 1
        (Get-LinRes $w $r.reservation_id).teardown_proof.runner_deregistered | Should -Be 'never_registered'
    }

    It 'the seed must leave after first boot: an eject that fails or leaves a medium destroys the clone, never registered' {
        foreach ($k in @(@{ EjectFails = $true }, @{ EjectNoop = $true })) {
            $w = New-LinWorld
            $B = New-LinBackend $w
            Set-LinKnob $w $k
            $r = New-LinReservation $w
            $res = @(Invoke-LinSteps $B $w $r.reservation_id -Max 4)
            $res[-1].Action | Should -Be 'destroyed'
            @(Get-LinJournal $w $r.reservation_id | Where-Object { $_.op -eq 'ready' -and $_.phase -eq 'failed' })[0].result.detail |
                Should -BeLike $(if ($k.ContainsKey('EjectFails')) { '*Set-VMDvdDrive failed*' } else { '*AAP_VmUntrusted: a DVD medium is still attached*' })
            (Get-LinRes $w $r.reservation_id).teardown_proof.runner_deregistered | Should -Be 'never_registered'
            @(Get-LinLeases $w).Count | Should -Be 0
        }
    }

    It 'a pin that cannot be written as a plain file destroys the clone before any command' -Tag 'channel-file' {
        $w = New-LinWorld
        $B = New-LinBackend $w
        $r = New-LinReservation $w
        $rid = $r.reservation_id
        [void](Invoke-LinSteps $B $w $rid -Max 2)   # created, booted
        [void][IO.Directory]::CreateDirectory((Join-Path $w.Clones "$rid\ssh\known_hosts"))
        (Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid)).Action | Should -Be 'destroyed'
        @(Get-LinJournal $w $rid | Where-Object { $_.op -eq 'ready' -and $_.phase -eq 'failed' })[0].result.detail | Should -BeLike '*AAP_UnsafePath: a dir where a channel file goes*'
        @(Get-LinCalls $w 'Guest*').Count | Should -Be 0
    }
}

Describe 'the backend context' {
    It 'refuses a provider without every op' -Tag 'provider-ops' {
        $w = New-LinWorld
        foreach ($op in 'ListVms', 'GetHostKey', 'EjectSeed', 'NewKeyPair', 'NewSeedImage') {
            $p = New-LinProvider
            $p.Remove($op)
            { New-AapLinBackend -Provider $p -Network (New-LinNetwork) -AllocatorRoot $w.Cap -JournalRoot $w.Journal -StoragePath $w.StoragePath -RelaxedTrustForTests -WarningAction SilentlyContinue } |
                Should -Throw "*AAP_ProviderInvalid*$op*"
        }
    }

    It 'refuses a journal folder anyone else can read' -Tag 'journal-trust' {
        $w = New-LinWorld
        [void](New-LinBackend $w)
        Grant-LinAce $w.Journal '*S-1-5-32-545:(R)'
        { New-LinBackend $w } | Should -Throw '*AAP_JournalUntrusted*S-1-5-32-545*'
    }

    It 'refuses a compile folder anyone else can read (Add-Type''s temporary files go there)' -Tag 'compile-trust' {
        $w = New-LinWorld
        [void](New-LinBackend $w)
        Grant-LinAce (Join-Path $w.Journal 'compile') '*S-1-1-0:(R)'
        { New-LinBackend $w } | Should -Throw '*AAP_CompileUntrusted*S-1-1-0*'
    }

    It 'creates a missing journal folder admin-only (protected, no other ACE)' {
        $w = New-LinWorld
        [void](New-LinBackend $w)
        $acl = Get-Acl -LiteralPath $w.Journal
        $acl.AreAccessRulesProtected | Should -BeTrue
        @($acl.Access | ForEach-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } | Sort-Object -Unique) |
            Should -Be @(@('S-1-5-18', 'S-1-5-32-544', $script:UserSid) | Sort-Object -Unique)
    }

    It 'refuses relaxed trust for folders below ProgramData' {
        $w = New-LinWorld
        { New-AapLinBackend -Provider (New-LinProvider) -Network (New-LinNetwork) -AllocatorRoot $w.Cap -JournalRoot 'C:\ProgramData\aap-runner\capacity\journal' -StoragePath $w.StoragePath -RelaxedTrustForTests -WarningAction SilentlyContinue } |
            Should -Throw '*AAP_RelaxedRefused*'
    }

    It 'refuses to start without the relay beside the module' {
        $w = New-LinWorld
        $saved = Get-LinModuleVar 'RelayScript'
        Set-LinModuleVar 'RelayScript' (Join-Path $w.Root 'no-such-relay.ps1')
        try { { New-LinBackend $w } | Should -Throw '*AAP_RelayMissing*' } finally { Set-LinModuleVar 'RelayScript' $saved }
    }

    It 'refuses storage document <Name>' -Tag 'storage-form', 'storage-nesting' -ForEach @(
        @{ Name = 'a relative root'; Tier = 'clone_root'; Path = 'aap\clones'; Like = '*AAP_StorageInvalid*clone_root*' }
        @{ Name = 'a drive root'; Tier = 'clone_root'; Path = 'E:\'; Like = '*AAP_StorageInvalid*clone_root*' }
        @{ Name = 'a UNC root'; Tier = 'scratch_root'; Path = '\\server\share\x'; Like = '*AAP_StorageInvalid*scratch_root*' }
        @{ Name = 'a reserved name'; Tier = 'scratch_root'; Path = 'E:\aap\aux .d'; Like = '*AAP_StorageInvalid*reserved*' }
        @{ Name = 'a trailing dot'; Tier = 'base_root'; Path = 'E:\aap\base.'; Like = '*AAP_StorageInvalid*trailing*' }
        @{ Name = 'a dot-dot component'; Tier = 'base_root'; Path = 'E:\aap\..\base'; Like = '*AAP_StorageInvalid*' }
        @{ Name = 'a percent sign'; Tier = 'clone_root'; Path = 'E:\aap\%d'; Like = '*AAP_StorageInvalid*clone_root*' }
        @{ Name = 'a stream'; Tier = 'base_root'; Path = 'E:\aap\base::$INDEX_ALLOCATION'; Like = '*AAP_StorageInvalid*' }
        @{ Name = 'clone inside base'; Tier = 'clone_root'; Path = '<base>\clones'; Like = '*AAP_StorageInvalid*clone_root is equal to or inside base_root*' }
        @{ Name = 'scratch equal to clone'; Tier = 'scratch_root'; Path = '<clone>'; Like = '*AAP_StorageInvalid*is equal to or inside*' }
        @{ Name = 'a root in the data folder'; Tier = 'scratch_root'; Path = 'C:\ProgramData\aap-runner\scratch'; Like = '*AAP_StorageInvalid*overlaps*' }
        @{ Name = 'a root holding C:\wsl'; Tier = 'scratch_root'; Path = 'C:\wsl\x'; Like = '*AAP_StorageInvalid*overlaps*' }
    ) {
        $w = New-LinWorld
        $doc = Get-Content -Raw $w.StoragePath | ConvertFrom-Json
        $doc.roots.$Tier.path = $Path.Replace('<base>', $w.Base).Replace('<clone>', $w.Clones)
        Write-LinJson $w.StoragePath $doc
        { New-LinBackend $w } | Should -Throw $Like
    }
}
