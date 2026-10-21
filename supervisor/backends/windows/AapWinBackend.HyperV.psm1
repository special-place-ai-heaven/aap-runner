# Production provider for AapWinBackend.psm1: the only place the Windows backend calls Hyper-V, Storage and file hashing.
# Windows PowerShell 5.1 and PowerShell 7 on a Hyper-V host, elevated (the supervisor). NOT RUN by P10: authored against
# the documented cmdlets and exercised only through fakes; the first real run is the D2 lab (P02.1), then P22.
# Every op takes one hashtable and returns plain values. Listings run with -ErrorAction Stop, so a listing error throws
# and never reads as an empty host (allocator.md, Reconcile). Import AapWinBackend.psm1 first: WriteUnattend uses its
# exported Select-AapWinPartition and Write-AapWinUnattend. The per-clone password reaches WriteUnattend only as the
# backend's secret object (Length, WriteTo, Clear) and is never a cmdlet's parameter value here.
# The guest network (switch, NAT, port ACLs, guards) is not here: it is the P10.0 module behind $Backend.Network. NewVm
# leaves the VM without a network adapter; P10.0's Attach adds the one adapter the backend then verifies. GetVmConfig
# reports the adapters in host-network-module.md's provider read-back shape, for the shared check.

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
# Integration services by id, not by their localized names.
$script:GuestServiceId = '6C09BB55-D683-4DA0-8931-C9BF705F6480'
$script:KvpExchangeId = '2A34B1C2-FD73-4043-8A5B-DD2159BC743F'

function Get-AapWinHvVm([string]$Id) {
    $vm = @(Hyper-V\Get-VM -ErrorAction Stop | Where-Object { ([string]$_.Id).ToLowerInvariant() -ceq $Id })
    if ($vm.Count -ne 1) { throw "AAP_Unexpected: VM $Id not found" }
    $vm[0]
}

# Bytes under a folder without following reparse points; an unreadable entry throws.
function Get-AapWinTreeBytes([string]$Path) {
    $sum = [double]0
    foreach ($e in [IO.Directory]::GetFileSystemEntries($Path)) {
        $attr = [int][IO.File]::GetAttributes($e)
        if (($attr -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        if (($attr -band [int][IO.FileAttributes]::Directory) -ne 0) { $sum += Get-AapWinTreeBytes $e } else { $sum += (New-Object IO.FileInfo $e).Length }
    }
    $sum
}

function New-AapWinHyperVProvider {
    <# The provider hashtable New-AapWinBackend expects. #>
    if (-not (Get-Command Write-AapWinUnattend -ErrorAction SilentlyContinue)) { throw 'AAP_ProviderInvalid: import AapWinBackend.psm1 before creating the Hyper-V provider' }
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
    $p.NewDisk = { param($a)
        # The scratch disk: dynamic, its maximum size the reservation's cap, formatted NTFS here (a disk this process just
        # created, never a guest-authored one) so the guest's SanPolicy brings it online as its D: temp disk.
        [void](Hyper-V\New-VHD -Path $a.Path -SizeBytes ([uint64]$a.SizeBytes) -Dynamic)
        $disk = Hyper-V\Mount-VHD -Path $a.Path -Passthru | Get-Disk
        try {
            Initialize-Disk -Number $disk.Number -PartitionStyle GPT
            $part = New-Partition -DiskNumber $disk.Number -UseMaximumSize
            [void](Format-Volume -Partition $part -FileSystem NTFS -NewFileSystemLabel 'Temporary Storage' -Confirm:$false)
        } finally { Hyper-V\Dismount-VHD -Path $a.Path }
    }
    $p.WriteUnattend = { param($a)
        # Only into a clone disk that never booted (the backend's rule), on the partition the base layout fixes, mounted
        # with no drive letter at an access path inside the admin-only reservation folder; the path goes before the
        # dismount, so no other account ever sees the volume.
        $mnt = Join-Path (Split-Path -Parent $a.Vhdx) 'mnt'
        $disk = Hyper-V\Mount-VHD -Path $a.Vhdx -NoDriveLetter -Passthru | Get-Disk
        try {
            $os = Select-AapWinPartition -Partitions @(Get-Partition -DiskNumber $disk.Number)
            if ([IO.Directory]::Exists($mnt)) { [IO.Directory]::Delete($mnt) }   # an empty leftover of a crash; anything in it throws
            [void][IO.Directory]::CreateDirectory($mnt)
            Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $os.PartitionNumber -AccessPath ($mnt + '\')
            try { Write-AapWinUnattend -Root $mnt -UserName $a.User -Password $a.Password -Network $a.Network }
            finally { Remove-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $os.PartitionNumber -AccessPath ($mnt + '\') }
        } finally {
            Hyper-V\Dismount-VHD -Path $a.Vhdx
            if ([IO.Directory]::Exists($mnt)) { [IO.Directory]::Delete($mnt) }
        }
    }
    $p.NewVm = { param($a)
        # Every VM file inside the reservation's clone folder (no Hyper-V default host folder); checkpoints off, TurnOff,
        # Nothing; the image's needs (images/windows/INTEGRATION.md, P10 item 1): generation 2, Secure Boot off, nested
        # virtualization exposed, the scratch disk second. No file copy and no key-value exchange: the credential goes
        # in offline through the answer file and PowerShell Direct is the only channel.
        $vm = Hyper-V\New-VM -Name $a.Name -Path $a.Path -Generation 2 -MemoryStartupBytes ([int64]$a.MemGib * 1GB) -VHDPath $a.OsDisk
        Hyper-V\Set-VM -VM $vm -ProcessorCount $a.Cpus -StaticMemory -CheckpointType Disabled -AutomaticStopAction TurnOff -AutomaticStartAction Nothing -SmartPagingFilePath $a.Path -SnapshotFileLocation $a.Path
        Hyper-V\Set-VMProcessor -VM $vm -ExposeVirtualizationExtensions $true
        Hyper-V\Set-VMFirmware -VM $vm -EnableSecureBoot Off
        if ($a.ScratchDisk) { Hyper-V\Add-VMHardDiskDrive -VM $vm -Path $a.ScratchDisk }
        foreach ($svc in @(Hyper-V\Get-VMIntegrationService -VM $vm | Where-Object { $_.Id -like "*\$($script:GuestServiceId)" -or $_.Id -like "*\$($script:KvpExchangeId)" })) {
            Hyper-V\Disable-VMIntegrationService -VMIntegrationService $svc
        }
        Hyper-V\Get-VMNetworkAdapter -VM $vm | Hyper-V\Remove-VMNetworkAdapter
        @{ Id = ([string]$vm.Id).ToLowerInvariant() }
    }
    $p.GetVmConfig = { param($a)
        $vm = Get-AapWinHvVm $a.VmId
        $svc = @(Hyper-V\Get-VMIntegrationService -VM $vm)
        $on = { param($id) [bool](@($svc | Where-Object { $_.Id -like "*\$id" -and $_.Enabled }).Count) }
        # The provider read-back of host-network-module.md (Consumer obligations), as Hyper-V shows each adapter: text values,
        # compared exactly by the shared check; strict mode makes a misspelt property throw instead of reading as unset.
        $nics = foreach ($n in @(Hyper-V\Get-VMNetworkAdapter -VM $vm)) {
            $name = ''; $type = ''
            if ($n.SwitchId) { $sw = Hyper-V\Get-VMSwitch -Id $n.SwitchId -ErrorAction Stop; $name = [string]$sw.Name; $type = [string]$sw.SwitchType }
            @{  SwitchName = $name; SwitchType = $type
                DhcpGuard = [string]$n.DhcpGuard; RouterGuard = [string]$n.RouterGuard; MacAddressSpoofing = [string]$n.MacAddressSpoofing
                PortMirroringMode = [string]$n.PortMirroringMode; VlanMode = [string]$n.VlanSetting.OperationMode; StormLimit = [string]$n.StormLimit
                LegacyAcls = @(Hyper-V\Get-VMNetworkAdapterAcl -VMNetworkAdapter $n).Count
                # the other VMs with an adapter on the same switch; the host's own adapters are not VMs
                Peers = @(Hyper-V\Get-VMNetworkAdapter -All | Where-Object { $name -and -not $_.IsManagementOs -and $_.SwitchName -ceq $name -and $_.VMId -ne $vm.Id } |
                    ForEach-Object { [string]$_.VMName })
                Acls = @(Hyper-V\Get-VMNetworkAdapterExtendedAcl -VMNetworkAdapter $n | ForEach-Object {
                        @{ Action = [string]$_.Action; Direction = [string]$_.Direction; RemoteAddress = [string]$_.RemoteIPAddress
                            LocalAddress = [string]$_.LocalIPAddress; Protocol = [string]$_.Protocol; RemotePort = [string]$_.RemotePort
                            LocalPort = [string]$_.LocalPort; Weight = $_.Weight; Stateful = [string]$_.Stateful; IsolationId = [string]$_.IsolationID } })
            }
        }
        @{
            Generation = [int]$vm.Generation; CheckpointType = [string]$vm.CheckpointType
            AutomaticStopAction = [string]$vm.AutomaticStopAction; AutomaticStartAction = [string]$vm.AutomaticStartAction
            GuestServiceInterface = (& $on $script:GuestServiceId); KeyValuePairExchange = (& $on $script:KvpExchangeId)
            ConfigurationLocation = [string]$vm.ConfigurationLocation; SnapshotFileLocation = [string]$vm.SnapshotFileLocation; SmartPagingFilePath = [string]$vm.SmartPagingFilePath
            Cpus = [int]$vm.ProcessorCount; MemGib = [int][Math]::Ceiling($vm.MemoryStartup / 1GB)
            Disks = @(Hyper-V\Get-VMHardDiskDrive -VM $vm | ForEach-Object { [string]$_.Path }); Adapters = @($nics)
            ComPorts = @(Hyper-V\Get-VMComPort -VM $vm | Where-Object { $_.Path }).Count; DvdDrives = @(Hyper-V\Get-VMDvdDrive -VM $vm).Count
            GpuPartitions = @(Hyper-V\Get-VMGpuPartitionAdapter -VM $vm -ErrorAction Stop).Count; AssignedDevices = @(Hyper-V\Get-VMAssignableDevice -VM $vm -ErrorAction Stop).Count
        }
    }
    $p.StartVm = { param($a) $vm = Get-AapWinHvVm $a.VmId; if ($vm.State -ne 'Running') { Hyper-V\Start-VM -VM $vm } }
    $p.StopVm = { param($a) Hyper-V\Stop-VM -VM (Get-AapWinHvVm $a.VmId) -TurnOff -Force }
    $p.RemoveVm = { param($a) Hyper-V\Remove-VM -VM (Get-AapWinHvVm $a.VmId) -Force }
    $p.ListVms = { param($a)
        @(Hyper-V\Get-VM -ErrorAction Stop) | ForEach-Object {
            @{ Id = ([string]$_.Id).ToLowerInvariant(); Name = [string]$_.Name; State = [string]$_.State; Cpus = [int]$_.ProcessorCount; MemGib = [int][Math]::Ceiling($_.MemoryStartup / 1GB) }
        }
    }
    $p.MeasureBytes = { param($a) Get-AapWinTreeBytes $a.Path }
    $p
}

Export-ModuleMember -Function New-AapWinHyperVProvider
