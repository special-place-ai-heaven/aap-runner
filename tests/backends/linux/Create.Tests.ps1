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
    # A declaration as the P10.0 module returns it for a Linux clone (the shared fake's host), with $Change applied.
    function New-LinDecl([string]$Name, [hashtable]$Change = @{}) {
        $d = [ordered]@{ schema = 1; kind = 'host_network_attach'; vm_id = '6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b'; vm_name = $Name; profile = 'linux'
            subnet = '172.31.251.0/24'; gateway = '172.31.251.1'; address = '172.31.251.7'; resolvers = @('192.0.2.53', '198.51.100.53'); endpoints = @()
        }
        foreach ($k in $Change.Keys) { $d[$k] = $Change[$k] }
        $d
    }
    # The step that follows create (boot), with the guest network's fake host tampered or failing before it.
    function Invoke-LinBoot([string[]]$Tamper = @(), [string[]]$Fail = @()) {
        $w = New-LinWorld
        $B = New-LinBackend $w
        $r = New-LinReservation $w
        (Invoke-AapLinStep -Backend $B -Reservation $r -BaseSha256 $w.BaseSha).Action | Should -Be 'created'
        Set-AapFakeHostNetworkKnob -Root $w.Net -Tamper $Tamper -Fail $Fail
        $s = Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $r.reservation_id) -BaseSha256 $w.BaseSha
        Set-AapFakeHostNetworkKnob -Root $w.Net
        [pscustomobject]@{ Step = $s; W = $w; B = $B; Id = $r.reservation_id
            Detail = @(@(Get-LinJournal $w $r.reservation_id | Where-Object { $_.op -eq 'boot' -and $_.phase -eq 'failed' }) | ForEach-Object { $_.result.detail }) -join ' | '
        }
    }
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
        # Whoever owns the test roots is no longer trusted: the user when the session is not elevated, Administrators (the
        # default owner of an elevated token's files, as on the hosted runner) when it is. Only SYSTEM stays trusted.
        $B.TrustedSids = @('S-1-5-18')
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
        $B.TrustedSids = @('S-1-5-18')   # the owner of the test base (the user, or Administrators when elevated) is no longer trusted
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
        @($seed.files.PSObject.Properties.Name) -join ',' | Should -Be 'user-data,meta-data,network-config'
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
        $decl = New-LinDecl 'aap-l-1-1-0123abcd'
        (New-AapLinSeed -VmName 'aap-l-1-1-0123abcd' -InstanceId 'aap-x' -PublicKey $pub -Network $decl).Keys -join ',' | Should -Be 'user-data,meta-data,network-config'
        foreach ($bad in @(@('aap-w-1-1-0123abcd', 'aap-x', $pub), @('aap-l-1-1-0123abcd', 'AAP X', $pub), @('aap-l-1-1-0123abcd', 'aap-x', ($pub + "`nruncmd: [reboot]")),
                @('aap-l-1-1-0123abcd', 'aap-x', 'ssh-rsa AAAAB3NzaC1yc2E'), @("aap-l-1-1-0123abcd`nruncmd", 'aap-x', $pub))) {
            { New-AapLinSeed -VmName $bad[0] -InstanceId $bad[1] -PublicKey $bad[2] -Network $decl } | Should -Throw '*AAP_SeedInvalid*'
        }
    }

    It 'the network-config is the declaration''s static addressing, DHCP off, on the hv_netvsc interface' {
        $pub = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI' + ('A' * 43)
        $nc = (New-AapLinSeed -VmName 'aap-l-1-1-0123abcd' -InstanceId 'aap-x' -PublicKey $pub -Network (New-LinDecl 'aap-l-1-1-0123abcd'))['network-config']
        $nc | Should -BeExactly ((@('version: 2', 'ethernets:', '  aap0:', '    match:', '      driver: hv_netvsc', '    dhcp4: false', '    dhcp6: false', '    accept-ra: false',
                    '    link-local: []', '    addresses: [172.31.251.7/24]', '    routes:', '      - to: default', '        via: 172.31.251.1', '    nameservers:',
                    '      addresses: [192.0.2.53, 198.51.100.53]') -join "`n") + "`n")
    }

    It 'New-AapLinSeed writes no network-config from a declaration the shared check refuses (<Case>)' -Tag 'seed-network' -ForEach @(
        @{ Case = 'another VM name'; Change = @{ vm_name = 'aap-l-2-1-0123abcd' } }
        @{ Case = 'the Windows profile'; Change = @{ profile = 'windows' } }
        @{ Case = 'an address outside the subnet'; Change = @{ address = '172.31.252.7' } }
        @{ Case = 'the gateway as address'; Change = @{ address = '172.31.251.1' } }
        @{ Case = 'a YAML line in a resolver'; Change = @{ resolvers = @("192.0.2.53`n    dhcp4: true") } }
        @{ Case = 'a key too many'; Change = @{ dhcp = $true } }
    ) {
        $pub = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI' + ('A' * 43)
        { New-AapLinSeed -VmName 'aap-l-1-1-0123abcd' -InstanceId 'aap-x' -PublicKey $pub -Network (New-LinDecl 'aap-l-1-1-0123abcd' $Change) } | Should -Throw '*AAP_SeedInvalid: the network declaration*'
    }

    It 'New-AapLinSeed puts only dotted IPv4 addresses and a prefix length into the YAML, even past a shared check that accepts more (<Case>)' -Tag 'seed-yaml' -ForEach @(
        @{ Case = 'a YAML line in a resolver'; Change = @{ resolvers = @("192.0.2.53]`n    dhcp4: true`n#") } }
        @{ Case = 'a YAML line in the address'; Change = @{ address = "172.31.251.7/24]`n    dhcp4: true`n#" } }
        @{ Case = 'a hostname as gateway'; Change = @{ gateway = 'gw.example' } }
        @{ Case = 'a leading zero'; Change = @{ address = '172.31.251.07' } }
        @{ Case = 'an IPv6 address'; Change = @{ address = 'fd00::7' } }
        @{ Case = 'no prefix length'; Change = @{ subnet = '172.31.251.0' } }
        @{ Case = 'a prefix length that is not digits'; Change = @{ subnet = '172.31.251.0/24 # x' } }
        @{ Case = 'a subnet that is not an address'; Change = @{ subnet = 'x/24' } }
    ) {
        Mock -ModuleName AapLinBackend Get-AapHostNetworkDeclarationProblems { }
        $pub = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI' + ('A' * 43)
        (New-AapLinSeed -VmName 'aap-l-1-1-0123abcd' -InstanceId 'aap-x' -PublicKey $pub -Network (New-LinDecl 'aap-l-1-1-0123abcd')).Keys -join ',' | Should -Be 'user-data,meta-data,network-config'
        { New-AapLinSeed -VmName 'aap-l-1-1-0123abcd' -InstanceId 'aap-x' -PublicKey $pub -Network (New-LinDecl 'aap-l-1-1-0123abcd' $Change) } | Should -Throw '*AAP_NetworkInvalid*'
    }

    It 'a key pair ssh-keygen did not make, or a public key of another shape, is refused' -Tag 'key-shape' {
        Assert-LinRefused (Invoke-LinCreate -Knobs @{ KeyFails = $true }) '*AAP_KeyInvalid*'
        Assert-LinRefused (Invoke-LinCreate -Knobs @{ PublicOverride = 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQAB' }) '*AAP_KeyInvalid: ssh-keygen gave no ed25519 public key*'
        Assert-LinRefused (Invoke-LinCreate -Knobs @{ SeedFails = $true }) '*IMAPI2 failed*'
    }

    It 'a seed image whose bytes on disk are not the ones written (<How>) is refused before the VM gets it' -Tag 'seed-written' -ForEach @(
        @{ How = 'short'; Hashed = 0 }, @{ How = 'stale'; Hashed = 1 }   # the size is checked first, then the re-read hash
    ) {
        $x = Invoke-LinCreate -Knobs @{ SeedLost = $How }
        Assert-LinRefused $x '*AAP_SeedInvalid: the seed image on disk is not the image that was written*'
        @(Get-LinCalls $x.W 'SetSeed *').Count | Should -Be 0
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

    It 'create runs NewVm with no seed, Attach, the seed from the declaration into the DVD drive, then Verify; it keeps no copy' {
        $w = New-LinWorld
        $B = New-LinBackend $w
        $r = New-LinReservation $w
        $rid = $r.reservation_id
        (Invoke-AapLinStep -Backend $B -Reservation $r -BaseSha256 $w.BaseSha).Action | Should -Be 'created'
        $vm = @(Get-LinVms $w)[0]
        $order = @(Get-LinCalls $w | Where-Object { $_ -match '^(NewVm|NetAttach|NewSeedImage|SetSeed|NetVerify|StartVm) ' } | ForEach-Object { ($_ -split ' ')[0] })
        $order -join ',' | Should -Be 'NewVm,NetAttach,NewSeedImage,SetSeed,NetVerify'
        $decl = @(Get-AapFakeHostNetworkRecord -Root $w.Net -VmId $vm.Id)[0].declaration
        $nc = [string](Read-LinSeed (Join-Path $w.Clones "$rid\seed.iso")).files.'network-config'
        $nc | Should -Match "(?m)^    addresses: \[$([regex]::Escape($decl.address))/24\]$"
        $nc | Should -Match "(?m)^        via: $([regex]::Escape($decl.gateway))$"
        $nc | Should -Match "(?m)^      addresses: \[$([regex]::Escape(@($decl.resolvers) -join ', '))\]$"
        $nc | Should -Match '(?m)^    dhcp4: false$'
        $nc | Should -Not -Match 'dhcp4: true'
        @($vm.Dvds) | Should -Be @((Join-Path $w.Clones "$rid\seed.iso"))
        # The declaration lives in the module's journal only: never in the reservation's journal or the backend context.
        (@(Get-LinJournalLines $w $rid) -join "`n") | Should -Not -Match ([regex]::Escape($decl.address))
        # The guest boots with that address and nothing else: no DHCP serves it.
        @(Invoke-LinSteps $B $w $rid -Max 3 -Until { param($x) $x.state -eq 'ready' } | ForEach-Object { $_.Action }) -join ',' | Should -Be 'booted,ready'
        @(Get-LinVms $w)[0].Address | Should -BeExactly $decl.address
    }

    It 'refuses a create whose network the module''s Verify reports: <Tamper>' -Tag 'network-verify' -ForEach @(
        'no-adapter', 'second-adapter', 'external-switch', 'other-switch', 'dhcp-guard-off', 'router-guard-off', 'mac-spoofing-on', 'port-mirroring', 'vlan-trunk',
        'storm-limit-off', 'legacy-acl', 'foreign-peer', 'drop-fixed-deny', 'drop-inbound-deny', 'scoped-deny', 'stateful-rule', 'isolated-rule', 'no-source-pin',
        'pin-above-deny', 'extra-allow', 'public-host', 'host-empty', 'host-no-gateway', 'host-no-lan' | ForEach-Object { @{ Tamper = $_ } }
    ) {
        $x = Invoke-LinCreate -Prepare { param($w) Set-AapFakeHostNetworkKnob -Root $w.Net -Tamper $Tamper }.GetNewClosure()
        Assert-LinRefused $x '*AAP_NetworkUntrusted*'
        @(Get-AapFakeHostNetworkRecord -Root $x.W.Net).Count | Should -Be 0   # torn down: removed, then detached
    }

    It 'refuses a create when the module fails: <Fail>' -Tag 'network-verify' -ForEach @(
        @{ Fail = 'Attach'; Like = '*AAP_NetworkUntrusted: Attach failed*' }, @{ Fail = 'AttachAfterIntent'; Like = '*AAP_NetworkUntrusted: Attach failed*' }
        @{ Fail = 'AttachAfterAct'; Like = '*AAP_NetworkUntrusted: Attach failed*' }, @{ Fail = 'Verify'; Like = '*AAP_NetworkUntrusted: the guest network cannot be verified*' }
    ) {
        $x = Invoke-LinCreate -Prepare { param($w) Set-AapFakeHostNetworkKnob -Root $w.Net -Fail $Fail }.GetNewClosure()
        Assert-LinRefused $x $Like
        @(Get-AapFakeHostNetworkRecord -Root $x.W.Net).Count | Should -Be 0
    }

    It 'every object Verify writes is a problem: a $null after an empty problem list refuses the create' -Tag 'network-verify' {
        Assert-LinRefused (Invoke-LinCreate -Knobs @{ VerifyWritesNull = $true }) '*AAP_NetworkUntrusted*'
    }

    It 'the read-back is Hyper-V''s, through the provider, even when the module''s Verify passes: <Case>' -Tag 'network-readback' -ForEach @(
        @{ Case = 'no adapter'; Adapters = @() }
        @{ Case = 'an adapter with no fields'; Adapters = @(@{ SwitchName = 'aap-guests-linux' }) }
    ) {
        $x = Invoke-LinCreate -Knobs @{ VmOverride = @{ Adapters = $Adapters } }
        Assert-LinRefused $x '*AAP_NetworkUntrusted*'
        @(Get-LinCalls $x.W 'NetVerify *').Count | Should -BeGreaterThan 0
    }

    It 'refuses a declaration the shared check refuses: AAP_NetworkInvalid, nothing seeded' -Tag 'network-declaration' {
        $x = Invoke-LinCreate -Knobs @{ AttachDeclares = 'public-subnet' }
        Assert-LinRefused $x '*AAP_NetworkInvalid*'
        @(Get-LinCalls $x.W 'NewSeedImage *').Count | Should -Be 0
    }

    It 'a crash between Attach and the seed re-runs to one VM, one seed and the same declaration' {
        $w = New-LinWorld
        $r = New-LinReservation $w
        $rid = $r.reservation_id
        $c = Start-LinChild $w 'create:after-attach' $rid 1
        $c.ExitCode | Should -Be -1 -Because "stdout: $($c.Out) stderr: $($c.Err)"
        $vm = @(Get-LinVms $w)
        $vm.Count | Should -Be 1
        @($vm[0].Dvds).Count | Should -Be 0
        $first = @(Get-AapFakeHostNetworkRecord -Root $w.Net)[0].declaration.address
        $B = New-LinBackend $w
        (Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid) -BaseSha256 $w.BaseSha).Action | Should -Be 'created'
        @(Get-LinCalls $w 'NewVm *').Count | Should -Be 1
        @(Get-LinCalls $w 'NewSeedImage *').Count | Should -Be 1
        @(Get-AapFakeHostNetworkRecord -Root $w.Net).Count | Should -Be 1
        @(Get-AapFakeHostNetworkRecord -Root $w.Net)[0].declaration.address | Should -BeExactly $first
        [string](Read-LinSeed (Join-Path $w.Clones "$rid\seed.iso")).files.'network-config' | Should -Match "(?m)^    addresses: \[$([regex]::Escape($first))/24\]$"
        @(@(Get-LinVms $w)[0].Dvds) | Should -Be @((Join-Path $w.Clones "$rid\seed.iso"))
    }

    It 'a seed the provider cannot put in the VM''s one DVD drive refuses the create' {
        Assert-LinRefused (Invoke-LinCreate -Knobs @{ SetSeedFails = $true }) '*Set-VMDvdDrive failed*'
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

Describe 'the guest network before every start and while it runs' {
    It 'boot attaches again (the same declaration), checks it, verifies and reads back before StartVm' {
        $x = Invoke-LinBoot
        $x.Step.Action | Should -Be 'booted'
        $order = @(Get-LinCalls $x.W | Where-Object { $_ -match '^(NetAttach|NetVerify|StartVm) ' } | ForEach-Object { ($_ -split ' ')[0] })
        $order -join ',' | Should -Be 'NetAttach,NetVerify,NetAttach,NetVerify,StartVm'
        @(Get-AapFakeHostNetworkRecord -Root $x.W.Net).Count | Should -Be 1
    }

    It 'a start the network does not allow is refused (<Tamper><Fail>): StartVm never runs, the clone is torn down' -Tag 'network-verify' -ForEach @(
        @(@('no-adapter', 'second-adapter', 'external-switch', 'other-switch', 'dhcp-guard-off', 'router-guard-off', 'mac-spoofing-on', 'port-mirroring', 'vlan-trunk',
                'storm-limit-off', 'legacy-acl', 'foreign-peer', 'drop-fixed-deny', 'drop-inbound-deny', 'scoped-deny', 'stateful-rule', 'isolated-rule', 'no-source-pin',
                'pin-above-deny', 'extra-allow', 'public-host', 'host-empty', 'host-no-gateway', 'host-no-lan') | ForEach-Object { @{ Tamper = $_; Fail = '' } }) +
        @(@('Attach', 'AttachAfterIntent', 'AttachAfterAct', 'Verify') | ForEach-Object { @{ Tamper = ''; Fail = $_ } })
    ) {
        $x = Invoke-LinBoot -Tamper @($Tamper | Where-Object { $_ }) -Fail @($Fail | Where-Object { $_ })
        $x.Step.Action | Should -Be 'destroyed'
        $x.Detail | Should -BeLike '*AAP_Network*'
        @(Get-LinCalls $x.W 'StartVm *').Count | Should -Be 0
        @(Get-LinVms $x.W).Count | Should -Be 0
    }

    It 'a boot step that finds its VM running (started before a crash) verifies it, and stops it when Verify fails' -Tag 'boot-verify' {
        foreach ($t in @(@(), @('dhcp-guard-off'))) {
            $w = New-LinWorld
            $B = New-LinBackend $w
            $r = New-LinReservation $w
            [void](Invoke-AapLinStep -Backend $B -Reservation $r -BaseSha256 $w.BaseSha)
            $vms = @(Get-LinVms $w); $vms[0].State = 'Running'; Save-LinVms $w $vms
            $B.StatusSeconds = 3600; $B.NetAt[$r.reservation_id] = [DateTime]::UtcNow   # the running check is not due: only boot's
            Set-AapFakeHostNetworkKnob -Root $w.Net -Tamper $t
            $s = Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $r.reservation_id) -BaseSha256 $w.BaseSha
            @(Get-LinCalls $w 'NetAttach *').Count | Should -Be 1 -Because 'a running VM is never attached again'
            if ($t.Count) { $s.Action | Should -Be 'destroyed' } else { $s.Action | Should -Be 'booted' }
            @(Get-LinCalls $w 'StartVm *').Count | Should -Be 0
        }
    }

    It 'a running clone whose network Verify no longer accepts is stopped and torn down (<State>)' -Tag 'network-running' -ForEach @(
        @{ State = 'ready' }, @{ State = 'busy' }
    ) {
        $w = New-LinWorld
        Set-LinKnob $w @{ RunnerBusy = $true }
        $B = New-LinBackend $w
        $r = New-LinReservation $w
        $rid = $r.reservation_id
        [void](Invoke-LinSteps $B $w $rid -Max 5 -Until { param($x) $x.state -eq 'ready' })
        if ($State -eq 'busy') { (Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid)).Action | Should -Be 'running'; [void](Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid)) }
        (Get-LinRes $w $rid).state | Should -Be $State
        Set-AapFakeHostNetworkKnob -Root $w.Net -Tamper 'public-host'   # the host gained a public address: not certified
        $s = Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid)
        $s.Action | Should -Be 'destroyed'
        @(Get-LinJournal $w $rid | Where-Object { $_.phase -eq 'failed' })[0].result.detail | Should -Be 'network not verified'
        @(Get-LinVms $w).Count | Should -Be 0
        $B.NetAt.ContainsKey($rid) | Should -BeFalse -Because 'the throttle entry goes with the reservation'
    }
}

Describe 'the provider''s adapter names' {
    BeforeAll {
        Import-Module (Join-Path (Split-Path -Parent $script:BackendModule) 'AapLinBackend.HyperV.psm1') -Force
        $script:Me = '6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b'
        $script:Other = '00000000-0000-4000-8000-0000000000aa'
        function Get-LinNameProblem([object[]]$Adapters) { & (Get-Module AapLinBackend.HyperV) { param($v, $a) Get-AapLinAdapterNameProblem $v $a } $script:Me $Adapters }
    }

    It 'accepts the module''s adapter on its own VM beside other VMs'' adapters' {
        Get-LinNameProblem @(@{ Name = "aap-guest-$($script:Me)"; VmId = $script:Me }, @{ Name = "aap-guest-$($script:Other)"; VmId = $script:Other }, @{ Name = 'Network Adapter'; VmId = $script:Other }) |
            Should -BeNullOrEmpty
    }

    It 'an aap-guest-(vm id) adapter on another VM than the one it names' -Tag 'adapter-name-vm' {
        Get-LinNameProblem @(@{ Name = "aap-guest-$($script:Me)"; VmId = $script:Me }, @{ Name = "aap-guest-$($script:Me)" + [char]::ConvertFromUtf32(0x00AD); VmId = $script:Other }) |
            Should -BeLike '*sits on VM*'
    }

    It 'an aap-guest-(vm id) name that appears twice' -Tag 'adapter-name-dup' {
        @(Get-LinNameProblem @(@{ Name = "aap-guest-$($script:Me)"; VmId = $script:Me }, @{ Name = "aap-guest-$($script:Me)"; VmId = $script:Me })) | Should -Contain "the adapter name aap-guest-$($script:Me) appears more than once"
    }

    It 'an adapter of this VM under another name' -Tag 'adapter-name-own' {
        Get-LinNameProblem @(@{ Name = 'Network Adapter'; VmId = $script:Me }) | Should -BeLike "*is not aap-guest-$($script:Me)*"
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
