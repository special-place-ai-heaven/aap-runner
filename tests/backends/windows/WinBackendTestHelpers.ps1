# Fake world for the P10 Windows backend tests. Pester 5, Windows PowerShell 5.1 and PowerShell 7.5+.
# Real folders under the test drive for the storage roots, the journal and the allocator (the real AapCapacity.psm1 in
# relaxed trust), and file-backed fakes for Hyper-V (vms.json), the guest agent (guests\<vm id>.json), the broker (its
# -Invoker, leases.json) and the P10.0 network module (the shared strict fake, tests/common/AapHostNetworkFake.psm1, under
# fake\net), so a child process killed mid-step leaves the very world the parent then recovers from. Nothing here calls
# Hyper-V, wsl.exe or the network.
# The fakes resolve $w (the world) at call time from the calling scope, as P06's do: a test names its world $w.
# No secret is ever written: the fake broker keeps the SHA-256 of each JIT config, the fake disk the SHA-256 of the
# per-clone password, and the fake guest the SHA-256 and length of what it received. The password is the backend's
# secret object (Length, WriteTo, Clear); Get-WinSecretBytes reads it the way the call child does, from a stream.

$script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$script:BackendModule = $(if ($env:AAP_WINBACKEND_MODULE) { $env:AAP_WINBACKEND_MODULE } else { Join-Path $script:Repo 'supervisor\backends\windows\AapWinBackend.psm1' })
$script:SupervisorDir = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $script:BackendModule))
$script:CapModule = Join-Path $script:SupervisorDir 'capacity\AapCapacity.psm1'
Import-Module (Join-Path $script:Repo 'tests\common\AapHostNetworkFake.psm1')
$script:Validator = Join-Path $script:Repo 'parity\contracts\validate.py'
$script:WinGen = 'win25-vs2026-x64/20261007.264.1-aap.1'
$script:VolGuid = '00000000-0000-4000-8000-0000000000e1'
$script:OtherGuid = '00000000-0000-4000-8000-0000000000f2'
$script:UserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$script:Utf8 = New-Object Text.UTF8Encoding($false)
$script:GiB = 1073741824

function Get-WinSha([byte[]]$Bytes) {
    $h = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($h.ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant() } finally { $h.Dispose() }
}
function Get-WinSecretBytes($Secret) { $ms = New-Object IO.MemoryStream; $Secret.WriteTo($ms); , $ms.ToArray() }
# A secret object like New-AapWinPassword's, around a test value.
function New-WinSecret([string]$Text) {
    $bytes = [Text.Encoding]::ASCII.GetBytes($Text)
    $s = [pscustomobject]@{ Length = $bytes.Length }
    $s.PSObject.Methods.Add([Management.Automation.PSScriptMethod]::new('WriteTo', { param([IO.Stream]$Stream) $Stream.Write($bytes, 0, $bytes.Length) }.GetNewClosure()))
    $s.PSObject.Methods.Add([Management.Automation.PSScriptMethod]::new('Clear', { [Array]::Clear($bytes, 0, $bytes.Length) }.GetNewClosure()))
    $s
}
function ConvertFrom-WinJson([string]$Text) {
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { return , (ConvertFrom-Json -InputObject $Text -DateKind String) }
    , (ConvertFrom-Json -InputObject $Text)
}
function Read-WinJson([string]$Path, $Default) {
    if (-not [IO.File]::Exists($Path)) { return $Default }
    $t = [IO.File]::ReadAllText($Path)
    if (-not $t.Trim()) { return $Default }
    ConvertFrom-WinJson $t
}
function Write-WinJson([string]$Path, $Object) { [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Object -Depth 10 -Compress), $script:Utf8) }

# A folder with inheritance cut: SYSTEM, Administrators and the test user only (P09's New-CapRoot), so relaxed trust holds.
function New-WinAclDir([string]$Path) {
    [void][IO.Directory]::CreateDirectory($Path)
    $out = & icacls.exe $Path /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' "*$($script:UserSid):(OI)(CI)F" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "icacls failed: $out" }
}

function Set-WinModuleVar([string]$Name, $Value) { & (Get-Module AapWinBackend) { param($n, $v) Set-Variable -Scope Script -Name $n -Value $v } $Name $Value }
function Get-WinModuleVar([string]$Name) { & (Get-Module AapWinBackend) { param($n) Get-Variable -Scope Script -Name $n -ValueOnly } $Name }
function Invoke-WinInModule([scriptblock]$Block, [object[]]$ArgumentList = @()) { & (Get-Module AapWinBackend) $Block @ArgumentList }

# ---- the world -----------------------------------------------------------------------------------------------------

function New-WinWorld {
    param([int]$Windows = 1, [string]$Under = $TestDrive)
    $root = Join-Path $Under ('w' + [guid]::NewGuid().ToString('n').Substring(0, 10))
    $w = [pscustomobject]@{
        Root = $root; Base = (Join-Path $root 'roots\base'); Clones = (Join-Path $root 'roots\clones'); Scratch = (Join-Path $root 'roots\scratch')
        Cap = (Join-Path $root 'cap'); Journal = (Join-Path $root 'cap\journal'); Fake = (Join-Path $root 'fake'); StoragePath = (Join-Path $root 'storage.json')
        BaseFile = $null; BaseSha = $null; File = (Join-Path $root 'world.json')
    }
    [void][IO.Directory]::CreateDirectory((Join-Path $root 'roots'))
    foreach ($d in $w.Base, $w.Clones, $w.Scratch, $w.Cap) { New-WinAclDir $d }
    foreach ($d in $w.Fake, (Join-Path $w.Fake 'guests'), (Join-Path $w.Fake 'exchanges'), (Join-Path $w.Fake 'net\records'), (Join-Path $w.Fake 'net\host')) { [void][IO.Directory]::CreateDirectory($d) }
    $genDir = Join-Path $w.Base ($script:WinGen -replace '/', '\')
    [void][IO.Directory]::CreateDirectory($genDir)
    $w.BaseFile = Join-Path $genDir 'base.vhdx'
    [IO.File]::WriteAllText($w.BaseFile, 'fake sealed base disk')
    $w.BaseSha = (Get-FileHash -LiteralPath $w.BaseFile -Algorithm SHA256).Hash.ToLowerInvariant()
    # Sealed as P06 leaves it: protected DACL, no write for anyone but the admins (here: the test user), ReadOnly.
    New-WinAclDir $genDir
    $out = & icacls.exe $w.BaseFile /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' "*$($script:UserSid):F" '*S-1-5-83-0:RX' 2>&1
    if ($LASTEXITCODE -ne 0) { throw "icacls failed: $out" }
    [IO.File]::SetAttributes($w.BaseFile, [IO.FileAttributes]::ReadOnly)
    $roots = [ordered]@{
        base_root = [ordered]@{ path = $w.Base; volume_guid = $script:VolGuid }; clone_root = [ordered]@{ path = $w.Clones; volume_guid = $script:VolGuid }
        scratch_root = [ordered]@{ path = $w.Scratch; volume_guid = $script:VolGuid }; staging_root = $null
    }
    Write-WinJson $w.StoragePath ([ordered]@{ schema = 2; kind = 'storage'; volume_floor_gib = 10; roots = $roots })
    Write-WinJson (Join-Path $w.Fake 'vms.json') @()
    Write-WinJson (Join-Path $w.Fake 'leases.json') @()
    Write-WinJson (Join-Path $w.Fake 'knobs.json') @{}
    $hostInfo = @{ cpu_cores = 32; mem_gib = 96; io_mbps = 1000; control_distro_mem_gib = 1
        volumes = @(@{ volume_guid = $script:VolGuid; tiers = @('base', 'clone', 'scratch', 'staging'); available_gib = 2010; floor_gib = 10; held_gib = 0 })
    }
    foreach ($call in @(
            { Initialize-AapAllocator -Root $w.Cap -HostInfo $hostInfo -Linux 0 -Windows $Windows -RelaxedTrustForTests },
            { Set-AapProfileCounts -Root $w.Cap -Linux 0 -Windows $Windows -WindowsGeneration $script:WinGen -RelaxedTrustForTests },
            { Register-AapLegacySlots -Root $w.Cap -ManagerStopped -RelaxedTrustForTests })) {
        $r = & $call
        if (-not $r.Ok) { throw "allocator setup: $($r.Reason) $($r.Detail)" }
    }
    Write-WinJson $w.File $w
    $w
}

function Read-WinWorld([string]$File) { ConvertFrom-WinJson ([IO.File]::ReadAllText($File)) }

function Get-WinKnob($World, [string]$Name, $Default = $null) {
    $k = Read-WinJson (Join-Path $World.Fake 'knobs.json') $null
    if ($null -eq $k) { return $Default }
    $p = $k.PSObject.Properties[$Name]
    if ($null -eq $p) { return $Default }
    $p.Value
}
function Set-WinKnob($World, [hashtable]$Knobs) {
    $k = @{}
    $old = Read-WinJson (Join-Path $World.Fake 'knobs.json') $null
    if ($null -ne $old) { foreach ($p in $old.PSObject.Properties) { $k[$p.Name] = $p.Value } }
    foreach ($n in $Knobs.Keys) { $k[$n] = $Knobs[$n] }
    Write-WinJson (Join-Path $World.Fake 'knobs.json') $k
}
function Add-WinCall($World, [string]$Text) { [IO.File]::AppendAllText((Join-Path $World.Fake 'calls.log'), $Text + "`n") }
function Get-WinCalls($World, [string]$Like = '*') {
    $p = Join-Path $World.Fake 'calls.log'
    if (-not [IO.File]::Exists($p)) { return @() }
    @([IO.File]::ReadAllLines($p) | Where-Object { $_ -like $Like })
}
# A JSON array file as a flat list (Windows PowerShell's ConvertFrom-Json returns an array as one object).
function Read-WinList([string]$Path) { $x = Read-WinJson $Path @(); @($x | ForEach-Object { $_ } | Where-Object { $null -ne $_ }) }
function Get-WinVms($World) { Read-WinList (Join-Path $World.Fake 'vms.json') }
function Save-WinVms($World, $Vms) { Write-WinJson (Join-Path $World.Fake 'vms.json') @($Vms) }
function Get-WinLeases($World) { Read-WinList (Join-Path $World.Fake 'leases.json') }
function Save-WinLeases($World, $Leases) { Write-WinJson (Join-Path $World.Fake 'leases.json') @($Leases) }

# ---- fakes ---------------------------------------------------------------------------------------------------------

function New-WinProvider {
    $p = @{}
    $p.GetVolumeGuid = { param($a) $bad = Get-WinKnob $w 'WrongVolume' ''; if ($bad -and $a.Path -like "*$bad*") { return $script:OtherGuid }; $script:VolGuid }
    $p.GetHostSecurity = { param($a)
        if (Get-WinKnob $w 'HostFails' $false) { throw 'fake: Get-VMHost failed' }
        @{ EnhancedSessionMode = (Get-WinKnob $w 'EnhancedSession' $false); HyperVAdmins = [object[]]@(Get-WinKnob $w 'HyperVAdmins' @()) }
    }
    $p.HashFile = { param($a)
        Add-WinCall $w "HashFile $($a.Path)"
        if (-not ($a.Stream -is [IO.FileStream]) -or $a.Stream.CanWrite) { throw 'fake: HashFile needs the backend''s read handle' }
        $o = Get-WinKnob $w 'HashOverride' ''; if ($o) { return $o }; (Get-FileHash -LiteralPath $a.Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $p.NewDiffDisk = { param($a) Add-WinCall $w "NewDiffDisk $($a.Path) $($a.Parent)"; [IO.File]::WriteAllText($a.Path, 'differencing child of ' + $a.Parent) }
    $p.GetVhdParent = { param($a) $o = Get-WinKnob $w 'VhdParent' ''; if ($o) { return $o }; [IO.File]::ReadAllText($a.Path).Substring('differencing child of '.Length) }
    $p.NewDisk = { param($a) Add-WinCall $w "NewDisk $($a.Path) $($a.SizeBytes)"; [IO.File]::WriteAllText($a.Path, "dynamic vhdx max $($a.SizeBytes)") }
    $p.WriteUnattend = { param($a)
        # The real answer file's network part is Write-AapWinUnattend's (Create.Tests.ps1); here the call records what it got.
        Add-WinCall $w "WriteUnattend $($a.Vhdx) $($a.User) $($a.Network.address)/$($a.Network.subnet) via $($a.Network.gateway) dns $(@($a.Network.resolvers) -join ',')"
        if (Get-WinKnob $w 'UnattendFails' $false) { throw 'AAP_DiskLayout: fake mount failed' }
        if ($a.Password -is [string] -or $a.Password.Length -ne 32) { throw 'fake: the password is not a 32-character secret object' }
        if ($null -eq $a.Network) { throw 'fake: no network declaration' }
        $vm = @(Get-WinVms $w | Where-Object { $_.OsDisk -eq $a.Vhdx })
        if ($vm.Count -and $vm[0].State -ne 'Off') { throw 'fake: the clone disk is in use by a running VM' }
        [IO.File]::WriteAllText($a.Vhdx + '.cred', (Get-WinSha (Get-WinSecretBytes $a.Password)))
    }
    $p.NewVm = { param($a)
        Add-WinCall $w "NewVm $($a.Name)"
        if (Get-WinKnob $w 'NewVmFails' $false) { throw 'fake: New-VM failed' }
        $id = [guid]::NewGuid().ToString()
        $cfg = Join-Path $a.Path 'Virtual Machines'
        [void][IO.Directory]::CreateDirectory($cfg)
        [IO.File]::WriteAllText((Join-Path $cfg "$id.vmcx"), 'fake vm configuration')
        $vm = [ordered]@{ Id = $id; Name = $a.Name; State = 'Off'; Cpus = $a.Cpus; MemGib = $a.MemGib; Generation = 2; CheckpointType = 'Disabled'
            AutomaticStopAction = 'TurnOff'; AutomaticStartAction = 'Nothing'; GuestServiceInterface = $false; KeyValuePairExchange = $false
            ConfigurationLocation = $a.Path; SnapshotFileLocation = $a.Path; SmartPagingFilePath = $a.Path; Cred = ($a.OsDisk + '.cred'); OsDisk = $a.OsDisk
            Disks = @(@($a.OsDisk, $a.ScratchDisk) | Where-Object { $_ }); Adapters = @(); ComPorts = 0; DvdDrives = 0; GpuPartitions = 0; AssignedDevices = 0
        }
        if (Get-WinKnob $w 'ExtraDisk' $false) { $vm.Disks = @($vm.Disks) + (Join-Path $a.Path 'extra.vhdx') }
        $o = Get-WinKnob $w 'VmOverride' $null
        if ($null -ne $o) { foreach ($q in $o.PSObject.Properties) { $vm[$q.Name] = $q.Value } }
        Save-WinVms $w (@(Get-WinVms $w) + [pscustomobject]$vm)
        @{ Id = $id.ToUpperInvariant() }
    }
    $p.GetVmConfig = { param($a)
        $v = @(Get-WinVms $w | Where-Object { $_.Id -eq $a.VmId })[0]
        # Its adapters as Hyper-V would report them, in the contract's provider read-back shape (the shared fake's view).
        if ($null -ne $v) { $v.Adapters = @(Get-AapFakeHostNetworkAdapter -Root (Join-Path $w.Fake 'net') -VmId $a.VmId) }
        $v
    }
    $p.StartVm = { param($a)
        Add-WinCall $w "StartVm $($a.VmId)"
        if (Get-WinKnob $w 'StartFails' $false) { throw 'fake: Start-VM failed' }
        $vms = @(Get-WinVms $w); foreach ($v in $vms) { if ($v.Id -eq $a.VmId) { $v.State = 'Running' } }; Save-WinVms $w $vms
    }
    $p.StopVm = { param($a) Add-WinCall $w "StopVm $($a.VmId)"; $vms = @(Get-WinVms $w); foreach ($v in $vms) { if ($v.Id -eq $a.VmId) { $v.State = 'Off' } }; Save-WinVms $w $vms }
    $p.RemoveVm = { param($a)
        Add-WinCall $w "RemoveVm $($a.VmId)"
        if (Get-WinKnob $w 'RemoveVmFails' $false) { throw 'fake: Remove-VM failed' }
        $vm = @(Get-WinVms $w | Where-Object { $_.Id -eq $a.VmId })
        foreach ($v in $vm) { $f = Join-Path $v.ConfigurationLocation "Virtual Machines\$($v.Id).vmcx"; if ([IO.File]::Exists($f)) { [IO.File]::Delete($f) } }
        Save-WinVms $w @(Get-WinVms $w | Where-Object { $_.Id -ne $a.VmId })
    }
    $p.ListVms = { param($a)
        if (Get-WinKnob $w 'ListFails' $false) { throw 'fake: Get-VM failed (access denied)' }
        @(Get-WinVms $w | ForEach-Object { @{ Id = $_.Id; Name = $_.Name; State = $(if (Get-WinKnob $w 'Paused' $false) { 'Paused' } else { $_.State }); Cpus = $_.Cpus; MemGib = $_.MemGib } })
    }
    $p.MeasureBytes = { param($a) if (Get-WinKnob $w 'MeasureFails' $false) { throw 'access denied' }; [double](Get-WinKnob $w 'CloneBytes' $script:GiB) }
    $p
}

# The network module: the shared strict fake (host-network-module.md, Shared fake) over this world's VMs, its tampers and
# faults set with Set-WinNet. Each call is logged. Knobs stand for a module that lies, which the backend must not trust:
# 'NetDecl' (fields merged into the declaration Attach returns), 'NetVerifySilent' (Verify writes nothing),
# 'NetVerifyOut' (what Verify writes instead of its own answer; '<null>' writes a null) and 'NetVerifyError' (Verify writes
# a non-terminating error and nothing else). 'NetForeign' is the count of the VM's adapters the module did not make.
function Get-WinNet($World) {
    New-AapFakeHostNetwork -Root (Join-Path $World.Fake 'net') -Vm { param($id)
        $v = @(Get-WinVms $w | Where-Object { $_.Id -eq $id })
        if (-not $v.Count) { return $null }
        @{ State = [string]$v[0].State; Adapters = [int](Get-WinKnob $w 'NetForeign' 0) }
    }
}
function Set-WinNet($World, [string[]]$Tamper = @(), [string[]]$Fail = @()) { Set-AapFakeHostNetworkKnob -Root (Join-Path $World.Fake 'net') -Tamper $Tamper -Fail $Fail }
function Get-WinNetRecords($World) { @(Get-AapFakeHostNetworkRecord -Root (Join-Path $World.Fake 'net')) }
function New-WinNetwork {
    @{
        Attach = { param($a)
            Add-WinCall $w "NetAttach $($a.VmId) $($a.Profile)"
            $d = & (Get-WinNet $w).Attach $a
            $edit = Get-WinKnob $w 'NetDecl' $null
            if ($null -eq $edit) { return $d }
            $o = [ordered]@{}
            foreach ($q in $d.PSObject.Properties) { $o[$q.Name] = $q.Value }
            foreach ($q in $edit.PSObject.Properties) { $o[$q.Name] = $q.Value }
            [pscustomobject]$o
        }
        Detach = { param($a) Add-WinCall $w "NetDetach $($a.VmId)"; & (Get-WinNet $w).Detach $a }
        Verify = { param($a)
            Add-WinCall $w "NetVerify $($a.VmId)"
            if (Get-WinKnob $w 'NetVerifySilent' $false) { return }
            if (Get-WinKnob $w 'NetVerifyError' $false) { Write-Error 'fake: Verify could not read a port ACL' -ErrorAction Continue; return }
            $out = Get-WinKnob $w 'NetVerifyOut' $null
            if ($null -eq $out) { & (Get-WinNet $w).Verify $a } else { foreach ($o in @($out)) { if ($o -ceq '<null>') { $null } else { $o } } }
        }
    }
}

# The guest agent of guest-transport.md, file-backed per VM: it refuses a wrong vm_id, a lease generation other than the
# first it saw, a seq not strictly greater than the last one it accepted (guest-transport.md, Sequence rule: gaps are
# fine), a reused nonce, an expired command and a second one-shot command. Knob 'Guest' maps a command (or '*') to a misbehaviour; 'NotUp' is a
# count of calls that find no PowerShell Direct yet (the agent never sees them); 'LoseReply' a count of calls the agent
# accepts whose reply never arrives.
function New-WinGuest {
    {
        param($Call)
        $hc = ConvertFrom-WinJson $Call.Envelope
        $payload = [byte[]]@()
        if ($Call.PayloadLength -gt 0) { $ms = New-Object IO.MemoryStream; & $Call.WritePayload $ms; $payload = $ms.ToArray() }
        $none = @{ ExitCode = 0; Stdout = [byte[]]@(); TimedOut = $false; Overflow = $false }
        $vm = @(Get-WinVms $w | Where-Object { $_.Id -eq $Call.VmId })
        if (-not $vm.Count -or $vm[0].State -ne 'Running') { return $none }
        $notUp = [int](Get-WinKnob $w 'NotUp' 0)
        if ($notUp -gt 0) { Set-WinKnob $w @{ NotUp = $notUp - 1 }; return $none }
        $cred = [IO.File]::ReadAllText($vm[0].Cred)
        if ((Get-WinSha (Get-WinSecretBytes $Call.Password)) -ne $cred) { Add-WinCall $w "GuestAuthRefused $($Call.VmId)"; return $none }
        $sf = Join-Path $w.Fake "guests\$($Call.VmId).json"
        $st = Read-WinJson $sf ([pscustomobject]@{ Seq = 0; Gen = 0; Nonces = @(); Shots = @(); Probes = 0; PayloadSha = ''; PayloadLen = 0 })
        $status = 'ok'; $state = 'booting'; $exit = $null; $diag = ''
        $shot = @('deliver_registration', 'start_runner', 'shutdown') -contains $hc.cmd
        $expired = [DateTime]::ParseExact($hc.expires_at, "yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture, 'AssumeUniversal, AdjustToUniversal') -lt [DateTime]::UtcNow.AddSeconds([double](Get-WinKnob $w 'ClockOffset' 0) - 5)
        if ($hc.vm_id -ne $Call.VmId -or ($st.Gen -and $st.Gen -ne $hc.lease_generation) -or $hc.seq -le $st.Seq -or @($st.Nonces) -contains $hc.nonce -or
            ($shot -and @($st.Shots) -contains $hc.cmd) -or $expired) {
            $status = 'refused'; $diag = 'refused by the agent'
        } else {
            $st.Seq = $hc.seq; $st.Gen = $hc.lease_generation; $st.Nonces = @($st.Nonces) + $hc.nonce
            if ($shot) { $st.Shots = @($st.Shots) + $hc.cmd }
            switch ($hc.cmd) {
                'probe' { $st.Probes++; $state = $(if ($st.Probes -gt [int](Get-WinKnob $w 'BootProbes' 0)) { 'ready' } else { 'booting' }) }
                'deliver_registration' { $st.PayloadSha = Get-WinSha $payload; $st.PayloadLen = $payload.Length; $state = 'registered'; $diag = 'bootstrap material removed' }
                'start_runner' { $state = 'listening'; $diag = 'runner started from env input' }
                'status' { $state = Get-WinKnob $w 'GuestStatus' 'listening' }
                'collect' { $state = 'job_done'; $exit = 0; $diag = 'job summary: 1 job, exit 0' }
            }
        }
        Write-WinJson $sf $st
        $lose = [int](Get-WinKnob $w 'LoseReply' 0)
        if ($lose -gt 0) { Set-WinKnob $w @{ LoseReply = $lose - 1 }; return $none }
        $reply = [ordered]@{ schema = 1; kind = 'guest_reply'; vm_id = $hc.vm_id; reservation_id = $hc.reservation_id; lease_generation = $hc.lease_generation
            seq = $hc.seq; nonce = $hc.nonce; status = $status; guest_state = $state; runner_exit_code = $exit; diag = $diag
        }
        $how = Get-WinKnob $w 'Guest' $null
        $bad = $null
        if ($null -ne $how) { foreach ($k in @($hc.cmd, '*')) { $q = $how.PSObject.Properties[$k]; if ($null -ne $q -and $null -eq $bad) { $bad = [string]$q.Value } } }
        $text = $null
        switch -Wildcard ($bad) {
            'timeout' { return @{ ExitCode = $null; Stdout = $null; TimedOut = $true; Overflow = $false } }
            'overflow' { return @{ ExitCode = $null; Stdout = $null; TimedOut = $false; Overflow = $true } }
            'exit' { return @{ ExitCode = 3; Stdout = [byte[]]@(); TimedOut = $false; Overflow = $false } }
            'silent' { return $none }
            'oversized' { $reply.diag = 'x' * 512; $text = (ConvertTo-Json $reply -Compress) + (' ' * 8000) }
            'extra' { $reply.extra = 1 }
            'missing' { $reply.Remove('diag') }
            'echo-*' { $f = $bad.Substring(5); $reply[$f] = $(switch ($f) { 'vm_id' { [guid]::NewGuid().ToString() } 'reservation_id' { 'r-00000000000000ff' } 'nonce' { 'f' * 32 } default { [long]$reply[$f] + 1 } }) }
            'nonprintable' { $reply.diag = 'ESCMARK' }
            'badjson' { $text = '{"schema":1,"kind":"guest_reply"' }
            'dupkey' { $text = (ConvertTo-Json $reply -Compress).TrimEnd('}') + ',"diag":"again"}' }
            'nested' { $reply.diag = 'x'; $text = (ConvertTo-Json $reply -Compress).TrimEnd('}') + ',"x":{"a":{"b":{"c":{"d":1}}}}}' }
            'badvalue' { $reply.status = 'maybe' }
            'state' { $reply.guest_state = 'busy' }
            'secret' { $reply.diag = 'SYNTHETIC-JIT-MARKER-' + 'echoed' }
            'refuse' { $reply.status = 'refused' }
            'hostui' { $text = 'WARNING: a remote host call' + "`n" + (ConvertTo-Json $reply -Compress) }
        }
        if ($null -eq $text) { $text = ConvertTo-Json $reply -Compress }
        $bytes = $script:Utf8.GetBytes($text + "`n")
        if ($bad -eq 'nonprintable') { $bytes[$text.IndexOf('ESCMARK')] = 7 }
        if ($null -eq $bad -or $bad -eq 'refuse') {
            $x = [ordered]@{ schema = 1; kind = 'exchange'; cmd = (ConvertFrom-WinJson $Call.Envelope); reply = (ConvertFrom-WinJson ($text)) }
            Write-WinJson (Join-Path $w.Fake ('exchanges\' + [guid]::NewGuid().ToString('n') + '.json')) $x
        }
        @{ ExitCode = 0; Stdout = $bytes; TimedOut = $false; Overflow = $false }
    }
}

# The broker, behind aap-broker.psm1's -Invoker: a lease ledger in leases.json (no JIT value, only its hash).
function New-WinBroker {
    {
        param([byte[]]$Bytes, [int]$Timeout)
        $req = ConvertFrom-WinJson ([Text.Encoding]::ASCII.GetString($Bytes))
        $out = { param($o) [pscustomobject]@{ ExitCode = 0; Stdout = [Text.Encoding]::ASCII.GetBytes((ConvertTo-Json -InputObject $o -Compress)); TimedOut = $false; Overflow = $false } }
        $down = [pscustomobject]@{ ExitCode = 1; Stdout = [byte[]]@(); TimedOut = $false; Overflow = $false }
        $leases = @(Get-WinLeases $w)
        $l = @($leases | Where-Object { $_.lease_id -eq $req.lease_id })[0]
        Add-WinCall $w "Broker $($req.kind) $($req.lease_id)"
        switch ($req.kind) {
            'lease_request' {
                $how = Get-WinKnob $w 'LeaseOutcome' 'issued'
                if ($how -eq 'unavailable') { return $down }
                if ($how -eq 'bad_reply') { return [pscustomobject]@{ ExitCode = 0; Stdout = [Text.Encoding]::ASCII.GetBytes('not json'); TimedOut = $false; Overflow = $false } }
                $base = [ordered]@{ schema = 1; kind = 'lease_response'; lease_id = $req.lease_id; result = 'refused'; reason = 'replay'; runner_id = $null; runner_name = $null; expires_at = $null; jit_config = $null }
                if ($null -ne $l) { return (& $out $base) }
                $name = 'aap-w-{0}-{1}-{2}' -f $req.slot, $req.lease_generation, $req.reservation_id.Substring(2, 8)
                if ($how -eq 'refused') {
                    Save-WinLeases $w ($leases + [pscustomobject]@{ lease_id = $req.lease_id; reservation_id = $req.reservation_id; state = 'refused'; runner_name = $name; jit_sha = '' })
                    $base.reason = 'github_error'
                    return (& $out $base)
                }
                if ($how -eq 'wrong_name') { $name = 'aap-w-5-{0}-{1}' -f $req.lease_generation, $req.reservation_id.Substring(2, 8) }
                $jit = 'SYNTHETIC-JIT-MARKER-' + [guid]::NewGuid().ToString('n')
                Save-WinLeases $w ($leases + [pscustomobject]@{ lease_id = $req.lease_id; reservation_id = $req.reservation_id; state = 'issued'; runner_name = $name; jit_sha = (Get-WinSha ([Text.Encoding]::ASCII.GetBytes($jit))) })
                $base.result = 'issued'; $base.reason = 'ok'; $base.runner_id = 4242; $base.runner_name = $name
                $base.expires_at = [DateTime]::UtcNow.AddMinutes(10).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture); $base.jit_config = $jit
                return (& $out $base)
            }
            'release_request' {
                $how = Get-WinKnob $w 'ReleaseOutcome' 'normal'
                if ($how -eq 'unavailable') { return $down }
                $res = [ordered]@{ schema = 1; kind = 'release_response'; lease_id = $req.lease_id; result = 'retry'; reason = 'github_error' }
                if ($how -eq 'retry') { return (& $out $res) }
                if ($how -eq 'clock_skew') { $res.result = 'refused'; $res.reason = 'clock_skew'; return (& $out $res) }
                if ($null -eq $l -or $how -eq 'not_found') { $res.result = 'refused'; $res.reason = 'not_found'; return (& $out $res) }
                $res.reason = 'ok'
                if ($l.state -eq 'issued') { $l.state = 'released'; $res.result = 'deregistered' } else { $l.state = 'released'; $res.result = 'already_gone' }
                Save-WinLeases $w $leases
                return (& $out $res)
            }
            'status_request' {
                $how = Get-WinKnob $w 'StatusOutcome' 'ok'
                # StatusAfterStatus: this answer is normal, the next ones are that outcome.
                if (Get-WinKnob $w 'StatusAfterStatus' $null) { Set-WinKnob $w @{ StatusOutcome = (Get-WinKnob $w 'StatusAfterStatus' $null); StatusAfterStatus = $null } }
                if ($how -eq 'unavailable') { return $down }
                if ($how -eq 'timeout') { return [pscustomobject]@{ ExitCode = $null; Stdout = $null; TimedOut = $true; Overflow = $false } }
                if ($how -eq 'bad_reply') { return [pscustomobject]@{ ExitCode = 0; Stdout = [Text.Encoding]::ASCII.GetBytes('{"schema":1,"kind":"status_response"'); TimedOut = $false; Overflow = $false } }
                $res = [ordered]@{ schema = 1; kind = 'status_response'; lease_id = $req.lease_id; result = 'refused'; reason = 'not_found'; runner = $null }
                if ($null -eq $l) { return (& $out $res) }
                $res.result = 'ok'; $res.reason = 'ok'
                if ($l.state -ne 'issued') { $res.runner = [ordered]@{ status = 'absent'; busy = $false } }
                else { $res.runner = [ordered]@{ status = (Get-WinKnob $w 'RunnerStatus' 'online'); busy = [bool](Get-WinKnob $w 'RunnerBusy' $false) } }
                # BusyAfterStatus: this answer says idle, and a job starts right after it.
                if (Get-WinKnob $w 'BusyAfterStatus' $false) { Set-WinKnob $w @{ BusyAfterStatus = $false; RunnerBusy = $true } }
                return (& $out $res)
            }
        }
        $down
    }
}

# ---- driving it ----------------------------------------------------------------------------------------------------

# The status cadence is off (StatusSeconds 0) so every step heartbeats; one test puts it back.
function New-WinBackend($World) {
    $w = $World
    $B = New-AapWinBackend -Provider (New-WinProvider) -Network (New-WinNetwork) -Transport (New-WinGuest) -BrokerInvoker (New-WinBroker) `
        -AllocatorRoot $w.Cap -JournalRoot $w.Journal -StoragePath $w.StoragePath -LockTimeoutSeconds 5 -RelaxedTrustForTests -WarningAction SilentlyContinue `
        -Clock { [DateTime]::UtcNow.AddSeconds([double](Get-WinKnob $w 'ClockOffset' 0)) } -Sleep { param($s) }
    $B.StatusSeconds = 0
    $B.NetSeconds = 0
    $B
}

function New-WinReservation($World) {
    $r = Request-AapReservation -Root $World.Cap -Profile windows -MemOverheadMib 512 -CloneGib 60 -ScratchGib 40 -IoMbps 100 -ImageGeneration $script:WinGen -RelaxedTrustForTests
    if (-not $r.Ok) { throw "request: $($r.Reason) $($r.Detail)" }
    $r.Reservation
}

function Get-WinRes($World, [string]$Id) {
    $s = Get-AapAllocatorState -Root $World.Cap -RelaxedTrustForTests
    if (-not $s.Ok) { throw "allocator: $($s.Reason) $($s.Detail)" }
    @($s.State.reservations | Where-Object { $_.reservation_id -eq $Id })[0]
}

# Steps a reservation until it is reconciled or $Until says stop; returns the step results.
function Invoke-WinSteps($B, $World, [string]$Id, [int]$Max = 12, [scriptblock]$Until = $null) {
    $w = $World
    $out = New-Object Collections.Generic.List[object]
    for ($i = 0; $i -lt $Max; $i++) {
        $r = Get-WinRes $w $Id
        if ($r.state -eq 'reconciled' -or ($Until -and (& $Until $r))) { break }
        $out.Add((Invoke-AapWinStep -Backend $B -Reservation $r -BaseSha256 $w.BaseSha))
    }
    $out.ToArray()
}

function Get-WinJournalLines($World, [string]$Id) {
    $p = Join-Path $World.Journal "$Id.jsonl"
    if (-not [IO.File]::Exists($p)) { return @() }
    @([IO.File]::ReadAllLines($p) | Where-Object { $_ })
}
function Get-WinJournal($World, [string]$Id) { @(Get-WinJournalLines $World $Id | ForEach-Object { ConvertFrom-WinJson $_ }) }

# validate.py in file mode: every journal line and every recorded exchange, one file each. Returns the FAIL lines.
function Invoke-WinValidator($World, [string]$Contract, [string[]]$Docs) {
    $dir = Join-Path $World.Root ('v-' + [guid]::NewGuid().ToString('n').Substring(0, 8))
    [void][IO.Directory]::CreateDirectory($dir)
    $files = @(for ($i = 0; $i -lt $Docs.Count; $i++) { $f = Join-Path $dir "$i.json"; [IO.File]::WriteAllText($f, $Docs[$i], $script:Utf8); $f })
    if (-not @($files).Count) { return @('no documents') }
    $ErrorActionPreference = 'Continue'
    $out = @(& python -B -I $script:Validator $Contract @files 2>&1 | ForEach-Object { "$_" })
    @($out | Where-Object { $_ -notlike 'ok    *' })
}

# Every file under the world, as bytes, searched for each secret (byte-exact).
function Find-WinSecret($World, [string[]]$Secrets) {
    $hits = New-Object Collections.Generic.List[string]
    foreach ($f in [IO.Directory]::GetFiles($World.Root, '*', [IO.SearchOption]::AllDirectories)) {
        $text = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($f))
        foreach ($s in $Secrets) { if ($s -and $text.Contains($s)) { $hits.Add($f) } }
    }
    , $hits.ToArray()
}

# A child process that builds the backend over the same world, sets a fault point and steps one reservation; it kills
# itself at the fault (exit -1). Plain .ps1 files, CreateNoWindow, no data but paths on the command line.
function Start-WinChild($World, [string]$Fault, [string]$Id, [int]$Steps = 12) {
    $script = Join-Path $World.Root 'child.ps1'
    if (-not (Test-Path -LiteralPath $script)) {
        [IO.File]::WriteAllText($script, @'
param([string]$Helpers, [string]$WorldFile, [string]$Fault, [string]$Id, [int]$Steps)
$ErrorActionPreference = 'Stop'
$WarningPreference = 'SilentlyContinue'
. $Helpers
Import-Module $script:CapModule
Import-Module $script:BackendModule
$w = Read-WinWorld $WorldFile
$B = New-WinBackend $w
if ($Fault) { Set-WinModuleVar 'Fault' $Fault }
$res = Invoke-WinSteps $B $w $Id $Steps
[Console]::Out.WriteLine('steps ' + @($res).Count + ' ' + ((@($res) | ForEach-Object { $_.Action }) -join ','))
'@, $script:Utf8)
    }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Process -Id $PID).Path
    $argv = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $script, (Join-Path $PSScriptRoot 'WinBackendTestHelpers.ps1'), $World.File, $Fault, $Id, "$Steps")
    $psi.Arguments = ($argv | ForEach-Object { if ($_ -eq '') { '""' } else { '"' + $_ + '"' } }) -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    if ($env:AAP_WINBACKEND_MODULE) { $psi.EnvironmentVariables['AAP_WINBACKEND_MODULE'] = $env:AAP_WINBACKEND_MODULE }
    $p = [Diagnostics.Process]::Start($psi)
    $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit(180000)) { $p.Kill(); throw "child did not exit" }
    $p.WaitForExit()
    [pscustomobject]@{ ExitCode = $p.ExitCode; Out = $o.Result; Err = $e.Result }
}
