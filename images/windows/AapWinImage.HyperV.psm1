# P06 production provider: the only place the image builder calls Hyper-V, Storage, DISM, PowerShell Direct and ACL APIs.
# Windows PowerShell 5.1 (the supervisor's host) and PowerShell 7 on a Hyper-V host, elevated. NOT RUN by P06: authored
# against the documented cmdlets and exercised only through fakes; the first real run is the D2 lab (README, What is not done).
# Every op takes one hashtable. Nothing here downloads: input verification is P03's Invoke-AapManifest -Offline.
# The build guest is trusted until sysprep (no job has run in it), so PowerShell Direct is used directly here; replies are
# still size-bounded, and the module validates their content.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:Common = Join-Path $PSScriptRoot '..\common\AapArtifact.psm1'
$script:Manifest = Join-Path $PSScriptRoot '..\common\artifacts.manifest.json'
$script:TrustedInstaller = 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
$script:VmSid = 'S-1-5-83-0'   # NT VIRTUAL MACHINE\Virtual Machines: VM worker processes read the parent of a differencing disk

function Get-AapGuestCredential([string]$User, [string]$Password) {
    New-Object Management.Automation.PSCredential ".\$User", (ConvertTo-SecureString -String $Password -AsPlainText -Force)
}
function Get-AapWindowsPartitionRoot([int]$DiskNumber) {
    foreach ($p in @(Get-Partition -DiskNumber $DiskNumber | Where-Object { $_.Type -eq 'Basic' -or $_.GptType -eq '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}' })) {
        if (-not $p.DriveLetter) { $p | Add-PartitionAccessPath -AssignDriveLetter; $p = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $p.PartitionNumber }
        $root = "$($p.DriveLetter):\"
        if (Test-Path -LiteralPath (Join-Path $root 'Windows\System32')) { return $root }
    }
    throw 'AAP_DiskLayout: no Windows partition on the disk'
}
function Get-AapTreeBytes([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer) { return [double]$item.Length }
    $sum = [double]0
    foreach ($e in [IO.Directory]::GetFileSystemEntries($Path)) {
        $attr = [int][IO.File]::GetAttributes($e)
        if (($attr -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        if (($attr -band [int][IO.FileAttributes]::Directory) -ne 0) { $sum += Get-AapTreeBytes $e } else { $sum += (New-Object IO.FileInfo $e).Length }
    }
    return $sum
}

function New-AapWinHyperVProvider {
    <# The provider hashtable Invoke-AapWinImageBuild expects. #>
    $p = @{}
    $p.TestRootTrust = { param($a)
        # P03's rules (owner, ACL masks, reparse, ancestors, fixed drive) plus the admin-only rule of backend-lifecycle.md
        # revision 2: a protected DACL and no ACE, inheritable or inherit-only included, for anyone but the admin SIDs.
        Import-Module $script:Common -Force
        @(Get-AapStagingProblems -Root $a.Path | ForEach-Object { $_.Text })
        if (Test-Path -LiteralPath $a.Path -PathType Container) {
            $acl = Get-Acl -LiteralPath $a.Path
            if (-not $acl.AreAccessRulesProtected) { "$($a.Path): the DACL inherits from its parent" }
            foreach ($r in @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))) {
                if (@('S-1-5-18', 'S-1-5-32-544', $script:TrustedInstaller) -notcontains $r.IdentityReference.Value) { "$($a.Path): $($r.IdentityReference.Value) has an access entry" }
            }
        }
    }
    $p.GetVolume = { param($a)
        $v = Get-Volume -FilePath $a.Path
        $m = [regex]::Match([string]$v.UniqueId, '\{([0-9a-fA-F-]{36})\}')
        @{ Guid = $m.Groups[1].Value.ToLowerInvariant(); FreeBytes = [double]$v.SizeRemaining }
    }
    $p.MeasureBytes = { param($a) Get-AapTreeBytes $a.Path }
    $p.VerifyInputs = { param($a)
        Import-Module $script:Common -Force
        $m = Read-AapManifest -Path $script:Manifest
        $r = Invoke-AapManifest -Manifest $m -StagingRoot $a.StagingRoot -Name $a.Names -Offline
        $paths = @{}
        foreach ($e in @($m.entries | Where-Object { @($a.Names) -ccontains $_.name })) { $paths[$e.name] = Get-AapStagedPath -StagingRoot $a.StagingRoot -Entry $e }
        @{ Complete = [bool]$r.Complete; Paths = $paths; Detail = "rejected: $(@($r.Rejected) -join ', '); unverified: $(@($r.Unverified) -join ', ')" }
    }
    $p.NewBuildDisk = { param($a)
        [void](Hyper-V\New-VHD -Path $a.Path -SizeBytes ([uint64]$a.SizeGib * 1GB) -Dynamic)
        if ($a.Format) {
            $disk = Hyper-V\Mount-VHD -Path $a.Path -Passthru | Get-Disk
            try {
                Initialize-Disk -Number $disk.Number -PartitionStyle GPT
                $part = New-Partition -DiskNumber $disk.Number -UseMaximumSize
                [void](Format-Volume -Partition $part -FileSystem NTFS -NewFileSystemLabel 'Temporary Storage' -Confirm:$false)
            } finally { Hyper-V\Dismount-VHD -Path $a.Path }
        }
    }
    $p.ApplyWindowsImage = { param($a)
        $iso = Mount-DiskImage -ImagePath $a.IsoPath -Access ReadOnly -StorageType ISO -PassThru
        try {
            $wim = "$(($iso | Get-Volume).DriveLetter):\sources\install.wim"
            $img = @(Get-WindowsImage -ImagePath $wim | Where-Object { $_.ImageName -ceq $a.Edition })
            if ($img.Count -ne 1) { throw "AAP_MediaMismatch: edition '$($a.Edition)' is not in the media" }
            $info = Get-WindowsImage -ImagePath $wim -Index $img[0].ImageIndex
            $disk = Hyper-V\Mount-VHD -Path $a.Vhdx -Passthru | Get-Disk
            try {
                Initialize-Disk -Number $disk.Number -PartitionStyle GPT
                $efi = New-Partition -DiskNumber $disk.Number -Size 260MB -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
                [void](Format-Volume -Partition $efi -FileSystem FAT32 -NewFileSystemLabel 'System' -Confirm:$false)
                [void](New-Partition -DiskNumber $disk.Number -Size 16MB -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}')
                $os = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter
                [void](Format-Volume -Partition $os -FileSystem NTFS -NewFileSystemLabel 'Windows' -Confirm:$false)
                $efi | Add-PartitionAccessPath -AssignDriveLetter
                $efiRoot = "$((Get-Partition -DiskNumber $disk.Number -PartitionNumber $efi.PartitionNumber).DriveLetter):\"
                $osRoot = "$((Get-Partition -DiskNumber $disk.Number -PartitionNumber $os.PartitionNumber).DriveLetter):\"
                [void](Expand-WindowsImage -ImagePath $wim -Index $img[0].ImageIndex -ApplyPath $osRoot)
                & (Join-Path $env:SystemRoot 'System32\bcdboot.exe') (Join-Path $osRoot 'Windows') /s $efiRoot.TrimEnd('\') /f UEFI | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "AAP_DiskLayout: bcdboot exited $LASTEXITCODE" }
                foreach ($k in @($a.Files.Keys)) { $t = Join-Path $osRoot $k; [void][IO.Directory]::CreateDirectory((Split-Path -Parent $t)); [IO.File]::WriteAllText($t, [string]$a.Files[$k], (New-Object Text.UTF8Encoding($false))) }
                foreach ($k in @($a.CopyFiles.Keys)) { $t = Join-Path $osRoot $k; [void][IO.Directory]::CreateDirectory((Split-Path -Parent $t)); Copy-Item -LiteralPath $a.CopyFiles[$k] -Destination $t }
            } finally { Hyper-V\Dismount-VHD -Path $a.Vhdx }
            @{ ImageIndex = $img[0].ImageIndex; Build = [string]$info.Version }
        } finally { Dismount-DiskImage -ImagePath $a.IsoPath | Out-Null }
    }
    $p.NewDiffDisk = { param($a) [void](Hyper-V\New-VHD -Path $a.Path -ParentPath $a.Parent -Differencing) }
    $p.WriteOfflineFiles = { param($a)
        $disk = Hyper-V\Mount-VHD -Path $a.Vhdx -Passthru | Get-Disk
        try {
            $root = Get-AapWindowsPartitionRoot $disk.Number
            foreach ($k in @($a.Files.Keys)) { $t = Join-Path $root $k; [void][IO.Directory]::CreateDirectory((Split-Path -Parent $t)); [IO.File]::WriteAllText($t, [string]$a.Files[$k], (New-Object Text.UTF8Encoding($false))) }
        } finally { Hyper-V\Dismount-VHD -Path $a.Vhdx }
    }
    $p.NewVm = { param($a)
        $vm = Hyper-V\New-VM -Name $a.Name -Path $a.Path -Generation 2 -MemoryStartupBytes ([int64]$a.MemGib * 1GB) -VHDPath $a.OsDisk
        Hyper-V\Set-VM -VM $vm -ProcessorCount $a.Cpus -StaticMemory -CheckpointType Disabled -AutomaticStopAction TurnOff -AutomaticStartAction Nothing -SmartPagingFilePath $a.Path -SnapshotFileLocation $a.Path
        Hyper-V\Set-VMProcessor -VM $vm -ExposeVirtualizationExtensions $true      # upstream enables Hyper-V, Containers and WSL2 inside the guest
        Hyper-V\Set-VMFirmware -VM $vm -EnableSecureBoot Off                         # upstream sets bcdedit TESTSIGNING ON
        Hyper-V\Add-VMHardDiskDrive -VM $vm -Path $a.TempDisk
        Hyper-V\Disable-VMIntegrationService -VM $vm -Name 'Guest Service Interface'
        if ($a.SwitchName) { Hyper-V\Connect-VMNetworkAdapter -VMName $a.Name -SwitchName $a.SwitchName }
    }
    $p.StartVm = { param($a) if ((Hyper-V\Get-VM -Name $a.VmName).State -ne 'Running') { Hyper-V\Start-VM -Name $a.VmName } }
    $p.StopVm = { param($a)
        Hyper-V\Stop-VM -Name $a.VmName -Force
        $until = (Get-Date).AddSeconds($a.TimeoutSeconds)
        while ((Hyper-V\Get-VM -Name $a.VmName).State -ne 'Off') { if ((Get-Date) -gt $until) { throw 'AAP_RebootTimeout: guest did not shut down' }; Start-Sleep -Seconds 5 }
    }
    $p.RestartVm = { param($a) Hyper-V\Restart-VM -Name $a.VmName -Type Reboot -Force }
    $p.RemoveVm = { param($a)
        $vm = Hyper-V\Get-VM -Name $a.Name -ErrorAction SilentlyContinue
        if ($vm) { if ($vm.State -ne 'Off') { Hyper-V\Stop-VM -VM $vm -TurnOff -Force }; Hyper-V\Remove-VM -VM $vm -Force }
    }
    $p.WaitGuestReady = { param($a)
        $cred = Get-AapGuestCredential $a.User $a.Password
        $until = (Get-Date).AddSeconds($a.TimeoutSeconds)
        while ((Get-Date) -lt $until) {
            try { if ((Invoke-Command -VMName $a.VmName -Credential $cred -ScriptBlock { 'ready' } -ErrorAction Stop) -eq 'ready') { return $true } } catch { Start-Sleep -Seconds 15 }
        }
        return $false
    }
    $p.SendFile = { param($a)
        $s = New-PSSession -VMName $a.VmName -Credential (Get-AapGuestCredential $a.User $a.Password)
        try {
            Invoke-Command -Session $s -ScriptBlock { param($d) [void][IO.Directory]::CreateDirectory($d) } -ArgumentList (Split-Path -Parent $a.GuestPath)
            Copy-Item -LiteralPath $a.HostPath -Destination $a.GuestPath -ToSession $s -Force
        } finally { Remove-PSSession $s }
    }
    $p.InvokeGuest = { param($a)
        $job = Invoke-Command -VMName $a.VmName -Credential (Get-AapGuestCredential $a.User $a.Password) -AsJob -ArgumentList $a.Script, $a.RequestPath -ScriptBlock {
            param($script, $request)
            & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script -RequestPath $request
        }
        try {
            if (-not (Wait-Job -Job $job -Timeout $a.TimeoutSeconds)) { throw "AAP_GuestTimeout: no reply within $($a.TimeoutSeconds) s" }
            $out = (@(Receive-Job -Job $job -ErrorAction SilentlyContinue | ForEach-Object { [string]$_ }) -join "`n")
            if ($out.Length -gt $a.MaxBytes) { return $out.Substring(0, $a.MaxBytes + 1) }
            return $out.Trim()
        } finally { Remove-Job -Job $job -Force }
    }
    $p.ReceiveFile = { param($a)
        $s = New-PSSession -VMName $a.VmName -Credential (Get-AapGuestCredential $a.User $a.Password)
        try {
            $len = Invoke-Command -Session $s -ScriptBlock { param($f) if (Test-Path -LiteralPath $f -PathType Leaf) { (Get-Item -LiteralPath $f).Length } else { -1 } } -ArgumentList $a.GuestPath
            if ($len -lt 0) { throw "AAP_HostileGuest: $($a.GuestPath) is missing" }
            if ($len -gt $a.MaxBytes) { throw "AAP_HostileGuest: $($a.GuestPath) is over $($a.MaxBytes) bytes" }
            Copy-Item -LiteralPath $a.GuestPath -Destination $a.HostPath -FromSession $s -Force
        } finally { Remove-PSSession $s }
    }
    $p.OptimizeDisk = { param($a)
        Hyper-V\Mount-VHD -Path $a.Vhdx -ReadOnly
        try { Hyper-V\Optimize-VHD -Path $a.Vhdx -Mode Full } finally { Hyper-V\Dismount-VHD -Path $a.Vhdx }
    }
    $p.MountReadOnly = { param($a)
        $disk = Hyper-V\Mount-VHD -Path $a.Vhdx -ReadOnly -Passthru | Get-Disk
        Get-AapWindowsPartitionRoot $disk.Number
    }
    $p.Dismount = { param($a) if ((Hyper-V\Get-VHD -Path $a.Vhdx -ErrorAction SilentlyContinue).Attached) { Hyper-V\Dismount-VHD -Path $a.Vhdx } }
    $p.ReadOfflineRegistry = { param($a)
        # The hive file is copied out of the read-only volume and loaded under a unique name, read, then unloaded.
        $copy = Join-Path ([IO.Path]::GetTempPath()) ("aap-hive-" + [guid]::NewGuid().ToString('n'))
        $mountName = 'AAPSCAN_' + [guid]::NewGuid().ToString('n').Substring(0, 8)
        $reg = Join-Path $env:SystemRoot 'System32\reg.exe'
        Copy-Item -LiteralPath (Join-Path $a.MountRoot "Windows\System32\config\$($a.Hive)") -Destination $copy
        try {
            & $reg load "HKLM\$mountName" $copy | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "AAP_ScanIncomplete: cannot load the $($a.Hive) hive" }
            try {
                $key = "Registry::HKEY_LOCAL_MACHINE\$mountName\$($a.Key)"
                try { $exists = Test-Path -LiteralPath $key } catch { throw "AAP_ScanIncomplete: cannot read $($a.Hive)\$($a.Key)" }
                if (-not $exists) { return $null }
                if ($null -eq $a.Name) { return 'present' }
                $v = Get-ItemProperty -LiteralPath $key -Name $a.Name -ErrorAction SilentlyContinue
                if ($v) { return [string]$v.($a.Name) } else { return $null }
            } finally { [GC]::Collect(); & $reg unload "HKLM\$mountName" | Out-Null }
        } finally { Remove-Item -LiteralPath $copy -Force -ErrorAction SilentlyContinue }
    }
    $p.SetReadOnlyAcl = { param($a)
        # Owner Administrators; SYSTEM, Administrators and the VM worker group may read; nobody may write. Inheritance off.
        $isDir = Test-Path -LiteralPath $a.Path -PathType Container
        $acl = $(if ($isDir) { New-Object Security.AccessControl.DirectorySecurity } else { New-Object Security.AccessControl.FileSecurity })
        $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'))
        $acl.SetAccessRuleProtection($true, $false)
        $inherit = $(if ($isDir) { [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit' } else { [Security.AccessControl.InheritanceFlags]::None })
        foreach ($sid in 'S-1-5-18', 'S-1-5-32-544', $script:VmSid) {
            $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule (New-Object Security.Principal.SecurityIdentifier $sid), 'ReadAndExecute, Synchronize', $inherit, 'None', 'Allow'))
        }
        if (-not $isDir) { [IO.File]::SetAttributes($a.Path, [IO.FileAttributes]::ReadOnly) }
        Set-Acl -LiteralPath $a.Path -AclObject $acl
    }
    $p.GetVmMemoryOverheadMib = { param($a)
        $id = [string](Hyper-V\Get-VM -Name $a.VmName).Id
        $w = @(Get-CimInstance Win32_Process -Filter "Name='vmwp.exe'" | Where-Object { $_.CommandLine -match $id })
        if ($w.Count -ne 1) { throw 'AAP_Unmeasured: VM worker process not found' }
        [int][Math]::Ceiling($w[0].WorkingSetSize / 1MB)
    }
    return $p
}

Export-ModuleMember -Function New-AapWinHyperVProvider
