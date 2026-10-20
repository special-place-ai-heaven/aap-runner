# P07 production provider: the only place the Ubuntu image builder calls Hyper-V, Storage, IMAPI, hvsocket, ACL and
# comparison APIs. Windows PowerShell 5.1 (the supervisor's host) and PowerShell 7 on a Hyper-V host, elevated. NOT RUN by
# P07: authored against the documented cmdlets and exercised only through fakes; the first real run is the D2 lab (README,
# What is not done). Every op takes one hashtable. Nothing here downloads: input verification is P03's
# Invoke-AapManifest -Offline.
# The guests are hostile. The host never attaches or mounts a guest disk: files go in on host-built seed images, and the
# only channel back is an hvsocket connection to the guest agent (vsock port from the plan) whose reply is capped while it
# is received. No guest gets a network adapter except the build VM, on the internal switch aap-guests-linux.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
# P06's read-only ACL and safe deletion helpers (Set-AapReadOnlyAcl, Remove-AapTree).
Import-Module (Join-Path $PSScriptRoot '..\windows\AapWinImage.psm1')
$script:Common = Join-Path $PSScriptRoot '..\common\AapArtifact.psm1'
$script:Manifest = Join-Path $PSScriptRoot '..\common\artifacts.manifest.json'
$script:Certify = Join-Path $PSScriptRoot '..\..\tools\parity-certify\certify.py'
$script:TrustedInstaller = 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
$script:VmSid = 'S-1-5-83-0'   # NT VIRTUAL MACHINE\Virtual Machines: VM worker processes read the parent of a differencing disk
$script:SwitchName = 'aap-guests-linux'
$script:Utf8 = New-Object Text.UTF8Encoding($false)
$script:Python = $null

# The hvsocket client: a SOCKADDR_HV endpoint (family 34, VM id, service id) and one call per connection that sends the
# header and payload, closes the sending side, and reads the reply until the guest closes it, at most maxBytes.
$script:ChannelSource = @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
public class AapHvEndPoint : EndPoint {
    readonly Guid vm, svc;
    public AapHvEndPoint(Guid vm, Guid svc) { this.vm = vm; this.svc = svc; }
    public override AddressFamily AddressFamily { get { return (AddressFamily)34; } }
    public override SocketAddress Serialize() {
        SocketAddress sa = new SocketAddress((AddressFamily)34, 36);
        byte[] v = vm.ToByteArray(), s = svc.ToByteArray();
        for (int i = 0; i < 16; i++) { sa[4 + i] = v[i]; sa[20 + i] = s[i]; }
        return sa;
    }
    public override EndPoint Create(SocketAddress sa) { return this; }
}
public static class AapHvChannel {
    public static long Call(Guid vm, Guid svc, byte[] header, Stream payload, Stream reply, long maxBytes, int timeoutMs) {
        using (Socket s = new Socket((AddressFamily)34, SocketType.Stream, (ProtocolType)1)) {
            s.SendTimeout = timeoutMs; s.ReceiveTimeout = timeoutMs;
            s.Connect(new AapHvEndPoint(vm, svc));
            s.Send(header);
            if (payload != null) {
                byte[] buf = new byte[1 << 20]; int n;
                while ((n = payload.Read(buf, 0, buf.Length)) > 0) { int off = 0; while (off < n) { off += s.Send(buf, off, n - off, SocketFlags.None); } }
            }
            s.Shutdown(SocketShutdown.Send);
            using (NetworkStream ns = new NetworkStream(s, false)) { return Copy(ns, reply, maxBytes, timeoutMs); }
        }
    }
    // Reads until the sender closes, counting bytes as they arrive: one byte over maxBytes, or the deadline, ends the call.
    public static long Copy(Stream src, Stream dst, long maxBytes, int timeoutMs) {
        DateTime deadline = DateTime.UtcNow.AddMilliseconds(timeoutMs);
        byte[] rb = new byte[65536]; long total = 0; int r;
        while ((r = src.Read(rb, 0, rb.Length)) > 0) {
            total += r;
            if (total > maxBytes) { throw new InvalidDataException("AAP_HostileGuest: the guest sent over " + maxBytes + " bytes"); }
            dst.Write(rb, 0, r);
            if (DateTime.UtcNow > deadline) { throw new TimeoutException("AAP_GuestTimeout: no complete reply in time"); }
        }
        return total;
    }
}
'@

# The ISO writer for seed images: IMAPI2's result stream, copied block by block into a file created new.
$script:IsoSource = @'
using System;
using System.IO;
using System.Runtime.InteropServices.ComTypes;
public static class AapIsoWriter {
    public static void Save(object stream, string path, int blockSize, int blocks) {
        IStream s = (IStream)stream;
        using (FileStream fs = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None)) {
            byte[] buf = new byte[blockSize];
            for (int i = 0; i < blocks; i++) { s.Read(buf, blockSize, IntPtr.Zero); fs.Write(buf, 0, blockSize); }
        }
    }
}
'@

function Initialize-AapType([string]$Name, [string]$Source) { if (-not ($Name -as [type])) { Add-Type -TypeDefinition $Source -Language CSharp } }

function Get-AapVm($A) {
    $vm = @(Hyper-V\Get-VM -Id $A.VmId)
    if ($vm.Count -ne 1) { throw "AAP_Unexpected: VM $($A.VmId) not found" }
    $vm[0]
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

# One request on the guest channel. The header names a fixed verb; the token is the per-guest credential from its seed.
# A connection that cannot be made or breaks is AAP_GuestUnreachable, a slow one AAP_GuestTimeout, an oversized reply
# AAP_HostileGuest; nothing a guest sends is ever an empty success.
function Invoke-AapChannel($A, [IO.Stream]$Reply) {
    Initialize-AapType 'AapHvChannel' $script:ChannelSource
    $len = 0; $payload = $null
    try {
        if ($A.ContainsKey('InputPath') -and $A.InputPath) { $payload = [IO.File]::OpenRead($A.InputPath); $len = $payload.Length }
        elseif ($A.ContainsKey('InputText') -and $null -ne $A.InputText) { $b = $script:Utf8.GetBytes([string]$A.InputText); $payload = New-Object IO.MemoryStream(, $b); $len = $b.Length }
        $header = [Text.Encoding]::ASCII.GetBytes("aap1 $($A.Token) $($A.Verb) $($A.Name) $len`n")
        $svc = [guid]('{0:x8}-facb-11e6-bd58-64006a7986d3' -f [int]$A.Port)
        try { return [AapHvChannel]::Call([guid]$A.VmId, $svc, $header, $payload, $Reply, [long]$A.MaxBytes, [int]$A.TimeoutSeconds * 1000) }
        catch {
            $m = [string]$_.Exception.GetBaseException().Message
            if ($m -match '^AAP_(HostileGuest|GuestTimeout):') { throw $m }
            if ($_.Exception.GetBaseException() -is [Net.Sockets.SocketException] -and $_.Exception.GetBaseException().SocketErrorCode -eq 'TimedOut') { throw 'AAP_GuestTimeout: the guest did not answer in time' }
            throw 'AAP_GuestUnreachable: the guest channel failed'
        }
    } finally { if ($payload) { $payload.Dispose() } }
}

function New-AapUbuntuHyperVProvider {
    <# The provider hashtable Invoke-AapUbuntuImageBuild expects. PythonPath: the python 3 the installer deploys for P05's
       comparison (absolute path, admin-only folder). #>
    param([Parameter(Mandatory)][string]$PythonPath)
    if ($PythonPath -cnotmatch '^[A-Za-z]:\\' -or -not (Test-Path -LiteralPath $PythonPath -PathType Leaf)) { throw 'AAP_ProviderInvalid: PythonPath must be an absolute path to python.exe' }
    $script:Python = $PythonPath
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
    # An empty dynamic disk; the guest's installer partitions and formats it. The host never attaches it.
    $p.NewBuildDisk = { param($a) [void](Hyper-V\New-VHD -Path $a.Path -SizeBytes ([uint64]$a.SizeGib * 1GB) -Dynamic) }
    $p.NewDiffDisk = { param($a) [void](Hyper-V\New-VHD -Path $a.Path -ParentPath $a.Parent -Differencing) }
    # The seed: an ISO 9660 + Joliet image labelled CIDATA (cloud-init NoCloud), built from files written into a new folder.
    $p.NewSeedImage = { param($a)
        Initialize-AapType 'AapIsoWriter' $script:IsoSource
        $dir = "$($a.Path).files"
        [void][IO.Directory]::CreateDirectory($dir)
        try {
            foreach ($k in @($a.Files.Keys)) {
                $fs = New-Object IO.FileStream((Join-Path $dir $k), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                try { $b = $script:Utf8.GetBytes([string]$a.Files[$k]); $fs.Write($b, 0, $b.Length) } finally { $fs.Dispose() }
            }
            $img = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
            $img.FileSystemsToCreate = 3   # ISO 9660 and Joliet: Joliet keeps the lower-case names cloud-init looks for
            $img.VolumeName = $a.Label
            $img.Root.AddTree($dir, $false)
            $res = $img.CreateResultImage()
            [AapIsoWriter]::Save($res.ImageStream, $a.Path, [int]$res.BlockSize, [int]$res.TotalBlocks)
        } finally { Remove-AapTree $dir (Split-Path -Parent $dir) }
    }
    $p.GetSwitch = { param($a)
        $s = @(Hyper-V\Get-VMSwitch -Name $a.Name -ErrorAction SilentlyContinue)
        if ($s.Count -ne 1) { return $null }
        @{ Name = [string]$s[0].Name; SwitchType = [string]$s[0].SwitchType }
    }
    $p.NewVm = { param($a)
        $vm = Hyper-V\New-VM -Name $a.Name -Path $a.Path -Generation 2 -MemoryStartupBytes ([int64]$a.MemGib * 1GB) -NoVHD
        Hyper-V\Set-VM -VM $vm -ProcessorCount $a.Cpus -StaticMemory -CheckpointType Disabled -AutomaticStopAction TurnOff -AutomaticStartAction Nothing -SmartPagingFilePath $a.Path -SnapshotFileLocation $a.Path
        # Ubuntu's shim is signed by the Microsoft UEFI CA.
        Hyper-V\Set-VMFirmware -VM $vm -EnableSecureBoot On -SecureBootTemplate 'MicrosoftUEFICertificateAuthority'
        Hyper-V\Add-VMHardDiskDrive -VM $vm -Path $a.OsDisk
        foreach ($iso in @($a.Dvds)) { Hyper-V\Add-VMDvdDrive -VM $vm -Path $iso }
        $first = $(if ($a.BootFromDvd) { @(Hyper-V\Get-VMDvdDrive -VM $vm)[0] } else { @(Hyper-V\Get-VMHardDiskDrive -VM $vm)[0] })
        Hyper-V\Set-VMFirmware -VM $vm -FirstBootDevice $first
        # No file copy and no key-value exchange between host and guest; the hvsocket agent is the only channel.
        foreach ($svc in 'Guest Service Interface', 'Key-Value Pair Exchange') { Hyper-V\Disable-VMIntegrationService -VM $vm -Name $svc }
        $nic = @(Hyper-V\Get-VMNetworkAdapter -VM $vm)
        if ($a.SwitchName) {
            $s = @(Hyper-V\Get-VMSwitch -Name $a.SwitchName -ErrorAction SilentlyContinue)
            if ([string]$a.SwitchName -cne $script:SwitchName -or $s.Count -ne 1 -or [string]$s[0].SwitchType -ne 'Internal') { throw "AAP_NetworkUntrusted: guests attach only to the internal switch $($script:SwitchName)" }
            $nic | Hyper-V\Connect-VMNetworkAdapter -SwitchName $a.SwitchName
        } else {
            $nic | Hyper-V\Remove-VMNetworkAdapter
        }
        @{ Id = [string]$vm.Id }
    }
    $p.StartVm = { param($a) $vm = Get-AapVm $a; if ($vm.State -ne 'Running') { Hyper-V\Start-VM -VM $vm } }
    # Packer's hyperv-iso boot command: text and <enter> typed into the installer's GRUB through the synthetic keyboard
    # (Msvm_Keyboard), <waitN> pauses N seconds. Host to guest only; nothing comes back.
    $p.TypeBootCommand = { param($a)
        $cs = Get-CimInstance -Namespace 'root\virtualization\v2' -ClassName Msvm_ComputerSystem -Filter "Name='$($a.VmId)'"
        $kb = @(Get-CimAssociatedInstance -InputObject $cs -ResultClassName Msvm_Keyboard)
        if ($kb.Count -ne 1) { throw 'AAP_Unexpected: the VM has no synthetic keyboard' }
        foreach ($k in @($a.Keys)) {
            if ($k -match '^<wait([0-9]*)>$') { Start-Sleep -Seconds $(if ($Matches[1]) { [int]$Matches[1] } else { 1 }); continue }
            $parts = $k -split '<enter>', -1
            for ($i = 0; $i -lt $parts.Count; $i++) {
                if ($parts[$i]) { $null = Invoke-CimMethod -InputObject $kb[0] -MethodName TypeText -Arguments @{ asciiText = $parts[$i] } }
                if ($i -lt $parts.Count - 1) { $null = Invoke-CimMethod -InputObject $kb[0] -MethodName TypeKey -Arguments @{ keyCode = [uint32]13 } }
            }
        }
    }
    $p.WaitVmOff = { param($a)
        $until = (Get-Date).AddSeconds($a.TimeoutSeconds)
        while ((Get-Date) -lt $until) { if ((Get-AapVm $a).State -eq 'Off') { return $true }; Start-Sleep -Seconds 15 }
        return $false
    }
    $p.RemoveDvds = { param($a)
        $vm = Get-AapVm $a
        Hyper-V\Get-VMDvdDrive -VM $vm | Hyper-V\Remove-VMDvdDrive
        Hyper-V\Set-VMFirmware -VM $vm -FirstBootDevice (@(Hyper-V\Get-VMHardDiskDrive -VM $vm)[0])
    }
    $p.StopVm = { param($a)
        Hyper-V\Stop-VM -VM (Get-AapVm $a) -Force
        $until = (Get-Date).AddSeconds($a.TimeoutSeconds)
        while ((Get-AapVm $a).State -ne 'Off') { if ((Get-Date) -gt $until) { throw 'AAP_RebootTimeout: guest did not shut down' }; Start-Sleep -Seconds 5 }
    }
    $p.RemoveVm = { param($a)
        $vm = @(Hyper-V\Get-VM -Name $a.Name -ErrorAction SilentlyContinue)
        if ($vm.Count -gt 1) { throw "AAP_Unexpected: more than one VM is named $($a.Name)" }
        if ($vm.Count) { if ($vm[0].State -ne 'Off') { Hyper-V\Stop-VM -VM $vm[0] -TurnOff -Force }; Hyper-V\Remove-VM -VM $vm[0] -Force }
    }
    $p.WaitGuestReady = { param($a)
        $until = (Get-Date).AddSeconds($a.TimeoutSeconds)
        while ((Get-Date) -lt $until) {
            $ms = New-Object IO.MemoryStream
            try {
                $null = Invoke-AapChannel (@{ VmId = $a.VmId; Port = $a.Port; Token = $a.Token; Verb = 'ready'; Name = '-'; MaxBytes = 64; TimeoutSeconds = 30 }) $ms
                if ($script:Utf8.GetString($ms.ToArray()).Trim() -ceq 'ready') { return $true }
            } catch { $null = $_ } finally { $ms.Dispose() }
            Start-Sleep -Seconds 15
        }
        return $false
    }
    $p.InvokeGuest = { param($a)
        $ms = New-Object IO.MemoryStream
        try {
            $null = Invoke-AapChannel $a $ms
            $b = $ms.ToArray()
            foreach ($x in $b) { if ($x -lt 9 -or ($x -gt 13 -and $x -lt 32) -or $x -gt 126) { throw 'AAP_HostileGuest: the guest reply is not printable ASCII' } }
            [Text.Encoding]::ASCII.GetString($b)
        } finally { $ms.Dispose() }
    }
    $p.ReceiveFile = { param($a)
        # The file streams into a host file created new; the cap counts bytes as they arrive. Zero bytes is a missing file.
        $fs = New-Object IO.FileStream($a.HostPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $n = Invoke-AapChannel (@{ VmId = $a.VmId; Port = $a.Port; Token = $a.Token; Verb = 'get'; Name = $a.Name; MaxBytes = $a.MaxBytes; TimeoutSeconds = $a.TimeoutSeconds }) $fs }
        finally { $fs.Dispose() }
        if ($n -le 0) { throw "AAP_GuestUnreachable: the guest has no $($a.Name)" }
    }
    # The guest trimmed its free space before it shut down; Pretrimmed reclaims it without attaching the disk.
    $p.OptimizeDisk = { param($a) Hyper-V\Optimize-VHD -Path $a.Vhdx -Mode Pretrimmed }
    $p.SetReadOnlyAcl = { param($a)
        # Owner Administrators; SYSTEM, Administrators and the VM worker group may read; nobody may write. Inheritance off.
        Set-AapReadOnlyAcl -Path $a.Path -Owner 'S-1-5-32-544' -Readers @('S-1-5-18', 'S-1-5-32-544', $script:VmSid)
    }
    $p.GetVmMemoryOverheadMib = { param($a)
        $id = [string](Get-AapVm $a).Id
        $w = @(Get-CimInstance Win32_Process -Filter "Name='vmwp.exe'" | Where-Object { $_.CommandLine -match $id })
        if ($w.Count -ne 1) { throw 'AAP_Unmeasured: VM worker process not found' }
        [int][Math]::Ceiling($w[0].WorkingSetSize / 1MB)
    }
    # P05's comparison in a hidden child: the committed reference against the capped guest inventory. Exit 0 pass, 1 differences, 2 error.
    $p.CompareInventory = { param($a)
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $script:Python
        $psi.Arguments = ('-B -I "{0}" compare --reference "{1}" --candidate "{2}" --allowlist "{3}" --out "{4}"' -f $script:Certify, $a.Reference, $a.Candidate, $a.Allowlist, $a.Out)
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $proc = [Diagnostics.Process]::Start($psi)
        try {
            $err = $proc.StandardError.ReadToEndAsync()
            $null = $proc.StandardOutput.ReadToEnd()
            if (-not $proc.WaitForExit(600000)) { $proc.Kill(); throw 'AAP_VerifyFailed: the inventory comparison did not finish' }
            $null = $err.Result
            $proc.ExitCode
        } finally { $proc.Dispose() }
    }
    return $p
}

Export-ModuleMember -Function New-AapUbuntuHyperVProvider
