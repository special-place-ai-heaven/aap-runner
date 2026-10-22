# Fake world for the P11 Linux backend tests. Pester 5, Windows PowerShell 5.1 and PowerShell 7.5+.
# Real folders under the test drive for the storage roots, the journal and the allocator (the real AapCapacity.psm1 in
# relaxed trust), and file-backed fakes for Hyper-V (vms.json), ssh-keygen, the seed ISO writer, the guest's first boot and
# its agent behind sshd (guests\<vm id>.json), the broker (its -Invoker, leases.json) and the P10.0 network module (the
# shared strict fake, tests/common/AapHostNetworkFake.psm1, under fake\net), so a
# child process killed mid-step leaves the very world the parent then recovers from. Nothing here calls Hyper-V, ssh,
# wsl.exe or the network.
# The fakes resolve $w (the world) at call time from the calling scope, as P10's do: a test names its world $w.
# The fake private key holds the marker FAKE-PRIVATE-KEY and a random tail, and its public line is derived from it, so the
# fake guest can check which key a call presents; the fake broker keeps only the SHA-256 of each JIT config, and the fake
# guest the SHA-256 and length of what it received. The fake seed ISO is a JSON file holding the seed's files as text.

$script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$script:BackendModule = $(if ($env:AAP_LINBACKEND_MODULE) { $env:AAP_LINBACKEND_MODULE } else { Join-Path $script:Repo 'supervisor\backends\linux\AapLinBackend.psm1' })
$script:SupervisorDir = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $script:BackendModule))
$script:CapModule = Join-Path $script:SupervisorDir 'capacity\AapCapacity.psm1'
$script:Validator = Join-Path $script:Repo 'parity\contracts\validate.py'
Import-Module (Join-Path $script:Repo 'tests\common\AapHostNetworkFake.psm1')   # the shared strict fake of the P10.0 module
$script:LinGen = 'ubuntu-24.04-x64/20261012.334.1-aap.1'
$script:VolGuid = '00000000-0000-4000-8000-0000000000e1'
$script:OtherGuid = '00000000-0000-4000-8000-0000000000f2'
$script:UserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$script:Utf8 = New-Object Text.UTF8Encoding($false)
$script:GiB = 1073741824

function Get-LinSha([byte[]]$Bytes) {
    $h = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($h.ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant() } finally { $h.Dispose() }
}
# An ed25519-shaped public key line from any bytes (43 base64 characters after the fixed 25-character prefix).
function Get-LinPublicOf([byte[]]$Bytes) {
    $h = [Security.Cryptography.SHA256]::Create()
    try { $b64 = [Convert]::ToBase64String($h.ComputeHash($Bytes)) } finally { $h.Dispose() }
    'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI' + $b64.Substring(0, 43)
}
function ConvertFrom-LinJson([string]$Text) {
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { return , (ConvertFrom-Json -InputObject $Text -DateKind String) }
    , (ConvertFrom-Json -InputObject $Text)
}
function Read-LinJson([string]$Path, $Default) {
    if (-not [IO.File]::Exists($Path)) { return $Default }
    $t = [IO.File]::ReadAllText($Path)
    if (-not $t.Trim()) { return $Default }
    ConvertFrom-LinJson $t
}
function Write-LinJson([string]$Path, $Object) { [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Object -Depth 10 -Compress), $script:Utf8) }

# A folder with inheritance cut: SYSTEM, Administrators and the test user only (P09's New-CapRoot), so relaxed trust holds.
function New-LinAclDir([string]$Path) {
    [void][IO.Directory]::CreateDirectory($Path)
    $out = & icacls.exe $Path /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' "*$($script:UserSid):(OI)(CI)F" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "icacls failed: $out" }
}

function Set-LinModuleVar([string]$Name, $Value) { & (Get-Module AapLinBackend) { param($n, $v) Set-Variable -Scope Script -Name $n -Value $v } $Name $Value }
function Get-LinModuleVar([string]$Name) { & (Get-Module AapLinBackend) { param($n) Get-Variable -Scope Script -Name $n -ValueOnly } $Name }
function Invoke-LinInModule([scriptblock]$Block, [object[]]$ArgumentList = @()) { & (Get-Module AapLinBackend) $Block @ArgumentList }

# A PowerShell host (Windows PowerShell 5.1 or 7) run in a process of its own with a console of its own: CreateNoWindow gives
# it a new hidden console, so a suite hosted by 7, or by a host with no console, still reaches the Windows PowerShell 5.1
# behaviours, and this process's console is never touched. -Utf8Console starts the host behind cmd.exe's chcp 65001, so its
# console input code page is UTF-8 as a CI host's is and a 5.1 host reads a preamble-bearing [Console]::InputEncoding;
# without it the console is the machine's default. Standard input is a pipe closed at once. Every token is double-quoted.
$script:Ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script:Pwsh7 = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
$script:HostSwitches = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass')
function Invoke-LinHosted([string]$Shell, [string[]]$FileArgs, [switch]$Utf8Console, [int]$TimeoutSeconds = 180) {
    $exe = $(if ($Shell -eq 'pwsh') { $script:Pwsh7 } else { $script:Ps51 })
    $tokens = @($exe) + $script:HostSwitches + @('-File') + $FileArgs
    foreach ($t in $tokens) { if ($t.Contains('"') -or $t.EndsWith('\')) { throw "Invoke-LinHosted: cannot quote $t" } }
    $psi = New-Object Diagnostics.ProcessStartInfo
    if ($Utf8Console) {
        $psi.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
        $psi.Arguments = '/d /s /c ""' + (Join-Path $env:SystemRoot 'System32\chcp.com') + '" 65001 >nul & ' + (($tokens | ForEach-Object { '"' + $_ + '"' }) -join ' ') + '"'
    } else {
        $psi.FileName = $exe
        $psi.Arguments = (@($tokens | Select-Object -Skip 1 | ForEach-Object { '"' + $_ + '"' }) -join ' ')
    }
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    # A PowerShell 7 caller leaves its module path behind; Windows PowerShell 5.1 must rebuild its own.
    if ($exe -eq $script:Ps51) { [void]$psi.EnvironmentVariables.Remove('PSModulePath') }
    $p = [Diagnostics.Process]::Start($psi)
    $timedOut = $false
    try {
        $null = $p.Handle   # Windows PowerShell 5.1 reports no ExitCode unless the handle was opened while running
        $p.StandardInput.Close()
        $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
        # One deadline for the host's exit and for draining its output: a descendant that keeps stdout or stderr open must
        # not hold the suite past it.
        $until = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        $timedOut = -not $p.WaitForExit($TimeoutSeconds * 1000)
        if (-not $timedOut) { $timedOut = -not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($o, $e), [int][Math]::Max(0, ($until - [DateTime]::UtcNow).TotalMilliseconds)) }
        [pscustomobject]@{ Code = $(if ($timedOut) { $null } else { $p.ExitCode }); TimedOut = $timedOut; Out = $(if ($o.IsCompleted) { $o.Result } else { '' }); Err = $(if ($e.IsCompleted) { $e.Result } else { '' }) }
    } finally {
        # Whatever ended this call (the deadline, an exception, a stopped run), nothing of its process tree is left.
        if ($timedOut -or -not $p.HasExited) { try { $null = & (Join-Path $env:SystemRoot 'System32\taskkill.exe') /T /F /PID $p.Id 2>&1 } catch { $null = $_ } }
        $p.Dispose()
    }
}
function Write-LinDriver([string]$Dir, [string]$Name, [string]$Text) { [void][IO.Directory]::CreateDirectory($Dir); $f = Join-Path $Dir $Name; [IO.File]::WriteAllText($f, $Text, $script:Utf8); $f }

# ---- the world -----------------------------------------------------------------------------------------------------

function New-LinWorld {
    param([int]$Linux = 1, [string]$Under = $TestDrive)
    $root = Join-Path $Under ('l' + [guid]::NewGuid().ToString('n').Substring(0, 10))
    $w = [pscustomobject]@{
        Root = $root; Base = (Join-Path $root 'roots\base'); Clones = (Join-Path $root 'roots\clones'); Scratch = (Join-Path $root 'roots\scratch')
        Cap = (Join-Path $root 'cap'); Journal = (Join-Path $root 'cap\journal'); Fake = (Join-Path $root 'fake'); StoragePath = (Join-Path $root 'storage.json')
        Net = (Join-Path $root 'fake\net')
        BaseFile = $null; BaseSha = $null; File = (Join-Path $root 'world.json')
    }
    [void][IO.Directory]::CreateDirectory((Join-Path $root 'roots'))
    foreach ($d in $w.Base, $w.Clones, $w.Scratch, $w.Cap) { New-LinAclDir $d }
    foreach ($d in $w.Fake, (Join-Path $w.Fake 'guests'), (Join-Path $w.Fake 'exchanges'), $w.Net) { [void][IO.Directory]::CreateDirectory($d) }
    $genDir = Join-Path $w.Base ($script:LinGen -replace '/', '\')
    [void][IO.Directory]::CreateDirectory($genDir)
    $w.BaseFile = Join-Path $genDir 'base.vhdx'
    [IO.File]::WriteAllText($w.BaseFile, 'fake sealed ubuntu base disk')
    $w.BaseSha = (Get-FileHash -LiteralPath $w.BaseFile -Algorithm SHA256).Hash.ToLowerInvariant()
    # Sealed as P07 leaves it: protected DACL, no write for anyone but the admins (here: the test user), ReadOnly.
    New-LinAclDir $genDir
    $out = & icacls.exe $w.BaseFile /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' "*$($script:UserSid):F" '*S-1-5-83-0:RX' 2>&1
    if ($LASTEXITCODE -ne 0) { throw "icacls failed: $out" }
    [IO.File]::SetAttributes($w.BaseFile, [IO.FileAttributes]::ReadOnly)
    $roots = [ordered]@{
        base_root = [ordered]@{ path = $w.Base; volume_guid = $script:VolGuid }; clone_root = [ordered]@{ path = $w.Clones; volume_guid = $script:VolGuid }
        scratch_root = [ordered]@{ path = $w.Scratch; volume_guid = $script:VolGuid }; staging_root = $null
    }
    Write-LinJson $w.StoragePath ([ordered]@{ schema = 2; kind = 'storage'; volume_floor_gib = 10; roots = $roots })
    Write-LinJson (Join-Path $w.Fake 'vms.json') @()
    Write-LinJson (Join-Path $w.Fake 'leases.json') @()
    Write-LinJson (Join-Path $w.Fake 'knobs.json') @{}
    $hostInfo = @{ cpu_cores = 32; mem_gib = 96; io_mbps = 1000; control_distro_mem_gib = 1
        volumes = @(@{ volume_guid = $script:VolGuid; tiers = @('base', 'clone', 'scratch', 'staging'); available_gib = 2010; floor_gib = 10; held_gib = 0 })
    }
    foreach ($call in @(
            { Initialize-AapAllocator -Root $w.Cap -HostInfo $hostInfo -Linux $Linux -Windows 0 -LinuxBackend hyperv-vm -RelaxedTrustForTests },
            { Set-AapProfileCounts -Root $w.Cap -Linux $Linux -Windows 0 -LinuxBackend hyperv-vm -LinuxGeneration $script:LinGen -RelaxedTrustForTests },
            { Register-AapLegacySlots -Root $w.Cap -ManagerStopped -RelaxedTrustForTests })) {
        $r = & $call
        if (-not $r.Ok) { throw "allocator setup: $($r.Reason) $($r.Detail)" }
    }
    Write-LinJson $w.File $w
    $w
}

function Read-LinWorld([string]$File) { ConvertFrom-LinJson ([IO.File]::ReadAllText($File)) }

function Get-LinKnob($World, [string]$Name, $Default = $null) {
    $k = Read-LinJson (Join-Path $World.Fake 'knobs.json') $null
    if ($null -eq $k) { return $Default }
    $p = $k.PSObject.Properties[$Name]
    if ($null -eq $p) { return $Default }
    $p.Value
}
function Set-LinKnob($World, [hashtable]$Knobs) {
    $k = @{}
    $old = Read-LinJson (Join-Path $World.Fake 'knobs.json') $null
    if ($null -ne $old) { foreach ($p in $old.PSObject.Properties) { $k[$p.Name] = $p.Value } }
    foreach ($n in $Knobs.Keys) { $k[$n] = $Knobs[$n] }
    Write-LinJson (Join-Path $World.Fake 'knobs.json') $k
}
function Add-LinCall($World, [string]$Text) { [IO.File]::AppendAllText((Join-Path $World.Fake 'calls.log'), $Text + "`n") }
function Get-LinCalls($World, [string]$Like = '*') {
    $p = Join-Path $World.Fake 'calls.log'
    if (-not [IO.File]::Exists($p)) { return @() }
    @([IO.File]::ReadAllLines($p) | Where-Object { $_ -like $Like })
}
# A JSON array file as a flat list (Windows PowerShell's ConvertFrom-Json returns an array as one object).
function Read-LinList([string]$Path) { $x = Read-LinJson $Path @(); @($x | ForEach-Object { $_ } | Where-Object { $null -ne $_ }) }
function Get-LinVms($World) { Read-LinList (Join-Path $World.Fake 'vms.json') }
function Save-LinVms($World, $Vms) { Write-LinJson (Join-Path $World.Fake 'vms.json') @($Vms) }
function Get-LinLeases($World) { Read-LinList (Join-Path $World.Fake 'leases.json') }
function Save-LinLeases($World, $Leases) { Write-LinJson (Join-Path $World.Fake 'leases.json') @($Leases) }
# The fake seed ISO: its label and files.
function Read-LinSeed([string]$Path) { Read-LinJson $Path $null }

# ---- fakes ---------------------------------------------------------------------------------------------------------

function New-LinProvider {
    $p = @{}
    $p.GetVolumeGuid = { param($a) $bad = Get-LinKnob $w 'WrongVolume' ''; if ($bad -and $a.Path -like "*$bad*") { return $script:OtherGuid }; $script:VolGuid }
    $p.GetHostSecurity = { param($a)
        if (Get-LinKnob $w 'HostFails' $false) { throw 'fake: Get-VMHost failed' }
        @{ EnhancedSessionMode = (Get-LinKnob $w 'EnhancedSession' $false); HyperVAdmins = [object[]]@(Get-LinKnob $w 'HyperVAdmins' @()) }
    }
    $p.HashFile = { param($a)
        Add-LinCall $w "HashFile $($a.Path)"
        if (-not ($a.Stream -is [IO.FileStream]) -or $a.Stream.CanWrite) { throw 'fake: HashFile needs the backend''s read handle' }
        $o = Get-LinKnob $w 'HashOverride' ''; if ($o) { return $o }; (Get-FileHash -LiteralPath $a.Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $p.NewDiffDisk = { param($a) Add-LinCall $w "NewDiffDisk $($a.Path) $($a.Parent)"; [IO.File]::WriteAllText($a.Path, 'differencing child of ' + $a.Parent) }
    $p.GetVhdParent = { param($a) $o = Get-LinKnob $w 'VhdParent' ''; if ($o) { return $o }; ([IO.File]::ReadAllLines($a.Path))[0].Substring('differencing child of '.Length) }
    $p.NewKeyPair = { param($a)
        Add-LinCall $w "NewKeyPair $($a.Dir)"
        if (Get-LinKnob $w 'KeyFails' $false) { throw 'AAP_KeyInvalid: fake ssh-keygen exited 1' }
        $priv = [Text.Encoding]::ASCII.GetBytes('FAKE-PRIVATE-KEY-' + [guid]::NewGuid().ToString('n'))
        [IO.File]::WriteAllBytes((Join-Path $a.Dir 'id_ed25519'), $priv)
        $pub = Get-LinPublicOf $priv
        [IO.File]::WriteAllText((Join-Path $a.Dir 'id_ed25519.pub'), "$pub aap-management`n")
        $o = Get-LinKnob $w 'PublicOverride' ''; if ($o) { return $o }
        $pub
    }
    $p.NewSeedImage = { param($a)
        Add-LinCall $w "NewSeedImage $($a.Path) $($a.Label)"
        if (Get-LinKnob $w 'SeedFails' $false) { throw 'fake: IMAPI2 failed' }
        $files = [ordered]@{}; foreach ($k in $a.Files.Keys) { $files[$k] = [string]$a.Files[$k] }
        Write-LinJson $a.Path ([ordered]@{ label = $a.Label; files = $files })
        # What the writer produced, as the production provider reports it; knob SeedLost: the file on disk is not that
        # ('short': its last byte lost, 'stale': the right size with another byte, as a short read used to leave it).
        $bytes = [IO.File]::ReadAllBytes($a.Path)
        $made = @{ Bytes = [long]$bytes.Length; Sha256 = (Get-LinSha $bytes) }
        switch ([string](Get-LinKnob $w 'SeedLost' '')) {
            'short' { [IO.File]::WriteAllBytes($a.Path, [byte[]]$bytes[0..($bytes.Length - 2)]) }
            'stale' { $bytes[$bytes.Length - 2] = 0; [IO.File]::WriteAllBytes($a.Path, $bytes) }
        }
        $made
    }
    $p.NewVm = { param($a)
        Add-LinCall $w "NewVm $($a.Name)"
        if (Get-LinKnob $w 'NewVmFails' $false) { throw 'fake: New-VM failed' }
        if ($a.ContainsKey('Seed')) { throw 'fake: NewVm takes no seed: the seed carries the declaration, so it comes after Attach' }
        $id = [guid]::NewGuid().ToString()
        $cfg = Join-Path $a.Path 'Virtual Machines'
        [void][IO.Directory]::CreateDirectory($cfg)
        [IO.File]::WriteAllText((Join-Path $cfg "$id.vmcx"), 'fake vm configuration')
        $vm = [ordered]@{ Id = $id; Name = $a.Name; State = 'Off'; Cpus = $a.Cpus; MemGib = $a.MemGib; Generation = 2; SecureBoot = $true; SecureBootTemplate = 'MicrosoftUEFICertificateAuthority'
            CheckpointType = 'Disabled'; AutomaticStopAction = 'TurnOff'; AutomaticStartAction = 'Nothing'; DynamicMemory = $false; NestedVirtualization = $true
            GuestServiceInterface = $false; KeyValuePairExchange = $true; ConfigurationLocation = $a.Path; SnapshotFileLocation = $a.Path; SmartPagingFilePath = $a.Path
            Disks = @($a.OsDisk); Dvds = @(); DvdDrives = 1; ComPorts = 0; GpuPartitions = 0; AssignedDevices = 0; Booted = $false; HostKey = ''; AuthKey = ''; OsDisk = $a.OsDisk
            Address = ''
        }
        if (Get-LinKnob $w 'ExtraDisk' $false) { $vm.Disks = @($vm.Disks) + (Join-Path $a.Path 'extra.vhdx') }
        Save-LinVms $w (@(Get-LinVms $w) + [pscustomobject]$vm)
        @{ Id = $id.ToUpperInvariant() }
    }
    # The seed into the VM's one DVD drive (knob SetSeedFails), refused for a VM that is not Off or has another number of
    # DVD drives, as the production op.
    $p.SetSeed = { param($a)
        Add-LinCall $w "SetSeed $($a.VmId) $($a.Seed)"
        if (Get-LinKnob $w 'SetSeedFails' $false) { throw 'fake: Set-VMDvdDrive failed' }
        $vms = @(Get-LinVms $w)
        foreach ($v in $vms) {
            if ($v.Id -ne $a.VmId) { continue }
            if ($v.State -ne 'Off' -or $v.DvdDrives -ne 1) { throw "AAP_SeedInvalid: fake: the VM is $($v.State) with $($v.DvdDrives) DVD drives" }
            $v.Dvds = @($a.Seed)
        }
        Save-LinVms $w $vms
    }
    # The VM as Hyper-V reads back: its adapters are what the shared fake module made (the provider shape); knob VmOverride
    # changes any field of the read-back.
    $p.GetVmConfig = { param($a)
        $v = @(Get-LinVms $w | Where-Object { $_.Id -eq $a.VmId })
        if (-not $v.Count) { return $null }
        $c = @{}
        foreach ($q in $v[0].PSObject.Properties) { $c[$q.Name] = $q.Value }
        $c.Adapters = @(Get-AapFakeHostNetworkAdapter -Root $w.Net -VmId $a.VmId)
        $o = Get-LinKnob $w 'VmOverride' $null
        if ($null -ne $o) { foreach ($q in $o.PSObject.Properties) { $c[$q.Name] = $q.Value } }
        $c
    }
    # The guest's first boot: cloud-init reads the seed in the VM's DVD (its authorized key), sshd makes a host key and the
    # guest publishes it through Key-Value Pair Exchange (knob KvpDelay: that many reads find nothing yet).
    $p.StartVm = { param($a)
        Add-LinCall $w "StartVm $($a.VmId)"
        if (Get-LinKnob $w 'StartFails' $false) { throw 'fake: Start-VM failed' }
        $vms = @(Get-LinVms $w)
        foreach ($v in $vms) {
            if ($v.Id -ne $a.VmId) { continue }
            $v.State = 'Running'
            if (-not $v.Booted) {
                $v.Booted = $true
                $v.HostKey = Get-LinPublicOf ([guid]::NewGuid().ToByteArray())
                $seed = @($v.Dvds | Where-Object { $_ })
                if ($seed.Count) {
                    $s = Read-LinSeed $seed[0]
                    $m = [regex]::Match([string]$s.files.'user-data', 'restrict,command="[^"]+" (ssh-ed25519 [A-Za-z0-9+/]+)')
                    if ($m.Success) { $v.AuthKey = $m.Groups[1].Value }
                    # No DHCP: the guest's address is the one its seed's network-config gives it, or none.
                    $nm = [regex]::Match([string]$s.files.'network-config', '(?m)^    addresses: \[([0-9.]+)/[0-9]+\]$')
                    if ($nm.Success) { $v.Address = $nm.Groups[1].Value }
                }
            }
        }
        Save-LinVms $w $vms
    }
    $p.GetHostKey = { param($a)
        Add-LinCall $w "GetHostKey $($a.VmId)"
        if (Get-LinKnob $w 'KvpFails' $false) { throw 'fake: CIM failed' }
        $delay = [int](Get-LinKnob $w 'KvpDelay' 0)
        if ($delay -gt 0) { Set-LinKnob $w @{ KvpDelay = $delay - 1 }; return $null }
        $o = Get-LinKnob $w 'HostKeyOverride' $null; if ($null -ne $o) { return $o }
        $v = @(Get-LinVms $w | Where-Object { $_.Id -eq $a.VmId })
        if (-not $v.Count -or $v[0].State -ne 'Running' -or -not $v[0].HostKey) { return $null }
        [string]$v[0].HostKey
    }
    $p.EjectSeed = { param($a)
        Add-LinCall $w "EjectSeed $($a.VmId)"
        if (Get-LinKnob $w 'EjectFails' $false) { throw 'fake: Set-VMDvdDrive failed' }
        if (Get-LinKnob $w 'EjectNoop' $false) { return }
        $vms = @(Get-LinVms $w); foreach ($v in $vms) { if ($v.Id -eq $a.VmId) { $v.Dvds = @() } }; Save-LinVms $w $vms
    }
    $p.StopVm = { param($a) Add-LinCall $w "StopVm $($a.VmId)"; $vms = @(Get-LinVms $w); foreach ($v in $vms) { if ($v.Id -eq $a.VmId) { $v.State = 'Off' } }; Save-LinVms $w $vms }
    $p.RemoveVm = { param($a)
        Add-LinCall $w "RemoveVm $($a.VmId)"
        if (Get-LinKnob $w 'RemoveVmFails' $false) { throw 'fake: Remove-VM failed' }
        $vm = @(Get-LinVms $w | Where-Object { $_.Id -eq $a.VmId })
        foreach ($v in $vm) { $f = Join-Path $v.ConfigurationLocation "Virtual Machines\$($v.Id).vmcx"; if ([IO.File]::Exists($f)) { [IO.File]::Delete($f) } }
        Save-LinVms $w @(Get-LinVms $w | Where-Object { $_.Id -ne $a.VmId })
    }
    $p.ListVms = { param($a)
        if (Get-LinKnob $w 'ListFails' $false) { throw 'fake: Get-VM failed (access denied)' }
        @(Get-LinVms $w | ForEach-Object { @{ Id = $_.Id; Name = $_.Name; State = $(if (Get-LinKnob $w 'Paused' $false) { 'Paused-Critical' } else { $_.State }); Cpus = $_.Cpus; MemGib = $_.MemGib } })
    }
    $p.MeasureBytes = { param($a) if (Get-LinKnob $w 'MeasureFails' $false) { throw 'access denied' }; [double](Get-LinKnob $w 'CloneBytes' $script:GiB) }
    $p
}

# The P10.0 module: the shared strict fake (tests/common/AapHostNetworkFake.psm1) over the world's own folder $w.Net, its
# tampers and faults set with Set-AapFakeHostNetworkKnob -Root $w.Net. It asks the fake Hyper-V above whether a VM exists
# and in what state. Each call is logged (NetAttach, NetVerify, NetDetach) so tests can check the order; knob
# VerifyWritesNull makes Verify write one $null item after its problems (a module that writes anything on success).
$script:LinNetVm = { param($id) $v = @(Get-LinVms $w | Where-Object { $_.Id -eq $id }); if ($v.Count) { @{ State = [string]$v[0].State; Adapters = 0 } } }
function New-LinNetwork {
    @{
        Attach = { param($a)
            Add-LinCall $w "NetAttach $($a.VmId)"
            $d = & (New-AapFakeHostNetwork -Root $w.Net -Vm $script:LinNetVm).Attach $a
            # Knob AttachDeclares 'public-subnet': a module that declares a subnet outside every private range.
            if ((Get-LinKnob $w 'AttachDeclares' '') -ceq 'public-subnet') {
                $h = [ordered]@{}; foreach ($q in $d.PSObject.Properties) { $h[$q.Name] = $q.Value }
                $h.subnet = '203.0.113.0/24'
                return $h
            }
            $d
        }
        Detach = { param($a) Add-LinCall $w "NetDetach $($a.VmId)"; & (New-AapFakeHostNetwork -Root $w.Net -Vm $script:LinNetVm).Detach $a }
        Verify = { param($a)
            Add-LinCall $w "NetVerify $($a.VmId)"
            & (New-AapFakeHostNetwork -Root $w.Net -Vm $script:LinNetVm).Verify $a
            if (Get-LinKnob $w 'VerifyWritesNull' $false) { $null }
        }
    }
}

# The guest behind its sshd and forced command, file-backed per VM. ssh.exe's own failures come back as exit 255 with no
# reply: the VM not running, sshd not up yet (knob NotUp, a count), a host key other than the one pinned in the call's
# known_hosts, or a client key other than the one its seed authorized. The agent then refuses a wrong vm_id, a lease
# generation other than the first it saw, a seq not strictly greater than the last one it accepted (gaps are fine), a
# reused nonce, an expired command and a second one-shot command. Knob 'Guest' maps a command (or '*') to a misbehaviour;
# 'LoseReply' a count of calls the agent accepts whose reply never arrives (ssh exit 255). A started runner writes the
# job's state into the clone's disk, as a job writes to its root file system.
function New-LinGuest {
    {
        param($Call)
        $hc = ConvertFrom-LinJson $Call.Envelope
        $payload = [byte[]]@()
        if ($Call.PayloadLength -gt 0) { $ms = New-Object IO.MemoryStream; & $Call.WritePayload $ms; $payload = $ms.ToArray() }
        $fail = @{ ExitCode = 255; Stdout = [byte[]]@(); TimedOut = $false; Overflow = $false }
        $vm = @(Get-LinVms $w | Where-Object { $_.Id -eq $Call.VmId })
        if (-not $vm.Count -or $vm[0].State -ne 'Running') { return $fail }
        $notUp = [int](Get-LinKnob $w 'NotUp' 0)
        if ($notUp -gt 0) { Set-LinKnob $w @{ NotUp = $notUp - 1 }; return $fail }
        $dir = Split-Path -Parent $Call.Config
        $kh = Join-Path $dir 'known_hosts'
        if (-not [IO.File]::Exists($kh) -or [IO.File]::ReadAllText($kh) -cne "aap-guest $($vm[0].HostKey)`n") { Add-LinCall $w "GuestHostKeyRefused $($Call.VmId)"; return $fail }
        if ((Get-LinPublicOf ([IO.File]::ReadAllBytes((Join-Path $dir 'id_ed25519')))) -cne $vm[0].AuthKey) { Add-LinCall $w "GuestAuthRefused $($Call.VmId)"; return $fail }
        $sf = Join-Path $w.Fake "guests\$($Call.VmId).json"
        $st = Read-LinJson $sf ([pscustomobject]@{ Seq = 0; Gen = 0; Nonces = @(); Shots = @(); Probes = 0; PayloadSha = ''; PayloadLen = 0 })
        $status = 'ok'; $state = 'booting'; $exit = $null; $diag = ''
        $shot = @('deliver_registration', 'start_runner', 'shutdown') -contains $hc.cmd
        $expired = [DateTime]::ParseExact($hc.expires_at, "yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture, 'AssumeUniversal, AdjustToUniversal') -lt [DateTime]::UtcNow.AddSeconds([double](Get-LinKnob $w 'ClockOffset' 0) - 5)
        if ($hc.vm_id -ne $Call.VmId -or ($st.Gen -and $st.Gen -ne $hc.lease_generation) -or $hc.seq -le $st.Seq -or @($st.Nonces) -contains $hc.nonce -or
            ($shot -and @($st.Shots) -contains $hc.cmd) -or $expired) {
            $status = 'refused'; $diag = 'refused by the agent'
        } else {
            $st.Seq = $hc.seq; $st.Gen = $hc.lease_generation; $st.Nonces = @($st.Nonces) + $hc.nonce
            if ($shot) { $st.Shots = @($st.Shots) + $hc.cmd }
            switch ($hc.cmd) {
                'probe' { $st.Probes++; $state = $(if ($st.Probes -gt [int](Get-LinKnob $w 'BootProbes' 0)) { 'ready' } else { 'booting' }) }
                'deliver_registration' { $st.PayloadSha = Get-LinSha $payload; $st.PayloadLen = $payload.Length; $state = 'registered'; $diag = 'bootstrap material removed' }
                'start_runner' {
                    $state = 'listening'; $diag = 'runner started from env input'
                    [IO.File]::AppendAllText($vm[0].OsDisk, "`njob state: /home/runner planted, workspace planted, listener on 8080, unit aap-planted.service")
                }
                'status' { $state = Get-LinKnob $w 'GuestStatus' 'listening' }
                'collect' { $state = 'job_done'; $exit = 0; $diag = 'job summary: 1 job, exit 0' }
            }
        }
        Write-LinJson $sf $st
        $lose = [int](Get-LinKnob $w 'LoseReply' 0)
        if ($lose -gt 0) { Set-LinKnob $w @{ LoseReply = $lose - 1 }; return $fail }
        $reply = [ordered]@{ schema = 1; kind = 'guest_reply'; vm_id = $hc.vm_id; reservation_id = $hc.reservation_id; lease_generation = $hc.lease_generation
            seq = $hc.seq; nonce = $hc.nonce; status = $status; guest_state = $state; runner_exit_code = $exit; diag = $diag
        }
        $how = Get-LinKnob $w 'Guest' $null
        $bad = $null
        if ($null -ne $how) { foreach ($k in @($hc.cmd, '*')) { $q = $how.PSObject.Properties[$k]; if ($null -ne $q -and $null -eq $bad) { $bad = [string]$q.Value } } }
        $text = $null
        switch -Wildcard ($bad) {
            'timeout' { return @{ ExitCode = $null; Stdout = $null; TimedOut = $true; Overflow = $false } }
            'overflow' { return @{ ExitCode = $null; Stdout = $null; TimedOut = $false; Overflow = $true } }
            'exit' { return @{ ExitCode = 3; Stdout = [byte[]]@(); TimedOut = $false; Overflow = $false } }
            'drop' { return @{ ExitCode = 255; Stdout = $script:Utf8.GetBytes('{"schema":1,"kind":"guest_re'); TimedOut = $false; Overflow = $false } }
            'silent' { return @{ ExitCode = 0; Stdout = [byte[]]@(); TimedOut = $false; Overflow = $false } }
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
            'banner' { $text = 'Welcome to Ubuntu' + "`n" + (ConvertTo-Json $reply -Compress) }
        }
        if ($null -eq $text) { $text = ConvertTo-Json $reply -Compress }
        $bytes = $script:Utf8.GetBytes($text + "`n")
        if ($bad -eq 'nonprintable') { $bytes[$text.IndexOf('ESCMARK')] = 7 }
        if ($null -eq $bad -or $bad -eq 'refuse') {
            $x = [ordered]@{ schema = 1; kind = 'exchange'; cmd = (ConvertFrom-LinJson $Call.Envelope); reply = (ConvertFrom-LinJson ($text)) }
            Write-LinJson (Join-Path $w.Fake ('exchanges\' + [guid]::NewGuid().ToString('n') + '.json')) $x
        }
        @{ ExitCode = 0; Stdout = $bytes; TimedOut = $false; Overflow = $false }
    }
}

# The broker, behind aap-broker.psm1's -Invoker: a lease ledger in leases.json (no JIT value, only its hash).
function New-LinBroker {
    {
        param([byte[]]$Bytes, [int]$Timeout)
        $req = ConvertFrom-LinJson ([Text.Encoding]::ASCII.GetString($Bytes))
        $out = { param($o) [pscustomobject]@{ ExitCode = 0; Stdout = [Text.Encoding]::ASCII.GetBytes((ConvertTo-Json -InputObject $o -Compress)); TimedOut = $false; Overflow = $false } }
        $down = [pscustomobject]@{ ExitCode = 1; Stdout = [byte[]]@(); TimedOut = $false; Overflow = $false }
        $leases = @(Get-LinLeases $w)
        $l = @($leases | Where-Object { $_.lease_id -eq $req.lease_id })[0]
        Add-LinCall $w "Broker $($req.kind) $($req.lease_id)"
        switch ($req.kind) {
            'lease_request' {
                if ($req.profile -ne 'ubuntu-24.04-x64') { throw 'fake broker: the Linux backend asked for another profile' }
                $how = Get-LinKnob $w 'LeaseOutcome' 'issued'
                if ($how -eq 'unavailable') { return $down }
                if ($how -eq 'bad_reply') { return [pscustomobject]@{ ExitCode = 0; Stdout = [Text.Encoding]::ASCII.GetBytes('not json'); TimedOut = $false; Overflow = $false } }
                $base = [ordered]@{ schema = 1; kind = 'lease_response'; lease_id = $req.lease_id; result = 'refused'; reason = 'replay'; runner_id = $null; runner_name = $null; expires_at = $null; jit_config = $null }
                if ($null -ne $l) { return (& $out $base) }
                $name = 'aap-l-{0}-{1}-{2}' -f $req.slot, $req.lease_generation, $req.reservation_id.Substring(2, 8)
                if ($how -eq 'refused') {
                    Save-LinLeases $w ($leases + [pscustomobject]@{ lease_id = $req.lease_id; reservation_id = $req.reservation_id; state = 'refused'; runner_name = $name; jit_sha = '' })
                    $base.reason = 'github_error'
                    return (& $out $base)
                }
                if ($how -eq 'wrong_name') { $name = 'aap-l-5-{0}-{1}' -f $req.lease_generation, $req.reservation_id.Substring(2, 8) }
                $jit = 'SYNTHETIC-JIT-MARKER-' + [guid]::NewGuid().ToString('n')
                Save-LinLeases $w ($leases + [pscustomobject]@{ lease_id = $req.lease_id; reservation_id = $req.reservation_id; state = 'issued'; runner_name = $name; jit_sha = (Get-LinSha ([Text.Encoding]::ASCII.GetBytes($jit))) })
                $base.result = 'issued'; $base.reason = 'ok'; $base.runner_id = 4242; $base.runner_name = $name
                $base.expires_at = [DateTime]::UtcNow.AddMinutes(10).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture); $base.jit_config = $jit
                return (& $out $base)
            }
            'release_request' {
                $how = Get-LinKnob $w 'ReleaseOutcome' 'normal'
                if ($how -eq 'unavailable') { return $down }
                $res = [ordered]@{ schema = 1; kind = 'release_response'; lease_id = $req.lease_id; result = 'retry'; reason = 'github_error' }
                if ($how -eq 'retry') { return (& $out $res) }
                if ($how -eq 'clock_skew') { $res.result = 'refused'; $res.reason = 'clock_skew'; return (& $out $res) }
                if ($null -eq $l -or $how -eq 'not_found') { $res.result = 'refused'; $res.reason = 'not_found'; return (& $out $res) }
                $res.reason = 'ok'
                if ($l.state -eq 'issued') { $l.state = 'released'; $res.result = 'deregistered' } else { $l.state = 'released'; $res.result = 'already_gone' }
                Save-LinLeases $w $leases
                return (& $out $res)
            }
            'status_request' {
                $how = Get-LinKnob $w 'StatusOutcome' 'ok'
                # StatusAfterStatus: this answer is normal, the next ones are that outcome.
                if (Get-LinKnob $w 'StatusAfterStatus' $null) { Set-LinKnob $w @{ StatusOutcome = (Get-LinKnob $w 'StatusAfterStatus' $null); StatusAfterStatus = $null } }
                if ($how -eq 'unavailable') { return $down }
                if ($how -eq 'timeout') { return [pscustomobject]@{ ExitCode = $null; Stdout = $null; TimedOut = $true; Overflow = $false } }
                if ($how -eq 'bad_reply') { return [pscustomobject]@{ ExitCode = 0; Stdout = [Text.Encoding]::ASCII.GetBytes('{"schema":1,"kind":"status_response"'); TimedOut = $false; Overflow = $false } }
                $res = [ordered]@{ schema = 1; kind = 'status_response'; lease_id = $req.lease_id; result = 'refused'; reason = 'not_found'; runner = $null }
                if ($null -eq $l) { return (& $out $res) }
                $res.result = 'ok'; $res.reason = 'ok'
                if ($l.state -ne 'issued') { $res.runner = [ordered]@{ status = 'absent'; busy = $false } }
                else { $res.runner = [ordered]@{ status = (Get-LinKnob $w 'RunnerStatus' 'online'); busy = [bool](Get-LinKnob $w 'RunnerBusy' $false) } }
                # BusyAfterStatus: this answer says idle, and a job starts right after it.
                if (Get-LinKnob $w 'BusyAfterStatus' $false) { Set-LinKnob $w @{ BusyAfterStatus = $false; RunnerBusy = $true } }
                return (& $out $res)
            }
        }
        $down
    }
}

# ---- driving it ----------------------------------------------------------------------------------------------------

# The status cadence is off (StatusSeconds 0) so every step heartbeats; one test puts it back.
function New-LinBackend($World) {
    $w = $World
    $B = New-AapLinBackend -Provider (New-LinProvider) -Network (New-LinNetwork) -Transport (New-LinGuest) -BrokerInvoker (New-LinBroker) `
        -AllocatorRoot $w.Cap -JournalRoot $w.Journal -StoragePath $w.StoragePath -LockTimeoutSeconds 5 -RelaxedTrustForTests -WarningAction SilentlyContinue `
        -Clock { [DateTime]::UtcNow.AddSeconds([double](Get-LinKnob $w 'ClockOffset' 0)) } -Sleep { param($s) }
    $B.StatusSeconds = 0
    $B
}

function New-LinReservation($World) {
    $r = Request-AapReservation -Root $World.Cap -Profile linux -MemOverheadMib 512 -CloneGib 55 -ScratchGib 0 -IoMbps 100 -ImageGeneration $script:LinGen -RelaxedTrustForTests
    if (-not $r.Ok) { throw "request: $($r.Reason) $($r.Detail)" }
    $r.Reservation
}

function Get-LinRes($World, [string]$Id) {
    $s = Get-AapAllocatorState -Root $World.Cap -RelaxedTrustForTests
    if (-not $s.Ok) { throw "allocator: $($s.Reason) $($s.Detail)" }
    @($s.State.reservations | Where-Object { $_.reservation_id -eq $Id })[0]
}

# Steps a reservation until it is reconciled or $Until says stop; returns the step results.
function Invoke-LinSteps($B, $World, [string]$Id, [int]$Max = 12, [scriptblock]$Until = $null) {
    $w = $World
    $out = New-Object Collections.Generic.List[object]
    for ($i = 0; $i -lt $Max; $i++) {
        $r = Get-LinRes $w $Id
        if ($r.state -eq 'reconciled' -or ($Until -and (& $Until $r))) { break }
        $out.Add((Invoke-AapLinStep -Backend $B -Reservation $r -BaseSha256 $w.BaseSha))
    }
    $out.ToArray()
}

function Get-LinJournalLines($World, [string]$Id) {
    $p = Join-Path $World.Journal "$Id.jsonl"
    if (-not [IO.File]::Exists($p)) { return @() }
    @([IO.File]::ReadAllLines($p) | Where-Object { $_ })
}
function Get-LinJournal($World, [string]$Id) { @(Get-LinJournalLines $World $Id | ForEach-Object { ConvertFrom-LinJson $_ }) }

# validate.py in file mode: every journal line and every recorded exchange, one file each. Returns the FAIL lines.
function Invoke-LinValidator($World, [string]$Contract, [string[]]$Docs) {
    $dir = Join-Path $World.Root ('v-' + [guid]::NewGuid().ToString('n').Substring(0, 8))
    [void][IO.Directory]::CreateDirectory($dir)
    $files = @(for ($i = 0; $i -lt $Docs.Count; $i++) { $f = Join-Path $dir "$i.json"; [IO.File]::WriteAllText($f, $Docs[$i], $script:Utf8); $f })
    if (-not @($files).Count) { return @('no documents') }
    $ErrorActionPreference = 'Continue'
    $out = @(& python -B -I $script:Validator $Contract @files 2>&1 | ForEach-Object { "$_" })
    @($out | Where-Object { $_ -notlike 'ok    *' })
}

# Every file under the world but the clones' ssh folders (where the private key belongs), as bytes, searched for each
# secret (byte-exact). -All searches the ssh folders too.
function Find-LinSecret($World, [string[]]$Secrets, [switch]$All) {
    $hits = New-Object Collections.Generic.List[string]
    foreach ($f in [IO.Directory]::GetFiles($World.Root, '*', [IO.SearchOption]::AllDirectories)) {
        if (-not $All -and $f -like "$($World.Clones)\*\ssh\*") { continue }
        $text = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($f))
        foreach ($s in $Secrets) { if ($s -and $text.Contains($s)) { $hits.Add($f) } }
    }
    , $hits.ToArray()
}

# A child process that builds the backend over the same world, sets a fault point and steps one reservation; it kills
# itself at the fault (exit -1). Plain .ps1 files, CreateNoWindow, no data but paths on the command line.
function Start-LinChild($World, [string]$Fault, [string]$Id, [int]$Steps = 12) {
    $script = Join-Path $World.Root 'child.ps1'
    if (-not (Test-Path -LiteralPath $script)) {
        [IO.File]::WriteAllText($script, @'
param([string]$Helpers, [string]$WorldFile, [string]$Fault, [string]$Id, [int]$Steps)
$ErrorActionPreference = 'Stop'
$WarningPreference = 'SilentlyContinue'
. $Helpers
Import-Module $script:CapModule
Import-Module $script:BackendModule
$w = Read-LinWorld $WorldFile
$B = New-LinBackend $w
if ($Fault) { Set-LinModuleVar 'Fault' $Fault }
$res = Invoke-LinSteps $B $w $Id $Steps
[Console]::Out.WriteLine('steps ' + @($res).Count + ' ' + ((@($res) | ForEach-Object { $_.Action }) -join ','))
'@, $script:Utf8)
    }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Process -Id $PID).Path
    $argv = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $script, (Join-Path $PSScriptRoot 'LinBackendTestHelpers.ps1'), $World.File, $Fault, $Id, "$Steps")
    $psi.Arguments = ($argv | ForEach-Object { if ($_ -eq '') { '""' } else { '"' + $_ + '"' } }) -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    if ($env:AAP_LINBACKEND_MODULE) { $psi.EnvironmentVariables['AAP_LINBACKEND_MODULE'] = $env:AAP_LINBACKEND_MODULE }
    $p = [Diagnostics.Process]::Start($psi)
    $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit(180000)) { $p.Kill(); throw "child did not exit" }
    $p.WaitForExit()
    [pscustomobject]@{ ExitCode = $p.ExitCode; Out = $o.Result; Err = $e.Result }
}
