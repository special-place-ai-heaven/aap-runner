# Production provider for AapLinBackend.psm1: the only place the Linux backend calls Hyper-V, Storage, CIM, IMAPI2,
# ssh-keygen and file hashing. Windows PowerShell 5.1 and PowerShell 7 on a Hyper-V host, elevated (the supervisor). NOT
# RUN by P11: authored against the documented cmdlets and APIs and exercised only through fakes; the first real run is the
# D2 lab (P02.1), then P22.
# Every op takes one hashtable and returns plain values. Listings run with -ErrorAction Stop, so a listing error throws
# and never reads as an empty host (allocator.md, Reconcile). The host never attaches or mounts a guest disk (Windows cannot
# read ext4, and parsing guest metadata on the host is what the hostile-guest rule forbids): files go in on the host-built
# seed ISO, and the only data that comes back outside the capped ssh channel is the guest's public host key, read from
# Key-Value Pair Exchange with a bounded, DTD-free XML reader and checked by the backend. The per-clone private key is
# written by ssh-keygen straight into the backend's admin-only folder and never read here. The guest network (switch, NAT,
# port ACLs, guards) is the P10.0 module behind $Backend.Network: NewVm leaves the VM without a network adapter.

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
# Integration services by id, not by their localized names.
$script:GuestServiceId = '6C09BB55-D683-4DA0-8931-C9BF705F6480'
$script:KvpExchangeId = '2A34B1C2-FD73-4043-8A5B-DD2159BC743F'
$script:KeyGenExe = 'C:\Windows\System32\OpenSSH\ssh-keygen.exe'
$script:HostKeyItem = 'aap-ssh-host-key-ed25519'   # the guest-to-host KVP item P15's first-boot unit writes
$script:Utf8 = New-Object Text.UTF8Encoding($false)

function Get-AapLinHvVm([string]$Id) {
    $vm = @(Hyper-V\Get-VM -ErrorAction Stop | Where-Object { ([string]$_.Id).ToLowerInvariant() -ceq $Id })
    if ($vm.Count -ne 1) { throw "AAP_Unexpected: VM not found: $Id" }
    $vm[0]
}

# Bytes under a folder without following reparse points; an unreadable entry throws.
function Get-AapLinTreeBytes([string]$Path) {
    $sum = [double]0
    foreach ($e in [IO.Directory]::GetFileSystemEntries($Path)) {
        $attr = [int][IO.File]::GetAttributes($e)
        if (($attr -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        if (($attr -band [int][IO.FileAttributes]::Directory) -ne 0) { $sum += Get-AapLinTreeBytes $e } else { $sum += (New-Object IO.FileInfo $e).Length }
    }
    $sum
}

# The value of one guest-to-host KVP item, or $null: GuestExchangeItems are Msvm_KvpExchangeDataItem instances embedded as
# XML, which vmms writes and the guest fills; each is read with DTDs prohibited and a size bound.
function Get-AapLinKvpItem($Items, [string]$Name) {
    $settings = New-Object Xml.XmlReaderSettings
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $settings.MaxCharactersInDocument = 16384
    foreach ($item in @($Items)) {
        if ($null -eq $item -or ([string]$item).Length -gt 16384) { continue }
        $doc = New-Object Xml.XmlDocument
        $doc.XmlResolver = $null
        $reader = [Xml.XmlReader]::Create((New-Object IO.StringReader ([string]$item)), $settings)
        try { $doc.Load($reader) } catch { continue } finally { $reader.Dispose() }
        $props = @{}
        foreach ($p in @($doc.SelectNodes('/INSTANCE/PROPERTY'))) { $props[[string]$p.GetAttribute('NAME')] = [string]$p.InnerText }
        if ($props.ContainsKey('Name') -and $props['Name'] -ceq $Name -and $props.ContainsKey('Data')) { return $props['Data'] }
    }
    $null
}

function New-AapLinHyperVProvider {
    <# The provider hashtable New-AapLinBackend expects. #>
    $p = @{}
    $p.GetVolumeGuid = { param($a)
        $m = [regex]::Match([string](Storage\Get-Volume -FilePath $a.Path -ErrorAction Stop).UniqueId, '\{([0-9a-fA-F-]{36})\}')
        $m.Groups[1].Value.ToLowerInvariant()
    }
    $p.GetHostSecurity = { param($a)
        # Hyper-V Administrators by SID (its name is localized); members as SIDs.
        $group = (New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-578').Translate([Security.Principal.NTAccount]).Value.Split('\')[-1]
        $members = @(([ADSI]"WinNT://./$group,group").psbase.Invoke('Members') | ForEach-Object {
                (New-Object Security.Principal.SecurityIdentifier ([byte[]]$_.GetType().InvokeMember('objectSid', 'GetProperty', $null, $_, $null)), 0).Value })
        @{ EnhancedSessionMode = [bool](Hyper-V\Get-VMHost -ErrorAction Stop).EnableEnhancedSessionMode; HyperVAdmins = [object[]]$members }
    }
    # The hash reads the backend's own handle on the base (shared for reading only, held until the differencing disk exists).
    $p.HashFile = { param($a)
        $h = [Security.Cryptography.SHA256]::Create()
        try { $a.Stream.Position = 0; ([BitConverter]::ToString($h.ComputeHash($a.Stream)) -replace '-', '').ToLowerInvariant() } finally { $h.Dispose() }
    }
    $p.NewDiffDisk = { param($a) [void](Hyper-V\New-VHD -Path $a.Path -ParentPath $a.Parent -Differencing) }
    $p.GetVhdParent = { param($a) [string](Hyper-V\Get-VHD -Path $a.Path -ErrorAction Stop).ParentPath }
    # The per-clone management key: ssh-keygen writes id_ed25519 (private) and id_ed25519.pub into the backend's new
    # folder, whose protected SYSTEM/Administrators DACL the files inherit. Only the public line is read and returned.
    $p.NewKeyPair = { param($a)
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $script:KeyGenExe
        $psi.Arguments = '-q -t ed25519 -N "" -C aap-management -f "{0}"' -f (Join-Path $a.Dir 'id_ed25519')
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.RedirectStandardInput = $true
        $proc = [Diagnostics.Process]::Start($psi)
        try {
            $proc.StandardInput.Close()
            $o = $proc.StandardOutput.ReadToEndAsync(); $e = $proc.StandardError.ReadToEndAsync()
            if (-not $proc.WaitForExit(30000)) { $proc.Kill(); throw 'AAP_KeyInvalid: ssh-keygen did not finish' }
            $null = $o.Result; $null = $e.Result
            if ($proc.ExitCode -ne 0) { throw "AAP_KeyInvalid: ssh-keygen exited $($proc.ExitCode)" }
        } finally { $proc.Dispose() }
        $pub = Join-Path $a.Dir 'id_ed25519.pub'
        if ((New-Object IO.FileInfo $pub).Length -gt 512) { throw 'AAP_KeyInvalid: the public key file is too large' }
        $parts = ([IO.File]::ReadAllText($pub)).Trim().Split(' ')
        if ($parts.Count -lt 2) { throw 'AAP_KeyInvalid: not a public key line' }
        "$($parts[0]) $($parts[1])"
    }
    # The seed: an ISO 9660 + Joliet image labelled CIDATA (cloud-init NoCloud; Joliet keeps the lower-case names cloud-init
    # looks for), built from the backend's text in a folder of its own beside the ISO and written by AapLinIsoWriter (compiled
    # by New-AapLinBackend with an admin-only %TMP%). The folder goes as soon as the image is written.
    $p.NewSeedImage = { param($a)
        if (-not ('AapLinIsoWriter' -as [type])) { throw 'AAP_SeedInvalid: the ISO writer is compiled by New-AapLinBackend' }
        $dir = "$($a.Path).files"
        if (Test-Path -LiteralPath $dir) { throw "AAP_UnsafePath: a leftover seed folder: $dir" }
        [void][IO.Directory]::CreateDirectory($dir)
        try {
            foreach ($k in @($a.Files.Keys)) {
                $fs = New-Object IO.FileStream((Join-Path $dir $k), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                try { $b = $script:Utf8.GetBytes([string]$a.Files[$k]); $fs.Write($b, 0, $b.Length) } finally { $fs.Dispose() }
            }
            $img = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
            $img.FileSystemsToCreate = 3   # ISO 9660 and Joliet
            $img.VolumeName = $a.Label
            $img.Root.AddTree($dir, $false)
            $res = $img.CreateResultImage()
            [AapLinIsoWriter]::Save($res.ImageStream, $a.Path, [int]$res.BlockSize, [int]$res.TotalBlocks)
        } finally {
            foreach ($f in [IO.Directory]::GetFiles($dir)) { [IO.File]::Delete($f) }
            [IO.Directory]::Delete($dir)
        }
    }
    $p.NewVm = { param($a)
        # Every VM file inside the reservation's clone folder (no Hyper-V default host folder); checkpoints off, TurnOff,
        # Nothing; the image's needs (images/ubuntu-24.04/INTEGRATION.md, P11 item 1): generation 2, Secure Boot with the
        # Microsoft UEFI CA (Ubuntu's shim), static memory, one SCSI disk, the seed as the one DVD, booting from the disk.
        # Nested virtualization exposed (hosted Ubuntu runners offer /dev/kvm). No file copy; Key-Value Pair Exchange on, for
        # the guest's host key only (guest-transport.md, Linux candidate). No network adapter: P10.0's Attach adds it.
        $vm = Hyper-V\New-VM -Name $a.Name -Path $a.Path -Generation 2 -MemoryStartupBytes ([int64]$a.MemGib * 1GB) -VHDPath $a.OsDisk
        Hyper-V\Set-VM -VM $vm -ProcessorCount $a.Cpus -StaticMemory -CheckpointType Disabled -AutomaticStopAction TurnOff -AutomaticStartAction Nothing -SmartPagingFilePath $a.Path -SnapshotFileLocation $a.Path
        Hyper-V\Set-VMProcessor -VM $vm -ExposeVirtualizationExtensions $true
        Hyper-V\Set-VMFirmware -VM $vm -EnableSecureBoot On -SecureBootTemplate 'MicrosoftUEFICertificateAuthority'
        Hyper-V\Add-VMDvdDrive -VM $vm -Path $a.Seed
        Hyper-V\Set-VMFirmware -VM $vm -FirstBootDevice (@(Hyper-V\Get-VMHardDiskDrive -VM $vm)[0])
        foreach ($svc in @(Hyper-V\Get-VMIntegrationService -VM $vm)) {
            if ($svc.Id -like "*\$($script:GuestServiceId)") { Hyper-V\Disable-VMIntegrationService -VMIntegrationService $svc }
            if ($svc.Id -like "*\$($script:KvpExchangeId)") { Hyper-V\Enable-VMIntegrationService -VMIntegrationService $svc }
        }
        Hyper-V\Get-VMNetworkAdapter -VM $vm | Hyper-V\Remove-VMNetworkAdapter
        @{ Id = ([string]$vm.Id).ToLowerInvariant() }
    }
    $p.GetVmConfig = { param($a)
        $vm = Get-AapLinHvVm $a.VmId
        $svc = @(Hyper-V\Get-VMIntegrationService -VM $vm)
        $on = { param($id) [bool](@($svc | Where-Object { $_.Id -like "*\$id" -and $_.Enabled }).Count) }
        $fw = Hyper-V\Get-VMFirmware -VM $vm
        $nics = foreach ($n in @(Hyper-V\Get-VMNetworkAdapter -VM $vm)) {
            $name = ''; $type = ''
            if ($n.SwitchId) { $sw = Hyper-V\Get-VMSwitch -Id $n.SwitchId -ErrorAction Stop; $name = [string]$sw.Name; $type = [string]$sw.SwitchType }
            @{ SwitchName = $name; SwitchType = $type; DhcpGuard = ([string]$n.DhcpGuard -eq 'On'); RouterGuard = ([string]$n.RouterGuard -eq 'On'); MacAddressSpoofing = ([string]$n.MacAddressSpoofing -eq 'On') }
        }
        @{
            Generation = [int]$vm.Generation; CheckpointType = [string]$vm.CheckpointType
            SecureBoot = ([string]$fw.SecureBoot -eq 'On'); SecureBootTemplate = [string]$fw.SecureBootTemplate
            AutomaticStopAction = [string]$vm.AutomaticStopAction; AutomaticStartAction = [string]$vm.AutomaticStartAction
            DynamicMemory = [bool]$vm.DynamicMemoryEnabled; NestedVirtualization = [bool](Hyper-V\Get-VMProcessor -VM $vm).ExposeVirtualizationExtensions
            GuestServiceInterface = (& $on $script:GuestServiceId); KeyValuePairExchange = (& $on $script:KvpExchangeId)
            ConfigurationLocation = [string]$vm.ConfigurationLocation; SnapshotFileLocation = [string]$vm.SnapshotFileLocation; SmartPagingFilePath = [string]$vm.SmartPagingFilePath
            Cpus = [int]$vm.ProcessorCount; MemGib = [int][Math]::Ceiling($vm.MemoryStartup / 1GB)
            Disks = @(Hyper-V\Get-VMHardDiskDrive -VM $vm | ForEach-Object { [string]$_.Path })
            Dvds = @(Hyper-V\Get-VMDvdDrive -VM $vm | Where-Object { $_.Path } | ForEach-Object { [string]$_.Path }); Adapters = @($nics)
            ComPorts = @(Hyper-V\Get-VMComPort -VM $vm | Where-Object { $_.Path }).Count
            GpuPartitions = @(Hyper-V\Get-VMGpuPartitionAdapter -VM $vm -ErrorAction Stop).Count; AssignedDevices = @(Hyper-V\Get-VMAssignableDevice -VM $vm -ErrorAction Stop).Count
        }
    }
    # The guest's public host key as its first boot published it (guest to host Key-Value Pair Exchange), or $null while
    # it has not. The backend checks the shape and pins it before the first SSH command.
    $p.GetHostKey = { param($a)
        $cs = @(Get-CimInstance -Namespace 'root\virtualization\v2' -ClassName Msvm_ComputerSystem -Filter "Name='$((Get-AapLinHvVm $a.VmId).Id)'" -ErrorAction Stop)
        if ($cs.Count -ne 1) { throw 'AAP_Unexpected: no computer system for the VM' }
        $kvp = @(Get-CimAssociatedInstance -InputObject $cs[0] -ResultClassName Msvm_KvpExchangeComponent -ErrorAction Stop)
        if ($kvp.Count -ne 1) { return $null }
        Get-AapLinKvpItem $kvp[0].GuestExchangeItems $script:HostKeyItem
    }
    # Ejects the seed from every DVD drive of the running VM; an empty drive stays empty.
    $p.EjectSeed = { param($a) foreach ($d in @(Hyper-V\Get-VMDvdDrive -VM (Get-AapLinHvVm $a.VmId) | Where-Object { $_.Path })) { Hyper-V\Set-VMDvdDrive -VMDvdDrive $d -Path $null } }
    $p.StartVm = { param($a) $vm = Get-AapLinHvVm $a.VmId; if ($vm.State -ne 'Running') { Hyper-V\Start-VM -VM $vm } }
    $p.StopVm = { param($a) Hyper-V\Stop-VM -VM (Get-AapLinHvVm $a.VmId) -TurnOff -Force }
    $p.RemoveVm = { param($a) Hyper-V\Remove-VM -VM (Get-AapLinHvVm $a.VmId) -Force }
    $p.ListVms = { param($a)
        @(Hyper-V\Get-VM -ErrorAction Stop) | ForEach-Object {
            @{ Id = ([string]$_.Id).ToLowerInvariant(); Name = [string]$_.Name; State = [string]$_.State; Cpus = [int]$_.ProcessorCount; MemGib = [int][Math]::Ceiling($_.MemoryStartup / 1GB) }
        }
    }
    $p.MeasureBytes = { param($a) Get-AapLinTreeBytes $a.Path }
    $p
}

Export-ModuleMember -Function New-AapLinHyperVProvider
