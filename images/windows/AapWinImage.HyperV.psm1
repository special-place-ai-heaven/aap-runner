# P06 production provider: the only place the image builder calls Hyper-V, Storage, DISM, PowerShell Direct and ACL APIs.
# Windows PowerShell 5.1 (the supervisor's host) and PowerShell 7 on a Hyper-V host, elevated. NOT RUN by P06: authored
# against the documented cmdlets and exercised only through fakes; the first real run is the D2 lab (README, What is not done).
# Every op takes one hashtable. Nothing here downloads: input verification is P03's Invoke-AapManifest -Offline.
# The build and verification guests run internet-sourced installers and are treated as hostile: replies are size-capped
# while received, files received from the guest land in the build folder first, and no host path is ever resolved through
# guest-authored file system metadata (reparse points refused).
# Load AapWinImage.psm1 first: the ops call its exported helpers (Assert-AapPlainPath, Write-AapGuestFile,
# Select-AapWindowsPartition, Receive-AapCappedJob, Set-AapReadOnlyAcl, Wait-AapVmOff, Wait-AapGuestReady).

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:CommonDir = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\common'))
$script:Common = Join-Path $script:CommonDir 'AapArtifact.psm1'
$script:Manifest = Join-Path $PSScriptRoot '..\common\artifacts.manifest.json'
$script:TrustedInstaller = 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
$script:VmSid = 'S-1-5-83-0'   # NT VIRTUAL MACHINE\Virtual Machines: VM worker processes read the parent of a differencing disk
$script:Utf8 = New-Object Text.UTF8Encoding($false)

function Get-AapGuestCredential([string]$User, [string]$Password) {
    $s = New-Object Security.SecureString
    foreach ($c in $Password.ToCharArray()) { $s.AppendChar($c) }
    $s.MakeReadOnly()
    New-Object Management.Automation.PSCredential ".\$User", $s
}
# Every call into a guest, file transfers included, runs as a job whose output is capped while it arrives
# (Receive-AapCappedJob); there is no other channel. A call that cannot start or fails is AAP_GuestUnreachable. $A.Tick,
# when the builder gives one, runs once per poll: its network re-check of the running build VM.
function Invoke-AapGuestJob($A, [scriptblock]$ScriptBlock, [object[]]$ArgumentList = @(), [long]$MaxBytes = 4096, [int]$TimeoutSeconds = 120) {
    try { $job = Invoke-Command -VMId $A.VmId -Credential (Get-AapGuestCredential $A.User $A.Password) -AsJob -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList }
    catch { throw 'AAP_GuestUnreachable: the guest call did not start' }
    Receive-AapCappedJob -Job $job -MaxBytes $MaxBytes -TimeoutSeconds $TimeoutSeconds -Tick $A.Tick
}
function Get-AapVm($A) {
    $vm = @(Hyper-V\Get-VM -Id $A.VmId)
    if ($vm.Count -ne 1) { throw "AAP_Unexpected: VM $($A.VmId) not found" }
    $vm[0]
}
# The Windows partition of a mounted build disk, by the layout the builder made (never by searching for \Windows), with a
# drive letter; the path to \Windows\System32 must hold no reparse point.
function Get-AapWindowsPartitionRoot([int]$DiskNumber) {
    $os = Select-AapWindowsPartition -Partitions @(Get-Partition -DiskNumber $DiskNumber)
    if (-not $os.DriveLetter) { $os | Add-PartitionAccessPath -AssignDriveLetter; $os = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $os.PartitionNumber }
    if (-not $os.DriveLetter) { throw 'AAP_DiskLayout: no drive letter is free for the Windows partition' }
    $root = "$($os.DriveLetter):\"
    $sys = Join-Path $root 'Windows\System32'
    Assert-AapPlainPath -Root $root -Path $sys -Reason 'AAP_HostileGuest'
    if ((Get-AapPathKind $sys) -ne 'dir') { throw 'AAP_HostileGuest: the Windows partition has no \Windows\System32' }
    return $root
}
# The admin-only rule of backend-lifecycle.md revision 2 for one folder: not a link, owned by an admin SID, a protected
# DACL and no ACE, inheritable or inherit-only included, for anyone but the admin SIDs. Plain .NET and Get-Acl, no module,
# so it can run before images\common is loaded.
function Get-AapAdminOnlyProblems([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }
    if (([int][IO.File]::GetAttributes($Path) -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) { "${Path}: is a link"; return }
    $admins = @('S-1-5-18', 'S-1-5-32-544', $script:TrustedInstaller)
    $acl = Get-Acl -LiteralPath $Path
    if ($admins -notcontains $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value) { "${Path}: the owner is not an administrator SID" }
    if (-not $acl.AreAccessRulesProtected) { "${Path}: the DACL inherits from its parent" }
    foreach ($r in @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))) {
        if ($admins -notcontains $r.IdentityReference.Value) { "${Path}: $($r.IdentityReference.Value) has an access entry" }
    }
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
    if (-not (Get-Command Write-AapGuestFile -ErrorAction SilentlyContinue)) { throw 'AAP_ProviderInvalid: import AapWinImage.psm1 before creating the Hyper-V provider' }
    $p = @{}
    $p.TestRootTrust = { param($a)
        # images\common is P03's code: it is loaded only after its own folder passes the admin-only rule here. Then P03's
        # rules (owner, ACL masks, reparse, ancestors, fixed drive) and the admin-only rule for the folder asked about.
        $common = @(Get-AapAdminOnlyProblems $script:CommonDir)
        if ($common.Count) { return @($common | ForEach-Object { "images\common is not admin-only, so it was not loaded: $_" }) }
        Import-Module $script:Common -Force
        @(Get-AapStagingProblems -Root $a.Path | ForEach-Object { $_.Text })
        @(Get-AapAdminOnlyProblems $a.Path)
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
            $letter = ($iso | Get-Volume).DriveLetter
            if (-not $letter) { throw 'AAP_MediaMismatch: the mounted media got no drive letter' }
            $wim = "${letter}:\sources\install.wim"
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
                $efiLetter = (Get-Partition -DiskNumber $disk.Number -PartitionNumber $efi.PartitionNumber).DriveLetter
                $osLetter = (Get-Partition -DiskNumber $disk.Number -PartitionNumber $os.PartitionNumber).DriveLetter
                if (-not $efiLetter -or -not $osLetter) { throw 'AAP_DiskLayout: no drive letter is free for the new partitions' }
                $osRoot = "${osLetter}:\"
                [void](Expand-WindowsImage -ImagePath $wim -Index $img[0].ImageIndex -ApplyPath $osRoot)
                & (Join-Path $env:SystemRoot 'System32\bcdboot.exe') (Join-Path $osRoot 'Windows') /s "${efiLetter}:" /f UEFI | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "AAP_DiskLayout: bcdboot exited $LASTEXITCODE" }
                foreach ($k in @($a.Files.Keys)) { Write-AapGuestFile -Root $osRoot -RelPath $k -Bytes $script:Utf8.GetBytes([string]$a.Files[$k]) }
                foreach ($k in @($a.CopyFiles.Keys)) { Write-AapGuestFile -Root $osRoot -RelPath $k -Bytes ([IO.File]::ReadAllBytes($a.CopyFiles[$k])) }
            } finally { Hyper-V\Dismount-VHD -Path $a.Vhdx }
            @{ ImageIndex = $img[0].ImageIndex; Build = [string]$info.Version }
        } finally { Dismount-DiskImage -ImagePath $a.IsoPath | Out-Null }
    }
    $p.NewDiffDisk = { param($a) [void](Hyper-V\New-VHD -Path $a.Path -ParentPath $a.Parent -Differencing) }
    $p.WriteOfflineFiles = { param($a)
        # Only before a disk's first boot (the verification child of the sealed disk), through Write-AapGuestFile.
        $disk = Hyper-V\Mount-VHD -Path $a.Vhdx -Passthru | Get-Disk
        try {
            $root = Get-AapWindowsPartitionRoot $disk.Number
            foreach ($k in @($a.Files.Keys)) { Write-AapGuestFile -Root $root -RelPath $k -Bytes $script:Utf8.GetBytes([string]$a.Files[$k]) }
        } finally { Hyper-V\Dismount-VHD -Path $a.Vhdx }
    }
    $p.NewVm = { param($a)
        $vm = Hyper-V\New-VM -Name $a.Name -Path $a.Path -Generation 2 -MemoryStartupBytes ([int64]$a.MemGib * 1GB) -VHDPath $a.OsDisk
        Hyper-V\Set-VM -VM $vm -ProcessorCount $a.Cpus -StaticMemory -CheckpointType Disabled -AutomaticStopAction TurnOff -AutomaticStartAction Nothing -SmartPagingFilePath $a.Path -SnapshotFileLocation $a.Path
        Hyper-V\Set-VMProcessor -VM $vm -ExposeVirtualizationExtensions $true      # upstream enables Hyper-V, Containers and WSL2 inside the guest
        Hyper-V\Set-VMFirmware -VM $vm -EnableSecureBoot Off                         # upstream sets bcdedit TESTSIGNING ON
        Hyper-V\Add-VMHardDiskDrive -VM $vm -Path $a.TempDisk
        # No file copy and no key-value exchange between host and guest; PowerShell Direct is the only channel.
        foreach ($svc in 'Guest Service Interface', 'Key-Value Pair Exchange') { Hyper-V\Disable-VMIntegrationService -VM $vm -Name $svc }
        # No adapter: the P10.0 guest network module gives the build VM its one adapter (switch, guards, port ACLs); the
        # verification VM keeps none.
        Hyper-V\Get-VMNetworkAdapter -VM $vm | Hyper-V\Remove-VMNetworkAdapter
        @{ Id = [string]$vm.Id }
    }
    $p.GetVmConfig = { param($a)
        $vm = Get-AapVm $a
        @{ AutomaticStartAction = [string]$vm.AutomaticStartAction; CheckpointType = [string]$vm.CheckpointType }
    }
    $p.StartVm = { param($a) $vm = Get-AapVm $a; if ($vm.State -ne 'Running') { Hyper-V\Start-VM -VM $vm } }
    $p.StopVm = { param($a)
        # As a job: Stop-VM itself waits for the guest to shut down, and the network re-check ($a.Tick) runs while it does.
        $job = Hyper-V\Stop-VM -VM (Get-AapVm $a) -Force -AsJob
        try { if (-not (Wait-AapVmOff -GetState { (Get-AapVm $a).State } -TimeoutSeconds $a.TimeoutSeconds -Tick $a.Tick)) { throw 'AAP_RebootTimeout: guest did not shut down' } }
        finally { Remove-Job -Job $job -Force }
    }
    $p.RemoveVm = { param($a)
        $vm = @(Hyper-V\Get-VM -Name $a.Name -ErrorAction SilentlyContinue)
        if ($vm.Count -gt 1) { throw "AAP_Unexpected: more than one VM is named $($a.Name)" }
        if ($vm.Count) { if ($vm[0].State -ne 'Off') { Hyper-V\Stop-VM -VM $vm[0] -TurnOff -Force }; Hyper-V\Remove-VM -VM $vm[0] -Force }
    }
    $p.WaitGuestReady = { param($a)
        Wait-AapGuestReady -TimeoutSeconds $a.TimeoutSeconds -Tick $a.Tick -Probe { param($t)
            Invoke-AapGuestJob @{ VmId = $a.VmId; User = $a.User; Password = $a.Password; Tick = $t } { 'ready' } -MaxBytes 64 -TimeoutSeconds 60 }
    }
    $p.GetGuestBootTime = { param($a)
        # A guest that is going down or not yet up answers nothing ($null); the builder asks again until its timeout.
        try { $o = Invoke-AapGuestJob $a { [string](Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().Ticks } -MaxBytes 64 }
        catch { if ($_.Exception.Message -match '^AAP_(GuestUnreachable|GuestTimeout):') { return $null }; throw }
        (@($o) | ForEach-Object { [string]$_ }) -join ''
    }
    $p.SendFile = { param($a)
        # 1 MiB chunks, each its own capped call (no copy session, whose replies nothing would cap); the first creates the file.
        $s = [IO.File]::OpenRead($a.HostPath)
        try {
            $first = $true
            do {
                $buf = New-Object byte[] 1048576
                $n = $s.Read($buf, 0, $buf.Length)
                if ($n -lt $buf.Length) { [Array]::Resize([ref]$buf, $n) }
                $null = Invoke-AapGuestJob $a { param($f, $b, $first)
                    if ($first) { [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($f)) }
                    $fs = New-Object IO.FileStream($f, $(if ($first) { [IO.FileMode]::Create } else { [IO.FileMode]::Append }), [IO.FileAccess]::Write)
                    try { $fs.Write($b, 0, $b.Length) } finally { $fs.Dispose() }
                } @($a.GuestPath, $buf, $first) -MaxBytes 4096 -TimeoutSeconds 600
                $first = $false
            } while ($n -eq 1048576)
        } finally { $s.Dispose() }
    }
    $p.InvokeGuest = { param($a)
        $out = Invoke-AapGuestJob $a { param($script, $request)
            & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script -RequestPath $request
        } @($a.Script, $a.RequestPath) -MaxBytes $a.MaxBytes -TimeoutSeconds $a.TimeoutSeconds
        ((@($out) | ForEach-Object { [string]$_ }) -join "`n").Trim()
    }
    $p.ReceiveFile = { param($a)
        # The guest streams the file as byte chunks; the cap counts them as they arrive and the host file is created new.
        # A failed call (file missing, guest down) throws before any host file exists.
        $chunks = Invoke-AapGuestJob $a { param($f, $max)
            $s = [IO.File]::OpenRead($f)
            try {
                $left = [long]$max + 1
                while ($left -gt 0) {
                    $buf = New-Object byte[] ([int][Math]::Min(1048576, $left))
                    $n = $s.Read($buf, 0, $buf.Length)
                    if ($n -le 0) { break }
                    if ($n -lt $buf.Length) { [Array]::Resize([ref]$buf, $n) }
                    Write-Output -NoEnumerate $buf
                    $left -= $n
                }
            } finally { $s.Dispose() }
        } @($a.GuestPath, $a.MaxBytes) -MaxBytes $a.MaxBytes -TimeoutSeconds 1800
        $fs = New-Object IO.FileStream($a.HostPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            foreach ($c in @($chunks)) {
                if (-not ($c -is [byte[]])) { throw 'AAP_HostileGuest: the guest sent something other than file bytes' }
                $fs.Write($c, 0, $c.Length)
            }
        } finally { $fs.Dispose() }
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
    $p.SetReadOnlyAcl = { param($a)
        # Owner Administrators; SYSTEM, Administrators and the VM worker group may read; nobody may write. Inheritance off.
        Set-AapReadOnlyAcl -Path $a.Path -Owner 'S-1-5-32-544' -Readers @('S-1-5-18', 'S-1-5-32-544', $script:VmSid)
    }
    $p.GetVmNetwork = { param($a)
        # The read-back of host-network-module.md (Consumer obligations), as Hyper-V shows each adapter, never as the network
        # module says; the shared check judges it. Under StrictMode a misspelt property throws instead of reading as unset.
        $vm = Get-AapVm $a
        foreach ($n in @(Hyper-V\Get-VMNetworkAdapter -VM $vm)) {
            $name = ''; $type = ''
            if ($n.SwitchId) { $sw = Hyper-V\Get-VMSwitch -Id $n.SwitchId -ErrorAction Stop; $name = [string]$sw.Name; $type = [string]$sw.SwitchType }
            # MacAddress goes through as Hyper-V prints it: the shared check normalises it (twelve hex digits, no separators). This
            # module is apart from the one that imports the check, so it must not call the check's functions (contract, Read-back).
            @{  SwitchName = $name; SwitchType = $type
                MacAddress = [string]$n.MacAddress; DhcpGuard = [string]$n.DhcpGuard; RouterGuard = [string]$n.RouterGuard; MacAddressSpoofing = [string]$n.MacAddressSpoofing
                PortMirroringMode = [string]$n.PortMirroringMode; VlanMode = [string]$n.VlanSetting.OperationMode; StormLimit = [string]$n.StormLimit
                LegacyAcls = @(Hyper-V\Get-VMNetworkAdapterAcl -VMNetworkAdapter $n).Count
                # the other VMs with an adapter on the same switch; the host's own adapters are not VMs
                Peers = @(Hyper-V\Get-VMNetworkAdapter -All | Where-Object { $name -and -not $_.IsManagementOs -and $_.SwitchName -ceq $name -and $_.VMId -ne $vm.Id } |
                    ForEach-Object { [string]$_.VMName })
                Acls = @(Hyper-V\Get-VMNetworkAdapterExtendedAcl -VMNetworkAdapter $n | ForEach-Object {
                    @{ Action = [string]$_.Action; Direction = [string]$_.Direction; RemoteAddress = [string]$_.RemoteIPAddress
                       LocalAddress = [string]$_.LocalIPAddress; Protocol = [string]$_.Protocol; RemotePort = [string]$_.RemotePort
                       LocalPort = [string]$_.LocalPort; Weight = $_.Weight; Stateful = [string]$_.Stateful; IsolationId = [string]$_.IsolationID } }) }
        }
    }
    $p.GetVmMemoryOverheadMib = { param($a)
        $id = [string](Get-AapVm $a).Id
        $w = @(Get-CimInstance Win32_Process -Filter "Name='vmwp.exe'" | Where-Object { $_.CommandLine -match $id })
        if ($w.Count -ne 1) { throw 'AAP_Unmeasured: VM worker process not found' }
        [int][Math]::Ceiling($w[0].WorkingSetSize / 1MB)
    }
    return $p
}

Export-ModuleMember -Function New-AapWinHyperVProvider
