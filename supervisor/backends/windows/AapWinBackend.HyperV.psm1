# Production provider for AapWinBackend.psm1: the only place the Windows backend calls Hyper-V, Storage and file hashing.
# Windows PowerShell 5.1 and PowerShell 7 on a Hyper-V host, elevated (the supervisor). NOT RUN by P10: authored against
# the documented cmdlets and exercised only through fakes; the first real run is the D2 lab (P02.1), then P22.
# Every op takes one hashtable and returns plain values. Listings run with -ErrorAction Stop, so a listing error throws
# and never reads as an empty host (allocator.md, Reconcile). Import AapWinBackend.psm1 first: WriteUnattend uses its
# exported Select-AapWinPartition, New-AapWinUnattend and Write-AapWinGuestFile.
# The guest network (switch, NAT, port ACLs, guards) is not here: it is the P10.0 module behind $Backend.Network. NewVm
# leaves the VM without a network adapter; P10.0's Attach adds the one adapter the backend then verifies.

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$script:Utf8 = New-Object Text.UTF8Encoding($false)

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
    if (-not (Get-Command Write-AapWinGuestFile -ErrorAction SilentlyContinue)) { throw 'AAP_ProviderInvalid: import AapWinBackend.psm1 before creating the Hyper-V provider' }
    $p = @{}
    $p.GetVolumeGuid = { param($a)
        $m = [regex]::Match([string](Storage\Get-Volume -FilePath $a.Path -ErrorAction Stop).UniqueId, '\{([0-9a-fA-F-]{36})\}')
        $m.Groups[1].Value.ToLowerInvariant()
    }
    $p.HashFile = { param($a) (Get-FileHash -LiteralPath $a.Path -Algorithm SHA256).Hash.ToLowerInvariant() }
    $p.NewDiffDisk = { param($a) [void](Hyper-V\New-VHD -Path $a.Path -ParentPath $a.Parent -Differencing) }
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
        # Only into a clone disk that never booted (the backend's rule), on the partition the base layout fixes.
        $disk = Hyper-V\Mount-VHD -Path $a.Vhdx -Passthru | Get-Disk
        try {
            $os = Select-AapWinPartition -Partitions @(Get-Partition -DiskNumber $disk.Number)
            if (-not $os.DriveLetter) { $os | Add-PartitionAccessPath -AssignDriveLetter; $os = Get-Partition -DiskNumber $disk.Number -PartitionNumber $os.PartitionNumber }
            if (-not $os.DriveLetter) { throw 'AAP_DiskLayout: no drive letter is free for the Windows partition' }
            $bytes = $script:Utf8.GetBytes((New-AapWinUnattend -UserName $a.User -Password $a.Password))
            try { Write-AapWinGuestFile -Root "$($os.DriveLetter):\" -RelPath 'Windows\Panther\unattend.xml' -Bytes $bytes } finally { [Array]::Clear($bytes, 0, $bytes.Length) }
        } finally { Hyper-V\Dismount-VHD -Path $a.Vhdx }
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
        foreach ($svc in 'Guest Service Interface', 'Key-Value Pair Exchange') { Hyper-V\Disable-VMIntegrationService -VM $vm -Name $svc }
        Hyper-V\Get-VMNetworkAdapter -VM $vm | Hyper-V\Remove-VMNetworkAdapter
        @{ Id = ([string]$vm.Id).ToLowerInvariant() }
    }
    $p.GetVmConfig = { param($a)
        $vm = Get-AapWinHvVm $a.VmId
        $svc = @(Hyper-V\Get-VMIntegrationService -VM $vm)
        $on = { param($name) [bool](@($svc | Where-Object { $_.Name -eq $name -and $_.Enabled }).Count) }
        $nics = foreach ($n in @(Hyper-V\Get-VMNetworkAdapter -VM $vm)) {
            $type = ''
            if ($n.SwitchName) { $type = [string](Hyper-V\Get-VMSwitch -Name $n.SwitchName -ErrorAction Stop).SwitchType }
            @{ SwitchName = [string]$n.SwitchName; SwitchType = $type; DhcpGuard = ([string]$n.DhcpGuard -eq 'On'); RouterGuard = ([string]$n.RouterGuard -eq 'On'); MacAddressSpoofing = ([string]$n.MacAddressSpoofing -eq 'On') }
        }
        @{
            Generation = [int]$vm.Generation; CheckpointType = [string]$vm.CheckpointType
            AutomaticStopAction = [string]$vm.AutomaticStopAction; AutomaticStartAction = [string]$vm.AutomaticStartAction
            GuestServiceInterface = (& $on 'Guest Service Interface'); KeyValuePairExchange = (& $on 'Key-Value Pair Exchange')
            ConfigurationLocation = [string]$vm.ConfigurationLocation; SnapshotFileLocation = [string]$vm.SnapshotFileLocation; SmartPagingFilePath = [string]$vm.SmartPagingFilePath
            Cpus = [int]$vm.ProcessorCount; MemGib = [int][Math]::Ceiling($vm.MemoryStartup / 1GB)
            Disks = @(Hyper-V\Get-VMHardDiskDrive -VM $vm | ForEach-Object { [string]$_.Path }); Adapters = @($nics)
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
